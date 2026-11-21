# Particles: the `vfx` plugin

`plugins/vfx` (`Runtime`, `Editor`, `Shaders`): particle effects simulated, lit and drawn on the
GPU. Without the plugin enabled, neither the game nor the editor has particle code, state, passes
or shaders. It extends the renderer only through
[`engine/render`](../../mirai-rendering/references/views.md#extension-stages). The plugin's
editor (inspector, document, thumbnails and `particle.*`) is in [its reference](vfx-editor.md).

## Format

`plugins/vfx/runtime/effect` (`effect.PARTICLE_KIND` `PART`, `.particle`,
`effect.PARTICLE_VERSION` as the manifest declares it; another version asks to write it again).
An effect is like a material: entities name it (`vfx.Particle_Emitter`) and give it values of
their own (`vfx.Particle_Override`, fields and program parameters alike). The `particle` table
stores the primary layer followed by additional layers, each with its own `Particle_Info` and
program parameters. The `hidden` table is for the primary layer's instance fields.

- `Particle_Info` is the destination of what is imported from other engines; its fields and
  their units are in `effect.odin`. Besides them:
  - a constant `rate`: a program's `births` gives any other shape;
  - the shapes `Surface` and `Bones` take the triangles or bones of what the entity binds or
    draws ([surfaces and bones](#surfaces-bones-and-resources));
  - `gravity` and `drag` read the gravity (`Gravity`) and wind (`Wind`) where each particle is, the
    volumes bodies and foliage read, evaluated on the GPU
    ([volumes](../../mirai-gameplay/references/libraries.md#volume)); those of an effect view fall
    with `GRAVITY`;
  - a `Mesh` particle shows one of `meshes`, picked by `mesh_weights` when it starts (a
    program's `particle.mesh` may change it; `flags` from `MESH_CHOICE_SHIFT`), and turns as
    `facing` says: by its `rotation` (and `spin`) about an axis of its own, or with its front
    (-Z) along where it last went faster than `PARTICLE_MESH_FACING_SPEED` (kept in the bits of
    `flags` a ribbon has, so what rests does not turn), its +Y up, rolled by its rotation and
    scaled along each axis by its emitter; a sorted effect has one mesh (validation);
  - `Beam` draws a camera-facing strip from each particle to an endpoint offset in the emitter's
    axes. Its optional arc offsets the midpoint along the emitter's +Y axis.
  - the editor groups fields by their tags. Its layer controls select, add and remove additional
    layers. `particle.set` replaces the additional layer sequence when given `layers`.
- Curves and gradients use non-decreasing active times in [0, 1]. Zero times after the last
  active key are unused. Sampling past the last key holds its value.
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

A `Particle_Emitter` on an entity starts each layer of its effect, with a clock per layer. Start,
stop, restart, pause, resume and burst apply to the entity's layers. Start and stop set `active`
during Play and `preview` during Edit. In either world, `loop` controls repetition. Turning
emission off lets live particles finish. `destroy_when_done` removes the entity in Play after the
last layer and sub effect in its subtree finish. Events that name a sub effect target its primary
layer.

Without an asset, `Particle_Emitter.preset` selects starter values. Use
`effect.particle_preset` to read or adapt those values in code, or set `preset` in `particle.set`
to start an asset from them.

Values of an instance:

- `Particle_Override`: the entity's own values for the primary layer, shaped like
  `erender.Material_Override`: one
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
- `Particle_Bindings` chooses the surface or bones for the shape. Without a chosen entity, the
  shape samples what its own entity draws. A `Particle_Binding` binds one named program resource
  to an entity or grid. Put it on the emitter or name the emitter from a separate binding
  entity. The world indexes these bindings by emitter and resource name.
- A grid: that of the entity that binds its source or that of the world's grid it names (`grid`);
  without a binding, the first grid that its stages walk is that of the emitter's entity, if it has
  one, and any other that of the world with the resource's name. A binding to what does not exist
  reads nothing: it is not looked up elsewhere. So each fluid runs on its own and several emitters
  read different grids with the same program.
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
  the scene and through what the medium lets pass cell by cell toward it, the local lights as the
  fog takes them and the ambient one. It stores it in the world buffer, the same in every frame of
  a still scene, with no history: a light that turns on is whole in the frame it does.
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
  and `particles_sync` hands the GPU the births it has yet to start. Rollback copies the
  sequence and latest birth time. The host keeps a bounded history and GPU cursor for each
  channel with births, discards the replaced future on replay, and releases unlistened channels.
- A cone at a channel birth uses its nonzero normal as the cone axis.

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
  frames and starts again. It adds the layers and their sub effects with relative color and
  without light, collision or fade. They are drawn only in the
  `Effect` stage of that texture's effect view. One that was not asked for in a frame goes away
  with its particles. The host allocates records as interfaces request effects.
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

- `particles_sync` (`render`, both loops, after `render_sync`) gives the pool the world's emitters
  that changed ([pools](#pools-and-emitters); `Emitter_Desc`: the resolved `Particle_Info` and what
  the frame resolves of it) with the births of its clock that it did not start and its age, and the
  seconds that the world advanced:
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
- A frame does only what changed. `particles_sync` tells the pool (`pool_put`) only of the
  emitters whose emitter, values, place, hiding, bindings or channel changed (`core.changes` of
  those tables), whose clock started births, restarted or paused since, or whose effect reads
  otherwise in the assets; an emitter that did not change costs nothing but the look at its clock.
  The clocks are written every tick, as their time goes, so it is the one thing compared for all.
  Those whose frames give something every time are told every frame: a program (its age), the
  resources or stages it reads, the births of its channel, or a place drawn between two ticks.
- Resolved effect and program values are shared by emitters with the same values. A host-side
  cache tracks an asset's inputs, including its layers and sub effects. Rollback snapshots hold
  compact emission data and clocks. Moving emitters update their live pose and birth data
  through the pool's indexed slots.
- An emitter that is hidden leaves the pool. On removal its world-space particles can finish
  in an orphaned slot.
  - `pool_frame` starts each frame; the pool's tables are built when the world first has
    emitters, and again, without its particles, for another capacity. `particles_sync` then puts
    every emitter again (`Pool.made_count`);
  - a capacity whose buffer exceeds what the device binds leaves the pool as it was; one that the
    device cannot create leaves it with the capacity it had, without its particles. Neither is
    retried;
  - a new `id` takes a range (first free gap; freed gaps join their neighbors) and starts empty;
    one that changes capacity or `generation` starts again.
- An emitter that does not fit in the pool or the table (`EMITTER_CAPACITY` per world) is left out
  and tried again the next frame.
- The table of emitters lives on the GPU (`Pool_Buffer.Emitters`) and the GPU keeps the rows it was
  given: a frame builds and writes (`pass_buffer_write`, in runs of neighbors) only the rows that
  were put, the slots that were freed, and the rows whose births, start or previous place go back
  to rest after the frame that simulated them. All of them when the pool's buffers were made or the
  renderer's origin moved. What every emitter shares in a frame (the step, the births of the
  channels, where the reports go) is in `Gpu_Frame`, first in the rows of the frame.
- Nothing allocates in a stable frame: the pool's tables are built when it is created, and a
  program's parameters go up only when they change.
- The GPU row packs static effect values when they change and frame values as needed. The
  resource and stage uploads stop at the last active row. Gravity and wind live in a persistent
  buffer and are uploaded when their values or origin change.
- The free, live and draw lists have a buffer of their own. The arena after the draw records
  grows on demand for program attributes and birth lookup slots. Growth preserves existing
  GPU state. A birth lookup is kept for a source emitter once a program requests it.
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
  view (`mirai_vfx_view`). For attributes that store world-space points, declare `//! rebase`
  and write `void rebase(float3 origin_shift, inout Attributes a)`. The shift adds its delta
  once per surviving particle, including paused particles. State and data-channel words can use
  coordinates relative to their emitter or another particle.
- The emitters of an effect view (`FLAG_VIEW`) have places of that view: the origin does not move
  them.
- The `finish` pass counts in the `particles` counters (`erender.counters`): those alive and the
  emitters that have any, two frames back.
- Each kind of pass marks one GPU interval (`particle begin` ... `sprites`; `particle steps`
  after the first step): time per pass, not per emitter, as a pass goes over every emitter.
- Asking for a world's passes is asking for them once per frame even if several lists arrive.

### Births and steps

- Each emitter gives its births in up to `SPAWNS` `Particle_Spawn` groups: count, how many per
  instant, index of the first, age of the first at the end of the frame and spacing between
  instants. A burst starts at one instant; a rate is spread.
- Each particle's seed comes from the emitter's and its birth index: the same particle has the same
  random values even if the frames change.
- A birth older than the frame (a prewarm, or a world that was not drawn) starts where its life took
  it, with the emitter's acceleration; one older than its life does not start.
- Frames given without a simulating frame in between add up: their seconds, and the births put in
  them age with those of the following ones; if they exceed `SPAWNS`, the neighbors are merged
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
  forces. `render` fills draw records after the final step. What it gives the material of a sprite
  (`visual.data`, with its bit in `visual.given`, and `visual.random`) reaches its Surface program;
  no data is given if it does not write it, and the random value comes from the particle's seed.
  `births`, of a program that declares `//! births`, runs once per frame in emit (mode 3, before the
  births), and its count replaces the effect's births, spread over the frame.
- Each program in use supplies emit and simulate pipelines. Programs with stages supply their
  stage pipeline. Emit and stage get hardware tracing variants when they use tracing. Declare
  `//! use trace` when an included helper calls the trace function. Mesh and sprite vertices
  consume the cached draw record and share their vertex pipeline across Vfx programs.
- [Debugging](vfx-editor.md#debugging) reads through `emitter_ranges`, in editor passes only.
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
- **finish** writes counters and indirect draws. The sort pass orders ribbon points and groups
  mesh choices. Groups sort tiles in shared memory and merge them through the pool's scratch
  list, covering the whole live range.

In each view:

- **volumes** (`Blend`): the volumes' media, before the sprites.
- **sprites** (`Blend`): over the lit image, before TAA; the emitters from farthest to nearest.
  - `Billboard` (faces the camera, with rotation), `Velocity` (stretched according to `stretch`),
    `Horizontal` (plane in XZ), `Beam` and `Ribbon` ([ribbons](#ribbons)). The blended pass sorts
    flagged emitters back to front using the current view's direction.
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
  - An unlit particle's color uses its effect's emission units. A material's emission uses the
    material's own units regardless of particle lighting.
  - `Additive` adds radiance; `Alpha` covers with premultiplied alpha.
  - With glass in view, each fragment is drawn in the pass of its side of the nearest layer
    (`.Glass_Depth`).
- **effects** (`Effect`): the sprites of the emitters of a `Particles` node, in the effect view of
  its texture, with the same sorted list and the same pipelines; none of them is drawn in the
  world's views, and `Mesh` particles are not drawn in them but those whose material blends.
- **meshes** (`Gbuffer`): `Mesh` particles (but those whose material blends) in the G-buffer
  ([mesh particles](#mesh-particles)).

## Ribbons

- A particle joins a ribbon (`flags` above `RIBBON_SHIFT`; 0, that of the emitter): that of the
  particle whose event started it (`particle_own_ribbon` of its seed), or what its program gives
  `particle.ribbon`. `Trail` makes an event each time a particle's age (before a hit takes life
  from it) passes a multiple of `1/TRAILS_PER_SECOND`, and at the end of each frame a leader:
  the events of the last step start their points after it, drawn in the frame, and the point of a
  leader lives until the next step, so a trail reaches its head.
- The sort pass orders ribbon points by ribbon, age and slot, so a burst keeps one order.
  A segment takes enough pieces to approximate its curve within about a pixel at its distance.
  The piece count rises immediately and falls gradually. The scratch list stores each segment's
  first quad, and the draw takes their sum.
- The vertices of a segment find it by binary search and lie on the cubic that leaves each point
  along the mean of the directions to its neighbours (toward its one neighbour at an end), with
  width, color and light lerped; what each particle shows is kept by the last step and by its
  birth after the Attributes of its program (`RIBBON_LOOK_BYTES`), so no program runs per vertex.
- A death needs no state: the next frame's list joins the neighbours of a dead point.

## Mesh particles

- They are drawn with `particle_mesh.vert` and the engine's fragment, or that of the Surface
  program of their materials: a draw per mesh of the emitter and program (`pass_mesh_programs`),
  the mesh in its parameters, whose first instance is where `finish` put the run of the list of
  that mesh (through the scratch quarter of the lists, for more than one mesh), turned as their
  effect says (`particle_mesh_rotation`), with motion vectors from their velocity and the
  emitter's material or the mesh's, which the plugin tells the renderer each frame
  (`frame_gbuffer_mesh`) so that the views store their reflectance and their layers. Everything
  that follows lights, shades and reflects them.
- Each draw takes the level 0 clusters of its mesh indexed by where the frame lists it among the
  meshes drawn whole (`pass_indices(.Meshes)`, `pass_draw_indexed_indirect`, the draws `finish`
  writes after the events from `Mesh.draw_first`, `MESH_DRAWS_AT`; weights and meshes are in the
  emitter's row) and reads its vertices only through `geometry.slang`: the
  plugin asks each frame for the whole mesh (`frame_mesh_whole`), and a mesh with pages outside
  its root loads them all and does not release them while it is drawn, because the scene's cull
  does not see the particles. What a program's `render` gives does not reach them.

## Verification

- `mirai test plugins/vfx/runtime/effect`: format, validation and value paths.
- `mirai test plugins/vfx/runtime` (with `MIRAI_VALIDATION=1` and `-define:ODIN_TEST_THREADS=1`):
  emission, requests, values and curves read as on the GPU and the values that `particles.slang`
  copies, without a renderer (`vfx_test.odin`,
  `data_test.odin`), and on the GPU (`gpu_test.odin`), with the generation of the engine and plugin
  shaders that `mirai test` does in `.mirai/tmp/vfx-test-shaders`: births, steps, generations and
  pauses, events, pools per world, rejected capacity, ribbons (trails of two heads, curves, pieces
  and the order of two ribbons, `two_ribbons.slang`), programs, the `Surface` shape and a
  program that follows a moving surface (`testdata/stick.slang`), the `Bones` and `Surface` shapes
  with the rig of a mesh and a skeleton written in the test and a posed skin, `World` hits that
  fall to the floor and slide according to their friction, sprites that run the Surface program of
  their material with what their particle gives, its random value and its radius
  (`hand_over.slang`, `particle_data.slang`), stages over cells with iterations (`tally.slang`),
  splats that a stage stores (`spread.slang`), mesh particles that pick their meshes by weight
  and face their velocity, rays from a
  stage against a cube (`probe.slang`), read back with `pass_readback`, a volume that glows
  (`puff.slang`), a floor whose Surface program reads a grid's
  world texture (`count_ground.slang`), channel births and their rollback (`testdata/gather.slang`),
  reports, sprites behind a `fog` box dimmed by it and one in front of it not, all the modes
  around glass without validation errors and stable frames without allocating; for debugging,
  one interval per kind of pass, the ranges of each emitter against its counters and the
  Attributes of a program where the catalog names them (`glitch.slang`).
- `mirai test plugins/vfx/editor` (with `-collection:plugins=<root>/plugins`): the effects document
  (`document_test.odin`).
- In the demo editor, without a window and with validation: the physics gallery launches
  `physics_gallery/physics_burst.scene` (station 11 with `trigger` 1 and `simulation.start`), and
  `particle.*` creates, changes and controls effects
  ([methods](../../mirai-agent-api/references/methods.md#components-and-assets)); a `Surface` effect
  over a mesh and another bound to a sphere (`Particle_Bindings`) are seen in `capture`.
