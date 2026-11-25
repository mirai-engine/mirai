---
name: cues
description: Play a sound and a particle birth at an animation marker, or at the start, a window
  or a hit of an ability, as data - footsteps, reload clicks, landing dust, swing whooshes, hit
  sparks - with no event loop in game code.
---

# Sound and particle cues

A cue (`audio.Cue`) is what plays at one moment where something is: `sound` (a `.sound` or a
`.sound_set`), `channel` (a birth channel that a `vfx.Particle_Channel` emitter listens to:
[channels](../vfx/channels.md)) and `align_up` (the birth's normal is the up of where it plays).
Either half may be empty. The engine plays it; game code writes no loop over events for it.

## At an animation marker

The cues of a `.character` give a marker name of its clips a cue, one row per marker, up to 256
rows. Each time a clip of an entity whose `Animation.asset` is that set crosses the marker, its cue
plays at the entity, or at a bone or a socket of its skeleton (`anchor` `Bone` or `Socket`, named
in `at`). `animation.cue.set` replaces the rows; `animation.asset.inspect` lists them:

```sh
mirai rpc animation.cue.set '{"path":"characters/zombie.character","cues":[
  {"marker":"step_l","anchor":"Bone","at":"foot_l",
   "cue":{"sound":"<id of steps.sound_set>","channel":"dust","align_up":true}},
  {"marker":"swing","cue":{"sound":"<id of whoosh.sound>"}}]}'
```

A prop that plays a plain `.anim` gets cues from a `.character` of its clips.

## At an ability

- `Ability_Window.on_begin` plays at the user when the window opens. A window from 0 plays at the
  start of the ability.
- `Ability_Effect.on_hit` plays at the target when a hitbox hits with that effect, so each of
  `target_effects` can sound and spark its own way (flesh, metal).

## What the engine keeps

- A cue's sound plays once per tick of the entity that plays it: a tick a rollback runs again
  neither repeats it nor misses one only the corrected tick asks, and two entities side by side
  both sound.
- Its birth goes to `core.Births`; the particles of a tick run again are not drawn twice.
- Playing cues allocates nothing in a tick.

## When it is not a cue

- An emitter that runs while a span of a clip lasts (a sword trail):
  `vfx_animation.Particle_Animation_Span` on the emitter, [weapons](../vfx/weapons.md).
- A sound that loops or follows an entity: an `Audio_Source` ([audio](../audio.md)).
- Anything else (a camera shake, a decal): read `Animation_Events` or `Ability_Events` in a fixed
  step.
