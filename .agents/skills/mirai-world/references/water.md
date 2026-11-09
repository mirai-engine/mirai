# Water: the `water` plugin

`plugins/water` (`Runtime`, `Shaders`; depends on `physics`, `fog` and `vfx`) draws each
`Fluid_Volume` of [physics](../../mirai-physics/references/physics.md#fluids) as water, from the
same fluids in which bodies float (`phys.fluids_in`): one datum, one place. Without volumes it
adds no instances or passes. `water` does not depend on `fluids` (an external plugin,
<https://github.com/tomaszbk/mirai-fluids>): its `water_fluids` bridge emits the wakes of floating
bodies, draws the foam of the fluid grid over the water bodies (`water.bodies_bind`) and bends the
surface with the grid waves through `Water_Settings.surface_program`, the project setting that
names the Surface program of a water without its own material (empty or unknown:
`Water_Surface`).

## Appearance

- `Water` on the `Fluid_Volume` entity changes its appearance; without it, `WATER_DEFAULT`.
  `material` is a `.mat` like any other; without it, a glass derived with the water's IOR, the
  `Water_Surface` program and the absorption and scattering of `Water`.
- **Surface.** A [glass](../../mirai-rendering/references/materials.md#glass) solid: that of a
  plane is a sheet open underneath, a grid generated once (`surface_build`) that follows the
  camera in steps of `SURFACE_STEP`, with cells that double outward by rings and whose edges
  between levels share vertices; that of a box, its cube. They are added as frame instances
  (`instance_add`) before `render_sync`.
- **Waves.** Those of a plane are those of physics ([`Fluid_Waves`][waves]): `water_render` uploads
  with each body its `wave_terms`, measured from the origin of each pass at the time the frame
  shows (that of physics between its last two steps, like the poses; without Play, the
  application clock), and `water_waves.slang`, twin of `wave_point` and `wave_surface`, evaluates
  them. A plane with waves, or that a dry box crosses, is drawn through a deformable copy of its
  grid (`Sheet`) that the `water_sheet` step of `Geometry` writes each frame (without waves, only
  when the grid or the boxes move): each vertex goes where the water that rests on it is, and a
  wave fades where the ring's cells measure more than a quarter of its length. Raster, rays,
  shadows and glass see the same surface in which bodies float.
- **`Water_Surface`** (`shaders/water_surface.slang`): bends the normal with the small-wave trains
  of `water.slang`, the same ones that the caustics follow.
- **Medium.** The glass solid absorbs and scatters on every path through the water, from above, from
  below and in what it traces ([glass](../../mirai-rendering/references/materials.md#glass)). Each
  fluid also hands `fog` a medium of its box (a plane, a box around the camera under its troughs)
  that only gives the sun shafts (`shafts`), that is cut by the dry boxes of higher priority and
  that turns off the sunlight on the way down according to the water's absorption ([media from other
  plugins](../../mirai-plugins/references/render-plugins.md#media-from-other-plugins)).
- **Caustics.** `water_caustics.comp` builds each frame, in the `Lit` stage, the pattern that the
  small waves give to sunlight at a depth: the area to which each part of the surface sends the
  light, a repetition of the waves per texture. `water_light.comp` adds to the direct light
  (`Direct`) of what is under a surface the part of the pattern where its light crossed the
  surface, before the fog: over waves, the depth and the crossing are those of the surface with
  waves. It reads the pattern twice, turned apart and chosen in patches narrower than a repeat,
  so the repeat of the waves does not show as a tile over a wide shallow floor.
- **Over the glass** (`water_over`, `Blend` stage, in front of the glass): the line of the surface
  over the lens where the near plane crosses it, over the waves. It only runs if the view's near
  plane can cross a surface.
- The surface's IOR is that of its material (without `material`, the water's): the sunlight under
  the water and the caustics follow it, and they take that of the first fluid with caustics.
- The frame's bodies (`Gpu_Body`) are built in the world and each pass uploads them relative to
  its `Pass.origin` (`bodies_relative`). The small waves and the caustics pattern are read at the
  world place by adding from the origin only what is not a whole repetition of the waves
  (`water_detail_place`), which far from the center keeps precision.
- **Dry boxes.** They cut the shafts and the sun that turns off with the priority rules of
  physics. The air floor of a dry box inside a fluid is drawn as a surface of that fluid. A dry
  box of higher priority that crosses a plane's surface cuts it in `water_sheet`: what stays
  inside goes down to its floor, which is the surface, and what stays within a ring and a half of
  a wall sticks to it. With the camera inside, the box is drawn as an air solid (IOR 1, no
  medium), which the glass takes as the camera's solid instead of the water: inside there is no
  water.

## What physics shows

`water_bodies` (`fixed`, after `physics_step`) reads what each awake body has under the surface at
the end of the step (`phys.fluid_bodies`) and returns nothing to the simulation nor enters a
rollback. The emitters of each channel draw their births with their effect:

- a body that enters the water faster than `SPLASH_SPEED` pushes to the `CHANNEL_SPLASHES` channel
  a splash with droplets according to its size and speed, one every `SPLASH_PAUSE` ticks;
- a body with more than `BUBBLE_UNDER` below the surface that moves faster than `BUBBLE_SPEED` (a
  swimmer, a vehicle, a sinking box) pushes to `CHANNEL_BUBBLES` bubbles behind it and below the
  surface, according to its size and speed, once every `BUBBLE_PAUSE` ticks;
- with the view under the surface, `CHANNEL_MOTES` receives every `MOTE_PAUSE` ticks particles
  suspended in the view, which the effect spreads around and leaves still where they are born.

**Wetness.** `Water_Wet` stores per body, with fixed capacity, how wet it is: what it has under
the surface while it is in the water and, on leaving, what it had falling until it dries in
`WET_SECONDS`. A body that physics no longer lists is out of the water or asleep; one asleep where
the water found it does not dry. `water_wet_render` (`render`, after `render_sync`) gives that
value with [`instance_wet_set`](../../mirai-rendering/references/views.md#extension-stages) to
the instances of `Render_Sync.instances` of the body and of what hangs from it, which the
materials apply ([wetness](../../mirai-rendering/references/materials.md#evaluation)). It rebuilds
the list of those instances when the renderer's, the hierarchy or which bodies are wet change; in
between it only sends those that moved one step of `WET_LEVELS`.

## Sound

`water_hearing` (`late`, before `audio_reverb` and `audio_buses`) writes the
[`Audio_Medium`](../../mirai-gameplay/references/libraries.md#audio) from the fluid where the
listener is (`audio.listener_position`, `phys.fluid_at`): under the surface of a fluid, outside a
dry box, the master loses the highs (`UNDER_LOWPASS`) and the water reverb sounds
(`UNDER_REVERB`); above, the air.

## Scene

A scene with water has the `Fluid_Volume` entity (with `Water` if its appearance changes and
`Fluid_Waves` if it has waves) and, for splashes, bubbles and suspended particles, an emitter with
a `Particle_Channel` `splashes`, `bubbles` or `motes`. The `raft` scene of the demo builds them
from `tools/demo_content`.

## Limits

- A box is drawn as a cube of water: its sides are seen from outside, and it has no waves.
- In the corner of a dry box that crosses a plane a triangle of water of at most one ring cell can
  remain, inclined between the two walls.
- Far from the camera, the waves that the ring does not show fade from the drawing and not from
  physics: there what floats can depart from the drawn surface.
- The dark line of the lens is only seen with the near plane within `LENS_WIDTH` of the surface;
  which part of the lens is under the water is decided by the glass per pixel.
- From inside a dry box, what is seen outside it does not have the water medium (one solid per
  view).

## Verification

- `mirai test plugins/water/runtime`: the grid faces up, covers its square and shares each edge
  between levels; one splash per body that enters fast and none from a still one; the bodies carry
  to the shaders the waves measured from the pass origin; bubbles from one that moves under water
  and none from a still one; wetness rises in the water and dries in `WET_SECONDS`; the medium
  under the surface (`interaction_test.odin`).
- The waves in physics: `mirai test plugins/physics/runtime/sim` (`fluid_waves_test.odin`) and
  `mirai test plugins/physics/runtime the_waves_of_a_plane_are_its_own_and_the_sea_of_the_wind`.
- `mirai test render how_wet_an_instance_is_stays_with_its_identity_and_changes_no_light` and
  `mirai test engine/audio the_medium_around_the_listener_dulls_the_master_and_mixes_its_reverb`.
- In the demo editor, `raft` scene, with validation: `capture` from above, at water level,
  from below and crossing the surface, and inside and outside the dry box that crosses the sea; in
  Play, a falling box splashes, what floats follows the waves, the swimmer bubbles and sees
  suspended particles under the water, and what leaves the water looks dark and shiny for a few
  seconds. `mirai render check demo --views` of the `raft_*` views.

[waves]: ../../mirai-physics/references/physics.md#fluids
