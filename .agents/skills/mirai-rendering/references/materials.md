# Materials and textures

OpenPBR 1.1 model: glTF 2.0 metallic-roughness base with optional [layers](#layers-openpbr)
(coat, fuzz, specular anisotropy, diffuse transmission) and an unlit mode.

## Material row

- **Schema:** `asset.Material_Info` is the single schema; `render.Material_Desc` embeds it and
  adds resolved `textures`, `program_id`, and `custom_params`. Shaders get indices, modes, and
  defaults from the [generated schema](shaders.md#compilation).
- **GPU row (`Gpu_Material_Row`):** Layer blocks are read only when their `layers` bit is set.
  The shader writes `row` with the index used to read it; CPU leaves `row` at 0.
- Textures follow glTF channels (+Y tangent-space normals) and multiply their paired scalars.
  Row 0 is the default material; the Plane shape uses a `two_sided` default row.
- **Overlays (`overlay.frag.slang`):** Drawn over an instance's opaque base with the same mesh.
  `Alpha` covers lit; `Additive` adds light; `Multiply` filters base color unlit (independent of
  lighting and exposure).
- Instances may override all mesh materials with one row, tint base color, and add emission;
  material-less objects use row 0 tinted.
- **Per-instance overrides (`Instance_Material_Values`, `Material_Values`, `Material_Live`):**
  `instance_material_values_hold` / `instance_material_values_give` diff `gpu_material` once on
  CPU and store changed row/layer/parameter words at `Gpu_Instance.material_values`. Shaders
  read via `material_row`, `material_layers`, `material_parameters` (previews set
  `MIRAI_NO_INSTANCES` and skip the pool). Layer blocks stay populated even at weight 0 so
  instance overrides work.
- **Fade (`Instance_Material_Values.fade`):** Scales opacity on blended rows. Opaque/masked rows
  stay out of blend passes: raster dithers pixels via `fade_pixel_left` (bit-reversed temporal
  phase, TAA resolves smoothly), shadows use fixed thresholds, rays use direction-hashed
  `ray_fade_left`. Fade 1 is culled; fading slots are tested like masked; alpha-changing
  overrides reclassify instances (`instance_alpha`, `instance_material`).

```odin
// Override a Surface parameter, a standard field, or fade per entity (engine/render).
if live := erender.material_live(lives, entity); live != nil {
    erender.material_value(live, "progress", {0.5, 0, 0, 0}, slot = 0)
    erender.material_value(live, "roughness", {0.25, 0, 0, 0}, slot = 0)
}
// Persistent authored values (color.a drives fade; 1 - alpha -> fade):
values.color = {1, 0.8, 0.8, 0.5}
erender.material_texture(&values, base.name_hash("maps.mask"), 0, mask_tex_id)
```

## Evaluation

- Common PBR and Surface programs share `material_standard`; programs extend it with
  `mirai_surface_standard(ctx)`. Programs omitting it replace PBR values and neither load nor
  sample standard maps (`Program.standard`), while keeping `ctx.normal`, parameter textures,
  position, UV0/UV1, time, and LOD.
- **Vertex color:** Common PBR multiplies base color; programs read `ctx.vertex_color` (white if
  absent) and decide (`material_vertex_tint`). Instance tint multiplies both; `uniform_color`
  skips only the vertex-color multiply.
- **Object space:** `material_context_instance` supplies pivot, orthogonal scaled axes, and
  bounds (`mirai_object_point` divides by squared axis lengths); previews/extensions use world
  space. Vertex color and object match across G-buffer, translucents, overlays, coverage, and
  ray hits; each batch instance is its own object.
- **Wet (`ctx.wet`, 0..1):** Set per instance via [`instance_wet_set`](views.md#extension-stages)
  (0 without instance or in batches). `material_wet_apply` (Lagarde "Water drop 3b") runs after
  evaluation on all non-transmissive, lit materials: darkens rough dielectrics and lowers
  roughness while keeping F0. Programs read `ctx.wet` only to add effects.
- Masked coverage reads only opacity and mask map, program or not ([alpha](#alpha)).
- Non-default F0/F90 instances are cached; the reflectance target allocates lazily and is used
  only while such a box lies in the view or a nested frustum ([G-buffer](frame-graph.md#passes)).

## BRDF

- Lambert + GGX with height-correlated Smith visibility and Schlick Fresnel (`brdf.slang`). Uses
  `|n × h|²` for `1 − (n·h)²` to avoid area-light banding at `MIN_ROUGHNESS` (higher for point
  lights).
- Dielectric `F0` derives from `IOR >= 1` (`specular_ior`) with specular color/factor; metals use
  base color. `F90` preserves specular factor (including 0).
- OpenPBR albedo scaling (`base_diffuse_share`): diffuse and diffuse transmission receive
  `1 − max(directional_albedo)` of the base specular lobe for both direct and indirect light.
- **DFG table:** Integrated at startup by `dfg.comp` into `DFG_TEXTURE` (entry 0); restores
  Kulla-Conty multiple scattering on rough metals.
- **Units:** Light irradiance is stored divided by π (specular lobe multiplies by π;
  [units](display.md#units)). Emission is luminance in nits.

## Layers (OpenPBR)

- `asset.material_layers` sets row `layers` bits; Surface programs add bits for fields written
  on `Mirai_Surface`. `unlit` excludes all other layers. Layers only enable the
  [layers target](frame-graph.md) while visible; they never change scene lighting mode.
- **Stack order:** Fuzz over coat over base via albedo scaling (`shading_layers` prepares once
  for raster, `glass_shading`, `surface_shading`, GI, and studio; `shading_lobes` and
  `indirect_compose` match).

| Layer | Behavior and shader contract |
| --- | --- |
| Coat | GGX lobe with own normal, roughness, IOR; darkens base, relative IOR below (`material_specular`). |
| Fuzz | Zeltner-Burley-Chiang (2022) LTC + MaterialX adjustments; counted in diffuse filter lobe. |
| Diffuse transmission | Thin-sheet OpenPBR / `KHR_materials_diffuse_transmission`: back lit via inverted Lambert (`shading_back`, `back_irradiance`, `direct_lighting` rays). `LIGHTS_THROUGH` / `trace_through` crosses masked transmitting sheets only; GI reflects diffuse part only. |
| Anisotropy | Anisotropic GGX on MikkTSpace tangent rotated by `rotation`/map; bent normal for environment (Revie 2011), anisotropic VNDF for traced reflections. |
| Unlit | BSDF = 0 everywhere; outputs emission (nits or [relative](display.md#exposure-relative-emission)). Base color/opacity still govern coverage. |

- **Traced reflection:** `GBUFFER_TRACE_COAT` traces coat if it reflects at least what base lets
  through; the other lobe reads probes.
- **Zero-cost when unused:** `direct` and `composite` run `unlayered` (`MIRAI_GBUFFER_NO_LAYERS`)
  when no layered instance is visible; `reflect` runs `MIRAI_MATERIAL_NO_LAYERS` when none exist
  in the scene. Glass uses its `layers` variant of `glass_layer` only when layered glass is in
  view.

## Derived graph

`surface_parse` and `surface_graph` (`cook/shaders/surface.odin`, engine-time) derive a dataflow
graph per revision for checks and `material.program.inspect`. Source is the sole truth; the
graph is never stored or edited.

- Nodes cover `ctx.*`, parameters, constants, texture reads, variable/surface writes, calls,
  control flow, and opaque `code` blocks (`switch`).
- **Stable IDs:** `Program/function/name` with `#n` from the second write
  (`Ocean/evaluate/out.base_color#2`), re-resolved to lines per revision.
- Tracks value bounds/constness/normalization/tangent provenance and `Graph_Node.type` against
  `mirai_material.slang`.

## Indirect composition

`indirect_compose(Shading, Indirect)` (`brdf.slang`) is the single indirect-light formula across
composite, overlays, glass, glossy reflection hits, and studio previews.

- `indirect_lobes` (`scene.slang`) reads the probe volume once per requested lobe; specular uses
  the DFG table with multiple scattering and Lagarde-de Rousiers specular occlusion (also on
  traced reflections).
- Material ambient occlusion applies `occlusion_bounced` (Jimenez et al. 2016) to diffuse.

## Textures

- `.tex` files carry pre-built mips in final format (`cook/textures`,
  [imports](../../mirai-imports/references/imports.md#textures-cooktextures)); `host` uploads
  sampled levels via `texture_add_data`, starting at the first level `<= texture_max_size`.
- `texture_add` generates mips on CPU for runtime RGBA8 pixels; `texture_image` replaces pixels.

| Format | Use | Fallback without `Features.texture_bc` |
| --- | --- | --- |
| BC7 / BC1 | Color & alpha data / opaque data | Decoded to RGBA8 on CPU by `host` |
| BC5 / BC6H | Normals (Z rebuilt in shader) / HDR | Decoded to RGBA8 / RGBA16F on CPU |
| RGBA8 / RGBA16 / RGBA16F | Uncompressed color / data / HDR | Uploaded directly |

- **Arrays and cubes:** Uploaded whole via `texture_add_data` (`Texture_Data.layers`, `cube`),
  no streaming. The 2D texture table shows default white in their slot; materials, parameters,
  UI, decals, and sky receive `Unsupported` (`assets_texture_image`). No pass samples them yet.
- **Pool:** `texture_pool_megabytes` minus [texture view](views.md#texture-views) targets
  (`Stats.view_target_bytes`). Oversized non-streaming textures drop largest levels
  (`textures_reduced`). `host.assets_textures_reload` (called by `graphics_apply`) reloads
  affected textures smallest-to-largest when size, pool, or compression changes.
- **Filtering & table:** Shared trilinear repeat anisotropic sampler; G-buffer biases by
  `log2(render / output)` for TAA scaling. Capacity is `texture_capacity` minus
  `TEXTURE_RESERVED` (DFG + air); index is `TEXTURE_RESERVED + handle - 1`
  (`texture_index`, [table](rhi.md#bindings-and-texture-table)).

## Residency by sampling

Asset textures stream only sampled mips (`render/texture_residency.odin`,
`host/assets_streaming.odin`). Runtime/shared/extension textures keep uploaded levels.

- **Source:** `Texture_Data.source` and `level` link streamed mips back to `.tex`.
- **Feedback (`MIRAI_TEXTURE_FEEDBACK`):** G-buffer resolve (including nested views/programs),
  extension `Gbuffer`, glass layers, reflections, probes, and material points record per-texture
  atomic-min finest mip (one atomic per wave, helper lanes ignored; raster uses anisotropic
  derivatives + bias, rays use ray cones). `mirai_sample_texture_level` and `mirai_texture_size`
  pin all mips; `mirai_load_texture` skips feedback.
- **Cadence:** Runs on window frames and `Frame_Desc.streamed` offscreen frames. Programs and
  standard resolve rotate feedback every `TEXTURE_FEEDBACK_TURNS` frames (other turns run the
  `quiet` pipeline without recording). Decals, particles, sky, and UI do not report feedback.
- **Hysteresis & budget:** Promotions apply immediately; demotions wait `TEXTURE_FEEDBACK_FRAMES`
  at `TEXTURE_KEEP_LEVELS` coarser (`RESIDENT_KEEP`), bounded by `texture_max_size` and
  `TEXTURE_TAIL`. Unseen textures keep levels until pool pressure evicts them first, then
  farthest sampled ones (`texture_targets`, `textures_reduced`, `textures_pending`).
- **Streaming transaction:** `textures_update` runs between frames when feedback/pool/textures
  change. `app_textures_stream` (`app_frame_begin`) reads up to `TEXTURE_READS` mip ranges in
  jobs ([texture ranges](../../mirai-assets/references/kinds.md#texture),
  [load budget](../../mirai-core/references/host.md#loaded-assets)) and submits via
  `texture_levels_queue` (stale `stamp` dropped; `texture_stream_stop` halts missing files).
  Up to `TEXTURE_UPLOADS` textures stage rows within `UPLOAD_FRAME_BYTES` (shared with
  [geometry streaming](scene.md#geometry-over-several-frames)), copy resident mips on GPU, and
  swap atomically via `texture_uploads_install` (same handle/rows). `textures_shrink` copies on
  GPU without disk reads. Section loads and `texture_add_over_frames` enter at `TEXTURE_TAIL`
  first, never showing half mips.
- Single-layer BC textures may upload in field planes staged within the upload budget and
  reassembled by compute into scratch; CPU readers and layered textures join planes on load.

## Normal maps and specular antialiasing

- **MikkTSpace (`tangent_frame_normal` in `scene.slang`):** Interpolated unnormalized normal and
  tangent with `sign * cross(normal, tangent)` (mirrored instances flip sign; back faces flip
  frame; facing uses interpolated normal, not winding, via `fragment_turned`). Runtime meshes
  can supply `Mesh_Generate_Options.tangents`. Normal map UV transform rotates/mirrors RG
  without scale (`material_map_normal`); away-facing normals clamp to the silhouette.
- **Specular AA:** Widens roughness by normal variance (Tokuyoshi-Kaplanyan). Un-widened
  roughness is saved in Motion.B for [traced reflections](#traced-reflections); 2x2 direct-light
  points widen by block spread to prevent jitter flicker.

## Alpha

- **Mask (`mask`):** Coverage is `opacity * mask_map.a` (or `base_color` alpha if `maps.mask` is
  unset) vs `alpha_cutoff`; discarded everywhere (visibility, shadows, outlines, rays). Programs
  cannot control mask coverage: writing alpha on a masked material raises asset error `Coverage`
  (`engine.diagnostics`). Instances override masks via `maps.mask` in `Material_Values`. Only
  tested slots and fading instances pay for mask reads (`Gpu_Instance.tested`); native BLAS
  keeps tested mesh slots in separate geometry. Masked mips preserve alpha-test coverage ratio.
- **Blend (`blend`):** Drawn forward premultiplied over the lit scene; all contributions weight
  by `alpha`, with `1 - alpha` background passing through. Casts no shadows, skips G-buffer and
  bounces; sharp reflections see it only as a color filter ([glass in rays](#glass-in-rays)).

## Ray hits

- Probes, reflections, and glass read base color, metallic-roughness, and emission at ray-cone
  LOD; light-gathering rays skip lamp emission ([local lights](lights.md#local-lights)).
- Hits interpolate normals/tangents for normal maps and evaluate Surface programs with explicit
  LOD. Past the first bounce surfaces are diffuse (specular added to albedo); sharp reflections
  keep specular highlights except grazing direct-light sparks.

## Surface programs in rays and raster

Each Surface program compiles its own stages once ([programs](shaders.md#programs-and-stages)):

- **Raster (`program_graphics`, `program_stages.odin`):** `vis_resolve.frag` resolves once per
  visible program at program depth. Programs using dual UVs (`mirai_uv0`, `mirai_dual.slang`,
  `mirai_sample_texture(ctx, index, dual_uv)`) evaluate once per pixel; plain-UV/`ddx` programs
  re-evaluate discontinuous quads (`mirai_program_derivatives`). Cluster draws (glass,
  translucents, overlays, highlight) bind `SLOT_DRAW` per program; highlight runs program stages
  only for blended materials.
- **Rays (`points.odin`, `include/points.slang`):** Hits enqueue material points via wave atomic
  `points_take` and exit; `points_resolve` (`points.comp`) buckets points per program (skipped
  for 1 program), `surface_points__<Program>.comp` writes packed results, and `points_resume`
  continues (`points_rounds`). Buffer caps at `POINTS_MAX` (overflow falls back to material
  row). Used by reflections, probes, indirect reference, and glass.
- **Traversal coverage:** Masked rays test `hit_covers` / `material_mask` inline; no program
  runs in ray traversal.
- **Deferred filters:** Sharp reflection rays crossing program glass chain filter points
  (`point_filter_at`) and apply corrections on resume (`filters_weigh`, `filters_correction`).

```slang
//! mirai surface Rust_Reveal
//! use opaque
//! vertex reach reach
//! parameter mask_tex {"texture":true}
//! parameter progress {"default":1,"min":0,"max":1}
//! parameter reach {"default":0.5,"min":0,"max":10}
namespace Rust_Reveal {
struct Parameters { uint mask_tex; float progress; float reach; };
Mirai_Vertex vertex(Mirai_Vertex_Context ctx, Parameters p) {
    Mirai_Vertex v = mirai_vertex_default(ctx);
    v.position += ctx.normal * (p.reach * (1.0 - p.progress));
    return v;
}
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_standard(ctx);
    float m = mirai_sample_texture(ctx, p.mask_tex, mirai_uv0(ctx)).r;
    s.roughness = lerp(s.roughness, 0.9, saturate(m * p.progress));
    return s;
}
}
```

### Vertex functions

- Declared via `//! vertex [reach <metres>|reach <parameter>]` and
  `Mirai_Vertex vertex(Mirai_Vertex_Context ctx, Parameters p)` (`mirai_material.slang`; test
  fixture `Pieces` in `render/testdata/pieces.slang`).
- **Single posed mesh (`displace.odin`):** `surface_vertices__<Program>.comp` writes level-0
  current/previous vertices (`Skin_State.displaced`) before `Geometry`, feeding raster, shadows,
  rays (refit BLAS/tree like [skinning](scene.md#gpu-skinning)), outlines, and motion vectors.
- **Dirty-only execution:** Runs only when transform, material parameters, instance values, or
  time (if `vertex.reads` reads time) change. Bounds grow by `reach` per axis in mesh space.
- **Skins:** Displaced in-place after skinning (current and previous frames); deformables and
  batches are not displaced. While the pipeline builds, vertices remain at rest/previous pose.

### Program pipelines

- Startup builds all engine stages, points, and vertex pipelines for listed programs
  (`programs_listed`, `create_pipelines`) so frame 1 and runtime spawns never fall back.
- With a window or `--surface` (`App_Desc.shown`), `pipeline_thread` (`pipeline_thread.odin`,
  cores - 1) builds edited program pipelines (`program_stages_publish`, `programs_ask`,
  `pipelines_install`) asynchronously; until ready, stages draw material rows
  (`point_record_given`). Headless sessions/tests build synchronously.
- Thumbnails, captures, and impostors wait for pipelines (`renderer_pipelines_pending`,
  `renderer_pipelines_wait`, `host.app_pending`, `renderer_pipelines_made`). Extensions request
  program pipelines via `Stage_Pipeline_Desc.program` or `pass_gbuffer_pipeline(..., program)`.

### Program limits

- Particle collisions (`mirai_vfx_trace`) read vertex normal + row normal map, not program ones.
- **Focal tests (`mirai test render ...`):**
  - GPU: `material_program_shows_in_what_a_reflection_finds`,
    `material_program_shows_on_what_the_camera_sees`,
    `material_program_draws_as_its_rows_until_its_pipelines_are_made`,
    `material_program_pipelines_are_made_before_a_frame_draws_with_them`,
    `material_textures_color_the_bounced_light`,
    `material_program_moves_the_vertices_the_camera_the_rays_and_the_motion_see`,
    `gpu_a_program_moves_a_skin_after_its_skin_now_and_before`,
    `gi_reference_gives_the_light_of_a_white_furnace`
  - CPU (`--no-gpu`): `an_instance_whose_program_moves_vertices_shows_a_pose_of_its_own`

## LOD

- LODs arrive prebuilt from import
  ([levels](../../mirai-imports/references/imports.md#levels-of-detail)) or
  `host.assets_render_geometry_make`. `mesh_add` registers 1 level; each cluster owns 1 slot.
  Culling selection: [techniques](gi.md#lighting-techniques-and-optimization).

## Material previews and thumbnails

- Material picker renders antialiased spheres inline in the UI pass (no offscreen targets).
- `renderer_thumbnail` renders offscreen orthographic views (`thumbnail_view`, optional world
  `fit` box); `renderer_preview` draws document previews (`Preview_View`, `Preview_Light`)
  inside the frame; both use `studio.slang` (`FRAME_FLAG_STUDIO`, `studio_emission`) and the
  [previews curve](display.md#display-transform) without touching scene histories.
- `renderer_thumbnail_values` reads unclamped channels (`Thumbnail_Target`) for
  `material.preview.capture`; editor caches results via `renderer_set_thumbnails`.
- **Impostors (`render/impostor.odin`):** `impostor_capture` renders hemi-octahedral frames
  (`impostor` variant of `thumbnail.frag`) from CPU mesh copies + scene materials, returns mean
  transmission (`impostor_transmission`), dilates off-thread (`impostor_dilate`), and builds
  mips (`texture_build`, `texture_add_built`). Shaders mirror `impostor_direction` /
  `impostor_axes` ([foliage](../../mirai-world/references/foliage.md#far-impostor-and-crown)).

## Traced reflections

- **Selection:** Un-widened roughness (Motion.B) picks traced pixels, shared blocks, detail, and
  probe blend (`[0.5, 1.0] * reflection_roughness`). Specular AA widens ray cones; glass uses
  widened roughness.
- **Sampling:** Fixed-pattern stratified GGX VNDF (mirror below `MIRROR_ROUGHNESS`). Hits light
  directly up to `reflection_light_budget` (then [light tree](lights.md#local-lights)), reading
  view shadow maps where covered without tracing rays.
- **Modes (`Settings.reflections`):** `Off` (default, probes + sharp sky), `Traced` (2x2 shared
  ray from `REFLECTION_SHARED_ROUGHNESS`, probe-lit hits), `Detailed` (every pixel, direct-lit
  hits, glass color filters and specular hits below `REFLECTION_SHARED_ROUGHNESS`).
- **Filter:** Single-frame sliding tile average over strata (no temporal trail), weighted by
  surface similarity (edges stronger than wave relief).

## Glass

`transmission` enables glass (`KHR_materials_transmission`/`ior`/`volume`, `render/glass.odin`):

- **Shading & layers:** Transmissive materials draw as blend even when `opaque`; `mask` ignores
  transmission. Uses `shading_layers` (`glass_shading`, `glass_light`) and `shading_through`
  (coat tints transmitted light without double darkening). Closest layer traces base reflection;
  coat reads probes.
- **Sheet vs solid:** `thickness == 0` is a two-sided non-refracting sheet. `thickness > 0`
  refracts at entry/exit (closed mesh ray exit, 20% pane shortcut, open-mesh `sheet_through`
  relief refraction, Beer-Lambert `attenuation_color`/`attenuation_distance`, `scatter_color`).
- **From inside (`glass_inside.comp`):** Selects smallest `material_solid` box containing or
  within `GLASS_MEDIUM_NEAR` of the camera; back faces mark `GBUFFER_GLASS_EXIT` (Snell window +
  internal reflection), per-group upward ray confirms immersion, medium absorbs/scatters from
  eye to first layer or opaque depth.
- **Layers & culling:** Closest layers read a scene copy (rough glass blurs over a disc); deeper
  surfaces filter forward. Blend-only instances sit in `RAY_GLASS`. All glass passes skip when
  no transmissive instance is in frustum.
- **Limits:** No refraction behind layers, no caustics/dispersion, TAA uses background motion, 1
  immersed solid per view (no absorption between interior layers or on shadows/GI/particles).

```json
// Author a tinted solid glass material via `mirai rpc material.set`:
{
  "path": "materials/tinted_glass.mat",
  "values": {
    "base_color": [0.85, 0.96, 0.92], "roughness": 0.05,
    "transmission": 1.0, "ior": 1.5, "thickness": 0.2,
    "attenuation_color": [0.7, 0.95, 0.85], "attenuation_distance": 1.5
  }
}
```

### Glass in rays

- Only `Detailed` sharp reflections (`< REFLECTION_SHARED_ROUGHNESS`) filter through blended
  faces (`trace_glass_filter`, `BLEND_FILTERS`, deferred filters for programs), unbent, counting
  solid absorption once on entry.
- All other rays (`trace_visible` skips `RAY_GLASS`, probes, rough reflections, glass-behind
  rays, fog) ignore glass completely: glass never casts shadows or tints light. Use a textured
  light for colored projection.
- **Focal tests:** `material_glass_casts_no_shadow_in_rays`,
  `glass_lets_the_indirect_light_through_uncolored`.

## Limits

- No node-based material editor, virtual textures, subsurface scattering, iridescence,
  dispersion, or OpenPBR transmission outside glass.
- [Residency by sampling](#residency-by-sampling) does not track glass refraction rays or
  extension stages; glass layers omit sharp-reflection filtering and `glass_inside.comp`.
