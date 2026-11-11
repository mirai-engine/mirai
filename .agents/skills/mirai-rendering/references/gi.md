# Global illumination and tracing

## Lighting techniques and optimization

- Light transport is common to all providers: `shaders/include/trace.slang` defines `trace_ray`
  and each pass uses it without knowing whether the software BVH (compute) or the hardware ray
  queries answer. Both return instance, primitive, distance and barycentrics; the surface
  attributes are rebuilt from the same geometry pool.
- Diffuse indirect comes from the [probe volume](#probe-volume), with all the bounces, darkened at
  contact by the [contact occlusion](#contact-occlusion). Nothing in the indirect samples
  directions or lights per frame: what the scene does not change gives the same every frame, and
  there is no boiling for a filter to hide.

Each technique states its status; what is listed as prepared is not implemented.

### BVH and acceleration structures

- **BVH** (implemented, `render/bvh.odin`). Built by the one SAH builder of `std/spatial`
  (`bvh_build`), its nodes uploaded as it lays them out, with a depth that limits the shader
  stack; compute traversal nearest-first, bounded by the nearest hit and with early exit for
  shadow rays. Its triangle test is watertight, as the hardware one: no ray passes between two
  triangles through the edge or corner they share, so each triangle keeps its corners whole.
- **BLAS / TLAS** (implemented). One BLAS per ray cut of each mesh in object space, persistent:
  editing transform, material or visibility does not rebuild it. Cut 0 is level 0; the coarser
  ones are cuts of the DAG that the file stores (`ray_errors`). `ray_cuts_update` chooses the
  one of each instance by its distance to the eye, with hysteresis: one of error `e` serves from
  the distance where `e` falls below the ray-origin bias, below half the sun's penumbra and below
  half the separation of the probe cascade there. Each mesh always has a cut (`ray_cut_always`):
  0, or the coarsest in a mesh with [pages by distance](scene.md#scene-and-instances), which
  comes from the root alone. With hardware RT the BLAS of another cut is built when an instance
  wants it, with positions decoded from its pages if they are not in the pools, and is released
  `RAY_CUT_KEEP` frames after none wants it. An instance traces the cut it wants if it has its
  structure and, for a streamed mesh, all its pages in the pools (a hit reads them); if not, the
  nearest one on the way to the always-cut. The pages of a wanted cut are requested with priority
  0 and those of a traced one do not leave the pools. Batch instances trace the always-cut. A cut
  change marks light only if its error changes by more than half a cell. A primitive is
  `cluster << 7 | triangle`; with hardware RT a table per BLAS gives it from the primitive index.
  A TLAS over the instance boxes is rebuilt per scene revision, in software and as a native
  structure with hardware RT.
  - Blend-only instances are a separate ray class that the other rays do not visit.
  - [Batches](scene.md#instance-batches) that only cast shadow or are only seen have their own
    classes (`RAY_SHADOW_ONLY`, `RAY_UNSHADOWED`), requested by the shadow rays (`RAY_SHADOWS`) and
    those that see surfaces (`RAY_SEEN`). In software, a TLAS reference after the instances is a
    batch, whose instance tree leads to the BLAS of its mesh.
- **Only the structure of the tracer in use.** With hardware RT a mesh has its native BLAS and no
  software BVH (`rays[k].bvh_node_count` 0). When switching to software,
  `renderer_apply_settings` builds the one of each mesh that lacks it (one pose, from its bind
  vertices); when going back to hardware, the missing BLAS. Poses refit only the structure in use.
  - The software TLAS (the tree of the instances) is built and kept only when tracing in software
    (`Scene_State.tlas_off` with hardware RT): it stays stale until a switch to software rebuilds
    it, and only then does it have GPU buffers.
  - A device makes only the pipelines of the tracer in use (`tracer_settle`): the other one's are
    made when settings switch to it, or at start when hardware RT falls back. Hardware RT requires
    the `hw` variant of every stage that traces rays (`tracer_missing`): with it no pass traverses
    the software BVH.
- **Hardware ray tracing** (implemented). Inline ray queries in the `_hw` variants of direct
  light, probes, contact occlusion and reflections; SPIRV-Cross translates them to Metal. The
  self-test protects it, with the fallback to software on Vulkan
  ([RHI](rhi.md#hardware-ray-tracing)).
- **Hybrid rendering** (implemented). G-buffer by rasterization; shadows, bounces and probes by
  tracing in compute.
- **SDF tracing** (prepared). `trace.slang` is the only provider interface: an SDF or surface
  cache provider is added there without changing the passes.

### Other techniques

- **Screen-space tracing** (not implemented). Reflections and contact occlusion trace in the
  world: a march over the depth does not see behind thin geometry and gave fireflies at its
  edges.
- **Light probes** (implemented): the [volume](#probe-volume). There is no radiance cache or
  screen probes.
- **Fixed sampling and NEE** (implemented). Each probe traces the same directions every time and
  contact occlusion a fixed pattern per pixel; at each pixel and at each probe hit, sun and local
  lights with their shadow ray, chosen by a deterministic light tree
  ([local lights](lights.md#local-lights)). There is no ReSTIR or stochastic direct light.
- **Culling and LOD** (implemented). Frustum, normal cone and two-phase occlusion on the GPU, per
  instance and per cluster ([frame graph](frame-graph.md#passes)). The cut of the DAG or of
  the whole levels takes each cluster whose projected error falls within `lod_error_pixels` and
  that of what replaces it does not; rays trace the instance's cut (above), with an origin bias
  that grows with distance.
- Reflections and glass trace up to `gi_max_distance`; beyond that, the probe volume. The budgets
  belong to `render.Settings` ([settings](settings.md#settings)) and the resolution to
  [the scene](settings.md#scene-resolution).

### Temporal and denoising

- **No on-screen history of the indirect.** The volume lives in the world and contact occlusion
  is computed entirely every frame; what is temporal in the image is TAA and the shadow history
  ([history](lights.md#shadows)).
- **Marked changes.** The scene marks where the light changed (`Scene_State.changes`: spheres of
  lights that change, objects that move, change brightness or show a material that changed what
  the light sees; everything on a general change). The probes it reaches are traced at once and
  stay awake `PROBE_AWAKE` while the light travels through the bounces.
- **Blackout.** A change of more than half of the light that reaches the volume is a general
  change that warms the volume over `GI_BLACKOUT_FRAMES`: the later light is seen in the frames
  in which it passes (`render/blackout.odin`).

## Contact occlusion

`shaders/contact.comp.slang` (`pass_contact`, the `Indirect` stage): the probes are far from each
other and do not see the corner of a table or the floor under a wardrobe.

- Each pixel traces short rays of the hemisphere of its normal in the world, which also see what
  is off screen or behind something nearer to the eye; the nearest occludes more, so that the
  edge fades.
- The directions of a pixel rotate through a fixed pixel pattern, not through its point, which
  the jitter moves every frame; a bilateral blur over the surface removes the pattern. Nothing
  changes from one frame to the next if the scene does not change.
- The pixels of a nested view (a portal, a mirror) compute it from where their surface is in the
  world, like those of the view, and the blur does not mix the two sides of the opening: without
  it, what was seen through a portal was lighter in the corners than what was on this side.
- The composition multiplies the volume irradiance by it: the indirect shadow is sharp at contact
  and opens with distance, which is what the volume gives far away.
- **Small things.** An instance smaller than `SMALL_INSTANCE_REACH` is of the ray class
  `RAY_SMALL`: contact occlusion, reflections and direct light see it, and the volume rays
  (`MIRAI_TRACE_NO_SMALL`) do not. What moves at that size does not change the volume light: its
  near shadow is the contact one and what it emits is given by the light it carries inside
  (`light_stands_for`); a small one that glows without a light does not illuminate its
  surroundings. The class follows the box: a movement or a pose that enlarges it takes it out of
  the class.

## Probe volume

`render/ddgi.odin` and `shaders/ddgi_*.comp.slang`, in the manner of Lumen Lite:

- Cascades centered on the focus of the first view, `probe_cascades` of them, each at twice the
  distance of the previous one, with `probe_grid` probes per horizontal axis. The focus is what
  the camera looks at, at `core.View.focus` in front of the eye (the pivot of an orbit); without
  a focus, the eye. The center sits one separation of the first cascade below the focus: an eye
  sees mostly what is below it, and with `probe_grid` 16 (8 probes high) the floor 2.5 m from it
  fell in the next cascade, whose probes see beyond the walls. An orthographic view does not
  change the image when moving away: centered on its eye, 20 m from the pivot, what it sees would
  read the coarse cascades. A world cell keeps its slot while the cascade shifts (toroidal);
  nothing is created in a frame.
- Each probe traces `probe_rays` spherical Fibonacci rays rotated by its cell, the same every
  time. Their hits trace the direct light and take the bounces from the volume: each trace adds
  one.
- A change of its light is followed in full. Between traces it measures how much its light moves
  while the bounces it reads settle (`Probe.frames.w`): a movement within that approaches it
  little by little; only a larger one traces it again.
- **Filter between neighbors.** Each texel also takes what the neighboring probes store in that
  direction, where they see what this one would see: the point the neighbor sees lies in that
  direction and the distance of the probe itself ends there, unless one of the two is open (it
  reaches the distance limit). The neighbors are read from `kept`, the atlas to which
  `ddgi_keep.comp` copies each probe after its trace, never from the tile being written. A probe
  awakened by a change filters the same as a settled one.
- **Priority** (`ddgi_select.comp`, `probe_budget` per frame): first the probes that do not store
  the light of their cell; then those that a change keeps awake, first those nearest to it
  relative to its reach (what a change changes most is near), or their own light; then the one
  that has gone longest without being traced relative to how much pixels use it
  (`ddgi_mark.comp`), fine cascades first. What is left keeps tracing in turns with the scene
  still: since the rays are the same, a settled probe gives what it gave. A sky that changes
  without stopping (a sunset with an atmosphere) is followed in turns, with stains of the
  previous light until it stops.
- **Relocation** within its cell: a probe inside a wall comes out and one stuck to a surface
  moves away. A covered one keeps the light it had; one that never had it gives nothing.
- **Reading** (`probe_cascade_read`): DDGI weights (wrapped cosine, Chebyshev without a floor),
  square-root blend (`probe_light_root` of what is stored), bias toward the normal and toward the
  eye that shrinks near the eye or the ray origin. A probe behind the plane of a surface does not
  illuminate it: it sees the other side of what supports it. Where the probes that see the point
  open gather enough of the trilinear weight, the others weigh as much as they see it, with a
  continuous transition in space; where almost none sees it, the light drops with how much they
  see it (`PROBE_HIDDEN_SHARE`).
- The fine cascade blends with the next one in a band measured from the center of the cascades
  (`volume_center`), which moves little by little, and not from the cascade, which jumps one cell
  at a time: measured from the cascade, the light of a bench changed abruptly when advancing.
  Every view (nested, texture, split screen) measures from that center, not from its eye. Where
  the fine one stores nothing, the next one; beyond, the sky. With a small `probe_grid` the floor
  already reads a cascade whose probes see through thin walls.
- `sample_probes_around` gives the light around several directions of a point (normal, specular
  lobe and coat) with a single choice of probes and weights; `sample_probes` reads one.

## Glass in the indirect

With `colored_shadows` and glass in the scene, the volume rays and the shadow rays of what they
find cross the glass with the [medium filter](materials.md#medium-filter) of each instance
(`Ray_Path.glass`): the sky light enters through a stained-glass window with its color. Without
the option, the rays go through it without a filter.

## Light of each world

`render/world_light.odin`: the probe volume belongs to a world, with its light scale; the renderer
keeps `Renderer_Desc.worlds` (edit and play).

- `scene_world(r, world, fresh)` says that the scene that follows is that of another world, or
  that of the same one replaced by another (`fresh`). The light of the displayed world stays with
  it; a world that returns recovers its own and its `scene_set` marks no changes. Beyond the
  capacity, the one displayed longest ago loses its own. `render_sync` calls it when the
  `World_Id` changes or when it rebuilds the scene in a frame whose view is cut.
- A world not shown that takes another scene (a document opened right after Play) drops what was
  kept of it with `world_light_forget`: when it returns it starts without light and warms up.
- Each view starts another history and takes its exposure at once
  ([exposure](display.md#exposure)); the next frame keeps the `delta_time` of the previous one.
- **Warm-up.** The frame that shows a world without light (and the one that follows
  `renderer_reset_history`) updates the volume `GI_WARM_UPDATES` times, like Lumen's
  `ForceFullUpdate`, each with up to `PROBE_WARM_BUDGET` probes and one more bounce: the light of
  its first frame ends up close to the settled one. A blackout spreads it over a few frames, so as
  not to stall the game.
- **New scale.** A change of light scale carries the histories and the irradiance atlases to it in
  the next frame (`history_scale.comp`); nothing starts over. A light thousands of times stronger
  than the others, even if it reaches nothing, leaves that of the room intact: the atlases and
  the probe rays store the light in fifth root (`probe_light_encode`, like RTXGI), far from the
  denormals of half floats, and the light that is not worth its shadow ray is measured exposed
  like the view (`light_cutoff`), not in render units.
- **Shader reload.** One that changes the scene image is a discontinuity: the displayed world
  warms up again and the stored ones start without light when they return (`world_light_stale`).
  One that changes only the previews touches neither histories nor light.

## Indirect reference

What the tests compare the volume and the contact occlusion with: not in the renderer games run,
but a custom pass of the tests (`render/reference_test.odin`, stage
`render/testdata/gi_reference.comp.slang` in `TEST_GENERATION`) that writes `Gi` in place of the
`Indirect` stage ([given light](views.md#render-pipelines)):

- Each pixel traces `GI_REFERENCE_PATHS` paths per frame by the cosine. At each surface it adds
  its emission (unless a light represents it) and the light of the sun and of each local light by
  a ray to a point of each (`reference_lighting`, the same as the reference of the lights), and
  continues;
  Russian roulette cuts from the third bounce, up to `GI_REFERENCE_BOUNCES`. A ray with no hit
  sees the sky.
- The side of the surface the ray arrived at is that of its triangle, not that of the
  interpolated normal.
- `Gi` (`Targets.gi_given`) stores the mean and the frames it gathers; it starts over when the
  view loses its history, the camera or the settings change, or the test says so (another
  scene). Composite and the debug views take a `Gi` a custom pass wrote as the diffuse indirect
  light instead of the volume's.
- White furnace test: `gi_reference_gives_the_light_of_a_white_furnace`, with each tracer.
- Scenes and metrics that use it: [measuring GI](verification.md#measuring-gi).

## Sky and sun

`sky_radiance(dir, spread)` (`shaders/include/scene.slang`) is the sky light from a direction,
for what is seen and for every ray that finds nothing.

- It comes from the enabled [`Sky`](../../mirai-gameplay/references/libraries.md#render) component
  (`sky_environment` translates it). Without one enabled and visible there is no sky light and the
  background is black.
- `Sky.luminance` is luminance in nits.
- Without an image: gradient of `Sky.luminance`, with the horizon somewhat lighter and the ground
  darker.
- `Sky.image`: equirectangular color texture, twice as wide as tall (full turn across the width,
  zenith up, horizon at its middle).
  - The full rotation of its entity turns it (`Gpu_Frame.sky_orientation`, a quaternion: a world
    direction is a sky one through its inverse); `luminance` multiplies it: the luminance of its
    white.
  - It is an ordinary texture of the table, block-compressed: an HDR image (BC6H) keeps the light
    of its clouds above its white. The sun contributes its light as `Sun`, not through the image:
    an HDRI is imported with its sun painted out.
  - `Gpu_Frame.sky_map` carries its index and its last level.
- `Sky.atmosphere`: the air of a spherical planet lit by the `Sun`, by the method of Hillaire
  2020 ([atmosphere](#atmosphere)); `luminance` and `image` do not apply and without an enabled
  `Sun` there is no sky light.
- A change under way blends the sky with that of the one coming (`Gpu_Frame.sky_from` and
  `sky_from_map`): the image, gradient or atmosphere of each side, by its weight. The two
  atmospheres of a change are of the air of the enabled sky.
- `spread` is how much sky the ray represents and chooses the image level: 0 a pixel that looks at
  it; the roughness in a reflection; 1 a ray that gathers light, which reads `SKY_GATHER_LEVELS`
  before the last.
- `sky_irradiance(normal)` is what the sky gives a surface without GI.
- `sky_seen(dir)` is the sky seen by the eye: it adds the sun disc (radius `Settings.sun_radius`,
  that of its penumbra; radiance bounded by `SUN_DISC_MAX`) and its halo when the `Sun` has
  `disc`. The background of each view and what is seen through glass use it; the rays that gather
  light and the reflections do not, to which the sun arrives as light and specular highlight.
- With `use_background`, or in the prefab editor background, the solid color replaces the seen sky
  and the disc; the sky light keeps coming from `sky_radiance`.
- The sun light at a place comes only from `sun_light(position)`: `Gpu_Frame.sun_color` is that of
  above the air when the sky is an atmosphere.

### Atmosphere

`air.slang` and `render/air.odin`. The air is that of `Sky.air` (Earth by default, coefficients
per km of a physical atmosphere): Rayleigh and Mie that dilute with their scale height, Mie
absorption and a tent-shaped ozone layer. The world is flat and horizontal at the eye;
`Air.altitude` is that of y 0 above the planet's ground.

- **Tables**, in fixed entries at the start of the texture table (`AIR_*_TEXTURE`, after the DFG),
  made the first time a sky is an atmosphere:
  - Transmittance up to the top of the air by radius and direction, and scattering of the orders
    after the first with isotropic phase (geometric series over fixed directions). They change
    only with the air (`air_frame`).
  - The sky around the eye, one row per window view (texture views use that of the first), with
    u the angle to the sun around the vertical and v the zenith with more texels at the horizon;
    it includes the lit planet ground below the horizon. It changes with the sun height, the air
    and an eye that moves up or down past `AIR_SKY_ALTITUDE_TOLERANCE` from where it was computed
    (`air_view`); within it the row is read with the current altitude, so the horizon follows the
    eye.
  - Every value is for a sun of illuminance 1 over the air: the illuminance scales it when
    reading it, so an intensity change recomputes nothing.
- **Sun.** `Sun.illuminance` remains what reaches the ground with the sun overhead: above the air
  it is worth that times `air_overhead`, the vertical column in closed form. `sun_light`
  attenuates it with the transmittance at the altitude of the place and turns it off by the
  fraction of the disc below the planet's horizon, so a day is turning the sun and from space the
  sun sets behind the planet.
- **What illuminates the scene comes from the same tables.** `sky_radiance` and `sky_seen` read
  the eye row; `sky_irradiance` averages fixed directions around the normal. The GI rays see that
  sky, so the ambient of the probes follows the sunset.
- **Aerial perspective** per view (`Targets.aerial`, `air_aerial.comp`): columns over the view
  without jitter in slices along it up to `AIR_AERIAL_DISTANCE`, each texel the air light to the
  end of its slice and the mean transmittance. It is recomputed when the camera, the sun or the
  air change. Composite applies it to the image that is shown (`out_display`); the fog of the
  `fog` plugin is composed on top in `Lit`: they are two media and they add up, without counting
  anything twice. Glass and what blends afterwards do not take it.
- Nothing is sampled: each table integrates with fixed steps, and a still view recomputes none.
