# Waiting: cooldowns, countdowns and requests for later

A wait is a named field of your component that holds ticks: `core.Cooldown` for what is ready
again after a while, `core.Countdown` for what runs from a start to an end. Start one with the
`core.Time` of the fixed step and ask it what it is at that tick. It lasts the same seconds at any
tick rate, the row is written when it starts and when it is stopped, never while it runs, and a
world copy, a save and a rollback keep it as they keep the rest of the row. This is the one way to
wait: there is no `await`, no coroutine, no timer object and no numbered slot.

```odin
@(component)
Gun :: struct {
    reload:f32,         // seconds between shots
    shot:core.Cooldown, // ready by its zero value
}

@(component)
Mine :: struct {
    fuse_seconds:f32,
    fuse:core.Countdown, // not running by its zero value
}

@(step="fixed",server)
game_fire :: proc(guns:^core.Table(Gun),actions:inp.Input_Of(Action),time:core.Time) {
    for row in 0..<core.count(guns) {
        gun:=core.at(guns,row)
        e:=core.entity_at(guns,row)
        if !core.cooldown_ready(gun.shot,time) || !inp.pressed(actions,e,.Fire) {continue}
        core.cooldown_start(&core.edit_at(guns,row).shot,time,gun.reload)
    }
}

@(step="fixed",server)
game_mines :: proc(mines:^core.Table(Mine,.Read),commands:core.Commands,time:core.Time) {
    for row in 0..<core.count(mines) {
        if !core.countdown_due(core.at(mines,row).fuse,time) {continue}
        core.destroy(commands,core.entity_at(mines,row))
    }
}
```

- **Cooldown:** `cooldown_start(&c,time,seconds)`, `cooldown_ready(c,time)`, and
  `cooldown_remaining(c,time)` for a HUD.
- **Countdown:** `countdown_start(&c,time,seconds)` and `countdown_stop(&c)`;
  `countdown_running` until its end, `countdown_due` on the one tick it ends (seen once by a step
  that runs every tick, with no write), `countdown_ended` from then on until it is started again
  or stopped; `countdown_elapsed`, `countdown_remaining` and `countdown_progress` (0 to 1) for a
  bar or a blend.
- **Several waits:** one named field each (`shot`, `grenade`, `dash`), never an array of slots.
- **A raw tick:** `core.deadline(time,seconds)` gives the tick a wait ends at and
  `core.due(time,at)` whether it came (0 has, `core.NEVER` never does); `core.elapsed`,
  `core.seconds_of` and `core.ticks_of` convert. The typed waits are made of them.
- **A request for later:** `core.later(&requests.queue,time,2,Hit{target,5})` carries its due tick;
  the owner takes with `core.take_due(&requests.queue,time)` what was pushed and what is due. A
  library may push to its own queue: a spawner that sends a wave pushes the entity of the wave
  for the tick of its next enemy, and takes it then.
- **Bullet time:** an entity with `core.Own_Pace` waits on `core.own_time(time,clock,paces,e)`
  instead of `time`.
- **Steps in a row** (open, hold, close): an enum of the step it is in and a `Countdown` started
  as it entered it; each tick the function looks at `countdown_ended` and moves on.
- **An agent of `behavior`:** `ai.after(a,seconds)` inside its action, `ai.mind_ready` between
  actions ([ai](../ai.md)). An ability's cooldown is the `cooldown` of its row
  (plugin `abilities`).

## Pitfalls that fail silently

- Counting ticks (`ticks-=1`, `time.tick%60`) lasts half as long at 120 Hz: give seconds.
- `left-=time.dt` writes the row every tick, so it is copied and sent every tick: keep a
  `Countdown`.
- Asking through `core.edit` (`core.countdown_due(core.edit(t,e).fuse,time)`) stamps the row
  every tick: read with `core.at` or `core.get`, edit only to start or stop.
- An owner that takes with `core.take` refuses what was pushed with `core.later`.
- A queue is not saved: a wait a save must keep is a field of a component, not `core.later`.
- While the clock does not advance (`time.dt` 0) a wait ends on the next tick.
