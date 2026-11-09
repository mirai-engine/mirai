# Render plugins

Eight engine plugins extend the renderer without code of their own in the core.

- They use the [stages, hooks, views and deformable meshes][ext] through [`engine/render`][stages],
  without importing `render` or `rhi`.
- They have no GPU resources: on each frame they ask for the pipeline of the stages in their
  `shaders/` and the textures of each view (`pass_texture`), which the renderer keeps, and they
  upload the rows of their passes to the frame memory.
- What they upload on their own (decal boxes, fog volumes, mirror faces, portal gates) they build
  in the world in the `render` step and each pass leaves it relative to its `Pass.origin`, like
  their shaders; what they give to the renderer's procedures goes in the world.
- What their shaders share goes in the includes of `engine/render/shaders`, which every stage finds
  like those of `shaders/include`: the mask of a face seen through a nested view
  (`nested_face.slang`), with its Odin part, `pass_nested_faces`.
- Each one has a scene in the demo, except `mirror`, which is in the `main` gallery, `lens`, which
  the demo does not enable, and `fsr`, which is chosen in Graphics.

| Plugin | Component | Uses |
| --- | --- | --- |
| `decals` | `Decal` | `Surface` stage |
| `deform` | `Deform` | deformable meshes and `Geometry` stage |
| `monitors` | `Screen` | texture views |
| `portals` | `Portal`, `Traveler` | nested views, `Mask` stage, ray, light and probe hooks |
| `mirror` | `Mirror` | nested views and `Mask` stage |
| `fog` | `Fog_Volume` | `Lit` stage, view 3D textures with history, traced shadows |
| `fsr` | `Fsr_Settings` setting | a [pipeline][pipelines] with its own passes, no `Resolve` |
| `lens` | `Lens`, `Lens_Volume` | `Post` stage, view textures with levels |

The `Editor` part of each one is its [Create card][cards] in Logic and what a selected entity shows
(a decal's box and where it projects, the arrow from the camera to its screen, a portal's opening
with its front and the path to its exit, a mirror's face, a fog volume's box). The `portals` editor
also declares the `nested` inspection mode: the color of the nested view that drew each pixel. An
entity relates to another through a slot (`core.Entity`): `Screen.camera`, `Portal.exit`.

## Decals

`Decal` puts a color or an image on the surfaces inside the box of its entity (its sides are the
scale), through its local Y axis.

- No geometry: `decals_render` gathers the visible decals sorted by `order` and requests a
  `Surface` pass that draws the box of each one. The fragment finds the pixel's surface by its
  depth and blends base color and emission into the G-buffer (`Alpha_Color`: the target's alpha,
  which carries metallic or occlusion, does not change). Since it enters before lighting, the
  decal receives light, shadows and reflections from the surface; normal, roughness and metallic
  do not change.
- The mip level comes from the pixel's footprint (`frame.footprint`) and the box's texels per
  meter: the derivatives of a reconstructed position break at every edge.
- It is not drawn over pixels of nested views or over glass.

## Deform

`Deform` deforms on the GPU the mesh of its entity, for raster and for rays: shadows, reflections
and motion vectors follow the shape.

- `deform_render` creates per entity a deformable copy of its mesh (`deformable_create`), hands it
  over as a visual replacement (`host.app_instance_add` with `replace_source`) and, while the
  shape changes, requests a `Geometry` pass where the stage of its shape writes the vertices from
  the rest ones, as `render.Gpu_Posed_Vertex` in the words of the vertex pool that
  `pass_deformable` gives. With `speed` 0 the shape stays fixed and is only written when its
  parameters or the vertex buffer change.
- The shape is an equation: `float3 deform_shape(float3 p, Deform_Shape shape)` gives where the
  vertex that rests at `p` is. Those of `kind` (wave, tilt, twist, rings) are in `deform.comp`;
  `axis` and `direction` are in mesh space.
- Each vertex's normal comes from the same function, deforming two steps over the surface at rest:
  every shape lights well without a formula of its own.
- The mesh needs enough vertices to bend; the `Cube`, `Plane` and `Cylinder` primitives do not
  have them. The conservative box is the rest one plus how far a vertex can move away (`reach`).
  Colliders do not follow the shape.

Own equation: a `name.comp.slang` stage in the `shaders/` of the project or of another plugin that
includes `programs/plugins/deform/deform.slang` (with `Deform_Shape` and the mesh measurements) and
defines `deform_shape`, with no Odin code; example: `shaders/pulse.comp.slang` of the demo.
`Deform.shape` names it, `kind` stops choosing and `values` are four numbers that the equation
reads as it likes. Without the stage in the shaders in use, the mesh is drawn at rest.

## Monitors

`Screen` shows what a camera sees in a material slot of its entity's mesh, as light it emits.

- `camera` is the slot of an entity with `Camera`, no other components: it uses its projection,
  clip plane and layers; `active=false` if it must not be the game's view.
- A camera's image is a **feed**. The screens that show the same camera with the same aspect share
  one: it is drawn once, at the largest size, with the highest cadence and the fullest quality
  that any of them asks for.
- `monitors_render` hands over each feed as a [texture view][vtex] at the size at which it is
  seen: the smallest level (each half the previous) that still gives one texel per pixel to the
  screen that shows it largest, with margin to shrink. The textures of each level are kept with
  their histories, and a new level is drawn `WARM_IMAGES` times before being shown, so that its
  history settles unseen.
- With no screen in the view, the feed drops to its smallest level and to a lower cadence: what a
  screen reflects, or sees through a portal, keeps seeing it alive. A camera that no visible
  screen names is not drawn.
- The screen is a visual replacement with a derived material row (`host.assets_material_derive`)
  that emits the shown level. For it to light, its entity also carries a `Rect_Light` and
  `Light_Emission` with its `slot`: the rectangle takes the row that the screen shows in that
  frame, because the replacement carries `replace_source` and the entity's `object_id` ([local
  lights][lights]). The glass of the demo's screens is thin so as not to block the shadow rays,
  which stop before the rectangle's plane.

## Portals

`Portal{exit, ellipse, layers, wall}` is an opening that shows the place of another entity and
leads to it: the unit square of its entity seen from its +Z, of its scale (`ellipse`: the
inscribed ellipse).

- `exit` is the exit slot: another portal or any entity; without it nothing is shown. What is in
  front continues behind `exit`, turned half a turn about its local Y and without scale
  (`through_of`). Two portals that name each other join two places, also a floor with a wall.
- `wall` is the collider in which it is open, of any type, or `NONE`. `Traveler{point}` goes
  through the portals that its point crosses.

**Render** (`gpu.odin`), up to `PORTAL_CAPACITY` portals per scene:

- Each view receives in its `Mask` stage one nested view per portal that faces it (the nearest
  ones): the scene from its camera carried through the portal, cut by the exit plane and with the
  portal's layers. The mask is a screen triangle with scissor that intersects each pixel's ray
  with the opening's plane (`nested_face.slang`): it stays whole with the eye on the plane, where
  a quad would be clipped against the near plane.
- Each view's constants carry the gates (`frame.portals`). The ray hook makes a ray that enters
  through the front of an opening continue from the exit: reflections, GI, probes and shadows
  cross once, with the accumulated distance.
- Probe hook (`portals_probes.slang`): the part of a point's irradiance that arrives through the
  opening is the opening's form factor seen from the point, read at the point behind it, on the
  exit side. On the plane, the parts of the two sides add up to one: a body half-crossed receives
  the same indirect light on both sides.
- A light on this side whose shadow ray would cross an opening is blocked. Each portal brings the
  strongest lights of its exit's room (`PORTAL_LIGHT_CAPACITY`) through the light hook, as lights
  seen from behind the opening with the shape of their entity (`sphere_desc`, `rect_desc`): they
  light only through it, with the beam's edge soft according to the light's size, and carry two
  shadow rays, to the opening and from the exit. They enter the shadow blocks like any light, and
  the penumbra of what is on the other side continues on this side.

**Travel** (`portals.odin`):

- `portals_travel` (`fixed`, before `locomotion_seat`: before the game input and the physics)
  looks at the stretch that each traveler covered in the previous tick. If its point entered
  through the front of an opening, it places it on the other side with `core.place` (a
  [jump][jump]: the `previous` goes with it, so drawing interpolates on the other side), asks
  physics for the turned velocity (`phys.set_velocity`) and publishes the crossing in
  `Portal_Crossings`.
- Only physics bodies and characters travel, with no second writer of their tables: physics
  applies the request when its step of the same tick starts. A body comes out turned by the whole
  portal.
- A character comes out upright (`character_through`): its heading is that of its gaze turned by
  the portal; if the turn is not about the vertical (floor to wall), the capsule is placed whole
  in front of the exit. The gaze (`Move_Input`) of a traveler that this end decides (`core.owned`)
  is turned by the plugin; whoever keeps another direction of their own turns it with `turn` in
  the same tick.

**Walls** (`collision.odin`, `portals_collision`, only in the game loop, after `portals_travel`):

- While a portal with `wall` leads somewhere, its wall is [cut][cuts] (`phys.Collider_Cuts`) at the
  opening and a strip of `RIM_WIDTH` around it, from a little in front of the opening to the
  bottom of the wall: what enters does not touch it and queries go through it (a character on a
  floor portal falls). The wall's `Collider` is not touched.
- Four child boxes of the portal (`Portal_Rim`) line the hole with the surface and the collision
  of the wall, in the strip, from its face to its bottom: what is in the hole does not enter the
  wall sideways. Where the face and the bottom are is measured by rays against the wall's collider
  alone (`collider_raycast`), at most `WALL_DEPTH_MAX` behind; without a bottom (one-face
  triangles), the frame has `RIM_DEPTH_MIN`. `Portal_Frame` stores them and is rebuilt only when
  the opening or its wall moves, or the collider changes; without the wall behind the opening's
  center there is no hole.

**Half-crossed** (`portals_collision`):

- A traveler whose box (`phys.body_bounds`) crosses the plane of an opening within its square has
  a [twin][cuts] (`phys.Body_Twin`): copies of its colliders where the portal leads it, which
  collide only in front of the exit. The part that peeks out collides with what is behind the exit
  and pushes what it finds, and that returns to the traveler turned by the portal: it stays
  half-crossed against a wall on the other side.
- What of the traveler goes past the bottom of the wall (of the opening, if it is loose) is cut:
  it does not collide with what is behind the wall on this side and queries do not find it there.
- On the tick in which `portals_travel` carries it, the twin goes to the exit, if it is a portal
  that returns: it stays on the entry side while it finishes coming out. Far from every opening it
  has neither twin nor cut.

**On both sides** (`doubles.odin`):

- `portals_doubles` draws again, carried by the portal, each mesh of a traveler that crosses the
  plane of an opening, as a frame instance: a half-crossed body is seen from both sides.
- `portals_view` (after `camera_view`) covers the frames between the tick in which the point
  crossed and the one that carries it: if the view's eye is already behind the opening, it draws
  it from where it will be. Comparing the eye with that of the previous frame (`Portal_View`, from
  the host: a world that goes back ticks does not take it away), it delivers `core.View.carried`
  if the path between the two enters through the opening, and the renderer keeps the history; if
  the portal carried it in another way (a third-person camera that jumps with its body), it marks
  `core.View.cut`. A view that comes out turned or shifted relative to where the portal would have
  carried it is straightened in `RIGHTING_TIME`.

**Limits.** Glass, particles and overlays are not seen through a portal, nor a portal through
another, and the exit does not scale. Each part of a body that crosses is lit where it is. The hole
and its frame are the opening's square: at the corners of an `ellipse` opening the hole can be
entered without traveling. The frame is flat, at the height of the wall's face at the opening's
center: on a curved surface it does not follow it. A traveler has one twin at a time, that of the
portal to whose plane it is nearest, and `sim.TWIN_CAPACITY` half-crossed travelers fit. With
several window views none gets ahead of the tick or carries its history (`portals_view` acts on
`core.View`). A covered portal still costs its nested view.

## Mirror

`Mirror{ellipse, layers}` is a flat mirror: the unit XY square of its entity seen from +Z, of its
scale, or the inscribed ellipse. The entity carries no mesh; `mirrors_render` does two things with
each visible mirror:

- **In the views that face it** it adds in the `Mask` stage a [nested view][nested] reflected in
  the face's plane and cut by it. What is reflected goes once through the view's lighting, filters
  and TAA, with soft shadows, GI and its own reflections, and costs one more G-buffer over those
  pixels instead of a ray with per-pixel shading. The mask finds the face by ray, like that of the
  portals.
- **For everything else** it draws behind the face a thin metal body with roughness 0, which the
  mask covers. Through it the rays (reflections of other surfaces, GI), the views without room
  for another nested view and those that look at it through a portal or another mirror see the
  mirror.
- A view's nested views are shared between portals and mirrors in the order in which their plugins
  ask for them; among the mirrors, the nearest first.

**Limits.** What a nested view does not draw (glass, particles, decals, overlays) is not
reflected. A mirror inside another, or through a portal, is the traced body: one more level of
reflection, without the detail of the first. It reflects everything, without tint or roughness,
and only with flat faces.

## Fog

`Fog_Volume` is a medium that darkens what is behind it and shows the light that crosses it, with
the shafts that what blocks the sun and the lights cuts in it. It is a
[volume](../../mirai-gameplay/references/libraries.md#volume) value: the `Volume` of its entity says
where it is (without one, the whole world), its edge and whether it replaces or adds to what is
below; the shaders combine it at each point with `volume_weight` and `volume_mix`.

- `density` (per meter): of the light that crosses a meter, more or less the part it stops.
- `color`: of what it stops, the part it scatters in each channel; it absorbs the rest.
- `anisotropy`: greater than 0 scatters forward, and a shaft shines more looked at toward its
  light; less than 0, backward (Henyey-Greenstein, up to ±0.95).
- `falloff` (per meter): it thins with the height above its base (the lowest point of its
  `Volume`, or the entity's height without limits), by e every `1/falloff` meters; below it does
  not grow.
- `variable`: its density varies from place to place in wisps and banks of some `wisp_size` meters
  that move by themselves, without depending on the engine wind. They are layers of value noise
  (`WISP_OCTAVES`), each smaller than the previous, that travel with `drift` by a part of their own
  (`WISP_DRIFT`) and also on their own (`WISP_CHANGE`): they slide over one another and the wisps
  change shape as they advance. The field goes from 0 to 2 times `density` and its mean is
  `density`: the noise goes as much above as below its half and the contrast pushes it equally
  toward both sides. Layers smaller than a grid cell blend into their mean instead of flickering.
  Where each layer is in the frame is computed by the CPU in f64 with the world time and the
  render origin (`wisp_lattice`), in whole cells and a fraction: it loses no precision far from the
  world center or after hours.
- Up to `CAPACITY` (16) visible volumes counting the media of other plugins, which keep their
  place: the lowest world priorities are left over first.

`Fog_Settings.hidden` (machine) says how often a cell that is behind everything its column sees is
lit:

- `Every_Frame`: like those that are seen.
- `Every_Fourth` (default): one frame in four, in turns; in the others it keeps its reprojected
  light. When the camera shows it, it already has its light settled.
- `Never`: it is not lit, and on being shown its light starts again: a few frames with more grain
  than the rest.

### Media from other plugins

A plugin adds media to the frame through the `Fog_Media` queue (`medium_add`), before
`fog_render`: a world box (`Medium.box`, its sides are the scale) that is added to the world's
volumes, after them, with density, color and anisotropy like a `Fog_Volume`, a priority and these
marks:

- `dry`: a dry box, without medium, that removes from itself the `carved` media of lower priority
  and what those media take from the sun;
- `carved`: a dry box of higher priority removes it;
- `sun_only`: only the sun lights it, in shafts; the surrounding light is drawn by whoever adds
  it;
- `shade` (per meter): what it takes from the sunlight that crosses it. What is in it receives
  from the sun `exp(-shade · path until leaving its box toward the sun)` (`fog_shade`): the light
  of its froxels (from the sun, and the ambient one along the path upward) and the surfaces it has
  inside, which `fog_apply` darkens before adding the fog to them.

It is used by [water](../../mirai-world/references/water.md): the medium under a surface and its dry
boxes.

**Render** (`fog_render`, `render`, after `render_sync`; `Lit` stage of each view):

- Each view has a froxel grid aligned with its frustum (`grid_size`): one column every
  `GRID_PIXELS` (8) pixels up to `GRID_COLUMNS` (160), the rows of its aspect (100 at 1440×900, 90
  at 16:9) and `GRID_SLICES` (64) slices up to `DISTANCE` (128 m). Slice `s` starts at depth
  `SLICE_SCALE · ((1 + DISTANCE / SLICE_SCALE)^(s/64) − 1)`: about 13 cm long near the eye, 80 cm
  at 10 m, 8.5 m at the end.
- `fog_far.comp` stores the farthest depth that each column sees (one group per column over its
  pixels; what has no surface counts as the end of the grid) and `fog_reach.comp`, that of that
  column and the two on each side: up to there the integration filter and the interpolation of
  `fog_apply` read the grid. A cell whose previous slice starts farther is hidden. With
  `Every_Frame` they do not run.
- `fog_light.comp` takes at each froxel a fixed point of the cell and writes two textures: the
  medium of the volumes there, with the wisps of the variable ones as they are now, and the light
  that point receives for each meter of what it scatters (except a hidden cell out of its turn,
  which copies its reprojected light and leaves the medium empty, or with `Never` is marked as not
  lit; one without history is lit at once). The light is weighted with the mean medium of each
  volume, not that of this frame: it does not depend on where the wisps are. Where there is a medium
  that scatters, it lights it with the light of the engine's media (`shaders/include/media.slang`,
  the same as the volumes of [`vfx`](../../mirai-world/references/vfx.md#volumes)):
  - the sun, `sun_light` of the place, with a shadow ray (`trace_transmission`);
  - a local light chosen from the light tree according to what it gives the point, divided by the
    probability of choosing it, with another ray: two rays per froxel with any number of lights;
  - the ambient: the mean of what the probe volume gives to an upward-facing surface and a
    downward-facing one (without GI, the sky).
- The rays are those of the direct light's shadows: with `colored_shadows` and glass in the scene,
  a shaft that crosses a stained glass window takes its color.
- Only the froxel's light is blended with that of the previous frame where its center was, if the
  view keeps it (`pass_texture` gives `kept`): a camera cut starts again. The medium is always
  that of this frame, so wisps that cross a shaft take its light at once, without a trail and
  without reprojecting the field. The light stores in `a` whether there was a medium (1) or not
  (0), multiplied by the light: blended with a frame without medium, `rgb / a` is still the
  light. It is not blended where a ray of the froxel crosses what casts shadows and changed since
  the previous frame, or its light moved
  ([mark](../../mirai-rendering/references/lights.md#shadows)): the shaft that cuts something that
  moves appears at once. The history stores the unfiltered light.
- `fog_integrate.comp` integrates each column from the eye over the length of each froxel
  (Hillaire 2015): the cell's medium times the light of the cells of its slice around it, with a
  tent filter that spreads what the rays see of the sun. After the grid it continues along the
  column in `FAR_SLICES` more slices, each farther than the previous one by the same ratio up to
  `FAR_REACH` and the last one unbounded, each in closed form, with a fixed cost per column
  (slices times volumes) and not per pixel:
  - what each volume stops is the exact integral of its mean density (the exponential of the
    height above its base, constant below) between where the slice enters and leaves its shape,
    without its soft edge; the one that replaces what is below keeps the part of the slice that it
    occupies;
  - what it scatters is its albedo times the sunlight at the middle of the slice (`sun_light`,
    without shadow ray, with the phase of its anisotropy and what the media with `shade` take from
    it) and times the ambient where the grid ends (`media_ambient`): the same terms as the last
    slice of the grid, so the fog continues seamlessly at `DISTANCE`. Dry boxes do not enter.

  The cost is fixed per column (slices times volumes), not per pixel.
- `fog_apply.comp` reads the grid and the far slices at each pixel's depth (what has no surface,
  up to the end of the view): `image · transmittance + light`. With an atmosphere the fog is
  composited over the aerial perspective that the composite already applied, and the sun of both
  comes from `sun_light`.
- With glass in view the `Lit` stage runs on each side of the nearest layer and `fog_apply` splits
  at that point, with the same composition: behind it applies the fog from the glass to the
  surface (what the grid gives up to the surface without the part up to the glass, divided by what
  that part lets through), which the glass filters; in front, over the lit glass, that from the eye
  to the glass. Where the fog in front lets almost no light through, that behind is applied as if
  it let `FOG_FRONT_LEAST` through: the glass and what is behind it are not seen.
- Each pass has its GPU time (`pass_timestamp`).

**Limits.** Particles and panels are drawn afterward, without fog. Only the nearest glass layer
cuts the fog: the one between two layers goes through the one behind, and what the glass refracts
from a pixel without glass brings its whole fog. Beyond `DISTANCE` there are no shafts or shadows,
local lights or wisps: the medium continues with its mean density, lit by the sun without shadows
and by the ambient at the end of the grid, and the soft edge of a volume is hard. The shaft has the
size of the froxel, a light that moves leaves a short trail and the sun is traced as a point,
without penumbra. Extension lights (those of the portals) do not light the medium, and a light does
not have a scattering factor of its own.

## FSR

AMD FidelityFX Super Resolution 3.1 as an [antialiasing technique][techniques] (`fsr3`): it
reconstructs the view's image at its output size from the previous frames, like TAA, with more
detail and twice the cost.

- While `Graphics_Settings.antialiasing` names it and the shaders have their stages, `fsr_render`
  draws the window views with the `Full` pipeline whose `Resolve` passes are those of
  `ffx_fsr3upscaler.cpp` in their order, with `jitter = .Upscale`. The scene resolution is that of
  the Resolution setting.
- The passes are AMD's HLSL (`shaders/fsr3`, with its `UPSTREAM.md`) compiled by Slang, with the
  plugin's entry points (`shaders/fsr3_*.comp.slang`). The resources and formats are those of
  `ffx_fsr3upscaler.cpp`; what the algorithm keeps between frames is `history` or `kept`.
- The view's exposure arrives in a 1x1 texture (`fsr3_exposure`), which also resets the frame
  information when the history starts.
- **Frame generation.** With `Graphics_Settings.frame_generation`, the same pipeline adds after
  `Output` the optical flow and interpolation of FSR 3.1 (`runtime/framegen.odin`, in the order of
  `ffx_opticalflow.cpp` and `ffx_frameinterpolation.cpp`): they read `Ldr` without the UI and write
  `Generated`
  ([frame generation](../../mirai-rendering/references/views.md#frame-generation)). Without
  FSR as antialiasing it does not generate. The flow's luma has history instead of the pair that
  AMD alternates; the previous image is a `kept` resource that the last pass copies.
- `Fsr_Settings.sharpness` (machine, a Graphics row) chooses the `sharpen` variant of the
  accumulation and RCAS.
- No FSR 1 or FSR 2.2.

## Lens

What a lens does besides exposing the image: depth of field, motion blur, bloom, vignette, radial
distortion and chromatic aberration. All off or neutral by default; without an effect on in any
view, the plugin requests no passes.

- **Who decides.** `Lens` on the camera entity replaces it entirely; without it, the `Lens_Volume`
  where the view is, a [volume](../../mirai-gameplay/references/libraries.md#volume) value that
  blends numbers by their weight and takes the switches past the half. `lens_render` resolves it
  for the frame's view and for each local view (`camera.Local_Views`); each pass takes that of its
  `Camera.slot`. A texture view (a monitor, `capture` without UI) takes that of the frame's
  view.
- **Consistent with exposure.** The aperture (f-number) and the shutter time are those of the
  `Exposure` that exposes the view: that of the camera, or that of the `View_Volume` where it is
  ([exposure](../../mirai-rendering/references/display.md#exposure)). In `Auto` they do not
  change the brightness; in `Manual` closing the shutter darkens the image like in a camera. The
  focal length comes from the vertical field and from `Lens.sensor` (0.024: full frame): with the
  same f, a wide angle barely defocuses.
- **Where it runs.** In the `Post` stage of each view
  ([extensions](../../mirai-rendering/references/views.md#extension-stages)): over the resolved
  image, at output size, before the PostProcess and the tonemap, in this order and each one
  writing the next image with `pass_image_write`. After the temporal resolve nothing averages
  frames: no pass samples randomly per frame or uses a pattern that changes.
- **Depth of field.** The circle of confusion is that of a thin lens, `radius∞ · (1 − focus/d)`,
  limited to `COC_MAX` of the height. A half-size layer gathers what each pixel sees through the
  aperture (`lens_dof_bokeh`: rings of samples, even in the disc's area); what is nearer than the
  pixel covers it with its own circle and in the part of the disc that it represents, and what is
  not, with the smaller of the two. The tiles (`DOF_TILE`) give the widest circle in front of the
  focus, so that a defocused foreground spreads over what is sharp. The image takes the layer only
  where its own circle exceeds one pixel or what is near covers it: what is sharp keeps the detail
  of the full resolution.
- **Motion blur** (McGuire 2012 with the weights of Jimenez 2014). The trail of each pixel is half
  of what moved while the shutter was open (`shutter / delta_time` of the frame's vectors),
  limited to `MOTION_MAX` of the height, which is also the tile's side. What nothing drew moves
  with the camera's turn. Each pixel samples along the longest trail of the neighboring tiles and
  its own, no more than a pixel between samples, always at the same places.
- **Bloom** (Jimenez 2014). Levels from half size (`BLOOM_LEVELS`) with 13 samples when going
  down, the first with Karis's average so that a bright pixel does not flicker, and a 3×3 tent
  when going up adding the widest. The image is blended with the mean of all the levels by
  `bloom`: it conserves energy and has no threshold.
- **Distortion, aberration and vignette**, in the last pass, that of the bloom: the distortion is
  radial with the radius measured to the corner and a scale that keeps the image filling the view;
  the aberration carries red farther from the center and blue nearer, and only adds two reads; the
  vignette is the natural `cos⁴` falloff of the off-axis angle according to the view's field.
- Each effect has its GPU time (`lens dof`, `lens motion`, `lens bloom`, `lens`).

**Limits.** Depth of field is that of a circular aperture, without diaphragm shape, and an
orthographic view does not have it. Motion blur does not see what moved within a pixel nor follow
curves within the shutter; trails longer than the tile are cut at it, and with long shutters a thin
object leaves faint bands. The editor grid is composited afterward and is not blurred.

## Verification

- Check types of each `runtime/` and `editor/`, generate and build the demo and open each scene in
  the editor without a window with validation (`--headless --validation --api-port`): zero
  validation errors in all of them.
- The cards: `scene.add` (`preset` `decal`, `screen`, `portal` or `mirror`), `scene.set` to give
  the slot and `capture` with the entity selected.
- What to look at per scene:
  - `decals/decals.scene`: decals on floor, wall, steps and a sphere; order between two
    overlapping ones; the one that emits; edges up close.
  - `deform/deform.scene`: shadows and reflections that follow the shape, normals without facets,
    nothing blurry in motion; the wall's hoses use the demo's equation.
  - `monitors/monitors.scene`: screens up close and far away (the level follows the size); looking
    away lowers the cost; the floor reflects the light of each screen.
  - `portals/portals.scene`, `portals/portal_chamber.scene` (the [portal game][game]) and
    `portals/portal_lab.scene`: the doors from the front, from the side and from behind, the eye on
    the plane, the shafts and the light that enter through an opening with the shadows of the other
    side, the wall's hole and the half-crossed cube.
  - `gallery/main.scene`: the gallery mirror from the front, from the side and with the camera
    moving: reflections with their reflections, sharp edges, no trail; with `ellipse`.
  - `church/church.scene`: the sun shafts of the stained glass windows cross the nave with their
    colors and the candles have their halo. Hiding `Haze` (`scene.set` with `Hidden`) isolates its
    cost.
- In Play, by API (`editor.input` with keys, one frame per tick): walk toward a door and capture
  the frames of the crossing, which must be continuous (the position continues on the other side,
  the gaze turns with the portal and the velocity is preserved); come back through the other one;
  throw a cube through. Measure with the portal visible and hidden (`scene.set` with `visible`).
- Lens, in a project that enables it: `mirai test plugins/lens/runtime` (who decides, the volume
  blend and the circle of confusion) and, in `lights/night.scene` with a `Lens_Volume`, a capture
  per effect against the same view without it (`--reference`) and `--repeat` (the image does not
  change between frames). Motion blur is captured by flying with `editor.input` (right button and
  a key held) and `capture` with UI before releasing them.
- Walking, turning fast while looking at a door and looking at a monitor are tested by the user.

[ext]: ../../mirai-rendering/references/views.md#views-cameras-and-extensions
[stages]: ../../mirai-rendering/references/views.md#extension-stages
[cards]: ../../mirai-editor/references/extensions.md#create-cards
[vtex]: ../../mirai-rendering/references/views.md#texture-views
[lights]: ../../mirai-rendering/references/lights.md#local-lights
[jump]: ../../mirai-physics/references/engine.md
[cuts]: ../../mirai-physics/references/physics.md#twins-and-cuts
[nested]: ../../mirai-rendering/references/views.md#nested-views
[game]: ../../mirai-gameplay/references/demo.md#portal-game
[pipelines]: ../../mirai-rendering/references/views.md#render-pipelines
[techniques]: ../../mirai-rendering/references/views.md#antialiasing-techniques
