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
  used and `Renderer.hardware_rt_note` why not. Changing it builds the structures of the other
  ([tracer in use](gi.md#bvh-and-acceleration-structures)).
- `reference_lights` and `reference_gi` replace the direct and indirect light with their
  references ([shadows](lights.md#shadows), [indirect](gi.md#indirect-reference)).
- A change recreates only what depends on it: the states of the additional and texture views
  always; the main targets with the resolution; the probe volume with its shape and its budget;
  the glass targets with `glass_layers` (waits for the device). What changes the image the
  histories keep (`colored_shadows`, the reflection ones, the references) discards them;
  `colored_shadows` also restarts the probes. `page_pool_bytes` recreates nothing: the
  [pages](scene.md#scene-and-instances) region is reserved once, with the first mesh that uses
  it, inside the vertex pool and before the blocks of the meshes that arrive later; a later
  change waits for the renderer to start again.
- `Graphics_Settings.texture_memory` and `geometry_memory` set `texture_pool_megabytes` and
  `page_pool_bytes`; at 0 they are automatic (a part of the device memory and the renderer
  default), and no preset touches them.

## Scene resolution

- The window views draw the scene at `render_scale` of their points (on Retina, 1 is half the
  pixels of the drawable per axis) and TAA brings it to the drawable resolution. A texture view
  draws it at the size of the texture.
- `render_megapixels` (0: no limit) lowers that scale where the window views, added together,
  have more pixels: each axis by `sqrt(render_megapixels / pixels)`. The cost per pixel does not
  grow with the output, and in split screen all take the same scale, without going below the
  minimum of `render_scale`.
- The UI, panels, lines and outline are drawn after TAA at the drawable resolution: a budget does
  not blur them. Textures are read with a mip bias of `log2` of the scale, which keeps their
  detail.
- Changing the size, the number of views or the budget recreates their targets.
- `Graphics_Settings.render_megapixels` is its own setting: no preset changes it.

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
