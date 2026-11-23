# Weapon trails, slashes and flashes

Effects that follow a blade or a character: a trail behind a sword, a slash arc, a charge cone, a
muzzle flash. The emitter is a child entity of the weapon or the character, so it moves with it.

## Sword trail

A `Ribbon` effect (`Point`, speed 0, `rate` or `rate_over_distance`) on an entity at the blade:

- `ribbon_axis` `Emitter_Up`: the ribbon is wide along the +Y of the emitter where each point was
  born, so it lies in the plane of the blade. `Camera` (the default) turns it toward the camera.
- `ribbon_tile` (m): the texture of its material repeats every this many metres from the head of
  the ribbon, so it keeps its look at any speed. 0 spans it once from head to tail.
- `scale.x` widens it.

```odin
fx:=effect.PARTICLE_DEFAULTS
fx.shape, fx.speed, fx.rate, fx.lifetime = .Point, {0, 0}, 90, {0.25, 0.25}
fx.render, fx.ribbon_axis, fx.ribbon_tile, fx.blend = .Ribbon, .Emitter_Up, 0.5, .Additive
err:=effect.particle_save("assets/particles/sword_trail.particle", &types, {id=id, info=fx})
```

Start it at the swing and stop it after (`vfx.start`, `vfx.stop`): each time it starts again it
begins another ribbon, so two swings never join, and neither do the points before and after a
teleport (`core.Jump`). Each birth of a [channel](channels.md) starts a ribbon of its own.

## Slash arcs and charge cones

A `Mesh` effect whose `facing` is `Emitter` keeps the turn its emitter had when each particle was
born, rolled about its front by `rotation`; `scale` stretches its mesh along each of its axes,
constant for the whole effect. A Mesh particle blends as the `alpha_mode` of its material says:
`Opaque` and `Mask` are lit surfaces (debris), `Blend` covers what is behind by its opacity, and
`Additive` adds its light without darkening anything (glowing arcs, flashes). The `blend` of the
effect is for sprites, ribbons and beams only.

## Local space

With `local_space`, particles move with the emitter: a flame on a swung torch stays on it. They
take nothing more from `inherit_velocity` than what goes faster than the emitter, and their meshes
are drawn coming from where the emitter was the frame before, without smearing.

## Darkening

`blend` `Multiply` multiplies what is behind a sprite by its color (scorch puffs, shadows of
smoke). It adds no light and is not lit.
