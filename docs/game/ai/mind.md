# A mind: think, one action and the loop

A zombie that patrols two points, chases what it remembers and bites it, two at a time per
target. Its `zombie_patrol` and `zombie_bite` have the shape of `zombie_chase`. The entity that
carries the mind: [what an enemy is](../ai.md#what-an-enemy-is).

```odin
package game

import "core:math/linalg"
import "mirai:core"
import "mirai:std/ai"
import behavior "plugins:behavior/runtime"

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
zombie_chase :: proc(a:^ai.Act(Zombie_Act)) -> ai.Status {
    w := (^Tick)(a.user)
    subject, _, _, _ := seen(w)
    if subject == core.NONE && a.phase != .Exit {return .Failure}
    return behavior.follow_act(w, a, subject, 1.2) // Exit stops the agent
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
```
