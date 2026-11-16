# UI, world panels and debug lines

`render/ui.odin`, `ui_offscreen.odin` and `debug.odin`; the fields of each type are commented
there.

- Everything drawn over the finished image enters through `Frame_Desc` and is recorded in the pass
  of the LDR target, after the tonemap and the LDR PostProcess, in this order: world panels, debug
  lines and screen layers.
- They are display colors: exposure, tonemap and PostProcess do not alter them.
- A frame without panels or lines records nothing for them.

## Screen layers

`Frame_Desc.ui`: each `Ui_Layer` carries vertices (`Ui_Vertex`, in window points), optional
`shapes`, `effects` and `draws`; the layers are drawn in order, the game UI first and the editor
one on top. A `Ui_Draw` is a range with its scissor (with negative width or height, empty clip) or
a `Begin_Layer`/`End_Layer` that delimits an isolated group.

- **`Ui_Vertex.material`** chooses the color source: flat color, font atlas, asset thumbnails,
  material sphere ([previews](materials.md#material-previews-and-thumbnails)), table image
  (`ui_image`), analytic shape (`UI_MATERIAL_SHAPE_BIT`) or a [UI program](shaders.md#programs)
  (`UI_MATERIAL_PROGRAM_BIT`), whose `ctx.time` is `Frame_Desc.time`. The vertex color keeps the
  tint.
- **Font atlas.** `renderer_set_font` with another size creates the texture and uploads it whole;
  with the same one, it stores the region that changed and the frame recorded afterwards copies it
  without waiting for the GPU: **the pixels must stay valid until then**.
- **`Ui_Shape`**: `ui_shape.slang` evaluates rounded rectangle and ellipse by distance, with the
  vertex UVs in the local position of the shape; a shape not uploaded gives transparent coverage.
  Its layout is a [shared struct](shaders.md#compilation).

### Isolated composition

- Each group (`Ui_Effect`) is drawn into a transparent target; its close applies once opacity and
  rounded mask to all the already composed children.
- The blurred background is taken from the parent target before opening the group and stays under
  the children: text and later children remain sharp. In a nested group, the background is the
  parent's target.
- A texture is never read while it is being written.
- Groups without a close, invalid ones or ones that exceed the depth are discarded and counted;
  the frame always returns to the LDR target.
- The effects are screen ones; world panels do not apply them.

## World panels

- `Frame_Desc.panels`: a `World_Panel` is UI placed in the scene, with the same vertices and
  shapes in panel points, `billboard` toward each view's camera and `view` for a single view of a
  split screen.
- Scissors do not apply to panels; each panel is a draw with its constants. A shape table shared
  by several panels and the screen layer is uploaded once.

## Offscreen UI

- `ui_texture_add(r, width, height, name, effects)` adds to the texture table an sRGB entry that a
  material or the UI show like any color texture, and what draws it: an RGBA8 target, copied
  into the entry on the GPU; with `effects`, also the targets of an effects view. Up to
  `UI_TEXTURE_CAPACITY`, created in a transaction between frames; `ui_texture_remove` removes them.
- **`Frame_Desc.ui_textures`**: a `Ui_Texture_Draw` is UI in units of `size`, which covers its
  texture: a world panel on a mesh or an interface captured alone. Its layer is drawn before the
  views, over `clear`, with the same pass as the screen layers (`Ui_Surface`): scissors, isolated
  layers and background blur at the scale of the texture, with targets of its size that are
  created the first time it composes a layer. Another one of the same frame on the same texture
  draws on top, and the materials of that frame already see it. `ui_texture_capture` reads it
  between frames; an `offscreen` and `ui_only` frame draws only these textures.
- **`Frame_Desc.effect_views`**: an `Effect_View` draws in its texture what the extensions draw in
  the [`Effect`](views.md#extension-stages) stage seen by its camera, over nothing, after the
  frame's simulation and before the UI that shows it: the particles of a `Particles` node
  ([vfx](../../mirai-world/references/vfx.md#ui-effects)). Its light, with exposure 1,
  goes through the display transform (`ui_particles.frag`) and the part of the pixel they cover
  is the alpha.
- **`Frame_Desc.probes`**: a `Depth_Probe` asks for the linear depth of the opaque scene in a patch
  of cells around a pixel of a window view, with the camera it is drawn with; it arrives at
  `renderer_depth_probes` one or two frames later, with the farthest surface of each cell.
  `depth_probe_hides` takes a point to that camera and says whether the cell where it falls covers
  it, or that it does not know outside the patch.
- `mesh_ray(r, mesh, transform, origin, direction)` gives where a ray touches a mesh, its first
  texture coordinate and the normal there, from what the renderer keeps on the CPU: its software
  BVH, or the one that `mesh_ray_prepare` builds when it does not keep it (hardware tracing), which
  lives until `mesh_ray_release` or the mesh goes. World panels on meshes and editor picking use
  it. A pose of `skin_create` is touched as its palette and its morph weights of the next frame
  pose it; one that an extension deforms, at rest.

## Debug lines

- `Frame_Desc.debug`: a `Debug_Lines` is an immediate batch over caller memory
  (`debug_lines_make(storage, depth_test)`) that is filled every frame with the `debug_*`
  primitives.
- One-pixel lines, without antialiasing. One that does not fit is discarded and counted in
  `dropped`.

## Depth and composition

- Panels and lines are drawn after TAA and the tonemap, at the drawable resolution and without
  jitter: without history, sharp and with their colors.
- `shaders/include/overlay.slang` hides the fragment that lies behind the farthest of the G-buffer
  depths in a 2×2 texel footprint, with tolerance.
- The queried depth is that of opaque surfaces: a panel or a line behind a glass is drawn over it.
  The edge where a surface covers a panel follows the scene texels.
- In nested views, see [opening](views.md#nested-views).

## Capacities

- `Renderer_Desc.ui_vertex_capacity`, `ui_shape_capacity`, `debug_vertex_capacity` and
  `ui_layer_depth` (zero: the `render` constants). What does not fit is counted in
  `Stats.ui_vertices_dropped`, `ui_shapes_dropped` and `debug_vertices_dropped`.
- The isolated targets and the two blur ones are created on start or resize. No stable frame
  allocates, creates targets or grows buffers; a list without groups adds only its draws to the
  LDR pass.
