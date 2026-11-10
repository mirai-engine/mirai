# Order, requests and events

## Order

A function runs in a stage of its phase: `@(step="fixed",stage="react")`.
Stages of `fixed`, in order: `begin` (network), `input` (seats and their actions), `intent`
(default: your rules; they write `Move_Input` and push requests), `apply` (spawns, cameras,
animation sampling), `simulate` (locomotion and physics), `react` (reads contacts and damage),
`end`.

Inside a stage the parameters order the functions: one that pushes a request runs before the
library that takes it, and the writer of a table, a storage or events before its readers.
`after="a b"` and `before="c"` name functions of the engine or of your plugins, inside the stage,
only for what the parameters do not say: reading what the last tick left on purpose
(`before="the_writer"`), which of two functions that read each other runs first (`mirai generate`
reports the cycle and the name that settles it), and what goes through `shared` data,
`core.Commands` or the renderer. Functions of your library that share a queue run as declared.
A name wins over the data; an `after` toward a later stage is an error.

`server` (`@(step="fixed",server)`) runs only where the rules are decided: a lone game or a
server. Use it for rules; split what also has to run on clients.

## Request: ask the library that owns the data

A table has one writing function and a storage one writing library. Everyone else pushes into a
queue storage that its owner takes in its own step.

```odin
Hit :: struct {target:core.Entity, damage:f32}

@(storage,queue)
Hit_Requests :: struct {queue:core.Queue(Hit)}

hit :: proc(requests:^Hit_Requests,target:core.Entity,damage:f32) {
    core.push(&requests.queue,Hit{target,damage})
}

@(step="fixed")
game_hits :: proc(requests:^Hit_Requests,healths:^core.Table(Health)) {
    for request in core.take(&requests.queue) {
        if health:=core.edit(healths,request.target);health!=nil {health.hp-=request.damage}
    }
}
```

Any other function receives `^Hit_Requests` and calls `hit(requests,e,5)`. The engine's work the
same way: `scene.spawn(spawner,"arena/Crate.prefab",at)`, `phys.set_velocity(bodies,e,v)`,
`save.request_save(saves,"slot")`, `core.place(placer,e,position)` (teleport anything;
`at_rest=true` also stops a body),
`inp.drive(seats,seat,body)`, `cam.camera_mode(changes,camera,.Aim)`.

Finding what to act on: `core.first(table)` and `core.sole(table)` return an entity and `ok`
(`sole`: only when it is the one row), `core.entity_named(names,"Lift")` finds by name, and
`core.set_on(table,e,on)` turns a component on or off at the end of the function.

## Event: tell the rest what happened

```odin
@(storage)
Score :: struct {points:i32}

@(storage,events)
Hit_Events :: struct {landed:core.Queue(Hit)}

@(step="fixed",stage="react")
game_hit_events :: proc(events:^Hit_Events) {
    core.queue_clear(&events.landed)               // the owner clears, then fills
    // core.push(&events.landed,Hit{e,5})
}

@(step="fixed",stage="react")
game_score :: proc(events:core.Ref(Hit_Events),score:^Score) {
    for hit in events.landed.items {score.points+=i32(hit.damage)}
}
```

Readers take `core.Ref(Events)` in the stage of the owner or a later one: in its stage they run
after it. Engine events:
`phys.Physics_Events` (contacts, overlaps, sleep), `anim.Animation_Events`,
`destruct.Destruct_Events`; read them in `stage="react"` of the same tick.
`save.Save_Results` and `scene.Scene_Results` are filled and emptied by frame: read them in a
`frame` step. A `fixed` step that reads such a storage is a generator error.

## Pitfalls that fail silently

- Two functions writing the same non-`shared` table, or two libraries writing a storage, is a
  generator error: the second pushes a request.
- A reader in an earlier stage than the owner's does not see this tick's events.
- Waiting is a deadline tick, never a countdown: [waiting.md](waiting.md).
- A request names a `core.Entity`: if it died before the owner ran, the request does nothing.
  Report it with `core.report(problems,e,"game.cause","what failed and how to fix it")`.
- A queue nobody takes grows: the owner's step must run on every end that pushes (not `server`).
