---
name: vfx
description: Particles and visual effects from game code with the `vfx` plugin - emitters,
  one-shot effects, bursts, impacts, sparks, dust, smoke, per-instance values, layers, channels,
  distance culling.
---

# Game VFX

An effect is a `.particle` asset shown by a `vfx.Particle_Emitter`. Game code spawns emitters and
sends requests. Imports: `plugins:vfx/runtime` as `vfx`,
`plugins:vfx/runtime/effect`, `mirai:engine/scene`, `mirai:core`.

## Map

- An effect once, at a point: [one-shot](#one-shot-effect).
- Start, stop or burst an existing emitter: [requests](#control-an-emitter).
- Other color or rate for one entity: [values](#values-of-one-instance).
- Many hits per tick, each with its place and velocity: [channels](vfx/channels.md); at a marker
  or an ability, with a sound: [cues](audio/cues.md). Far apart: [culling](vfx/culling.md).
- A trail behind each spark: [trails](#trails); a sword trail or slash: [weapons](vfx/weapons.md).
- Write or tune an effect: [authoring](#author-an-effect).

## One-shot effect

The prefab is one entity with `Particle_Emitter{particle=id, active=true, destroy_when_done=true}`
and `loop` off; it deletes itself once its particles are dead. Spawn it as in [spawn and
forget](core/prefabs.md#spawn-and-forget), with `transient=true`, which keeps it out of saves.

## Control an emitter

`vfx.Particle_Requests` is applied in the next fixed step, in order; a rollback draws none twice:
```odin
// inside a fixed function, with requests:^vfx.Particle_Requests
vfx.start(requests, e); vfx.stop(requests, e) // set or clear active; live particles finish
vfx.burst(requests, e, 30) // every layer; layer=1: the second alone
```

`start` and `stop` change `active`. Also `restart`, `pause`, `resume`. `vfx.status(clocks,
emitter, e)` is of the whole effect (`Playing` while a layer plays, `Done` once all are); with
`layer=N`, of that layer.

## Values of one instance

```odin
err:=vfx.request_value(requests, e, "parameters.heat", f32(0.8)) // layers whose program has it
if err!=.None {core.report(problems, e, "game.vfx", "%s", vfx.error_message(err))}
vfx.request_value(requests, e, "layers.1.rate", f32(40))     // the second layer alone
```

A name is a field path (`rate`, `bursts.0.count`) or `parameters.` and a parameter of the
program, checked when asked; without `layers.N.` a field is of the primary layer and a parameter
of every layer whose program declares it (none: `particle.instance.inspect` says why). Also
`request_value_remove`, `request_values_clear`. Assets belong to the effect. A value changed every
tick allocates nothing.

## Author an effect

Editor: the `.particle` document. Agent: `particle.set`, `particle.inspect`. Debris: `Mesh` with
up to four `meshes` and `mesh_weights`, `facing` `Velocity` for shards that point where they fly.
Content tool, over the defaults ([assets](assets.md)):

```odin
fx:=effect.PARTICLE_DEFAULTS
fx.duration, fx.rate, fx.bursts[0] = .05, 0, {count=50, cycles=1}
err:=effect.particle_save("assets/particles/dust.particle", &types, {id=id, info=fx})
```

## Trails

A trail behind each spark: a `Ribbon` effect (`Point`, speed 0) named by `sub_particle` of the
first with `trigger` `Trail`, `sub_count` 1; a program may set `particle.ribbon` in `initialize`.

## Pitfalls

- Nothing draws without `"vfx"` in `plugins` of `project.mirai`. Bad requests report
  `vfx.request`, a full pool `vfx.capacity` (`engine.diagnostics`).
- `destroy_when_done` never fires with `loop` on, unless the emitter is stopped.
- An emitter that does not show: `particle.instance.inspect` gives `why`; NaN or Inf in its
  particles report `vfx.nan`, naming the fields of its program that hold them.
