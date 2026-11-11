---
name: vfx
description: Particles and visual effects from game code with the `vfx` plugin - emitters,
  one-shot effects, bursts, impacts, sparks, dust, smoke, per-instance values, channels, reports.
---

# Game VFX

An effect is a `.particle` asset shown by a `vfx.Particle_Emitter`. Game code spawns emitters and
sends requests. Imports: `plugins:vfx/runtime` as `vfx`,
`plugins:vfx/runtime/effect`, `mirai:engine/scene`, `mirai:core`.

## Map

- An effect once, at a point: [one-shot](#one-shot-effect).
- Start, stop or burst an existing emitter: [requests](#control-an-emitter).
- Other color or rate for one entity: [values](#values-of-one-instance).
- Many hits per tick, each with its place and velocity: [channels](vfx/channels.md).
- A sound or decal where a particle dies or hits: [reports](vfx/reports.md).
- A trail behind each spark or comet: [trails](#trails).
- Write or tune an effect: [authoring](#author-an-effect).

## One-shot effect

The prefab is one entity with `Particle_Emitter{particle=id, active=true, destroy_when_done=true}`
and `loop` off; it deletes itself once its particles are dead. Spawn it as in
[spawn and forget](core/prefabs.md#spawn-and-forget), with `transient=true`, which keeps it out of
saves.

## Control an emitter

`vfx.Particle_Requests` is applied in the next fixed step, in order.
```odin
// inside a fixed function, with requests:^vfx.Particle_Requests
vfx.start(requests, e); vfx.stop(requests, e) // set or clear active; live particles finish
vfx.burst(requests, e, 30)
```

`start` and `stop` change the emitter's `active`, as writing the field does. Also `restart`,
`pause` and `resume`. `vfx.status(clocks, emitter, e)` gives a `Particle_Status` with its `state`
(`Playing`, `Done`).

## Values of one instance

```odin
err:=vfx.request_value(requests, e, "colors.1", [4]f32{1, 0.2, 0, 1})
if err!=.None {core.report(problems, e, "game.vfx", "%s", vfx.error_message(err))}
vfx.request_value(requests, e, "parameters.heat", f32(0.8)) // a parameter of its program
```

A name is a field path of the effect (`rate`, `bursts.0.count`) or `parameters.` and a parameter
of its program, checked when asked; with a parameter its program does not declare, the emitter
runs without the program and `particle.instance.inspect` says why. Also `request_value_remove`
and `request_values_clear`. Assets belong to the effect.

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

- Nothing draws unless `"vfx"` is in `plugins` of `project.mirai`.
- A request for an entity without `Particle_Emitter` only reports `vfx.request` in
  `engine.diagnostics`. An emitter that finds no room in the particle pool reports
  `vfx.capacity`.
- `destroy_when_done` never fires with `loop` on, unless the emitter is stopped.
- Requests go in `fixed`, so a rollback does not draw them twice.
