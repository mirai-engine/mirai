# Renderer and scene (`render/`)

## Renderer

- `renderer_init(r, Renderer_Desc)` takes device, drawable size, settings, optional shader
  generation, allocator and capacities.
- Callers (`host`, editor) feed scenes via `mesh_add`, `materials_set`, `texture_add`,
  `scene_update`, `scene_light_update` and extension [passes](views.md#extension-stages), then
  submit one non-blocking command buffer per `renderer_frame(r, Frame_Desc)`
  ([views](views.md#frame-and-views), [UI](ui.md#ui-world-panels-and-debug-lines)).
- Stable scenes and UI never create GPU resources or allocate Odin memory.
- `renderer_resize` takes physical pixels, UI scale and native density separately
  ([resolution](settings.md#scene-resolution),
  [units](../../mirai-platform/references/platform.md#display-scale)). Stats:
  [statistics](frame-graph.md#statistics).

## Scene and instances

- **Incremental entry & OOM.** Instances and lights enter only via
  [partial changes](#partial-scene-changes) (full replace: `scene_update(r, 0, instances, true)`).
  GI wakes only around instances that appear, disappear or change look (not `highlight`);
  `mesh_add` marks nothing. `scene_update`, `scene_light_update`, `materials_set` and
  `materials_update` reserve first; on OOM they return `false`, leave the scene unchanged and set
  `Renderer.error`.
- **Non-invertible transforms.** Zero scale or non-finite values hide the instance
  (`INSTANCE_FLAG_COLLAPSED`) with a finite AABB and no inverse/hw transform; `scene_move` with an
  invertible transform restores it unless hidden by desc or its mesh is uploading
  ([several frames](#geometry-over-several-frames)).
- **Anchor, highlight & shadows.** `Instance_Desc.anchor` subtracts origin in f64 before f32
  storage (`engine/render.camera_carried`). `highlight` picks 0, 15 editor or 15 game styles
  (`Highlight_Style`, [outlines](frame-graph.md#outlines)). `shadowless` (`Mesh_Renderer.shadows`
  off) skips shadow rays/maps (`RAY_UNSHADOWED`, no glass filter) while keeping raster and surface
  rays.
- **Pools & whole-mesh draws.** Registered geometry is immutable in two u32 pools: vertex pool
  (`asset.mesh_page_layout` page blocks + posed vertices) and index pool (clusters, page table,
  levels, slot words, native BLAS primitive tables, batch instances); `Gpu_Mesh` indexes parts.
  Non-culled readers (glass, blends, overlays, outlines, particles, `frame_mesh_whole`) share a
  per-frame index list (`mesh_draws.odin`, `Gpu_Mesh.draw_first`), growing to peak demand.
- **Clusters, levels & foliage.** `.mesh` v6 ([format](../../mirai-assets/references/kinds.md)):
  <= 128 tris/slot on power-of-two grids; GPU reads via `geometry.slang` and `posed.slang`, CPU via
  `cluster_vertex` and `mesh_level_decode`. Static DAGs and skinned levels share `cut.slang` /
  `cluster_in_cut` against `lod_error_pixels`. `MESH_FLAG_ISLANDS` (`asset.Island_Vertex`,
  `cluster_along`, `island_offset` in `geometry.slang`) morphs foliage pop-free; rays hit level 0
  at rest; boxes hold grown islands.
- **Detail camera, distant & raster lists.** `Frame_Desc.detail` (`Gpu_Frame.detail_eye`) overrides
  mesh, ray-cut and texture LOD while keeping view visibility. Distant meshes
  (`asset.mesh_build_far`, `host.assets_mesh_publish`, `Surface_Vertex`, `MESH_FLAG_SURFACE`) carry
  per-vertex surface stats (`material_surface_apply` over row 0) and stream like paged meshes.
  `mesh_add` encodes 1 level (`asset.mesh_build`) -> `mesh_add_geometry`
  (`host.assets_render_geometry_make`, `host.assets_mesh_generate`, `geom.corner_tangents`,
  [std/math](../../mirai-std/references/math.md)). Visibility raster lists grow to
  `RASTER_LIST_SHARE` (1/3) of peak demand and spill over multiple rounds.
- **Streamed pages (`render/pages.odin`).** Meshes with `page_data` (`asset.mesh_pages_pack`) and
  `root_page > 0` (`MESH_FLAG_STREAMED`, `Mesh_Stream`) load root pages only; others start at
  `GPU_NONE` (`Gpu_Mesh_Page`; GPU `page_at`/`cluster_block`/`mesh_vertex_page`, CPU
  `pooled_cluster`/`record_decode`).
  - **Slots & invariant.** Non-root pages take `MESH_PAGE_WORDS` slots up to `PAGE_SLOTS_START`,
    doubling up to `Settings.page_pool_bytes` (OOM draws root and sets `Stats.problem`). A page is
    resident iff all parent pages are resident, covering the mesh once; missing-parent requests load
    the topmost missing parent whose own parents are present.
  - **Cull & loading.** `cull_clusters` draws a resident cluster when parent error fails and own
    error passes or `child_page` is absent (requesting `child_page` by error priority before
    occlusion). Readbacks arrive `MAX_FRAMES_IN_FLIGHT` frames later; non-culled readers skip
    missing pages (outlines draw finest resident). Frames load up to `PAGE_LOAD_WORDS` (via
    `Renderer_Desc.jobs` if set), evicting LRU slots unstamped for `PAGE_KEEP` frames with no
    loaded children, not a loading parent, and not in a traced ray cut. `PAGE_SHORT_FRAMES`
    consecutive shortages set `Stats.problem` (`page_pool_bytes` / GPU memory).

## Partial scene changes

`render_sync` feeds only `core.changes`: swap-remove gone rows, append new, `scene_update` dirty
runs, `scene_move`, `scene_tint`, then frame visual instances.

| Call | Effect & invalidation |
| --- | --- |
| `scene_move(r, descs, transforms, anchors)` | Shifts `prev_world` (motion 1 frame, rest next); updates hw TLAS; refits sw TLAS (rebuilds past `TLAS_REFIT_SLACK` 1.5). Atomic validation. |
| `scene_tint(r, descs, tints, emissions, values)` | Updates tint, emission and optional `Instance_Material_Values`; marks light near changed rows. |
| `scene_update(r, first, instances, truncate)` | Replaces range, appends or truncates. Matching `(object_id, copy_owner, copy_variant)` keeps motion/extension state; unchanged rows are no-ops. Settles TLAS once (`tlas_settle`). Marks light in box + `LIGHT_CHANGE_SIZES` (10x radius, max `LIGHT_CHANGE_REACH` 8 m; full 8 m if glowing). |
| `scene_light_update(r, i, light)` / `scene_light_remove(r, i)` | Adds/replaces/swap-removes light; rejects `!light_gives`. Settles units, blackout and [light tree](lights.md#light-tree) once (`scene_lights_settle`). |
| `scene_set_environment` | Updates sun, sky, background and light units without rebuilding TLAS. |
| `materials_set(r, mats)` / `materials_update(r, mats, rows)` | Row `n` <- `mats[n - 1]`; uploads changed ranges (full past `MATERIAL_RANGES_MAX`); reclassifies only on class change; wakes GI only on lit fields (`materials_lit`, full past `MATERIAL_LIT_ROWS` or `LIGHT_CHANGES_MAX`). |

- Queries: `scene_instance_materials`, `scene_instance_placed`, `scene_instance_was(r, dst, from)`,
  `instance_revision`. Uploads send touched runs (`Scene_State.touched`); software uploads nodes
  (+ refs on rebuild), hardware skips the software tree.

```odin
if !render.scene_update(r, 0, instances[:], truncate = true) { return r.error }
render.scene_move(r, []u32{0}, []render.Mat4{next_xform}, []render.Vec3{anchor})
render.scene_tint(r, []u32{0}, []render.Vec3{{1, 0.8, 0.8}}, []render.Vec3{{0, 0, 0}})
render.materials_update(r, materials[:], []u32{row}) // row n reads materials[n - 1]
```

## Visual instances

- `copy_owner` / `copy_variant` separate motion histories for extra instances of one entity while
  keeping its GPU `object_id`. `uniform_color` skips vertex-color tinting (programs still read it)
  and shares resident geometry.
- **Replacement** (`host.extras_instance_add` with `replace_source = true`, `hidden = true` hides
  source too): one-frame visual substitute; leaves picking, colliders, scenes and undo untouched.
- **Posed mesh** (`engine/render` `Posed_Meshes`, `posed_set`/`posed_drop`): GPU-posed copy (skin,
  `Deform`, imprint, displaced terrain) becomes the entity's mesh; owner drops pose before removing
  the mesh.

## Instance batches

`render/batch.odin`: dense instances of one mesh without per-instance table rows, sharing cull,
G-buffer and rays with scene instances.

- **API.** `batch_set(r, handle, world, desc, instances, colors)` (handle 0 = new; load
  transaction; descriptive error without mutating on bad mesh, non-finite values, negative
  distances or `Rays_Only` without ray flags), `batch_remove` (generational), `batch_count`,
  `batch_records`, `batch_info`, `batches_revision`, `batches_wind`, `batch_ray` (CPU level-0 pick).
- **Layout & world.** `Batch_Desc` (`engine/render.batch_desc`; derived rows live with the batch),
  `Batch_Instance` (`batch_instance`: f32 pos, 10-bit `quat_pack`, half-float scale; static),
  optional `batch_color(tint, wet)`. Stored in u32 index pool relative to snapped `ORIGIN_STEP`
  `batch_anchor`; one row after scene instances + `BATCH_GROUP` slots/group. Shaders read all
  instances via `scene_instance` (`index < instance_count` = scene, else batch). Belongs to
  `scene_world` (`batches_build`); `meshes_clear` forgets all (`batches_epoch`).
- **Filled by the GPU.** `batch_reserve(r, handle, world, desc, capacity, low, high)` takes room
  for `capacity` instances and a count word before them (`pool_take`: no CPU writes, no upload;
  the same room again only takes the new box/desc). Each view zeroes the counts of those drawn
  (`Batch_State.counts`) and runs the `Instances` stage before its cull; `pass_batch_target`
  binds the pool to write and gives `first`, `count`, `capacity` and `anchor`, and the cull reads
  `batch_count` (the count, up to the room; row `world_inv[2].z` = first word). No flags: rays,
  maps and `batch_ray` never meet them. Nested views draw what the main view wrote.
- **Cull & rays.** Batch AABB -> instance AABB -> cluster cut; dither fade/cull +
  `Settings.batch_min_pixels` raster cull (rays still see it); blend triangles ignored.
  `Batch_Flags`: `Casts_Shadow`, `Ray_Visible`, `Rays_Only` (no view/pick; needs a ray flag). Sw:
  per-batch tree + 1 TLAS item; hw: `tlas_batches.comp` builds native TLAS instances at rest (no
  vertex hook). Marks light around box if ray-visible in active world.
- **Verification.** `mirai test render` (`batch_test.odin`, `batch_bench_test.odin`
  `-define:BATCH_BENCHMARK=true`; GPU `batch_trace_test.odin`:
  `a_batch_casts_the_shadows_and_shows_in_the_reflections_of_its_instances`,
  `a_batch_with_a_basis_is_drawn_where_its_transform_says`); filled: `batch_test.odin`
  `a_batch_the_gpu_fills_holds_its_room_and_its_count`, GPU `batch_fill_gpu_test.odin`
  (`testdata/batch_fill.comp`).

```odin
insts := []render.Batch_Instance{render.batch_instance({2, 0, 0}, 1, {1, 1, 1})}
colors := []u32{render.batch_color({0.9, 1.0, 0.9}, 0.2)}
desc := render.Batch_Desc{
    mesh = mesh, tint = {1, 1, 1}, flags = {.Casts_Shadow, .Ray_Visible},
    fade_distance = 60, cull_distance = 80,
}
batch, err := render.batch_set(r, 0, world_key, desc, insts, colors)
```

## Meshes and textures one at a time

`render/scene_edit.odin`:

- `mesh_add_geometry(r, geometry, slot_words, rays)`: registers encoded geometry, slot material
  words (default row 0) and optional ray cuts.
- `mesh_remove`: frees ranges, hides referencing instances, merges free ranges without compacting,
  defers BLAS destroy. `texture_remove`: removes between frames keeping handles; update referencing
  materials via `materials_set` before the next frame.

## Geometry publication

- `renderer_commit_geometry` publishes dirty pool ranges, mesh rows and new native BLASes:
  non-blocking at frame start, or immediate + wait outside a frame (draining multi-frame uploads).
  Uses host `rhi.Memory.Staging` per flight + immediate; failed reservation keeps dirty ranges.
- **Pools (`render/pools.odin`).** `pool_room`/`pool_reserve` grow with slack and GPU-copy old
  contents. OOM skips the request, sets `Stats.problem`, and blocks retries of that size until
  equal bytes are freed. Native BLAS decodes cap at `BLAS_INPUT_TRIANGLES`/frame; inputs >
  `UPLOAD_FRAME_BYTES` stream via `Upload_Fill.Inputs`. Previews register immutable meshes via
  `host.assets_mesh_generate` ([host](../../mirai-core/references/host.md#loaded-assets)).

## Geometry over several frames

`render/geometry_uploads.odin`: fixed `GEOMETRY_UPLOADS` queue, zero stable-frame allocations.

- `mesh_add_over_frames` (plus large `skin_create` > `UPLOAD_FRAME_BYTES` or referencing queued
  meshes/bindings, and large BLAS inputs) streams ranges across frames; falls back to immediate if
  `!mesh_upload_room`. `render.mesh_ahead_make` precomputes cuts/stream data on a worker thread.
- CPU copies fill lazily (`Upload_Fill`); keep passed geometry/cuts alive while
  `mesh_upload_pending`. Early CPU readers flush via `mesh_filled`; `batch_ray` skips uploading
  meshes. Shares `UPLOAD_FRAME_BYTES`/frame with `texture_uploads_record` (textures <= half while
  geometry is queued).
- **Hidden until complete.** Instances stay `INSTANCE_FLAG_COLLAPSED` (skipped by `scene_move` and
  outlines), batches unbuilt and BLAS/pose deferred until `geometry_uploads_install` reveals all
  after the last range (`mesh_uploading`). `Mesh_Upload.serial` guards slot reuse; `mesh_remove`
  cancels uploads and clears `INSTANCE_FLAG_COLLAPSED`.

```odin
if render.mesh_upload_room(r) {
    mesh, req, ok := render.mesh_add_over_frames(r, geom, slot_words, &ahead)
    // Keep geom and ahead alive until !render.mesh_upload_pending(r, req).
    _ = mesh; _ = ok
}
```

## Program catalog

`render/programs.odin`: `renderer_programs` loads `catalog.json`; `program_find`,
`program_defaults`, `program_parameter_set` and `program_parameter_set_texture` populate
`Material_Desc.custom_params` or `Postprocess_Desc.params` with type/range checks.

## GPU skinning

- `skin_create(r, source, influences, joint_count, morph, part)` creates a GPU-deformed copy
  (level-0 or all-level influences; optional `Morph_Data`, `Skin_Part_Pose`). Poses of one source
  share bind vertices, influences and targets; poses > `UPLOAD_FRAME_BYTES` stream
  [over several frames](#geometry-over-several-frames) and appear already posed.
- `skin_update(r, handle, palette, reset_motion, morph_weights, part)` takes bind-to-local matrices
  **with inverse bind already composed** (empty `morph_weights` keeps current). Validates lengths
  and finiteness atomically; skips if unchanged; disables glass-panel shortcut.
- **GPU & refit.** Pre-cull compute applies morphs, skins, writes previous positions and refits the
  active ray structure (staggered native BLAS rebuild every `SKIN_REBUILD_INTERVAL` refits).
  `pose_traced` skips refit if untraced or below `ray_cut_distance` error; still poses equalize
  once and stop. `mesh_remove` frees it. Previews: `skin_preview_*`
  ([previews](../../mirai-plugins/references/previews.md));
  [deformables](views.md#deformable-meshes) share the refit.

```odin
skin, ok := render.skin_create(r, base_mesh, influences[:], u32(len(palette)))
if ok {
    render.skin_update(r, skin, palette[:], reset_motion = false) // inverse bind composed
}
```
