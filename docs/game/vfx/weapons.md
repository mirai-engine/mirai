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

Start it at the swing and stop it after: each time it starts again it begins another ribbon, so
two swings never join, and neither do the points before and after a teleport (`core.Jump`). Each
birth of a [channel](channels.md) starts a ribbon of its own.

The swing of a clip starts and stops it as data: `vfx_animation.Particle_Animation_Span` on the
emitter entity names a span of the clips of its animated parent (`span`), or two markers (`span`
and `end_marker`), and optionally the action they count for. The trail runs while the span lasts
and stops when the clip ends or is interrupted. A one-shot sound or burst at a marker is a
[cue](../audio/cues.md).

## Slash arcs and charge cones

A `Mesh` effect whose `facing` is `Emitter` keeps the turn its emitter had when each particle was
born, rolled about its front by `rotation`; `scale` stretches its mesh along each of its axes,
constant for the whole effect. A Mesh particle blends as the `alpha_mode` of its material says:
`Opaque` and `Mask` are lit surfaces (debris), `Blend` covers what is behind by its opacity, and
`Additive` adds its light without darkening anything (glowing arcs, flashes). The `blend` of the
effect is for sprites, ribbons and beams only.

A Vfx program places each mesh on its own: in `render`, `visual.orientation` (a quaternion of the
world) takes the place of `facing` and `visual.scale` stretches that particle over the `scale` of
the effect. The Surface program of a blended material fades or erodes an arc with
`ctx.particle_life` (0 to 1) and `ctx.particle_color`, masks it with the `ctx.vertex_color` of its
mesh and rims it with `ctx.view_direction`. A program with `//! births` needs `max_particles`.

## Muzzle flash light

`light` gives a layer one point light at its emitter, moved by `light.offset` (metres, in the
axes of the emitter), while its particles live: `color_over_life` dims and tints it (its alpha
scales `light.intensity`) at the mean age of the particles alive; `light.range` stays. A short
burst with a fading alpha is a flash that lights the walls around the barrel and goes out with
the sparks. The light stays at the emitter: it does not fly with the
particles.

```odin
fx.light = {color = {1, 0.7, 0.4}, intensity = 800, range = 6, radius = 0.05, offset = {0, 0, 0.1}}
```

At most `Particle_Settings.max_lights` (32) layers shine at once, those nearest the player;
past that, the problem `vfx.lights_over` names how many were dropped.

## Local space

With `local_space`, particles move with the emitter: a flame on a swung torch stays on it. They
take nothing more from `inherit_velocity` than what goes faster than the emitter, and their meshes
are drawn coming from where the emitter was the frame before, without smearing.

## Darkening

`blend` `Multiply` multiplies what is behind a sprite by its color (scorch puffs, shadows of
smoke). It adds no light and is not lit.
