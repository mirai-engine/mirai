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
- **Projected textures** (`texture` of `Spot_Light` and `Rect_Light`, `Light_Desc.texture`):
  the light's color is multiplied by its texture where each part of it falls. A spot lays it
  across its cone as a slide in a projector, the circle of the cone inscribed in it, its width
  along `Light_Desc.texture_axis` (+X of its entity); a rectangle across its face, as
  `Light_Emission` lays its material (which a texture of the light replaces). A point light has
  no direction to lay one over and takes none. The color comes from `light_contribution`, the one
  evaluation of a light at a point: the direct light with maps, samples or the lists of the
  lights without shadows, the fog and media, glass, overlays, reflection hits, the probes, lit
  particles and the lights of portals take it alike. The texture of a spot is blurred over the
  pixel of a surface of the view (`shading_footprint`) and is as sharp as its finest level
  elsewhere. Where a group of the tree stands for its lights (far groups of a cut, walks,
  weights of the grid), a light counts with its color as if its texture were white.
- In the record (`Gpu_Light.size`), the image word `w` holds the entry of the texture with
  `GPU_LIGHT_TEXTURE`, or a rectangle's material row; a spot keeps the right of its texture in
  `z`. A light without a texture has the record it would have without the field, reads no
  texture and adds no pass. Textures of lights do not report their levels
  ([residency](materials.md#residency-by-sampling)): they keep those they were loaded with.
- **Shares** (`Light_Desc.indirect` and `scattering`, the sun's in `Sun_Desc`): what of its light
  the probes gather and what media scatter, 0 to the largest half; the direct light of a view does
  not read them. They travel as two halves in `Gpu_Light.axis.w` (`light_shares`), and a group
  of the tree keeps the mean of each share of its lights weighed by their light
  (`Light_Node.indirect` and `scattering`), zero only when all of them are. Zero in a
  `Light_Desc` is a light that neither bounces nor lights a fog, and costs nothing there: the
  walks and the cut of a probe hit pass it by, and media never pick it.
- **Lamps.** Shadow rays stop before the box of their light's sphere: a light inside its lamp
  casts no shadow with it.
- **Without shadows** (`Light_Desc.shadowless`, the `shadows` of its component off): nothing
  stops its light, and it costs no shadow work: no map, no cell of the grid, no node of a cut, no
  ray. It goes to the tree of the lights without shadows ([light tree](#light-tree)): the direct
  light, the probes and the media take it alike. A sun
  without them (`Sun_Desc.shadowless`) is `SUN_UNSHADOWED`, as with `Settings.sun_shadows` off.
- For the rays that gather light (probes and the reference), an emissive instance that contains
  the center of a light and whose box is not much larger than its sphere is that light
  (`hit_on_light`): the hit brings nothing. Its emission would count the light twice, and also
  what its surface reflects: inside the sphere of a light the irradiance is that of its surface.
- An emissive surface without a light inside illuminates by indirect light; reflections and glass
  show the emission of all of them.
- There are no reservoirs or light history: a light that moves, turns on or turns off is worth it
  from the frame in which it changes.
- **The lights of a frame are those of the scene, known on the CPU**: nothing writes lights on the
  GPU, so what depends on them (the tree, the grid, the shadow pages and caches) is kept while they
  stay still. A particle glows by its emission and is not a light; an effect that must light its
  surroundings carries a light on its entity. Decided by the user: bringing back per-particle or
  GPU-written lights needs a measured reason that holds against this.

### Capsules and rectangles

- **Capsule** (`Light_Desc.length` and `axis`): a sphere of `radius` along a segment, with the
  irradiance of the segment cut below the horizon (Picott).
- **Rectangle** (`size`, `direction` and `axis`): shines evenly toward the -Z of the entity of its
  `Rect_Light` (`axis`, its -X, is its right seen from that side), with the exact irradiance of
  the part above the horizon (Arvo). With `texture`, or else `material` (the emission of the
  material), its image tints it: the diffuse takes the color around the nearest point filtered by
  its distance; the highlight, that of the point it comes from filtered by the lobe.
- `intensity` is in candelas; that of a rectangle is the luminance of its face, in nits
  ([units](display.md#units)).

### Light tree

`render/light_tree.odin`:

- `light_tree_build` splits the lights that light every way from spots and rectangles and each
  kind by reach class (`light_reach_class`, four times apart): no group mixes two of those parts.
  Within a part it splits where the two halves cost least by the surface area and orientation
  heuristic of PBRT-v4 (`light_bounds_cost`: power, the solid angle their light shines through
  and the area of their box), so lights close together, alike in power and facing alike share a
  group. It travels in
  a buffer (`SLOT_LIGHT_TREE`) in depth order: the two children of a group go after it, and no
  traversal opens a group that does not satisfy this (`light_node_opens`), so none goes back even
  if it reads a malformed tree.
- A group stores what its lights give together as a sphere (color, weighted center, radius, reach
  and spread) and where they shine (Conty Estévez and Kulla 2018, as in PBRT-v4): the cone of the
  directions they shine whole in, how far past it their light fades out and the narrowest cone
  each shines whole in around its own axis. A point outside that receives nothing from the group:
  without the cone, a group of downlights that the cut could not open lit the ceiling.
- A group of spots or rectangles stands for its lights like any other (`node_aims`): its light
  is that of one light whose cone lies between the narrowest of theirs and the cone of the group,
  within the most and the least the cone lets through, and how far it may be from either counts
  in its error, so it opens where the directions of its lights matter.
- **Without shadows.** Those lights form a tree of their own after that of the others
  (`light_tree_shadowless`), which no traversal from node 0 meets; while every light casts none,
  the root of those that do is a group of none (`LIGHT_NODE_NONE`), which reaches nothing. They
  do not enter the cut of a point or trace rays: the frame constants give the root of their tree
  (`shadowless_lights`) and `shadowless_lighting` adds what it gives, like the
  [unshadowed light](#unshadowed-light-of-a-pixel) of the others. The direct filter adds it to the
  pixel as it is, without a shadow, from the [list](#lists-of-a-cell) of its tile;
  `direct_lighting` (hits, probes, glass, overlays, the points that trace their own rays and the
  points of media) without rays, and so does the reference.
- **Changes.** While the lights keep their number and each its class (with shadows or without,
  directed or not, and its reach class), `scene_light_update` refits
  the leaf that changed and the groups above it (`light_tree_refit`), past `LIGHT_REFITS_MAX` in a
  frame the whole tree once, and only the changed ranges go; `scene_lights_settle` rebuilds the
  tree once a frame when its cost (`light_tree_cost`, that of the build summed over the groups)
  grows beyond `LIGHT_TREE_REFIT_SLACK`. Another number or another
  class is another set (`light_revision`): it is rebuilt and uploaded whole.
- A group keeps its shortest and longest range. It reaches as far as its longest-reach light,
  windows its light halfway between both ranges and counts their difference in its error, so it
  neither loses a light that reaches far among short ones nor lends the short ones its reach.

### Unshadowed light of a pixel

`local_lighting` and `lights_estimate` walk the tree from the root without entering the groups
that do not reach it. The pixels of a view's direct light take the lights with shadows from the
[grid](#direct-light-of-a-view) and those without from the [list](#lists-of-a-cell) of their
tile, which holds what the walks would visit; hits, probes, glass, overlays and the points that
trace their own rays take both kinds from the tree:

- A group represents its lights as a sphere while its bounded error is small compared with the
  light that reaches the point: by the curvature of the falloff and of the cosine across its
  lights, by all its light where they are on both sides of the horizon, and by the variation of
  the reach window. Between the represent threshold and the open threshold, group and children add
  in gradual proportions. A group that is near relative to its size always opens.
- The light it errs against includes what the point already has: the sun and the lights with
  shadows of the pixel (`direct_filter`) or of the hit (`direct_lighting`).
- A walk visits at most `LIGHT_WALK_MAX` nodes, opening first the group whose light is most at
  stake; past them, the groups it holds stand for their lights. Its cost does not grow with the
  lights that reach a point, and it is the same every frame. Where the groups to open fit, the
  order does not change the light: the walk opens them last held first, weighing no need, and
  starts again in order only when it is cut short.

### Lists of a cell

`render/light_lists.odin`, `light_lists.comp`, `light_lists.slang`:

- What both walks of the lights without shadows visit is decided once for the points of a cell,
  and each point sums that list with no walk. The cells of a view are the tiles of its screen,
  listed again each frame from the box of the points of their pixels and that of their normals.
- **What a list holds**, in the order of the tree: a light; a group that stands for its lights at
  every point of the cell; a group that may open at some point, followed by what lies under it.
  A group no light of which reaches the cell is left out with what lies under it, and one that
  opens whole at every point is left out alone.
- **The sum is that of the walk.** A point weighs each entry with the functions the walks weigh
  a node with (`estimate_node`, `local_node`): its own estimate, its own doubt, its own shares
  between a group and what lies under it. So a list changes no light: it is the same on both
  sides of the border of a cell and whichever cell holds the point, and a list may hold more
  than a point needs, never less. A rule of the walks changes there and nowhere else.
- **The bounds are loose on the safe side.** A group stands for the cell only where the most it
  may err over the box stays under `LIGHTS_GROUPED` of the least light the estimate gives the
  cell; the light of the sun and of the lights with shadows, which a point also errs against,
  is left out of that least.
- **A list is bounded**: it keeps as many nodes of each walk as the walk visits at most, so what
  a walk gives a point fits the list of a cell no wider than the point. A cell that would list
  more lists none and each of its points walks the tree, so its light is still that of the
  walk and nothing shows at its border; `Stats.light_lists` counts it (`walked`), and the
  status of the editor shows it.
- The lists are those of the whole light of each light (`LIGHT_SHARE_ALL`): a cell for the
  probes or the media needs its own, since the estimate a group errs against is that of the
  share.

### Cutoff of a point that traces its own rays

`light_cut`:

- The points of the view with neighbours and a filter take their light from samples of the grid
  of the lights ([direct light of a view](#direct-light-of-a-view)), whose cost does not grow with
  the lights but which shows a pattern without the filter; a point alone (glass, overlays, the
  other side of a surface, hits of reflections and probes) needs all of its light on its own, and
  takes it from the cut, which groups the far lights.
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

## Direct light of a view

The `direct` step ([frame graph](frame-graph.md#passes)) takes the light of each point from a
fixed number of samples (`direct_samples`) spread over the lights that reach it:

- **Grid of lights** (`render/light_grid.odin`, `light_grid.comp`). The world in cells whose lists
  hold the lights that reach them; past `DIRECT_FEW` a cell holds an alias table to draw from.
  The GPU rebuilds it in the frame the lights change; `light_weight.slang` weighs each light at a
  point by `light_weight_at`, which also weighs a light of the tree (`node_weight`): a light is
  weighed in one place. It covers the ranges of the lights with shadows. A cell whose entries
  would not fit the rows counted on the CPU lists none.
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
  whole scene and leaves what stopped it. The other samples meet only what stopped the rays of their
  group and of the groups around (with hardware ray tracing, each is a ray query), and those of a
  light only what lies in the cone from the point to it: the cost does not grow with the scene.
- **Points.** With `direct_half_resolution` the points are one pixel of each 2x2. Every frame
  takes every point: the direct light keeps nothing from the frame before, so nothing trails
  behind what moves.
- **Filter** (`direct_points`, `direct_spread`, `direct_filter`). The light of the local lights
  with nothing in the way is taken over a 3x3 window of the pattern on the surface of the point;
  the part of it that got there, and the part of the sun that did, over the points of that window
  within the noise of the samples, and then each spread over the penumbra radius that what hid it
  gives. The pixels take them from the points around them of their surface. The last pass also
  adds the [lights that cast no shadows](#lists-of-a-cell) as they are, the lights of
  [extensions](views.md#extension-hooks-and-constants) each with its hard ray, and the other side
  of a surface that lets light through (`direct_lighting`).
- **Shadow maps** (`render/shadow_maps.odin`; every renderer draws them). Every frame, from the
  camera and the lights alone, the lights whose sphere covers a share of the view get a map for each
  face of their cube they light the view through, and the sun one for each of its levels around the
  eye (each twice as wide as the one before, up to the reach of the scene). A light turned off takes
  none; a spot no wider than a face of the cube takes one map along its cone. They draw the clusters
  of the instances of the scene and of the batches that cast shadows at the detail a texel of the
  map asks for where they lie (`shadow_map_detail`), not the eye, and leave out an instance smaller
  than a texel of the map (`shadow_map_unseen`). Clusters of masked slots are drawn apart, with
  their [mask map](materials.md#alpha) as a shadow ray reads it, with the derivatives of its uv, a
  texel of the map wide. Glass casts no shadow in the maps and colors none of their light, as in
  the shadow rays of the lights no map holds ([glass in rays](materials.md#glass-in-rays)):
  colored light through glass is the light's own, one that projects a texture. They are culled as
  the view culls its own: by instance and slot, which hands the clusters of the levels the cut of
  the map can take (`instance_clusters`) to a pass by cluster in chunks, which hands each to every
  page of the round it covers, into lists that count what does not fit and grow, like those of the
  view.

## Pages of the shadow maps

- **Pages of the maps.** A map lies in a slot: each of its mips a square of `SHADOW_PAGE` pages
  half as wide as the one before (a level of the sun has its finest alone), of which only those the
  points of the view read exist. `shadow_mark.comp` marks, for each point of the direct light, the
  pages the taps around it reach in the level of the sun and the mip of each face of a light with
  one texel to one or two pixels of the view there (`SHADOW_TEXEL_PIXELS`, `sun_pick`,
  `light_pick`; a face no finer than
  its widest penumbra over the search of the taps). Of its own level or mip a point marks the
  pages of the taps nearest it (`SHADOW_SEARCH_NEAR`) and of the ellipse whose lit share it takes;
  where the search of its blockers reaches farther, the pages of the level or mip as many times
  coarser, which its far taps read: a blocker that far casts a penumbra as wide, so a tall scene
  asks for hardly more pages of the finest levels than a low one. Over the top of each octave the
  point blends into the next level or mip, whose pages it marks too, and its texel-based constants
  grow to meet those of the next. The first level of the sun is a metre wide, each after it twice as
  wide, and the grid of the pages and texels of every level lies on the world, not on the origin of
  the frame.
  `shadow_pages.comp` gives each marked page a page of the pool of the view through the table of
  the pages (`Shadow_Raster.table`, at `SLOT_SHADOW_TABLE`), in the same frame, so a page first
  read is drawn before it is read. Pages are given in one order every frame: the safety net first
  (the 2x2 pages of each level of the sun nearest the eye, the coarsest page of each face), then
  from the coarsest level or mip to the finest; past the pool the finest are left out
  (`SHADOW_COUNT_LEFT`), the same every frame. A page keeps its place while no point reads it,
  until another needs it: free pages first, then those unread the longest; one read within a
  cycle of the jitter of the view gives its place only to a page of a level that ranks sooner,
  so that where the pool is full a page the points of one frame miss and those of the next read
  is not drawn again. What stays changing under a page still marks it stale, so a page read is
  always of this frame. Where a page is not drawn
  its entry names the nearest coarser level or mip drawn there (`SHADOW_ENTRY_COARSER`), which its
  points read; where none is, they trace. A point looks up the entries of the 2x2 pages around
  its taps once (`shadow_near`), which its taps and its hard shadow read. A pass after
  the maps that reads them (the fog) marks the pages it reads for the next frame
  (`pass_shadow_marks`). A level moves with the eye by whole
  pages and keeps its pages where they are in the world (`shadow_page_entry`): walking draws the
  pages that come in; along the light it keeps how far it reaches towards the sun while the scene
  stays within it. A tap past the side of a face of the cube of a light reads the face its
  direction falls on (`shadow_beside`).
- **What a frame draws at most.** The draws of the cache and those of the atlas each take at most
  the bound of the renderer in a frame of any view, still, moving or first (`Shadow_Bound`). It
  follows the GPU time the rounds of the maps take (`SHADOW_MAPS_TIMING`, measured in every frame
  with `rhi.cmd_measure_begin`, not the steps of the pages, which cost the same whatever it is), as
  what they draw costs in proportion to it: from `SHADOW_FRAME_CLUSTERS`, what the least GPU the
  engine runs on draws into a depth map, masked, in a few milliseconds, it grows while pages wait
  and the rounds take less than their share of the rest of the frame, a refresh of the display at
  least (`SHADOW_MAPS_SHARE`), so
  that filling a view slows its frames by that share at most, and shrinks when they take more, never
  past `SHADOW_FRAME_CLUSTERS_MOST`, far within the time a driver gives a draw before it resets the
  device. Before the cull by cluster, `Grant` gives the pages, those whose points read them drawn
  the frame before first (`SHADOW_JOB_KEPT`), then in the order they are given, while what they take
  fits half the bound: what a page took when the round last drew it, else what the cull by instance
  foresees, scaled by what the draws took of that before (`SHADOW_WORDS_SCALE`), and for a page not
  drawn yet a part of the share at most, as what is foreseen strays most where a page holds the
  most. A page may take twice that, so one that takes more is the only one left over; a page of the
  cache that takes more than half the bound is drawn in bands of its rows over frames
  (`SHADOW_WORDS_BAND`); a page of the atlas that came is granted only where its quota leaves the
  pages kept room to take more the frame after, so a page composed while what moves in it moves is
  composed every frame. A page is foreseen once and keeps it until drawn, and the culls after the
  grant go over the slots and spans of the pages granted alone: a page that waits costs no instance.
  A page left over, one that waits and one whose band is not its last are not ready that frame
  (`Settle`): their points read the nearest coarser page drawn, or trace, and the steps run again
  the next frame.
- **A still view.** While its camera, size, parameters and lights stay and no caster changes
  (`Shadow_Seen`), a view keeps the marks and the table of the frames before: its points mark the
  pages they read only for a cycle of its jitter after a change, the marks add up, and the steps
  of the pages run (a gate writes their arguments) only where a point or a pass after the maps
  marked a page not drawn nor left out of the pool, or a page waits for a frame with room for it
  (`SHADOW_STEP_NEW`). A still frame marks and
  gives no page (`Stats.shadow_marked`, `SHADOW_STEP_RUNS`).
- **What a frame draws.** The cost follows what changed. The cache of the view
  (`Shadow_Raster.cache`) holds what stays, page by page: a page draws there again only where it is
  new or what stays changed under it (an instance that came, went or changed its box or pose, a
  page of its mesh, a masked material), of a page it held only the texels the boxes of what
  changed cover (`SHADOW_WORDS_PART`): what else lies in a wide page is not drawn again. The
  atlas (`Shadow_Raster.atlas`), what the passes read, composes the cache and what moves again
  only in the pages where the cache drew or what
  moves was or is. The boxes of what changed mark their pages on the GPU, but where the cache hides
  them: the cache keeps the farthest depth over blocks of each page it drew (`Shadow_Raster.hiz`),
  and what moves is not drawn where it lies past that. An instance that changes again within
  `SHADOW_MOVER_FRAMES` moves (each followed on its own, however many,
  `Scene_State.shadow_changes`): the cache leaves it out once, and the atlas draws it in the pages
  its moves cover until it stays that long and joins the cache again; a mover that stands still
  costs nothing. A batch of a deformable that sways (the wind) moves so in the maps whose texel is
  narrower than its sway, in the pages the boxes of its instances cover (`SHADOW_CULL_SWAY`), not
  all those of its box; the others draw it at rest and keep it. A light or a level of the sun that
  moves or turns lets go of its pages and draws those read whole into the atlas alone that frame,
  and the cache the next still frame; an origin jump lets go of every page.
- **Reading the maps.** A map holds a point only within its face and range, and samples tell
  elsewhere. A tap compares a blocker with the plane of the surface of the point where the tap
  falls, less twice what the plane rises from there to the middle of its texel (scaled to the texel
  of a coarser page it reads), so a surface never shades itself; a tap no page holds tells nothing.
  A point under a map takes taps around it: all lit, lit; all blocked, hidden; where
  they disagree (a penumbra) it takes the hard shadow of the map at the point, and `direct_spread`
  averages that evenly over the points of its surface within the penumbra width the blockers give,
  the wider of that of the point and that of each neighbour, so the penumbra is the same seen from
  either side. A point wider on its surface than its penumbra (far ground seen at a grazing angle)
  spreads its taps over its width and takes the share of them that is lit, which the jitter of the
  view does not move. Lights without maps (small on the screen) trace their samples: raster for near
  and large lights, rays for far ones. The constants of the view carry the levels of the sun it
  drew (`Gpu_Frame.sun_maps`), so that a pass after the direct light takes the shadow of the sun
  from them and traces only where none holds the point (`sun_shadow_seen`; an extension binds the
  atlas with `Surface_Source.Shadow_Atlas`): the fog lights its cells so. The buffers of the maps
  (`Renderer.shadow_buffers`) and the lists of their cull are shared by the views; the cache, the
  atlas and the pages are each view's own.
- **Skinned meshes.** The skin writes the posed box and normal cone of each cluster, grown by the
  reach of its vertex programs, so that the view cull and the shadow map cull leave posed clusters
  out like static ones.
- **Shapes.** The points of a capsule or a rectangle cover their shape (`light_point`); those of a
  rectangle go on the diagonals of the cells of a 4x4 grid. One below the surface horizon gives no
  light.
- **Points that trace their own rays.** Glass, overlays, the back side, probes and reflection
  hits use `direct_lighting`: one hard shadow ray per node of their
  [cut](#cutoff-of-a-point-that-traces-its-own-rays), and none where no light looks at them.
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
  - With the scene still there are no marks and the image is the same. Glass does not mark: the
    validation of the history reaches it.
- The debug view Shadows shows the part of the light that got there. `Stats.shadow` counts what
  the maps of the last view drew: clusters, triangles and pages, those left out and those that
  wait.
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
`render_a_wider_light_casts_a_softer_shadow`,
`render_an_edge_takes_no_light_from_the_face_beyond_it` and, for the cache of the maps,
`render_moved_cascades_give_what_whole_ones_give`,
`render_shadow_maps_follow_what_moves_in_its_frame`, `render_a_swaying_batch_shades_where_it_is`,
`render_a_page_first_read_is_drawn_in_its_frame`,
`render_a_full_pool_keeps_the_pages_of_a_jitter_cycle`,
`render_a_frame_draws_no_more_than_its_clusters_and_the_rest_comes_after`,
`render_a_swaying_batch_keeps_its_pages_under_the_bound`,
`render_a_wide_search_asks_for_coarser_pages_not_more_of_the_finest`,
`render_a_turning_sun_gives_what_whole_maps_give`
and `render_an_origin_jump_gives_what_whole_maps_give`, and for the lights and the sun without
shadows `render_a_light_without_shadows_lights_through_what_holds_it`, and for a mesh without
them `render_a_mesh_without_shadows_lets_the_sun_through`) and, for the grid and
the groups of lights and their lists, `render_many_lights_match_their_reference`,
`render_lights_that_few_reach_at_a_time_are_each_lit` and
`render_groups_of_lights_give_what_their_lights_give`; for the images of lights,
`lights_color_their_light_by_their_image` (GPU) and
`a_light_keeps_the_texture_it_projects_in_its_record` (without a device).
