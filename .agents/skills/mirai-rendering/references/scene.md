# Renderer and scene (`render/`)

## Renderer

- `renderer_init(r, Renderer_Desc)` receives device, drawable, settings, an optional shader
  generation, the allocator of its tables and its capacities.
- Whoever uses the renderer (`host`, the editor) delivers the scene with `mesh_add`,
  `materials_set`, `texture_add` and `scene_set`, and the extensions their
  [passes](views.md#extension-stages); each frame with `renderer_frame`.
- `renderer_frame(r, Frame_Desc)` records a single command buffer that the RHI submits without
  waiting for the GPU. Frame fields: [views](views.md#frame-and-views) and
  [UI, panels and lines](ui.md#ui-world-panels-and-debug-lines).
- Neither stable scenes nor the UI create GPU resources or allocate Odin memory.
- `renderer_resize` receives physical size, UI scale and native density separately: the scene
  applies its resolution ([resolution](settings.md#scene-resolution)) and the UI goes from points
  to pixels with the content scale
  ([units](../../mirai-platform/references/platform.md#display-scale)).
- `renderer_stats`: [statistics](frame-graph.md#statistics).

## Scene and instances

- `mesh_add`: static geometry, load transaction. `materials_set`: material table. `texture_add`:
  see [textures](materials.md#textures).
- `scene_set(r, instances, lights, sun, environment)` replaces instances, lights and environment.
  It pairs each instance with the previous one by identity (object and copy) and marks the light
  change only around those that appear, disappear or show something else (transform, mesh,
  material, tint, emission, flags; not the highlight); lights, sun and environment mark their own.
  A `mesh_add` marks nothing: no instance shows the mesh yet.
- **Without memory** `scene_set`, `scene_update`, `scene_set_lights`, `materials_set` and
  `materials_update` take the room of all they write before they change anything: they return
  false with the scene as it was and the reason in `Renderer.error`, and the caller gives the
  same again in a later frame.
- What changes afterwards enters without replacing the scene
  ([partial changes](#partial-scene-changes)).
- **Transform without an inverse.** An instance whose transform has no inverse (zero scale on some
  axis, or a value that is not finite) is neither drawn nor traced: it is hidden
  (`INSTANCE_FLAG_COLLAPSED`) with a finite box, without inverse or hardware transform. Without an
  inverse the rays cannot enter its mesh, and with a NaN the software BVH traversed it whole for
  each ray that reached its leaf. A `scene_move` that gives it one shows it again, unless it is
  hidden by its description or its mesh is still uploading
  ([several frames](#geometry-over-several-frames)).
- **Anchor.** `Instance_Desc.anchor` is the world place its transform starts from (zero: that of
  the world). What a camera carries arrives from the camera's place
  (`engine/render.camera_carried`): the renderer adds it when subtracting its origin, in f64, and
  f32 stores it at the pace of its size and not that of the world place, which at 16 km is a
  millimeter. `scene_move` receives the anchors of what it moves.
- **Highlight.** `Instance_Desc.highlight` is an outline level: 0 none, the editor's 15 and then
  the game's 15 styles. `Highlight_Style` gives color, fill and what is seen behind for each level,
  and the width of its side. The renderer does not know the selection or the editor tools
  ([outlines](frame-graph.md#outlines)).
- **Pools.** Geometry lives in two pools of u32 words: the vertex one (the block of each page of
  each mesh, with the layout of `asset.mesh_page_layout`: vertices, UV1, colors, surface and
  triangles of the page; and the posed vertices of skins and deformables, by mesh vertex index) and
  the index one (clusters, page table, levels, the material word of each slot, the primitive tables
  of the native BLAS and the batch instances). A mesh is one block of each, with those of its pages
  following in its order; its row of the mesh table (`Gpu_Mesh`) gives where each part starts.
  Instances, materials and lights are indexed buffers; the material textures are in the
  [texture table](rhi.md#bindings-and-texture-table).
- **Pages.** The vertices and triangles of a cluster are read only through the entry of its page
  (`Gpu_Mesh_Page`: base in the vertex pool, `GPU_NONE` if it is not there, and first vertex,
  vertices and first triangle word of the mesh that it holds), never from the whole mesh: on the
  GPU with `page_at` and `cluster_block` of `geometry.slang`, and by vertex index with
  `mesh_vertex_page`; on the CPU with `pooled_cluster`, which gives the page geometry to the
  `asset` decoders, and `record_decode` for whoever wants the whole mesh. Both also read the pages
  that are not in the pools: they decode them from their compressed blocks into a renderer
  scratch.
- **Pages by distance** (`render/pages.odin`). A mesh with the blocks of its pages (`page_data`:
  from a file, or made in memory and compressed with `asset.mesh_pages_pack`, like the distant one)
  whose root is not the whole mesh (`root_page > 0`) is *streamed* (`MESH_FLAG_STREAMED`): its block
  holds only the root pages and the others start at `GPU_NONE`; the renderer keeps in its
  `Mesh_Stream` its pages, their compressed blocks and the parents of each page, and whoever
  registered it can release its geometry. What is made in memory without `page_data` always has
  all its pages.
  - **Slots.** The first streamed mesh reserves once, through `pool_room`, a region of the vertex
    pool of `Settings.page_pool_bytes` in slots of `MESH_PAGE_WORDS` words. The CPU copy of a slot
    is the decoded block of its page, and it is published like any dirty range. Without memory for
    the region there is no streaming: those meshes draw their root and `Stats.problem` says so.
  - **Cull rule.** For a streamed mesh `cull_clusters` draws a cluster if its page is there, the
    error of its parent is not within the threshold, and its own is or the page of its children
    (`child_page`) is not there; in that case it requests that page with the pixels of its error,
    before the occlusion test. The instance's level range goes up to the coarsest, and each drawn
    cluster stamps its slot with the frame. The requests (fixed-capacity list; what exceeds it is
    counted) and the stamps come back through readbacks `MAX_FRAMES_IN_FLIGHT` frames later. The
    other readers without a cull (glass, particles, outline) skip the clusters whose page is not
    there; the outline draws the finest there is.
  - **Invariant.** A page is in the pools only if all the pages that have its parents are: it
    loads only with its parents present and does not leave while it has loaded children. This way
    what the cull draws covers the mesh exactly once. A fine group can be a child of clusters from
    several pages and the view request it from just one: a request with missing parents loads
    first the missing parent whose own parents are there.
  - **Loading.** Each frame deduplicates the requests (the higher priority stays), sorts them and
    loads the most requested up to `PAGE_LOAD_WORDS` decoded words, in jobs if the renderer has a
    `Job_System` (`Renderer_Desc.jobs`, that of `host`) and otherwise on the calling thread. The
    slot is a free one or that of the page drawn longest ago that was not stamped in `PAGE_KEEP`
    frames, has no loaded children, is not a parent of the one loading and is not in a ray cut
    that an instance traces. Releasing it leaves its entry at `GPU_NONE`. A stable frame does not
    allocate.
  - If for `PAGE_SHORT_FRAMES` consecutive frames requests are left without room, `Stats.problem`
    says `page_pool_bytes` is lacking.
- **Clusters.** A mesh arrives in the clusters of `.mesh` v6
  ([format](../../mirai-assets/references/kinds.md)): up to 128 triangles of one slot with their
  own vertices, local u8 indices and position and UV on power-of-two grids of the mesh, so two
  clusters that share a vertex place it at the same spot. The shaders read vertices, triangles and
  posed vertices only in `geometry.slang` and `posed.slang`; the CPU, with the `asset` decoders
  (`cluster_vertex`, `mesh_level_decode`) over each page.
- **Levels.** A static mesh is a DAG of clusters; one with skin or pruned foliage, whole levels
  whose clusters share the mesh sphere. Both are drawn with the same cut (`cut.slang`,
  `cluster_in_cut` on the CPU): a cluster enters when its projected error is within
  `lod_error_pixels` and that of what replaces it is not.
- **Detail of another camera.** The error is projected from `Gpu_Frame.detail_eye`, the eye of
  the view unless `Frame_Desc.detail` holds a camera: then the views of the window take from it
  the levels of the meshes, the cuts rays trace and the levels of the textures, while visibility
  and the image stay those of their own camera. It is what a paused game saw, kept while the
  editor looks closer.
- The G-buffer is drawn with one non-indexed indirect draw per phase, whose instance count is
  written by the culling: one instance per visible cluster, which the vertex shader reads from the
  visible list ([culling](frame-graph.md#passes)). No binds per material or per object.
- `mesh_add` encodes vertices and indices with `asset.mesh_build` at one level and registers them
  with `mesh_add_geometry`, which takes the geometry from a file or that made earlier in a job
  (`host.assets_render_geometry_make`) with its ray cuts. The meshes made at runtime
  (`host.assets_mesh_generate`, shapes) take the tangents from `geom.corner_tangents` and repeat a
  vertex at UV seams. Renderer, imports and plugins encode normals and colors with the functions
  of [std/math](../../mirai-std/references/math.md).
- **Distant mesh.** That of an unloaded section (`asset.mesh_build_far`, published with
  `host.assets_mesh_publish`) has no textures: each vertex carries the mean color, roughness,
  metallic and emission of its cluster (`Surface_Vertex`, `MESH_FLAG_SURFACE`, two words per vertex
  after the colors of its page). `geometry.slang` gives them in `Mesh_Point.surface`; the G-buffer
  and the ray hits add its emission to that of the instance and put its roughness and its metallic
  over those of the material (`material_surface_apply`), a single one, that of row 0. Its surfaces
  go in the block of each page: it is paged like any streamed mesh.
- The registered geometry is immutable.

## Partial scene changes

`scene_set` rebuilds the instance table, their boxes, the software TLAS and the lights, and uploads
the whole tables: it is used when what is drawn changes. For the rest:

- **`scene_move(r, descs, transforms, anchors)`** moves instances of the last `scene_set`: `descs`
  are positions in the list it received and `transforms` the current transform of each one.
  - The previous transform becomes the previous one: the next frame draws the motion and the
    following one uploads them at rest.
  - It updates instance, its box, the scene box and the hardware TLAS instance, which is rebuilt
    on the GPU.
  - The software tree is refit (`tlas_refit`: each node takes the box of what lies below it) and
    is built again only when the sum of surfaces of its nodes exceeds `TLAS_REFIT_SLACK` (1.5)
    times that of when freshly built. The rays find the same surfaces as after a `scene_set`.
  - It returns `false`, without changing anything, if the lists differ in length or name an
    instance that the set did not have.
- **`scene_tint(r, descs, tints, emissions)`** changes only tint and emission.
- **`scene_update(r, first_desc, instances, truncate=false)`** replaces a range of descriptors,
  can append at the end and, with `truncate`, remove the suffix that follows the range.
  - It keeps indices and rows of others. It updates geometry, materials, opaque/blend flags,
    overlays, highlight and bounds with the same instance builder as `scene_set`.
  - With the same count it uploads the touched rows; the tree is refit only if geometry or
    transform changed, and its references are reclassified only if the ray class or the
    visibility changed. Changing alpha within the same class does not touch the tree.
  - When the count changes the tree is built again and the table is uploaded.
  - What the tree asks for (building, reclassifying or refitting) `tlas_settle` does once, when
    uploading the scene in the frame, whatever the calls before: each one alone would traverse
    all the instances. Until then the tree is the previous one. Whoever adds or removes many
    instances in a frame gives them in few calls: `render_sync` gathers those that leave and those
    that arrive.
  - Each mesh carries the doubly linked list of its instances: one leaves it without traversing
    it.
  - It returns `false` without mutating if the range or a mesh is invalid, or if the last
    `scene_set` omitted descriptors because of invalid meshes.
  - It neither modifies nor refits a geometry BLAS.
  - It marks the light change around each touched instance, before and after, like `scene_tint`;
    not in the whole scene. The reach is its box plus `LIGHT_CHANGE_SIZES` (10) times its radius,
    up to `LIGHT_CHANGE_REACH` (8 m): its shadow and the light it reflects fall with the square of
    the distance over its size. An instance that glows, or whose brightness changes, marks the
    whole `LIGHT_CHANGE_REACH`.
- **`scene_set_lights(r, lights, sun, environment)`** replaces lights, sun and environment; it
  touches neither instances nor their tree. While each index names the same light it refits the
  light tree and uploads only what changed ([light tree](lights.md#light-tree)).
- **`scene_set_highlights`** and **`scene_set_environment`** change highlights and environment.
- **`materials_set(r, materials)`** replaces the material table and
  **`materials_update(r, materials, rows)`** changes only the rows `rows` (row `n` takes
  `materials[n - 1]`). Both compare row by row:
  - An equal row does nothing; another uploads alone, as a range of the table, with the next frame.
    Past `MATERIAL_RANGES_MAX` ranges the whole table is uploaded.
  - BLAS, TLAS and lights are kept. The instances are reclassified only if the class of a row
    changed (alpha mode, program, reflectance, layers).
  - The GI is woken only if something the world light sees changed (everything except the
    occlusion intensity and, without a program, the normal map), and only around what shows those
    rows (`materials_lit`): each instance that shows them in a slot or a layer, with its box plus
    `LIGHT_CHANGE_REACH`, and each light rectangle that shows its emission. Past
    `MATERIAL_LIT_ROWS` rows, or `LIGHT_CHANGES_MAX` marks, it changes across the whole scene.
  - A row beyond the table enlarges it with the default material.
- **Upload.** The instances a partial change touches go alone, in runs of the table, however many
  they are (`Scene_State.touched`, a bit per instance); the whole table goes with `scene_set`, a
  change of the instance count and what rewrites every row. What moved goes once more, at rest,
  with the frame after. Tracing in software, after a movement the tree nodes are uploaded, and
  the references only if it was built again; with hardware RT the tree is not uploaded.

## Visual instances

- An entity can contribute several instances. `Instance_Desc.copy_owner` and `copy_variant`
  separate their transform histories; at zero they identify the original. The GPU object ID is
  still the origin's.
- `uniform_color` omits the vertex colors as tint and keeps the tint, the same in raster, hits and
  shadow filters; a program still reads them as data. A translucent white copy is this flag with a
  white blend material and shares the resident geometry.
- **Replacement** (`host.extras_instance_add` with `replace_source=true`): visually substitutes the
  world mesh with the same `object_id`; `engine/render` hides the base sent to the GPU and when it
  stops delivering it, draws it again. It uses `scene_update` without extracting the world again;
  it does not change picking, colliders, scenes or undo; with `hidden=true` it also hides its
  source.

## Instance batches

`render/batch.odin`. A batch is many instances of a mesh with their materials, without a row of
the instance table for each one: the same cull, the same G-buffer and the same rays as the scene
instances.

- **`batch_set(r, handle, world, Batch_Desc, instances)`** creates a batch (`handle` 0) or replaces
  the one it names, which keeps its handle. Load transaction. On invalid input (a mesh that does
  not exist, non-finite position or scale, negative distances) it returns an error that says how
  to fix it and changes nothing. **`batch_remove`** removes it; a removed handle no longer names
  anything (generation). `batch_count` counts batches and instances.
- **For extensions.** `batch_records` and `batch_info` traverse the batches (handle, world,
  `object_id`, values, mesh, instances) and `batches_revision` rises when a batch arrives, leaves
  or is set again. `batch_values_set` gives the `values` of a batch as an extension that is not
  its owner would: it changes its row in place, without rebuilding the tables or raising the
  revision, and they last until its owner sets it again.
- **CPU rays.** `batch_ray(r, world, origin, direction, distance)` gives the batch, the instance,
  the distance and the normal of the first thing a ray finds: the batch box, that of each instance
  and the level 0 triangles of its mesh at rest, from the renderer's CPU copies. It is what the
  editor picker asks for.
- **`Batch_Desc`**: mesh, material or materials per slot (like `Instance_Desc`), tint, layers,
  `flags`, fade and cull distances, `vertex` (four numbers for the
  [vertex hook](views.md#extension-hooks-and-constants)), `reach` (the most that hook moves a
  point, in meters: the boxes of its instances and clusters with which the views clip grow by
  that), `values` (those of `instance_values`) and `object_id`. `engine/render.batch_desc` builds
  it from a `Mesh_Renderer`. The material rows it derives (fade, override) live as long as the
  batch lives: `render_sync` retains them in each round of derived rows, so whoever publishes
  batches does not publish them again because what the entities show changes.
- **`Batch_Instance`**: position in f32, rotation of `quat_pack` (std/math) and scale across (x
  and z) and along y in half floats. An instance has no previous transform: a batch is still and
  its motion vectors are those of the camera and those of the vertex hook.
- **World.** Each batch belongs to a world (`world`, the key of `scene_world`) and those of the
  displayed world are drawn. Changing world, batches or the scene's instance count rebuilds the
  tables of the batches drawn in the next frame (`batches_build`); a stable frame does not touch
  them. The tables traverse batches, not instances: what belongs to each instance is done when
  placing it. `meshes_clear` forgets all the batches and raises `batches_epoch`; a removed mesh
  leaves its batches undrawn until the next `batch_set`.
- **GPU data.**
  - The instances go to the scene's u32 pool as ranges of the same allocator as the indices, and
    are published with the geometry. Their positions, their box, their tree and the rows of their
    native TLAS are relative to the batch anchor (the multiple of `ORIGIN_STEP` nearest to them),
    which its row carries relative to the origin (`batch_anchor`): an origin jump rebuilds the
    rows of the batches, not their instances.
  - Each drawn batch has a row of the instance table after the instances: mesh, materials, flags
    and values, and in its transforms where its instances are and how they are drawn (`batch_*` of
    `scene.slang`).
  - It has `BATCH_GROUP` instance slots per group of its instances. A group table in the pool
    names the batch of each group. Its clusters go to the same visible list and the same draw as
    those of the scene.
- **Instance index.** Below `frame.instance_count` it names a scene instance; from there, the slot
  of a batch instance. Every pass that reads an instance by index goes through `scene_instance`.
- **Cull.** The same tests and the same per-cluster cut as the instances; between the fade
  distance and the cull one it fades with the dither pattern of its own body, which TAA blends. An
  instance whose box covers fewer than `Settings.batch_min_pixels` pixels is not rasterized, and
  fades the same from twice that: far away, foliage leaves the raster without jumps. The rays keep
  seeing it (the distant shadow remains, with the canopy and the coarse cuts).
- **Glass.** A batch draws no blend triangles; one made entirely of blend is neither drawn nor
  traced.
- **Rays only.** `Rays_Only` leaves the batch in no layer: no view draws it, the picker
  (`batch_ray`) does not find it and the rays of its other flags see it like any other; without
  any of them it is an error. Foliage uses it for its distant canopy and its mesh at rest.
- **Rays.** `Batch_Flags` `Casts_Shadow` and `Ray_Visible`; a batch with neither is raster only,
  enters no ray structure and changes no light. The others have their own ray class
  ([BVH](gi.md#bvh-and-acceleration-structures)): in software, a tree of their instances and one
  TLAS item per batch; with hardware RT, each instance is one of the native TLAS, which a compute
  (`tlas_batches.comp`) writes from its place in the pool at each build, without going through the
  CPU. The rays see the mesh at rest, without the vertex hook.
- **Light.** `batch_set` and `batch_remove` mark the change around the batch box, only for
  batches that rays see and of the displayed world.
- **Cost.** With hardware RT the native TLAS is rebuilt whole when something moves, with the traced
  instances of the batches; those that are only drawn cost nothing there.
- Tests: `mirai test render` with `batch_test.odin` (CPU), `batch_bench_test.odin`
  (`-define:BATCH_BENCHMARK=true`) and, on GPU,
  `a_batch_casts_the_shadows_and_shows_in_the_reflections_of_its_instances`
  (`batch_trace_test.odin`), which compares a batch with the same scene instances with each
  tracer.

## Meshes and textures one at a time

`render/scene_edit.odin`:

- **`mesh_add_geometry(r, geometry, slot_words, rays)`** receives the already encoded geometry and
  the material word of each slot (row and origin slot); without words, a slot of row 0. `rays` are
  the ray cuts made earlier; without them it makes them there.
- **`mesh_remove`** frees only the ranges of that mesh and hides the instances that named it; it
  keeps instances, handles and offsets of others, joins adjacent free ranges and does not
  compact. The removed BLAS goes through the RHI's deferred destruction.
- **`texture_remove`** removes a texture between frames without changing the other handles; the
  materials that named it are replaced with `materials_set` before the next frame.

## Geometry publication

- `renderer_commit_geometry` publishes the pending ranges of vertices, indices, mesh rows, nodes
  and triangles, and builds the new native BLAS. In a frame it is recorded at the start of its
  list and the CPU does not wait for the GPU: creating a mesh at runtime (a terrain chunk) does
  not stall the frame. The publication leaves the read barriers of the pools, which the passes do
  not declare. Outside a frame it is an immediate transaction with its wait, which also sends
  everything the queue of [several frames](#geometry-over-several-frames) has and shows it on
  return.
- One staging per frame in flight and another for the immediate copies, which no frame in flight
  reads, in host memory (`rhi.Memory.Staging`): loading a level does not occupy GPU memory with
  copies. If a reservation fails, it keeps the dirty ranges and withdraws the new BLAS of that
  attempt.
- **Pools without memory** (`render/pools.odin`). Whoever adds to a pool asks for room first
  (`pool_room`); the buffer grows and the next publication copies the old one on the GPU, without
  uploading it again. If the GPU has no memory, what it asked for (a mesh, a batch, the entries of a
  BLAS) does not fit, the rest is drawn and `Stats.problem` says what is lacking, what occupies the
  memory and how to avoid it. The same size is not requested again until as many bytes are freed as
  it added. The CPU copy of a pool grows with the same slack (`pool_reserve`), and the pages region
  is reserved with it: grown to the exact size, each mesh that takes the end of the pool would
  copy it whole in its frame.
- The entries of the new native BLAS that a frame decodes do not exceed `BLAS_INPUT_TRIANGLES` (the
  first mesh always enters; one without ray tables counts its triangles before making them): the
  others continue in the coming frames, and until then the hardware rays do not find them. Those
  of a mesh that exceed `UPLOAD_FRAME_BYTES` only take their place in their frame: they are
  decoded as they are uploaded through the several-frames queue (`Upload_Fill.Inputs`), and their
  BLAS is built when they have been uploaded. The pools have room for them at once, grown to
  double: doing it mesh by mesh would copy the whole pool each time.
- **Geometry preview.** It uses a new, immutable mesh from `host.assets_mesh_generate`; it does not
  edit a resident one and is withdrawn before `render_sync`
  ([life, UV1 and collision](../../mirai-core/references/host.md#loaded-assets)).
- Adding or removing instances and growing buffers requires global work: there is no constant cost
  per chunk.

## Geometry over several frames

`render/geometry_uploads.odin`. What does not fit in what a frame uploads goes through a fixed queue
of `GEOMETRY_UPLOADS` meshes, without allocating in a stable frame.

- **What goes.** `mesh_add_over_frames` registers a mesh like `mesh_add_geometry` and moves its pool
  ranges (its vertex and index blocks, and the tables and trees of its cuts) from the dirty ranges
  to the queue. A pose of `skin_create` that gives more than `UPLOAD_FRAME_BYTES`, or whose mesh
  or binding are still in the queue, goes the same way, with the influence and target buffers of a
  new binding; any other is there in the next frame, with its binding uploaded on the spot. Without
  room in the queue (`mesh_upload_room`) it goes on the spot; the deformables always go on the
  spot. The BLAS entries of a mesh that is drawn and exceed `UPLOAD_FRAME_BYTES` wait for room in
  the queue and share its budget, without hiding anything.
- **Done in the job.** What `render.mesh_ahead_make` does in the job of a load (the cuts, the
  verification of the geometry with its slots, the plate axes, the reach of its levels and the
  stream of a paged mesh, with the copy of its blocks) is not repeated when registering it: the
  frame that takes it does not traverse its geometry. Without that (`ahead` nil, or made with other
  slots) the registration does it.
- **CPU copy.** With its cuts, `mesh_add_over_frames` only takes in the CPU pools the blocks of
  its pages, its clusters and the tables and trees of its cuts; each range writes them from the
  geometry and the cuts it received when it sends them, with the same budget (a page range, in
  whole pages), and whoever passed them keeps them until it has been uploaded. What reads those
  pools on the CPU beforehand (`skin_create`, `deformable_create`, `mesh_triangles`, `mesh_ray`, an
  impostor, changing tracer) first writes everything that is missing (`mesh_filled`); `batch_ray`
  does not see a batch of a mesh that is still uploading.
- **Budget.** Each frame's publication sends the next ranges, in queue order, with what the texture
  levels (`texture_uploads_record`) leave of `UPLOAD_FRAME_BYTES`: a single budget per frame for
  everything that uploads over several frames, of which the textures take half while there is
  geometry. What the budget leaves of a mesh does not go to the next one; a range beyond its pool's
  buffer waits for it to grow.
- **Hidden until complete.** Until all of it has been uploaded, nothing reads it on the GPU: its
  instances stay hidden (`INSTANCE_FLAG_COLLAPSED`: a `scene_move` does not show them and the
  outline does not draw them), its batches are not built, `mesh_draw_range` rejects it, its BLAS
  is not built and its pose is neither deformed nor refit, and stays dirty. Before the frame that
  follows that of its last range it is shown at once (`geometry_uploads_install`): its instances,
  the light around it, its batches and its BLAS, in the publication of that frame.
  `mesh_upload_pending` and `mesh_uploading` say so.
- **Reused slots.** A range uploads from the CPU copy when its turn comes, and `Mesh_Upload`
  carries a serial: the mesh that takes the handle or the ranges of one that left (`mesh_remove`
  takes it out of the queue) is another request, uploads all its own and never shows that of the
  former. The instances that `mesh_remove` withdraws lose `INSTANCE_FLAG_COLLAPSED`: no movement
  shows them with the mesh that takes their handle.
- What a load takes this way `host` awaits
  ([load budget](../../mirai-core/references/host.md#loaded-assets)).

## Program catalog

`render/programs.odin`: `renderer_programs` reads the `catalog.json` of the shaders in use;
`program_find` gives a program with its reflected parameters, `program_defaults` its default
bytes, and `program_parameter_set` and `program_parameter_set_texture` write a parameter,
rejecting another type or out of range. The result goes in `Material_Desc.custom_params` or
`Postprocess_Desc.params`.

## GPU skinning

- **`skin_create`** registers, in a load transaction, a fixed-topology mesh that deforms on the
  GPU, with optional morph targets. With influences of level 0 the pose is that level; with those
  of all levels, it deforms each and the GPU keeps choosing among them. A pose larger than what a
  frame uploads goes with its influences and targets
  [over several frames](#geometry-over-several-frames), and is not deformed until it has been
  uploaded: its instance is not drawn, casts no shadow, rays do not see it and it has no outline,
  and if it replaces the world mesh (`replace_source`) that one is not drawn either. It appears
  already posed.
- The poses of the same source share bind vertices, influences and targets; one with other
  influences or targets needs another source. Each pose has joints, current and previous vertices
  and the ray structure of the tracer in use
  ([tracer in use](gi.md#bvh-and-acceleration-structures)). What is shared lives until its last
  user is withdrawn.
- **`skin_update(r, handle, palette, reset_motion, morph_weights)`** receives bind to mesh-local
  space matrices **with the inverse bind already composed**: the renderer does not apply it again.
  Empty `morph_weights` keeps the weights it has.
  - It rejects palettes or weights of another size and non-finite values before mutating; without
    changes or a requested reset, it recomputes nothing.
  - `part` (`Skin_Part_Pose`): the palette that collapses the part and its layers, which the view
    that does not draw them rasterizes ([own body](views.md#cameras-and-layers)).
  - The boxes come from those of each joint in bind plus what its targets move. It does not use
    the glass panel shortcut: the bind pose does not prove the deformed shape.
- **GPU.** Before the culling, a dispatch per pose adds the deltas of its targets (none with all
  the weights at zero), blends matrices, deforms and writes the previous positions. Afterwards
  the ray structure is refit: the BVH keeps the bind topology, and the native BLAS is rebuilt
  every `SKIN_REBUILD_INTERVAL` refits, staggered per mesh.
- Raster, shadows, reflections and rays read the same geometry. A still pose makes one last write
  to equalize current and previous and stops dispatching. `mesh_remove` frees it.
- **Preview** (`skin_preview_*`): the same compute, with the deformed vertices returned between
  frames, without scene meshes or BLAS
  ([previews](../../mirai-plugins/references/previews.md)).
- The [deformable meshes](views.md#deformable-meshes) of extensions use the same refit.
