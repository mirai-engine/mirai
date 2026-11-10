# Views, cameras and extensions

## Frame and views

- **`Frame_Desc.views`**: up to `VIEW_CAPACITY` `Frame_View` with camera, cut and rectangle in
  drawable pixels. Each view slot has its `Targets`, previous matrices and histories; scene,
  geometry, materials, pipelines and probes are shared, and the scene upload and the probe update
  run once per frame.
- One command buffer renders the views and composes them into the complete LDR, which is what
  `renderer_capture` reads. Empty or `disabled` regions stay black.
- Panels and lines are drawn in each view; the screen UI, once at the end.
- The window views share the pixel budget of the settings
  ([resolution](settings.md#scene-resolution)).
- Changing count, size or settings recreates the affected targets; stable frames reuse memory and
  resources.
- **`Frame_Desc.camera_cut`** resets the screen histories (TAA, reflections, shadows, glass, HiZ)
  and the previous matrix; it does not recreate pipelines or discard probes. `render.camera_view`
  activates it (`core.View.cut`, which `host` reads when running the `render` phase) when the
  camera entity changes.
- `renderer_camera_cut` invalidates all the views; the cut of a `Frame_View`, only its own.
- **`Frame_Desc.output`** also copies the finished image to a texture of the frame's size, ready
  to sample: the shared texture of the [player](../../mirai-core/references/host.md#the-player)
  that the editor shows.
- **`Frame_Desc.ui_only`** draws only the screen UI over black (the editor while its viewport
  shows the players of a network game or an asset document covers the scene). With `App.ui_only`,
  `render_sync` does not touch the GPU scene: a world drawn between frames keeps it without
  rebuilds and the displayed one resumes it when it is drawn again.
- `texture_add_shared(r, shared, width, height, format, name)` opens a
  [shared texture](rhi.md#textures-shared-between-processes) as a table entry to draw it in the UI;
  `texture_remove` frees it.
- **`Frame_Desc.offscreen`** draws only into the LDR image that `renderer_capture` reads:
  `rhi.frame_begin(d, present=false)` does not acquire a swapchain image and the frame is not
  presented.
  - That frame neither moves nor updates the probe volume or the world's radiance cache.
  - `host.app_capture_world` uses it for a world that is not shown (an AI turn): it runs its `Ui`
    and `Render` phases, draws several frames with a camera cut in the first, writes the PNG and
    leaves `renderer_camera_cut` for the window's next frame. `render_sync` rebuilds the GPU scene
    when returning to the displayed world.
  - An offscreen frame whose views are all texture views is **textures only**: it touches neither
    the window views nor their targets, does not draw the main one and what runs once per frame
    goes with the first texture view.
  - `host.app_world_draw` draws this way, between frames, a world of its own into a texture: each
    frame it moves its clocks with the `Fixed` phase of the editor loop and draws it with the
    `Render` phase of its game, and returns the window's camera and time as they were. The editor's
    particle previews use it ([vfx](../../mirai-world/references/vfx-editor.md)).
- **`Frame_View.inspection`** (and `Frame_Desc.inspection` for the view of a frame without views):
  what that view shows instead of its lit image
  ([inspection modes](settings.md#inspection-modes)). Changing it keeps targets and histories; a
  view without it, texture views included, is seen lit.
- **`Frame_Desc.time`**: seconds of the displayed world: in Play, the game's; outside Play, the sum
  of the `dt` of the application's frames (`App.seconds`), the fixed one in a manual run. Programs
  read it in `frame.time` and the renderer derives its time step from it.

### Pass of a view

Each view is recorded with an explicit `Pass` (`render/frame.odin`) with its `View_State`, camera
and constants: no pass reads targets or camera from the renderer. The targets of a technique are
created the first time a view uses it (`ensure_*_targets`).

## Cameras and layers

`Camera` describes the projection (perspective, orthographic or a custom matrix), its off-center
`shift`, a `clip_plane` and the `layers` it draws. Rules:

- `projection`: `Perspective`; `Orthographic` with `height` in meters from bottom to top; or
  `Custom` with the `custom` matrix from view to clip (depth 1 at the nearest, `w` a function of
  depth only).
- `shift`: center of the projection in halves of the view (off-center frustum).
- `far`: far plane; 0, the default, none: a perspective sees to infinity (reversed Z in D32 keeps
  precision) and an orthographic to the far side of the scene (`camera_reach`).
- `clip_plane`: world plane behind which nothing is drawn, with any projection.
- `layers`: layers that the view draws (0: all).

Rules:

- **From the eye.** The matrices of a view (`view`, `view_proj` and the others) take a point from
  its eye, not from the render origin: it is projected with `view_clip`, `view_clip_unjittered`
  and `view_clip_previous` (this one from `frame.prev_eye`), never by multiplying a place by the
  matrix. This way a view far from the origin (texture, split screen, `offscreen` capture) keeps
  the precision of the places it receives.
- **A world drawn between frames** (preview, thumbnail, capture of another world) first moves the
  origin to the eye of its `View` (`renderer_origin_follow` from `host.app_world_draw` and
  `app_capture_world`), before its render phase gives its places to the scene: the scene stores
  them relative to the origin and, far from it, they would lose what projecting from the eye no
  longer recovers. The window's next frame returns it to its eye.
- **Ray per pixel.** No shader inverts the projection or assumes perspective. The point at linear
  depth `d` of pixel `uv` is `view_origin(uv) + d * view_ray(uv)` (`eye_origin/du/dv` and
  `ray_origin/du/dv` in the constants).
- `frame.eye` is the eye as a point (`w=1`) or the direction toward it in a parallel projection
  (`w=0`); `to_eye` and `eye_distance` read it.
- `frame.depth_plane` and `prev_depth_plane` give the linear depth of a world point for the
  current and the previous camera (`view_depth`, `previous_depth`).
- `frame.footprint`: width of a pixel at depth 0 and its growth per unit of depth; texture LOD,
  ray cones and bias come from it.
- **Clip plane.** A view with `clip_plane` uses the `clip` variant of the G-buffer vertex stage
  (`SV_ClipDistance`), which exist with `Features.clip_distance`; the cull uses it as the sixth
  frustum plane.
- **Layers.** `Instance_Desc.layers` (16 bits; 0: only the first) says in which layers an instance
  is; the cull discards those that share none with the view. Rays do not look at layers: what a
  view does not draw still gives shadow and reflection.
- **The own body.** `Instance_Desc.owner` (1 + the local slot whose body it is; 0: none) sets
  `INSTANCE_FLAG_OWNED` and the slot in bits 13 to 15 of the flags. A view of a slot
  (`core.View.own`) does not draw from its body the `own_hidden` layers, and fades it in `fade`:
  with 1 the cull discards it; below that, the G-buffer discards that part of its pixels with a
  4x4 Bayer pattern fixed on screen, which TAA blends into transparency without passing the body
  to the blend pass. `Gpu_Frame.own` carries the slot and the `fade`; bits 16 to 31 of
  `Gpu_Frame.layers`, `own_hidden`. The renderer does not know what a head is: it decides by
  layers. The body still gives shadow and reflection and is seen whole in nested views (which set
  `own` to 0). `engine/render` marks the instances from `View_Bodies`, and a replacement of an
  entity's mesh (`replace_source`) takes its `Layers` and its owner.
- **The part of a skinned mesh.** A pose with a part has another copy of its vertices, deformed
  with the palette that collapses the part into its bone, in the layers of its mesh. A view that
  does not draw those layers rasterizes that copy; the rays use the whole pose
  ([skinning](scene.md#gpu-skinning)).
- `engine/render` exposes the same in `Camera` and in the `Layers` component; `core.View` carries it
  up to `host.camera_from_view`.

## Carried camera

`Frame_View.carried` (and `Frame_Desc.carried`, `core.View.carried`) is the rigid transformation
that carried the camera since the previous frame together with what it sees: a teleport that
preserves the image. The view reprojects its histories by composing it with its inverse instead of
discarding them. Zero: there was none.

## Texture views

- `view_texture_add(r, width, height, name)` adds to the texture table an sRGB RGBA8 entry for what
  a camera sees; a material shows it like any color texture.
- A `Frame_View` with `texture` nonzero (size in `rect.z/w`) is a complete view of the frame that
  is drawn **before** those of the window; its LDR is copied to the entry on the GPU
  (`rhi.cmd_copy_texture`) in the same command buffer.
- The targets of each texture are created the first time a view names it and are kept while
  frames draw it: those no frame drew for `TEXTURE_VIEW_IDLE_FRAMES` are freed, and with all the
  `TEXTURE_VIEW_CAPACITY` states taken, those of the view drawn longest ago. The entry keeps its
  last image.
- What those targets hold of the GPU is counted when each frame ends (`Stats.view_target_bytes`)
  and comes out of the [texture pool](materials.md#textures).
- `host.extras_texture_view_add(extras, view)` delivers them (up to 8 per frame).
- `view_texture_remove(r, texture)` removes the entry and the targets of its view, between frames.
- With `Frame_View.readback` the image returns to the CPU without waiting for the GPU, through the
  machinery of [reads](#extension-stages): `view_texture_pixels(r, texture)` gives it, with its
  frame, when the frame that copied it finishes (a few frames later). `view_texture_capture` reads
  the last image waiting for the GPU, between frames.
- In `engine/render`: `view_texture_add(renderer, ...)`,
  `view_texture_draw(extras, texture, view, width, height, cut, pipeline, readback)` (draws a
  `core.View` into the texture in this frame with a [pipeline](#render-pipelines)),
  `view_texture_pixels(renderer, texture)`, `view_texture_capture(renderer, texture)` and
  `view_texture_remove(renderer, texture)`.
- The standard `Light` pipeline leaves out contact occlusion, traced reflections and per-block
  shadows (hard per-pixel shadows), for views that are shown small.
- What runs once per frame (probes, the extensions' `Simulate` stage, previews) goes with the first
  window view: a texture view reads the probes of the previous frame. In a textures-only frame,
  the `Simulate` stage goes with the first of them.
- Over a texture view no selection outline, grid, UI or backdrop are drawn.

## Nested views

- A `Nested_View` is another view drawn inside some pixels of a view, with the same projection and
  jitter: what its camera would see carried by a distance-preserving transformation, rigid or a
  reflection (`to_world`; `previous` for the previous frame), cut by `clip_plane` and limited to
  `layers`. Up to `NESTED_VIEW_CAPACITY` per view, without recursion; only with
  `Features.clip_distance`.
- It shares G-buffer, histories and light passes with the view that contains it.
- **Pixels.** A nested pixel stores its **negative** linear depth and `1 + index` of its view in
  the alpha of the motion target. No shader operates on the raw depth: `depth_empty`,
  `depth_distance`, `depth_nested` and `depth_same_side` (`depth.slang`) decode it, and `pixel_at`
  (`pixel.slang`) gives the world position that the pixel shows. A source that uses them includes
  that file: this way only its stages change with nested views.
- **Filters.** The spatial ones (shadows, GI, reflections, upsampling) do not mix pixels from
  different sides (`depth_same_side`). The temporal ones compare magnitudes: a
  [carried camera](#carried-camera) through keeps the history of what it saw nested.
- **Drawing.**
  1. G-buffer and depth pyramid of the view (which never sees nested depth).
  2. The `Mask` stage of an extension writes which pixels belong to each nested view and seals the
     hardware depth with that of the opening.
  3. For each nested view: cull with its camera; a second depth buffer (the farthest where the mask
     named it, the nearest elsewhere, scissor in `Nested_View.rect`); G-buffer with the `nested`
     constant, which writes negated depth and index.
- **Opening.** `Nested_View.opening` is the plane of the face through which the nested view is seen.
  What is drawn without history (lines, panels) stays in front of a nested pixel only if it is in
  front of that plane; without a plane it is compared with the distance of what the pixel shows.
- **Limits.** Glass, the `Blend` stage, overlays, grid and outline are not drawn in nested pixels;
  the translucents and what `Blend` draws in the view are clipped against the sealed depth.

## Render pipelines

A view is drawn with a pipeline (`render/pipeline.odin`): the list of passes that make its image,
in the declared order. Each renderer stage (`Render_Stage`) declares what it reads and writes in
`stage_contract`; a `Custom` pass declares its uses (`Render_Use`) and a `record`.

- **Compile.** `renderer_pipeline(r, desc)` returns the handle or an error that says what is wrong
  and how to fix it:
  - each read has a writer before it, except the optional ones of a stage;
  - each stage appears once, and `Geometry`, `Composite` and `Output` are mandatory;
  - an own pass writes only what a compute can and reads the previous frame only from a resource
    with history; it reads `Depth` (reversed) and `Exposure`, which it does not write;
  - passes whose result nothing reads are pruned, except those that write a resource with history
    or `kept` that a later frame reads;
  - a pass that writes `Taa` without the `Resolve` stage asks for `jitter = .Upscale` or `.None`;
  - a pass after `Output` writes only `Generated` and own resources, and `Generated` is written
    only after `Output` ([frame generation](#frame-generation)).
- **Image.** `Output` finishes the last image written: an own pass that writes `Taa` takes the
  place of `Resolve`, like an upscaler, and one that writes `Display` returns to the unresolved
  image.
- **Given light.** An own pass that writes `Direct` takes the place of `Direct`; one that writes
  `Gi`, of `Indirect` (both is an error): `Gi` is then the diffuse indirect light itself, which the
  composite takes instead of the probe volume's (`FRAME_FLAG_GI_GIVEN`), and it keeps what the pass
  left the frame before. The references of the tests are such passes
  ([indirect reference](gi.md#indirect-reference)).
- **Request.** A pipeline is requested in every frame that uses it; the renderer compiles it the
  first time, identifies it by a hash of the description (including `record` and `user`: a project
  reload gives another) and keeps up to `RENDER_PIPELINE_CAPACITY` (16); one that no recent frame
  requested leaves its place.
- **Standard** (`Standard_Pipeline`, `standard_pipeline_passes`), always present:
  - `Full`: all the stages ([frame graph](frame-graph.md#passes)).
  - `Light`: `Full` without `Reflections` or `Indirect`, with `Direct` in `Traced` mode.
- **Use.** `Frame_View.pipeline` chooses a view's. 0 is the frame's main one
  (`renderer_main_pipeline`, which lasts that frame) in a window view, and `Full` in a texture one.
  Changing pipeline cuts the view's histories.
- **Own resources.** `Custom0` to `Custom47` (`Render_Resource_Desc`): textures of a format that a
  compute writes, or buffers of `bytes` or of `pixel_bytes` per pixel of their size.
  - Size: the internal one (`Full`) or the output one (`Output`), divided by two `shift` times and
    rounded to a multiple of `align`, or fixed. `mips` gives a texture levels (`RENDER_MIPS_ALL`:
    down to one texel).
  - They are created per view on first use and rebuilt if the view's size changes.
  - Those without history or `kept` that are used in disjoint ranges share memory.
  - Those with history have two copies that alternate; the `kept` ones, one that the passes read and
    write in place and which passes from one frame to the next. They start at zero, return to zero
    after a view cut and are read without a writer before them in the frame.
- **Jitter** (`Render_Pipeline_Desc.jitter`): `Resolve` follows the stage (16 phases while TAA is
  on); `Upscale` is that of a temporal upscaler of the pipeline: 8 phases at output size times the
  square of how much smaller the view is drawn (`upscale_jitter_phases`). A view cut restarts its
  phases and the frame index the shaders seed their noise with (`View_State.turn`): the frames
  after a cut do not depend on how many the view drew before it.
- **Record.** The `record` of a `Custom` pass binds its resources with
  `pass_resource(pass, slot, resource, previous, mip)` and dispatches with
  `stage_pipeline({stage = .Custom, shader})`, which takes `<shader>.comp` from the shaders in use.
  The RHI derives the barriers; afterwards the renderer binds the scene tables again.
  - Slots (`CUSTOM_PASS_SLOTS`, 24): the first ten are `SLOT_PASS0` to `SLOT_PASS9`; the others are
    the bindings of the scene tables, which a pass that uses them does not read. A shader names
    them with `CUSTOM_SLOT_n` of `custom_slots.slang`, which also works in HLSL registers.
  - `pass_constants` binds a constants block (a cbuffer) in a slot; `pass_clear` zeroes a resource
    that the pass writes; `pass_resource_write` copies once what a buffer stores, like the weights
    of a network.
  - `Stage_Pass` brings what a pass in place of `Resolve` resolves: output size, jitter of the frame
    and the previous one in pixels and its phases, the camera, the frame time, and whether the
    resources with history have the previous frame (`history`, false after a cut, a size change or
    a pipeline change) with how many frames (`history_frames`).
  - `Reactive` is zero in a frame without particles.
- `engine/render` exposes it as `pipeline(renderer, desc)`, `pipeline_standard(renderer, kind)`,
  `pipeline_main(renderer, pipeline)` and the `pass_*`.

### Antialiasing techniques

`Graphics_Settings.antialiasing` names the technique that resolves the image and the scale: `off`,
`taa` or one that a plugin offers. The plugin offers it in each frame (`antialiasing_offer`) and,
while the setting names it, draws the window views with a pipeline whose passes take the place of
`Resolve` (`pipeline_main`). Without the plugin, or until its shaders are there, TAA resolves,
which every name except `off` turns on. Texture views use their own pipeline.
`antialiasing_offered` lists those of the last frame: the Graphics popup offers
them. The `fsr` plugin is one
([render plugins](../../mirai-plugins/references/render-plugins.md#fsr)).

### Frame generation

The `Custom` passes after `Output` generate the image that the window shows between the previous
frame and the current one:

- They read `Ldr` before `Output` draws over it the scene panels, the debug lines and the screen
  layers, and write `Generated`, of output size. They run only in the window views of a frame that
  presents, never in a texture view or in a capture.
- Afterwards, `overlays_pass` draws the same over `Ldr` and over `Generated`; the UI vertices are
  uploaded once. In split screen `compose_views` also composes the generated images (a view that
  did not generate puts its own).
- The generated one is shown only with history (not after a cut, a size change or a pipeline
  change): `Stats.generated`.
- While the main pipeline generates, the renderer asks the RHI for
  [paced presentation](rhi.md#paced-presentation) and draws the two images in the pair it gives
  (`swapchain_generated_texture` and `swapchain_texture`).
- `Graphics_Settings.frame_generation` asks for it from the antialiasing technique that offers it
  (FSR 3.1, [plugin](../../mirai-plugins/references/render-plugins.md#fsr)). The High and Ultra
  presets turn it on; Low and Medium do not, because of the memory of its passes. The frame limit
  and VSync count the images shown: with a generated one, `platform.frame_end` gives the loop twice
  the time. So it does not generate when VSync (on a 60 Hz display) or the limit would leave the
  game fewer than `FRAME_GENERATION_BASE_MIN` own frames (`graphics_generates`): at half it
  trembles when moving the camera and arrives late to input.

## Extension stages

- A plugin's runtime uses the renderer only through `engine/render` (`extend.odin`): the `pass_*`
  and types of `render/extend.odin` under another package name.
- A function that reaches the renderer receives it, `renderer: ^erender.Renderer` (nil without a
  GPU: each procedure answers its zero), and one that adds to the frame, `extras:
  ^host.Frame_Extras`; a step gets both
  [bound](../../mirai-core/references/generator.md#parameters).
- A `@(step="render")` function requests passes for the next frame with `frame_pass(renderer, stage,
  record, user)`: up to `FRAME_PASS_CAPACITY` (32), in the requested order; the list lasts that
  frame and requesting the same pass again (stage, `record` and `user`) is requesting it once.
- `record(pass: ^Pass, user)` records with `pass_*`. The `Pass` gives the stage, the size of the
  view's targets, the eye (`eye`: position with `w` 1, or direction of an orthographic one with `w`
  0), the matrix without jitter (`view_projection`), the world the frame draws (`world`, the key of
  `scene_world`: an extension records only what belongs to that world), the frame number
  (`frame`), the world seconds (`time`) and, in `Blend`, the glass side (`glass`).

## Stages in frame order

- **`Geometry`**: once per frame, after uploading the scene and before the views; its `Pass` has no
  view (size and matrix at zero). It writes vertices of [deformable meshes](#deformable-meshes):
  `pass_vertices_begin` and, per mesh, `pass_deformable`, `pass_pipeline`, `pass_params` and
  `pass_dispatch`.
- **`Simulate`**: once per frame, with the first window view (or the first texture one of a
  textures-only frame), after its G-buffer and its occlusion; a `ui_only` frame does not run it. It
  dispatches with the scene tables bound: it traces (`hw`), reads the light tree and the probe
  volume, and reads the depth and normal of that view with `pass_surface_read`. The
  [particles](../../mirai-world/references/vfx.md#passes) use it.
- **`Gbuffer`**: each view, after `Simulate` and before `Mask`: surfaces that the extension draws
  in the G-buffer and that are lit like the scene. `pass_gbuffer_begin` opens the view's G-buffer
  targets with its depth; `pass_gbuffer_pipeline(pass, shader)` gives the pipeline of
  `<shader>.vert` with the engine fragment of that view's variant (with or without reflectance or
  layers, with the instance ids if the shaders ask for them). The extension says each frame which
  mesh and material it draws (`frame_gbuffer_mesh`), and the views take the targets they ask for,
  wherever their surfaces are. The vertex shader fills a `Gbuffer_Vertex`
  (`include/gbuffer_vertex.slang`) and places it with `gbuffer_vertex_place`; the pixel carries
  instance 0. It also fills its mesh's color (`out_vertex_color`, white without one) and its tint
  with `material_vertex_tint`: a program reads the color as data and does not multiply it. With
  `fragment`, `<fragment>.frag` writes the targets instead of the engine, with the `plain` and
  `layers` variants and the packing of `gbuffer.slang`, like the
  [foliage](../../mirai-world/references/foliage.md#far-impostor-and-crown) impostor. Materials
  with a Surface program are drawn with their program's fragment: `program` in
  `pass_gbuffer_pipeline` gives that pipeline, `pass_material_program` says the program of a
  material and `pass_mesh_programs` those of what a mesh shows, for a draw per program in which the
  vertex shader collapses the clusters of the others. Until the program's pipeline is made, that of
  the stage without it ([program pipelines](materials.md#program-pipelines)).
- **`Mask`**: each view, after its G-buffer, occlusion and the `Gbuffer` stage. It adds
  [nested views](#nested-views) with `pass_nested_add` and draws their mask between
  `pass_mask_begin` and `pass_end`. The faces through which one is seen (mirrors, portals) are
  chosen by `pass_nested_faces`: those the view sees head-on, the nearest first, until full.
- **`Surface`**: each view, after the nested G-buffers and before lighting.
  `pass_surface_begin(pass, {.Albedo, .Emission})` opens a pass over the requested targets until
  `pass_end`; linear depth, motion and those not requested stay as reads
  (`pass_surface_read(pass, slot, .Linear_Depth)`). Before that pass it can dispatch a compute
  (`stage_pipeline` with `compute`) that reads the G-buffer with `pass_surface_read` and writes a
  texture of the view, which the pass reads afterwards with `pass_texture_sample`.
- **`Lit`**: each view, after composite and before the `Blend` stage and TAA, except in a view with
  an inspection mode. It dispatches over the lit opaque image, which `pass_image_bind(pass, slot)`
  binds to read and write (`rgba16f`, render units before exposure), and reads the G-buffer with
  `pass_surface_read`, also the direct light already in the image (`Direct`). With glass in view
  it runs twice, like `Blend`: behind the nearest layer (`glass` `Behind`), with the layers
  already rasterized and before the glass reads what is behind it, and in front (`Front`), over
  the lit glass; without glass, once (`All`). `.Glass_Depth` gives the layer: a medium applies its
  share of the path on each side, and what only changes opaque surfaces does nothing in front.
  The [fog](../../mirai-plugins/references/render-plugins.md#fog) and the
  [water](../../mirai-world/references/water.md) caustics use it.
- **`Blend`**: each view, over the lit image before TAA, except in a view with an inspection mode.
  With glass in view it runs twice: behind the nearest layer, after its raster and before the glass
  reads what is behind it (`glass` `Behind`), and in front, over the lit glass (`Front`); without
  glass, once (`All`). `pass_blend_begin` opens the image (render units, before exposure) and the
  coverage that TAA reads, with the view's depth for the test; the renderer clears the coverage in
  the view's first pass and tells TAA to read it, which keeps less history where it was drawn.
  `pass_surface_read` adds `.Glass_Depth`, the depth of the nearest layer, with which each pass
  draws only its side. Its pipeline blends the image with `blend` and adds the coverage.
- **`Post`**: each view, at the start of `Output`, after the exposure and before the PostProcess
  programs, except in a view with an inspection mode. It dispatches over the resolved image (that
  of TAA or of an upscaler; without TAA, that of composite), at output size (`output_width`), in
  render units before exposure. `pass_image_write(pass, read, write)` binds that image to read and
  the next one to write (`rgba16f`), which becomes the image: the later one, the PostProcess and
  the tonemap read it. A pass never writes the one it reads (that of TAA is its history) and writes
  all the pixels of the next one; the two alternate with the stack's targets, without copies.
  `pass_image_bind` binds it for reading only. It reads from the view what `Output` declares:
  `pass_surface_read` of `Linear_Depth`, `Motion`, `Albedo`, `Normal` and `Emission`, at the size of
  their targets; `delta_time` is the world seconds that the motion vectors cover.
  [`lens`](../../mirai-plugins/references/render-plugins.md#lens) uses it.
- **`Effect`**: each effects view of the frame (`Frame_Desc.effect_views`), after the simulation and
  before the UI that shows it ([offscreen UI](ui.md#offscreen-ui)). `Stage_Pass.texture` names the
  texture; `pass_blend_begin` opens its clean targets (light, coverage and depth) with the
  constants of its camera, over an empty scene depth and without glass. A `stage_pipeline` pipeline
  with `.Effect` is like a `Blend` one.
- **`Custom`**: where a [pipeline](#render-pipelines) places it; it dispatches over the declared
  resources (`pass_resource`). `frame_pass` does not accept it.
- **`Inspect`**: an extension's inspection mode, only in the view whose `View_Inspection` names its
  `record`, after composite and the core inspection modes. It dispatches over the view's image,
  which `pass_image_bind(pass, slot)` binds to read and write (linear `rgba16f`, shown in [0, 1]
  without exposure or display transform), and reads the G-buffer with `pass_surface_read`.
  `frame_pass` does not accept it: the pass goes in the view that shows it (in the editor,
  [a plugin's modes](../../mirai-editor/references/extensions.md#an-inspection-mode)).
- `Simulate` and `Gbuffer` run inside the pipeline's `Geometry` stage; `Mask`, `Surface` and `Lit`,
  inside `Nested`, `Surface` and `Lit`; `Blend`, inside `Transparency`; `Post`, inside `Output`: one
  without them draws no nested views, decals, fog or particles.

## Restrictions of the `pass_*`

- `pass_params` and `pass_upload` return `false` if the frame memory is not enough: that draw is
  not made.
- `pass_surface_read(pass, slot, .Instance)` binds the instance that drew each pixel + 1 (R32 uint;
  0: nothing, or a surface of the `Gbuffer` stage) while the shaders ask for it
  (`//! mirai needs instance_ids`); without asking it reads 0. It is the index of the instance in
  the renderer's scene: it lasts the frame, it is not the instance's identity. From
  `frame.instance_count` it is an instance of a [batch](scene.md#instance-batches); `scene_instance`
  reads any.
- `instance_values_set(renderer, index, values)` gives four numbers to an instance of the
  renderer (by its index, that of `instance_object`), which the shaders read with
  `instance_values(instance)` of `scene.slang`: the instance's row carries them, they continue
  while the instance keeps its identity and they change neither its light nor its rays.
- `instance_wet_set(renderer, index, wet)` says how wet an instance of the renderer is, from 0
  to 1, with the same rules of identity, light and rays; every material applies it
  ([wet](materials.md#evaluation)). It has a single writer, the
  [water](../../mirai-world/references/water.md#what-physics-shows) plugin.
- `pass_scissor` limits the pixels (without size: the whole view); `pass_draw` and `pass_dispatch`
  execute. After a stage the renderer binds the scene tables again.
- `pass_timestamp(pass, name)`: the GPU time of what the pass records from there counts under that
  name in the frame times (`profile.capture`, `engine.status`), until the next pass that names its
  own.
- **View textures.** `pass_texture(pass, slot, Pass_Texture_Desc{name, format, width, height, depth,
  history}, previous)` binds in `SLOT_PASS0 + slot` a texture that the view keeps between frames
  for the extension, in any stage with a view:
  - 2D, or 3D with `depth` greater than 1, in a format that a compute writes; a 2D with `mips` has
    levels (`RENDER_MIPS_ALL`: down to one texel), and `mip` binds one to write it or, with -1, all
    to read them, like `pass_resource`;
  - `name` distinguishes it from the others of the view; requesting it with another format, size
    or levels rebuilds it;
  - with `history` it has two copies that alternate: that of the frame and, with `previous`, that of
    the previous one;
  - it returns `kept`: the previous copy has what that view's passes wrote in their previous frame.
    It is false the first time, after a camera cut and after a frame without requesting it. What it
    holds before something writes it is not known;
  - the renderer creates it at the first request (up to `EXTENSION_TEXTURE_CAPACITY` = 8 per view),
    keeps it while the view's passes request it every frame and frees it after a frame of the view
    without requesting it, or with the view;
  - `pass_texture_sample(pass, slot, desc, previous)` binds it so that the draws of the next pass
    read what the earlier dispatches wrote: it goes before `pass_surface_begin` or
    `pass_mask_begin`, which no longer admit barriers.
- **Buffers of a world.** `pass_buffer(pass, slot, Buffer_Desc{name, size})` binds in `SLOT_PASS0 +
  slot` a buffer that the renderer keeps for the extension under that name and the pass's world,
  until it releases it (`buffer_release(renderer, world, name)`, in the world's `release`) or the
  renderer closes (up to `EXTENSION_BUFFER_CAPACITY` = 64):
  - it creates it the first time and again if it is requested with another size, and returns
    `made`: what it holds is not known. One larger than what the device binds is not created;
  - a world that is not drawn keeps its own: its state waits, still, for its next frame;
  - `pass_buffer_write` copies rows to a part, through frame memory, and `pass_buffer_fill` fills it
    with a value; both outside a draw pass;
  - `pass_buffer_ready(pass, desc, indirect)` makes readable what the dispatches wrote for the draws
    of the next pass, or as their indirect arguments: it goes before `pass_gbuffer_begin` or
    `pass_blend_begin`, which do not admit barriers;
  - `pass_dispatch_indirect` and `pass_draw_indexed_indirect` take their arguments from a buffer;
    `pass_indices(pass, .Scene)` binds the scene indices (`mesh_draw_range` gives those of a mesh)
    and `.Quad`, the six of a quad.
- **Lights.** `lights_ask(renderer, with_shadow, without_shadow)` asks for room for lights that
  a `Simulate` pass writes with `pass_lights(pass, lights, nodes)`: they shine like those of the
  scene; those of the first part cast shadows and those of the second trace no rays
  ([GPU lights](lights.md#gpu-lights)).
- **Table textures.** `table_texture(renderer, world, Table_Texture_Desc{name, width, height})`,
  between frames, gives the table place of an RGBA16F texture of the world under that name, which
  the extension fills each frame with `pass_table_texture_copy(pass, buffer, offset, desc)` from a
  buffer of the world and which the materials read like any other. Making it, or with another size,
  is a transaction; `table_texture_release` frees it (up to `EXTENSION_TABLE_TEXTURE_CAPACITY`). A
  transaction that frees what it brought can take its place: then it is made again.
- **Rows of a frame.** `pass_rows_upload` copies rows once to the frame memory and `pass_rows` binds
  them in that frame's passes (`Pass.frame` says when to upload them again).
- **Counters.** `pass_counters(pass, slot, name)` binds four `u32` of a name that the renderer sets
  to zero every frame and reads with its statistics: `erender.counters(renderer, name)` and
  `Stats.counters` give those of two frames back (up to `EXTENSION_COUNTER_CAPACITY` = 16 names).
- **Reads.** `pass_readback(pass, buffer, offset, Buffer_Desc{name, size})`, outside a draw pass,
  copies a part of a world buffer at the end of the frame; when that frame finished, the CPU has it
  without waiting for the GPU: `erender.readback(renderer, world, name)` gives the bytes of the last
  copied frame and its number, valid until the next frame. Making it, or with another size, is a
  transaction; the extension frees it with `readback_release` in the world's `release` (up to
  `EXTENSION_READBACK_CAPACITY`). What returns arrives frames later and is not deterministic: it is
  presentation, never input of `fixed`
  ([generator](../../mirai-core/references/generator.md#attributes)).
- **Pipelines.** A plugin's stages are sources `name.vert.slang`, `name.frag.slang` or
  `name.comp.slang` in its `shaders/`; the project generation compiles them (`extensions` key of
  the manifest).
- `stage_pipeline(renderer, {stage, shader, targets, blend, compute, name, fragment, program})`
  gives (and `pass_stage_pipeline`, inside a pass):
  - for `Mask`, `Surface` and `Blend`, the pipeline of `<shader>.vert` and `<shader>.frag` (without
    `.vert`, a three-vertex triangle over the whole view) with the formats and state of the stage
    (`Mask`: those of the mask, with depth test and write; `Surface`: the named targets, with that
    blend; `Blend`: the image with that blend and the coverage added, with depth test without
    writing it);
  - for `Geometry`, `Simulate`, `Lit`, `Post`, `Custom` and `Inspect`, and for `Surface` with
    `compute`, that of `<shader>.comp`. `Gbuffer` takes `pass_gbuffer_pipeline`. A stage that traces
    declares the `hw` variant and the `color` constant (`//! variant`, `//! constant`, like
    `shadow_trace.comp`) and receives the pipeline of the rays the renderer traces: by hardware,
    and through the colored-shadow glass filters (`colored_shadows` and some blend instance).
    Without the variant, the stage itself: one that traces without `hw` does not see the scene
    with ray queries.
  - with `program`, that of a graphics stage with the fragment of that Surface program, if the stage
    marks it `//! per surface program`; that of the stage without it while it is not made.
- The renderer creates the pipeline at the first request, keeps it (up to `STAGE_PIPELINE_CAPACITY`
  = 64) and destroys it when loading other shaders and on closing.
- The extension requests the pipeline every frame; without the stage (embedded shaders, project
  without the plugin) it receives 0 and does not draw.
- A plugin neither creates nor frees GPU resources: its pipelines, the textures of each view and
  the buffers of each world belong to the renderer, and its rows go in the frame memory. Its
  `@(storage,host)` storage keeps flat data.

## Extension hooks and constants

What an extension needs **inside** the engine stages is composed when generating the project
shaders, with lines `//! mirai frame`, `needs nested_views`, `needs instance_ids` and
`hook ray|lights|probes|vertex` in its Slang sources; the comment in
`cook/shaders/extensions.odin` lists them, with `constant`, the line that shares a
[constant of its Odin code](shaders.md#compilation) with its shaders. Rules:

- A `frame` source is included before `Frame_Data` and uses no engine declarations;
  `pass_extension_data(pass, "<name>")` returns its bytes, zero until the extension writes them. A
  frame source and a hooks source are different files. The fields are declared only by the stages
  with some project or plugin source (its stages, its hooks, its programs): an engine stage reads
  them through a hook.
- The ray, probe and vertex hooks admit a single source per generation, and probes and vertices
  without other hooks; the lights of all the sources are added.
- `needs instance_ids` adds to the G-buffer an R32 uint target after the last of each variant; a
  project without a plugin that asks for it neither creates nor writes it.
- The generation writes `include/extensions.slang`, `extension_hooks.slang` and
  `extension_probes.slang`, and publishes in `catalog.json` where each frame struct landed
  (`Renderer.frame_layout`). Without extensions the includes stay empty and the stages are the
  engine's, byte for byte.
- **Common error:** every stage that includes `trace.slang` or `lighting.slang` includes
  `<extension_hooks.slang>` afterwards; without that include it does not link when a project
  brings hooks.

Hooks:

- **Rays** (`mirai_ray_gate`, declared in `trace.slang`): whether the ray exits through a gate
  before `t_max`, at what distance and how it continues; it does not trace. `trace_ray` traverses
  up to two segments around a single traversal site; a ray without a hit sees the sky in the
  direction it leaves with, and a probe stores the distance to the gate. The shadow rays of the
  engine lights that would cross a gate count as blocked.
- **Probes** (`mirai_probe_gate`): the part of the light around a direction that arrives through a
  gate, where to read it on the other side, which side it gives to and how the directions rotate.
  `sample_probes_around` blends the two reads in that proportion: the probe field is not cut at the
  opening.
- **Vertices** (signature in `extensions.odin`): where a vertex of a batch instance is at
  `frame.time`; the G-buffer also calls it with the previous time for the motion vectors. It moves
  only what is rasterized: shadows and reflections see the mesh at rest.
- **Lights** (`mirai_extension_light_count` and an `Extension_Light` per index, in
  `lighting.slang`): they are lights like the others. The [shadow](lights.md#shadows) blocks trace
  their ray (and the optional second) to a point of their disc and `direct` adds their unshadowed
  light; `direct_lighting` adds them in a single loop on thin geometry and on reflection, GI and
  probe hits.

## Batches

`engine/render` exposes the [instance batches](scene.md#instance-batches) (`batch_set`,
`batch_remove`, `batches_epoch`, `batch_desc`, `batch_instance`). The world is the `core.World_Id`
of the calling function: each world publishes its own and those of the displayed world are drawn. A
batch lasts until `batch_remove` or until `batches_epoch` changes: whoever publishes them keeps
their handles in a `by_world` storage and removes them in the `release` of its world. The
[foliage](../../mirai-world/references/foliage.md) plugin uses it.

## Deformable meshes

- `deformable_create(renderer, source)` registers a copy of a mesh whose vertices an extension
  writes on the GPU, like a [skinning](scene.md#gpu-skinning) pose: the renderer copies current to
  previous before the `Geometry` stage and afterwards refits the ray structure; `mesh_remove` frees
  it.
- Each frame in which the shape changes, the extension calls `deformable_update` with its box and
  writes the current vertices in `Geometry`; a shape that stops changing makes one last pass to
  equalize current and previous. A box that does not change marks no light.
- `pass_deformable` gives where, in vertex pool words, the vertices that the extension writes and
  the rest ones it reads are (one `Posed_Vertex` each, which its shader reads and writes with
  `posed.slang`: `posed_load`, `posed_store`), and its row of the mesh table. Vertex `i` is the `i`
  of the mesh's clusters. The rest of a vertex (its color) is in the mesh's pages: the shader
  includes `geometry.slang`, with the pools and the mesh table that `pass_pipeline` binds in
  `Geometry`, and reads it by index (`mesh_vertex_color`).
- With `levels`, the copy keeps the source's levels of detail: `pass_deformable` counts the vertices
  of all of them and the extension writes them; the GPU keeps taking its cut and the rays see the
  first. `vertices_made` counts the times the vertex buffer was created again: what was written was
  lost and has to be written again.

## Geometry for extensions

- `mesh_triangles` gives the triangles of the first level of a mesh from the renderer's CPU copy;
  `texture_add` and `texture_remove`, a table image with its levels, which a shader reads at
  `texture_index`; `impostor_capture`, the frames of an impostor
  ([materials](materials.md#material-previews-and-thumbnails)). Load transactions.

## Skinned meshes

- `skin_create(renderer, source, influences, joint_count, morph={})` registers a copy of a skinned
  mesh that the renderer deforms by joints on the GPU ([skinning](scene.md#gpu-skinning));
  `influences` (`Skin_Influence`, one per vertex of level 0 or of all levels) name joints of the
  palettes and `morph` (`Morph_Data`) its targets. Load transaction. One larger than what a frame
  uploads is not drawn until it has been uploaded ([several
  frames](scene.md#geometry-over-several-frames), `mesh_uploading`): an instance that replaces the
  world mesh with it leaves the entity undrawn until then.
- `skin_update(renderer, handle, palette, reset_motion=false, morph_weights=nil)` gives the palette
  of the next frame, one matrix per joint, from the bind pose to the mesh space, and the weights of
  its targets; `reset_motion` draws no motion since the previous frame.
- `skin_palette(renderer, handle, current, previous)` reads the palette that will deform the next
  frame and that of the previous one, per joint and as rows of a 3x4: what an extension needs to
  follow the pose (the bones of the particles).
- `mesh_remove` frees it; those that remain go with the renderer. This way the `animation` plugin's
  skin deforms without importing `render` or `rhi`.
