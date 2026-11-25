# Views, cameras and extensions

## Frame and views

- **`Frame_Desc.views`:** Up to `VIEW_CAPACITY` `Frame_View` entries (camera, cut, pixel rect).
  Each slot owns its `Targets`, previous matrices, and histories; scene, geometry, materials,
  pipelines, and probes are shared (uploaded/updated once per frame). Window views share the
  [resolution budget](settings.md#scene-resolution).
- One command buffer renders all views and composes the LDR image (`renderer_capture` reads it;
  unused/disabled rects stay black). Panels and debug lines draw per view; screen UI once at
  end.
- **Cuts:** `Frame_Desc.camera_cut` / `renderer_camera_cut` reset histories and previous
  matrices for all views (never pipelines or probes); `Frame_View.camera_cut` resets only that
  view. `render.camera_view` sets `core.View.cut` on camera-entity switch.
- **Outputs & modes:**
  - `Frame_Desc.output`: copies final LDR to a shared texture
    ([player](../../mirai-core/references/host.md#the-player)); `texture_add_shared` /
    `texture_remove` expose [shared textures](rhi.md#textures-shared-between-processes) to UI.
  - `Frame_Desc.ui_only` / `App.ui_only`: draws screen UI over black without touching GPU scene.
  - `Frame_Desc.offscreen`: skips swapchain acquire/present (`present=false`) and never moves or
    updates probes. `host.app_capture_world` captures off-window worlds and leaves a camera cut.
    All-texture-view offscreen frames skip window targets (`host.app_world_draw` for previews).
  - `Frame_View.inspection` / `Frame_Desc.inspection`:
    [inspection modes](settings.md#inspection-modes) preserve targets and histories.
  - `Frame_Desc.time`: world seconds (`frame.time`); renderer derives `delta_time` from it.

### Pass of a view

- Each view records via an explicit `Pass` (`render/frame.odin`); no pass pulls targets or
  camera from `Renderer`. Technique targets allocate lazily (`ensure_*_targets`).
- Transient within-frame targets (`targets_frame`: G-buffer, direct, display, frame rays,
  contact, post stack) are shared across same-size views; persistent targets (histories, LDR,
  coverage, highlight) are per view. Main view drops scene targets/shadow pool once window views
  take over (`main_scene_release`).

## Cameras and layers

- `Camera`: `Perspective`, `Orthographic` (`height` in m), or `Custom` (view-to-clip, depth 1
  near, `w` depends only on depth), plus off-center `shift`, `far` (0 = infinite reversed-Z D32
  or `camera_reach`), `clip_plane`, and 16-bit `layers` (0 = all). Exposed via `engine/render`
  `Camera`, `Layers`, and `core.View` (`host.camera_from_view`).
- **Eye-relative projection:** Matrices project relative to the view's eye (`view_clip`,
  `view_clip_unjittered`, `view_clip_previous` from `frame.prev_eye`), preserving precision far
  from origin. Off-window worlds call `renderer_origin_follow` before scene sync.
- **Projection-agnostic shaders:** Shaders reconstruct `view_origin(uv) + d * view_ray(uv)`;
  `frame.eye` has `w=1` (point) or `w=0` (ortho dir); `view_depth` / `previous_depth` read depth
  planes; `frame.footprint` drives LOD, ray cones, and bias.
- **Clip plane & layers:** `clip_plane` uses `clip` vertex variants (`Features.clip_distance`)
  and culls as the 6th frustum plane. `Instance_Desc.layers` filters raster culling only; rays
  still see hidden layers.
- **Own body & parts:** `Instance_Desc.owner` (`1 + slot`, sets `INSTANCE_FLAG_OWNED`) lets
  `core.View.own` cull `own_hidden` layers (`Gpu_Frame.layers` bits 16..31) and dither `fade`
  (`Gpu_Frame.own`, 4x4 Bayer -> TAA, fade 1 culled). Still casts shadows/reflections and
  renders whole in nested views (`own=0`). Skinned meshes with a part keep a collapsed-part
  vertex copy for views hiding those layers ([skinning](scene.md#gpu-skinning)).

## Carried camera

`Frame_View.carried` / `core.View.carried` carries a rigid teleport transform applied to both
camera and visible scene since last frame, reprojecting histories instead of cutting them
(0 = none).

## Viewmodel

- `Scene_State.foreground[slot]`: the instances of `INSTANCE_FLAG_FOREGROUND` of a local slot
  (`Instance_Desc.foreground`, set by the sync on what hangs from an `engine/render.Viewmodel`
  under a body of `View_Bodies`), their field of view (`scene_set_foreground`) and the boxes of
  the weapon and the body (`scene_foreground_bodies`). A view whose `Camera.own` has one draws it
  (`render/foreground.odin`); no other view, cull, map or ray structure meets those instances.
- **Depth:** the world of that view is drawn below `FOREGROUND_DEPTH` (15/16) of its depth and of
  `glass_zbuffer` (`rhi.cmd_set_depth_range` names the targets it holds for); `inv_view_proj`
  takes the stored depth, so the pyramid and what decodes the depth target follow. After the
  G-buffer (and the `Gbuffer` stage) the viewmodel is culled (`FRAME_FLAG_FOREGROUND`), rastered
  above 15/16 and resolved over the G-buffer with its projection and its previous one (motion).
  The pyramid keeps the world alone: the next frame culls nothing behind the weapon.
- **Tag:** `foreground_tag.frag` writes `VIEWS_FOREGROUND` and the kept share (`VIEWS_KEPT`) into
  the views target: `min(1, (world depth - FOREGROUND_CLEARANCE) / its depth)`, from the world
  depth before the resolve. `pixel_at` returns the cleared place, `Pixel.true_position` the drawn
  one; `pixel_side` keeps it apart in spatial filters, `pixel_across` takes the maps of the world
  at `FOREGROUND_MARK_DEPTH` or farther, `pixel_rays_omitted` leaves `RAY_BODY`/`RAY_BODY_SMALL`
  out of its rays, contact occlusion skips it. A mask of nested views keeps the tags.
- **Maps:** `FOREGROUND_MAPS` squares of `FOREGROUND_MAP_SIDE` below the pool in the atlas
  (`FOREGROUND_MAP_SLOT`, read by the shared filter as they are): the weapon and the body
  (`FRAME_FLAG_BODY`) for the sun and `Gpu_Frame.foreground_light`. The maps of the world of the
  view leave out its body (`Shadow_Raster.body`: made anew when it changes, its moves stale
  nothing there); `direct_maps` multiplies a weapon pixel by its layer at its true place and a
  world pixel by the body layer.
- **Not yet:** glass, blends and overlays of the viewmodel; maps for more than the sun and one
  light; hardware rays from its pixels leave out every local body.

## Texture views

- `view_texture_add` / `view_texture_remove` manage sRGB RGBA8 table entries;
  `Frame_View.texture` renders **before** window views and copies via `rhi.cmd_copy_texture` in
  the same command buffer.
- Targets allocate lazily, evict after `TEXTURE_VIEW_IDLE_FRAMES` or LRU past
  `TEXTURE_VIEW_CAPACITY`, and deduct `Stats.view_target_bytes` from the
  [texture pool](materials.md#textures). Up to 8 views/frame (`host.extras_texture_view_add`).
- `readback=true` returns pixels asynchronously via `view_texture_pixels`;
  `view_texture_capture` blocks between frames. Texture views read previous-frame probes (except
  `Simulate` in textures-only frames) and omit outlines, grid, UI, and backdrop.

```odin
// Create, render with Light pipeline, poll async readback, and free (engine/render).
tex, ok := erender.view_texture_add(renderer, 512, 512, "cam_feed")
// In @(step="render"):
pipe := erender.pipeline_standard(renderer, .Light)
erender.view_texture_draw(
    extras, tex, cam_view, 512, 512, cut = false, pipeline = pipe, readback = true,
)
if pixels, frame_id, ready := erender.view_texture_pixels(renderer, tex); ready {
    _ = pixels; _ = frame_id
}
// On cleanup / release:
erender.view_texture_remove(renderer, tex)
```

## Nested views

- `Nested_View` renders up to `NESTED_VIEW_CAPACITY` non-recursive distance-preserving views
  (rigid or mirror via `to_world`/`previous`, `clip_plane`, `layers`) inside masked pixels of a
  view (`Features.clip_distance` required), sharing G-buffer, histories, and lighting.
- **Encoding:** Nested pixels store **negative** linear depth and `1 + index` in the R8 views
  target, which the first `pass_nested_add` of a frame makes and clears and shaders read through
  `pixel_view` only while `FRAME_FLAG_NESTED` is set: a view without nested views pays nothing.
  Always decode via `depth_empty`, `depth_distance`, `depth_nested`, `depth_same_side`
  (`depth.slang`) and `pixel_at` (`pixel.slang`). Spatial filters isolate sides
  (`depth_same_side`); temporal filters compare magnitudes.
- **Order:** (1) Main G-buffer + HiZ; (2) `Mask` stage writes mask and seals hardware depth at
  opening; (3) per nested view: cull, masked second depth (`Nested_View.rect` scissor),
  visibility + `nested` resolve. `Nested_View.opening` clips un-historied overlays.
- **Limits:** Glass, `Blend`, overlays, grid, and outlines do not draw inside nested pixels;
  main-view translucents/`Blend` clip against sealed depth.

## Render pipelines

A view executes a compiled `Render_Pipeline_Desc` (`render/pipeline.odin`, `erender.pipeline`):

- **Compile rules (returns handle or actionable error):**
  - Every non-optional read needs a prior writer; stages appear at most once; `Geometry`,
    `Composite`, and `Output` are required.
  - `Custom` passes write only compute-writable resources; previous-frame reads require
    `history` (builtin: `Taa`, `Hiz`); `Depth` (reversed) and `Exposure` are read-only.
  - Unread passes prune unless writing `history`/`kept` read later.
  - Writing `Taa` without `Resolve` requires `jitter = .Upscale` or `.None`.
  - Passes after `Output` write only `Generated` and custom resources; `Generated` is
    post-`Output` only.
- **Overrides & cache:** `Output` reads last written image (`Taa` replaces `Resolve`; `Display`
  reverts to unresolved). Custom `Direct` replaces `Direct`; custom `Gi` replaces `Indirect`
  (`FRAME_FLAG_GI_GIVEN`, carries previous frame, used by
  [indirect reference](gi.md#indirect-reference)). Cached by hash (`RENDER_PIPELINE_CAPACITY` =
  16; request each frame); `Standard_Pipeline` gives `Full` and `Light` (no
  `Reflections`/`Indirect`). Switching pipeline cuts histories.
- **Custom resources (`Custom0`..`Custom47`, `Render_Resource_Desc`):** Compute-writable
  textures or buffers (`bytes` or `pixel_bytes`), sized `Full`, `Output` (`shift`, `align`), or
  `Fixed`; `RENDER_MIPS_ALL` allocates full mip chains. Non-`history`/`kept` resources with
  disjoint lifetimes alias memory; `history` double-buffers and `kept` persists in-place (zeroed
  on cut).
- **Jitter & binding:** `Resolve` (16 TAA phases) or `Upscale` (`upscale_jitter_phases`); cuts
  reset `View_State.turn`. `Custom` passes bind via `pass_resource`, `pass_constants`,
  `pass_clear`, `pass_resource_write`, and `stage_pipeline({stage = .Custom, shader})` across
  `CUSTOM_PASS_SLOTS` (24: `SLOT_PASS0..9` + 14 scene-table slots via `CUSTOM_SLOT_n` in
  `custom_slots.slang`). `Reactive` is zero without `Blend` passes or additive materials.

```odin
// Build a custom pipeline replacing Resolve (e.g., upscaler plugin).
@(static, rodata) up_uses := [?]erender.Render_Use{
    {.Display, .Read, false}, {.Motion, .Read, false},
    {.Depth, .Read, false}, {.Taa, .Write, false},
}
custom := erender.Render_Pass_Desc{
    stage = .Custom, name = "upscale", record = upscale_record,
    user = state, uses = up_uses[:],
}
desc := erender.Render_Pipeline_Desc{
    passes = my_passes[:], resources = my_res[:], jitter = .Upscale,
}
if handle, err := erender.pipeline(renderer, desc); err == "" && handle != 0 {
    erender.pipeline_main(renderer, handle)
}
```

### Antialiasing techniques

Plugins register via `antialiasing_offer(renderer, name, label)` each frame; while
`Graphics_Settings.antialiasing` matches `name`, the plugin sets `pipeline_main`. Missing
plugins or shaders fall back to TAA (anything except `off`). `antialiasing_offered` lists
choices ([`fsr`](../../mirai-plugins/references/render-plugins.md#fsr)).

### Frame generation

- Post-`Output` `Custom` passes read pre-overlay `Ldr` and write output-sized `Generated` on
  presenting window views only (never texture views, captures, or headless), only when `history`
  is valid (`Stats.generated`).
- `overlays_pass` draws UI/lines/panels onto both `Ldr` and `Generated`; `compose_views` merges
  split screen; RHI uses [paced presentation](rhi.md#paced-presentation)
  (`swapchain_generated_texture`, `swapchain_texture`).
- Controlled by `Graphics_Settings.frame_generation` (High/Ultra on; disabled by
  `graphics_generates` if VSync or cap drops base FPS below `FRAME_GENERATION_BASE_MIN`).

## Extension stages

- Plugins access rendering strictly via `engine/render` (`extend.odin`);
  `renderer: ^erender.Renderer` is nil-safe without GPU. Request passes each frame in
  `@(step="render")` via `frame_pass(renderer, stage, record, user)` (max `FRAME_PASS_CAPACITY`
  = 32, deduped).
- `Stage_Pass` provides `stage`, target/output dimensions, `eye`, unjittered `view_projection`,
  `world` (`world_key`), `origin`, `frame`, `time`, `delta_time`, `glass`, `texture`, `camera`,
  `jitter`, and `history`/`history_frames`.

## Stages in frame order

| Stage | Scope / Pipeline parent | Role and key `pass_*` calls |
| --- | --- | --- |
| `Geometry` | 1x/frame (no view) / `Geometry` | Deformable vertices: `pass_vertices_begin`, `pass_deformable`, `pass_dispatch`. |
| `Decal` | Per view / `Geometry` | Before the resolve, after the decals of the scene: `pass_decal_targets`, `pass_decal_begin` (decal targets, no depth attached), `pass_surface_read .Depth`; `frame_decal_emission` asks for the emission target ([decals](materials.md#decals)). |
| `Simulate` | 1st view (not `ui_only`) / `Geometry` | GPU sim with scene tables, HW rays, probes, `pass_surface_read` depth/normal. |
| `Gbuffer` | Per view / `Geometry` | Lit custom geometry: `pass_gbuffer_begin`, `pass_gbuffer_pipeline`, `pass_depth_pyramid`, `pass_rest_write`. |
| `Mask` | Per view / `Nested` | Nested views: `pass_nested_add`/`pass_nested_faces`, `pass_mask_begin`..`pass_end`. |
| `Lit` | Per view (no inspect) / `Lit` | Read-write `rgba16f` opaque image (`pass_image_bind`), runs `Behind`/`Front` if glass (`Glass_Depth`). |
| `Blend` | Per view (no inspect) / `Transparency` | Forward blend (`pass_blend_begin`, TAA coverage), runs `Behind`/`Front` if glass (`Glass_Depth`). |
| `Post` | Per view (no inspect) / `Output` | Output-size resolved image (`pass_image_write` ping-pong, never in-place; reads G-buffer). |
| `Effect` | Per `effect_views` | Offscreen UI effects (`Stage_Pass.texture`, `pass_blend_begin`, empty depth). |
| `Custom` | Pipeline-placed | Compute over declared `pass_resource` slots; rejected by `frame_pass`. |
| `Inspect` | View `View_Inspection` | Debug `rgba16f` [0,1] output via `pass_image_bind`; rejected by `frame_pass`. |

- **`Gbuffer` details:** Declare meshes/materials each frame with `frame_gbuffer_mesh` so views
  allocate reflectance/layers targets. Vertex shaders fill `Gbuffer_Vertex`
  (`include/gbuffer_vertex.slang`, `gbuffer_vertex_place`, `material_vertex_tint`, instance 0).
  Custom fragments provide `plain`/`layers` variants (`gbuffer.slang`). Use `pass_depth_pyramid`
  (`pyramid_hides`), `pass_depth_pyramid_build`, and `pass_mesh_programs`/`pass_material_program`
  for Surface program draws.

```odin
// Register and record a Lit compute pass with a per-view history texture (engine/render).
@(step="render", loops="game editor", after="render_sync")
my_render :: proc(state: ^My_State, app: ^host.App) {
    state.pipe = erender.stage_pipeline(app.renderer, {stage = .Lit, shader = "my_lit"})
    if state.pipe != 0 { erender.frame_pass(app.renderer, .Lit, my_lit_record, state) }
}
my_lit_record :: proc(pass: ^erender.Pass, user: rawptr) {
    state := cast(^My_State)user
    if pass.glass == .Front { return }
    tex := erender.Pass_Texture_Desc{
        name = "my_accum", format = .RGBA16_Float,
        width = pass.width, height = pass.height, history = true,
    }
    if ok, _ := erender.pass_texture(pass, 1, tex); !ok { return }
    erender.pass_image_bind(pass, 0)
    erender.pass_surface_read(pass, 2, .Linear_Depth)
    erender.pass_timestamp(pass, "my lit")
    erender.pass_pipeline(pass, state.pipe)
    erender.pass_dispatch(pass, (pass.width + 7) / 8, (pass.height + 7) / 8)
}
```

## Restrictions of the `pass_*`

- `pass_params` and `pass_upload` return `false` when frame memory is exhausted (skip the draw).
- `pass_surface_read(..., .Instance)` returns `instance + 1` (batch instances from
  `frame.instance_count`, read via `scene_instance`) only when shaders declare
  `//! mirai needs instance_ids`; otherwise reads 0.
- **Single writers:** `instance_wet_set` ->
  [`water`](../../mirai-world/references/water.md#what-physics-shows); `colors_load` /
  `instance_colors_set` -> [`paint`](../../mirai-plugins/references/plugins.md#paint).
- `pass_scissor` clips draws; `pass_timestamp` groups GPU timings (`profile.capture`,
  `engine.status`). Renderer rebinds scene tables after each stage. Plugins own no GPU objects.

| Resource | API & capacity | Lifecycle & rules |
| --- | --- | --- |
| View texture | `pass_texture` / `_sample` / `pass_volume_sample` (`EXTENSION_TEXTURE_CAPACITY` = 8/view) | 2D, 2D array (`layers`), 3D (`depth`), `mips` (`mip=-1` read all), `history` (`kept` false on cut/first/skip); freed after 1 unrequested frame. |
| View media | `MEDIA_TEXTURE`, `pass_media`, `media_over` (`media_grid.slang`) | Written in `Lit` by [`fog`](../../mirai-plugins/references/render-plugins.md#fog); sampled in later blend passes. |
| World buffer | `pass_buffer` / `_write` / `_fill` / `_held` (`EXTENSION_BUFFER_CAPACITY` = 64) | Persists per `world` until `buffer_release` in `release`; indirect args (`pass_dispatch_indirect`, `pass_draw_indexed_indirect`, `pass_indices`). |
| Table texture | `table_texture` / `pass_table_texture_copy` (`EXTENSION_TABLE_TEXTURE_CAPACITY`) | RGBA16F per world readable by materials; transaction to create/resize; free via `table_texture_release`. |
| Frame rows | `pass_rows_upload` / `pass_rows` | Uploaded once per `Pass.frame` into frame memory. |
| Counters | `pass_counters` / `erender.counters` (`EXTENSION_COUNTER_CAPACITY` = 16) | 4x `u32` zeroed per frame; read 2 frames later (`Stats.counters`). |
| Readbacks | `pass_readback` / `erender.readback` (`EXTENSION_READBACK_CAPACITY`) | Async end-of-frame copy; presentation-only (never `fixed`); `readback_release`. |
| Stage pipeline | `stage_pipeline` / `pass_stage_pipeline` (`STAGE_PIPELINE_CAPACITY` = 64) | Request each frame (0 if missing); tracing compute needs `//! variant hw`; graphics program variant needs `//! per surface program`. |

## Extension hooks and constants

Declared via directives in plugin/project `shaders/` (`cook/shaders/extensions.odin`):

- `//! mirai frame <Struct> <name>`: included before `Frame_Data` (no engine types; separate
  file from hooks); CPU writes via `pass_extension_data(pass, "<name>")`; layout published in
  `catalog.json` (`Renderer.frame_layout`).
- `//! mirai needs nested_views` / `needs instance_ids` (appends R32 uint G-buffer target).
- `//! mirai hook ray|lights|probes|vertex ...`: `ray`, `probes`, and `vertex` allow 1 source
  per generation (`probes`/`vertex` in own files); `lights` aggregate across all sources.
- `//! mirai constant <NAME> <int|uint|float> <file.odin>`: shares Odin constants
  ([compilation](shaders.md#compilation)).
- Generation emits `include/extensions.slang`, `extension_hooks.slang`, and
  `extension_probes.slang` (empty without extensions -> byte-identical engine stages).
- **Common error:** Every stage including `trace.slang` or `lighting.slang` must include
  `<extension_hooks.slang>` afterwards or linking fails when hooks are active.
- **Hook contracts:**
  - `mirai_ray_gate` (`trace.slang`): redirects rays without tracing (max 2 segments; shadow
    rays crossing a gate are blocked).
  - `mirai_probe_gate`: blends `sample_probes_around` across openings.
  - Vertex hook: two-part batch displacement (per-cluster at current/previous time, then
    per-vertex if nonzero); raster and [swaying maps](lights.md#what-sways-in-the-maps) only
    (rays see rest).
  - `mirai_extension_light_count` + `Extension_Light` (`lighting.slang`): hard-ray lights added
    in [direct filter](lights.md#direct-light-of-a-view) and `direct_lighting`.

```slang
// Extension frame block + constant + light hook headers (separate frame and hook files):
//! mirai frame My_Frame my_ext
struct My_Frame { float4 params; };

//! mirai constant MY_CAP int ../runtime/my_ext.odin
//! mirai needs instance_ids
//! mirai hook lights my_light_count my_light_at
```

## Batches

`engine/render` exposes [instance batches](scene.md#instance-batches) (`batch_set`,
`batch_remove`, `batches_epoch`, `batch_desc`, `batch_instance`) scoped by `core.World_Id`.
Store handles in a `by_world` storage and call `batch_remove` in `release` (re-create if
`batches_epoch` changes).

## Deformable meshes

- `deformable_create(renderer, source)` clones level 0 for GPU deformation (`mesh_remove`
  frees).
- Call `deformable_update` with mesh-space bounds on changing frames and write vertices in
  `Geometry` (`pass_deformable` -> `Posed_Vertex` via `posed_load`/`posed_store` in
  `posed.slang`; vertex colors via `mesh_vertex_color` in `geometry.slang`). Renderer copies
  current -> previous before `Geometry` and refits BLAS afterwards; stopping triggers one
  equalizing pass.
- Set `Batch_Desc.sway` for [swaying shadows](lights.md#what-sways-in-the-maps); monitor
  `vertices_made` to rewrite if the vertex pool reallocates.

## Geometry for extensions

Load transactions: `mesh_triangles` (level-0 CPU copy), `texture_add` / `texture_remove`
(`texture_index`), and `impostor_capture`
([materials](materials.md#material-previews-and-thumbnails)).

## Skinned meshes

- `skin_create(renderer, source, influences, joint_count, morph={}, part=false)` registers a
  GPU-skinned copy (load transaction; large meshes stream over frames while `mesh_uploading`).
- `skin_update(renderer, handle, palette, reset_motion=false, morph_weights=nil, part={})`
  uploads bind-to-mesh matrices and morph weights; `skin_palette` reads current/previous 3x4
  rows for extensions (e.g., particle bones); `mesh_remove` frees.
