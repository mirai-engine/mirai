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

A table and a storage have one writing library, whose functions write them in loop order. Every
other library pushes into a queue storage that its owner takes in its own step.

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
same way: `scene.spawn(spawner,"arena/Crate.scene",at)`, `phys.set_velocity(bodies,e,v)`,
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

@(storage)
Hit_Events :: struct {landed:core.Events(Hit)}

@(step="fixed",stage="react")
game_hit_events :: proc(events:^Hit_Events) {
    // core.push(&events.landed,Hit{e,5})         // the owner pushes and never clears
}

@(step="fixed",stage="react")
game_score :: proc(events:core.Ref(Hit_Events),score:^Score) {
    for hit in events.landed.items {score.points+=i32(hit.damage)}
}
```

Readers take `core.Ref(Events)` (or `Events` by value) and find in `items` what came since they
last ran: each event reaches each function once, in `fixed`, `frame` or `late`, with any number of
ticks in a frame. In the stage of the owner a reader runs after it; one that runs before it gets
the event in its next run. Engine events:
`phys.Physics_Events` (contacts, overlaps, sleep), `anim.Animation_Events`,
`destruct.Destruct_Events`, `save.Save_Results` and `scene.Scene_Results`.

## Objects with a state

Keep the phase an object is in and the tick it entered it; derive the rest from `core.Time`
([waiting.md](waiting.md)). What a row starts with is set in its first tick, when `core.added`
says the row is new; no field says it was set up:

```odin
@(component)
Bob :: struct {height,speed:f32, base_y:f32 `mirai:"transient"`}

@(step="fixed")
game_bobs :: proc(bobs:^core.Table(Bob),transforms:^core.Table(core.Transform),time:core.Time) {
    for row in 0..<core.count(bobs) {
        local:=core.free(transforms,core.entity_at(bobs,row))
        if local==nil {continue}
        // New: asked before the row is written.
        if core.added(bobs,row) {core.edit_at(bobs,row).base_y=local.position.y}
        bob:=core.at(bobs,row)
        local.position.y=bob.base_y+math.sin(f32(time.seconds)*bob.speed)*bob.height
    }
}
```

`core.added(table,row)` is true from the add that gave the row its value until the row is written
(`edit`, `edit_at`, a `set` that changes it); it is for the library that writes the table.

## Pitfalls that fail silently

- Two libraries writing the same non-`shared` table or storage is a generator error: the second
  pushes a request.
- A function that receives the storage of events to write (`^Events`) sees the whole log, not
  what is new to it: read with `core.Ref(Events)`.
- Waiting is a deadline tick, never a countdown: [waiting.md](waiting.md).
- A request names a `core.Entity`: if it died before the owner ran, the request does nothing.
  Report it with `core.report(problems,e,"game.cause","what failed and how to fix it")`.
- A queue nobody takes grows: the owner's step must run on every end that pushes (not `server`).
