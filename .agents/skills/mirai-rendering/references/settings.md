# Settings and inspection modes

## Settings

- `render.Settings` defines the budget of each effect; the comments of its fields say what each
  one controls. `renderer_apply_settings(r, settings)` changes it between frames and validates
  the whole request before applying: if a value is out of range it returns `false` without
  changing anything.
- `DEFAULT_SETTINGS` is the high quality; a CPU device starts with `CPU_DEVICE_SETTINGS`.
  Quality presets, frame limit and vsync belong to whoever presents (`rhi.swapchain_set_vsync`).
- Exposure belongs to each camera ([exposure](display.md#exposure)), not to the settings.
- `trace_mode` selects the tracer; `hardware_ray_tracing_active` says whether the hardware one is
  used and `Renderer.hardware_rt_note` why not. Changing it makes the pipelines and builds the
  structures of the other ([tracer in use](gi.md#bvh-and-acceleration-structures)); if the
  software pipelines are not made, `renderer_apply_settings` returns `false` and changes nothing.
- A change starts again only what was made with the fields that changed, in every view; the rest,
  histories, exposure and probes, stays, so a slider drag keeps them:
  - the main targets with `resolution` (several window views remake theirs in their next frame;
    texture views draw at the size of their texture); the glass targets with `glass_layers`. Only
    these wait for the device;
  - the probe volume with its shape, `colored_shadows` or `sun_shadows`; its probes gather again
    everywhere, keeping the volume, with `gi_strength`, `light_budget` or `sun_radius`. With
    either, the worlds not shown lose the light they kept;
  - the histories that hold what the change alters: shadows with `sun_shadows`; reflections,
    glass and TAA with `colored_shadows`, `sun_shadows`, `reflection_light_budget` and
    `reflections`;
  - the texture levels with `texture_max_size` and `texture_pool_megabytes`.
- `page_pool_bytes` recreates nothing: the
  [pages](scene.md#scene-and-instances) region is reserved once, with the first mesh that uses
  it, inside the vertex pool and before the blocks of the meshes that arrive later; a later
  change waits for the renderer to start again.
- `Graphics_Settings.texture_memory` and `geometry_memory` set `texture_pool_megabytes` and
  `page_pool_bytes`; at 0 they are automatic (a part of the device memory and the renderer
  default), and no preset touches them.

## Scene resolution

- `Settings.resolution` is a target of lines: the window views draw that fraction of the lines
  they span together, never above one pixel per point (on Retina, half the pixels of the drawable
  per axis) nor below `RENDER_SCALE_MIN`. The cost per pixel does not grow with the output, and in
  split screen all take the same scale. TAA brings the image to the drawable resolution. A
  texture view draws it at the size of the texture.
- The UI, panels, lines and outline are drawn after TAA at the drawable resolution: a budget does
  not blur them. Textures are read with a mip bias of `log2` of the scale, which keeps their
  detail.
- Changing the size, the number of views or the target recreates their targets.
- `Graphics_Settings.resolution` is that target; each preset writes its own. No setting stores
  the preset: what names one (a control, `graphics_preset` of `settings.set`, the code of a game)
  writes its fields with `graphics_preset_apply`, before the fields that go on top;
  `graphics_quality_of` computes the one the fields are at, and `graphics_apply` only reads. At
  the window of the render check, presets from Medium up stay at one pixel per point, so a check
  compares the same image with the same cost.

## Inspection modes

Each view chooses what it shows instead of its lit image with `Frame_View.inspection` (or
`Frame_Desc.inspection` in a frame without views), a `View_Inspection`
(`render/debug_views.odin`).

- `mode` is a `Debug_View`: the G-buffer and light channel ones are resolved in composite; the
  shadow, reflection and local light ones, in the `debug view` pass after composite.
- An inspected view is shown without exposure or display transform, without glass, overlays or
  sprites. Changing mode does not recreate targets or cut histories.
- `record` and `user`: an extension's mode, which the renderer records only in that view in the
  [`Inspect`](views.md#extension-stages) stage, over the `mode` image.
- `renderer_debug_view_status` says whether the window views can show a mode with their last
  pipeline, settings and scene, and if not, why; a mode they cannot show stays black. Its
  pipelines are created the first time a frame uses them (`LAZY_PIPELINES`).
- Which modes the editor offers:
  [inspection mode](../../mirai-editor/references/panels.md#inspection-mode).
