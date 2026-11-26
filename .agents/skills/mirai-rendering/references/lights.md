# Lights and shadows

## Local lights

- **Geometry & units:** Local lights are evenly lit spheres of `radius` (`Point_Light`,
  `Spot_Light`; 0 uses a minimum radius), capsules (their `length` along `+X` of the entity), or
  rectangles. All aim along `-Z`; points and spots never read the entity scale (`sphere_desc`),
  so a child keeps its own, while a rectangle is the unit square of its entity
  ([components](../../mirai-gameplay/references/libraries.md#render)). Color is independent of
  entity mesh tint; a smooth window zeros intensity at `range`.
- **Analytic shading:** Diffuse uses horizon-clipped sphere irradiance (Snyder; Lagarde-de
  Rousiers); specular uses nearest-point sphere approximation with energy-normalized lobe
  widening (Karis). Spots shine whole within `inner` of their half-angle `angle` and fade
  smoothly (`spot_fade`) to its edge; `inner` 1 is a hard edge. It travels in the top byte of
  `Gpu_Light.size.z` with the right of a projected texture (`light_spot_bits`).
- **Projected textures (`Spot_Light.texture`, `Rect_Light.texture`, `Light_Desc.texture`):**
  Multiplies light color across the cone (`Light_Desc.texture_axis`, +X) or rectangle face
  (overrides `Light_Emission`); point lights ignore textures. Evaluated once in
  `light_contribution` for direct, fog/media, glass, overlays, probes,
  particles, and portals (spots blur by `shading_footprint` on view surfaces; sharp elsewhere;
  grouped tree nodes treat textures as white). Stored in `Gpu_Light.size.w` with
  `GPU_LIGHT_TEXTURE` (or rectangle material row); no residency feedback
  ([residency](materials.md#residency-by-sampling)).
- **Shares (`Light_Desc.indirect`, `scattering`; `Sun_Desc`):** Packed as two halves in
  `Gpu_Light.axis.w` (`light_shares`) and averaged weighted by flux in `Light_Node.indirect` /
  `scattering`. Direct view light ignores them; 0 skips probe walks/cuts and media completely.
- **Lamps & emissives:** Shadow rays stop before the light's sphere bounds so lamp housings cast
  no self-shadow. Light-gathering rays treat emissive instances tightly enclosing a light as
  that light (`hit_on_light`) to prevent double counting. Emissives without lights bounce via GI.
- **Shadowless (`Light_Desc.shadowless`, `Sun_Desc.shadowless`):** Skips shadow maps, grid,
  cuts, and rays (`SUN_UNSHADOWED` for sun); routed to the shadowless tree.
- **CPU-known, stateless:** No light reservoirs or history — changes apply immediately. Lights
  are strictly scene-owned on CPU (never GPU-written or per-particle) so trees, grids, and
  shadow caches persist while lights stay still.
- **Lights of the frame (`Frame_Extras.lights`, `light_add`):** Take the first slots of the
  renderer, before entity lights (`extra_lights_settle`), up to the most a frame gave; entity
  lights that come or go never move them. A slot the frame leaves empty is turned off
  (`scene_light_off`: power 0, place and kind kept), so a flash that ends refits one leaf and
  changes no set; a slot reused by a light of another kind or reach class rebuilds the tree.
  Shadow maps and the light grid skip lights that are off.

```odin
// Game components (engine/render) and low-level Light_Desc:
spot := erender.SPOT_LIGHT_DEFAULT
spot.intensity, spot.range, spot.radius = 8000, 25, 0.1
spot.texture = gobo_tex_id
spot.indirect, spot.scattering = 1, 0.5
spot.shadows = true // false -> shadowless tree, zero shadow cost

rect := render.Light_Desc{
    position = {0, 3, 0}, color = {1, 0.95, 0.9}, intensity = 4000, range = 15,
    direction = {0, -1, 0}, axis = {1, 0, 0}, size = {2, 1},
    indirect = 1, scattering = 1, shadowless = false,
}
```

### Capsules and rectangles

- **Capsule (`length`, `axis`):** Sphere of `radius` swept along a segment; horizon-clipped
  segment irradiance (Picott).
- **Rectangle (`size`, `direction`, `axis`):** Emits along `-Z` (`axis` = right seen from lit
  side); exact horizon-clipped polygon irradiance (Arvo). `texture` or `material` emission tints
  diffuse (distance-filtered) and specular (lobe-filtered).
- **Units:** `intensity` is candelas for spheres/capsules/spots and nits for rectangles
  ([units](display.md#units)).

### Light tree

`render/light_tree.odin`:

- `light_tree_build` partitions omni vs directed lights and splits by 4x reach class
  (`light_reach_class`), then builds via PBRT-v4 SAOH (`light_bounds_cost`). Stored in depth
  order in `SLOT_LIGHT_TREE`; `light_node_opens` guards against malformed backward links.
- Each group stores aggregate sphere bounds + min/max range (midpoint window, span in error) and
  orientation cone (Conty Estévez & Kulla 2018; `node_aims` bounds spot/rect cone variance so
  downlights never leak onto ceilings).
- **Shadowless tree (`light_tree_shadowless`):** Appended after the shadowed tree (root at
  `shadowless_lights`; empty shadowed root is `LIGHT_NODE_NONE`). Evaluated via
  `shadowless_lighting` without rays from tile [lists](#lists-of-a-cell) in `direct_filter` or
  directly in `direct_lighting` and reference.
- **Updates:** Same count and classes refit incrementally (`scene_light_update`,
  `light_tree_refit`, full rebuild above `LIGHT_REFITS_MAX` or when `light_tree_cost` exceeds
  `LIGHT_TREE_REFIT_SLACK` in `scene_lights_settle`). Structural changes bump `light_revision`
  and upload whole.

### Unshadowed light of a pixel

`local_lighting` and `lights_estimate` traverse the tree, skipping out-of-range groups:

- A group represents its children as a sphere when its bounded error (falloff/cosine curvature,
  horizon straddling, reach spread) is small relative to total light (including sun + shadowed
  light); smoothly blends between represent and open thresholds; nearby groups always open.
- Bounded to `LIGHT_WALK_MAX` nodes per walk (LIFO when budget suffices; restarts
  priority-ordered only on overflow), keeping cost constant per frame regardless of light count.

### Lists of a cell

`render/light_lists.odin`, `light_lists.comp`, `light_lists.slang`:

- Screen tiles build per-frame lists of shadowless tree entries (leaf, always-grouped, or
  maybe-open + subtree) from tile position/normal bounds so pixels sum linearly without walking.
- **Exact walk equivalence:** Pixels weight list entries with `estimate_node` / `local_node`
  against their own estimate (no tile seams). Bounds use `LIGHTS_GROUPED` conservatively
  (omitting sun/shadowed light). Overflow falls back to per-pixel walk
  (`Stats.light_lists.walked`). Lists assume `LIGHT_SHARE_ALL` (probes/media require
  share-specific estimates).
- **Blended cells (`translucent_draws.comp`, `light_cells.slang`):** When the scene has shadowless
  lights, per-blended-instance (or subdivided from `TRANSLUCENT_CELLS`) cells hold the shadowless
  list. For shadowed lights, forward blends read the world [light grid](#direct-light-of-a-view)
  up to `light_budget` brightest reaching lights (falling back to `light_cut` past `DIRECT_FEW`),
  shadowed by a single-tap map lookup without tracing rays: at the level/mip of the view pixel
  (`Shading.footprint`, as the opaque surfaces beside it), read in the page of its texel or the
  nearest coarser one drawn (`shadow_texel`). Only a point no drawn page holds gets the light
  unshadowed, so never pick blend levels finer than the view's pages.

### Cutoff of a point that traces its own rays

- Isolated points (glass, overlays, diffuse-transmission back faces, probes)
  use `light_cut` instead of the view grid: opens highest-need nodes (widest/brightest, spots
  first) up to budget (`light_budget`, `PROBE_LIGHT_BUDGET`, max `LIGHT_CUT_MAX`).
- Each cut group traces one ray to a child picked proportionally to reflected BRDF luminance
  (unbiased `light / probability`).
- **Lit particles ([`vfx`](../../mirai-world/references/vfx.md#passes)):** Sum omnidirectional
  unshadowed estimates of both trees.

## Shadows

- Sun (`Settings.sun_radius`) and local lights (`radius`) cast area shadows that soften with
  occluder distance, stay sharp at contact, and stretch at grazing angles.
- Pixel cost scales with sample budget, not light count.

## Direct light of a view

The `direct` pass ([frame graph](frame-graph.md#passes)) distributes `direct_samples` per point:

- **Light grid (`render/light_grid.odin`, `light_grid.comp`):** World cells list reaching
  shadowed lights (alias table past `DIRECT_FEW`), rebuilt on GPU when lights change. Single
  weight formula in `light_weight.slang` (`light_weight_at`, `node_weight`).
- **Systematic spread:** 3x3 screen-pattern systematic sampling over light weights evaluates
  exact analytic shading once per chosen light times visible sample ratio.
- **Sun:** Points store sun visibility only; pixels evaluate sun BRDF with full-res normals.
  Covered points read shadow maps without spending samples; uncovered points sample sun as a
  light.
- **Rays & resolution (`direct_rays`, `direct_samples`):** 1 of 2x2 pixels traces full-scene
  primary rays and shares blockers with neighbors (HW ray queries trace directly).
  `direct_half_resolution` runs 1 point per 2x2 with zero temporal history (no trails).
- **Filter (`direct_points`, `direct_spread`, `direct_filter`):** Averages unshadowed local
  light over 3x3 pattern, filters visibility over blocker-derived penumbra width, then adds
  [shadowless lists](#lists-of-a-cell), [extension lights](views.md#extension-hooks-and-constants)
  (hard rays), and back-side `direct_lighting`.
- **Tiles (`direct_maps`, `Targets.direct_tiles`, `abi.DIRECT_TILES_*`):** While a view draws
  maps, `direct_maps` lists the 8x8 tiles with a sampled point, the 16x16 ray tiles over them and
  their 3x3 neighbours (whose blockers `direct_samples` reads) and the 64x64 spread blocks with a
  radius of a point or more plus the neighbour block within `DIRECT_SPREAD_MAX` of their border;
  rays, samples and spread run by indirect dispatch over those alone, bit-exact with all tiles
  (`Renderer.direct_every` lists every tile for the tests). A point without a surface leaves
  `direct_points.a = -1`, as the spread does, so a block it skips needs no write.
- **Shadow maps (`render/shadow_maps.odin`):** Built for large-screen local lights (cube faces
  or single spot cone) and sun cascades. Culled by map texel detail (`shadow_map_detail`,
  `shadow_map_unseen`, `shadow_culled` by eye cell), drawing opaque and masked clusters
  separately (masked uses texel-wide UV derivatives; no glass) via
  [`raster_lists.slang`](frame-graph.md#passes).

```slang
// Extension pass reading view shadow maps and marking pages for next frame:
#define SUN_SHADOW_SLOT SLOT_PASS5
#define SHADOW_DATA_SLOT SLOT_PASS6
#define SHADOW_MARKS_SLOT SLOT_PASS9
#define MIRAI_LIGHT_MAPS
#include "shadow_maps.slang"
// Odin record callback:
//   erender.pass_surface_read(pass, 5, .Shadow_Atlas)
//   erender.pass_shadow_data(pass, 6)
//   erender.pass_shadow_marks(pass, 9)
float vis = sun_shadow_seen(world_pos, float3(0), cell_width, true); // -1 -> ray fallback
```

## Pages of the shadow maps

- **Virtual pages:** Each map mip is a `SHADOW_PAGE` grid (sun cascades: 1 m first level, 2x per
  level, world-snapped). `shadow_mark.comp` marks pages for `SHADOW_TEXEL_PIXELS` (`sun_pick`,
  `light_pick`), `SHADOW_SEARCH_NEAR`, and coarser levels for wide blocker searches; `Ancestors`
  requests 2 coarser levels + 8 neighbors. `shadow_pages.comp` allocates from per-view pool
  (`shadow_pool_pages` <= `SHADOW_POOL_PAGES`, `SLOT_SHADOW_TABLE`) in fixed order: safety net
  first, then coarse-to-fine (overflow counted in `SHADOW_COUNT_LEFT`). Eviction preserves pages
  read within a jitter cycle (still) or previous frame (moving). Missing pages fall back to up
  to 2 coarser levels (`SHADOW_ENTRY_COARSER`, `SHADOW_HELD_COARSER`, `SHADOW_ENTRY_HELD` /
  `shadow_map_held`), or trace rays — never lit holes. `shadow_near` caches 2x2 page lookups;
  `shadow_beside` crosses cube faces; late passes mark via `pass_shadow_marks`.
- **Bounded per-frame work (`Shadow_Bound`):** Cache and atlas draws are budgeted in predicted
  raster units (`mesh_cluster_areas`, `shadow_units`, `SHADOW_UNIT_TEXELS`, weighted higher for
  masked foliage). Budget adapts from `SHADOW_FRAME_UNITS` up to `SHADOW_FRAME_UNITS_MOST` using
  `SHADOW_MAPS_TIMING` (`rhi.cmd_measure_begin`, target `SHADOW_MAPS_SHARE`, hard cap
  `SHADOW_MAPS_MOST_MS`) whenever `SHADOW_COUNT_SHORT > 0`; first frame always uses minimum.
  Instance/cluster culls are bounded (`shadow_reach`, `SHADOW_WORDS_SLOTS`/`SKIPPED`/`REACH`,
  `SHADOW_CHUNK_UNITS`). `Grant` prioritizes kept pages (`SHADOW_JOB_KEPT`), scales estimates
  (`SHADOW_WORDS_SCALE`), splits giant cache pages into row bands (`SHADOW_WORDS_BAND`), then
  refreshes swaying pages (`SHADOW_JOB_REFRESH`, `refresh_order`). Unfinished pages settle
  (`Finish`/`Settle`) to coarser/ray fallback and resume next frame.
- **Still views (`Shadow_Seen`):** After one jitter cycle with no camera/light/caster change,
  marking and page steps skip unless a new/waiting page triggers (`SHADOW_STEP_NEW`,
  `SHADOW_STEP_RUNS`, `Stats.shadow_marked`).
- **Cache vs atlas:** `Shadow_Raster.cache` redraws only changed sub-rects (`SHADOW_WORDS_PART`,
  `lod_error_pixels`, `SHADOW_PAGE_SOFT` keeps previous atlas while refreshing) and stores HiZ
  (`Shadow_Raster.hiz`) to cull occluded movers. Repeated movers (`SHADOW_MOVER_FRAMES`,
  `Scene_State.shadow_changes`) leave cache for `Shadow_Raster.atlas` until still; batch cull
  changes use cell-margin boxes (`SHADOW_CULL_MARGIN`, `shadow_cull_changes`). Moving lights/sun
  draw directly to atlas; origin jumps drop all pages.
- **Reading & invalidation:** Plane-slope bias avoids self-shadowing; `direct_spread` widens
  penumbras symmetrically; grazing ground spreads taps jitter-free. `Gpu_Frame.sun_maps` exposes
  sun cascades to later passes (`Surface_Source.Shadow_Atlas`). `Renderer.shadow_buffers` are
  shared; cache/atlas/pages are per view. Skinned meshes emit posed cluster boxes + vertex
  reach. `Scene_State.occluders` / `Gpu_Frame.moved` mark `occluder_changed` on
  hit/crossed/moved-light samples so TAA and
  [`fog`](../../mirai-plugins/references/render-plugins.md) drop stale history. `Stats.shadow`
  and `Stats.shadow_stale` (`engine.status`) diagnose redraw bursts.
- **Reference & limits:** `render/reference_test.odin` replaces `Direct` with unbiased
  stochastic rays. Low sample counts show penumbra noise until filtered; unmapped lights soften
  only as far as the filter window.

## What sways in the maps

- Swaying batches (`Batch_Desc.sway`, `batches_wind`, or moving deformables) use the vertex hook
  only in maps whose texel is narrower than at `SHADOW_SWAY_REACH` (`shadow_sway_texel`, never
  the coarsest sun cascade) and narrower than the sway amplitude; cluster boxes grow by current
  wind. Distant maps draw and cache at rest.
- Swaying casters rasterize into `Shadow_Raster.layer` (`SHADOW_SWAY_COARSER` levels coarser)
  and composite into the atlas (exact cache where coverage < 50%, tile plane inside, farthest
  depth on silhouettes; `SHADOW_SWAY_*`).
- **Rest-space coherence:** Rays and probes see batches at rest. `rest.comp` writes sway offset
  of the pixels of batches only; the others keep a stale texel that the depth stored with it
  rejects (`pixel_rest` in `gbuffer.slang`, `FRAME_FLAG_SWAY`; impostors use `pass_rest_write`) so
  shadow rays, contact occlusion, reflections, probes, and distant rest-cached maps query from
  the rest position while near swaying maps query the swayed position (`shadow_place`).

```sh
# Focal CPU and GPU tests for lights, trees, lists, and shadow maps:
mirai test render a_light_keeps_the_texture_it_projects_in_its_record --no-gpu
mirai test render render_sun_shadow_is_ray_traced render_many_lights_match_their_reference
```

- **Focal GPU tests (`render/render_test.odin`):** `render_sun_shadow_is_ray_traced`,
  `render_soft_shadow_blurs_with_the_distance_to_its_caster`,
  `render_soft_shadow_leaves_with_its_caster`, `render_a_low_sun_draws_out_the_end_of_a_shadow`,
  `render_a_wider_light_casts_a_softer_shadow`,
  `render_an_edge_takes_no_light_from_the_face_beyond_it`,
  `render_moved_cascades_give_what_whole_ones_give`,
  `render_shadow_maps_follow_what_moves_in_its_frame`,
  `render_shadow_maps_follow_a_pose_in_its_frame`,
  `render_a_swaying_batch_shades_where_it_is`,
  `render_a_batch_casts_no_shadow_past_its_cull_distance`,
  `render_a_page_first_read_is_drawn_in_its_frame`,
  `render_a_full_pool_keeps_the_pages_of_a_jitter_cycle`,
  `render_a_view_the_maps_cannot_hold_shows_no_lit_hole`,
  `render_a_frame_draws_no_more_than_its_bound_and_the_rest_comes_after`,
  `render_a_swaying_batch_keeps_its_pages_under_the_bound`,
  `render_a_swaying_batch_follows_its_sway_only_near_the_eye`,
  `render_a_swaying_forest_composes_again_only_what_is_near`,
  `render_a_wide_search_asks_for_coarser_pages_not_more_of_the_finest`,
  `render_a_turning_sun_gives_what_whole_maps_give`,
  `render_an_origin_jump_gives_what_whole_maps_give`,
  `render_a_light_without_shadows_lights_through_what_holds_it`,
  `render_a_mesh_without_shadows_lets_the_sun_through`,
  `render_many_lights_match_their_reference`,
  `render_lights_that_few_reach_at_a_time_are_each_lit`,
  `render_groups_of_lights_give_what_their_lights_give`,
  `lights_color_their_light_by_their_image`.
- **Focal CPU test:** `a_light_keeps_the_texture_it_projects_in_its_record`.
