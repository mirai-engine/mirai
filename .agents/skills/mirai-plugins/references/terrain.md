# Current terrain

Three explicit creation options; the representation is not deduced from the collider.

- **Heightfield Terrain**: compact heights (`Heightfield`).
- **3D Terrain**: free mesh (`Mesh`); allows caves without storing density.
- **Volumetric Terrain**: editable field of solid and air (`Volume`).
- All publish immutable meshes per chunk with levels of detail and support painted material
  layers; Heightfield adds holes.

## Entity, source and chunks

Creating a terrain produces identity, transform and `Terrain{source, revision, solid}`, without
`Mesh_Renderer`: the geometry belongs to derived children and their materials belong to the source
([materials](#materials-and-layers)), shared by all its owners. `revision` (read-only) is the
revision shared by the entities of that source and the key of the editor history; it requests no
reloads and after Discard it can differ from the file's.

Fields of `Terrain`:

- **`source`**: id of the canonical `.terrain` asset.
- **`revision`**: revision shared by the entities of that source; read-only.
- **`solid`**: enables the colliders of its chunks.

Chunks:

- `Terrain_Chunk{owner,coord,revision,lod,depth}` identifies each child by owner, coordinate (that
  of its first chunk) and depth in the [quadtree](#quadtree-and-nodes): 0 is a chunk, higher up a
  node that covers 2^depth chunks per side. It says the level its mesh shows with that of its
  sides. It carries no `core.Id`: it is rebuilt on load and is not saved as authoring.
- It has a Parent to the owner and a local transform at the origin of its chunk (`chunk_origin`,
  the lower corner of its cells): its vertices and its collider are in that space
  (`chunk_place`), so a terrain kilometers wide loses no f32 precision far from its center. An
  empty chunk keeps entity and coordinate for later edits while it is
  [resident](#jobs-publishing-and-residency).
- The children show in slot 0 the [layers](#materials-and-layers), with their material and their
  override, and in the other slots of a Mesh its materials (`chunk_materials`); they receive the
  owner's Tint.
- `terrain_update` writes `Terrain_Chunk`, `Material_Override` and, in its chunks, `Mesh_Renderer`,
  `Tint` and `Collider` (`shared` tables); the `Transform` and `Parent` of a new chunk it gives with
  `core.Commands`, because those tables have other writers. Chunks receive Tint and
  `Material_Override` from the owner, except with [layers](#materials-and-layers).
- Reusing or retiring a handle requires the right component, owner, coordinate and Parent, local
  transform and absence of Id; one in another place (another source size) is replaced.
- The sweep of incomplete chunks is triggered by layout changes or `Parent.version`; it keeps its
  stamps and does not walk tables in a stable frame. If a handle became an author, only the
  derived marker is removed.
- Changing `Terrain.source` retires the previous children and takes the resident revision.
- A source is read again when its file's stamp changes in the asset registry (`terrain_stamp`): a
  stroke, an undo, Save, Discard or a recovery.
- Changing `Terrain.source` retires the previous children. Changing representation or distribution
  replaces geometries; a local change keeps the identities of the unaffected chunks.

## Joining a Volume with a Heightfield

`Terrain.ground` of a Volume names the Id of the Heightfield terrain it joins (`join.odin`):

- The Volume owns its box. The pieces of that terrain take the cells under it as holes
  (`Join_Cut`: drawing, collider and picking), without writing into the source; a chunk with taken
  cells stays at level 0 and is not displaced. Nodes have no holes.
- In `JOIN_BAND` samples inside each side of the box (x and z), a chunk of the Volume blends its
  field with the height above the ground (`join_blend`), which at the side is all of it: the
  surface runs over the edges of the Heightfield between its samples. Heights are read live, from
  its pages or from the coarse grid while they are not there; a change of the ground under the box
  or beside it rebuilds the chunks of the strip (the `join` key of each piece). The chunks at the
  sides stay at level 0.
- The Volume stands on the samples of the Heightfield: same cell, no rotation or scale against it,
  its samples over its own in x and z, its box inside it. If not, it does not join and it is
  `terrain.ground_misaligned` (says how much to move it) or `terrain.ground_outside`; an Id that
  is not a Heightfield is `terrain.ground_invalid`, and a ground that leaves above or below the
  sides of the box, `terrain.ground_box`.
- Where one of the two is resident as a chunk, the other is too over those cells
  (`joins_resident`): the hole is not seen without the Volume nor the Volume without the ground.
- `terrain.create` with `kind` volume and `ground` creates it standing on the samples of that
  terrain, centered at `at`, with its cell and the ground at half the box's height, and its field
  filled with the ground (`source_volume_ground`) for digging.
- What a join builds (`Terrain_Chunk.joined`: a chunk with taken cells or of the strip) is not
  replaced by a stroke's preview: the stroke is seen there on confirming, as over a node.

## Canonical format

[Assets](../../mirai-assets/references/formats.md) container, Fourcc `TERR`, one
`terrain:Source_Info` row (type, samples, cell, chunk, revision, layers and materials of its slots)
whose limits `source.odin` validates.

- **Paged grids** (`Grid`, `grid.odin`): Heightfield heights, layer weights and holes in pages of
  `PAGE` samples per side over X/Z; Volume distances and weights in blocks of `BLOCK` samples per
  side in X/Y/Z. Every page has `PAGE_VALUES` values, so reading, copying, releasing and the format
  are one for both shapes. A `<grid>_pages` table gives per page a fill value or the place, size
  and XXH3 hash of its LZ block in `<grid>_blocks`, stored uncompressed: each page is read alone,
  by file range ([residency](#jobs-publishing-and-residency)).
- **Page coding** (`page_code.odin`): before LZ a page goes in byte planes, or, f32 values on
  multiples of `HEIGHT_STEP`, as the zigzag distance in steps from the plane of each sample's
  neighbors left, above and above-left, in byte planes. Saving puts heights on that lattice, at
  most half a step away; a height read from a file is saved again as it is, so edits and saves do
  not drift. Memory keeps what the brushes wrote: a page that leaves memory and the pages the
  network sends keep every value bit for bit. One coding serves the file, those blocks and the
  network.
- **A single-value page stores no values**, in memory, in the file or in copies: an all-air or
  all-solid block past the band. It takes values of its own when a brush or an import writes it,
  and a Volume brush leaves without values the blocks that it leaves with a single value
  (`grid_settle`). A page of the far edge stores only the source's samples there
  (`grid_page_extent`): sources of 2^k+1 samples per side do not pay a page for the last row.
- **Shared pages.** The values of a page and the own block of one that left are held by all the
  grids that copied them, counted in the header of their allocation (`shared_make`); the last one
  to release them frees them with the allocator that made them, which outlives the worlds that
  hold them. Writing a page that another grid holds copies it first (`grid_page_own`, inside
  `grid_prepare`): every writer prepares the region before writing. The coarse grid of a Heightfield
  is another grid of pages and is shared the same way. The geometry of a Mesh section is held by its
  copies with a counter (`Mesh_Hold`) and is never written: an edit puts new geometry in its
  place.
- **Volume**: `f32` distances (`distances`); negative is solid and positive air, limited to
  `SDF_BAND_CELLS` cells, as an approximate distance that does not recompute a global SDF after
  each brush. The initial block keeps an outer layer of air, and the brushes write only interior
  samples. A chunk gathers its samples and its halo from the blocks in a window of the field
  (`Scalar_Grid.first` and `extent`) with the positions of the whole field: neighbors that read
  different windows give the same vertices. A chunk whose blocks are all air or all solid extracts
  nothing.
- **Mesh**: stores neither heights nor density, but canonical indexed sections with their
  attribute tables, material per triangle and slots. The sections form a stable X/Z grid; each
  triangle belongs to a section by its centroid, with real 3D bounds. Sculpting or doing a boolean
  can move triangles between sections without changing identities or the number of chunks; what
  leaves the original distribution goes to an outer section. Sections reside whole: a boolean
  gathers the whole solid.

## Geometry and collision

- **Heightfield**: one vertex per sample and two triangles per cell with the collider's diagonal,
  which is native and keeps heights, spacing, origin, diagonal and holes. Normals consult
  neighbors of the whole source.
- **Volume**: extracts the zero surface with [marching
  tetrahedra](../../mirai-std/references/geom.md#scalar-field-surfaces-isosurfaceodin),
  welds exact positions and uses a Mesh collider; picking intersects the same triangles as the
  builder.
- **Mesh**: publishes each section and uses a Mesh collider; picking discards sections by AABB.
  Import keeps normals, UV0, colors and slots; UV1 is generated from X/Z.
- Colliders suppress flat or concave edges between chunks and keep convex ridges and outer edges;
  UV or material seams do not open the surface.

Levels of detail:

- The level of a Heightfield piece is the coarsest whose error (`Lod_Errors`: the farthest it
  ends up from its samples, measured when reading the source and followed by the edits) covers
  about `LOD_PIXELS` of the view from its terrain, and never finer than samples at
  `LOD_SPACING_PIXELS` pixels, which at a grazing angle come closer (`LOD_GRAZING`): the detail
  between samples that a pixel covers is not seen, however large its error. The pixels come from
  the height and field of the view (`core.View`), with hysteresis. With a positive
  `Terrain_Settings.lod_distance`, and in Mesh and Volume, the level comes from the distance to the
  box; in Heightfield, the distance does not make it coarser than its error allows.
- Two Heightfield chunks that touch, by a side or a corner, are at most one level apart
  (`lod_levels_balance` refines the coarser one): a fine edge stitched to an interior several
  levels coarser folds. In Volume each face is built at the neighbor's level.
- `Chunk_Lod` gives the chunk's level and that of its faces, edges and corners: each takes the
  finest of the chunks that share it, so neighbors build the same over it and no cracks or
  T-junctions open. In Heightfield the border is cut into segments of one chunk and points of the
  chunk grid (`Border_Levels`): each piece that shares it, chunk or node, builds it from those
  levels, without looking at what the others show. Below `COARSE_LEVEL` a border reads the samples,
  and only where both chunks are well within a viewer's reach (their pages are there); if not, the
  [coarse grid](#quadtree-and-nodes).
- The collider is always that of level 0: changing level publishes another mesh with the same
  collision and physics keeps the shape. If a coarse level shows nothing of what collides, the
  chunk shows level 0.
- A level is built when chosen, with the neighbors whose sides change; none is stored.
- **Heightfield**: level k shows one sample out of every 2^k and a strip of triangles stitches
  each side to the interior grid. A vertex's normal comes from the samples at a step of what the
  vertex shares (interior, segment of the side or point of the chunk grid, at the level of its
  border): a coarse level shades the slope that its triangles span and shared vertices have a
  single normal. A chunk with holes stays at level 0.
- **Volume**: level k extracts one sample out of every 2^k (`isosurface` with `Iso_Lod`); a cell
  that touches a finer face or edge is built with conforming tetrahedra. The gradient takes the
  step of what the sample shares.
- **Mesh**: level k simplifies the section to a 4^k-th of its triangles (`geom.simplify` with
  weighted normal and uv and `Lock_Border`). The vertices on the section's border are neither moved
  nor removed: any combination of neighboring levels closes. A vertex of triangles of several
  materials is split into one per material, which the simplifier keeps as a seam: the contour
  between materials is kept, and every vertex is one of the section.

Collision and picking:

- Only chunks collide; a node never does. The nearest chunks collide that fit in the
  `Physics_Settings` slots (`heightfields` or `meshes`, and `shapes`) not occupied by the colliders
  of other entities, and with `Terrain_Settings.collision_distance` only those inside it: physics
  capacity bounds how many, the distance which ones. No distance forces more chunks than physics
  admits.
- Drawing does not depend on the collider: a chunk whose collider finds no slot shows its ground
  without it (`terrain.collider_budget`) and tries again when the colliders change.
- While the world is not playing, every published chunk keeps its triangles on the CPU, also
  without a collider: the editor picks it by them at any distance. In a world that plays only the
  collider keeps them.
- A holed cell has no visible triangles, picking or collision; the physics heightfield receives the
  chunk's mask and its edges next to a hole stay active.

Construction and publishing:

- `chunk_build` is the single builder of preview and runtime. With `collision=false` it gives the
  same geometry without physical halos or masks nor the collision level 0.
- The preview does not replace nodes: a stroke over an area that shows a node is seen on confirming.
- The preview builds each chunk at the level it shows outside the stroke, so it joins those that do
  not change; a hole puts its chunk at level 0 and the neighbors whose side changes enter the
  preview. A Mesh section is previewed at level 0: its fixed border joins it to any neighbor.
- `chunk_publish` uses [generated meshes](../../mirai-core/references/host.md): it creates an
  immutable identity and then frees the previous one; it does not deform the resident mesh or
  refit. At runtime construction runs in jobs and publishing is a transaction with the collider
  ([jobs](#jobs-publishing-and-residency)).

## Materials and layers

- A source has from one to `LAYERS_MAX` layers, in the three representations; there is no
  layerless mode. It is born with one that covers everything: the Selection one with the material
  that slot 0 of the mesh showed. Each `Terrain_Layer` has material, `tiling`, `height_blend` and an
  automatic rule of slope and height (`Layer_Auto`).
- Slot 0 of the chunks shows the layers. The other slots of a Mesh show their materials
  (`Source.slots`, from slot 1), which go in the mesh: changing one rebuilds it. A Heightfield or a
  Volume has no other slots.
- The weights of each sample add up to `WEIGHT_FULL`: over the X/Z grid in Heightfield and Mesh,
  and at each sample of a Volume, which stores in this way what it has under the surface
  ([interior](#volume-interior)). Removing a layer distributes its share among the others in their
  proportions; the last one is not removed. Paint adds a fraction of the brush's layer and Erase
  removes it; the others keep their proportions (`weights_paint`). In a Volume they touch the
  brush's ball, not the column.
- Each vertex takes the painted weights (`source_weights_at`: in Mesh interpolated in X/Z, in
  Volume between the samples of its cell) and then each automatic layer, in order, covers the
  previous according to its rule (`layers_vertex`): a Mesh cave shares the weights of its X/Z
  column and the rules distinguish walls and ceilings. A rule falls linearly along its softness, so
  between two samples it changes at most what their slopes differ over it; in Heightfield it reads
  the slope the same at all levels.
- The weights travel in UV0 and UV1 of the slot 0 vertices; a vertex that shares a triangle of
  another slot is repeated with its own UVs.
- Slot 0 shows the source's layers material (`layers_material`): a Surface program that blends
  them reading their weights in `ctx.uv0` and `ctx.uv1`, and what it needs of the point (world
  position, normal, object). Without one, the standard layers one is a case of the same path:
  `LAYERS_MATERIAL` (`Terrain_Layers` program of `shaders/`) with a `Material_Override` that the
  plugin builds with each layer material. The owner's override does not pass to the chunks, and a
  program of its own takes its parameters from its material.
- `Terrain_Layers` projects the textures from the three axes, each by how much the surface faces
  it, sharpened: flat ground reads only the top one and a cliff those of its sides. A projection
  that barely weighs and a layer without weight are not read, and a ray reads the dominant
  projection. Each projection rotates its normal map over the surface (whiteout) in a frame that
  does not mirror the texture.
- It filters with the point's footprint (`mirai_sample_texture_projected`): the mips are correct in
  raster and in rays. A layer's height is the alpha of its base color, and `height_blend` makes
  the highest texels show where the layers blend. The colors of a Mesh source tint its base color.

### Volume interior

`Source_Info.interior` says which layer is under the surface of a Volume:

- Strata from top to bottom, each down to a depth below the top of its column (the last reaches
  the bottom), with edges that rise and fall (`wave`), and pockets (`Pocket`) or veins (`Vein`) of
  noise between two depths, each over the previous.
- `source_interior_apply` (`terrain.interior` in the editor) writes it into the weights of each
  sample, measuring the depth against the surface of that moment; it is not evaluated when
  drawing. The walls and floor of what is dug show those weights.
- Afterwards the brushes change it: Add, Union and Grow give what they turn solid the brush's layer
  (`Brush.layer`), blended with what the sample had by the part of its cell that was already solid;
  Remove and Subtract leave the weights. Applying the rule again overwrites what was painted
  inside.
- Removing a layer removes its strata and veins. A Heightfield or a Mesh has no interior.

### Texture relief

- In Heightfield, each layer with `displacement` raises the vertices near the view with the height
  of its texture, centered at the middle: that of the alpha of its base color, which
  `Terrain_Layers` blends with `height_blend` and projects the same (`terrain_projection.slang`).
  It is draw-only: the collider, picking and brushes follow the surface of the samples.
- `displacement.odin` does it: the level 0 chunks within `Terrain_Settings.displacement_distance`,
  the nearest ones, are built again with each cell split into `2^displacement_detail` per side
  (`chunk_detail_build`), over the collider's triangles. They are drawn with a deformable copy of
  that mesh, whose vertices the `terrain_displace.comp` Geometry pass writes once: when built, when
  what it reads changes or when the vertex buffer is rebuilt.
- Two displaced chunks build the side they share at the step of their cells; a side with a chunk
  that is not displaced keeps the samples, stitched to the interior grid with the strip of
  `piece_build`, and the relief turns off within a cell of it. A chunk is shown displaced only
  while each side matches the neighbor's: while one is rebuilt, the other shows its common mesh.

## Mesh authoring

- `source_from_mesh` copies a validated mesh and creates sections; it completes normals (before
  splitting it), UV0 by X/Z projection, colors and slot 0 if missing.
- `source_convert_heightfield(dst,src,depth)` converts heights explicitly: `depth=0` leaves an open
  surface and `depth>0` adds walls and a base under the minimum height, forming a closed solid. The
  base uses a fan per chunk whose triangles stay inside the chunk, and top and walls keep their
  resolution. It admits `dst=src` and replaces the destination only after preparing the new
  source. It keeps layers and weights; holed cells do not pass, and with holes `depth>0` fails.
- `source_convert_volume(dst,src)` gives the surface of a Volume (level 0 of its chunks, welded) as
  a Mesh source, without its field: the static shape of what was dug. It keeps layers and, at each
  sample of the Mesh, the Volume's weights at the top of that column; it admits `dst=src`.
- Operations (`Brush`): Raise and Lower displace along the normal, Smooth and Flatten approach the
  average or a plane, Refine splits long edges inside the sphere, Union and Subtract operate with
  the closed brush shape (sphere, capsule or box), Grab displaces the original zone of an
  immutable initial source (returning to zero delta restores it) and Grow moves the tip with a
  rigid central zone and subdivides the local edges. Ramp is Heightfield only.
- The brushes select sections by bounds plus a halo for neighbors, normals and shared edges, and
  reuse their buffers. Kernels: [surface
  editing](../../mirai-std/references/geom.md#surface-editing-surface_editodin) and [solid
  booleans](../../mirai-std/references/geom.md#solid-booleans-booleanodin).
- `source_mesh_boolean(s,operand,op,vertex_budget)` is a transaction over the whole solid: it
  gathers sections, runs the boolean, redistributes them and publishes only the changed ones and
  their halo. It requires closed, valid solids (an open surface is closed explicitly) and that the
  operand's materials be slots of the source. It does not convert to SDF.
- A Mesh failure (`Change.error`) keeps the canonical data; `Change.changed` can be false without
  an error if there was no effect. `source_edit` does not increment `revision`: whoever confirms
  the transaction does.

## Tool

T or its entry in the Tools menu, outside Play.

- Without a selected terrain, the panel offers **Terrains** (those of the scene) and **Create**;
  with one, only its modes. The brush only sculpts a selected terrain: a click on another selects
  it. Picking on a child leads to the owner and, if the picker finds nothing, the brush tries
  `source_ray` of the selected terrain.
- **Create**: Plane or Heightmap for Heightfield and 3D Terrain, and Selection for 3D Terrain. 3D
  Terrain cooks Plane and Heightmap directly as Mesh, with Base depth as the conversion's `depth`.
  Heightmap (16-bit PNG with its precision, TGA and BMP) normalizes integers to [0,1] without gamma
  and scales and offsets the height; its first row is the start of Z. Selection converts the
  selected `Mesh_Renderer` keeping entity and transform: the materials it showed pass to the slots
  and its mesh, its collider and its static body are removed (it rejects other bodies). Volumetric
  Terrain starts with a solid block surrounded by air. Plane shows the size in meters and in
  chunks, and the view draws its outline where it will be born.
- The new file (`terrain/<type>.terrain`) exists only in the registry's memory until Save and is
  part of the undo step: undoing it removes it even if later strokes changed it.
- **Convert to open mesh** and **Convert to solid mesh** (Sculpt) convert a Heightfield explicitly
  and reversibly with undo, with its owner selected; the solid asks to fill the holes first.
  **Convert to mesh** (Sculpt of a Volume) converts it into 3D Terrain.
- **Heightmap** (Sculpt of a Heightfield): Import sets the heights of an image, scaled and offset
  as in Create (one of another size gives it its size, with its layers and without what was
  painted or the holes); Export writes its heights into a 16-bit PNG from lowest to highest and
  leaves in the fields the scale and offset that import it back. **Size** gives it other samples
  around its center (each side changes by an even number, so the center remains a sample): what it
  had stays in place and what grows takes the heights and weights of the nearest edge
  (`source_resize`). Each one is an undo step.
- Everything of the tool is in its panel, from top to bottom: mode, brushes with their key, radius,
  strength, pen pressure, falloff, shape (alpha) and what is specific to the brush, and at the foot
  the **Entity** section with the entity's details, which the panel covers. **Sculpt** offers the
  representation's brushes, with the same names in all three (Set height is Flatten to a typed
  height, which the crosshair button or Ctrl and a click take under the pointer); **Shapes** (Mesh
  and Volume), the shapes; **Paint**, the materials of the slots of a Mesh after 0, the list of
  layers with that of the chosen one below and the brush, which adds or takes the layer to a
  weight (**Up to a weight**). Remove is disabled with a single layer. The material that blends the
  layers (**Blend**) appears only when it is not the plugin's (an import sets it). **Holes**
  (Heightfield), Hole and Fill per cell. Each material or layer change is an undo step.
- Radius, strength, falloff, hardness, pressure, alpha and slope filter belong to each mode
  (Sculpt, Holes, Shapes, Paint) and, with the values of the brushes and of Create, are stored in
  the editor [preferences](../../mirai-editor/references/editor.md) (`Terrain_Tool`).
- Heightfield brushes besides those of the representation: **Terrace** flattens toward steps of
  Step meters from the height of the press, which rise in their Riser part; **Noise** adds value
  noise of Scale meters, the same at each point for its source, so each pass deepens a pattern
  (also in Volume); **Erode** releases drops on the disc that run down the surface carrying soil
  and leave it where they slow down (`erode.odin`), and its effect fades out past the disc. **Way**
  (Both, Raise, Lower) lets Smooth, Flatten, Terrace and Noise only raise or only lower; **To the
  press** (or Alt) makes Raise only lift what is below the height of the press, up to it, and
  Lower only lower what is above it.
- **Slope filter** (Heightfield, in Sculpt, Holes and Paint): the brush touches only where the
  slope, measured on the surface from before the touch, is in the range, or outside it. **Shape**
  chooses an alpha from those of Terrain3D (`alphas/`, 16-bit PNGs embedded in the editor) that
  multiplies the falloff within the disc, with its rotation, fixed or random at each touch; Holes
  cuts where it is worth half or more.
- Keys while the tool is active (it takes them from the editor shortcuts with `tool_keys`):
  numbers choose the mode's brush and with Shift the mode, `[` and `]` change the radius, F drags
  the radius over the ground and Shift F the strength (with Ctrl, ten times finer; click, Enter or
  F confirm; Escape or the right button go back to the previous one: `editor.brush_adjust_*`, the
  same as foliage's). Ctrl, or the eraser tip of a pen, inverts the brush (Raise and Lower, Add
  and Remove, Paint and Erase, Hole and Fill, Add and Carve), Shift sculpts with Smooth and Alt
  stops Raise and Lower at the height of the press. With a pen, pressure multiplies the strength of
  the brushes that have it on.
- A stroke touches on pressing and, while held, up to `BRUSH_RATE` times per second with the
  accumulated time, like TerraBrush: still, it keeps acting. Each touch falls under the pointer on
  the surface from before the stroke, like Blender, carried along its normal to the current one;
  with the pointer still, at the point of the previous touch carried the same way. So what was
  raised does not push the brush toward the view. A fast drag also touches between two touches,
  every `STROKE_SPACING` of the radius, and they share the time; the cursor is drawn where the
  touch falls.
- Strength goes from 0 to 1 and says what a pass does (`PASSES_PER_SECOND` per second): Raise and
  Lower lift a part of the radius (`RAISE_PER_PASS`) and what interpolates covers that part of the
  way. The falloff (`geom.Falloff`) and the hardness apply to what fades toward the radius; Volume
  Add and Remove are the union with a sphere centered on the surface, and they converge.
- Flatten stores the press plane: its height in Heightfield and Volume; in Mesh, that of Plane
  (the surface, or the view).
- **Ramp** (Heightfield) and the **Shapes** shapes are placed with a drag and remain pending: the
  preview shows them over the source from before and their ends move with handles (those of the
  ramp over the surface, those of a shape over the view plane); the radius and falloff, the height
  of each end of the ramp and the blend are changed in the panel. Enter or Apply applies them as
  one undo step, Escape removes them and a click outside the handles or changing mode applies the
  pending one. A Mesh boolean runs on applying; Heightfield and Volume show it while it is
  adjusted. Refine is applied once per click.
- **Grab** and **Grow** capture point, radius and view plane on pressing and project the cursor on
  that plane until release (with an optional local axis). They depend on displacement, not on time.
  Grab always computes from the initial snapshot. Mesh Grow advances in steps bounded by Radius and
  Edge length, orients the tip by a delayed point of the trajectory and processes at most
  `GROW_STEPS_PER_FRAME` steps per frame; its subdivision is conforming and bounded, without
  remeshing or merging: joining solids requires a boolean. Volume Grow adds a capsule between the
  previous point and the current one.
- **Apply and consume selected mesh** does a boolean with a closed `Mesh_Renderer`, leaf and outside
  a locked prefab, transformed to the terrain's space (also under negative scale). Union reuses the
  slot with the same material (that of slot 0 joins the layers); Subtract gives the cut faces slot
  0. It consumes the entity and the same undo step restores source, operand, components and
  selection.

Preview and confirmation:

- During the stroke a copy and its temporary chunks change, which replace the surface of all the
  owners of the source. File, scene and revision stay intact until confirming; Escape, deactivating
  the tool or entering Play discard preview and copy. The chunks that a change touches are built in
  parallel in `std/jobs`, with the geometry the renderer takes, and the frame publishes them in
  order. A failure when building a preview keeps its pending mark to retry. Escape gives back what
  the stroke changed from the head, without reading the file.
- Where the brush is, the editor writes `Terrain_Focus` (its sole writer): the runtime shows as
  chunks, not as the nodes that cover them, the chunks of that source under the ring and one chunk
  around, so the preview, which replaces chunks, is seen also far away. While a stroke is held it
  also carries the region that changed, for the [foliage](foliage.md#ground).
- Creating, converting and confirming check the budgets of sources and of samples or vertices,
  discounting the replaced source, and that of chunks of a Volume without streaming; Mesh editing
  receives the vertex one before changing its data. The pieces and colliders of a Heightfield or a
  Mesh are arranged by the runtime ([quadtree](#quadtree-and-nodes)). It reserves no GPU resources,
  bodies or shapes.
- **History** (`terrain_history.odin`): for each source it edited, the tool stores its head, what
  the file has at the owners' revision (a copy without scratch, made on the first stroke). A step
  between two revisions stores what the source had at the revision in which the head is not, only
  where they differ: pages of a Heightfield's grids (those of the region the stroke touched),
  blocks of a Volume's values, info and materials, or the whole source when its type or size
  changes and in a Mesh. Undo and redo swap the step with the head, without copying, and the source
  that the tool edits follows the head without reading the file. The chain of revisions is that of
  the [editor](../../mirai-editor/references/extensions.md#a-viewport-tool).
- Cancelling occupies or displaces no history entries. Confirming builds the step (the copies
  before touching the head), writes the head into the registry's memory (`editor.file_set`,
  outside the history) and only afterwards publishes the step, the revisions and the removal of the
  operand in the undo step. If building or writing fails, the head goes back to what it was and
  scene, confirmed file and history, including redo, remain.
- The head stores the LZ block of each page it wrote with the hash of its values
  (`source_bytes(...,keep=true)`): writing the file again only compresses the pages that changed.
- The undo step stores the owners' revisions, not the file. `terrain_sync` takes the head to the
  revision restored by the steps and writes it in memory; if it is what the disk has, it stops
  being unsaved.
- If the file changes without the revision changing: with an undo or redo in between, the file
  takes the head; if not, it changed outside the tool (Save, Discard, a recovery), the revision
  has what the file has and the step that leads to it stores, of what changed, that of the previous
  revision (`steps_rebase`): undo returns to it and redo does not bring back what was discarded.
- On opening the document, the revision resolved from the file enters the initial base with
  `edits_sync_initial`, once per initial stamp: the first undo keeps the loaded source even if the
  saved scene had an earlier revision. Preview contract:
  [extensions](../../mirai-editor/references/extensions.md).

Inspection modes (`terrain_view.odin`, in Advanced → Terrain): `contours` (Contour lines),
`contours_height` (the same lines colored by height) and `slope` (Slope), the Terrain3D overlays:
their angles and colors, and their curves at a tenth of their heights, because theirs are for
worlds kilometers wide. `terrain_view.comp` draws them in the `Inspect` stage over every surface of
the view, terrain or not, to also see whether a ramp or a mesh is walkable. The world height and
what changes from one pixel to the next come from the linear depth of the pixel and its neighbors.
The slope reads the smooth normal of the G-buffer, as Terrain3D reads that of its vertices (with
the material's normal maps), and the curves recognize a flat surface by the triangle that the
neighbors give. The `Inspect` image arrives without exposure: the pass exposes it and passes it
through a filmic curve, near Lit; the lines go in their color, unlit. The pipeline is requested only
while one of the modes is shown
([plugin modes](../../mirai-editor/references/extensions.md#an-inspection-mode)).

Over Lit, with no pass of their own: `layer_weights` (Layer weights) and `selected_layer` (Selected
layer) show the chunks of the terrains with the `Terrain_Weights` material
(`assets/terrain_weights.mat`) instead of their own, as instances that replace them: one color per
layer, or the layer chosen in Paint from black to white, with the automatic rules included; the
preview of a stroke too. `chunks` (Chunks and levels) draws the outline of each piece over its
ground in the color of the level it shows, a coarser node one.

## API

`terrain.create`, `terrain.edit`, `terrain.layer`, `terrain.interior`, `terrain.sample`,
`terrain.heightmap` and `terrain.resize` (`terrain_api.odin`) do what the panel does in the edited
world on the entity they name (no selection needed), each change an unsaved undo step like a
stroke. `terrain.create` takes a `name` for its entity and file, beside the scene. A content tool
writes a terrain and its entity with `terrain.builder_terrain` (`builder.odin`), in one pass with
the scene. A layer is named by its material
(`asset.slot_named`: the path or stem, `default` with no material, `#2` for the second of the same). A Volume's interior is edited in Paint,
under its layers: its rows hold what is changed until Apply. `terrain.edit` is a stroke of a brush
by its name from `at` to `to`, touching every quarter of the radius with what a pass does; a ramp
or a shape is a touch from `at` to `to`. A brush that the representation does not have, a layer
that does not exist, removing the only layer or an alpha that is not there answer what they take;
an error of the operation, that of the panel. While a game of the caller runs, `terrain.edit` and
`terrain.layer` are requests of that game (`terrain.dig`, `request_layer`) that it applies on its
next tick, without undo: an alpha-less stroke whose touches fit in a tick's queue.

## Editing during play

- `terrain_update` writes the resident sources and consumes the requests before physics in Fixed;
  the editor also loads and publishes in Frame.
- `terrain.dig(requests,Brush,owner)` asks for an edit, in the world: `terrain_replay` and
  `terrain_update` resolve the owner first (given, or the terrain the brush touches: the nearest
  to the center, then the smallest footprint) and hand the brush on in its space, so networking
  keys edits by that owner. Request procs return nothing; `terrain_requests_serve` keeps the room
  of `Terrain_Settings.requests` and reports what was dropped or refused. `Brush.amount` is a
  delta in meters for Raise and Lower and a fraction for
  what interpolates (for continuous response, `1−exp(−strength*dt)`); Refine and the booleans
  require a positive amount and Hole and Fill do not read it. `falloff` and `hardness` give the
  falloff; Smooth averages the neighbors of a box that grows with the radius (`SMOOTH_REACH`).
  Paint and Erase work in the three representations; Hole, Fill and Ramp (from center to
  center+delta, at the heights of its ends), only in Heightfield. Volume Union and Subtract join or
  remove the shape with `blend`. Terrace (`interval`, `riser` from `target`) and Erode are
  Heightfield, Noise (`scale`, `seed`) Heightfield and Volume; `way`, `capped`, `slope` and
  `toward` (Paint toward `target`) are read as in the tool. The queue rejects a `Brush.alpha`: it
  points to memory that it does not keep. `request_layer` and `request_layer_remove` change the
  layers.
- Grow uses center and delta as the ends of the stretch and in Mesh requires `max_edge`; the
  runtime must subdivide long displacements like the tool. Grab needs
  `source_edit(...,baseline=&initial)` with an independent initial source, so the request queue
  rejects it.
- A request that fails is a `terrain.*` [problem](../../mirai-core/references/core.md#problems)
  of the entity it names, with the source's path and how to fix it; what does not load, does not
  fit or is not built is a problem of the first terrain that shows it.
- Sources are read through the host (`terrain_read`, over `host.assets_file`): Play, the preview
  and reload see what the registry has unsaved. The stamps are compared only when the registry's
  revision changes. The game does not write files per brush: `request_save` asks for an explicit
  save.
- `Terrain_Data` copies the sources for Play and snapshots sharing their pages, and a copy onto a
  destination that already has its tables does not allocate; its copy and its `swap` raise `epoch`
  so that `Terrain_Resident` rebuilds. Clearing the world takes it to its start; `Terrain_Settings`
  is a project setting and clearing the world does not touch it.
- `Terrain_Resident` (`host,by_world`) stores the derived meshes of each world, which are not
  rebuilt when another world runs in the same frame; `terrain_release` frees them with that world.
  Physics retains geometries for its snapshots; editor and Play share no mutable arrays.
- `Terrain_Settings` limits sources, shown pieces and resident samples (Heightfield counts those of
  its pages in memory and its coarse grid, Volume those of its blocks with values, Mesh its
  vertices); Mesh checks the budget before swapping geometry. A source loads if its samples fit:
  the pieces are arranged when shown ([quadtree](#quadtree-and-nodes)). Its distances are read on
  each frame.
- A stable frame reads no files, does no meshing, rewrites no tables and does not allocate.
  Loading, editing, copying and saving are transactions.
- No collapses or navigation regeneration. Edits in a network session: [network](#network).

## What digging leaves

`Terrain_Digs` (a world event that `terrain_replay` empties on each tick of a world that plays)
says what each `terrain.dig` edit or replica removed: the center in the world, a reach, the volume
and the cubic meters and material of each layer. In a Volume it is the part of each sample's cell
that stopped being solid, with its weights; in a Heightfield, the height that went down per cell,
with the weights of its column. `terrain` stores none of that: the game uses it (an inventory,
points) and these plugins:

- **Dust:** the automatic bridge `terrain_vfx` (`terrain` and `vfx`). `Terrain_Dust` on the terrain
  gives per layer a [`vfx`](vfx.md#channels) channel (`CHANNEL_DUST` or another, for another
  effect) and its color, and births per cubic meter with a cap per edit. An emitter with a
  `Particle_Channel` of that channel shows it.
- **Pieces and drops:** the `terrain_debris` plugin. `Terrain_Debris` gives per layer a piece
  prefab (with `Rigid_Body`, of the layer's material, which leaves with `speed`) and a drop one,
  each per so many cubic meters removed; what does not reach is owed to the next edit of that
  terrain (`Debris_Owed`), with a cap per tick for each.
- Both are configured in the inspector and by `scene.set`; the demo builds them in the `dig` scene.

## Network

`terrain` does not know the network: another library orders the edits with `Terrain_Replays` and
reads how they came out in `Terrain_Replay_Events` (`network.odin`). The automatic bridge
`terrain_multiplayer`, active with `terrain` and `multiplayer`, carries them from one end to the
other; authority, prediction and rollback for the rest belong to the
[multiplayer contract](../../mirai-networking/references/multiplayer.md).

- **A routed tick** (`Terrain_Replays.routed`, which the bridge requests on each tick of a session)
  applies in `terrain_replay`, before `terrain_update`, the replicas in their order (a brush, a
  layer change, a whole page of a grid, a whole section of a Mesh or the head of a base) and then
  the `terrain.dig` and `request_layer` requests, which `terrain_update` no longer sees. Each
  result says its error, the region that changed and its check: the hash of the values of all the
  grids in that region (of a Mesh's sections and its weights around them), or of the layers of a
  layer change, whose region is the whole source. What `terrain_replay` applies does not move
  `Source.revision`.
- **The server decides.** It applies what its game asks and what a client asks
  (`Net_Terrain_Ask`), and sends each edit and each layer change to all (`Net_Terrain_Edit`),
  numbered per source, with its tick, its region and its check. A client's request waits for the
  tick at which the client made it. What is not allowed comes back as `Net_Terrain_Refused` with
  the cause (rate, connection without a seat, reach from what its seat drives, radius, brush, tick,
  unloaded source or the edit's error), which the client reports as the `terrain.net_refused`
  problem with how to fix it. `Terrain_Net_Settings` (project setting) sets the rate, the reach and
  the radius.
- **What the game asks of a client is a prediction:** an edit is applied at its tick, stored with
  its check and asked of the server. When the server's edit comes back, a prediction that left the
  same check stays as that edit, without repeating the brush. A layer change is not predicted
  (`Terrain_Replays.asked`): it is asked and applied when it comes back, in the server's order. A
  game asks for an edit at the end that decides it (`core.owned`), not at both.
- **The client follows the server's order** per source, edits and parts, from where
  `Terrain_Net_World` says, which is part of the `World`: a correction that comes back earlier finds
  the source as it was and applies each element again at the tick at which it first applied it, and
  the game repeats its predictions. What arrives out of order waits for its turn; a lasting gap
  asks for a base.
- **An edit by someone else** over a pending prediction, from an already simulated tick, asks to go
  back to that tick (`multiplayer.rewind`) to end up in the server's order; if it cannot, or it
  touches no prediction, it is applied in the present.
- **No bit-for-bit equality.** A different check (another order, another architecture), a
  prediction that was rejected or never came back asks for the parts of that region
  (`Net_Terrain_Resync`): the pages of its grids and the sections of a Mesh. The server sends them
  whole, in LZ and in chunks, with a byte budget per tick that a long part spreads over ticks, and
  the client writes each one in the place of the order where it started arriving: what follows
  waits for it.
- **A source knows where it came from:** `Source.origin` is the hash of the contents of the file it
  was read from (or saved to, which becomes it), and each page and section says whether it was
  written since then (`altered`); a copy carries it.
- **One base for each source that the client loads, or cannot read,** is asked for by it with its
  origin if it wrote nothing since its file or what was written came from the server; if not,
  without origin. The server sends the base's head, which stands for all the earlier edits (shape,
  layers and materials), and the parts that it wrote since that origin, even before opening the
  session, not its history. With another origin, or none, it sends all: the client's source starts
  again from that shape, or is created if it did not have it. It only sends to the connections that
  entered its world. The base ends with a mark: what differs on the client up to it is not asked
  for, because the base brings it.
- A player launched over the network prints the base that arrives, a region that differs and on
  exit how many edits left another check; the server, the parts it sends to each connection. In
  the editor it goes to the log.
- `Terrain_Digs` comes out at each end where an edit is applied: the client's prediction and the
  edits of others that reach it. The dust belongs to each end; a game counts what was dug and
  `terrain_debris` makes pieces and drops only where `core.Network` is not a client, and a prefab
  with `Replicate` reaches the clients. `request_save` does not travel.
- What the bridge knows of the network (`Terrain_Net`) belongs to each world, outside it, and is
  forgotten with a scene that replaces it.

## Jobs, publishing and residency

Construction in jobs:

- `chunk_build` runs in `std/jobs` (`work.odin`), in `Terrain_Data` slots that travel with their
  sources when the world is swapped, and builds also what the renderer takes from the chunk:
  publishing it only gives it its materials and registers it. A job reads the live source: what
  changes or frees it (a request, a new read, saving, removing it and the `copy`, `free` and
  `reset` hooks) first waits for the jobs that read it. A page shared with another world is copied
  on writing it, so its jobs keep reading the one they had.
- Each job stores the data's epoch, the source, the chunk, the key (level and collider) and the
  source change it read (`Data_Source.change`); a result whose chunk changed while it ran is
  dropped and built again.
- A result is published in the next `terrain_update` call of the phase that asked for it, which
  waits for it if it did not finish: when it is seen does not depend on the threads, and a tick
  that edits shows the new chunk in the next one, with the previous version in between.
- A piece that shows nothing and is needed is built and published in the same call: a chunk
  without residency or with a viewer very close, a node where its terrain shows nothing, and what
  prevents opening the node that is shown over a chunk next to a viewer (its siblings and the nodes
  that replace it in the meantime). Loading a scene, Play, a rollback or a teleport do not leave a
  tick without ground under a viewer. Those jobs can use all the slots; the others, half.
- Changing level, border or collider publishes the piece and the neighbors whose sides change in
  the same call.
- A source is read whole in a job (`data_load_begin`): its file, its coarse grid and what its
  chunks and nodes reach, in memory of its own (`Data_Source.allocator`), and `data_load_end` adds
  it to the sources. Those that a section's load names are requested while it waits for the
  libraries and make it wait (`scene.Load_Waits`): the section joins with its ground ready. One
  that nobody waited for (the scene that opens, the one the editor adds) is read in the call that
  sees it. A source that a load waits for is not released even if no terrain shows it yet, and
  one that could not be read does not make anyone wait until the registry changes.
- In a frame, residency (what each terrain wants, what is urgent and what is published) is chosen
  in the calls of the fixed phase and, if there was none, in that of the frame: the one in the
  frame phase after a tick has nothing new.
- A published chunk shows its mesh with its collider if the owner is solid, wants it and a slot
  remains ([collision](#geometry-and-collision)).

## Quadtree and nodes

A Heightfield or Mesh source has a quadtree over its chunks (`quad.odin`): four chunks have a
parent that covers the same, and so on up to one root per source, even of a single chunk.
`Terrain` is `@(component,far)`: when its section is not loaded the terrain is left without
colliders (`Resident_Owner.far`, with `scene.Far_Kept`: it chooses its pieces as a solid one, but
none carries a collider or is urgent, they are built in jobs), and far from the sources it shows
its nodes ([what is unloaded](../../mirai-gameplay/references/libraries.md#scene-references)).
Volume has no nodes. A node where nothing is shown is urgent only near a viewer (`URGENT_REACH`);
farther away it waits for its job. While there are pieces to build, residency is chosen again once
per frame (in the first call); what the data changes, in each call.

- Each terrain (owner) chooses which pieces it wants: from the root, it opens the nodes under which
  it needs a chunk, or whose finest level is still coarse for the view. It needs as a chunk what is
  near a viewer if it has streaming; if not, being solid, what carries a collider (the nearest
  ones that fit in `Physics_Settings`, within `collision_distance`). It opens the nearest first
  (reach and distance) as long as the pieces of all the terrains fit in `Terrain_Settings.chunks`:
  past that, the far field shows coarser nodes and nothing is hidden. Roots always count; if they
  alone do not fit it is `terrain.chunks_full`. Volume keeps its nearest chunks and the rest is
  `terrain.chunks_full`.
- What a terrain shows follows what it wants as it is built: a region keeps what it showed until
  everything that replaces it is there, and a built node replaces in the meantime what is missing
  under it. Nothing is left twice or missing once covered.
- Each terrain builds its pieces (`Resident_Source` per owner), at the levels and borders its view
  asks for; the source's data are one. With streaming it keeps its root and the nodes it opens
  built.
- A Heightfield node is assembled from the coarse grid (`coarse.odin`): heights and layer weights
  every `COARSE` samples and in the last row and column, in memory while the source is there, with
  a bilinear between them. Reading the source fills it reading each page once, by rows of chunks in
  jobs (and the chunks of each row too); edits and layers follow it. Its interior level is at least
  its depth and `COARSE_LEVEL`, and the layer rule reads the slope of the coarse grid. A node shows
  no holes.
- A Mesh node simplifies the sections it covers (`chunk_mesh_simplify`) to a quarter of their
  triangles per depth, with the outer border fixed: it closes with any neighbor.
- A node has no collider; it keeps its triangles for picking while the world is not playing.
- The distance of an unbuilt piece uses the heights of its samples (`Data_Source.ranges`, from
  reading the source and from edits), not a 0.

Residency by distance:

- With a positive `Terrain_Settings.resident_distance`, a chunk is resident (mesh, collider, entity
  and pages) if a viewer of some terrain that shows it is at that distance from its box; it stops
  being so past `RESIDENT_KEEP` times, and a node covers it. At zero, the far field is also nodes,
  and chunks are those that carry a collider.
- Viewers: the world's [streaming
  sources](../../mirai-gameplay/references/libraries.md#scene-references)
  (`scene.Streaming_Sources`: the view while it draws, the bodies of the seats and the entities
  with `Streaming_Source`), each one where it is and where its movement takes it, with its
  `distance` (zero: `resident_distance`). A teleport puts a `Streaming_Source` at the destination
  before moving the player.
- A Heightfield or a Volume read from disk (`terrain_read(...,paged=true)` over
  `asset_load_front`) leaves its pages in the file and reads them in jobs, by range, when a
  resident chunk needs them with the halo that its construction and its collider read
  (`chunk_pages_region`; in Volume, the gradients of its coarsest level); it releases them when
  none reads them and no job reads the source. A page with edits is first stored in an LZ block of
  its own and comes back with them: unloading and reloading a dug zone keeps the changes. A node
  whose border reads samples waits for the pages of that border. A Volume's weights come and go
  with its distances, block by block.
- The residency of the pages is that of the chunks, which is the shared one of `scene`: the terrain
  has none of its own. A Volume's chunks are not roots: far from every viewer they are released,
  and their blocks with them.
- A brush first reads, in the tick, the pages it touches, and removing a layer all those of its
  weights. Save writes each page, those in memory and those in their blocks.
- A source that only has the registry's memory (unsaved in the editor) is read whole. Mesh resides
  whole: its chunks are released by distance, its data are not.
- A world copy (Play, snapshot, rollback) shares the pages in memory, the own blocks, the coarse
  grid and the Mesh sections; a uniform page is its value and the others stay in the file. A series
  of snapshots retains only the pages and sections that changed within it, and releases them on
  leaving the window. An editor history step stores only the pages and blocks it changed. What a
  copy retains is not released with the original. Reading the file again keeps in memory the pages
  whose block stores the same (by hash) and marks only the others.

Reading from other plugins (such as the foliage bridge), with `core.Ref(Terrain_Data)`:

- `terrain_source(data,id)`: the source, to read without writing it; `chunk_counts`, `chunk_index`
  and `chunk_box` give its chunk grid and the local box of each one.
- `terrain_height(data,id,x,z) -> (height,ok)` and `source_height_held(s,x,z)`: the local height
  of a Heightfield over the collider's triangles; `ok=false` for another type, outside the source
  or where its pages are not in memory (no resident chunk nearby). `source_ray` ends at the first
  cell without pages.
- `terrain_change(data,id)` and `terrain_changed(data,id,since) -> (low,high,changed)`: the change
  of a source's data and the local box of the chunks that changed after `since`;
  `terrain_data_change(data)` changes with that of any source. A page that arrives in memory marks
  the chunks that read it (what can be read changed); releasing it marks nothing.

## Limits in open worlds

- **Mesh** stores whole sections: its chunks are unloaded and its data are not, and its sections
  are not a 3D partition that loads deep caves apart. A source that is only in the registry's
  memory (unsaved) is read whole.
- **Volume** is limited to `VOLUME_SAMPLES_MAX` per axis and has no far nodes.
- **Joining a Volume with a Heightfield:** a Volume rotated against the ground does not join
  (`terrain.ground_misaligned`); several Volumes that overlap over a Heightfield are not
  supported; the excavation seen from far away is not seen, because the Heightfield shows nodes
  without holes and the Volume has no nodes.

## Verification

What a content tool writes: `a_content_tool_writes_a_terrain_and_its_entity_in_one_pass`
(`plugins/terrain/runtime`).

Runtime: `mirai test plugins/terrain/runtime` (CPU); `--release` only if a failure may depend on optimization. It covers
persistence, clones, validation, memory, halo, raycast, masks, immutable publishing, empty chunks,
physics, saving, stability and world copy.

- `chunk_visual_build_preserves_geometry_and_reuses_collision_buffers_for_all_sources`,
  `mesh_terrain_solid_base_fans_stay_local_and_close_partial_chunks`,
  `mesh_terrain_solid_conversion_allocation_failures_preserve_source_and_destination`,
  `bounded_volume_brushes_preserve_air_margin_and_can_remove_and_restore_all_material` and the
  `mesh_terrain_*` cases.
- Recycled handles, relinked sources and incomplete chunks: authors are not confused with derived
  children nor left orphaned.
- `drag_test.odin` (Grab, Grow, atomic budget and memory), `layers_test.odin`, `holes_test.odin`,
  `shading_test.odin` and `shape_test.odin` (falloff, wide Smooth, ramp and shapes in Volume and
  Mesh).
- `displaced_chunks_split_their_cells_on_the_collider_and_join_their_neighbors`: the relief
  subdivides over the collider, stitches the sides and respects the holes; its image needs a GPU
  capture.
- Levels: `chunks_of_mixed_levels_join_without_cracks_or_overlaps`,
  `far_chunks_show_coarser_levels_while_colliders_keep_every_sample`,
  `mesh_sections_of_mixed_levels_join_without_cracks_or_overlaps`,
  `volume_chunks_of_mixed_levels_join_closed_without_cracks`,
  `coarse_mesh_and_volume_levels_carry_the_weights_of_their_vertices` and
  `far_mesh_and_volume_chunks_show_coarser_levels_and_collide_at_level_0`. `bench_terrain_levels`
  (`-define:TERRAIN_BENCH=true`) measures each level.
- `terrains_that_cannot_load_or_be_edited_report_their_entity_and_the_fix`.
- Brushes (`brush_options_test.odin`):
  `capped_raise_and_lower_stop_at_the_height_of_the_press`,
  `a_way_keeps_flatten_raising_or_lowering_only`,
  `terraces_level_each_step_and_rise_over_their_riser`,
  `noise_is_the_same_pattern_at_a_point_and_passes_deepen_it`,
  `erosion_carries_ground_down_a_slope_into_a_basin_and_stays_near_the_disc`,
  `the_slope_filter_and_an_alpha_choose_what_a_brush_touches`,
  `paint_toward_a_target_stops_at_its_weight` and
  `a_resized_heightfield_keeps_its_ground_in_place_and_grows_from_its_edges`.
- Volume blocks (`blocks_test.odin`):
  `volume_blocks_all_air_or_all_solid_hold_no_values_through_brushes_and_the_file`,
  `volume_files_of_another_version_or_with_distances_past_the_band_are_refused`,
  `a_volume_read_by_pages_holds_only_the_blocks_it_reads_and_a_block_that_leaves_keeps_its_edits`
  and `volume_snapshots_hold_only_their_blocks_and_give_back_each_stroke`.
  `bench_terrain_volume_memory` (`-define:TERRAIN_BENCH=true`).
- Page coding (`page_code_test.odin`):
  `coded_pages_keep_heights_within_half_a_step_and_other_values_exactly` and
  `saved_heights_stay_where_the_file_put_them_through_edits_and_saves`.
- Join (`join_test.odin`):
  `a_joined_volume_meets_the_ground_on_the_sides_of_its_box_without_a_seam` and
  `a_volume_that_joins_a_heightfield_takes_its_cells_and_digs_under_them`.
- `the_interior_of_a_volume_shows_where_it_is_dug_and_what_fills_keeps_its_layer`,
  `lowering_a_heightfield_counts_the_height_it_takes_by_layer` and, in
  `volume_runtime_keeps_empty_chunk_identity_and_updates_collision_when_material_appears_or_disappears`,
  the event of what a game edit removed.
- `a_dug_volume_becomes_a_mesh_of_its_surface_with_its_layers_and_no_field` and
  `chunks_without_a_collider_keep_their_triangles_on_the_cpu_only_while_the_world_does_not_play`.
- `pipeline_test.odin`:
  `rebuilt_chunks_show_in_the_next_tick_whatever_the_threads_and_stale_results_are_let_go`,
  `chunks_without_a_slot_for_their_collider_still_show_their_ground_and_the_nearest_collide`,
  `letting_go_of_an_excavated_zone_and_reading_it_again_keeps_its_edits`,
  `a_volume_lets_go_of_the_blocks_far_from_its_viewers_and_reading_them_again_keeps_its_edits`,
  `reading_a_paged_source_again_keeps_the_pages_its_file_still_holds` and
  `streamed_terrains_keep_the_nearest_chunks_within_their_budget`.
  `bench_terrain_update_while_a_brush_edits` (`-define:MIRAI_BENCH=true`).
- Quadtree: `quad_test.odin`
  (`quadtree_nodes_and_chunks_of_mixed_levels_join_without_cracks_or_overlaps`,
  `a_mesh_node_keeps_the_outer_border_of_its_sections_with_fewer_triangles`, the coarse grid) and
  `quad_pipeline_test.odin`: a streamed terrain is covered once on each tick when crossing it, an
  elevated chunk is resident before being built, the piece budget opens by distance, a Mesh shows
  nodes, and
  `sixty_four_terrains_of_one_source_stream_without_holes_caps_or_allocations` (the 8 by 8 world of
  terrains of one source, scaled down, without allocating in a stable frame).

Network: `mirai test plugins/terrain_multiplayer/runtime` (CPU, the messages between ends by hand):
a client's edit applied by the server and seen by another, two edits of a region in the server's
order, out-of-order edits and a lost one, a client that joins late, a request refused with its
cause, a correction that comes back and repeats the ticks, and the brush in bytes.

Bridges: `mirai test plugins/terrain_vfx/runtime`
(`a_dig_raises_dust_of_each_layer_it_took_on_its_channel`) and
`mirai test plugins/terrain_debris/runtime`
(`digs_give_a_piece_for_each_volume_taken_and_keep_what_falls_short_for_the_next`).

Editor: `mirai test plugins/terrain/editor` (CPU).

- `terrain_creation_separates_heightfield_mesh_and_volume_and_keeps_undo`
- `a_canceled_stroke_takes_back_its_head_and_keeps_the_history`
- `a_stroke_keeps_the_pages_it_changed_and_undo_and_redo_trade_them`,
  `a_change_of_kind_keeps_the_whole_source_once`
- `failed_terrain_save_preserves_redo_snapshot_scene_and_committed_bytes`
- `terrain_layers_paint_and_holes_are_steps_of_undo_kept_unsaved`
- `terrain_editor_budget_leaves_chunks_and_colliders_of_a_heightfield_to_the_runtime`
- `terrain_history_follows_a_save_and_a_discard_of_its_file`
- `undoing_a_new_terrain_takes_its_file_away_after_its_strokes`
- `a_preview_shows_the_level_of_its_chunk_and_a_hole_joins_its_neighbors_at_level_0`
- `a_landscape_becomes_a_heightfield_that_keeps_four_layers_and_folds_the_rest`
- `terrain_runtime_reads_unsaved_sources_and_follows_a_discard_without_reloading_each_frame`
- `volume_strokes_are_steps_of_undo_that_keep_only_their_blocks`
- `terrain_view_modes_ask_for_their_pipeline_only_while_one_is_shown`

GPU: `shared_terrain_chunks_remain_visible_after_duplicate_copy_and_preview_retirement` with
`-define:TERRAIN_GPU=true`, outside the CPU suite: shared source, world copy, preview and
retirement, with captures and GPU validation. Its residency without GPU (one set of pieces per
terrain): `terrains_of_a_shared_source_keep_one_set_of_pieces_each_across_world_copies`.

- The surface, refinement and boolean kernels have tests in `std/geom`.
- `mirai shaders check plugins/terrain/shaders/terrain_layers.slang` compiles the layers program in
  raster and in rays; its image, the joins between levels and the holes need a GPU capture.
- By API and captures: preview, file and revision until confirming, cancellation, undo/redo and
  entities that share a source. Unsaved: `editor.input` creates and sculpts, `asset.unsaved` and
  the disk do not change, `play.inspect` and `capture` see it, `asset.save` writes and
  `asset.discard` returns to the disk. Direct gestures are tested by the user; a Darwin ARM64 check
  only verifies types.
