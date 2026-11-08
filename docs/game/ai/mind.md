# A complete mind

A zombie that patrols two points, chases what it remembers and bites it, two at a time per
target. `project.mirai` lists the plugin `behavior`, which brings `navigation` and `physics`.

```odin
package game

import "core:math/linalg"
import "mirai:core"
import "mirai:std/ai"
import behavior "plugins:behavior/runtime"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"

TEAM_PLAYER :: behavior.Team(1)
TEAM_ENEMY :: behavior.Team(2)
BITERS :: 2
@(component)
Patrol :: struct {points:[2][3]f32, next:i32}
Zombie_Act :: enum u8 {Patrol, Chase, Bite}
Tick :: struct { // what the actions read: Mind_Tick and the tables of the game
    using mind:behavior.Mind_Tick,
    patrols:^core.Table(Patrol),
}

// The subject the agent remembers best, where it was seen, how sure, and where the agent is.
seen :: proc(w:^Tick) -> (subject:core.Entity, at:[3]f32, sure:f32, here:[3]f32) {
    pose, _ := core.get(w.worlds, w.entity)
    here = pose.position
    mine, ok := core.get(w.perceptions, w.entity)
    if !ok {return}
    best, found := ai.memory_best(&mine.memory, here)
    if !found {return}
    return core.Entity(best.subject), best.position, best.confidence, here
}
zombie_think :: proc(t:^ai.Think(Zombie_Act)) { // only reads and proposes
    w := (^Tick)(t.user)
    ai.propose(t, .Patrol, 0.1)
    subject, at, sure, here := seen(w)
    if subject == core.NONE || sure < 0.2 {return}
    ai.propose(t, .Chase, 0.5)
    if linalg.length(at-here) < 1.8 &&
       ai.reserve_free(t, subject, BITERS) {
        ai.propose(t, .Bite, 1)
    }
}
zombie_patrol :: proc(a:^ai.Act(Zombie_Act)) -> ai.Status {
    w := (^Tick)(a.user)
    p := core.get(w.patrols, w.entity)
    if p == nil {return .Success if a.phase == .Exit else .Failure}
    if a.phase == .Enter {return behavior.move_act(w, a, p.points[p.next])}
    status := behavior.move_act(w, a, {}) // Update: the path state; Exit: stops if aborted
    if status == .Running || a.phase == .Exit {return status}
    p.next = 1 - p.next // arrived or could not: the other point
    return status
}
zombie_chase :: proc(a:^ai.Act(Zombie_Act)) -> ai.Status {
    w := (^Tick)(a.user)
    subject, _, _, _ := seen(w)
    if subject == core.NONE && a.phase != .Exit {return .Failure}
    return behavior.follow_act(w, a, subject, 1.2) // Exit stops the agent
}
zombie_bite :: proc(a:^ai.Act(Zombie_Act)) -> ai.Status {
    w := (^Tick)(a.user)
    if a.phase == .Exit {return .Success}
    if a.phase == .Enter {
        subject, _, _, _ := seen(w)
        if subject == core.NONE || !ai.token_take(a, u64(subject), BITERS) {return .Failure}
        // The damage is the game's own component, written here.
    }
    return ai.after(a, 0.8)
}
ZOMBIE_ACTS := [Zombie_Act]proc(a:^ai.Act(Zombie_Act)) -> ai.Status {
    .Patrol = zombie_patrol, .Chase = zombie_chase, .Bite = zombie_bite,
}

@(step="fixed", server)
zombies_think :: proc(world:behavior.Mind_World, patrols:^core.Table(Patrol)) {
    if !world.time.playing || world.time.dt <= 0 {return}
    w := Tick{mind=behavior.mind_tick(world), patrols=patrols}
    ctx := ai.Mind_Context{user=&w, keep=0.05, reservations=&world.claims.reservations}
    behavior.minds_tick(world.minds, world.agents, "zombie", &ZOMBIE_ACTS, zombie_think,
                        &ctx, &w.act, world.time, world.problems)
    behavior.minds_unknown(world.minds, world.agents, world.problems) // once, after every mind
}

zombie_add :: proc(c:core.Commands, at:[3]f32, route:[2][3]f32) -> core.Entity {
    e := core.commands_create(c)
    core.commands_add(c, e, core.Id{core.id_next(c.entities)}) // so the API can name it
    core.commands_add(c, e, core.Transform{at, 1, {1,1,1}})
    core.commands_add(c, e, phys.character_default())
    core.commands_add(c, e, phys.collider_character())
    core.commands_add(c, e, phys.WALK_DEFAULT)
    core.commands_add(c, e, nav.NAV_AGENT_DEFAULT)
    core.commands_add(c, e, Patrol{points=route})
    core.commands_add(c, e, behavior.Mind_Agent{mind=behavior.mind_name("zombie")})
    core.commands_add(c, e, behavior.MIND_PRESENTATION_DEFAULT)
    perceiver := behavior.PERCEIVER_DEFAULT
    perceiver.notices = behavior.Teams(1 << u32(TEAM_PLAYER))
    core.commands_add(c, e, perceiver)
    core.commands_add(c, e, behavior.Perceivable{team=TEAM_ENEMY, point=1})
    return e
}
```

The player's body carries `behavior.Perceivable{team=TEAM_PLAYER, point=1}` and a collider, so the
sight ray reaches it. The agent sees along the +Z of its body.
