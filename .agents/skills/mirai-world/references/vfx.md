# Particles: the `vfx` plugin

`plugins/vfx` (`Runtime`, `Editor`, `Shaders`): particle effects simulated, lit and drawn on the
GPU. Without the plugin enabled, neither the game nor the editor has particle code, state, passes
or shaders. It extends the renderer only through
[`engine/render`](../../mirai-rendering/references/views.md#extension-stages). The plugin's
editor (inspector, document, thumbnails and `particle.*`) is in [its reference](vfx-editor.md).

## Format

`plugins/vfx/runtime/effect` (`effect.KIND` `PART`, `.particle`, `effect.VERSION` 4; another
version asks to write it again). An effect is like a material: entities name it
(`vfx.Particle_Emitter`) and give it values of their own (`vfx.Particle_Override`, fields and
program parameters alike). Tables: `particle` (`Particle_Info`), `parameters`
(`Particle_Parameter`) and `hidden` (`Particle_Field`).

- `Particle_Info` is the destination of what is imported from other engines; its fields and
  their units are in `effect.odin`. Besides them:
  - a constant `rate`: a program's `births` gives any other shape;
  - the shapes `Surface` and `Bones` take the triangles or bones of what the entity binds or
    draws ([surfaces and bones](#surfaces-bones-and-resources));
  - `gravity` and `drag` read the gravity (`Gravity`) and wind (`Wind`) where each particle is, the
    volumes bodies and foliage read, evaluated on the GPU
    ([volumes](../../mirai-gameplay/references/libraries.md#volume)); those of an effect view fall
    with `GRAVITY`;
  - a `Mesh` particle turns its mesh by its `rotation` (and `spin`) about an axis of its own;
  - its particles light the scene with `lights`, and cast shadows only with `light_shadows`
    ([lights](#particle-lights));
  - the editor shows each field in the group its `group` tag names, or in that of the field
    before it ([document](vfx-editor.md#particle-document)).
- Curves have `PARTICLE_CURVE_KEYS` keys with non-decreasing times from 0 to 1; the surplus ones
  repeat the last at 1.
- `parameters` stores values for the program by name (`Particle_Parameter`: type, from one to four
  components, values or texture).
- `hidden` lists the fields that an instance does not show.
- A value is named by its path (`rate`, `colors.1`, `bursts.0.count`,
  `size_over_life.values.2`). `particle_fields` lists those that an instance can change; the
  program's text no. `particle_value_at` finds one by path and `particle_value_find` by the hash of
  its path, without allocating.
- `particle_validate` says the first invalid field and how to fix it (`particle_check` summarizes
  it); `particle_view` rejects an invalid file.
- The asset registry lists the `.particle` files like any file; `host.assets_document(a, id,
  effect.KIND)` keeps them open like scenes and `vfx.effect_view` reads them. An effect that the
  plugin rejects is a problem of the asset (`host.assets_document_refuse`).

## Game

A `Particle_Emitter` on an entity shows an effect. An effect of several emitters is a prefab,
placed with `scene.spawn`.

`Particle_Emitter` names the effect (none: `effect.PARTICLE_DEFAULTS`). It emits by its fields
alone: `active` while playing (start and stop set it), `preview` in the editor while the world does
not play; turning either off lets the live particles finish. `destroy_when_done` destroys, while
playing, the entity and what hangs from it once every emitter of the tree finished its cycle and
its last particles (and those of its sub effect) died.

Values of an instance:

- `Particle_Override`: the entity's own values, shaped like `erender.Material_Override`: one
  table of `base.name_hash` names and 16-byte values, where a name is a field path of the effect
  (`effect.particle_fields`, its bytes) or `parameters.` and a parameter of its Vfx program (its
  numbers as `[4]f32` or its texture's `Asset_Id`, `parameter_value`, `parameter_hash`): the
  prefix, the name of the file's table, keeps a parameter such as `speed` apart from the field.
  `value_set(&o, "colors.1", [4]f32{...})` validates a field's type and range, or a parameter's
  numbers, and returns an `Error`; `error_message` says how to fix it; `value_remove` takes one
  away. The effect's assets and program belong to the effect
  (`Effect_Field`). Whether the program declares a parameter is told when the emitter resolves
  it (`particle_program_check`, `value_parameter`).
- `particle_resolve(assets, particle, override)` gives what an entity shows;
  `particle_resolve_checked` also says what is wrong. `particle_program` resolves the effect's Vfx
  program in the catalog of the shaders in use (`erender.program_find`).
- It is the algorithm of the
  [prefab overrides](../../mirai-assets/references/scenes.md#prefab-instances), with the same
  functions of `asset/overrides.odin`: `value_leaves`, `overrides_mark` and `override_keep`.

## Surfaces, bones and resources

What an emitter reads besides its values are resources, in rows that the GPU finds through the
emitter: first the surface or bones of its shape, then those that its program declares
(`//! resource name surface|channel|grid|emitter|data`), in their order. Bones are of the `Bones`
shape alone: no program resource reads them. A grid is the one that the
emitter binds or one of the world by its name ([grids](#grids-and-stages)).

- A surface is the mesh that an entity draws in the frame, as the renderer has it: a skeleton's
  skin moves its triangles (`Render_Sync`, the mesh that replaces its own) and a particle that
  stores its triangle and its barycentrics follows it. Without the world's scene in the renderer,
  that of its `Mesh_Renderer`, where it is.
- The bones of a skinned mesh go from the joint of each parent bone to its own, skipping those
  that move no vertices: those that help a rig (an IK target, a root on the floor) deform nothing
  and would give particles far from the body. Which joint each one is (its parent and where it is
  in the bind pose) is read from the mesh and its skeleton the first time (transaction) and again
  when the assets change; each frame they are posed with the palette that the renderer gives the
  skin in that frame and in the previous one (`erender.skin_palette`) and go to the frame's rows.
  A mesh that nobody poses, in its bind pose.
- Who gives each one, in order: what the entity binds (`Particle_Bindings`: `surface` for the
  shape, `sources` for those of the program: the source of its name or, with none, the unnamed one
  of its index) and, for the shape, what the emitter draws. An effect names no mesh: one that must
  emit from a given mesh is a prefab whose emitter binds that mesh's entity. A resource without a
  source has no surface: the program reads it with `valid` false.
- A grid: that of the entity that binds its source or that of the world's grid it names (`grid`);
  without a binding, the first grid that its stages walk is that of the emitter's entity, if it has
  one, and any other that of the world with the resource's name. A binding to what does not exist
  reads nothing: it is not looked up elsewhere. So each fluid runs on its own and several emitters
  read different grids with the same program.
- Details shows of `Particle_Bindings` the surface and one row per resource of the program that an
  entity reads (surface, grid or emitter), with the name that the program gives it, and for
  a grid another with the name of the grid it reads; it writes the source of its index, unnamed
  (`bindings_section`).
- A surface is sampled by area and bones by length, on the GPU: the summed length of the bones goes
  with them in the frame's rows, and the sum of the areas of the triangles of each surface is built
  in the world's buffer (with the grids afterward) on the GPU (`particle_surface.comp`) the first
  time a world reads it and again when the scene rebuilds its vertices (`erender.vertices_made`),
  in a world buffer that is compacted and grows as a transaction; a stable frame does not touch it.
  A triangle of a surface is a level 0 primitive (cluster and triangle, `geometry.slang`):
  `CLUSTER_TRIANGLES` per cluster, with no area those past what the cluster has.
- Each row carries the pose of this frame and that of the previous one: the velocity of a point of
  the surface is that of its motion, which `inherit_velocity` passes to the particles.

## Grids and stages

A world grid is a `Particle_Grid` on an entity: a name, its cells along the world axes (an axis of
one cell is flat), the size of a cell and its layers of four floats.

- Its region is around the entity and follows it in whole cells, wrapping in place: moving it
  copies nothing and the cells that enter start at zero. Outside the region a cell reads zero.
- Each cell stores two copies, what the previous stage left and what this one leaves, and what the
  step's particles splatted (`mirai_vfx_grid_splat`, spread among the neighboring cells by
  proximity). What is splatted returns to zero at each step.
- Remaking the grids, or one of another size, is a transaction: its cells start at zero. A world
  has up to `GRID_CAPACITY`; one that does not fit, with another of the same name or with invalid
  values is the `vfx.grid` problem. Of two with one name it keeps the one that already had it in
  the previous frame, whatever the order of the rows; a new grid enters as an entry of its own,
  without what another entity's stored.

A program declares stages (`//! stage name over particles|grid [iterations N]`): on each step,
after the births and before `update`, stage k of each emitter that has it, k in order,
`iterations` times in separate dispatches: each iteration sees what the previous one left (a
constraint solver reads the other particles already moved).

- Over particles: once per live particle, like `update`. Neighbours go through a grid: one stage
  adds each particle to the words of its cell (`mirai_vfx_grid_word_add`) and a later one reads
  the cells around it.
- Over a grid: once per cell of its region; each iteration reads what the previous one left and
  leaves its cell's layers in the other copy, which keeps those it does not leave.
  A single emitter walks a grid with its stages; another that does so in the same frame is the
  `vfx.grid` problem and its stages over it do not run.
- The stages of a sub effect do not run.
- `initialize`, `update` and the stages trace the scene (`mirai_vfx_trace`): the emission,
  simulation and stage passes include the tracing and declare the `_hw` variant.
- Grids and fluids are grids and stages of this contract, not another system (the `fluids` plugin
  lives in the mirai-fluids repository).

## World textures

A `Particle_World_Texture` next to an entity's `Particle_Grid` lets materials read a layer
(`layer`) of its grid by the grid's name:

- The grid is flat along y; up to `WORLD_TEXTURES` per world. Anything else is the
  `vfx.world_texture` problem.
- A Surface program includes `vfx_world_texture.slang` and calls
  `vfx_world_texture("name", ctx.world_position)`: the value between cells by a cubic B-spline
  (four bilinear reads: up close the cells are not seen) over the grid's region, zero outside it
  and without the grid. The name arrives as Slang's `getStringHash` (`world_texture_name` in
  Odin).
- `vfx_world_texture_uv("name", uv)` reads it by UV over the region, like an Unreal material
  samples the render target that a grid writes: (0, 0) is the start of its first cell and (1, 1)
  the end of the last, bilinear and repeating.
- Each frame, after the steps, a dispatch leaves the layer in half precision behind the grids of
  the world buffer and the renderer copies it to a texture of its table
  (`erender.pass_table_texture_copy`). The world's cell c ends up at texel c modulo the cells,
  where the grid stores it: the texture repeats over the world and the region does not shift it.
- The views of a frame read what the previous frame's steps left, with their region: the first
  view draws before the steps of its frame.

## Grid states

`plugins/vfx/runtime/gridfile` (`gridfile.KIND` `VGRD`, `.grid`): what the cells of a grid's region
had, from its first cell (x fastest, then y and z), with their layers.

- A `Particle_Grid` that names one in `cached` starts from it when made, and again when it names
  another: `particles_frame` reads it and puts it in the order in which the grid stores its cells,
  and the pass writes it into its two copies. One of other cells or layers is the `vfx.grid`
  problem.
- `follow_view` centers the region, instead of on its entity, toward where the view's center looks
  at the plane at the entity's height, without passing what leaves inside what the view's bottom
  edge sees (`VIEW_NEAR`; the water waves): a high camera sees the waves where it looks and a low
  one, also those in front.
- A grid whose last writer left the pool, with its particles, is emptied once: nothing moves or
  turns off what it stores (the smoke of a deleted fountain).

## Volumes

A `Particle_Volume` next to an entity's `Particle_Grid` draws its grid as a medium: in its first
layer, `x` is the density and `y` how much it glows. A flat grid is not drawn (problem
`vfx.volume`).

- Once per frame, after the steps, each cell with density takes the light it receives with the
  light of the engine's media (`shaders/include/media.slang`, the same as `fog`): the sun through
  the scene and through what the medium lets pass cell by cell toward it, a local light in turns
  and the ambient one. It stores it in the world buffer, added to that of the previous frames: one
  light per turn gives all.
- In each view, before the sprites, a ray from the camera walks the region in half-cell steps up
  to the scene or the pass's glass: at each step it adds what the medium scatters of that light
  (the sun with the medium's phase toward the eye) and what it glows, behind what the previous
  steps already covered.
- Its screen triangle is on the near plane: the `Blend` depth test lets each pixel through and the
  march is cut at the scene.

## Channels

A game gives births to a channel (`core.Births`, a world queue of `core`: whoever pushes does not
import `vfx`): where,
with what velocity, color, size, how many and values that its programs read
(`Mirai_Vfx_Context.values`). Each emitter with a `Particle_Channel` of that channel starts
particles of its effect at each one, besides its own; a program reads them through a `channel`
resource.

- A channel is a name ([births](../../mirai-core/references/core.md#births)), keyed as a
  [data channel](#data-channels) is: whoever pushes and whoever listens say it as text
  (`fluids` `brushes` and `displacers`, `water` `splashes`, `terrain` `dust`, the demo's
  `impacts`). A program's `channel` resource reads the channel whose name is its own.

- A silent `Particle_Channel` (`silent`) starts no particles: its program reads the births alone,
  through a `channel` resource of the same name (the brushes of the `fluids` plugin).
- In the editor, while the world is not playing, an emitter that is not silent receives a birth on
  itself at the start of each cycle of its effect (`channel_preview`): nothing else gives it births
  there, and where it is can be seen.
- `particles_tick` numbers the births of each channel in the world, as the clocks number theirs,
  and `particles_sync` starts on the GPU only those it did not start: a rollback that gives them
  again does not draw them twice. A channel that starts being listened to starts those it stores.
- A channel stores those of its last ticks (`CHANNEL_BIRTHS`); the older ones are lost and counted.
  One that no emitter listens to is released.

## Data channels

A program reads and writes entries of words in the world's data channel of a name
(`//! resource name data words`, `data.odin`): what the programs add in a frame is read in the next
(`update` and the stages add only in the last step of the frame, so as not to repeat entries). A
game does not write a channel: it gives programs data through the `values` of its
[births](#channels). A game reads back a channel it watches (`data_watch` on each frame,
`data_entries` over `Particle_Data_Read`): what the programs added in a frame arrives once, frames
later and without waiting for the GPU; like the reports, it is presentation. The channel exists
while some program of the world uses it, with the most words that any asks for; remaking it empties
it. The layout of the words belongs to whoever writes and reads: the channels of an imported asset
store the asset's variables in their order.

## UI effects

A `Particles` node of a `.ui` asks on each frame it is shown for its effect in a texture
(`gui.UI_Effects`, which `gui` clears and fills;
[game UI](../../mirai-gameplay/references/libraries.md)).

- `particles_sync` gives each one its clock (`UI_Particles`, of the world), which advances with the
  frames and starts again, and adds it to the world's list as one more emitter, with its sub
  effect, without light, collision or fade, with relative color and `view`: it is drawn only in the
  `Effect` stage of that texture's effect view. One that was not asked for in a frame goes away
  with its particles.
- While the world's time is stopped and the UI shows effects, the world's emitters stay paused and
  the pool advances with the frames.

## Reports

`report` of an effect (or of its sub effect) names what the game hears from its particles: deaths
or hits, with position, velocity and normal, through the emitter's entity.

- The GPU writes them in the step they pass into a [data channel](#data-channels) of their own
  (`REPORTS_CHANNEL`, which exists while some emitter reports), and the CPU reads them frames later
  without waiting for it, as it reads a watched channel
  ([reads](../../mirai-rendering/references/views.md#extension-stages)): `Particle_Reports` has
  those of the last frame that finished, once each, placed in the world from the origin the head
  of the channel's copy stores. A frame stores `DATA_ENTRIES`; the rest are counted in `lost`.
- They are presentation (a decal, a sound, another effect): they are not deterministic or part of
  the world and decide nothing of the game. `Particle_Reports` is `presentation`: the generator
  rejects a `fixed` function that receives it
  ([generator](../../mirai-core/references/generator.md#attributes)).

Clocks (`Particle_Clocks`, of the world):

- One `Emitter_Clock` per emitter, in a `core.Entity_Map`; that of an emitter that left or lost its
  `World_Transform` is released from `core.changes`. It stores seconds of its generation,
  generation, pause and the numbered births it started (`emitted`), in `Particle_Birth`
  groups (first index, count, every how many, time of the first and spacing). It stores the last
  `PARTICLE_BIRTHS`; if they do not fit, it merges the two oldest without losing any.
- `particles_tick` (`fixed`, both loops, after `transforms_propagate`) takes the requests and
  advances the clocks: while playing, with `time.dt`; while not playing (the editor), with
  `frame.dt` and `preview`. A mode change restarts them: Play starts without those of the preview.
- `emission_step` adds the step's births: the rate, the bursts that the cycle reaches (the
  repetitions of a step in a group), the distance traveled and, on starting a generation with
  `prewarm` and `loop`, a whole life of earlier births. `emitter_capacity` gives the particles it
  needs.
- A copy, a Play and a rollback take the clocks.

Requests (`Particle_Requests`, a `core.Queue` of the world; `particles_tick` takes them in order):

- `start` and `stop` set and clear `Particle_Emitter.active`, which `particles_tick` alone writes
  for them (a stopped emitter lets its particles finish); `restart` (another generation: the GPU
  discards its particles), `pause`, `resume` and `burst(count)` (at the step's time) act on the
  clock. An emitter is emitting by its fields alone: `active` while playing, `preview` otherwise.
- `request_value` validates when asked, like `value_set`; it, `request_value_remove` and
  `request_values_clear`, applied, write `Particle_Override`.
- One for an entity without an emitter, or that the emitter does not take, is the `vfx.request`
  problem of that entity, with the `Error` and its `error_message`.
- `status(clocks, emitter, e)` gives where the clock of an emitter is.

To the GPU:

- `particles_sync` (`render`, both loops, after `render_sync`) builds each frame the world's
  emitters (`Emitter_Desc`: the resolved `Particle_Info` and what the frame resolves of it) with the
  births of its clock that it did not start and its age, and the seconds that the world advanced:
  those of its ticks while playing (a paused Play does not move its particles) and the frame in the
  editor. A rollback that repeats ticks does not start again what was started; one that started
  fewer starts what comes after.
- `Particle_Sync` is `@(storage,host,by_world)`: each world stores what it told the GPU about its
  emitters in a `core.Entity_Map` (`Emitter_Shown`: the `Emitter_Desc` of the emitter and of its
  sub effect, the needs of its program, started births, generation and pose), its pool and the
  pipelines of its stages, and releases the emitters that left from `core.changes`. The effect is
  resolved again (`shown_resolve`, the same for the world's emitters and the UI's) if the asset,
  its values or parameters, the shaders or the scene's vertices change.
- A new emitter starts at the current world pose and from the second frame interpolates the
  motion. `Emitter_Shown` keeps the previous pose even if the emitter is hidden or the application
  has no renderer.
- `Particle_Settings` (project setting): `capacity` (particles alive at once in a world). A
  capacity that the device does not take leaves the pool that there was and is the `vfx.capacity`
  problem, like an emitter that does not fit in the pool or in the emitter table, or a `sort` or
  `Ribbon` effect that needs more alive than `SORT_MAX`: its emitter is left with `SORT_MAX`.
- The sub effect of a `trigger` gets the room of the events of the effect's live particles: one
  each, or with `Trail`, those of a whole life of the sub effect at `TRAILS_PER_SECOND`.

## GPU

`plugins/vfx/runtime/gpu.odin` and the shaders of `plugins/vfx/shaders`.

### Pools and emitters

- One pool per world: its buffers (`pass_buffer`) belong to the renderer, under the world and the
  plugin's name; a world that is not drawn keeps its particles still, and `particles_release`
  (`release` phase) releases its own (`buffer_release`).
- `pool_emitters` receives each frame a world's whole list:
  - the pool's tables are built the first time the world gives emitters, and again, without its
    particles, if it asks for another capacity;
  - a capacity whose buffer exceeds what the device binds leaves the pool as it was; one that the
    device cannot create leaves it with the capacity it had, without its particles. Neither is
    retried;
  - a new `id` takes a range (first free gap; freed gaps join their neighbors) and starts empty; an
    `id` that is missing returns its range;
  - one that changes capacity or `generation` starts again.
- An emitter that does not fit in the pool or the table (`EMITTER_CAPACITY` per world) is left out.
- Nothing allocates in a stable frame: the pool's tables are built when it is created, the emitter
  table goes up to the frame memory once (`pass_rows_upload`) and all its passes bind it, and a
  program's parameters go up only when they change (`pass_buffer_write`).
- An effect field exists once: in `Particle_Info`, which `Emitter_Desc` carries as it is, and in
  the one place that packs it into the `Gpu_Emitter` row (`emitter_row`). The desc is built when
  the key of what it shows changes, the row only when its `revision` changes (0: every frame) or
  its range starts; each frame writes its place, its births, the step, its lights and its age, and
  uploads the table.
- `Gpu_Particle` and `Gpu_Emitter` are equal to `particles.slang`; the values that that file copies
  from the plugin (flags, types, sizes and capacities) are compared with those of Odin by a test.
  A pool's free and draw lists go in one buffer, and the programs' `Attributes` (those that their
  per-particle program declares) and their parameters in another.
- The functions of `particles.slang` and `particle_programs.slang` receive the emitter's slot and
  read from `particle_emitters[slot]` only the fields they use, like simulate: copying the whole
  row in each thread of a per-particle pass costs the registers and the reads of the whole row.
- Particles do not enter the BVH or the TLAS: they cast no shadow and do not appear in reflections
  or bounces.
- The places that their passes see are relative to the renderer's origin (`render/origin.odin`):
  those of emitters, resources, channel births and grid corners are subtracted when uploading
  them. The pool's particles and events store the origin they are at (`Pool.origin`) and, when the
  origin moved, the **shift** pass (`Geometry`, before every view) moves them once, with no visible
  motion; a world that was not drawn takes it on returning. Grids store absolute cells and locate
  a cell from the first one's corner (`Gpu_Grid.corner`). The reports and the particles that
  `particle.instance.inspect` copies return to the world adding the origin.
- A program also sees relative to the origin its emitter's transformation (`ctx.world`) and the
  view (`mirai_vfx_view`). Its `Attributes`, the words of its state and the entries of the data
  channels pass as they are: a place that they store is theirs to keep relative to the emitter or
  to another particle, because the shift does not touch them.
- The emitters of an effect view (`FLAG_VIEW`) have places of that view: the origin does not move
  them.
- The `finish` pass counts in the `particles` counters (`erender.counters`): those alive and the
  emitters that have any, two frames back.
- Asking for a world's passes is asking for them once per frame even if several lists arrive.

### Births and steps

- Each emitter gives its births in up to `SPAWNS` `Particle_Spawn` groups: count, how many per
  instant, index of the first, age of the first at the end of the frame and spacing between
  instants. A burst starts at one instant; a rate is spread.
- Each particle's seed comes from the emitter's and its birth index: the same particle has the same
  random values even if the frames change.
- A birth older than the frame (a prewarm, or a world that was not drawn) starts where its life took
  it, with the emitter's acceleration; one older than its life does not start.
- Lists that arrive without a simulating frame in between are added: their seconds, and their
  groups age with those of the following ones; if they exceed `SPAWNS`, the neighbors are merged
  without losing births.
- A frame simulates `dt` (up to `FRAME_MAX`) in steps of at most `STEP`, up to `STEPS`; each step
  starts the births that fall in it.
- It simulates the frame that a window view draws, or a texture-only one
  ([texture views](../../mirai-rendering/references/views.md#texture-views)); a `ui_only` one
  leaves what was asked for the next.
- A `paused` emitter keeps its particles as they are.

### Vfx programs

- An emitter can name a Vfx program (`Program`: catalog id and parameters); the contract is in
  `shaders/include/mirai_vfx.slang`
  ([Vfx domain](../../mirai-rendering/references/shaders.md#programs)). `Orbit`
  (`plugins/vfx/shaders/orbit.slang`) is the plugin's.
- `initialize` runs in emit, after the effect's values; `update`, on each step, before the effect's
  forces; `render`, in the sprite and mesh vertices. What `render` gives the material of a sprite
  (`visual.data`, with its bit in `visual.given`, and `visual.random`) reaches its Surface program;
  no data is given if it does not write it, and the random value comes from the particle's seed.
  `births`, of a program that declares `//! births`, runs once per frame in emit (mode 3, before the
  births), and its count replaces the effect's births, spread over the frame.
- Emit, simulate, stage, sprite and mesh have one pipeline per program in use, and one for the
  emitters without a program. Each dispatch goes from the first to the last slot that the emitters
  of its program have (in the pool or in the emitter table) and filters those of others; events are
  dispatched only for the programs of some destination emitter. The spans and pipelines are looked
  up again when a range, a program or a destination, or the shaders change.
- `particle.instance.inspect` copies the particles of the emitter it looks at with their
  Attributes, to debug a program: the editor part asks for that readback in a `Simulate` pass of
  its own (`editor/watch.odin`), so a game binary has none of it.
- The resource functions of `mirai_vfx.slang` are defined by `particle_programs.slang` over the
  emitter's resource rows (`ctx.emitter`), the areas buffer and the frame's channel births.

### Passes

In the `Simulate` stage, per step:

- **begin**: one thread per emitter; its counters, the dispatch that takes the previous step's
  events and the half of events that this step writes, empties. In the first, the new ranges with
  their dead slots and their free list filled (all of them, if the pool's buffers were made anew).
- **emit**:
  - the step's births, where the emitter was then (between `previous` and `transform`), or at a
    point of its surface with its normal, where the surface was, or of its bones, moved away from
    the bone up to the shape's radius;
  - the frame's channel births, in the first step;
  - an indirect dispatch starts those of the previous step's events in their destination emitter.
- **stage**: the programs' stages, k in order: over particles, one thread per slot; over cells, one
  thread per cell of each emitter and, after each iteration, the copy swap of its grid.
- **simulate**: one thread per slot of each program's span; `_hw` variant.
  - Program, acceleration, value-noise rotor with analytic derivatives (no sources), attractor and
    drag.
  - `World` collision with `trace_ray` and the triangle's normal. Only a particle that goes into
    the surface faster than the rest speed (and than twice what its acceleration gives it in the
    step) bounces and hits: event, report and lost life. Slower it stays on the surface without a
    hit, so a particle at rest is silent and keeps its life at any step. Friction takes tangent
    speed in proportion to the normal speed stopped (Coulomb), the same per second at any step.
  - Deaths to the free list; death, hit and `Trail` events ([ribbons](#ribbons)), and reports
    of those that the emitter's `report` names.
  - In the last step: the live ones to the draw list and, the `lit` ones, their light (sun with
    shadow ray, local lights without rays, probe volume and ambient), renewed for half of them each
    frame and stored as RGB with shared exponent.

Once per frame, in `Simulate`:

- **surface**: before the steps, the areas of the new surfaces, one group per surface.
- **stage** (clear mode): before the steps, the cells that entered the region of each grid that
  moved since the last time the GPU cleared them.
- **volume light**: after the steps, the light of the cells of each volume; `_hw` variant.
- **finish**: one group per emitter.
  - Sorted list in shared memory (bitonic, up to `SORT_MAX`): back to front, or a ribbon as
    [ribbons](#ribbons) says.
  - Indirect draw of what is alive and the counters.

In each view:

- **volumes** (`Blend`): the volumes' media, before the sprites.
- **sprites** (`Blend`): over the lit image, before TAA; the emitters from farthest to nearest.
  - `Billboard` (faces the camera, with rotation), `Velocity` (stretched according to `stretch`),
    `Horizontal` (plane in XZ) and `Ribbon` ([ribbons](#ribbons)).
  - `Mesh` particles whose material blends (alpha mode `blend`, `Emitter_Desc.blended`): their
    mesh with `particle_mesh_blend.vert` and the sprites' fragment, placed as in the G-buffer, so
    their color, opacity and curves fade them as a sprite's, additive or covering by alpha as the
    effect says; their texture is read through the material's map at the uv of their vertices,
    and a mesh without texture is whole. They are drawn in effect views too.
  - Material from the table. With a Surface program, each fragment runs it facing the camera (the
    `particle_sprite` pipeline with the program's fragment, `Stage_Pipeline_Desc.program`), with
    `uv0` in the flipbook frame, `uv1` in the next, the particle's color in `vertex_color` and what
    its particle gives (`particle_data`, `particle_given`, `particle_random` and its radius,
    `particle_radius`); an `unlit` program gives only its emission. The particle's color does not
    multiply what the program gives: it uses it as it likes, as a program uses a mesh's vertex
    color. Without a program, its base color texture is the flipbook, with a blend between two
    frames, tinted by the particle's color; without a texture, a soft disc.
  - `soft` fades against the scene's depth and near the camera.
  - A particle without light shows its color in nits or, with `relative`, the value that the
    exposed image shows (`emission_render_units`).
  - `Additive` adds radiance; `Alpha` covers with premultiplied alpha.
  - With glass in view, each fragment is drawn in the pass of its side of the nearest layer
    (`.Glass_Depth`).
- **effects** (`Effect`): the sprites of the emitters of a `Particles` node, in the effect view of
  its texture, with the same sorted list and the same pipelines; none of them is drawn in the
  world's views, and `Mesh` particles are not drawn in them but those whose material blends.
- **meshes** (`Gbuffer`): `Mesh` particles (but those whose material blends) in the G-buffer with
  `particle_mesh.vert` and the
  engine's fragment, or that of the Surface program of their materials, one draw per program
  (`pass_mesh_programs`): turned by their rotation about an axis of their own
  (`particle_rotation` of `particles.slang`), motion vectors from their velocity
  and the emitter's material or the mesh's, which the plugin tells the renderer each frame
  (`frame_gbuffer_mesh`) so that the views store their reflectance and their layers. Everything
  that follows lights, shades and reflects them. Each one draws without indices the level 0
  clusters of its mesh (`erender.mesh_draw_range`, `pass_draw_indirect`) and reads its vertices
  only through `geometry.slang`: the plugin asks each frame for the whole mesh (`frame_mesh_whole`),
  and a mesh with pages outside its root loads them all and does not release them while it is
  drawn, because the scene's cull does not see the particles.

### Particle lights

The particles of an emitter with `lights` are scene lights
([GPU lights](../../mirai-rendering/references/lights.md#gpu-lights)). Those of an effect with
`light_shadows` cast shadows within the shadow budgets, like the others; without it (the default)
they light everything within their reach, without shadow rays or a place in those budgets.

- Each frame, `particles_frame` asks for room for those of all the live emitters of the world, the
  ones that cast shadows and the ones that do not (`erender.lights_ask`, up to `LIGHTS_ASKED_MAX` of
  each class), and `pool_prepare` gives each emitter its share of that of its class, in the order
  of its slots (`light_share`, `Gpu_Emitter.lights`).
- Those that cast shadows are asked for with a box (`lights_box`): around each emitter, as far as
  its particles may go in their life at their fastest start or the fastest wind with the strongest
  pull on them; anywhere when they are born on a surface, on bones, in a channel or at the events
  of another emitter, or a program moves them.
- **lights** (`Simulate`, after **finish**): one group per share writes all its room
  (`erender.pass_lights`). An emitter with fewer alive than its share lights with all of them; with
  more, with those of even slots of its range, which keep their light while they live.
- A light is a sphere on the particle, of the color and opacity it shows (after its program) times
  `light_intensity` in candelas, with reach `light_range` and radius `light_radius` (0: half its
  size). A `lit` particle receives the light of the others and its own.
- Each group sorts its lights by a Z curve over the box of those of this frame and builds its tree
  by halves, each node what its lights give together, like the CPU tree.

## Ribbons

- A particle joins a ribbon (`flags` above `RIBBON_SHIFT`; 0, that of the emitter): that of the
  particle whose event started it (`particle_own_ribbon` of its seed), or what its program gives
  `particle.ribbon`. `Trail` makes an event each time a particle's age (before a hit takes life
  from it) passes a multiple of `1/TRAILS_PER_SECOND`, and at the end of each frame a leader:
  the events of the last step start their points after it, drawn in the frame, and the point of a
  leader lives until the next step, so a trail reaches its head.
- **finish** sorts a ribbon's list by its ribbon (as wide as the word leaves above the slot,
  `SORT_SLOT_BITS`), its age and its slot, so a burst keeps one order. Each segment within a ribbon
  takes the pieces its turn needs for straight pieces to stay within about a pixel of its curve at
  its distance (up to `RIBBON_PIECES`; none between ribbons), rising at once and coming down one a
  frame (kept in its first particle's `flags`); where the quads of each segment start goes in the
  lists quarter after the births, and the draw has their sum.
- The vertices of a segment find it by binary search and lie on the cubic that leaves each point
  along the mean of the directions to its neighbours (toward its one neighbour at an end), with
  width, color and light lerped; what each particle shows is kept by the last step and by its
  birth after the Attributes of its program (`RIBBON_LOOK_BYTES`), so no program runs per vertex.
- A death needs no state: the next frame's list joins the neighbours of a dead point.

## Verification

- `mirai test plugins/vfx/runtime/effect`: format, validation and value paths.
- `mirai test plugins/vfx/runtime` (with `MIRAI_VALIDATION=1` and `-define:ODIN_TEST_THREADS=1`):
  emission, requests, values, curves read as on the GPU, the values that `particles.slang` copies
  and the parts of the lights' place that each emitter takes, without a renderer (`vfx_test.odin`,
  `data_test.odin`), and on the GPU (`gpu_test.odin`), with the generation of the engine and plugin
  shaders that `mirai test` does in `.mirai/tmp/vfx-test-shaders`: births, steps, generations and
  pauses, events, pools per world, rejected capacity, ribbons (trails of two heads, curves, pieces
  and the order of two ribbons, `two_ribbons.slang`), programs, the `Surface` shape and a
  program that follows a moving surface (`testdata/stick.slang`), the `Bones` and `Surface` shapes
  with the rig of a mesh and a skeleton written in the test and a posed skin, `World` hits that
  fall to the floor and slide according to their friction, sprites that run the Surface program of
  their material with what their particle gives, its random value and its radius
  (`hand_over.slang`, `particle_data.slang`), stages over cells with iterations (`tally.slang`),
  splats that a stage stores (`spread.slang`), rays from a
  stage against a cube (`probe.slang`), read back with `pass_readback`, a volume that glows
  (`puff.slang`), particle lights with shadow that light the floor within their reach and not
  behind a cube, and without shadow, also behind it, a floor whose Surface program reads a grid's
  world texture (`count_ground.slang`), channel births and their rollback (`testdata/gather.slang`),
  reports, sprites behind a `fog` box dimmed by it and one in front of it not, all the modes
  around glass without validation errors and stable frames without allocating.
- `mirai test plugins/vfx/editor` (with `-collection:plugins=<root>/plugins`): the effects document
  (`document_test.odin`).
- In the demo editor, without a window and with validation: the physics gallery launches
  `physics_gallery/physics_burst.scene` (station 11 with `trigger` 1 and `simulation.start`), and
  `particle.*` creates, changes and controls effects
  ([methods](../../mirai-agent-api/references/methods.md#components-and-assets)); a `Surface` effect
  over a mesh and another bound to a sphere (`Particle_Bindings`) are seen in `capture`.
