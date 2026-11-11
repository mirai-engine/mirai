# Frame graph

The passes run on the GPU; the CPU uploads the dirty data through the ring. Texture views are
recorded first and then the window ones. Each view goes through passes 2 to 16, which are the
stages of the standard `Full` pipeline; a [pipeline](views.md#render-pipelines) can omit stages
or interleave its own passes.

## Passes

1. **upload**: skinning of the poses that changed; instances, materials, lights and their
   [tree](lights.md#local-lights) if they changed; the `Geometry` stage of the extensions; the
   refit of the ray structure in use and, with hardware RT, the native TLAS. What does not fit in
   the frame's transient memory is uploaded with the next one. Then, **glass mean**: the
   [medium filter](materials.md#medium-filter), when needed, and **air**: the tables of the
   [atmosphere](gi.md#atmosphere) that change with the air. Each view, at its start, redoes the
   row of its sky and its aerial perspective if its eye or the sun moved.
2. **cull (phase 0)**, per instance and then per cluster (`cull.comp`, `cull_clusters.comp`).
   - One thread per instance, and then one per slot of the drawn
     [batches](scene.md#instance-batches): frustum and occlusion of its box against the depth
     pyramid of the previous frame (with the previous camera). One that passes delivers, in
     chunks of up to 64, the clusters of the levels the cut can take at some point of its box: a
     distant object whose root already suffices delivers only the root. One that is hidden stays
     a candidate for phase 1.
   - One thread per cluster of the chunks: the level cut (`cut.slang`, projected error against
     `lod_error_pixels`), frustum, normal cone (closed meshes only) and the pyramid. A visible one
     enters the visible list (instance, cluster) and counts in the instance count of the phase's
     draw; one that the pyramid hides stays a candidate for phase 1. One of a material with a
     Surface program goes to the program list, which `cull_programs.comp` distributes per program
     with one indirect draw per program and phase.
   - An instance with all its blend materials is not drawn here; one with blend triangles that
     passes the tests (in any phase) turns on the glass passes with their dispatch sizes.
3. **gbuffer**
   - One non-indexed indirect draw per phase, 384 vertices per instance and one instance per
     visible cluster: the vertex shader reads the cluster from the list and its triangle per
     vertex (the triangles that do not pass collapse). Then, one per Surface program in use, with
     its pipeline ([programs](materials.md#surface-programs-in-rays-and-raster)). The fragment
     shader reads the material row of the cluster's slot and its textures from the table, without
     binds per material or per object. Mask: discards below the threshold; blend: not drawn here.
     The same on Vulkan and Metal, without mesh shaders or 64-bit atomics.
   - The targets are encoded by `gbuffer.frag` and the passes read them only with
     `include/gbuffer.slang` (`gbuffer_read`, `gbuffer_normal`, `gbuffer_shading`).
   - A reflectance target exists only while a visible instance has an opaque material that does
     not reflect like the default one ([materials](materials.md#evaluation)), and a
     [layers](materials.md#layers-openpbr) one only while a visible one has them; without them,
     the passes derive the reflectance or bind an empty target, and the scene does not change
     light mode. Visible means in the view's frustum, in that of a nested view or in the `Gbuffer`
     stage of an extension that says which mesh and material it draws (`frame_gbuffer_mesh`); the
     one that draws all the level 0 clusters of a mesh that the cull does not see says so too
     (`frame_mesh_whole`), and the pages of that mesh are all loaded and not evicted while it
     asks. Nested views are known after `Mask`: if they ask for the reflectance and the view's
     G-buffer was drawn without it, a pass fills it with the one given by the albedo and the
     metallic of their pixels, and the constants flag (`FRAME_FLAG_REFLECTANCE`) changes before
     the passes that read it.
4. **occlusion**
   - Maximum depth pyramid of the frame; phase 1 retests the instances and clusters rejected by
     occlusion and draws the visible ones. An object does not appear late even if the occluder
     moves or the camera jumps.
   - Phase 1 tests against the pyramid made with the depth of phase 0; after its G-buffer the
     pyramid is redone with that of both phases, which is the one that phase 0 of the next frame
     tests: what was rescued occludes from there.
   - The cull lists (chunks, visible clusters and candidates) count what does not fit
     (`Stats.cull_dropped`) and grow to that for the following frames: a frame can show holes
     where a list fills for the first time, not again at that size.
   - Then, the `Simulate` extension stages (first window view, or texture view in a
     textures-only frame: what moves on the GPU against this depth, like the
     [particles](../../mirai-world/references/vfx.md)) and `Gbuffer` (each view: surfaces of an
     extension in the G-buffer).
   - With extension passes: `Mask` stage, G-buffers of [nested views](views.md#nested-views) and
     `Surface` stage.
5. **direct**
   - Sun, local lights (all with size) and lights from
     [extensions](views.md#extension-hooks-and-constants), with the diffuse lobe and the GGX
     specular: the output is reflected radiance.
   - `shadow trace` and `shadow filter` compute beforehand, at half resolution, the fraction of
     light that reaches each 2×2 block; `direct` multiplies by it the unshadowed light of the
     pixel ([shadows](lights.md#shadows)) and adds that of the GPU lights that do not cast
     shadows ([GPU lights](lights.md#gpu-lights)).
   - `direct` does not trace: a pixel with no block on its surface enters a list that
     `direct rays` (`lighting_traced.comp`, indirect dispatch) traces. Without blocks (pipeline
     `Light`), `direct rays` lights each pixel and `direct` does not run.
6. **reflect**: the pixels smoother than `reflection_roughness` trace a ray from their lobe and a
   second pass filters in space and time; it is omitted while no material of the table can go
   below that limit ([traced reflections](materials.md#traced-reflections)).
7. **ddgi**: with indirect light, in the first window view, the
   [probe volume](gi.md#probe-volume) marks the probes that scene changes reach and those that
   pixels use, chooses by priority those it traces and updates their atlases and positions. With
   a still scene it keeps tracing in turns, with the same rays. The animated emission of a
   Surface program does not count as a change.
8. **contact**: the [contact occlusion](gi.md#contact-occlusion) traces its short rays and blurs
   them over the surface.
9. **composite**: `direct + indirect_compose + emission`
   ([indirect composition](materials.md#indirect-composition)), or the view's
   [inspection mode](settings.md#inspection-modes). Under an atmosphere, the image that is shown
   takes the aerial perspective.
   - The specular lobe takes the traced reflection in the proportion that it traced and the
     volume around its dominant direction in the rest.
   - The [grid](#reference-grid) is composed only in the background.
   - With extension passes and without an inspection mode, the [`Lit`](views.md#extension-stages)
     stage over the lit opaque image. With glass in view and `Lit`
     passes, the raster of the layers (step 11) goes before: the stage runs behind the nearest
     layer and again in front, over the lit glass.
10. **overlay**: up to four additional Surface materials per instance, in order, over opaque or
    masked geometry. A draw per instance whose vertex shader takes the clusters of the view's cut
    and collapses the others, so they cover what the G-buffer drew; they test depth equal without
    writing it and do not enter the BVH/TLAS
    ([overlays](../../mirai-core/references/host.md#loaded-assets)).
11. **translucent**: the nearest blend surfaces of each pixel form the `glass_layers` layers in a
    small G-buffer; those behind are drawn forward, back to front, and filter what they have
    behind. It is omitted if none is in view.
12. **glass**: lights each layer once per pixel, from the farthest to the nearest
    ([glass](materials.md#glass)). It runs with the dispatch sizes of the cull: none while all the
    glass is hidden.
    - The `Blend` stage of the extensions (the particle sprites): what is left behind the nearest
      layer after the layer raster, the rest after the glass; without glass in view, a batch after
      composite.
    - Over the lit glass and before `Blend` on the front side: the `Lit` stage in front of the
      nearest layer and then what the solid the camera is in absorbs and scatters
      (`glass_inside`).
13. **taa**: temporal anti-aliasing and rescaling to window resolution.
    - A moving pixel takes a tenth of the new frame. One still on screen (less than a quarter of a
      pixel per frame) averages its frames up to 64, four turns of the sixteen jitter points: an
      edge or a highlight finer than a pixel does not flicker. Each pixel counts its frames since
      its history starts (`Targets.taa_frames`), so a newly uncovered pixel or a newly cut view
      settles as fast as before; what changes beyond the surrounding colors is seen at once, by
      the clipping to the box.
    - The box is the variance in YCoCg of the 3×3 pixels of this frame. On a still pixel it widens
      as its history fills (`TAA_STILL_GAMMA`): the box of the jittered samples of a single frame
      moves with the jitter next to a high-contrast edge (a checkerboard, or its reflection), and
      clipped to it the average of the previous frames jumped on every frame. A light change on a
      smooth surface remains outside the box.
    - Where the `Blend` stage covered the pixel (`Targets.reactive`) the history weighs less.
      Where the pixel's shadow block was marked because what casts its shadow changed
      ([shadows](lights.md#shadows)), the pixel keeps what a moving one keeps: a shadow that moves
      over a still floor leaves no trail. An upscaler that replaces TAA does not receive that
      mark.
    - The history stores in its alpha the depth of the pixel (that of its sample, or that of the
      nearest neighbor when it followed its motion).
    - Disocclusion rejection: if the history shows something nearer than everything the pixel has
      around it, and wider than a pixel, the pixel starts over. A still edge and a thin wire
      reject nothing: the image is, byte for byte, the same as without the rejection.
14. **exposure + postprocess HDR**
    - `exposure` measures the image before TAA and adapts the view's exposure on the GPU
      ([exposure](display.md#exposure)).
    - The [`Post`](views.md#extension-stages) extension stage: plugin passes over the resolved
      image, each writing the next, which the PostProcess programs read.
    - Each view runs the list of its `Camera.slot`: that of its local player
      (`renderer_set_view_postprocesses`) or, with 0, that of the frame
      (`renderer_set_postprocesses`).
    - Ordered PostProcess programs read the last image a pass wrote (`Display`, or `Taa` of
      `Resolve` or of an [own pass](views.md#render-pipelines) in its place), exposed (mid gray is
      0.18), and write alternating targets, before the tonemap. The stack's targets are created
      when an active entry uses them. An effect's result goes back toward what it read by its
      `fade`; one faded out does not run, though a limited inspection counts it.
    - Besides that image, the effects read only what the `Output` stage declares in
      `stage_contract`: the linear depth, the normal and the mask of the [outlines](#outlines).
      Each effect measures its time with its side and its place in the list
      (`postprocess hdr 1`).
    - `View_Inspection.postprocess` of a view runs only the first effects of each side (the eye of
      the stack inspector); without a limit they all run.
15. **tonemap + postprocess LDR + ui**
    - Exposure and a read of the display LUT (the project's transform and sRGB:
      [transform](display.md#display-transform)), with triangular dithering of up to one 8-bit
      level on each side, fixed between frames and null at pure black and white.
    - Composes the [outlines](#outlines) layer.
    - The LDR PostProcess programs process the tonemapped image before the UI.
    - On top, in this order: world panels, debug lines and UI layers
      ([UI](ui.md#ui-world-panels-and-debug-lines)).
16. **present**: copy to the swapchain. The LDR image is kept for `renderer_capture`.

## Outlines

- One mechanism for the editor and the game. The level of an instance (`Instance_Desc.highlight`)
  is an editor one (`Renderer.highlight`) or a game style (`Renderer.outlines`, `outline_level`),
  which the entity's [`Outline`](../../mirai-gameplay/references/libraries.md#render) writes; the
  styles are described in `Highlight_Style`.
- On an instance the editor level replaces the game one (`instance_outline` of `engine/render`).
  On screen every editor level covers the game ones. The levels the editor reserves:
  [shapes](../../mirai-editor/references/editor.md#figures-of-whoever-works).
- **Mask.** It draws only the highlighted instances, after the G-buffer and with its own depth
  buffer: the surrounding geometry does not clip it. It is rasterized without jitter at the
  window point resolution, independent of `Settings.resolution`, and respects the material's alpha
  cutoff. The filter and the PostProcess (`mirai_outline`) read it, and they see only the game
  styles.
- **Occlusion.** The visible depth is queried in scene coordinates, with its jitter and a
  conservative footprint of 2×2 texels (`include/highlight.slang`); of the occluded part what
  remains is what the level's `Highlight_Style.behind` says.
- **Filter.** A compute prepares a premultiplied layer at point resolution that the tonemap
  composes after TAA. The dispatch is limited to a conservative on-screen bound of the
  highlighted instances, expanded by the radius; outside it the tonemap omits the layer, and a
  bound that crosses the camera plane covers the screen.
- Moving the camera recomputes the bound without rebuilding scene, instances or TLAS. A coplanar
  surface does not enable passes or clip the mask.
- An `outline_only` instance with `highlight` is drawn only in the mask and counts as visible
  (`highlight_drawn`): the editor shows this way what an agent deleted.

## Reference grid

- `Environment.ground_grid` (the asset preview views; in a scene the grid is an editor viewport
  option) enables in composite a procedural Y=0 plane with antialiased lines, X/Z axes, quadrants
  and distance fade.
- The linear depth limits it to the background without opaque surfaces, also when the model
  crosses the origin; the later transparent pass attenuates it with the material.
- TAA reprojects its world position.
- It adds no meshes, pickables, shadows or bounds.
- `scene_set_environment` changes the environment without rebuilding the TLAS; a preview lighting
  change discards histories and clears probes reusing their resources.

## Statistics

`renderer_stats` reports:

- GPU time of each interval between `cmd_timestamp` while someone asks for it
  (`host.profile_request` or a recording; `rhi.timestamps_want`), and otherwise a `frame`
  interval. Metal samples at the start and end of each encoder (the only thing Apple Silicon
  supports): an interval goes from the first start to the last end of its encoders. The intervals
  are on the `time.tick_now` clock, converted with a CPU and GPU clock pair sampled when they are
  collected: Metal always, Vulkan with `VK_KHR_calibrated_timestamps` (or the EXT) in the domain
  of `tick_now` (QPC on Windows, `CLOCK_MONOTONIC_RAW` on Linux). Without the extension, Vulkan
  places the last timestamp of the frame at the moment it collects it: it keeps the durations but
  arrives late;
- visible, culled and occluded instances, probes and estimated rays per frame;
- what was discarded by capacity ([UI limits](ui.md#capacities));
- materials, textures, their memory, reduced textures and compression
  ([materials](materials.md#textures));
- the counters of the [extensions](views.md#extension-stages) (`Stats.counters`).
