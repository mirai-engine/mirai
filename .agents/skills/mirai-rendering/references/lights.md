# Lights and shadows

## Local lights

- A local light is a sphere that shines evenly, of radius `radius` of `Point_Light` or
  `Spot_Light` (0: a point, with a minimum for the light). All four lights shine toward the -Z of
  their entity and take their shape from its scale
  ([components](../../mirai-gameplay/references/libraries.md#render)).
- **Diffuse.** Intensity over the squared distance to the center; where the sphere goes below the
  surface horizon, the part that still shows (Snyder; Lagarde and de Rousiers).
- **Specular.** The point of the sphere nearest to the reflection direction, with the lobe
  widened by its size and normalized to conserve energy (Karis).
- Their shadows open with their size ([shadows](#shadows)). A soft window turns it off at `range`.
- A spot lights the cone of half angle `angle` around its -Z, with a soft edge.
- The color of a light is that of its component, independent of the tint of its entity's mesh.
- **Lamps.** Shadow rays stop before the box of their light's sphere: a light inside its lamp
  casts no shadow with it.
- For the rays that gather light (probes and the reference), an emissive instance that contains
  the center of a light and whose box is not much larger than its sphere is that light
  (`hit_on_light`): the hit brings nothing. Its emission would count the light twice, and also
  what its surface reflects: inside the sphere of a light the irradiance is that of its surface.
- An emissive surface without a light inside illuminates by indirect light; reflections and glass
  show the emission of all of them.
- There are no reservoirs or light history: a light that moves, turns on or turns off is worth it
  from the frame in which it changes.

### Capsules and rectangles

- **Capsule** (`Light_Desc.length` and `axis`): a sphere of `radius` along a segment, with the
  irradiance of the segment cut below the horizon (Picott).
- **Rectangle** (`size`, `direction` and `axis`): shines evenly toward the -Z of the entity of its
  `Rect_Light` (`axis`, its -X, is its right seen from that side), with the exact irradiance of
  the part above the horizon (Arvo). With `material`, the material emission tints it: the diffuse
  takes the color around the nearest point filtered by its distance; the highlight, that of the
  point it comes from filtered by the lobe.
- `intensity` is in candelas; that of a rectangle is the luminance of its face, in nits
  ([units](display.md#units)).

### Light tree

`render/light_tree.odin`:

- `scene_set_lights` sorts the lights along a Z curve, point ones before spots, and builds a
  binary tree split where the curve passes from one half of the space to the other. It travels in
  a buffer (`SLOT_LIGHT_TREE`) in depth order: the two children of a group go after it, and no
  traversal opens a group that does not satisfy this (`light_node_opens`), so none goes back even
  if it reads a malformed tree.
- A group stores what its lights give together as a sphere (color, weighted center, radius, reach
  and spread) and where they shine (Conty Estévez and Kulla 2018, as in PBRT-v4): a cone of their
  directions and how far beyond their light reaches. A point outside that receives nothing from
  the group: without the cone, a group of downlights that the cut could not open lit the ceiling.
- A group that contains a spot opens before the others; when the budget is not enough, it
  represents its spots with their cone.
- **Changes.** While the lights keep their number and each its class, `scene_set_lights` refits
  the leaves that changed and the groups above them (`light_tree_refit`), rebuilds the tree only
  when it inflates beyond `LIGHT_TREE_REFIT_SLACK` and uploads only the changed ranges. Another
  number or another class is another set (`light_revision`): it is rebuilt and uploaded whole.
- A group that mixes very different reaches reaches as far as its longest-reach light, and the
  points it reaches traverse more nodes.

### GPU lights

An extension that asks for room for lights it writes on the GPU (`lights_ask`) has it from the
next frame, before the scene tree (`light_region_first`), in two parts: those that cast shadows
and those that do not, each rounded to a power of two, up to `LIGHT_REGION_MAX`:

- Node 0 is the root of the lights with shadows; from 1, the tree of the leaves of that part, in
  the usual depth order; then, a leaf without light. The tree of the lights without shadows
  follows in the same way, whose root does not hang from node 0. The scene tree starts behind, and
  its lights go before those of the region: those of each part end in a null light.
- The traversals of the lights with shadows do not change: they still start at node 0 and do not
  see the others. While no step writes the region, the root is that of the scene and each node of
  each part, its empty leaf: a group written over unwritten children leads to a leaf. A CPU refit
  rebuilds the root with the scene.
- The lights without shadows do not enter the cut of a point or trace rays: the frame constants
  give the root of their tree (`shadowless_lights`) and `shadowless_lighting` adds what they give,
  like the [unshadowed light](#unshadowed-light-of-a-pixel) of the others. The pixel adds it
  without multiplying it by the fraction of its blocks; `direct_lighting` (hits, probes, glass,
  overlays and the pixels that trace their rays), without rays; the media choose between the two
  trees by what each root gives and do not trace the ray of a light without shadow, nor does the
  reference.
- `pass_lights` in `Simulate` links lights and nodes to write them and says where each part is
  (`Pass_Lights`); whoever links it writes the whole region and the root, which joins that of the
  shadowed part and that of the scene as `light_tree_group`. When `Simulate` ends everything is
  readable again.
- A region that nobody wrote in a frame returns to the scene's root alone and to no light without
  shadow in the next one; another size rebuilds the tree.
- The frame takes the region (`scene_light_region`) before sizing the light and tree buffers
  (`ensure_scene_capacity`): a new or larger region enlarges them before the tree is uploaded.
  The other way around, the copy went past the end of the buffer and the nodes there did not
  exist: a traversal read zeros, groups whose second child is the root.
- What the GI stores of them is not marked as a light change: the probes take them when traced
  ([particles](../../mirai-world/references/vfx.md#particle-lights)).

### Unshadowed light of a pixel

`local_lighting` traverses the tree from the root without entering the groups that do not reach
it:

- A group represents its lights as a sphere while its bounded error is small compared with the
  light that reaches the point: by the curvature of the falloff and of the cosine across its
  lights, by all its light where they are on both sides of the horizon, and by the variation of
  the reach window. Between the represent threshold and the open threshold, group and children add
  in gradual proportions. A group that is near relative to its size always opens.
- The light that arrives is that of the shadow block's cut, smoothed over the surface in the
  penumbra filter. Deterministic: it is the same every frame.

### Cutoff of a shadowed point

`light_cut`:

- The nodes to which a point traces a ray: each light that reaches it as long as they fit in the
  budget; if there are more, from the root the node that needs it most is opened (brightest and
  widest seen from the point, those that contain a spot first). Every light that arrives lies
  under a node of the cut.
- The ray of a group goes to one of its lights with probability proportional to the luminance the
  point reflects from each toward whoever sees it, with its BRDF; in the blocks it is worth its
  light over that probability.
- Budgets: shadow blocks (`light_budget`), reflection hits (`reflection_light_budget`), volume
  probes (up to `PROBE_LIGHT_BUDGET`), glass and overlays. Both settings go up to `LIGHT_CUT_MAX`
  (32).
- **Lit particles** ([`vfx`](../../mirai-world/references/vfx.md#passes)): the unshadowed light
  of both trees from all sides, with the estimate of the light that arrives from each.

## Shadows

- Sun and local lights have size: the sun `Settings.sun_radius`, the local ones their `radius`.
  The shadow opens with that size and the distance of the occluder, stays sharp where they touch
  and, seen from the side, stretches in the direction of the light.
- **Tracing** (`shadow trace`). One pixel of each 2×2 block, different in each frame, traces a
  shadow ray to the sun, to each node of its [cut](#cutoff-of-a-shadowed-point) and to each light
  of [extensions](views.md#extension-hooks-and-constants).
- **Light points.** The ray goes to one of a fixed set of points of the light's disc (or of
  choices among the lights of a group, or of directions of the sun's disc). The point of each
  block follows the Bayer order in each 4×4 of blocks (`block_turn`) and how the disc rotates
  changes per 4×4, not per frame (`light_point_shift`): points that moved between frames made the
  shadow of a flashlight or a flickering lamp flicker.
- The block stores the fraction of light that arrives (per channel with `colored_shadows`), the
  blur its penumbra asks for and the light that would arrive with nothing in between, with which
  the pixels decide how much to open the tree.
- **History.** `SHADOW_HISTORY_FRAMES`, reprojected and validated by normal and by the depth the
  point had for the previous camera, and kept within what the frame's rays say in the surrounding
  blocks. The more that clipping moves it beyond half the box width, the fewer frames it is
  worth, as in NRD's SIGMA: one moved by `HISTORY_SLACK` or more is worth one frame, and what it
  kept of a shadow that left does not remain. A clip within half the width is the dispersion of
  the rays around a thin shadow and shortens nothing. Where the point stays still on screen,
  `SHADOW_HISTORY_STILL_FRAMES`: one turn of what the block's ray sees, which repeats every
  `TAA_JITTER_PHASES` frames (the block pixel that traces and the view jitter; the light points
  are fixed). More frames gather nothing new and lag what is not marked.
- Without history, the block takes the frame's ray only if it came from its surface: if it came
  from another (the jitter takes the pixel to the other side of an edge), it keeps no frames and
  its pixels trace their own rays. This way the face that no light looks at does not light the
  edge of the one that is in shadow. It also keeps no frames if the traced pixel had no light
  above its horizon: on a wall with its back to the sun, the side of a joint that the normal map
  tilts toward the sun took the whole block (white dots on the bricks and columns of `church`).
- Where the point moves on screen, what the history stores is shifted with the motion (a sun
  patch through a stained-glass window drags): it keeps fewer frames the faster it moves.
- **What changed.** The scene lists what casts shadows and changed since the last frame that drew
  it (`Scene_State.occluders`, `Gpu_Frame.moved`): each instance that moved, took another pose or
  shape, arrived or left, with the box it covers in both frames, the lights that moved or changed
  shape (not color or brightness) and the sun that turned more than its radius. Beyond the
  capacity, an instance joins the box that grows least, which then stands for several.
  - A block's ray marks the block (`occluder_changed`) if an instance that changed stops it, or if
    without stopping it crosses one of those boxes (the shadow that left or arrived), or if it
    goes to a light that moved. A ray stopped by something still does not mark: its result does
    not change.
  - The marked block starts its history over with the frame's ray and its penumbra width; the
    filter blurs it like a newly uncovered one. The box of what changed joins where it was and
    where it is, so the ray of the shadow that leaves crosses it in the frame in which it leaves.
  - TAA treats the pixel of a marked block as one that moves
    ([TAA](frame-graph.md#passes)), and the fog does not blend the history of a froxel whose
    ray crosses what changed ([`fog`](../../mirai-plugins/references/render-plugins.md)).
  - A batch that casts shadows marks its box when it arrives, leaves or changes (`batch_set`,
    `batch_remove`).
  - With the scene still there are no marks and the image is the same. The lights that the GPU
    writes and the glass do not mark: the history clipping reaches them.
- **Filter** (`shadow filter`). Separable, over the neighboring blocks of the same surface, with
  distances in meters on its plane: it distributes the requested blur and the light that arrives
  and blurs the fraction; a newly uncovered block is blurred more until it accumulates frames.
- **Direct light.** Each pixel computes its unshadowed light, without rays, and multiplies it by
  the fraction of the neighboring blocks of its surface; that of the
  [lights that cast no shadows](#gpu-lights) it adds as is.
- A pixel without blocks with frames of its surface that receives some light, the `Light`
  pipeline and the ray hits trace their own hard shadows, one ray per node of their cut; without a
  light looking at it, its direct light is zero without rays. With `colored_shadows`, those of the
  hits cross the glass with its [medium filter](materials.md#medium-filter).
- **Shapes.** The points of a capsule or a rectangle cover their shape (`light_point`); those of a
  rectangle go on the diagonals of the cells of a 4×4 grid. One below the surface horizon gives no
  light and the block uses the opposite one. The hard shadow of a shape goes to the point nearest
  to the normal (`light_aim`).
- **Reference.** `Settings.reference_lights` traces from each pixel to the whole set of points of
  the sun and of each light, randomly rotated per frame, without tree, blocks or filter: its
  average over a few frames is the exact image.
- **Limits.**
  - A block has one fraction for all its lights: the specular highlight of a covered light turns
    off in proportion to what covers all of them.
  - A penumbra narrower than two blocks joins the points of its blocks only in the filter; what
    is uncovered samples the softer one for a few frames. The penumbra width has a maximum in
    blocks.
  - On a face two or three pixels wide the blocks sometimes fall on it and sometimes on the
    neighbor: its light varies a little between frames.

Tests: the shadow ones of `render/render_test.odin` (`render_sun_shadow_is_ray_traced`,
`render_soft_shadow_*`, `render_a_low_sun_draws_out_the_end_of_a_shadow`,
`render_a_wider_light_casts_a_softer_shadow` and
`render_an_edge_takes_no_light_from_the_face_beyond_it`).

## Colored shadow filters

- `colored_shadows` (off by default): the shadow query also finds blend surfaces; each multiplies
  the ray's filter by `mix(white, linear_base_color, alpha)` and lets it continue. Rays are not
  deflected: no refraction or caustics in shadows.
- The filter of each texel is that of the shadow rays of the view's direct light (blocks,
  `direct rays`); those of what the volume and reflection rays find, and those of the blend
  surfaces, take the [medium filter](materials.md#medium-filter) of each instance.
- A single traversal with exit at the first blocker: opaque surface, coverage of a mask or a
  filter that lets no light through. It shares the color read of the visible material, with
  explicit ray mip. Alpha zero does not filter; black with alpha one blocks.
- Glass with a program filters first by its mean and its exact filter arrives later, as a material
  point: the shadow blocks and the `direct rays` add in the resumption what changes
  ([deferred filters](materials.md#surface-programs-in-rays-and-raster)).
- Glass also loses what it reflects head-on at each face; a solid counts color and absorption
  once, where the ray enters.
- Native geometry is built without duplicate candidates per primitive: a surface does not filter
  twice.
- The `color` constant of the same Slang, with the filter of each texel
  (`MIRAI_COLORED_SHADOWS`) or the mean one (`MIRAI_GLASS_MEANS`); its pipelines are made and used
  only with the option active and blend in the scene, and without it the code skips those
  traversals. The reflection pass always includes the per-texel one, for its sharp rays.
- Changing the option invalidates the histories and restarts the probes.
- Software tracing admits a tolerance in barycentrics at the edges: an oblique ray does not leak
  through a shared diagonal.
