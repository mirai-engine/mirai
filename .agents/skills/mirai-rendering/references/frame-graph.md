# Frame graph

Passes run on GPU; CPU uploads dirty data through the frame ring. Texture views record before
window views. Passes 2–15 form standard `Full`; custom [pipelines](views.md#render-pipelines) may
omit or interleave stages.

## Passes

1. **upload & air.** Dirty pose skinning; dirty instances/materials/lights +
   [tree](lights.md#local-lights); `Geometry` extensions; ray refit + hw TLAS; new
   [whole-mesh](scene.md#scene-and-instances) indices (overflows defer a frame). Then
   [atmosphere](gi.md#atmosphere) tables (`air`) and per-view sky row / aerial on eye/sun move.
2. **cull (phase 0)** (`cull.comp`, `cull_clusters.comp`, `cull_bins.comp`). Batch boxes ->
   instances + batch slots (prev transform vs prev pyramid) -> <= 64 cluster chunks -> cluster LOD
   (`cut.slang`, `lod_error_pixels`), frustum, normal cone, pyramid. Bins clusters (two-sided /
   tested depth-bucketed nearest-first), enables Surface program resolves and glass dispatches;
   all-blend skips opaque cull.
3. **visibility & resolve.** Per-round compute (`raster_lists.slang`, `Cull_List.Raster_*`, up to
   `RASTER_ROUNDS`, `Device_Info.subpixel_bits` margin) emits vertices/triangles. `visibility.slang`
   rasters 1 indexed indirect draw/bin (untested: no discard; tested: nearest-first via fade +
   [mask map](materials.md#alpha), no feedback; no blends). `vis_classify.frag` writes 16-bit
   program depth; early-Z equal resolve runs material once/pixel (`gbuffer_build.slang`,
   `gbuffer_output.slang`; read only via `include/gbuffer.slang`). Optional reflectance/layers
   targets exist only when visible (`frame_gbuffer_mesh`, `frame_mesh_whole` pins level-0 pages;
   nested views after `Mask` backfill reflectance + `FRAME_FLAG_REFLECTANCE`).
4. **occlusion & extension geometry.** Depth pyramid of the farthest reverse Z (gathers, 4x4
   footprint, +1 step; `pyramid_hides` compares projected depth with a slack) -> phase 1
   retest/raster -> rebuild pyramid (`pass_depth_pyramid_build` for `Gbuffer` extensions).
   `Stats.resolved_pixels`, `resolve_helpers`, `resolve_quads_again` (counted only while
   `Renderer.resolve_counted`: atomics per wave); `Stats.cull_dropped` grows
   lists and caches peaks in `Capacity_Marks` (`host/capacities.odin`). Runs `Simulate` (first
   window view, or texture view if textures-only; [particles](../../mirai-world/references/vfx.md)),
   `Gbuffer`, `Mask` and [nested](views.md#nested-views) G-buffers. Before the resolve, while the
   scene has a [decal](materials.md#decals) or an extension asks for `Decal`: `decal_draws.comp`
   culls the decal list, `decal.vert`/`decal.frag` draw it into the decal targets against the
   final depth, then the `Decal` stage; the resolve applies them (constant `decals`).
5. **direct.** Sun, local and [extension](views.md#extension-hooks-and-constants) lights (diffuse +
   GGX): light grid, shadow maps, `direct_rays` (1/2x2), `direct_samples`, `direct_points`,
   `direct_spread`, `direct_filter`, shadowless `light_lists`
   ([direct light](lights.md#direct-light-of-a-view)). Glass/overlays/back-side use
   `direct_lighting`.
6. **ddgi.** First window view updates [probe volume](gi.md#probe-volume) by priority; still scenes
   update only time-reading Surface programs in turns.
7. **contact.** [Contact occlusion](gi.md#contact-occlusion) short rays + probe light to pixels.
8. **composite.** `direct + indirect_compose + emission`
   ([composition](materials.md#indirect-composition)) or [inspection](settings.md#inspection-modes)
   + aerial + background [grid](#reference-grid). Specular reads probe volume and sky. Runs
   [`Lit`](views.md#extension-stages) (with glass visible, step 10 layer raster runs earlier so
   `Lit` runs behind and in front of nearest layer).
9. **overlay.** <= 4 Surface materials/instance over opaque/masked (depth-equal, no write,
   excluded from BVH/TLAS, [overlays](../../mirai-core/references/host.md#loaded-assets)).
10. **translucent.** Peels nearest glass layers; draws forward blends + overflow glass
    back-to-front against opaque depth (pyramid-culled; nearer-than-glass draws only in front).
    Additive materials add their coverage to `Targets.reactive` in the same pass.
11. **glass.** Shades layers back-to-front ([glass](materials.md#glass); culled when absent). Runs
    `Blend` (behind after peels, front after glass; once after composite without glass), front
    `Lit` and `glass_inside`. After each `Blend` side that drew into the distortion target
    (`pass_distortion_begin`), `distortion apply` copies `display` into `scene_copy` and displaces
    it once per pixel (`distortion.frag`), adding to `Targets.reactive`. `scene_copy` is the one
    copy glass and distortion share: behind applies before the glass snapshot, front after
    `glass_inside`.
12. **taa.** Upscales to window: 10% moving, <= 64-frame still average (4x16 jitter,
    `Targets.taa_frames`), 3x3 YCoCg variance clamp (`TAA_STILL_GAMMA` widens when still),
    exposed-compressed weights (render-unit history), `Targets.reactive` (`Blend` and additive
    coverage) and shadow-change marks (not passed to upscalers), depth in alpha, disocclusion reset
    (preserves still edges/thin wires).
13. **exposure & HDR post.** Pre-TAA [exposure](display.md#exposure) meter, `Post` stage, ordered
    HDR PostProcess stack per `Camera.slot` (`renderer_set_view_postprocesses`) or frame
    (`renderer_set_postprocesses`): mid-gray 0.18, lazy targets, `fade` 0 skips, reads only
    `Output` `stage_contract` (linear depth, normal, outline mask), timed `postprocess hdr 1`,
    capped by `View_Inspection.postprocess`.
14. **tonemap, LDR post & UI.** Exposure + [display LUT](display.md#display-transform) + fixed
    1-LSB triangular dither (null at 0/1) -> [outlines](#outlines) -> LDR PostProcess -> world
    panels -> debug lines -> [UI layers](ui.md#ui-world-panels-and-debug-lines).
15. **present.** Copy to swapchain; retains LDR for `renderer_capture`.

```slang
#define GBUFFER_ALBEDO SLOT_PASS0
#define GBUFFER_NORMAL SLOT_PASS1
#define GBUFFER_EMISSION SLOT_PASS2
#include "gbuffer.slang"

Gbuffer_Pixel g = gbuffer_read(p);
Shading s = gbuffer_shading(g, pixel);
float3 rest_pos = pixel.position - pixel_rest(p, linear_depth);
```

## Outlines

- Unified editor (`Renderer.highlight`) and game (`Renderer.outlines`, `outline_level`,
  [`Outline`](../../mirai-gameplay/references/libraries.md#render)) via `Instance_Desc.highlight`
  and `Highlight_Style`. Editor levels override and cover game styles (`instance_outline`,
  [editor shapes](../../mirai-editor/references/editor.md#figures-of-whoever-works)).
  `highlight_levels_shown` lists active levels (all game styles stay active for PostProcess masks).
- **Mask, occlusion & filter.** Drawn after G-buffer into own depth at unjittered point resolution
  (ignores `Settings.resolution`), honoring alpha cutoff; PostProcess (`mirai_outline`) sees game
  styles only. Occlusion tests 2x2 scene depth (`include/highlight.slang`), scaling by
  `Highlight_Style.behind`. Premultiplied compute filters conservative screen bound (+ radius; full
  screen if crossing camera plane) for tonemap; camera move updates bound without scene/TLAS
  rebuilds. `outline_only` draws only in mask (`highlight_drawn`).

```odin
r.outlines.width = 2.5
r.outlines.colors[0] = {0.2, 0.9, 1.0, 1.0}
r.outlines.behind[0] = 0.3
inst.highlight = render.outline_level(1)
```

## Reference grid

- `Environment.ground_grid` draws a procedural Y=0 plane in composite background (antialiased
  lines, X/Z axes, quadrants, distance fade), depth-limited, blend-attenuated, TAA-reprojected,
  with no meshes/picking/shadows/bounds. `scene_set_environment` updates without TLAS rebuild;
  preview lighting resets histories and clears probes in place.

## Statistics

- `renderer_stats` reports GPU intervals (`cmd_timestamp` under `host.profile_request` /
  `rhi.timestamps_want`, else `frame` + always-on `cmd_measure_begin`/`cmd_measure_end` for shadow
  maps), cull/probe/ray counts, capacity drops ([UI](ui.md#capacities)), textures/memory/compression
  ([materials](materials.md#textures)) and `Stats.counters`.
- Intervals align to `time.tick_now` (Metal encoder boundaries + CPU/GPU pair; Vulkan
  `VK_KHR_calibrated_timestamps`/EXT, else placed late at collect). `renderer_gpu_submissions` /
  `renderer_gpu_clear` (`rhi.frame_timings`) capture every submission of a host frame
  (`Stats.timings` holds only the last finished).
- **Per-mesh/material cost (`profile.cost`).** `renderer_cost_ask` / `renderer_cost` bind `cost`
  variants on the first non-cut frame of the first window view (visibility pixels + forward
  fragments per filter/light pair). GPU timings name peels `glass layers` and forward `translucent`.

```odin
for sub in render.renderer_gpu_submissions(r) { _ = sub.timings }
render.renderer_gpu_clear(r)
if problem := render.renderer_cost_ask(r); problem == "" {
    if cost, ready := render.renderer_cost(r); ready { _ = cost.meshes }
}
```
