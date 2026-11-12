# Foliage

Plugin `foliage` (`Runtime`, `Editor`, `Shaders`; depends on `physics`). It shows the foliage of a
scene without one entity per instance: it draws it with [instance batches][batches] and, far away,
with [impostors](#far-impostor-and-crown), makes it collide with one static body per resident cell
and stands it on the [ground](#ground) of the world.

[batches]: ../../mirai-rendering/references/scene.md#instance-batches

## Entity and source

- `Foliage{source, revision}` shows a `.foliage` asset in the entity's space; one asset per scene,
  like that of a [terrain](terrain.md). `revision` (read-only) is the key of the
  [tool](#tool)'s history, its sole writer: the runtime does not touch it, so undoing to revision 0
  of an imported level restores the source of that revision.
- `foliage_load` reads the sources through `host.assets_file` (with what the registry holds) and
  reads them again when the stamp of their file changes; one that cannot be read is the
  `foliage.source_unread` problem of its entity. `Foliage_Data` is copied with the world (Play,
  rollback).
- Each cell in memory has a version: reading the source again keeps that of the equal cells
  (`cells_version`) and gives the next one to those that changed; another seed or other types
  change all of them. What is built per cell compares that version.

## Format

[Assets](../../mirai-assets/references/formats.md) container, Fourcc `FOLI`, with the rows of
`source.odin`: `foliage` (seed, revision, next type id, ids given to manual instances), `types`,
`cells` of `CELL_SIZE` in x and z, and in packed bulk `manual` and `overrides`, by ranges of each
cell.

- `manual` and `overrides` are the byte planes of their records (byte j of every record, then
  j+1), each 4-byte word coded by its `Code`: the id from the one before it, the position and the
  point from the one before in its cell, the rotation with the low bytes of its components apart.
  Every bit comes back as it was, in the same order; `source_bytes` and `source_read` are the only
  writer and reader.

- A type has a stable `id` that is never reused and names a `.mesh` (with the materials of its
  slots that it changes, or those of the mesh) or a prefab, without converting them.
  `impostor_distance` (0: none) gives it a [far shape](#far-impostor-and-crown) and
  `wind_variants` (0: `WIND_VARIANTS`) the [wind variants](#wind) of one that casts a shadow.
  `offset` sinks or raises it and `rule` says where it stands ([layers](#layers-of-a-cell)). A file
  without those fields reads them as zero: no offset and with the rule off.
- A manual instance has an `id` of its own, from 1, unique in the source and never given again
  (`Foliage_Info.instances` counts those given): deleting or adding another in its cell does not
  change it, and it keeps it when moving to another cell. `source_instance_add` gives it,
  `manual_find` looks it up in its cell and `source_instance_remove` removes by it. The instance of
  an override carries 0; two with the same id, or one that the source did not give, are damage.
- A manual instance with `INSTANCE_GROUNDED` stores in `ground` its height above the ground where
  it was put, to reproject it when the ground changes. With `INSTANCE_ALIGNED` (only together with
  the other) its rotation is from the ground: it tilts with it according to the `align` of its
  type, also when it changes.
- An instance with `INSTANCE_COLORED` (manual, or of an override `Moved` or `Replaced`) stores in
  `color` its tint and wetness as `render.batch_color` packs them, which the Tint brush paints;
  without the flag `color` is 0. The batches of a cell carry the colors only where some instance
  has one ([batch colors](../../mirai-rendering/references/scene.md#instance-batches)).
- An override changes a generated instance by its id (type and point in its cell): `Deleted`,
  `Moved` or `Replaced`. In each cell they go in type and point order, without repeating:
  `source_override_set` inserts them in place, `source_read` sorts those of a file and
  `source_valid` rejects any other order.
- `source_read` validates everything before replacing the source; `source_bytes` writes only a
  valid source.

## Layers of a cell

`cell_expand` gives the instances of a cell: the manual ones; the generated ones if the cell has
`generate`; and over them the overrides, by id. The id of each one (`Placed.id`) names it in its
cell while the source has it: that of a manual is `MANUAL` and its own id; that of a generated
one, its type and its point (`generated_id`), stable while the seed and the type are the same
(lowering the density removes the last ids; another seed gives the same ids to other points, as
to the overrides).

- The generator (`scatter`) makes the points of each type from the seed, the cell and the type id.
  A point does not depend on how many there are (lowering the density removes the last ones and
  leaves the others where they were), and it only uses arithmetic, square root and the
  deterministic sine of std/math: it gives the same on every machine.
- Points and overrides come out in order, so each type walks its stretch once. An override whose
  id the generator no longer makes stays in the source as an orphan (problem `foliage.orphans`).
- A generated one stands on the [ground](#ground) and aligns with its normal according to
  `align`; where the ground is known and there is none (a hole), it is absent. From its stream,
  after the other values, it takes an `offset` in the range of its type along its y. A manual one
  (or a `Moved` or `Replaced`) with `INSTANCE_GROUNDED` stays `ground` meters above it and keeps
  its rotation, unless with `INSTANCE_ALIGNED` it tilts with the normal of the current ground like
  a generated one; without the mark or without ground it stays where it was put. In a world
  without ground the entity's y = 0 plane is the ground; in one with ground, a cell whose ground is
  not read yet or covers none of it shows no generated instance.
- **Placement rule** (`Foliage_Rule`, like `GroundSlopeAngle`, `Height` and the layers of an
  Unreal `UFoliageType`): on, `rule_allows` admits the ground whose slope (from the normal) and
  height fall in its ranges and, with `layers`, whose terrain layers add up to at least `weight`.
  Where it does not meet it, the generated one is absent, as in a hole: the ids of the others do
  not change. Without known weights (without terrain ground, or a terrain without layers) a rule
  with layers admits nothing.

## Ground

- `Foliage_Ground` (`World` storage) stores per `Foliage` a grid of heights per cell in its space
  (`Ground_Tile`, NaN where there is no ground) with its revision, and parallel to it the weights
  of the terrain layers at each sample (they add up to 255; all 0 where there is no ground or
  layers). Each grid has its samples per side; those of the same size share a `Ground_Pool`, from
  which a grid that changes size leaves by giving its place to the last one. `foliage_ground`
  writes it from [`core.Ground_Queries`](../../mirai-core/references/core.md#ground), without
  knowing who gives the ground (terrain), and raises the revision of what changes.
  `Foliage_Ground_Requests` carries the cells that someone needs before having instances there
  (the editor requests those of the brush). Without a ground provider no grid is written and the
  plane y = 0 of each `Foliage` is its ground.
- Each sample asks the probe along the down of the `Foliage` for the highest ground: `Ground` is a
  height and the weights of the layers there; `Empty` (a hole, a stroke the editor holds) and
  `Unloaded` (far from every viewer) leave it without ground, NaN; a grid where no sample is
  covered is removed, and a cell that generates there is the `foliage.no_ground` problem of its
  entity. The layers of the first ground read name what the weights of the owner are of.
- **Fine near, coarse far**: the grid of a cell is fine (the samples per side follow the spacing of
  the ground, `Ground_Query.spacing`, up to `SAMPLES_MAX`) near the [streaming sources][sources],
  with their hysteresis, up to where the meshes of their types are drawn and no more than
  `GROUND_REACH`, and where the editor requests it; far away it has `COARSE_SAMPLES` per side,
  asked `coarse`. Without sources all are fine. Those that cross the limit are read again when the
  sources move.
- It reads again only the cells under the boxes the ground announced since it last ran
  (`Ground_Queries.changed`), or all those of a `Foliage` that moves or arrives. The cells to read
  wait in a queue and are read `GROUND_TILES` per call, in jobs: a world that loads much ground and
  many `Foliage` at once keeps responding. A grid (heights and weights) equal to the previous one
  does not raise its revision, and a frame without changes reads nothing.

## Drawing

- `foliage_render` (`late`, after `transforms_propagate`) publishes one batch per cell and type
  with `render.batch_set` in the function's world, and stores them in `Foliage_Resident` (`host`,
  `by_world`), which removes them when the world is freed (`foliage_release`).
- Per cell (`Resident_Cell`): it rebuilds the batches of a cell when its version or the revision of
  its ground changes, and reuses its handles (`batch_set` on the same one); those of the others
  stay. It rebuilds all those of a `Foliage` when its entity moves or its source is another entry,
  and all of them when the renderer forgets the batches (`batches_epoch`) or a mesh, a material or
  a prefab that they show changes. A stable frame publishes nothing.
- The instances of a cell are grouped by type in one pass (`placed_group`, by count).
- The type gives mesh and materials (`render.batch_desc`), the distances, the ray flags and in
  `Batch_Desc.vertex.x` the hook's sway (`sway_amount`); `object_id` is the entity. Each batch has
  a role (`Batch_Role`): the mesh, a wind variant, the rest mesh for the rays that do not see the
  variants, or the crown. `resident_batch_find` returns it and `role_instance` translates the
  instance of a variant to its order in the type, for the picker.
- **Type built from a prefab** (no mesh): each `Mesh_Renderer` of the prefab that is on and not
  hidden, with its transform from the root (`prefab_parts`; the root's place is that of the
  instance), is a batch per cell, type and part with the composed transforms (`part_instance`).
  What `Batch_Instance` does not have (a shear, a mirror) is approximated; if it leaves out more
  than `PREFAB_ERROR` of the transform it is the `foliage.prefab_transform` problem, which says
  how to fix it. A prefab that cannot be read or has no meshes is `foliage.prefab`. With
  `Prefab` collision it also collides as its prefab ([collision](#collision)).
- A cell is drawn while it is resident through the [residency of the streaming
  sources](../../mirai-gameplay/references/libraries.md#sources-and-residency), with the farthest
  `cull_distance` of its types as its reach; a type that is never culled leaves all of them
  resident. One that stops being so releases its batches and its impostors. A `Foliage` has at
  most `RESIDENT_CELLS` resident, the nearest ones in reaches of their types; those that stay
  outside within reach are the `foliage.resident_cells` problem.

## Far: impostor and crown

A type with `impostor_distance` less than its `cull_distance` (or without it) has a far shape
(`far.odin`), one per asset it shows (mesh or prefab) and per world, made the first time a type
shows it and again when the mesh changes, like any cook:

- **Octahedral impostor** (Brucks): `render.impostor_capture` draws with the thumbnail renderer
  `IMPOSTOR_GRID`² frames of the upper half of the sphere, unlit: base color and coverage, normal
  and depth; two textures of the table with levels (`alpha_coverage` in the color). While it could
  not be made, the type is drawn with its mesh up to its `cull_distance`.
- **Bands.** The mesh fades between `impostor_distance` and `IMPOSTOR_BLEND` beyond it, and the
  impostor appears in the same stretch with the complement of the same pattern over the same box
  (`box_faded`): the instance stays whole, without pop. Far away the impostor fades with the
  type's `fade_distance` and `cull_distance`.
- **Drawing.** The `Gbuffer` stage draws one quad per instance toward the eye with a fragment of
  its own (`foliage_impostor.frag`): it blends the three neighboring frames of the direction, each
  moved by its depth, and writes color, normal and the depth of the leaves (`SV_Depth`), so it is
  lit and shaded like the scene. The instances of the resident cells go to a world buffer; nested
  views do not draw it.
- **Rays.** Per cell and type, according to the distance to the sources (`scene.resident`, with
  its hysteresis): near, the mesh batches; far, the crown (`crown_build`: the surface of the
  voxels dense in triangles, `CROWN_INSET` inside) as a `Casts_Shadow` and `Rays_Only` batch: the
  shadow rays see it (also those of the sun at the GI hits) and the probes and reflections do not.
  The impostor enters no ray structure.
- **Cell crown.** Past `CELL_CROWN_REACH` times the reach of the meshes of its types, a cell gives
  the rays a single crown instead of one per instance: `cell_crown_build` makes with `crown_build`
  the crown of the crowns of its instances that cast shadows, in the `Foliage` space, as a
  generated mesh of a one-instance batch. One entry of the ray structure per cell; the impostors
  remain per instance.
- `Foliage` is `@(component,far)`: when its section is not loaded it stays with these far shapes
  ([what is unloaded](../../mirai-gameplay/references/libraries.md#scene-references)). With
  `scene.Far_Kept` it draws only the types with a far shape and only that shape (impostors and
  crowns, never the mesh), without physics bodies. The crown of a cell is one per source, cell and
  version (`Shared_Crown`): the `Foliage`s of the same source trace the same mesh, each with its
  transform.
- **Budget.** A frame builds cells by `CELLS_A_FRAME` of cost (`CELL_COST` the one that publishes
  batches, 1 that of a `Foliage` that is not loaded) and takes `KINDS_A_FRAME` steps of far
  shapes: drawing the frames of an impostor (that frame builds no cells), or giving the renderer
  what its job made: the extended frames and their levels, and the crown with its geometry
  (`Kind_Bake`). The rest waits for the following frames (`Resident_Cell.stale`,
  `Resident_Owner.pending`), and the cells of a `Foliage` wait for the far shapes of their types.

## Wind

The wind is the `Wind` of [volume](../../mirai-gameplay/references/libraries.md#volume); a point
tilts with it `sway_amount` meters per m/s and meter of height above its instance's origin, by the
red of its vertex color (white: all), as `foliage_sway.slang` says. There are two paths with that
same function:

- **Type that casts a shadow: variants** (`wind.odin`). `wind_variants` deformable copies of each
  mesh, with their levels (`render.deformable_create`), which `foliage_sway.comp` writes in the
  `Geometry` stage and whose BLAS the renderer refits. Variant k turns the wind by its turn
  (2πk/n) and oscillates with its phase; each instance takes the one whose turn is nearest to its
  own (`wind_variant`), and tilts with the wind within half a step. Raster and shadow rays see the
  same variant; reflections, GI and probes see the rest mesh (`Ray_Visible` and `Rays_Only`
  batch). The wind is that of the first streaming source, up to `WIND_SPEED_MAX`: the variants' box
  contains it, so a frame of wind changes no boxes and marks no light, and the direct light is
  not reset by it. Without wind the variants stay still without writing.
- **Type without shadow: hook.** `foliage_vertex.slang` is the [vertex hook][hook] of its batches,
  with the wind of its place (`//! mirai frame Foliage_Wind_Frame foliage_wind`, written from the
  `Mask` stage relative to the origin of each view) and a phase per instance, from the world
  place. No ray sees it move.
- **Bending by bodies.** A `Foliage_Bender` tilts what moves in the hook (types without shadow:
  grass) away from its entity, `lean` radians at its center and nothing at half the largest side
  of the box its [`Volume`](../../mirai-gameplay/references/libraries.md#volume) is in, any shape
  (without one, as far as a bender reaches), rotated
  around the plant's place and by the red of its vertex color, like the wind. The `BENDERS` nearest
  to the first streaming source go in the constants of each view with where they were the previous
  frame, for the motion vectors. Radius and lean have a cap (`BEND_RADIUS_MAX`, `BEND_LEAN_MAX`):
  the hook batches carry in `Batch_Desc.reach` the most that the wind and a bender move a point
  (`hook_reach`), and the views cull them with those grown boxes. Types with shadow are not bent:
  their variants are shared by all the instances.

[hook]: ../../mirai-rendering/references/views.md#extension-hooks-and-constants

## Collision

- `foliage_physics` (between `physics_prepare` and `physics_places`) makes one static body per
  cell of each loaded `Foliage`, at the corner of the cell in the entity's pose, with the shapes of
  each instance of a type with collision on its ground, and rebuilds only the cells whose content
  or ground changed. The body's `user_data` is the entity and the shape's the instance id.
- **Shapes of a type** (`type_shapes`): its `Capsule` or `Box` of `size`, standing on the
  instance; with `Prefab` the `Box`, `Sphere`, `Capsule`, `Cylinder` and `Hull` colliders of its
  prefab with their own collision and their transform from its root; with `Hull` the convex hulls
  of its mesh, or of each mesh of its prefab. A primitive is scaled by the instance and the entity
  (`collider_scaled`: a capsule keeps its length from end to end); a hull is one slot of physics
  (`physics.owned_hulls`) that every instance scales and turns, kept in `Foliage_Physics.hulls`
  and given back once no shape uses it. A Mesh or sensor of the prefab, a type without what it
  collides as, or no room for hulls is the `foliage.collision` problem.
- **Every cell of a loaded Foliage collides**, however far from the streaming sources: an NPC or
  a shot on a server meets the trees far from every player, and the navmesh, built from the static
  collision, has the same obstacles wherever the players are. A `Foliage` kept for a section that
  is not loaded (`scene.Far_Kept`) collides with nothing. Physics_Settings must hold the shapes
  of every loaded cell; past them it is the `foliage.physics` problem.
- **Instances taken out** leave with their shapes alone (`collider_remove`): the body of the cell
  stays unless it has none left, and the navmesh rebuilds only around them. One put back builds
  its cell again.
- `Foliage_Physics` stores bodies and shapes with the world: a Play copy or a rollback carries
  both together. They are [owned bodies](../../mirai-physics/references/engine.md#owned-bodies) of
  physics. It does not run in a resimulated tick.

## Instances removed in play

What the game removes (felled, harvested, burned) does not change the source: it is world state,
like the [tombstones](../../mirai-gameplay/references/libraries.md#scene-references) of what
is destroyed in a section (`removal.odin`).

- `foliage_remove(requests, plant)` requests it with a `Foliage_Plant` (its Foliage, cell and id,
  `Placed.id`), as a pick of its batches gives it, `hit_of(physics, hit)` from a `physics.Hit`,
  or a query of the game (`query.odin`): `foliage_in_sphere` and `foliage_in_box` give the
  instances whose place is in an area of the world and `foliage_plant` where one stands and of
  which type, as the world shows them (on their ground, without what was taken out), with
  collision or not and however far from the players.
- `foliage_removals` fulfills it at the end that decides (alone, or the server; a client requests
  nothing), once per instance that the cell shows, grouped **by cell**: an entity with
  `Foliage_Removed` (`replicated`) hanging from the `Foliage` stores the cell, the count and the
  ids of up to `REMOVED_PAGE` instances removed from it, in the order in which they left. What is
  new in a cell goes to its entity with room, and what does not fit, to another. It names the
  `Foliage` by its `Id`, the same at each end and in each save: one without an `Id` removes
  nothing (`foliage.remove`). A tick without requests does not write the table.
- They are plain-data entities: the save stores them, Play and rollback copy them and a `Foliage`
  that stays for an unloaded section (`scene.Far_Kept`) keeps them with what hangs from it.
  Removing the entity returns its instances.
- **An id that the cell no longer has** (the source deleted that instance, or a manual one moved
  to another cell) removes nothing and is kept: it is what the game did, it costs nothing and it is
  not a problem, because changing the level under a saved game is expected. If the source restores
  it (an undo), it is left out again. A manual one moved to another cell in the source is seen
  again.
- `Foliage_Removals` orders them by `Foliage` and cell when the `Foliage_Removed` or `Foliage`
  tables change; drawing, impostors, crowns and collision rebuild only the cells whose removed
  instances changed (`removed_cell`), and the shared crown of a cell distinguishes what was
  removed from each `Foliage`.
- **Network**: `Foliage_Removed` is `replicated="object"`, so the server replicates each entity with
  `Simulation.Server` and `Audience.Always` without a `Replicate` of its own: one object per entity,
  not per instance, which reaches all connections. Its component is a [fragment][fragments] whose
  entries (`Removed_Instance` structs) have their own change bits: removing one more instance sends
  the count and its entries, and a connection that arrives later receives the whole cell with the
  creation, in parts if it does not fit in a datagram; an array of loose ids would be a single
  field, which is resent whole. The client makes it with its component and its foliage leaves it
  out. Each `REMOVED_PAGE` instances of a cell occupy one object of `Net_Settings.max_objects`.
- **Marks** (`marks.odin`): what play changes of how instances look (burnt, wet) is world state
  the same way. `foliage_mark(requests, plant, tint, wet)` asks it; `foliage_marks`, at the end
  that decides, keeps each instance once in an entity `Foliage_Marked` of its cell (up to
  `MARKED_PAGE`), changing its entry when it is marked again, so the network sends that entry
  alone. Saves, Play, rollback and `Far_Kept` keep them as removals; removing the entity gives the
  instances their look back. `Foliage_Marks` orders them by cell (`marked_cell`) and only the cells
  whose marks changed are drawn again; a mark goes over what the source paints. An id the cell
  does not show colors nothing and is kept.

[fragments]: ../../mirai-networking/references/networking.md#protocol-and-descriptors

## Tool

`Editor` part (`foliage_editor`), with G or its entry in the Tools menu, outside Play. It edits the
selected `Foliage`; without one it offers those of the scene and **New foliage**, a `.foliage` in
the registry's memory as a file of the undo step that creates it.

- **Types**: one card per type with its thumbnail and its instances, filtered by the search (part
  of the name, case-insensitive). The selected ones are those that Paint and Erase paint, as in
  Terrain3D (`types_click`): a click takes only one, Ctrl (Cmd) adds or removes leaving one, Shift
  takes the stretch of the list from the last one taken alone or added. The one clicked shows all
  its values (name, mesh, density, scale, turn, offset, rule, distances, wind, shadow and
  collision). Dropping a `.mesh` onto the types, or **Add to** in the menu of a browser mesh, adds
  one; dropping it onto a card changes the mesh of that type and keeps its instances. **Remove
  type**, or Delete with the pointer over the list, takes the selected ones with their manual
  instances and the overrides of their generated ones (`source_type_remove`), in one step.
- **Instances per type** (`Counts`): those shown by the edited `Foliage`, counted per cell over
  the source that `foliage_load` read, with its ground. Only the cells whose version or whose
  ground (for those that generate) changed are counted again, up to `COUNT_CELLS` per frame, and
  the total appears when none is left; a frame without changes counts nothing.
- **Live info** (folded at the start, as in Terrain3D): under the brush, place, cell and its
  instances, height of the surface and of the foliage ground, and slope.
- Modes (`foliage_modes.odin`), with keys 1 to 7. **Paint** puts under the ring manual instances
  of each selected type up to its density by Paint density (counting those already there and
  separated by half a step from it), lowered to the surface that the picker finds, where the type's
  [rule](#layers-of-a-cell) takes them, with the offset of their type, and `INSTANCE_GROUNDED` and
  `INSTANCE_ALIGNED` if they fall on known ground: the ground tilts them like the generated ones
  and realigns them when it changes. With **Ground only**, only on the ground (a terrain).
  **Erase** leaves of the selected types Erase density of their density, at random: manual ones
  leave their cell and generated ones with a `Deleted` override. **Place** puts one instance of
  the selected types, in turn, where it is clicked. **Reapply** gives the instances under the ring
  the scale, turn and offset of their type again (whatever their checkboxes mark), each one once
  per stroke. **Tint** gives them the tint and wetness of the panel, which the source keeps
  (`INSTANCE_COLORED`; a generated one by a `Moved` override where it stands); white and dry gives
  them their own look again. **Generate** turns on the generator of the cells whose square
  touches the ring and with Ctrl turns it off; turning it off removes the cell that has nothing else
  (`source_cell_generate`). It draws the nearby cells, in green those that generate.
- Keys like those of the [terrain](terrain.md#tool) (`editor.brush_adjust_*`, the same
  adjustment): `[` and `]` and F change the radius, Shift F the density of Paint or Erase, Ctrl
  swaps Paint for Erase. The ring follows the foliage ground where it knows it, yellow when
  placing, blue when removing and white when changing what is there.
- The brushes touch up to `BRUSH_RATE` times per second, like those of the terrain, and a fast drag
  also touches between two touches, every half radius. During the stroke the source is written in
  the registry's memory and the runtime rebuilds the touched cells; releasing confirms it as one
  step and Escape gives it back.
- **Select** takes with a click the instance of the batch that the picker gives (`batches=true`):
  alone, with Shift added and with Ctrl removed or added; a drag adds those of the selected types
  under the ring (with Ctrl, removes them), and **Select all of the types** takes all. The gizmo
  moves, rotates and scales the group around its center, or the single instance: a manual one
  changes in its cell or passes to another, with its id; a generated one becomes `Moved`
  (`Replaced` with another type), or `Deleted` and a manual one in another cell. What stays on the
  ground keeps its rotation from it (`INSTANCE_ALIGNED`): it looks as the gizmo left it and
  follows the ground. Delete removes them, End or **Stand on ground** stands them on the ground
  and **Type** gives them another type; each thing, one step. The type of the one taken with a
  click is left alone selected in the list and in view, even if the search had hidden it.
- **Undo**: the step stores the revision of the `Foliage`s; as in the terrain
  ([history](terrain.md#tool)), the tool stores the head of each source and each step only the
  cells, types and info that changed (`foliage_history.odin`); undo and redo change them with the
  head and `foliage_sync` writes it with `editor.file_set`. The file is rewritten when the step
  ends; one changed outside the tool (git, another tool) is taken as the current revision, without
  redo bringing back what it replaced.
- Radius, densities, Ground only and the Reapply checkboxes are stored in the editor preferences
  (`Foliage_Tool`).
- `foliage_cells` inspection mode (Advanced → Foliage): the outline of each cell near the view over
  its ground, green the one that generates and yellow the one that only has manual instances.
- **API** (`foliage_api.odin`): `foliage.create` (with `name`, for its entity and file beside the
  scene), `foliage.type_add` (a type by its mesh with
  the values it receives; its name is unique), `foliage.type_set` (the type by its name, the
  values it receives; the others stay; a rule's `layers` are materials of the terrain under it, as
  `Ground_Owner.layers` lists them), `foliage.type_remove`, `foliage.paint` (a paint, erase,
  reapply, generate or ungenerate stroke from `at` to `to`), `foliage.place` and `foliage.query`
  (types with their instances and instances inside a box), each change an undo step. They read
  the place and the ground of the `Foliage` as they are now: a manual editor runs the frames that
  read them.
- In the content browser, `Foliage_Kinds` and `Foliage_Thumbnails` list the `.foliage` and show
  them with a mesh of their types
  ([content browser](../../mirai-editor/references/panels.md#content-browser)).

## Verification

- `mirai test plugins/foliage/runtime` (CPU): cells
  (`cells_take_the_points_of_their_32_metres_including_negative_coordinates`), format
  (`a_foliage_asset_comes_back_as_it_was_written_and_damage_is_refused`), generator and overrides
  (`the_generator_makes_the_same_points_with_the_same_ids`,
  `overrides_change_their_generated_instance_and_orphans_are_kept`,
  `overrides_keep_the_order_of_type_and_point_and_are_found_by_it`), versions
  (`a_source_read_again_keeps_the_version_of_the_cells_that_did_not_change`), ground
  (`instances_stand_on_their_ground_and_generated_ones_leave_where_it_has_none`,
  `a_manual_instance_aligned_with_its_ground_leans_with_the_ground_that_changes`), rules and offset
  (`a_rule_of_slope_and_height_takes_out_the_generated_points_off_it_and_keeps_the_ids_of_the_rest`,
  `a_rule_of_layers_takes_the_ground_with_enough_of_them_and_none_where_they_are_not_known`,
  `a_generated_point_takes_an_offset_of_its_type_and_keeps_its_other_values`,
  `a_foliage_file_written_before_the_rules_reads_them_off_and_bad_rules_are_refused`), batches and
  prefabs (`batch_instances_carry_the_transform_of_their_entity`,
  `placed_instances_group_by_type_keeping_their_order`,
  `a_part_of_a_prefab_composes_with_its_instance_and_says_what_it_leaves_out`,
  `the_parts_of_a_prefab_are_its_shown_meshes_placed_from_its_root`), collision
  (`a_cell_collides_with_one_static_body_and_one_instance_leaves_alone`,
  `rocks_collide_as_one_hull_each_instance_scales`; the colliders of a prefab in
  `the_parts_of_a_prefab_are_its_shown_meshes_placed_from_its_root`), types
  (`a_removed_type_takes_its_instances_and_overrides_with_it`,
  `a_type_with_an_impostor_draws_its_mesh_up_to_its_distance`), crown
  (`a_crown_is_the_closed_surface_of_the_voxels_dense_with_leaves`) and wind
  (`an_instance_sways_with_the_variant_of_its_turn_and_downwind`,
  `the_instance_of_a_variant_is_found_among_those_of_its_type`).
- Ids of the manual ones: `a_manual_instance_keeps_its_id_through_the_edits_of_its_cell`.
- Resident cap: `past_their_budget_the_nearest_cells_stay_resident`.
- Instances removed (`plugins/foliage/runtime`):
  `instances_taken_out_are_one_entity_for_each_cell_that_the_cell_leaves_out`,
  `thousands_of_instances_taken_out_of_a_few_cells_are_a_few_entities` and
  `a_saved_game_takes_out_the_same_instance_after_its_source_is_edited` and
  `an_instance_taken_out_later_sends_a_small_part_of_its_cell`; what a game finds:
  `the_instances_a_game_finds_are_those_the_world_shows`; marks:
  `marks_of_play_are_one_entry_for_each_instance_of_their_cell`; that they reach a client:
  `an_entity_with_a_replicated_object_component_reaches_a_client` in `plugins/multiplayer/runtime`.
- Ground (`plugins/foliage/runtime`): `the_ground_of_foliage_is_read_where_the_ground_changed`.
- `mirai test plugins/foliage/editor -collection:plugins=<root>/plugins`:
  `foliage_strokes_and_selections_are_steps_of_undo_written_at_the_flush`,
  `a_move_of_an_imported_foliage_is_undone_back_to_revision_zero`,
  `a_canceled_stroke_puts_back_what_the_file_held`,
  `the_brush_fills_to_its_density_with_spacing_and_stands_on_the_ground`,
  `the_generate_brush_turns_on_the_cells_under_it_and_off_again`,
  `instances_placed_on_the_ground_lean_with_it_when_it_changes`,
  `the_search_finds_types_by_any_part_of_their_name`,
  `a_click_takes_one_type_ctrl_adds_or_takes_out_and_shift_takes_a_range`,
  `the_type_of_a_selected_instance_is_taken_alone_and_removed_types_leave_the_selection`,
  `instances_are_counted_by_cell_and_again_only_where_a_cell_or_its_ground_changed`,
  `erase_leaves_the_density_it_is_given_and_none_at_zero`,
  `generate_turns_on_the_cells_under_the_ring_and_ctrl_turns_them_off`,
  `a_step_keeps_the_cells_it_changed_and_trades_them_back`,
  `a_group_moves_together_and_an_instance_that_leaves_its_cell_keeps_the_others_named`,
  `reapply_gives_the_instances_the_scale_of_their_type_once_a_stroke`,
  `tint_paints_the_instances_under_the_ring_into_the_source`.
  Gestures (strokes, clicks, the gizmo) are tested by the user.
- `mirai test render` (CPU): `impostor_frames_cover_the_upper_hemisphere_and_fold_back`,
  `impostor_frames_spread_their_color_into_what_they_do_not_cover`,
  `a_batch_only_rays_meet_is_in_no_layer_and_the_picker_does_not_find_it` and
  `a_deformable_with_levels_keeps_the_levels_of_its_source_in_its_own_vertices`.
- What is seen (batches, fade into the impostor, wind, crown shadows) is verified in the editor of
  a project that enables the plugin (alien-planet), with GPU validation: the tests of the
  [batches](../../mirai-rendering/SKILL.md) and captures from close up and from more than 1 km.
  The plugin's shaders are compiled with `mirai shaders --project <project with foliage>`.
