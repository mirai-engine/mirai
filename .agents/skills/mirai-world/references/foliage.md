# Foliage

Plugin `foliage` (`Runtime`, `Editor`, `Shaders`; depends on `physics`). Renders scenes of plants
via [instance batches][batches] and [impostors](#far-impostor-and-crown), collides with one static
body per resident cell, and stands instances on world [ground](#ground) without one entity per
instance.

[batches]: ../../mirai-rendering/references/scene.md#instance-batches

## Entity and source

- `Foliage{source, revision}` (`@(component,far)`) shows one `.foliage` asset in entity space.
  `revision` (readonly) is the [tool](#tool) history key; runtime never writes it, so undoing to
  revision 0 restores an imported level's source.
- `foliage_load` reads sources via `host.assets_file` and reloads on file stamp change. Unreadable
  sources report `foliage.source_unread`. `Foliage_Data` copies with the world (Play, rollback).
- Reloads keep `cells_version` for unchanged cells and bump only changed ones. Changing seed or
  placement/collision type settings bumps all cells; draw-only type edits (mesh, materials,
  distances, wind, shadow, rays) keep cell versions and bump entry `look` (rebuilds batches and
  crowns only).

## Format

[Assets](../../mirai-assets/references/formats.md) container, Fourcc `FOLI`, rows in `source.odin`:
`foliage` (`Foliage_Info`), `types` (`Foliage_Type`), `cells` (`CELL_SIZE` in XZ), and packed bulk
`manual`, `overrides`, and `density` (`DENSITY_SAMPLES`² grid per cell; omitted = full density,
all-0 = off; written by `source_generate_area` and `cell_density_set`).

- `manual` and `overrides` are bit-exact byte planes with delta/word coding (`Code`); `source_bytes`
  and `source_read` are the sole writer/reader. `source_read` validates before replacing;
  `source_bytes` writes only valid sources.
- Type `id` is stable and never reused. A type references a `.mesh` (with optional slot material
  overrides) or a prefab without converting it. `impostor_distance` (0: none), `offset`, and `rule`
  default to zero when absent from older files.
- Manual instances take unique `id` >= 1 (`Foliage_Info.instances`), never reused and preserved
  across cell moves (`source_instance_add`, `manual_find`, `source_instance_remove`). Override
  instances carry `id = 0`; duplicate or unissued ids are invalid.
- Instance flags: `INSTANCE_GROUNDED` (`ground` height above ground for reprojection),
  `INSTANCE_ALIGNED` (only with grounded; tilts with ground normal by type `align`),
  `INSTANCE_COLORED` (`color` packed via `render.batch_color`, also tints/wets impostors).
- Overrides (`Deleted`, `Moved`, `Replaced`) target generated `(type, point)` and must stay sorted
  and unique per cell (`source_override_set`, `source_read` sorts, `source_valid` enforces).

## Layers of a cell

`cell_expand` merges manual instances, generated points (when `generate`), and overrides in order.
`Placed.id` is `MANUAL` + manual id, or `(type, point)` (`generated_id`), stable while seed and
type match (lowering density drops tail ids only).

- `scatter` uses Owen-scrambled base-2 (0,2) points per `(seed, cell, type)` with integer math,
  sqrt, and deterministic `std/math` sin — identical across machines, stratified without clumping.
- Cap: `CELL_GENERATED_MAX` points/cell; above it `generated_share` scales every type equally and
  reports `foliage.cell_instances`.
- **Radius** (`spaced_stand`): widest radius first; cross-border ties break deterministically by
  lower index then cell `(z, x)` within 3×3 cells (`RADIUS_MAX`), using only seed for same-type
  pairs and nearest-border ground/density/keep-outs for wider types. Radius 0 ignores spacing.
- **Density & rule** (`Foliage_Rule`): each point tests its stream `chance` against cell density
  and layer weight. `rule_allows` filters by slope, height, and terrain material `layers` (order-
  independent, sum >= `weight`, density fades with weight). Unknown weights admit nothing.
  Missing/hole ground omits generated points without shifting surviving ids.
- Orphan overrides (ids no longer generated) remain in the source and report `foliage.orphans`.
- Without a ground provider, `y = 0` is ground; with one, unread/uncovered cells show no generated
  instances.

## Ground

- `Foliage_Ground` (world storage) holds per-cell `Ground_Tile` heights (NaN = hole/unloaded) and
  parallel 4-layer weights (sum 255, `Ground_Layers` up to `LAYERS_MAX`). `foliage_ground` queries
  [`core.Ground_Queries`](../../mirai-core/references/core.md#ground) along entity down and bumps
  changed tile revisions. `Foliage_Ground_Requests` prioritizes editor-requested cells. Empty tiles
  are removed (`foliage.no_ground`).
- **Keep-outs** (`keep_out.odin`): `Foliage_Keep_Out` excludes generated foliage from its `Volume`,
  else `Spline` width, else box/sphere/capsule/cylinder `Collider` plus `margin` (neither reports
  `foliage.keep_out`). Marks `KEEP_OUT_SIDE`² squares (`Ground_Cell.kept`) at uniform resolution;
  keep-out edits dirty old and new boxes. Ignored without world ground.
- **Whole near, sparse far**: grid spacing follows `Ground_Query.spacing` (up to `SAMPLES_MAX`).
  Within mesh reach (`<= GROUND_REACH`) of [streaming sources][sources] or editor requests, tiles
  are whole; farther, `Sparse_Tile` samples only the 4 corners around each visible/spaced point and
  keep-out center (`sparse_keys`) so far and near placement match identically.
- Budgeted jobs (`GROUND_SAMPLES`/frame, editor requests then nearest source via `queue_order`)
  refresh only `Ground_Queries.changed` boxes (or all cells when `Foliage` moves). Unread cells get
  a temporary `SAMPLES_MIN` coarse tile from `GROUND_COARSE`. Identical reads skip revision bumps.

[sources]: ../../mirai-gameplay/references/libraries.md#sources-and-residency

## Drawing

- `foliage_render` (`late`, after `transforms_propagate`) publishes 1 batch/cell/type/prefab-part
  via `render.batch_set`, stored in `Foliage_Resident` (`host, by_world`, freed in
  `foliage_release`). Reuses handles; rebuilds only on cell version, ground revision, transform,
  entry, `batches_epoch`, or asset change. Stable frames publish nothing.
- Instances group in one pass (`placed_group`). `object_id` = entity; `Batch_Role` distinguishes
  mesh vs crown (`resident_batch_find`); batch instance `k` is the `k`-th of its type for picking.
- **Prefab types**: each visible `Mesh_Renderer` (`prefab_parts`) becomes a batch (`part_instance`).
  Shear/mirror error > `PREFAB_ERROR` reports `foliage.prefab_transform`; unreadable or meshless
  prefabs report `foliage.prefab`.
- Residency follows [streaming sources][sources] up to farthest `cull_distance` (0: all), capped at
  `RESIDENT_CELLS` nearest (`foliage.resident_cells`). Builds nearest first in jobs within
  `INSTANCES_A_FRAME` (`cell_bound`, min `CELL_COST_MIN`). Graphics `detail` scales distances and
  thins non-colliding types (`FOLIAGE_DETAIL`); colliding types never thin.

## Far: impostor and crown

Types with `impostor_distance > 0` and `< cull_distance` (or cull 0) build a far shape (`far.odin`)
per `(asset, frame_size, world)` (`Kind_Key`) once `render.mesh_renderer_settled` is true:

- **Octahedral impostor**: `render.impostor_capture` renders `IMPOSTOR_GRID`² upper-hemisphere
  frames (base color+coverage, normal+depth, roughness/metallic/AO/transmission) sized to match the
  largest instance at `impostor_distance` (`impostor_frame`). Falls back to mesh until built.
- **Crossfade & draw**: mesh fades across `impostor_distance`..`+IMPOSTOR_BLEND` and small screen
  size; impostor fades in with the complementary mask (`box_faded`, `box_small_faded`), then fades
  out by `fade_distance`/`cull_distance`. One per-world block buffer (`Impostor_Draw`) updates only
  dirty cells; two-phase Hi-Z `Gbuffer` cull (`foliage_impostor_cull.comp`, `foliage_impostor.frag`,
  writing `SV_Depth`) shades like scene geometry. Skipped in nested views.
- **Crowns & rays**: far cells replace mesh batches with `crown_build` (`CROWN_INSET` dense-voxel
  `Rays_Only` batch, mean color, respects `casts_shadow`/`ray_visible`). Past `CELL_CROWN_REACH` ×
  mesh reach, `cell_crown_build` merges a cell into one `Shared_Crown` (`crown_key`). Impostors
  never enter ray structures.
- Unloaded sections (`scene.Far_Kept`) draw only far shapes (impostors + crowns) with no physics.
  Budget: `CELLS_A_FRAME` and `KINDS_A_FRAME` steps/frame (`Kind_Bake`); `batches_epoch` rebuilds.

## Wind

- `volume.Wind` bends plants about instance origin in the [vertex hook][hook]
  (`foliage_vertex.slang`, `foliage_sway.slang`, `Foliage_Wind_Frame` from `Mask`): vertex color R
  weights bend (`sway_amount`, gust wave `FOLIAGE_WAVE`); R×G weights leaf flutter (`flutter_amount`
  in `vertex.z`).
- **Shadows**: types with `casts_shadow` and height >= `SHADOW_SWAY_HEIGHT` cast swaying shadows in
  near cascades (`shadow_sway`, `Batch_Desc.sway`/`wind`, per-cell `wind_zone_at`, `batches_wind`).
  Rays (traced shadows, reflections, GI, probes) always meet foliage at rest ([what sways][sway]).
  Impostor quads lean by top wind (`Impostor_Row.far.z`).
- **Swaying mesh entities**: `Foliage_Sway` on a `Mesh_Renderer` draws a 1-instance batch via the
  same hook (`foliage_sway_render`, `Drawn_Elsewhere`), keeping entity transform/collider/picking
  and rest-pose outlines.
- **Trampling**: `Foliage_Bender` stamps `Foliage_Trample` (`TRAMPLE_SIDE`×`TRAMPLE_TEXEL`, follows
  first source, recovers 1/e per `TRAMPLE_RECOVER`s, caps `BEND_RADIUS_MAX`, `BEND_LEAN_MAX`).
  Motion vectors read the prior frame's field; `Batch_Desc.reach` (`hook_reach`) expands cull boxes.

[hook]: ../../mirai-rendering/references/views.md#extension-hooks-and-constants
[sway]: ../../mirai-rendering/references/lights.md#what-sways-in-the-maps

## Collision

- `foliage_physics` (`fixed`, between `physics_prepare` and `physics_places`, skipped during
  `time.resimulating`) creates one [owned static body][owned] per loaded cell at cell corner
  (`user_data` = entity, shape user = `Placed.id`). `Foliage_Physics` copies with the world.
- **Every cell of a loaded `Foliage` collides** (server AI/shots/navmesh match everywhere), built
  nearest `scene.Simulation_Sources` first (`PHYSICS_INSTANCES_A_TICK`/tick). `Far_Kept` has no
  bodies.
- Shapes (`type_shapes`): `Capsule`, `Box`, `Prefab` (box/sphere/capsule/cylinder/hull/`Auto`
  colliders), or `Hull` (shared `physics.owned_hulls` scaled per instance). Unsupported/missing
  colliders or hull exhaustion report `foliage.collision`; full physics reports `foliage.physics`.
- Removed instances drop only their shapes (`collider_remove`); body stays until empty.

[owned]: ../../mirai-physics/references/engine.md#owned-bodies

## Instances removed in play

Play removals and marks are world state (`removal.odin`, `query.odin`, `marks.odin`), never source
edits. Authoritative side (singleplayer or server) processes `Foliage_Requests` (overflow reports
`foliage.requests`) into replicated (`replicated="object"`, `Simulation.Server`, `Audience.Always`)
child entities keyed by `Foliage` `Id` (missing `Id` reports `foliage.remove`):

- `Foliage_Removed` (`REMOVED_PAGE` `Removed_Instance` fragment entries/entity) and `Foliage_Marked`
  (`MARKED_PAGE` `Marked_Instance` entries/entity) replicate per-entry deltas, persist in saves,
  copy with Play/rollback, and stay with `Far_Kept`. Removing the entity restores instances/look.
- Orphan ids (deleted/moved in source) are harmlessly retained; marks override source tint. Only
  cells whose `removed_cell`/`marked_cell` hash changed rebuild.

```odin
// Query, harvest on physics hit, or scorch nearby plants in a fixed step.
if plant, ok := foliage.hit_of(phys_state, hit); ok {
    foliage.foliage_remove(requests, plant)
}
found := make([dynamic]foliage.Foliage_Found, context.temp_allocator)
if foliage.foliage_in_sphere(&found, blast_pos, 4.0, data, grounds, removals, foliages, worlds) {
    for item in found {
        foliage.foliage_mark(requests, item.plant, {0.25, 0.2, 0.15}, 0.0)
    }
}
```

## Tool

`foliage_editor` (shortcut **G**, outside Play). Edits selected `Foliage` or creates a new
`.foliage` in registry memory (one undo step).

- **Types**: searchable cards (click = single, Ctrl = toggle leaving one, Shift = range), drag-drop
  `.mesh` to add or replace, async per-cell `Counts` (`COUNT_CELLS`/frame), folded live info.
- **Modes** (`foliage_modes.odin`, keys 1–7): 1 Paint, 2 Erase, 3 Place, 4 Reapply, 5 Tint,
  6 Generate (Ctrl ungenerates, fades beyond `GENERATE_HARDNESS`), 7 Select (batch picker, gizmo,
  End = stand on ground). Brush keys match [terrain](terrain.md#tool) (`[`, `]`, F, Shift+F, Ctrl).
- During strokes (`BRUSH_RATE`), `Foliage_Stroke` overlays edited cells; release commits one diffed
  undo step (`foliage_history.odin`), Escape cancels. `foliage_cells` inspection mode outlines
  nearby cells (green = generating, yellow = manual). Browser uses `Foliage_Kinds` and
  `Foliage_Thumbnails`.
- **API** (`foliage_api.odin`): `foliage.create`, `foliage.type_add`, `foliage.type_set`,
  `foliage.type_remove`, `foliage.paint`, `foliage.place`, `foliage.query` (each edit = 1 undo step,
  settles place and ground first).

```sh
mirai rpc foliage.create '{"name":"Forest","at":[0,0,0]}'
mirai rpc foliage.type_add '{"entity":"Forest","mesh":"assets/pine.mesh","density":0.2,"wind":1}'
mirai rpc foliage.paint \
  '{"entity":"Forest","mode":"generate","at":[0,0,0],"to":[24,0,0],"radius":8}'
mirai rpc foliage.query '{"entity":"Forest","min":[-10,-5,-10],"max":[30,20,10]}'
```

## Verification

- `mirai test plugins/foliage/runtime` (CPU):
  `cells_take_the_points_of_their_32_metres_including_negative_coordinates`,
  `a_foliage_asset_comes_back_as_it_was_written_and_damage_is_refused`,
  `the_generator_makes_the_same_points_with_the_same_ids`,
  `generated_points_cover_their_cell_with_one_in_each_square`,
  `instances_with_a_radius_keep_apart_within_and_across_cells`,
  `the_density_of_a_cell_and_what_keeps_foliage_out_thin_its_instances`,
  `the_generate_brush_paints_the_density_of_the_cells_under_it`,
  `overrides_change_their_generated_instance_and_orphans_are_kept`,
  `overrides_keep_the_order_of_type_and_point_and_are_found_by_it`,
  `a_source_read_again_keeps_the_version_of_the_cells_that_did_not_change`,
  `instances_stand_on_their_ground_and_generated_ones_leave_where_it_has_none`,
  `a_manual_instance_aligned_with_its_ground_leans_with_the_ground_that_changes`,
  `a_rule_of_slope_and_height_takes_out_the_generated_points_off_it_and_keeps_the_ids_of_the_rest`,
  `a_rule_of_layers_takes_its_materials_in_any_order_and_nothing_unknown`,
  `a_generated_point_takes_an_offset_of_its_type_and_keeps_its_other_values`,
  `a_foliage_file_written_before_the_rules_reads_them_off_and_bad_rules_are_refused`,
  `batch_instances_carry_the_transform_of_their_entity`,
  `placed_instances_group_by_type_keeping_their_order`,
  `a_part_of_a_prefab_composes_with_its_instance_and_says_what_it_leaves_out`,
  `the_parts_of_a_prefab_are_its_shown_meshes_placed_from_its_root`,
  `a_cell_collides_with_one_static_body_and_one_instance_leaves_alone`,
  `rocks_collide_as_one_hull_each_instance_scales`,
  `a_removed_type_takes_its_instances_and_overrides_with_it`,
  `a_type_with_an_impostor_draws_its_mesh_up_to_its_distance`,
  `a_crown_is_the_closed_surface_of_the_voxels_dense_with_leaves`,
  `the_crown_of_a_cell_covers_its_trees_with_fewer_triangles_than_theirs`,
  `what_the_renderer_forgets_takes_the_crowns_and_far_forms_with_it`,
  `a_cell_writes_only_its_block_of_impostors`,
  `a_type_casts_swaying_shadows_by_its_size`,
  `every_bender_tramples_the_foliage_and_it_stands_back_up_over_time`,
  `the_shadows_of_a_calm_valley_stay_still_whatever_blows_at_the_view`,
  `a_manual_instance_keeps_its_id_through_the_edits_of_its_cell`,
  `past_their_budget_the_nearest_cells_stay_resident`,
  `the_cells_near_the_sources_are_found_by_rows_and_every_one_they_keep`,
  `cells_are_built_nearest_first_within_the_instances_of_a_frame`,
  `a_cell_generates_at_most_its_cap_and_thin_keeps_the_first_points_of_what_does_not_collide`,
  `the_collision_of_the_nearest_cells_is_built_first_within_its_budget`,
  `the_cells_of_a_stroke_show_over_its_file_until_it_is_cleared`,
  `instances_taken_out_are_one_entity_for_each_cell_that_the_cell_leaves_out`,
  `an_instance_is_taken_out_of_what_its_cell_shows_on_its_ground`,
  `thousands_of_instances_taken_out_of_a_few_cells_are_a_few_entities`,
  `a_saved_game_takes_out_the_same_instance_after_its_source_is_edited`,
  `an_instance_taken_out_later_sends_a_small_part_of_its_cell`,
  `the_instances_a_game_finds_are_those_the_world_shows`,
  `marks_of_play_are_one_entry_for_each_instance_of_their_cell`,
  `the_ground_of_foliage_is_read_where_the_ground_changed`,
  `foliage_is_kept_out_of_volumes_splines_and_colliders`,
  `the_ground_is_read_nearest_the_sources_first_and_each_tile_once`,
  `far_trees_stand_where_they_stand_near`.
- `mirai test plugins/foliage/runtime` (GPU with validation):
  `a_stalk_leans_away_from_where_a_bender_trampled_the_field`,
  `a_mesh_entity_that_sways_is_drawn_once_as_it_stands_and_casts_its_swaying_shadow`,
  `a_world_copied_for_play_draws_its_swaying_entities_once_and_leaves_nothing`,
  `a_swaying_wall_casts_its_shadow_where_it_leans_only_near_the_eye`,
  `a_swaying_canopy_is_shaded_as_it_is_at_rest`,
  `a_swaying_kind_builds_no_geometry_and_leaves_the_probes_still`,
  `a_swaying_kind_is_culled_by_cluster`,
  `a_kind_that_flutters_moves_its_leaves_on_their_own_and_one_that_does_not_stands`.
- `mirai test plugins/multiplayer/runtime`:
  `an_entity_with_a_replicated_object_component_reaches_a_client`.
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
  `tint_paints_the_instances_under_the_ring_into_the_source`,
  `a_point_past_what_a_foliage_holds_fails_naming_its_field`.
- `mirai test render`: `impostor_frames_cover_the_upper_hemisphere_and_fold_back`,
  `impostor_frames_spread_their_color_into_what_they_do_not_cover`,
  `a_batch_only_rays_meet_is_in_no_layer_and_the_picker_does_not_find_it`,
  `gpu_impostor_frames_keep_the_surface_of_their_material`.
- Shaders: `mirai shaders --project <project>`; visuals verified in `alien-planet` with GPU
  validation (close-up and >1 km captures).
