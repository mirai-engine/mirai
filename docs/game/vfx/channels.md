# Births by channel: many per tick, each with its place and velocity

Use it when a game gives an effect many births per tick, each with its own place and velocity
(bullet impacts, footsteps, sparks).

An entity with a `Particle_Channel` whose `name` is `"impacts"` next to its `Particle_Emitter`
starts particles of its effect at every birth pushed to that channel, besides the emitter's own.
A channel is only its name: the same text in the code that pushes and in the emitter.

```odin
import vfx "plugins:vfx/runtime"

@(step="fixed")
impacts :: proc(hits:core.Read(Hit), channels:^vfx.Particle_Channels) {
    for i in 0..<core.count(hits) {
        hit:=core.at(hits, i)
        vfx.channel_emit(channels, "impacts", vfx.Channel_Birth{
            position=hit.point, velocity=hit.normal*6, count=12,
        })
    }
}
```

- `Channel_Birth`: `position`, `velocity` (added to the effect's), `color` and `size` (multiply
  the effect's; zero means white and one), `count` (zero is one), `values` for the effect's
  program.
- The emitter that listens is in the scene (a prefab or the editor); `Particle_Channel` has
  `silent` for an effect whose program reads the births itself instead of starting particles.

## Pitfalls

- A birth to a channel that no emitter listens to is dropped without a message.
- A name spelled differently in the emitter and in the code is another channel.
- A channel keeps only the births of its last ticks; thousands in one tick lose the oldest.
- Push in `fixed`: a rollback repeats the births without drawing them twice.
