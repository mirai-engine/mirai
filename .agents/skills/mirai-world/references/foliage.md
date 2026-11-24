# Foliage

Plugin `foliage` (`Runtime`, `Editor`, `Shaders`; depends on `pcg` and `physics`). The rendering
and physics sink of what a `Pcg_Graph` places on the CPU (Tier 1: Macro and Meso layers): draws the
cells the graph generated via [instance batches][batches] and [impostors](#far-impostor-and-crown),
and collides with one static body per cell, without one entity per instance. Where and what is
placed (layers, paint, rules, zones, ground) is the `.pcg` source of the graph (`plugins/pcg`);
the foliage keeps no source, ground cache, scatterer or per-instance overrides.

[batches]: ../../mirai-rendering/references/scene.md#instance-batches

## Entity and looks

- An entity with `Pcg_Graph{source=.pcg}` and `Foliage` (`@(component,far)`) draws what the graph
  places, in the frame of its cells (`pcg.graph_frame`: the entity, or the world when anchored). A
  `Volume` on it bounds where the graph places. A `Foliage` without a graph reports
  `foliage.graph`.
- `Foliage{wind, flutter, shadows, rays, preset}` gives how the layers that place a **mesh** sway,
  cast shadows, are seen by rays and collide (hull `preset`). A layer that places a **prefab** draws
  its `Mesh_Renderer`s (their `shadows`), sways by the `Foliage_Sway` of its root (`prefab_sway`),
  and collides as its colliders (or the hulls of its meshes without any): promoting an instance
  spawns that same prefab, which looks, sways and collides the same.
- `looks_make` derives one `Look` per layer of the source (asset, distances, `filler`, `collides`,
  and `span`/`expected`: the stable-id range and full-cell count of its points). The cells match
  `pcg.Pcg_Generated` cells by coordinate and rebuild on their `revision`.

## Drawing

- `foliage_render` (`late`, `end`) publishes 1 batch/cell/layer/prefab-part via `render.batch_set`,
  stored in `Foliage_Resident` (`host, by_world`, freed in `foliage_release`). It rebuilds only on
  generated cell revision, marks, bands, frame, looks, `batches_epoch` or asset change; stable
  frames publish nothing. Builds go nearest first (`Generated_Cell.near`) within
  `INSTANCES_A_FRAME`.
- Instances group in one pass (`placed_group`); `object_id` = entity. `resident_batch_find` and
  `foliage_picked` (`layer_instance`) turn a batch pick into the `pcg.Pcg_Instance` it draws.
- **Filler budget**: graphics `detail` (`FOLIAGE_DETAIL`) scales distances and keeps the first
  `span*thin` point indices of each cell of a `filler` layer (`filler_kept`), dropping tail ids.
  Collision never thins.
- **Density-modulated LOD**: each cell picks, once when built, a `density_band` per layer from its
  instance count over `expected`; full cells give way to impostors at `DENSITY_LOD_MIN` of the
  distances (`band_scale` on mesh fade/cull and the band's impostor row; `DENSITY_BANDS` rows per
  look).
- **Prefab parts**: shear/mirror error > `PREFAB_ERROR` reports `foliage.prefab_transform`;
  unreadable or meshless prefabs report `foliage.prefab`.

## Far: impostor and crown

Layers with `impostor_distance > 0` and `< cull_distance` (or cull 0) build a far shape (`far.odin`)
per `(asset, frame_size, world)` (`Kind_Key`) once `render.mesh_renderer_settled` is true:

- **Octahedral impostor**: `render.impostor_capture` renders `IMPOSTOR_GRID`² upper-hemisphere
  frames sized to match the largest instance at `impostor_distance` (`impostor_frame`). Mesh until
  built. Materials compile the `impostor` use through the `program_uses` of the `.pcg` kind.
- **Crossfade & draw**: mesh fades across `impostor_distance`..`+IMPOSTOR_BLEND`; impostor fades in
  with the complementary mask, then out by `fade_distance`/`cull_distance`. One per-world block
  buffer (`Impostor_Draw`) updates only dirty cells; two-phase Hi-Z `Gbuffer` cull
  (`foliage_impostor_cull.comp`). Row of an instance: `slot<<16 | look*DENSITY_BANDS+band`.
- **Crowns & rays**: far cells replace mesh batches with `crown_build` (`Rays_Only`); past
  `CELL_CROWN_REACH` × mesh reach, `cell_crown_build` merges a cell into one `Shared_Crown`.
- Unloaded sections (`scene.Far_Kept`) draw only far shapes with no physics.

## Micro scatter on the GPU

`Micro` layers (grass, pebbles, flowers) are never placed on the CPU nor collide: `micro.odin`
scatters them on the GPU through `engine/render` alone (`Foliage_Micro`, `host, by_world`, freed in
`foliage_micro_release`). Without a renderer `foliage_micro` returns before any work or memory.

- **Tiles**: a tile is a cell of the graph and a `Scatter` layer of tier `Micro` placing a `.mesh`
  (a prefab, Cascade or Grammar reports `foliage.micro`), resident while a streaming source is
  within its `cull_distance` × detail (`MICRO_REACH_MAX` when 0), its `Pcg_Ground` tile is read
  whole and its cell is generated; at most `MICRO_SLOTS`, nearest first. `pcg.source_reach` counts
  `Micro` layers so the ground tiles under them exist: no second ground cache.
- **Generate once**: a tile's key (`micro_tile_key`) is the graph key, its ground tile revision,
  the cell's `occupied_hash` and its candidates; only a changed key regenerates it, the nearest
  `MICRO_TILES_A_FRAME` a frame, keeping its old instances meanwhile. The CPU packet is the ground
  tile heights plus `pcg.micro_samples` (field × paint × ground rule × excluding zones × graph
  `Volume`, 0 where occupied) on `MICRO_SAMPLES`² points; `foliage_micro_gen.comp` (`Simulate`)
  writes only survivors into the slot's block with an atomic count: no readback, no dead points.
  Inputs unchanged since the last frame (`micro_inputs`) skip residency entirely.
- **Occupancy** is pre-suppression: `pcg.cell_generate` rasterizes the radii of every Macro/Meso
  point that stood (`Generated_Cell.occupied`, sources with Micro layers only), so taking a tree
  out never lets grass sprout at its stump.
- **Draw**: per view, `foliage_micro_cull.comp` (`Gbuffer`) keeps instances within distance, in
  the frustum and not hidden by this frame's depth pyramid (one phase), into one list per look;
  `foliage_micro.vert` draws a fixed count of indirect draws (a look × Surface program) with the
  engine G-buffer fragment, shrinking between fade and cull, bent by `foliage_lean`/`foliage_sway`.
  Micro meshes are not in the ray structure and cast no shadow maps.
- **Detail**: filler layers keep `FOLIAGE_DETAIL[0]` of their candidates by hash; distances scale
  by `FOLIAGE_DETAIL[1]`.

## Wind

- `volume.Wind` bends plants about instance origin in the [vertex hook][hook]
  (`foliage_vertex.slang`, `foliage_sway.slang`): vertex color R weights bend (`sway_amount`), R×G
  weights leaf flutter (`flutter_amount`).
- **Shadows**: looks that cast shadows and stand >= `SHADOW_SWAY_HEIGHT` sway their shadows in near
  cascades (`shadow_sway`, per-cell `wind_zone_at`). Rays always meet foliage at rest
  ([what sways][sway]).
- **Swaying mesh entities**: `Foliage_Sway` on a `Mesh_Renderer` draws a 1-instance batch via the
  same hook (`foliage_sway_render`, `Drawn_Elsewhere`); on a prefab root it is also how a layer that
  places the prefab sways.
- **Trampling**: `Foliage_Bender` stamps `Foliage_Trample` around the first streaming source.

[hook]: ../../mirai-rendering/references/views.md#extension-hooks-and-constants
[sway]: ../../mirai-rendering/references/lights.md#what-sways-in-the-maps

## Collision

- `foliage_physics` (`fixed`, after `physics_prepare pcg_update`, before `physics_places`, skipped
  while `time.resimulating`) creates one [owned static body][owned] per generated cell at its corner
  (shape user = `Placed.id`). `Foliage_Physics` copies with the world: its handles name bodies of
  the copied simulation, and a copy without it would build every body twice. The ground cache
  (`pcg.Pcg_Ground`) copies too: without it a copy re-probes the ground and places on coarse
  tiles for a few frames. `foliage.query` `physics_bytes` and `pcg.inspect`
  `ground_bytes`/`ground_total_bytes` say what each copy carries.
- **Every cell the graph keeps collides**, at any detail and whoever looks, built nearest
  `scene.Simulation_Sources` first (`PHYSICS_INSTANCES_A_TICK`/tick); cells past the budget keep
  their old bodies until built. A cell that only lost instances (suppressed) destroys their shapes
  alone (`cell_only_lost`, by `placed_hash`); any other change rebuilds the cell.
- Missing collision shapes report `foliage.collision`; full physics reports `foliage.physics`.

[owned]: ../../mirai-physics/references/engine.md#owned-bodies

## Play: take out, promote, mark

Taking out and promoting are the graph's world rows (`pcg.Pcg_Suppressed`): one mechanism for the
editor and Play, replicated, saved and rolled back. Marks (burnt, wet) are `Foliage_Marked` pages
(`MARKED_PAGE`, `replicated="object"`) keyed by the entity `Id`; `Foliage_Requests` overflow reports
`foliage.requests`, a missing `Id` `foliage.mark`.

```odin
// Harvest on a physics hit, fell a tree as an entity, or scorch nearby plants in a fixed step.
if plant, ok := foliage.hit_of(phys_state, hit); ok {
    pcg.pcg_suppress_request(suppress, plant)   // or foliage.foliage_promote(promote, plant)
}
found := make([dynamic]foliage.Foliage_Found, context.temp_allocator)
if foliage.foliage_in_sphere(&found, blast_pos, 4, data, generated, foliages, graphs, worlds) {
    for item in found {foliage.foliage_mark(requests, item.plant, {0.25, 0.2, 0.15}, 0)}
}
```

## Editor

No tool: editing is the graph's. `foliage_cells` inspection mode (Advanced → Foliage) outlines the
generated cells near the view (green: places, grey: empty). `foliage.query` (read-only) settles the
graph, then lists layers with counts and the instances in a box (layer, cell, id, place, scale).

```sh
mirai rpc foliage.query '{"entity":"Woods","min":[-10,-5,-10],"max":[30,20,10]}'
```

## Verification

- `mirai test plugins/foliage/runtime --no-gpu`: looks, filler and bands, grouping, physics diffing
  and budget, hull rocks, prefab parts and sway, picks, queries, marks, impostor rows and crowns.
- `mirai test plugins/foliage/runtime` (GPU with validation): the wind, sway and bender tests of
  `gpu_test.odin` and `bend_test.odin`; micro generation once, cull and draw in
  `micro_gpu_test.odin` (`micro_test.odin`: occupancy, tile gating, headless no-op, no GPU).
- `mirai test plugins/foliage/editor -collection:plugins=<root>/plugins`.
- Live: `mirai session start demo --copy`, `scene.open forest/forest.scene`, `foliage.query
  entity=Woods`, and `mirai capture` of `forest` and `foliage_extreme` at 200+ frames.
