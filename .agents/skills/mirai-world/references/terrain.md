# Current terrain

Two explicit representations (never inferred from collider): **Heightfield Terrain** (`Heightfield`,
open ground + holes) and **Volumetric Terrain** (`Volume`, sparse SDF blocks for caves/overhangs/
digging). Both publish immutable per-chunk meshes with painted layers and share brush intents.

## Entity, source and chunks

A terrain entity carries `Terrain{source, revision, solid}` without `Mesh_Renderer`. Geometry lives
on derived child `Terrain_Chunk{owner, coord, revision, lod, depth}` entities (depth 0 = chunk,
depth > 0 = `2^depth` node; no `core.Id`, not saved). Each chunk sits at `chunk_origin`
(`chunk_place`) so kilometer-scale worlds keep f32 precision. Empty resident chunks retain their
entity for edits.
Children share the source's material slot and inherit owner `Material_Values` color/emission.
`terrain_update` writes `Terrain_Chunk`, `Mesh_Renderer`, `Material_Values`, `Collider`, and emits
new chunk `Transform`/`Parent` via `core.Commands`. Reloads trigger on registry `terrain_stamp`
change; changing `Terrain.source` retires old children; local edits keep unaffected chunk entities.

## Joining a Volume with a Heightfield

`Terrain.ground` on a Volume references a Heightfield `Id` (`join.odin`):
- The Volume's box cuts virtual holes (`Join_Cut`) in Heightfield chunks/nodes without mutating its
  source (cut chunks stay LOD 0, undisplaced).
- Within `JOIN_BAND` interior samples, the Volume blends toward live Heightfield heights
  (`join_blend`); ground edits rebuild the strip.
- Requires identical cell size, zero relative rotation/scale, aligned XZ samples and interior box;
  otherwise reports `terrain.ground_misaligned`, `terrain.ground_outside`, `terrain.ground_invalid`,
  or `terrain.ground_box`.
- `joins_resident` keeps overlapping chunks resident together. `terrain.create` (`kind:"volume"`,
  `ground`) initializes the Volume aligned and filled with the ground (`source_volume_ground`).
  Joined chunks skip live stroke previews and update on confirm.

## Canonical format

Asset container Fourcc `TERR`, `terrain:Source_Info` (`source.odin`; wrong `VERSION` refused).
- **Paged grids (`grid.odin`):** `field` (Heightfield `PAGE`x`PAGE` heights or sparse Volume
  `BLOCK`^3 `f32` distances clamped to `SDF_BAND_CELLS`, negative = solid), `weights`, and
  Heightfield-only `holes` and `paint`. Volume uses a `Tile` -> slab (`SLAB_PAGES`) sparse
  directory; `grid_settle` collapses uniform blocks. Uniform pages store zero data.
- **File layout & coding (`page_code.odin`):** `<grid>_pages` stores `Page_Run`s referencing
  uncompressed `<grid>_blocks` ranges (with XXH3 hash) for independent range reads. Each page uses
  planar prediction + integer adaptive range coding (heights quantized to `HEIGHT_STEP` on save;
  exact bit preservation in memory/network). Heightfields also store `coarse` and `pieces` tables
  at file front for far nodes without decoding pages, plus authoring edit-layer grids (`edit<n>_*`,
  `edit_under_pages`).
- **Copy-on-write (`shared_make`):** world copies share pages/coarse grids; writers call
  `grid_prepare` / `grid_page_own` before mutating.

## Geometry and collision

- **Heightfield:** one vertex per sample, two triangles matching collider diagonal, full-source
  normals; holed cells omit triangles/picking/collision (nodes use masked `LAYERS_HOLED_MATERIAL`).
- **Volume:** marching tetrahedra with exact vertex welding and `Mesh` collider.
- **LODs & stitching:** every piece publishes renderer cluster levels (chunk borders locked via
  `Chunk_Mesh.locked`). Heightfield nodes read `coarse` at `>= node_lod_min`; `Border_Levels`
  stitches crack-free using shared boundary normals. Urgent/runtime collider rebuilds publish
  `bare` first and add cluster levels in background.
- **Collision & picking:** every solid piece collides (chunks prioritized over nodes within
  `Physics_Settings` slots and `Terrain_Settings.collision_distance`; overflow reports
  `terrain.collider_budget` while rendering continues). Heightfield collider cells pick dominant
  material for `Collision_Settings.surfaces` friction/restitution. In Edit, all chunks retain CPU
  triangles for picking; in Play only colliders do. `chunk_build` + immutable `chunk_publish` serve
  preview and runtime.

## Materials and layers

1..`LAYERS_MAX` `Terrain_Layer` entries (material, `tiling`, `height_blend`, `detile`, `variation`,
`far_tiling`, slope/height `Layer_Auto`). Each sample packs `WEIGHT_SLOTS` heaviest weights into 32
bits (`Weights`). Paint/Erase adjust weights proportionally (`weights_paint`); automatic rules layer
on top (`layers_vertex`).
- **Heightfield `Surface_Maps` (`surface.odin`):** per-piece `control`, `normal`, optional `paint`
  (Tint/Roughness, `paint.odin`), and `mask` (holes), sampled via `uv0`. Volumes pack top-4 piece
  weights in `uv0`/`uv1`.
- **`Terrain_Layers` shader (`terrain_surface.slang`, `terrain_blend.slang`):** reads a generated
  `layers_table` texture, blends top 2-3 layers (`terrain_heaviest`, `terrain_height_blend` via
  base-color alpha), applies biplanar projection (flat ground reads top only; whiteout normals;
  `mirai_sample_texture_projected`), `detile`, `variation` and `far_tiling`. Custom source blend
  materials use the same slot.

### Volume interior

`Source_Info.interior` defines depth strata (`wave`) plus noise `Pocket`/`Vein` layers.
`source_interior_apply` (`terrain.interior`) bakes weights from surface depth once (never evaluated
at draw time). Add brushes paint `Brush.layer`; Carve preserves interior weights.

### Texture relief

Heightfield-only draw-only displacement (`displacement.odin`, `terrain_displace.comp`): nearby LOD 0
chunks within `displacement_distance` subdivide up to `2^displacement_detail` over collider
triangles (fading over `DISPLACEMENT_FADE`, capped at `DISPLACED_CAPACITY`) using base-color alpha
height. Shared borders match the coarser neighbor detail and fade flat beside undisplaced chunks.

## Tool

Shortcut `T` (outside Play). Without selection shows Terrains/Create; with selection shows mode
panel (`Sculpt`, `Shapes`, `Paint`, `Holes`; preferences stored in `Terrain_Tool`).
- **Create / IO:** Plane or Heightmap (16-bit PNG/TGA/BMP/R16/R32; `SAMPLES_MAX`); Volume starts as
  solid block in air. Supports Heightmap/Weightmap import/export, `source_resize`, `source_mirror`,
  Volume **Save surface as mesh** (`source_surface`), and **Apply and consume selected mesh**
  (`source_volume_mesh`, undo restores entity).
- **Edit layers (`edits.odin`):** additive Heightfield grids (`source_edit_layer_take`) plus an
  auto-maintained **Splines** layer (`source_conform`, `Terrain_Conform`, `terrain_follow` via
  `Edit_Follow_Provider` joined to the spline's undo step).
- **Brushes & hotkeys:** Raise/Lower/Smooth/Flatten/Set height/Terrace/Noise/Erode (`erode.odin`)/
  Thermal (Talus)/Ramp/Shapes/Paint/Tint/Roughness/Holes, slope filter, Terrain3D 16-bit alphas,
  pen pressure. Keys: digits (brush), Shift+digit (mode), `[`/`]` or `F`/`Shift+F` (size/strength),
  Ctrl (invert), Shift (Smooth), Alt (cap at press height). Ramp/Shapes stay editable via handles
  until Enter/Apply.
- **Preview & history (`terrain_history.odin`):** strokes mutate a copy (`Terrain_Focus` forces
  chunks under cursor); Escape discards without touching file/history. Confirming writes registry
  memory (`editor.file_set`) and records delta pages/blocks in one undo step (re-coding only dirty
  pages). External file changes rebase via `steps_rebase`.
- **Inspection modes (`terrain_view.odin`, `terrain_view.comp`):** `contours`, `contours_height`,
  `slope` (in `Inspect` stage over all scene geometry), `layer_weights`, `selected_layer`, `chunks`.

## API

`terrain.{create,edit,layer,interior,sample,heightmap,resize,region,mirror,edit_layer}`
(`terrain_api.odin`, `terrain_region.odin`, `terrain_edit_layers.odin`) act on named entities
without selection as single undo steps in Edit (`asset.slot_named` picks layers by material stem/
path/`default`/`#2`). During Play, `terrain.edit` and `terrain.layer` queue `terrain.dig` /
`request_layer` for the next tick (no undo, no brush alpha).

## Editing during play

- `terrain.dig(requests, Brush, owner)` queues world-space edits consumed by `terrain_update`
  before physics in `Fixed` (auto-resolves nearest terrain if `owner` omitted; non-uniform scale ->
  `Scale`; validation errors return `Edit_Error` + `edit_error_fix`; unsupported brush ->
  `terrain.edit_kind`).
- Unified `Brush_Kind` intents (`Add`, `Carve`, `Raise`, `Lower`, `Smooth`, `Flatten`, `Noise`,
  `Paint`, `Erase`; Heightfield-only: `Hole`, `Fill`, `Ramp`, `Terrace`, `Erode`). Runtime edits
  stay in memory (`request_save` saves explicitly).
- `Terrain_Data` shares COW pages on copy/rollback (`epoch` bumps invalidate caches);
  `Terrain_Resident` (`host,by_world`) isolates worlds. Stable frames allocate and mesh nothing.

## What digging leaves

`Terrain_Digs` (per-tick event cleared by `terrain_replay`) reports center, reach, removed volume
and per-layer cubic meters/material:
- **Dust (`dust.odin`):** `Terrain_Dust` emits `core.Births` per material to `vfx` channels.
- **Pieces & drops:** `terrain_debris` plugin (`Terrain_Debris`, `Debris_Owed`) spawns rigid piece
  and drop prefabs per cubic meter removed (server/non-client only).

## Ground

`ground.odin` implements `core.Ground_Queries` via `Terrain_Ground` (`copy=false` view into
`Terrain_Data`) so foliage/navigation query terrain without importing it: returns highest hit and
top-4 materials (`layers_dominant`), falling back to Heightfield coarse grid far away (`Unloaded`
for paged-out Volumes; `Empty` for holes or unconfirmed strokes). Pushes world dirty boxes to
`changed` (`Ground_Marks`) and tracks `unloaded` uncollided chunk runs.

## Network

`terrain` stays net-agnostic via `Terrain_Replays` / `Terrain_Replay_Events` (`network.odin`); the
automatic `terrain_multiplayer` bridge syncs edits over an operation journal per source:
- Server validates rate/seat/reach/radius (`Terrain_Net_Settings`, client refusals ->
  `terrain.net_refused`), applies in order and broadcasts region + content hash check.
- Clients predict `terrain.dig` (not layer changes), keeping matching checks without re-applying;
  conflicting remote edits rewind (`multiplayer.rewind`); check mismatches fetch authoritative
  `Net_Part` pages/blocks (no bit-exact cross-arch requirement).
- Late joiners request a base keyed by `Source.origin` (file hash), receiving only altered pages/
  blocks since that origin (or full base if origin differs).

## Jobs, publishing and residency

`chunk_build` runs in `std/jobs` (`work.odin`) reading live COW sources (mutations wait for active
readers; stale results drop by `Data_Source.change`).
- Runtime collider edits publish deterministically on the next tick; non-urgent visuals publish
  nearest-first within `PUBLISH_VERTICES`, showing Heightfield neighbors together (`pieces_show`)
  to prevent cracks.
- Urgent synchronous builds cover only ground within `GROUND_REACH` of `Simulation_Sources`/moving
  bodies plus unbuilt Heightfield roots; background builds cap at `WORK_BACKGROUND_SHARE`.
- Section loads wait for `data_load_begin` via `scene.Load_Waits` so sections join ready.

## Tree and nodes

Heightfields use a quadtree (1 root); Volumes use an octree bounded at `VOLUME_NODE_CELLS` per root
(`quad.odin`). `Terrain` is `@(component,far)`: unloaded sections keep far nodes without colliders
(`scene.Far_Kept`). Traversal opens nearest chunks within `Terrain_Settings.chunks` (root overflow
-> `terrain.chunks_full`), keeping old coverage until replacements finish.
- **Streaming residency:** with `resident_distance > 0`, chunks and disk pages (`terrain_read`
  `paged=true`, `RESIDENT_KEEP` hysteresis) stream around `scene.Streaming_Sources`. Edited pages
  spill to in-memory coded blocks on evict and restore on reload.
- Plugin read API (`core.Ref(Terrain_Data)`): `terrain_source`, `chunk_counts`/`index`/`box`,
  `terrain_height`, `source_height_held`, `terrain_change`.

## Limits in open worlds

- Caps: `SAMPLES_MAX` per axis, `CHUNKS_MAX` chunks, `VOLUME_NODE_CELLS` per Volume root.
- Heightfields cannot hold overhangs (use Volume or joined Volume; rotated or overlapping joined
  Volumes are unsupported).
- Adjacent Heightfields with matching cell/chunk/transform lattice stitch automatically
  (`adjacency.odin`: lower `Id` owns edge samples, levels differ by <= 1, brushes write both).

## Verification

- Runtime CPU: `mirai test plugins/terrain/runtime` (`intent_test.odin`, `volume_tree_test.odin`,
  `edits_test.odin`, `region_test.odin`, `layers_test.odin`, `holes_test.odin`, `shading_test.odin`,
  `shape_test.odin`, `brush_options_test.odin`, `blocks_test.odin`, `page_code_test.odin`,
  `join_test.odin`, `pipeline_test.odin`, `quad_test.odin`, `quad_pipeline_test.odin`).
- Benchmarks (`-define:TERRAIN_BENCH=true` / `-define:MIRAI_BENCH=true`): `bench_terrain_levels`,
  `bench_terrain_volume_memory`, `bench_terrain_update_while_a_brush_edits`.
- Network & debris: `mirai test plugins/terrain_multiplayer/runtime`,
  `mirai test plugins/terrain_debris/runtime`.
- Editor CPU: `mirai test plugins/terrain/editor`.
- Shaders & GPU: `mirai shaders check plugins/terrain/shaders/terrain_layers.slang`,
  `shared_terrain_chunks_remain_visible_after_duplicate_copy_and_preview_retirement`
  (`-define:TERRAIN_GPU=true`), and live session captures (`--copy`) verifying strokes, undo and
  shared sources.
