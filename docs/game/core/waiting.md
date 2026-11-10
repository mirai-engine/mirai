# Waiting: deadlines and cooldowns

A wait is the tick it ends at, kept in your component. `core.deadline(time,seconds)` gives that
tick and `core.due(time,at)` says whether it came; a deadline nobody set (0) has, and `core.NEVER`
never does. It lasts the same seconds at any tick rate, and a rollback and a save keep it. This is
the one way to wait: there is no `await`, no coroutine and no timer object.

```odin
@(component)
Mine :: struct {
    fuse:f32,     // seconds from lit to bang
    bang_at:u64,  // the tick it goes off at; 0: not lit
}

mine_light :: proc(mines:^core.Table(Mine),e:core.Entity,time:core.Time) {
    if mine:=core.get(mines,e);mine!=nil {mine.bang_at=core.deadline(time,mine.fuse)}
}

@(step="fixed",server)
game_mines :: proc(mines:core.Read(Mine),commands:core.Commands,time:core.Time) {
    for row in 0..<core.count(mines) {
        mine:=core.at(mines,row)
        if mine.bang_at==0 || !core.due(time,mine.bang_at) {continue}
        core.destroy(commands,core.entity_at(mines,row))
    }
}
```

- **Cooldown:** `if core.due(time,gun.ready_at) {gun.ready_at=core.deadline(time,0.4)}`.
- **While it lasts:** `lit:=!core.due(time,lamp.lit_until)`; nothing is written when it ends.
- **How long ago:** `core.elapsed(time,door.opened_at)` gives the seconds since a tick, for a
  blend; `core.seconds_of` and `core.ticks_of` convert between ticks and seconds.
- **Every so often:** `if core.due(time,next) {next=core.deadline(time,2.5)}`.
- **Bullet time:** an entity with `core.Own_Pace` waits on `core.own_time(time,clock,paces,e)`
  instead of `time`.
- **Steps in a row** (open, hold, close): an enum of the step it is in and the tick it entered it;
  each tick the function looks at `core.due` and moves on.
- **An agent of `behavior`:** `ai.after(a,seconds)` inside its action, `ai.mind_ready` between
  actions ([ai](../ai.md)).

## Pitfalls that fail silently

- Counting ticks (`ticks-=1`, `time.tick%60`) lasts half as long at 120 Hz: give seconds to
  `core.deadline` or `core.ticks_of`.
- `left-=time.dt` writes the row every tick, so it is copied and sent every tick: keep a deadline.
- A request is taken in the tick it was pushed in: "do this in 2 s" is a deadline in a component,
  and the request is pushed when it is due.
- A deadline of 0 is due: test `at!=0` when 0 means "not started".
- While the clock does not advance (`time.dt` 0) a wait ends on the next tick.
