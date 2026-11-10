# Current terrain

Two explicit creation options; the representation is not deduced from the collider.

- **Heightfield Terrain**: compact heights (`Heightfield`), for open ground.
- **Volumetric Terrain**: editable field of solid and air (`Volume`), for caves, overhangs and
  digging. Its field is sparse: it holds the blocks its surfaces cross, whatever its box.
- Both publish immutable meshes per piece, coarser far away, take the same brushes
  ([intents](#editing-during-play)) and support painted material layers; Heightfield adds holes.

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
  of its first chunk) and depth in the [tree](#tree-and-nodes): 0 is a chunk, higher up a
  node that covers 2^depth chunks per side. It says the level its mesh shows with that of its
  sides. It carries no `core.Id`: it is rebuilt on load and is not saved as authoring.
- It has a Parent to the owner and a local transform at the origin of its chunk (`chunk_origin`,
  the lower corner of its cells): its vertices and its collider are in that space
  (`chunk_place`), so a terrain kilometers wide loses no f32 precision far from its center. An
  empty chunk keeps entity and coordinate for later edits while it is
  [resident](#jobs-publishing-and-residency).
- The children show the [layers](#materials-and-layers) in their one slot, with their material
  and their override; they receive the owner's Tint.
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
  or beside it rebuilds the pieces of the strip (the `join` key of each piece).
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
`terrain:Source_Info` row (type, samples, cell, chunk, revision and layers) whose limits
`source.odin` validates. A file of another `VERSION` is refused.

- **Paged grids** (`Grid`, `grid.odin`): Heightfield heights, layer weights and holes in pages of
  `PAGE` samples per side over X/Z; Volume distances and weights in blocks of `BLOCK` samples per
  side in X/Y/Z. Every page has `PAGE_VALUES` values, so reading, copying, releasing and the format
  are one for both shapes. A page is named by its id, its place among every page of the grid.
- **A grid in blocks is sparse.** Its directory names what is not one value: a top level of parts
  (`Tile`), each a fill value or a table of slabs, each slab a fill value or its `SLAB_PAGES`
  pages. Air and solid far from a surface cost a `Tile` however large the box; a page takes a
  slot when a brush, an import or a read first gives it values, and `grid_settle` gives back the
  slabs and tables a brush leaves with one value. An X/Z grid holds every page, in id order.
- **In the file**, a `<grid>_pages` table holds runs (`Page_Run`) in the order of the directory:
  many pages of one fill value, or one page with the place, size and XXH3 hash of its LZ block in
  `<grid>_blocks`, stored uncompressed, so each page is read alone, by file range
  ([residency](#jobs-publishing-and-residency)). The runs depend on the values, not on what a grid
  happens to hold: two sources with the same samples write the same file.
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
  is another grid of pages and is shared the same way.
- **Volume**: `f32` distances (`distances`); negative is solid and positive air, limited to
  `SDF_BAND_CELLS` cells, as an approximate distance that does not recompute a global SDF after
  each brush. The initial block keeps an outer layer of air, and the brushes write only interior
  samples. A chunk gathers its samples and its halo from the blocks in a window of the field
  (`Scalar_Grid.first` and `extent`) with the positions of the whole field: neighbors that read
  different windows give the same vertices. A piece whose blocks are all air or all solid extracts
  nothing, and is known from the directory without reading a page (`volume_region_surface`).

## Geometry and collision

- **Heightfield**: one vertex per sample and two triangles per cell with the collider's diagonal,
  which is native and keeps heights, spacing, origin, diagonal and holes. Normals consult
  neighbors of the whole source.
- **Volume**: extracts the zero surface with [marching
  tetrahedra](../../mirai-std/references/geom.md#scalar-field-surfaces-isosurfaceodin),
  welds exact positions and uses a Mesh collider; picking intersects the same triangles as the
  builder.
- Colliders suppress flat or concave edges between chunks and keep convex ridges and outer edges;
  UV or material seams do not open the surface.

Levels of detail:

- **Volume** has no levels of its own. Its chunks show every sample, and a node of its
  [octree](#tree-and-nodes) is the surface of its chunks welded into one mesh, published with the
  cluster levels the renderer makes of any mesh: the view picks the detail of each cluster. The
  vertices on a side of the node's region that another piece shares are locked through every
  level (`Chunk_Mesh.locked`, `asset.Mesh_Source.locked`), so nodes and chunks meet without cracks
  at any mix of levels.
- The level of a Heightfield piece is the coarsest whose error (`Lod_Errors`: the farthest it
  ends up from its samples, measured when reading the source and followed by the edits) covers
  about `LOD_PIXELS` of the view from its terrain, and never finer than samples at
  `LOD_SPACING_PIXELS` pixels, which at a grazing angle come closer (`LOD_GRAZING`): the detail
  between samples that a pixel covers is not seen, however large its error. The pixels come from
  the height and field of the view (`core.View`), with hysteresis. With a positive
  `Terrain_Settings.lod_distance` the level comes from the distance to the box, never coarser
  than its error allows.
- Two Heightfield chunks that touch, by a side or a corner, are at most one level apart
  (`lod_levels_balance` refines the coarser one): a fine edge stitched to an interior several
  levels coarser folds.
- `Chunk_Lod` gives the level of a Heightfield chunk and that of its sides and corners: each takes
  the finest of the chunks that share it, so neighbors build the same over it and no cracks or
  T-junctions open. The border is cut into segments of one chunk and points of the
  chunk grid (`Border_Levels`): each piece that shares it, chunk or node, builds it from those
  levels, without looking at what the others show. Below `COARSE_LEVEL` a border reads the samples,
  and only where both chunks are well within a viewer's reach (their pages are there); if not, the
  [coarse grid](#tree-and-nodes).
- The collider is always that of level 0: changing level publishes another mesh with the same
  collision and physics keeps the shape.
- A level is built when chosen, with the neighbors whose sides change; none is stored.
- Level k of a Heightfield shows one sample out of every 2^k and a strip of triangles stitches
  each side to the interior grid. A vertex's normal comes from the samples at a step of what the
  vertex shares (interior, segment of the side or point of the chunk grid, at the level of its
  border): a coarse level shades the slope that its triangles span and shared vertices have a
  single normal. A chunk with holes stays at level 0.

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
  same geometry without physical halos or masks.
- The preview does not replace nodes: a stroke over an area that shows a node is seen on confirming.
- The preview builds each Heightfield chunk at the level it shows outside the stroke, so it joins
  those that do not change; a hole puts its chunk at level 0 and the neighbors whose side changes
  enter the preview.
- `chunk_publish` uses [generated meshes](../../mirai-core/references/host.md): it creates an
  immutable identity and then frees the previous one; it does not deform the resident mesh or
  refit. At runtime construction runs in jobs and publishing is a transaction with the collider
  ([jobs](#jobs-publishing-and-residency)).

## Materials and layers

- A source has from one to `LAYERS_MAX` layers, in both representations; there is no
  layerless mode. It is born with one that covers everything. Each `Terrain_Layer` has material,
  `tiling`, `height_blend` and an automatic rule of slope and height (`Layer_Auto`).
- The one slot of a piece shows the layers.
- The weights of each sample add up to `WEIGHT_FULL`: over the X/Z grid in Heightfield,
  and at each sample of a Volume, which stores in this way what it has under the surface
  ([interior](#volume-interior)). Removing a layer distributes its share among the others in their
  proportions; the last one is not removed. Paint adds a fraction of the brush's layer and Erase
  removes it; the others keep their proportions (`weights_paint`). In a Volume they touch the
  brush's ball, not the column.
- Each vertex takes the painted weights (`source_weights_at`: in Volume between the samples of its
  cell) and then each automatic layer, in order, covers the previous according to its rule
  (`layers_vertex`), which distinguishes walls and ceilings. A rule falls linearly along its
  softness, so between two samples it changes at most what their slopes differ over it; in
  Heightfield it reads the slope the same at all levels.
- The weights travel in UV0 and UV1 of the vertices.
- The slot shows the source's layers material (`layers_material`): a Surface program that blends
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
  the highest texels show where the layers blend.

### Volume interior

`Source_Info.interior` says which layer is under the surface of a Volume:

- Strata from top to bottom, each down to a depth below the top of its column (the last reaches
  the bottom), with edges that rise and fall (`wave`), and pockets (`Pocket`) or veins (`Vein`) of
  noise between two depths, each over the previous.
- `source_interior_apply` (`terrain.interior` in the editor) writes it into the weights of each
  sample, measuring the depth against the surface of that moment; it is not evaluated when
  drawing. The walls and floor of what is dug show those weights.
- Afterwards the brushes change it: Add gives what it turns solid the brush's layer
  (`Brush.layer`), blended with what the sample had by the part of its cell that was already solid;
  Carve leaves the weights. Applying the rule again overwrites what was painted inside.
- Removing a layer removes its strata and veins. A Heightfield has no interior.

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

## Tool

T or its entry in the Tools menu, outside Play.

- Without a selected terrain, the panel offers **Terrains** (those of the scene) and **Create**;
  with one, only its modes. The brush only sculpts a selected terrain: a click on another selects
  it. Picking on a child leads to the owner and, if the picker finds nothing, the brush tries
  `source_ray` of the selected terrain.
- **Create**: Plane or Heightmap for a Heightfield. Heightmap (16-bit PNG with its precision, TGA
  and BMP) normalizes integers to [0,1] without gamma and scales and offsets the height; its first
  row is the start of Z. Volumetric Terrain starts with a solid block surrounded by air. Plane
  shows the size in meters and in chunks, and the view draws its outline where it will be born.
- The new file (`terrain/<type>.terrain`) exists only in the registry's memory until Save and is
  part of the undo step: undoing it removes it even if later strokes changed it.
- **Save surface as mesh** (Sculpt of a Volume) writes its surface as a plain `.mesh` beside its
  source (`source_surface`), with the material of its first layer: the static form of what was
  dug, to place as any mesh. The terrain stays as it is.
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
  representation's brushes, with the same names in both (Set height is Flatten to a typed
  height, which the crosshair button or Ctrl and a click take under the pointer); **Shapes**
  (Volume), the shapes; **Paint**, the list of
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
- Flatten stores the height of the press. **Axis** (Heightfield) keeps a stroke along X or Z
  from its press.
- **Ramp** (Heightfield) and the **Shapes** shapes are placed with a drag and remain pending: the
  preview shows them over the source from before and their ends move with handles (those of the
  ramp over the surface, those of a shape over the view plane); the radius and falloff, the height
  of each end of the ramp and the blend are changed in the panel. Enter or Apply applies them as
  one undo step, Escape removes them and a click outside the handles or changing mode applies the
  pending one, which shows while it is adjusted.
- **Apply and consume selected mesh** (Shapes of a Volume) joins a closed `Mesh_Renderer`, leaf
  and outside a locked prefab, to the field or takes it out of it, as samples
  (`source_volume_mesh`: the distance to its triangles, inside by the parity of a column), in the
  terrain's space (also under negative scale) and with the blend of the shapes. It consumes the
  entity and the same undo step restores source, operand, components and selection.

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
- Creating and confirming check the budgets of sources and of samples, discounting the replaced
  source. The pieces and colliders are arranged by the runtime ([tree](#tree-and-nodes)). It
  reserves no GPU resources, bodies or shapes.
- **History** (`terrain_history.odin`): for each source it edited, the tool stores its head, what
  the file has at the owners' revision (a copy without scratch, made on the first stroke). A step
  between two revisions stores what the source had at the revision in which the head is not, only
  where they differ: pages of a Heightfield's grids (those of the region the stroke touched),
  blocks of a Volume's values and the parts of its directory that took one value, info and
  materials, or the whole source when its type or size changes. Undo and redo swap the step with
  the head, without copying, and the source that the tool edits follows the head without reading
  the file. The chain of revisions is that of the
  [editor](../../mirai-editor/references/extensions.md#a-viewport-tool).
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
stroke. `terrain.create` takes a `name` for its entity and file, beside the scene. A layer is named
by its material
(`asset.slot_named`: the path or stem, `default` with no material, `#2` for the second of the same).
A Volume's interior is edited in Paint,
under its layers: its rows hold what is changed until Apply. `terrain.edit` is a stroke of a brush
by its name from `at` to `to`, touching every quarter of the radius with what a pass does; a ramp
or a shape is a touch from `at` to `to`. A brush that the representation does not have, a layer
that does not exist, removing the only layer or an alpha that is not there answer what they take;
an error of the operation, what failed and how to fix it (`edit_error_fix`). While a game of the
caller runs, `terrain.edit` and `terrain.layer` are requests of that game (`terrain.dig`,
`request_layer`) that it applies on its next tick, without undo: an alpha-less stroke whose
touches fit in a tick's queue.

## Editing during play

- `terrain_update` writes the resident sources and consumes the requests before physics in Fixed;
  the editor also loads and publishes in Frame.
- `terrain.dig(requests,Brush,owner) -> Edit_Error` asks for an edit, in the world:
  `terrain_replay` and `terrain_update` resolve the owner first (given, or the terrain the brush
  touches: the nearest to the center, then the smallest footprint) and hand the brush on in its
  space, so networking keys edits by that owner. `terrain_requests_serve` keeps the room
  of `Terrain_Settings.requests` and reports what was dropped or refused.
- **A brush is an intent** (`Brush_Kind`), the same call on whichever representation is under it:
  Add and Carve join or take the shape of the brush (sphere, capsule or box), Raise and Lower
  move the surface by `amount` meters, Smooth, Flatten and Noise take it a part of the way (for
  continuous response, `1−exp(−strength*dt)`), Paint and Erase change the weight of a layer. A
  Volume joins a shape with `blend` and shifts its field to raise or lower; a Heightfield moves
  each column the shape crosses to its top or its bottom (`brush_shape_column`), so it carves a
  pit and cannot keep an overhang. Hole, Fill, Ramp (from center to center+delta, at the heights
  of its ends), Terrace and Erode are of a Heightfield alone.
- **What is wrong comes back** (`Edit_Error`, `brush_check`): a field that is not a number, out
  of its range or of another brush is refused by `dig` before it asks for anything, and
  `edit_error_fix` says which field and what to give. A brush the terrain under it lacks is
  `terrain.edit_kind` on that terrain when the edit is applied, with the brush to use in its
  place. A brush that touches nothing is no error. The queue rejects a `Brush.alpha`: it points
  to memory that it does not keep. `request_layer` and `request_layer_remove` change the layers.
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
  its pages in memory and its coarse grid, Volume those of its blocks with values). A source loads
  if its samples fit: the pieces are arranged when shown ([tree](#tree-and-nodes)). Its distances
  are read on each frame.
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

- **Dust:** `Terrain_Dust` on the terrain (`dust.odin`) gives per layer a channel of
  `core.Births` (`CHANNEL_DUST` or another, for another effect) and its color, and births per cubic
  meter with a cap per edit. An emitter of [`vfx`](vfx.md#channels) with a `Particle_Channel` of
  that channel shows it; without `vfx` nobody takes them.
- **Pieces and drops:** the `terrain_debris` plugin. `Terrain_Debris` gives per layer a piece
  prefab (with `Rigid_Body`, of the layer's material, which leaves with `speed`) and a drop one,
  each per so many cubic meters removed; what does not reach is owed to the next edit of that
  terrain (`Debris_Owed`), with a cap per tick for each.
- Both are configured in the inspector and by `scene.write`; the demo has them in the `dig`
  scene.

## Ground

`ground.odin` gives `core.Ground_Queries` (set by `terrain_update`), so foliage, navigation and any
other plugin read the ground without importing terrain. The probe answers the highest terrain along
a line; a Heightfield read straight down takes its coarse grid when asked or where its pages are
not in memory, so far from every viewer it still answers, coarser; a Volume there answers
`Unloaded`, and the page that comes marks its chunks, which announces them. A hole, or the region of
a stroke the editor holds (not in `Terrain_Data` until confirmed), answers `Empty`. At the end of
each `terrain_update` the views are made again when the terrains or their places changed
(`core.touched`) or the data did, and each change is pushed to `changed` as a box of the world: a
terrain that comes, goes, moves or shows another source (its whole box), the chunks whose version
passed the change last seen (`terrain_changed`, with a cell around them) and a stroke that begins,
grows or ends. Another epoch of `Terrain_Data` (a copied, swapped or reloaded world) starts the resident meshes
anew, and with them the box of every terrain is pushed. `unloaded` names the runs of chunks of each solid terrain
that have no collider now (not resident, beyond `collision_distance`, waiting for a slot or a
build); a chunk shown empty has nothing to load. They are made again only when the colliders, the
terrains or the data change or `Terrain_Resident.marks` moves (an owner or a chunk comes, goes or
turns empty or not), never by looking at every chunk; where they changed is pushed to
`unloaded`.

## Network

`terrain` does not know the network: another library orders the edits with `Terrain_Replays` and
reads how they came out in `Terrain_Replay_Events` (`network.odin`). The automatic bridge
`terrain_multiplayer`, active with `terrain` and `multiplayer`, carries them from one end to the
other; authority, prediction and rollback for the rest belong to the
[multiplayer contract](../../mirai-networking/references/multiplayer.md).

- **A routed tick** (`Terrain_Replays.routed`, which the bridge requests on each tick of a session)
  applies in `terrain_replay`, before `terrain_update`, the replicas in their order (a brush, a
  layer change, a whole page of a grid, the one value of a slab or a table of a Volume's
  directory, or the head of a base) and then
  the `terrain.dig` and `request_layer` requests, which `terrain_update` no longer sees. Each
  result says its error, the region that changed and its check: the hash of the values of all the
  grids in that region, or of the layers of a
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
  (`Net_Terrain_Resync`): the pages of its grids. The server sends them
  whole, in LZ and in chunks, with a byte budget per tick that a long part spreads over ticks, and
  the client writes each one in the place of the order where it started arriving: what follows
  waits for it.
- **A source knows where it came from:** `Source.origin` is the hash of the contents of the file it
  was read from (or saved to, which becomes it), and each page says whether it was
  written since then (`altered`; `Grid.filled` for the parts of a directory that took one value); a
  copy carries it.
- **One base for each source that the client loads, or cannot read,** is asked for by it with its
  origin if it wrote nothing since its file or what was written came from the server; if not,
  without origin. The server sends the base's head, which stands for all the earlier edits (shape,
  layers and materials), and the parts that it wrote since that origin, even before opening the
  session, not its history: the pages it holds, and one part for each slab or table of a Volume
  that is one value (`Net_Part`). With another origin, or none, it sends all: the client's source
  starts again from that shape, or is created if it did not have it. It only sends to the
  connections that entered its world. The base ends with a mark: what differs on the client up
  to it is not asked for, because the base brings it.
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

## Tree and nodes

A source has a tree over its chunks (`quad.odin`), even one of a single chunk. A Heightfield has a
quadtree: four chunks have a parent that covers the same, and so on up to one root per source. A
Volume has an octree as deep as a node of `VOLUME_NODE_CELLS` cells a side allows (two chunks a
side at least), with one root for each such region: a node is one build, so its size is bounded
and a large Volume has many roots. A root with no surface under it shows nothing and costs no
build.
`Terrain` is `@(component,far)`: when its section is not loaded the terrain is left without
colliders (`Resident_Owner.far`, with `scene.Far_Kept`: it chooses its pieces as a solid one, but
none carries a collider or is urgent, they are built in jobs), and far from the sources it shows
its nodes ([what is unloaded](../../mirai-gameplay/references/libraries.md#scene-references)).
A node where nothing is shown is urgent only near a viewer (`URGENT_REACH`);
farther away it waits for its job. While there are pieces to build, residency is chosen again once
per frame (in the first call); what the data changes, in each call.

- Each terrain (owner) chooses which pieces it wants: from its roots, it opens the nodes under which
  it needs a chunk, or, in a Heightfield, whose finest level is still coarse for the view (a node
  of a Volume holds every sample, and the renderer picks its detail). It needs as a chunk what is
  near a viewer if it has streaming; if not, being solid, what carries a collider (the nearest
  ones that fit in `Physics_Settings`, within `collision_distance`). It opens the nearest first
  (reach and distance) as long as the pieces of all the terrains fit in `Terrain_Settings.chunks`:
  past that, the far field shows coarser nodes and nothing is hidden. Roots always count; if they
  alone do not fit it is `terrain.chunks_full`.
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
- A Volume node is built from the blocks of its chunks (`node_build`), read for the build and let
  go once it shows ([levels](#geometry-and-collision)). Its job is taken when it ends, without
  waiting for it, and its levels are made in a second job that reads no source, so an edit does
  not wait for them. Chunks are built before nodes. An edit under a node that shows builds it
  again.
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
- A source read from disk (`terrain_read(...,paged=true)` over
  `asset_load_front`) leaves its pages in the file and reads them in jobs, by range, when a
  resident chunk, or a node of a Volume being built, needs them with the halo that its
  construction and its collider read (`chunk_pages_region`, `node_pages_region`); it releases
  them when none reads them and no job reads the source. A page with edits is first stored in an
  LZ block of its own and comes back with them: unloading and reloading a dug zone keeps the
  changes. A node whose border reads samples waits for the pages of that border. A Volume's
  weights come and go with its distances, block by block.
- The residency of the pages is that of the chunks, which is the shared one of `scene`: the terrain
  has none of its own. Far from every viewer the chunks of a Volume are released, and their blocks
  with them: what a game reads of a source there (`source_ray`, `source_value`) is not in memory.
- A brush first reads, in the tick, the pages it touches, and removing a layer all those of its
  weights. Save writes each page, those in memory and those in their blocks.
- A source that only has the registry's memory (unsaved in the editor) is read whole.
- A world copy (Play, snapshot, rollback) shares the pages in memory, the own blocks and the coarse
  grid; a uniform page is its value and the others stay in the file. A series
  of snapshots retains only the pages that changed within it, and releases them on
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

- A source that is only in the registry's memory (unsaved) is read whole.
- **Volume** is limited to `VOLUME_SAMPLES_MAX` per axis and `VOLUME_CHUNKS_MAX` chunks. Its
  octree stops at `VOLUME_NODE_CELLS`: a Volume kilometers wide shows its far ground as that many
  roots, each a piece of `Terrain_Settings.chunks`, and a streamed one builds each root once.
- A Heightfield cannot hold an overhang: Add and Carve move its columns. Ground that needs one is
  a Volume, alone or [joined](#joining-a-volume-with-a-heightfield) to the Heightfield around it.
- **Joining a Volume with a Heightfield:** a Volume rotated against the ground does not join
  (`terrain.ground_misaligned`); several Volumes that overlap over a Heightfield are not
  supported; far away the Heightfield shows nodes without holes under the nodes of the Volume.

## Verification

Runtime: `mirai test plugins/terrain/runtime` (CPU); `--release` only if a failure may depend on
optimization. It covers
persistence, clones, validation, memory, halo, raycast, masks, immutable publishing, empty chunks,
physics, saving, stability and world copy.

- `chunk_visual_build_preserves_geometry_and_reuses_collision_buffers_for_all_sources` and
  `bounded_volume_brushes_preserve_air_margin_and_can_remove_and_restore_all_material`.
- Intents (`intent_test.odin`):
  `one_brush_carves_adds_raises_and_flattens_a_heightfield_and_a_volume_alike`,
  `a_wrong_brush_is_an_error_that_says_what_failed_and_changes_nothing` (NaN, ranges, a brush a
  representation lacks, no memory) and
  `a_dig_request_edits_whichever_terrain_is_under_it_and_reports_what_it_cannot_do`.
- Sparse Volume and its octree (`volume_tree_test.odin`):
  `a_volume_node_is_the_surface_of_its_chunks_and_keeps_the_sides_it_shares_through_its_levels`,
  `a_cave_deeper_than_the_old_limit_is_dug_saved_read_by_pages_and_dug_again` (a dig across the
  borders of its blocks) and `a_large_volume_holds_and_stores_only_the_blocks_of_its_surfaces`.
- Recycled handles, relinked sources and incomplete chunks: authors are not confused with derived
  children nor left orphaned.
- `layers_test.odin`, `holes_test.odin`, `shading_test.odin` and `shape_test.odin` (falloff, wide
  Smooth, ramp and shapes).
- `displaced_chunks_split_their_cells_on_the_collider_and_join_their_neighbors`: the relief
  subdivides over the collider, stitches the sides and respects the holes; its image needs a GPU
  capture.
- Levels: `chunks_of_mixed_levels_join_without_cracks_or_overlaps` and
  `far_chunks_show_coarser_levels_while_colliders_keep_every_sample`. `bench_terrain_levels`
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
  `bench_terrain_volume_memory` (`-define:TERRAIN_BENCH=true`) prints, in bytes, what a Volume
  holds against every sample of its box, its file and what a viewer keeps resident.
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
- `chunks_without_a_collider_keep_their_triangles_on_the_cpu_only_while_the_world_does_not_play`.
- `pipeline_test.odin`:
  `rebuilt_chunks_show_in_the_next_tick_whatever_the_threads_and_stale_results_are_let_go`,
  `chunks_without_a_slot_for_their_collider_still_show_their_ground_and_the_nearest_collide`,
  `letting_go_of_an_excavated_zone_and_reading_it_again_keeps_its_edits`,
  `a_volume_lets_go_of_the_blocks_far_from_its_viewers_and_reading_them_again_keeps_its_edits`,
  `reading_a_paged_source_again_keeps_the_pages_its_file_still_holds` and
  `a_streamed_volume_past_its_budget_shows_nodes_in_place_of_its_far_chunks`.
  `bench_terrain_update_while_a_brush_edits` (`-define:MIRAI_BENCH=true`).
- Quadtree: `quad_test.odin`
  (`quadtree_nodes_and_chunks_of_mixed_levels_join_without_cracks_or_overlaps`, the coarse grid) and
  `quad_pipeline_test.odin`: a streamed terrain is covered once on each tick when crossing it, an
  elevated chunk is resident before being built, the piece budget opens by distance, and
  `sixty_four_terrains_of_one_source_stream_without_holes_caps_or_allocations` (the 8 by 8 world of
  terrains of one source, scaled down, without allocating in a stable frame).

Network: `mirai test plugins/terrain_multiplayer/runtime` (CPU, the messages between ends by hand):
a client's edit applied by the server and seen by another, two edits of a region in the server's
order, out-of-order edits and a lost one, a client that joins late, a request refused with its
cause, a correction that comes back and repeats the ticks, the brush in bytes, and
`a_volume_dig_that_differs_on_a_client_comes_back_as_its_blocks_and_a_late_client_gets_them`.

Ground and dust: `mirai test plugins/terrain/runtime` with
`the_ground_answers_each_line_as_its_terrain_has_it`,
`the_chunks_of_a_terrain_without_collider_are_unloaded_ground` and
`a_dig_raises_dust_of_each_layer_it_took_on_its_channel`. Debris:
`mirai test plugins/terrain_debris/runtime`
(`digs_give_a_piece_for_each_volume_taken_and_keep_what_falls_short_for_the_next`).

Editor: `mirai test plugins/terrain/editor` (CPU).

- `terrain_creation_separates_heightfield_and_volume_and_keeps_undo`
- `a_closed_mesh_joins_or_carves_a_volume_as_samples_and_undo_brings_its_entity_back`,
  `the_surface_of_a_volume_is_saved_as_a_mesh_asset`
- `a_canceled_stroke_takes_back_its_head_and_keeps_the_history`
- `a_stroke_keeps_the_pages_it_changed_and_undo_and_redo_trade_them`,
  `a_change_of_kind_keeps_the_whole_source_once`
- `failed_terrain_save_preserves_redo_snapshot_scene_and_committed_bytes`
- `terrain_layers_paint_and_holes_are_steps_of_undo_kept_unsaved`
- `terrain_editor_budget_leaves_chunks_and_colliders_to_the_runtime`
- `terrain_history_follows_a_save_and_a_discard_of_its_file`
- `undoing_a_new_terrain_takes_its_file_away_after_its_strokes`
- `a_preview_shows_the_level_of_its_chunk_and_a_hole_joins_its_neighbors_at_level_0`
- `terrain_runtime_reads_unsaved_sources_and_follows_a_discard_without_reloading_each_frame`
- `volume_strokes_are_steps_of_undo_that_keep_only_their_blocks`
- `terrain_view_modes_ask_for_their_pipeline_only_while_one_is_shown`

GPU: `shared_terrain_chunks_remain_visible_after_duplicate_copy_and_preview_retirement` with
`-define:TERRAIN_GPU=true`, outside the CPU suite: shared source, world copy, preview and
retirement, with captures and GPU validation. Its residency without GPU (one set of pieces per
terrain): `terrains_of_a_shared_source_keep_one_set_of_pieces_each_across_world_copies`.

- The surface kernel has tests in `std/geom`.
- `mirai shaders check plugins/terrain/shaders/terrain_layers.slang` compiles the layers program in
  raster and in rays; its image, the joins between levels and the holes need a GPU capture.
- By API and captures: preview, file and revision until confirming, cancellation, undo/redo and
  entities that share a source. Unsaved: `editor.input` creates and sculpts, `asset.unsaved` and
  the disk do not change, `play.inspect` and `capture` see it, `asset.save` writes and
  `asset.discard` returns to the disk. Direct gestures are tested by the user; a Darwin ARM64 check
  only verifies types.
