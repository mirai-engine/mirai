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

- `light_tree_build` sorts the lights along a Z curve, point ones before spots, and builds a
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
- **Changes.** While the lights keep their number and each its class, `scene_light_update` refits
  the leaf that changed and the groups above it (`light_tree_refit`), past `LIGHT_REFITS_MAX` in a
  frame the whole tree once, and only the changed ranges go; `scene_lights_settle` rebuilds the
  tree once a frame when it inflates beyond `LIGHT_TREE_REFIT_SLACK`. Another number or another
  class is another set (`light_revision`): it is rebuilt and uploaded whole.
- A group that mixes very different reaches reaches as far as its longest-reach light, and the
  points it reaches traverse more nodes.

### GPU lights

An extension that asks for room for lights it writes on the GPU (`lights_ask`) has it from the
next frame, before the scene tree (`light_region_first`), in two parts: those that cast shadows
and those that do not, each rounded to a power of two, up to `LIGHT_REGION_MAX`. Those that cast
shadows come with where they lie and how far they light, which the CPU does not see otherwise:
the grid of the lights holds what of the scene they light.

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
  like the [unshadowed light](#unshadowed-light-of-a-pixel) of the others. The direct filter adds
  it to the pixel as it is, without a shadow; `direct_lighting` (hits, probes, glass, overlays and
  the points that trace their own rays), without rays; the media choose between the two trees by
  what each root gives and do not trace the ray of a light without shadow, nor does the
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
it. The pixels of a view's direct light do not use it (they take the
[grid](#direct-light-of-a-view)); hits, probes, glass, overlays and the points that trace their own
rays do:

- A group represents its lights as a sphere while its bounded error is small compared with the
  light that reaches the point: by the curvature of the falloff and of the cosine across its
  lights, by all its light where they are on both sides of the horizon, and by the variation of
  the reach window. Between the represent threshold and the open threshold, group and children add
  in gradual proportions. A group that is near relative to its size always opens.
- Deterministic: it is the same every frame.

### Cutoff of a point that traces its own rays

`light_cut`:

- The nodes to which a point traces a ray: each light that reaches it as long as they fit in the
  budget; if there are more, from the root the node that needs it most is opened (brightest and
  widest seen from the point, those that contain a spot first). Every light that arrives lies
  under a node of the cut.
- The ray of a group goes to one of its lights with probability proportional to the luminance the
  point reflects from each toward whoever sees it, with its BRDF; the ray is worth its light over
  that probability.
- Budgets: the points of the view that trace their own rays (`light_budget`: glass, overlays, the
  other side of a surface that lets light through), reflection hits at sharp surfaces
  (`reflection_light_budget`), volume probes (up to `PROBE_LIGHT_BUDGET`). Both settings go up to
  `LIGHT_CUT_MAX`.
- **Lit particles** ([`vfx`](../../mirai-world/references/vfx.md#passes)): the unshadowed light
  of both trees from all sides, with the estimate of the light that arrives from each.

## Shadows

- Sun and local lights have size: the sun `Settings.sun_radius`, the local ones their `radius`.
  The shadow opens with that size and the distance of the occluder, stays sharp where they touch
  and, seen from the side, stretches in the direction of the light.
- The cost of a pixel depends on its samples, not on how many lights there are.

### Direct light of a view

The `direct` step ([frame graph](frame-graph.md#passes)) takes the light of each point from a
fixed number of samples (`direct_samples`) spread over the lights that reach it:

- **Grid of lights** (`render/light_grid.odin`, `light_grid.comp`). The world in cells whose lists
  hold the lights that reach them; past `DIRECT_FEW` a cell holds an alias table to draw from.
  The GPU rebuilds it in the frame the lights change; `light_weight.slang` weighs each light at a
  point. It covers the ranges of the lights of the scene and the part of the scene that the lights
  with shadows a pass writes on the GPU light, from the box and reach of `lights_ask` (all of the
  scene for `LIGHTS_ANYWHERE`), held with a margin so that a moving box does not place it again
  every frame. A cell whose entries would not fit the rows counted on the CPU lists none.
- **Spread.** A point weighs the lights of its cell and spreads its samples over them by weight,
  systematically (one at each m-th of the sum of weights, from the place of the pixel in a 3x3
  pattern): a light that gives much takes many samples and none depends on chance. A light that
  took samples gives its exact light with nothing in the way, with the material, once, times the
  part of its samples that got there.
- **Sun.** The points keep of the sun only how much of it gets there, and the pixels take its
  light themselves, each with its own normal and material: at half resolution the shape of the
  sun's light is still that of the pixels, and a light that few samples would reach gives no
  noise. Where a map of the view holds a point, the map tells that part and the sun takes no
  samples; elsewhere it takes them as one more light, for that alone. A pixel with no point of
  its surface around it asks the map itself.
- **Rays** (`direct_rays`, `direct_samples`). One pixel of each 2x2 traces one sample through the
  whole scene and leaves what stopped it. The other samples meet only what stopped the rays of
  their group and of the groups around (with hardware ray tracing, each is a ray query), and those
  of a light only what lies in the cone from the point to it: the cost does not grow with the
  scene.
- **Points.** With `direct_half_resolution` the points are one pixel of each 2x2. Every frame
  takes every point: the direct light keeps nothing from the frame before, so nothing trails
  behind what moves.
- **Filter** (`direct_points`, `direct_spread`, `direct_filter`). The light of the local lights
  with nothing in the way is taken over a 3x3 window of the pattern on the surface of the point;
  the part of it that got there, and the part of the sun that did, over the points of that window
  within the noise of the samples, and then each spread over the penumbra radius that what hid it
  gives. The pixels take them from the points around them of their surface. The last pass also
  adds the [lights that cast no shadows](#gpu-lights) as they are, the lights of
  [extensions](views.md#extension-hooks-and-constants) each with its hard ray, and the other side
  of a surface that lets light through (`direct_lighting`).
- **Shadow maps** (`render/shadow_maps.odin`, `Settings.shadow_maps`; the Graphics settings always
  turn it on). Every frame, from the camera and the lights alone, the lights whose sphere covers a
  share of the view, and the sun in cascades, get depth maps in one atlas, so the cost does not
  depend on what moves. A light turned off takes none; a spot no wider than a face of the cube takes
  one map along its cone; the cascades of the sun end where the scene ends. They draw the clusters
  of the cut of the view, of the instances of the scene and of the batches that cast shadows: what
  casts a shadow is what the view draws, at the detail its distance from the eye asks for. Those of
  an instance with masked or blended materials are drawn apart, with their coverage as a shadow ray
  asks it (`hit_covers`). A point under a map takes taps around it: all lit, lit; all blocked,
  hidden; where they disagree (a penumbra) it takes the hard shadow of the map at the point, and
  `direct_spread` averages that evenly over the points of its surface within the penumbra width the
  blockers give, the wider of that of the point and that of each neighbour, so the penumbra is the
  same seen from either side. A point wider on its surface than its penumbra (far ground seen at a
  grazing angle) spreads its taps over its width and takes the share of them that is lit, which the
  jitter of the view does not move; the cascades of the sun reach the horizon of an open scene for
  that ground. Lights without maps (small on the screen) trace their samples: raster for near and
  large lights, rays for far ones. Glass with a program keeps only its mean in the tint of the maps:
  a point with such glass between it and a light a map holds takes all of its light from samples,
  whose rays run the program. The constants of the view carry the cascades of the sun it drew
  (`Gpu_Frame.sun_maps`), so that a pass after the direct light takes the shadow of the sun from
  them and traces only where none holds the point (`sun_shadow_seen`; an extension binds the atlas
  with `Surface_Source.Shadow_Atlas`): the fog lights its cells so.
- **Skinned meshes.** The skin writes the posed box and normal cone of each cluster, grown by the
  reach of its vertex programs, so that the view cull and the shadow map cull leave posed clusters
  out like static ones.
- **Shapes.** The points of a capsule or a rectangle cover their shape (`light_point`); those of a
  rectangle go on the diagonals of the cells of a 4x4 grid. One below the surface horizon gives no
  light.
- **Points that trace their own rays.** Glass, overlays, the back side, probes and reflection
  hits use `direct_lighting`: one hard shadow ray per node of their
  [cut](#cutoff-of-a-point-that-traces-its-own-rays), and none where no light looks at them. With
  `colored_shadows`, those of the hits cross the glass with its
  [medium filter](materials.md#medium-filter).
- **Reference.** `Settings.reference_lights` is the same system with many samples and without
  maps or half resolution: its average over a few frames is the exact image.
- **What changed.** The scene lists what casts shadows and changed since the last frame that drew
  it (`Scene_State.occluders`, `Gpu_Frame.moved`): each instance that moved, took another pose or
  shape, arrived or left, with the box it covers in both frames, the lights that moved or changed
  shape (not color or brightness) and the sun that turned more than its radius. Beyond the
  capacity, an instance joins the box that grows least, which then stands for several.
  - A sample marks its point (`occluder_changed`) if an instance that changed stops it, or if
    without stopping it crosses one of those boxes (the shadow that left or arrived), or if it
    goes to a light that moved. A sample stopped by something still does not mark.
  - TAA treats the pixel of a marked point as one that moves
    ([TAA](frame-graph.md#passes)), and the fog does not blend the history of a froxel whose
    ray crosses what changed ([`fog`](../../mirai-plugins/references/render-plugins.md)).
  - A batch that casts shadows marks its box when it arrives, leaves or changes (`batch_set`,
    `batch_remove`).
  - With the scene still there are no marks and the image is the same. The lights that the GPU
    writes and the glass do not mark: the validation of the history reaches them.
- The debug view Shadows shows the part of the light that got there.
- **Reference.** What the tests compare with, outside the renderer games run: a custom pass of the
  tests in place of the `Direct` stage (`render/reference_test.odin`) traces from each pixel to
  the whole set of points of the sun and of each light, randomly rotated per frame, without grid,
  maps or filter: its average over a few frames is the exact image.
- **Limits.** With few samples a penumbra shows the noise of its samples until the filter and the
  frames smooth it; a light without map whose penumbra no ray of its group crosses is as soft as
  the filter lets it.

Tests: the shadow ones of `render/render_test.odin` (`render_sun_shadow_is_ray_traced`,
`render_soft_shadow_blurs_with_the_distance_to_its_caster`,
`render_soft_shadow_leaves_with_its_caster`, `render_a_low_sun_draws_out_the_end_of_a_shadow`,
`render_a_wider_light_casts_a_softer_shadow` and
`render_an_edge_takes_no_light_from_the_face_beyond_it`) and, for the grid and the groups of
lights, `render_many_lights_match_their_reference`,
`render_lights_that_few_reach_at_a_time_are_each_lit` and
`render_groups_of_lights_give_what_their_lights_give`.

## Colored shadow filters

- `colored_shadows` (off by default): the shadow query also finds blend surfaces; each multiplies
  the ray's filter by `mix(white, linear_base_color, alpha)` and lets it continue. Rays are not
  deflected: no refraction or caustics in shadows.
- The filter of each texel is that of the samples of the view's direct light (the `color`
  variants of `direct_samples`); those of what the volume and reflection rays find, and those of
  the blend surfaces, take the [medium filter](materials.md#medium-filter) of each instance.
- A single traversal with exit at the first blocker: opaque surface, coverage of a mask or a
  filter that lets no light through. It shares the color read of the visible material, with
  explicit ray mip. Alpha zero does not filter; black with alpha one blocks.
- Glass with a program filters first by its mean and its exact filter arrives later, as a material
  point: the direct samples add in the resumption what changes
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
