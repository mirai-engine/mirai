# Asset types in detail

Each type lives in its `asset/<type>.odin`: its tables and limits as constants, `*_document`/
`*_save` to write it, `*_view` to read it validated and `*_check` with its rules, which
`mirai asset verify` also applies. What the code does not make evident goes here.

## Fracture

The `destruct` plugin defines `.fracture` (`plugins/destruct/runtime/fracture_asset.odin`); the
model that consumes it (hulls, hierarchy and limits) belongs to
[destruction](../../mirai-physics/references/destruction.md).

- `Fracture_Info.source_mesh` can link it to the intact mesh; zero allows an independent source.
- Each piece is a closed mesh with local indices; the vertex and index ranges of the pieces cover
  the geometry exactly once. Strength zero on a connection inherits the component's; the physical
  construction also requires each cluster to have pieces.
- One hull per cluster is the shape the cluster collides with while whole: `fracture_document` bakes
  it as the convex hull of its pieces, and `fracture_source_check` validates what the author gives,
  without the hulls.
- `Fracture_Builder` does authoring in transactions: pieces from closed meshes, levels and
  connections by proximity between triangles, also for separate pieces. Area and strength are
  authoring parameters: it computes neither loads nor joining surfaces.
- `fracture_geometry` converts a validated source to runtime geometry; runtime and cooking share
  the algorithm. With non-uniform scale the areas are multiplied by the largest product of two
  axes.

## Mesh

- Geometry goes in clusters (`Cluster`) of up to `CLUSTER_TRIANGLES` triangles of a single slot,
  with `u8` indices to their vertices. A `Cluster_Vertex` (16 bytes) keeps position and uv as
  integers of grids of the whole mesh (`position_step`, `uv_step`, `uv1_step`, powers of two) from
  its cluster's minimum corner: a vertex that two clusters share decodes the same in both and no
  cracks open. The normal is octahedral and the tangent a signed angle
  (`math.tangent_angle_pack`); `uv1` and `color` are separate streams, only with `Has_Uv1` and
  `Has_Colors`. Every bulk column goes compressed, except `page_data`, which is compressed page
  by page, each page coded or as its raw words, whichever is smaller (`coded_bytes`, 0 for raw).
- Clusters go in pages (`Mesh_Page`): whole groups (the clusters that share a parent) of a single
  level, contiguous, up to `MESH_PAGE_WORDS`; a DAG group never crosses two pages. Their clusters,
  vertices and triangle words are contiguous ranges of the mesh's, from the finest to the coarsest.
  A page's block (`mesh_page_layout`) is its vertices, uv1, colors, surfaces and triangles, in words
  the renderer copies as they are; `mesh_page_decode` decodes one on the CPU, bit for bit, with
  preallocated scratch (`MESH_PAGE_SCRATCH_BYTES`) and without allocating. `page_data` stores each
  block coded (`asset/mesh_page_code.odin`) when that is smaller: each field split in low and high
  byte planes, tangent and normal kept as whole records so the repeats of a vertex that clusters
  share stay for the codec, and triangle bytes relative to the vertices met. Any words code back
  exactly, and a damaged coding fails, it does not crash. Each
  cluster names its page (`page`) and that of the group it was simplified from (`child_page`, that
  of its children). The pages from `root_page` are the root, always loaded: the coarsest levels as
  long as they fit in `MESH_ROOT_WORDS`, at least the coarsest, and every cluster nothing replaces;
  meshes with skin, morphs or `Levels` are entirely root. What `mesh_build` makes has no
  `page_data` until `mesh_pages_pack` codes its blocks as a file stores them (the far mesh does it
  when its root is not the whole mesh).
- Every mesh of finite positions and uvs fits in the grids: the step is the smallest power of two
  with which the widest cluster fits in 16 bits and the vertex farthest from the origin in 2^30
  steps; precision drops with size, it does not fail. The builders reject a NaN or an infinity
  (`vertices_finite`), and the importer says so with the mesh's name.
- `mesh_build` is the builder: it takes a `Mesh_Source` of full-precision `Vertex` (MikkTSpace
  tangent with its bitangent's sign, `material` as a row of `slots`), its indices and its levels,
  and importers and code-made meshes go through it. `mesh_level_decode` returns a level as an
  indexed mesh; `mesh_tangents` gives a code-made mesh the tangents of `geom.corner_tangents` and
  repeats a vertex where its corners take different tangents.
- `levels` (`Mesh_Level`) are cluster ranges, from the finest to the coarsest. Each cluster carries
  its error against level 0 and that of what replaces it (`parent_error`), each with its sphere; a
  view draws the clusters whose error fits its threshold and that of its replacement does not. In a
  DAG the clusters of a level replace parts of the previous one; with `Levels` each level is a
  whole mesh whose clusters share the mesh's sphere, and the same test picks only one. This is how
  the importer stores its levels ([levels of
  detail](../../mirai-imports/references/imports.md#levels-of-detail)) and the renderer draws them
  as they come. `ray_errors` are the DAG cuts that rays trace from afar; the coarsest takes only
  clusters of the root.
- `colliders` are collision shapes in the mesh's space; the importer writes them
  ([collision](../../mirai-imports/references/imports.md#collision)) or a tool does, and a `physics`
  plugin `Collider` `Hull` or `Mesh` uses them instead of the geometry that is drawn.
- Morph targets (`asset/morph.odin`): a delta names a cluster vertex and what the target at weight
  1 adds to its position, normal and tangent, before skin. `mesh_build` receives deltas of the
  source's vertices and copies them to each cluster that uses the vertex. An entity sets weights by
  name (`Morph_Weights`).
  - Deltas are stored quantized (`Morph_Cluster_Delta`) and the renderer reads them as they are:
    positions in steps of `morph_step`, the finest power of two that reaches the largest component
    of the mesh; normals and tangents, clamped to [-2, 2], in `MORPH_NORMAL_STEP` and
    `MORPH_TANGENT_STEP`. Each component is off by at most half its step. The builder rejects a
    delta that is not finite or names a vertex or a range the source does not have.
- A mesh of another `MESH_VERSION`, with skin or without, is rejected and must be reimported
  ([versions](formats.md#versions)). With skin it keeps bind positions and normals:
  `Mesh_Info.skeleton` references the skeleton, `joints` keeps indices of its bones and the mesh's
  own inverse-binds, and each vertex's eight weights are bytes that sum to 255
  (`skin_weights_quantize`).
  - Palette: `inverse(mesh_world)·rig_world·bone_model_pose·inverse_bind`.
- `mesh_view` decodes all pages into whole arrays (`Mesh_Geometry`), which CPU consumers read as if
  there were no pages, and validates counts, ranges, levels and pages; `mesh_check_indices` walks
  indices, weights, deltas and collision indices (linear).

## Skeleton

`.skeleton` stores a reusable hierarchy, separate from each mesh's bind; it stores no ECS entities
per bone.

- Bones with a unique path and earlier parent, and valid reference TRS; `sockets` with unique names
  on present bones.
- `body` (one row, optional) and `body_parts`: the
  [body map](../../mirai-std/references/anim-body.md) by bone path, with the confidence of each
  datum and whether a person set it; without `body` there are no rows. `skeleton_body_detect`
  detects it.
- `mesh_skeleton_check` validates a mesh's joint indices against the loaded skeleton: each file
  separately does not validate references to the other's content.

## Texture

- 8-bit formats `RGBA8`, `BC1`, `BC3`, `BC5` and `BC7`; `RGBA16` (16 linear bits, data that keeps
  its precision), `RGBA16F` and `BC6H` (linear half floats: HDR, light above 1; BC6H unsigned and
  without alpha). `cook/textures` encodes them ([compression](formats.md#compression)).
- **Levels, smallest first.** `texels` holds the levels from the smallest to level 0, compressed:
  `texture_open` reads a texture without its texels and `texture_decode` from a level decodes only
  the pieces of the stream that hold that level and the smaller ones (`texture_view` decodes all);
  `texture_mip` gives the bytes of a level, empty for one before `first`. Written with `Best`
  codecs, a texture of 16-byte blocks `cook/textures` writes stores the layouts the compressor has
  for it (`compressor:blocks`), which restore only whole: one of its tail (the levels of side
  `TEXTURE_TAIL` or less, which every read takes) and one of its larger levels; one per level
  compresses larger.
- **Planes of fields.** A BC1, BC3 or BC5 texture whose blocks are not `Fast` and that is
  compressed stores each level as planes of the fields of its blocks (`Fields`: endpoints and
  indices apart, `asset/texture_fields.odin`) when that stream is smaller, which the writer decides
  per texture compressing both with the profile `Fast` of its codecs; the read joins them back.
- `Srgb` says it is color: stored with the sRGB curve in `RGBA8`, `BC1`, `BC3` and `BC7`, linear in
  the others.
- **Layers.** `layers` is the number of images of each level (one if the file does not store it):
  those of an array or, with `Cube`, six faces per cube (+X, -X, +Y, -Y, +Z, -Z), square. A level
  stores its layers one after another and `texture_layer` gives the bytes of one. A cube is sampled
  with a Mirai world direction, with the GPUs' face and orientation convention (Vulkan, Metal and
  D3D share the face selection table).
- `texture_level_rgba8` (`asset/texture_blocks.odin`) writes an image of an 8-bit level as RGBA8; a
  BC5 receives in blue the third component of its unit vector. `texture_level_rgba16f` gives
  `RGBA16F` and `BC6H` as half floats and `texture_level_linear` gives any format as linear values,
  HDR included. `texture_bc6h_block_decode` reads every mode of BC6H; a reserved mode decodes to
  black.

## Material

- OpenPBR model with optional layers present with weight greater than zero (`material_layers`);
  `unlit` reflects nothing, shows its emission and excludes the layers. `emission_mode` is
  `Physical` (nits) or `Relative` (to exposure)
  ([model](../../mirai-rendering/references/materials.md#layers-openpbr)).
- An empty `program` is the standard model; `parameters` keeps its values and, with nonzero
  `overlay`, those of a layer of `overlays`. `hidden` are the names the editor does not show.
- The UVs have one transform, that of each map (`Material_Map`): a material that tiles gives the
  scale to its maps. The index of refraction is 1 or above.
- `material_view` validates ranges, also those of `imported` and `imported_parameters`.

### What was imported and what was changed

A material an import wrote has two layers in the same file: `imported` (one row of `Material_Info`)
is what the source gave in the last import and `material`, what the material is. Without
`imported`, the material is its own base: it has no changed fields nor anything to return to.

- An **override** is a field of `material` that differs from `imported`, compared leaf by leaf
  (`roughness`, `base_color`, `maps.normal.texture`): `material_overrides`. No separate list is
  stored, and returning a field to what was imported removes the override.
- `material_follow(view,new)` is what the import writes: what the source gives except the
  overrides. `material_revert(view,paths)` gives the parts they name (none: the whole material) what
  the source gave; a path that is not a part of `Material_Info` is `Invalid` and returns it.
- `imported_parameters` are the parameters of the last import of a source that gives a program.
  `material_parameters_follow` follows by name: it takes the new value except in a parameter that
  differs from `imported_parameters`, removes those the source stopped giving and keeps those a
  person added and those of the layers. `overlays` and `hidden` always belong to the material.
- It is the algorithm of the [prefab overrides](scenes.md#prefab-instances), with the same
  functions of `asset/overrides.odin`: `value_leaves`, `overrides_mark` and `override_keep`.

## Animation

`asset/animation.odin`. An `.anim` stores `std/anim` clips with their written names, their tracks,
keys and markers. The project's keeps every track as keys, which the editor edits; the cooked one
of a shipped game keeps the stream `anim.library_compress` makes of each clip
([storage](../../mirai-std/references/anim-storage.md)).

- A track's `target` is the textual identity of what it moves (empty for whoever plays the clip).
  glTF imports use escaped nominal paths independent of the source index; authored clips can use
  names.
- How a clip repeats is not stored: whoever plays it decides. Root options go in
  `Animation_Clip.root`; named sockets, in the `.skeleton`. `Animation_Clip.skeleton` names the
  `.skeleton` it plays on, which the importer, retarget bakes and clip edits fill: compression
  measures on its rest pose.
- `animation_document` checks capacities (`ANIMATION_MAX_*`), names, key order and finite numbers
  before building the document.
- `Cubic_Spline` requires explicit tangents and keeps glTF's per-component interpolation (Hermite,
  also for rotations); `Cubic` uses squad for rotations.
- `animation_clips_add` fills an `anim.Library`: clips and tracks carry the `base.name_hash` of
  their names and each marker's `id` is its row. If the view is invalid or not all clips fit, it
  returns 0 without touching the library. `animation_compress` then prepares it as the runtime plays
  it, on the skeletons a `Skeleton_Open` opens (`skeleton_open_registry`, or the host's assets) and
  the hierarchy of `animation_parents`; a cooked view already holds its streams.
- `animation_cooked_document` writes the cooked `.anim` from that library; `animation_descs`
  refuses a cooked view: it is not edited.
- `.character` and authoring by API (clips, tracks, keys, markers, skeletons) belong
  to the [animation plugin](../../mirai-animation/references/animation.md). Its edits validate the
  whole document and publish the file atomically keeping its identity; they are distinct from the
  scene's undo.

## Sound

`asset/sound.odin`. A `.sound` stores `Lossless` (16 bit samples coded without loss by
`audio.lossless_encode`, in the bulk table `lossless`, read from the file without a copy) or `File`
(a WAV or Ogg Vorbis as is in the bulk table `file`). Without the `Stream` flag the mixer keeps it
in memory (lossless stays encoded and each voice decodes it); with it, it is decoded while it plays
([audio](../../mirai-platform/references/audio.md#sounds)). The
lossless table is stored as it is: the residual coding leaves it nothing to gain. What the
importer stores: [imports guide](../../mirai-imports/references/imports.md#sounds).

## Sound set

`asset/sound_set.odin`. A `.sound_set` is `.sound`s that sound as one: each time it sounds one is
chosen by its weight, with a volume and a pitch from its ranges ([how it is
played](../../mirai-gameplay/references/libraries.md#audio)). Its `hearing` is how `audio.play`
hears it; an `Audio_Source` hears it by its own fields. It stores no audio: its sounds are
references, so they are dependencies and load like any `.sound`.

- `sound_set_problem` says which field is wrong and how to fix it; that each sound is a `.sound` is
  checked by the editor and the API, which know the registry. A weight of 0 counts as 1 and an entry
  without a sound does not count.
- It is created and edited by `sound_set.set` or its document in the editor
  ([previews](../../mirai-plugins/references/previews.md#sound-documents)).

## Interface

A `.ui` stores the records of [`ui.Tree_Data`](../../mirai-ui/references/ui.md#data-tree), a
table per record (`UI_TABLE_*`); contracts and precedence, in the
[UI reference](../../mirai-ui/references/ui.md).

- The texts of nodes go, of free length, in the bulk table `text`, which each
  record names by `offset` and `length` (`ui.Tree_String`); names and bindings, as fixed-length
  text. Images and fonts go by their asset's id, so they are dependencies.
- A component with `widget` takes its template from another `.ui`, which is also a dependency:
  `host.ui_tree_imports` reads those files (and theirs, without cycles) and `ui.tree_link` joins
  them to the records before loading. A row of `style_infos` with `from` takes the style of that
  name from the file of that component, at the same moment.
- `asset/ui.odin` declares the fourcc, the version, the tables and their structural check, because
  `asset` does not import `ui`; the node kinds, the override fields and the limits both judge the
  structure by are declared once, in `std/ui_format`, and `ui` gives them its own names. Whoever
  links the two packages writes and reads it:
  `host.ui_tree_document`, `ui_tree_save` and `ui_tree_view`; `ui_tree_document` returns `.Invalid`
  for records that `ui.tree_load` would reject.
- `asset.ui_check`, what `mirai asset verify` uses, accepts and rejects the same as `ui.tree_load`
  by structure (references, ranges, overrides, component cycles);
  `host.ui_check_refuses_what_tree_load_refuses_case_by_case` compares the two paths field by
  field. The values are covered by the check against the schema.
- Changing a value: `mirai asset set hud.ui 'nodes[6].layout.gap=8'`; adding or removing nodes or
  changing texts is its document (`mirai ui read`, edit, `mirai ui write`), or the editor's
  `ui.*` API.

## Font

`asset/font.odin` defines `.font`: the bulk table `file` stores the bytes of a TrueType or OpenType
font as is. One font per file: a collection (`ttcf`) or a web font does not pass `font_check`. The
UI keeps the bytes while it shows the font
([content](../../mirai-core/references/host.md#content)); what the importer stores:
[imports guide](../../mirai-imports/references/imports.md#fonts).

## Texts

`asset/strings.odin` defines `.strings`: a game's texts by key and language (`es`, `pt-BR`).
`entries` joins a key with a language and a range of the bulk table `text` (UTF-8, no length limit);
a key without text in a language has no entry.

- **One store.** Every text a player reads in their language is a key of a `.strings`, whoever
  shows it: a `Localized` node of a `.ui` (its text is the key), a `core.Text` field of a row of a
  `.records` or of a component (it holds the key) and the code (`core.text`). No other format
  stores a text in a language.
- **One table, one lookup.** `host.app_texts` joins every `.strings` of the assets into one
  `base.Texts`, read again when one changes, on disk or in memory; `base.text` finds a key in a
  language. A key is in one `.strings`: with two, the first by path is read and
  `mirai texts missing` says so.
- **Languages are data.** The languages of a game are the codes its `.strings` name (`pl` as much
  as `es`); the engine lists none. `mirai texts missing` names the characters of a language that
  the glyphs of the interfaces lack (`ui.FONT_RANGES`), which show as `?`.
- **One fallback.** A region that lacks a key shows what its language says (`es-419` and `es-AR`
  as `es`, `base.text` cutting the code at its last `-`). The first language of a `.strings` is
  the one its texts are written in (`UI_Settings.source`, which the tools write first): a language
  that lacks a key, and the code `""`, show what the key says in the first language of its file
  that has it.
- **One way to edit.** `cook/author/texts.odin` reads the `.strings` as rows of keys, sets a text,
  makes the key of a text (`texts_key`: equal texts share it, another text under that name takes a
  number), writes the files that changed, moves them through a CSV and lists what is missing with
  who asks for it. The CSV (`cook/import/strings.odin`, RFC 4180, UTF-8) is only that exchange: its
  first row is `key` and the code of each language, and a problem names its line. `mirai texts` does
  it on the files and `texts.*` in the open editor; a document of a `.ui` gives the text of a key
  beside its node and sets it ([texts](../../../../docs/game/ui/texts.md)).

## Records

`asset/records.odin` defines `.records`: a game data table whose rows are values of a code
`@(record)` struct ([game data](../../mirai-core/references/core.md#game-data)).

- `records` says the type of the rows as `library.Name`; the editor and `host` look it up in
  `World_Info.records`.
- `rows` has `id` (the key: what a `core.Record` stores), `name` (a word of ASCII letters, digits
  and `_`, unique in the table, by which the API and the CSV name the row) and `value`, with the
  type of the file's schema: a tool reads the rows without the code and the code reads them by field
  name. Ids are random, 53-bit, so that two branches adding rows do not collide and JSON reads them
  whole.
- `records_problem` says which row is not valid and how to fix it; `records_view` uses it on reading
  and `records_document` on writing.

## Prompts

`asset/prompts.odin` defines `.prompts`: each row is the part of a texture that shows an input of a
device family; the textures are dependencies of the pack.

- `family` and `input` are the numbers of `ui.Prompt_Family` and `ui.Prompt_Input`; `asset` does not
  import `ui`, and `host` checks at compile time that their counts match.
- `key` names the `core.Key` of the `Key` input and is empty in the others. Keys and mouse belong to
  the `Keyboard` family.
- What the importer builds: [imports guide](../../mirai-imports/references/imports.md#prompts).
