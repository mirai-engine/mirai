# Births by channel: many per tick, each with its place and velocity

Use it when a game gives an effect many births per tick, each with its own place and velocity
(bullet impacts, footsteps, sparks).

An entity with a `Particle_Channel` whose `name` is `"impacts"` next to its `Particle_Emitter`
starts particles of its effect at every birth pushed to that channel, besides the emitter's own.
A channel is only its name: the same text in the code that pushes and in the emitter.

```odin
@(step="fixed")
impacts :: proc(hits:^core.Table(Hit,.Read), births:^core.Births) {
    for i in 0..<core.count(hits) {
        hit:=core.at(hits, i)
        core.birth(births, core.Birth{
            channel=core.birth_channel("impacts"), position=hit.point, velocity=hit.normal*6,
            count=12,
        })
    }
}
```

- `core.Birth`: `channel`, `by` (the entity that causes it, if any), `position`, `velocity`
  (added to the effect's), `color` and `size`
  (multiply the effect's; zero means white and one), `count` (zero is one), `values` for the
  effect's program. `core.Births` is a log of `core`: code that pushes births does not import `vfx`.
- The emitter that listens is in the scene (a prefab or the editor); `Particle_Channel` has
  `silent` for an effect whose program reads the births itself instead of starting particles.

## Pitfalls

- A birth to a channel that no emitter listens to is dropped without a message.
- A name spelled differently in the emitter and in the code is another channel.
- `core.Births` holds `core.BIRTHS_CAPACITY` births of a frame and the one before, and a channel
  1024 the GPU has not started; what does not fit is lost and reported (`vfx.births`).
- Push in `fixed`: a rollback repeats the births without drawing them twice, draws one only the
  corrected tick pushes, and does not draw one it lacks if the GPU had not started it. It tells
  the births of a tick apart by `by`: give the entity that causes a birth (the body that splashes,
  the character that steps), so a correction that moves it far is still that birth and two
  entities side by side stay two. A birth with no `by` (an effect of the world) is told apart by
  its place, within a metre.
