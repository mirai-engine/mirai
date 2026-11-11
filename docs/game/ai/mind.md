# A mind: think and its actions

A zombie that patrols a path, chases what it remembers and bites it, two at a time per target.
The entity that carries the mind: [what an enemy is](../ai.md#what-an-enemy-is).

```odin
package game

import "core:math/linalg"
import "mirai:core"
import "mirai:std/ai"
import behavior "plugins:behavior/runtime"

BITERS :: 2
Zombie_Act :: enum u8 {Patrol, Chase, Bite}

// What the zombie reads of the world: a group of parameters, as for a step.
@(params)
Senses :: struct {
    worlds:core.Read(core.World_Transform),
    perceptions:core.Read(behavior.Perception),
}

// The subject the agent remembers best, where it was seen, how sure, and where the agent is.
seen :: proc(w:Senses, e:core.Entity) -> (subject:core.Entity, at:[3]f32, sure:f32, here:[3]f32) {
    pose, _ := core.get(w.worlds, e)
    here = pose.position
    mine, ok := core.get(w.perceptions, e)
    if !ok {return}
    best, found := ai.memory_best(&mine.memory, here)
    if !found {return}
    return core.Entity(best.subject), best.position, best.confidence, here
}

@(mind="zombie") // the name its agents say in Mind_Agent.mind
zombie_think :: proc(t:^ai.Think(Zombie_Act), w:Senses) { // only reads and proposes
    ai.propose(t, .Patrol, 0.1)
    subject, at, sure, here := seen(w, behavior.agent(t))
    if subject == core.NONE || sure < 0.2 {return}
    ai.propose(t, .Chase, 0.5)
    if linalg.length(at-here) < 1.8 && ai.reserve_free(t, subject, BITERS) {
        ai.propose(t, .Bite, 1)
    }
}

@(act="Patrol")
zombie_patrol :: proc(a:^ai.Act(Zombie_Act)) -> ai.Status {return behavior.patrol_act(a)}

@(act="Chase")
zombie_chase :: proc(a:^ai.Act(Zombie_Act), w:Senses) -> ai.Status {
    subject, _, _, _ := seen(w, behavior.agent(a))
    return behavior.chase_act(a, subject, 1.2) // follows a new subject; Exit stops the agent
}

@(act="Bite")
zombie_bite :: proc(a:^ai.Act(Zombie_Act), w:Senses) -> ai.Status {
    if a.phase == .Enter {
        subject, _, _, _ := seen(w, behavior.agent(a))
        if !ai.token_take(a, u64(subject), BITERS) {return .Failure} // released on Exit
    }
    return ai.after(a, 0.8)
}
```

- The engine runs the mind on the server in a `fixed` step named after its `think`
  (`zombie_think`), only while the world plays; other steps order against it with `after` and
  `before`. What each procedure receives after its first parameter is bound as for a step.
- Every value of the enum has one `@(act)`; one procedure may run several (`@(act="Chase
  Circle")`, then `a.action` says which). The build fails with what to write otherwise.
- `behavior.agent(a)` is the agent; the helpers of `behavior` (`move_act`, `chase_act`,
  `patrol_act`, `path_status`, `agent_path`, `present_look`, smart objects) take only `a` or `t`.

## Patrol

A path is a `Spline` ([splines](../world/splines.md)), drawn in the editor; the agent's
`behavior.Patrol{path=e}` names its entity, with `mode` `.Loop`, `.Back_And_Forth` or `.Once`.
An NPC that only patrols needs no mind: with `nav.Nav_Agent` and `Patrol` it walks the path by
itself. With a mind it walks it while an action returns `behavior.patrol_act(a)`, as above.

- It starts at the point after where it is nearest the path, so one pushed off or back from a
  chase rejoins it, and walks from point to point; the curve between two is the navmesh's way.
- A point it cannot reach (off the navmesh, no way there) is skipped for the next one.
- A path moved or edited while walked: it goes to where its point is now.
- A path of one point is a post: it walks there and stands.
- An interrupted patrol stops the agent, except in the middle of a link it crosses.
- No path to walk (no `Spline` on `path`, a point not finite): it fails with the problem
  `behavior.patrol`.
