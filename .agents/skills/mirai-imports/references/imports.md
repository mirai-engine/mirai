# Import: current behavior

Packages, all *engine-time*:

- `cook/import` (`import importer "mirai:cook/import"`, because `import` is a reserved word): the
  core. The imported model, the `Reader` a format reads with, the source space, the PBR
  conversions, the asset writer, the settings, loose images, sounds, fonts, strings and prompt
  packs. It knows no model format.
- `cook/import/obj`, `cook/import/gltf`, `cook/import/usd` and `cook/import/fbx` (on top of ufbx):
  one format each, with its `FORMAT`. They import the core and nothing from the other formats.
- `cook/import/sources`: the `FORMATS` table (the engine's formats), `source_kind` and
  `import_source`, used by the editor (`editor/import.odin`), `mirai import` (`command.odin`, in the
  engine's `mirai-import` program) and `tools/demo_content`. The editor adds the formats of
  plugins ([plugin formats](#plugin-formats)).
- `cook/textures`: images to `.tex` levels.

## API

- `sources.import_source` imports a file into a folder: a model writes its assets and, if it has
  nodes, its prefab; an image, its `.tex`; a sound, a font, a strings CSV or a prompt pack, its
  asset. What already exists is written where it is ([identity](#identity-and-reimport)) and the
  settings stay next to the source unless `no_save`.
- `sources.source_kind` says what a file is from its first bytes ([sniffing](#formats)), except
  what the signature does not settle: TGA by extension, strings by `.csv` and prompts by
  `.prompts.json`. It carries the formats it searches with (`formats`, `FORMATS` by default), like
  `model_folder` and `import_source`. Only models and images have
  [settings](#settings-of-a-source).
- `importer.import_model` reads a source with the first of the formats that recognizes it
  (`sources.FORMATS[:]` or those of a test) into an `Imported_Model` in its own arena
  (`model_destroy`); `importer.import_write` writes its assets and returns the `Import_Report`.
  `prefab.model_import` does both with the prefab (`cook/prefab.model_prefab`).
- `Outputs` (`output_root`, `output_part`): the assets of an import that is not a model (a scene,
  the source of a plugin) take the file and the id of the previous one like those of a model: the
  root by the source (or `into`, or the bytes) and every other by kind and name, then index.
- For engine-time tools: `mesh_levels` ([levels](#levels-of-detail)), `mesh_collision`
  ([colliders](#collision)) and the PBR conversions of `pbr.odin`.
- `Error` is `{code,message}`; `message` lives in the caller's `temp_allocator`. `Import_Options`
  carries the settings and how they apply: `ignore_stored`, `root` (relative to which sources are
  named and under which previous imports are searched), `into`, `rebuild`, `no_save`, the caches
  and `worker` ([in parallel](#in-parallel)).

## Formats

`importer.Format` describes a source format; each package declares its own as a constant
(`gltf.FORMAT`, `obj.FORMAT`...) and its own options travel in `Format.data`
(`usd.format(&options)`).

- `extensions` is an array and not a slice: a `Format` is copied and the copy keeps its
  extensions.
- `version` is the version of what `read` returns for the same bytes: it goes up when that changes,
  and assets of another version are rebuilt when importing again.
- `space` is the `Source_Space` of its files, unless `read` declares another.
- `folder` says the folder of its own a file's import goes to; without it, the file name.
- `sniff` looks at the first `SNIFF_BYTES`: `Content` if they are of the format, `No` if not,
  `Extension` if they say nothing (OBJ, or a JSON whose `asset` object comes later).

`format_find` picks the first format of `sources.FORMATS` whose sniff is `Content` and, if none,
the first that says `Extension` and lists the file's extension: a GLB named `.bin` is read as glTF
and a text named `.txt` is not imported.

### The reader

`Reader` accumulates a read in the model's allocator; a format fails with `fail`, warns with
`warn`, resolves and reads files with the reader's helpers (which reject unsafe paths) and builds
meshes with `Mesh_Builder`.

- A `Corner` carries position, normal, color and UV as the source gives them: a missing UV is 0 and
  a missing `uv1` is the `uv`. For morph targets it names its morph vertex and whether its normal
  is that of its face.
- `builder_morph` adds a target with sparse deltas in engine space. The flat corners of a face
  that deforms are not shared and their normal delta leads to the normal of the deformed face; a
  declared tangent takes the delta of the source and a MikkTSpace one, what MikkTSpace gives the
  shape at weight 1 minus the rest one.
- `source_space(r,space)` declares the file's space before the first triangle; `r.basis` is its
  change of basis, in case the reader needs to orient something (a light) in the engine's.

### Source space

`Source_Space{meters_per_unit,axes,v_origin}`: `axes` says which source axis, with sign, is the
engine's +X, +Y (up) and +Z (the back of a model). This makes the vertical axis, the front and the
handedness explicit (a negative determinant is a mirror). `ENGINE_SPACE` is that of the engine:
meters, `{X,Y,Z}`, V from the top. A source whose models face its +Z with +Y up, as glTF, turns half
a turn about +Y: `FACING_PLUS_Z`, `{Negative_X,Y,Negative_Z}`, and `GLTF_SPACE`. USD with
`upAxis = "Z"` is `{Negative_X,Z,Y}`; a left-handed source in centimeters with +Z up and +X to the
front is `{0.01, {Y,Z,Negative_X}}`.

The reader converts nothing; the import bakes the space once and what is written is already in
meters and in the engine's axes, with no added nodes or negative scales:

- **At each corner**: position, normal and UV (`1-v` with `Bottom`) and, in a mirror, the order of
  the corners, so the triangle's normal keeps pointing outward; bounds, LODs and colliders come
  from that geometry. A tangent of the source turns with the basis and its bitangent sign is
  inverted in a mirror and with `Bottom`.
- **Tangents**: corners without a tangent take those of MikkTSpace (`geom.corner_tangents`), each
  slot with the UV that the normal map of its material reads; a vertex whose corners take
  different tangents is repeated with its skin.
- **When the read ends** (`space_bake`): transforms of nodes and bones conjugated by the change of
  basis (`C T C⁻¹`), inverse binds, keys and tangents of the clips, and the range, radius and size
  of lights. A change of basis is a signed permutation: a TRS stays an exact TRS. A light points
  to -Z of its node in the engine: `space_bake` gives the node of a light `light_frame` of the basis
  on the right and its children its transpose on the left, and a format whose lights look at
  another axis than -Z of their node orients them in its reader.
- **In materials**, with `Bottom`, the mapping of each map and `uv_scale`/`uv_offset` are
  conjugated by the inversion of v; the identity stays the same, with no negative zeros.
- A space equal to the engine's touches nothing: the bytes are those of the source.

### Front

Every model faces -Z. A file that follows its format already does once its space is baked; one that
does not is turned about +Y after the read (`model_front`), in place: the source is parsed once.

- `Import_Settings.front` states where the model stands facing once imported, and the import turns
  it from there with all the file holds; `Negative_Z` keeps it as read.
- With `Auto`, a file that is a rig, all it draws being skinned, is turned from where the body of
  its first skeleton with one is found facing (`body_detect`), when detection is sure of it. A
  file that also draws meshes without skin (a level with a character in it) is not turned.
- A body left facing elsewhere warns with what to do, because the `.skeleton` stores no forward:
  animation, retargeting and ragdolls read every body as facing -Z.
- `space_turn` applies the turn, a change of basis like any other: to the vertices, normals,
  tangents, morph deltas and bounds the builders made, and through `space_bake` to the rest.

### Adding a format

1. A package `cook/import/<format>` that imports `importer "mirai:cook/import"` and nothing from the
   other formats. One that is not the engine's lives in its plugin ([plugin
   formats](#plugin-formats)).
2. `FORMAT :: importer.Format{name=...,extensions={0=".ext"},space=...,sniff=sniff,read=read}`
   (`version` 0) and, if it has options, an `Options` and a `format(&options)` like USD's.
3. `read` fills the `Reader` in the source space it declares (`space` with explicit `axes`):
   meshes with `Mesh_Builder`, materials with the values of `.mat` and the shared PBR conversions,
   images by path or bytes (`green_down` for a normal map with green pointing down) and parent
   nodes before children. What cannot be represented fails with a named error or leaves a warning.
4. A line in `sources.FORMATS` and its package in `ENGINE_PACKAGES`, in the library of `cook`
   (`cook/build/engine.odin`).
5. Tests in its package with `importer.import_model(path,[]importer.Format{FORMAT})`; the fuzz of
   `cook/import/sources` is extended with its fixtures.

### Plugin formats

Besides `sources.FORMATS`, the editor imports what the plugins of the library in use provide with
two providers of their editor part
([extension](../../mirai-editor/references/extensions.md#importers-of-a-plugin)):

- `Import_Format_Provider{format}` is one more `importer.Format`: it is imported like the engine's
  (`sources.import_source` with the editor's list of formats) and goes to `<folder>/`, where
  `Format.folder` says the folder. Its extensions are in the Models filter of the dialog. Its
  `prepare` gives, on the editor thread, the format's options for an import (`Format.data`), and
  `release` frees them when it ends.
- `Import_Source_Provider{source}` is a source that the plugin imports whole, without a folder: it
  is not a model, and it writes what its importer says (a scene, its assets). It appears with its
  name as a filter of the dialog and claims a file with `claims(path, head)`.
- `mirai import` and `tools/demo_content` do not know them: a format or a source of a plugin is
  imported in the editor, with the plugin in the project. The Unreal content importer is the
  `unreal` plugin of the catalog ([git plugins and
  catalog](../../mirai-plugins/references/plugins.md#git-plugins-and-catalog)).

## Import cache

The `Import_Info` of each asset is the cache of its import: source (relative to `root`), name,
index, size and hash of what was read (the source, or the image of a texture), version and
`settings_hash`.

- `importer_version` combines `IMPORTER_VERSION` (the writer) with `Format.version`
  (`import_version`); loose images and sounds use format version 0.
- `settings_hash` is the identity of the settings that make that asset, and of no other: for a
  mesh, levels, collision, maximum triangles and whether it forces collision
  (`mesh_settings_hash`); for a texture, its `Build_Options` with `BUILD_VERSION`; for a sound,
  whether it is `Stream`. Materials, skeletons and clips store 0. Changing a texture setting keeps
  the meshes, and one of the meshes, the textures.
- `import_write` keeps a mesh or a texture whose file already has the same id and kind, the current
  `kind_version`, the right hash and the same `Import_Info`: it is not simplified or compressed
  again (`Written.kept`), although the source is read whole; if only the `owner` changes, it
  rewrites the header. Materials, skeletons, clips and prefabs, which are cheap, are always
  written, with what a person changed in them ([what is written](#what-is-written)), also with
  `rebuild`.
- An asset of another writer or format version, other settings or another `kind_version`
  ([version rule](../../mirai-assets/references/formats.md#versions)) is rebuilt;
  `rebuild` (`mirai import --rebuild`) rebuilds everything.

## Identity and reimport

The id in the header is the only identity of an asset. Each import looks for what a previous import
of its source wrote in the `assets/` folder of the project at `root` (without a project, under
`root`; without `root`, under the output folder; not in what is compiled, like `dist/`), reading
only the header and `Import_Info` (`asset.import_peek`), and writes each part again in its file and
with its id, even if it was moved. Among several files with one id the original counts, as in the
[registry](../../mirai-assets/references/formats.md#registry); what is new receives
`asset_id_random`.

- **Outside the output folder** (`Import_Options.outside`): the editor writes an earlier output
  again where it is (`In_Place`). `mirai import` refuses (`Refuse`, error `Outside`) before writing
  anything when an earlier output of the source lies outside `--out` (the search reached it through
  `--root`), naming it; `--in-place` writes it there and `--copy` (`Copy`) looks for earlier imports
  only under `--out`, so a scratch import gets new ids and leaves the live one alone. `into` names
  the import wherever it is. Of two imports of one source (a copy), the root under the output folder
  is taken, and the parts the taken prefab holds (by owner and what it names) before those of the
  other.

- **The root** of an import is the prefab of a model, the texture of an image or the sound of a
  sound, without `owner`. It is found, in order:
  1. by `into` (`mirai import --into <id>`, `asset.import {into}`), which must be a root with an
     `Import_Info` of the root's kind; otherwise the error says so;
  2. by its `Import_Info.source`, which names this source;
  3. by the bytes: a root whose source no longer exists, with the size, hash and extension of this
     source, is the same one moved or renamed. The extension keeps an image imported alone from
     taking the texture of a moved model, which names the model with the bytes of the image. Two
     candidates leave a warning and neither is taken.
  Without a previous root, a model with nodes receives a new prefab.
- **The outputs** of a model (meshes, materials, textures, skeletons and the `.anim`) carry their
  `Import_Info`, and the prefab its own and `Cooked`. Each takes the previous output of its kind
  whose `Import_Info` names the source that the root recorded, owned or not: first by name (among
  equal names, the one of its index), then by index, for what was renamed in the source. A previous
  output that none takes stays as it is, with a warning.
- **The textures of a model** name the model as source and the image as name, with the size and
  hash of the image.
- **What the project already has is not written twice.** A new texture whose image has the bytes
  and settings of a texture imported in the project names that texture (in an import of the
  editor, also one another import wrote Fast with those settings); a new material whose
  textures are all like that names the project material that has exactly those textures and whose
  `imported` layer is what this source gives it; if the source gives it other values, one of its
  own is written. What starts using another import stops being part of its own
  ([parts](#parts)), together with the materials of that owner that name it; the report warns of
  it.

### Parts

The `owner` of an output says that the content browser shows it inside the model's prefab. Only
what surely belongs to that model is a part; what is doubtful stays independent and visible
(`cook/import/parts.odin`).

- Its meshes and skeletons are always parts; its clips and the textures that no material uses, not.
- A material is a part (`Parts.Auto`) only if all of this holds, in this order:
  1. it has textures;
  2. a single mesh of the model uses it;
  3. none of its textures belongs to another import (the own import of the same image file does not
     count);
  4. all the UVs of its triangles, where its map puts them (like the renderer), fall in 0..1 with
     the slack `PARTS_UV_SLACK`: what an exporter that crops its atlas leaves;
  5. no UV island reaches from one edge to the opposite;
  6. rasterized on a grid of `PARTS_GRID` per side, they leave at least `PARTS_MIN_UNUSED` unused;
  7. its base image (or its normal, or the first it has) does not tile at its edges: on no axis does
     the difference between opposite edges exceed `PARTS_SEAM_STEPS` times the mean step between
     neighboring interior pixels while the edge varies along itself by at least
     `PARTS_EDGE_CONTENT` of a step. A flat edge, the padding of an atlas, says nothing.
- A texture is a part if some material uses it and all those that use it are parts.
- `Written.detail` of each material says why: `part of manny: UVs inside 0..1, 38% unused,
  edges do not tile` or `of its own: <the first condition that failed>`.
- **It is decided once.** A previous output keeps its `owner`: a part taken out of its owner
  (`asset.detach` in the editor, which only clears `owner`) is still an output of the import, which
  writes it and leaves it outside. Only `parts` decides it again.
- `Import_Settings.parts` (`mirai import --parts auto|all|none`): `Auto` the above; `All` makes
  parts of all the materials and textures of the model, and `None` of none, also of those that
  already existed.
- A copy made outside the editor is left without `owner` and without `Import_Info` when it receives
  an id of its own: no import writes it
  ([repeated ids](../../mirai-assets/references/formats.md#registry)).

## In parallel

What costs most to write a model is built apart from writing it: `model_cook` first builds the
levels, clusters and colliders of each mesh (`mesh_cook`) and the levels of each texture
(`texture_cook`), one `Import_Options.worker` job each, in the arena of its `Cooked_Mesh` or
`Cooked_Texture`; `import_write` takes what was built for its settings and builds what is missing
when it gets to it, with the same functions. Ids, files, parts and what is shared are decided on a
single thread and in the usual order: with or without a job system the same bytes are written.

- What a previous import already wrote is not built beforehand (`Known`, from the outputs it
  found: a mesh by its `Import_Info`, a texture by the image and its settings), except with
  `rebuild`. If the writer later does not keep it, it builds it itself.
- `Import_Options.worker` is the worker of the job system that calls (`jobs.Worker_Ref`: the owner,
  or the job that imports); without a system, everything runs on the calling thread. The BC blocks
  of a texture go in parallel rows of the same system, and without it, in one of their own if they
  are long.
- `mirai import` cooks in a job system of all the cores; `--profile` gives the seconds of each zone
  (`jobs.worker_zone`, in the ring of each worker) summed over the threads: reading and
  decompression of packages, image decoding, BC, levels, clusters, writing. `asset.import` with
  `profile` gives the same in `asset.import_status`, with the translators and what the editor does
  when it ends. Both sum with `importer.profile_totals`: each zone under the one that contained it,
  with its seconds on the importing thread, which add up to its wall time, and what no zone
  covers.
- The writes of a map share `Import_Options.earlier_cache`: the front of each asset of the project
  is read once per import, and again only if its size or dates changed.

### Texture cache

What matters about a built texture does not depend on its id or its path: `cook/textures/cache.odin`
stores it by content in `.mirai/cache/textures`
(`project.cache_path(root, project.TEXTURE_CACHE)`), one `.tex` per key whose id is the key.

- `Import_Options.texture_cache` is that folder (`""`, none); the editor, cooking,
  `tools/demo_content` and `mirai import` of a map pass it, taking it from its project.
- A texture that is not kept looks for its `textures.cache_key_build` (the bytes of the image, or
  the texels the format made with their size, layers and format, and the `settings_hash`): if it is
  there, its levels are written with the id and the `Import_Info` of this import; if not, it is
  built and stored. The same image from another source, in another folder or with the settings of
  before is not compressed again. `rebuild` does not read the cache and rewrites it.
- With `Import_Options.fast_textures` (the editor's imports) a texture takes the Final the cache
  keeps for its key; without one it is built Fast under the key of Fast settings, and a texture
  kept Fast is written again as soon as the cache holds its Final. `Import_Info.settings_hash`
  says which of the two the file holds.
- [Cooking](../../mirai-projects/references/build.md#asset-cooking) stores there the blocks of
  an RGBA8 texture by `textures.cache_key_blocks`.
- `cache_read` checks hash and key: a damaged file or one of another `TEXTURE_VERSION` is a miss and
  is built again. Reading an entry marks it used.
- An entry belongs to no asset (an old one serves again when switching branch or setting): that is
  why it is bounded by size, `CACHE_BUDGET`, and `cache.trim` deletes the ones used longest ago.
  Deleting the folder only costs time. The mechanism (file per key, key id and version, read that
  marks use, budget) is `cook/cache`, the same as the mesh cache.

### Mesh cache

A built mesh is worth by its geometry as read and its settings, not by its id: `mesh_cook` stores
it in `.mirai/cache/meshes` (`project.cache_path(root, project.MESH_CACHE)`,
`Import_Options.mesh_cache`, which the editor and `mirai import` of a map pass), one `.mesh` per key
with its levels, clusters and colliders, without materials.

- The key (`mesh_cache_key`) is the content of the mesh as the reader gives it (vertices, indices,
  skin, submeshes, morph targets and flags) with `mesh_settings_hash`; the file's id carries
  `MESH_CACHE_VERSION`, from `IMPORTER_VERSION`, `MESH_VERSION` and the version of the settings key:
  a change of the writer, the format or that key does not read what came before.
- A mesh that is not kept looks for its key; if it is there, it is written with the id, the slots,
  the skeleton and the `Import_Info` of this import, the same bytes as building it. `rebuild` does
  not read the cache and rewrites it.
- It saves simplifying, the cluster DAG and the pages; reading the source, no. It is bounded by
  `MESH_CACHE_BUDGET`.

## Settings of a source

`Import_Settings` is how a source becomes assets; its zero value is the default of each setting and
its fields are the options of `mirai import` (`IMPORT_USAGE`). What is not obvious:

- `image` says how a loose image is read; `Normal_Green_Down` is a normal map with green pointing
  down, as DirectX writes them, which is inverted when cooking. `alpha_coverage` is the cutoff of
  the `mask` material that samples it: each level keeps its [coverage](#textures-cooktextures).
  The images of a model take the cutoff of their materials.
- `rdo_lambda` is how much error the [encoder](#textures-cooktextures) of textures in blocks
  trades for files that compress smaller: zero is the default lambda and a negative value, which
  `--rdo-lambda 0` writes, the least error.
- `max_triangles` simplifies a mesh with more triangles down to them as a
  [level](#levels-of-detail), and that is its level 0.
- `front` (`--front auto|negative_z|z|x|negative_x`, `front` of `asset.import`) is where a model
  stands facing once imported, for a source that does not face the front its format says and that
  detection does not turn or turns wrong ([front](#front)). It is part of a mesh's settings hash.
- `rig` gives a model a [template rig](#template-rigs-cookrig) (`Humanoid` or a Mesh2Motion
  animal) in place of the skeletons and skins of the source; `rig_crotch` and `rig_neck`, only for
  the humanoid, are the heights in meters of the crotch and the neck when the fit does not see them
  (a skirt, a coat).
- `skeleton` (`--skeleton <id>`) puts the clips of a model on a skeleton the project already has,
  with the same bones: the import writes only its `.anim`, bound to it, and no textures,
  materials, skeletons, meshes or prefab. It is how the motion of another file (a set of clips
  exported with a body) joins a character imported before. In the editor it is `skeleton` of
  `asset.import`, the way to give it to a [plugin format](#plugin-formats). The reader sees it in
  `r.options.settings` (the settings the import applies, those of `<source>.import` when it has
  one): a format whose clips keep no skeleton of their own (Cast) reads that `.skeleton` to bring
  its keys to the frames of its bones, and adds its bones as a skeleton of the model, which is
  not written.

Settings live next to the source in `<source>.import`, a JSON with one entry per field name (an
absent field is its default), and win over the options except with `ignore_stored`: importing a
source again gives the same assets whoever does it. An unreadable file (unknown field or value,
negative number, coverage outside 0 to 1) is `Malformed`, never the defaults. Only `import_source`
writes the file, and it does not touch it if it already says the same; `mirai import --no-save` and
`tools/demo_content` do not write it, except this one with the masked images
([generated content](../../mirai-gameplay/references/demo.md#generated-content)).

## The imported model

`Imported_Model` is plain data, without engine components. A rigid mesh is in the space of its node
and a skinned one keeps the bind geometry; nodes go parent before child, with their local transform
in [engine space](#source-space). A skeleton is also extracted from a skinned source without
geometry (an export of Unreal clips), and a glTF with only clips is an importable model. A single
node with a mesh is not promoted or wrapped: whoever builds the prefab decides. Materials are only
those a mesh uses; repeated names are told apart with `name (n)`.

## What is written

What is new goes to flat files in the folder (`<name>.mesh`, `.skeleton`, `.anim`, `.mat`, `.tex`
and, with `import_source`, the model's `.scene`), with a valid file name that does not overwrite
another asset; what already existed is written where it is ([identity](#identity-and-reimport)).
Each imported asset carries the `Cooked` flag and its `Import_Info` ([cache](#import-cache)).

- **Ids and owner.** Random the first time and the same afterwards; the [parts](#parts) name their
  prefab as `owner`. Dependencies come from the `Asset_Id`s that each asset names.
- **Compression.** Texels go in BC blocks ([textures](#textures-cooktextures)); the bulk columns of
  a mesh and the levels of a texture go in LZ
  ([compression](../../mirai-assets/references/formats.md#compression)).
- **Materials.** The `.mat` stores in `imported` what the source gives and in `material` what the
  material is ([two layers](../../mirai-assets/references/kinds.md#material)). Over the file of the
  previous import it rewrites `imported` and follows the source except in the fields that differ
  from what it gave before (`asset.material_follow`, the algorithm of prefab overrides); the
  parameters of a program stay the same by name, and `overlays` and `hidden` are kept: what was
  changed after importing stays and a new texture of the source arrives. The skeleton likewise
  keeps the body parts set by hand.
- **Images that cannot be used** leave a warning and the map without a texture; a loose image that
  does not decode fails. If `import_write` fails, it deletes what it created in that call; what
  already existed is replaced one at a time with atomic writes.
- `Written.detail` says what each asset has (triangles per level and colliders of a mesh; format,
  size and mips of a texture; entities of a prefab), also for a kept one.

`mirai import <file> --out <folder>` is `import_source`, in the `mirai-import` program that the
engine build leaves next to the editor: the importers are engine code, and the tool compiles
without them.

- It first builds the engine if it is not up to date, in the mode of `--dev` or `--release`
  (with neither, the last built); what that build says goes to stderr and stdout is left with the
  report.
- It starts from the settings of `<file>.import`, applies the given options (`IMPORT_USAGE`) and
  writes the file again: repeating the command without options gives the same assets.
- The report gives one line per asset (`id kind bytes path (detail)`), how many were already up to
  date, the settings file and the warnings. Exit codes: 0, 1 (failed) and 2 (usage).

## Template rigs (`cook/rig`)

With `rig` other than `Source`, `import_model` gives the model the skeleton of a Mesh2Motion
template and the skin of its meshes, in place of what the source brings (`cook/import/rig.odin`).
It serves for a character that arrives without a rig (a generated model, a sculpture) or with one
that does not animate. Which template is chosen by whoever imports: the setting does not recognize
which animal it is.

- **Templates.** The Mesh2Motion rigs (CC0): the human and the animals `Fox`, `Horse`, `Bird`,
  `Dragon`, `Kaiju`, `Shark`, `Snake` and `Spider`, with their names and paths under their root
  node (`Armature/root/...`, `SpiderRig/root/...`), the same ones importing one of their clips
  gives: the clips of that library name them by path. The animals come from
  `scripts/gen_rig_templates.py` (`animals.odin` and the samples of their surface in
  `cook/rig/animals/`), which takes them from the commit that `fetch_mesh2motion.py` pins.
- **Humanoid fit** (`rig.humanoid`). The model stands on +Y and faces -Z, in a T- or A-pose with
  the arms away from the body. It is read by horizontal sections: the floor, the top, the crotch
  (the lowest section above the shins that crosses the center line) and the neck (the narrowest
  between the chest and the top); each joint has the rule that reproduces it on the reference
  model (`template.odin`), and the two sides are mirrored. What is not seen (covered crotch, arms
  stuck to the torso) is assumed by proportion with a warning that says which setting to pass.
  The body is detected by name when writing the `.skeleton`.
- **Animal fit** (`rig.animal`, `register.odin`). The model is on +Y and faces -Z, like the
  template. The surface of the template, weighted to its bones, is deformed with its own skin until
  it covers the mesh: each joint turns, stretches the bone that ends in it and thickens what it
  carries, the two sides mirrored and the central ones only vertically, with pairs of closest
  points that are renewed between rounds and a soft loss for what the template does not have (a
  horn, some ears). It starts from the model's box, or from the rows of legs (blobs of a low
  section) carried to those of the mesh if that covers it better. If even so it does not cover it,
  a warning says so; that it covers it does not prove it is that animal.
- **Bind and rest.** The skin is bound where the joints are in the mesh; the rest of the `.skeleton`
  is the pose of the template with the lengths of the mesh.
- **Weights.** Those of the Mesh2Motion solvers (MIT): each vertex to the bone whose middle is
  closest, the limbs give back what remains behind their first joint, hanging arms give back the
  chest, and the edges are blended by the adjacency of the mesh, wider in the torso and only
  toward the child in a limb; the categories come from the bone name. In the humanoid the pelvis
  takes no vertices below the crotch. Two influences per vertex, quantized like those of any skin.
- **What it replaces.** Meshes are baked where they rest: one without skin where its node puts it,
  one with skin where its skin leaves it at bind (glTF ignores the node of a skinned mesh); the
  node stays at the root with the identity transform. The bones of the source leave with their
  skeletons and their clips (a warning counts them), and what hung from them stays under the
  nearest node that remains. A node with a mesh and children or a mesh in two nodes are rejected,
  saying how to export them.

## Levels of detail

With `lods=Auto` a static mesh is stored as the cluster DAG of its level 0
(`asset.mesh_build_dag` on top of `geom.cluster_dag_build`): groups of simplified clusters with
their border locked and split again up to the roots, with the cuts that its distant rays trace. One
with skin, or whose foliage is pruned, stores simplified levels after level 0 (up to `LOD_MAX` in
total), each with its own vertices, which `asset.mesh_build` encodes as whole levels (flag
`Levels`, `geom.cluster_levels_build`): clusters that share the sphere of the mesh, so that a view
chooses only one ([mesh](../../mirai-assets/references/kinds.md#mesh)). With `lods=None` or a
small mesh, level 0 alone is stored. What follows describes those whole levels; the DAG simplifies
with the same weights and locks.

- **Level 0.** The source's or, with more than `max_triangles`, the one that simplifying it down to
  them gives; the colliders come from it.
- **How many.** Each level aims at `LOD_SHARE` of the triangles of the previous one; the series
  ends if a level keeps more than `LOD_KEEP` of the previous one or its error exceeds the radius of
  the mesh (that one is not stored: it would be drawn only where the whole mesh fits in a pixel),
  or if the previous one has fewer than `LOD_MIN_TRIANGLES`.
- **How.** Each level comes from level 0 with `geom.simplify`
  ([simplifier](../../mirai-std/references/geom.md#simplification-simplifyodin)): normal and uv
  weighted (`LOD_WEIGHTS`) and the border locked, so that pieces that touch along the border (a
  modular kit) keep touching at every level. If normal seams stop it before the target, it repeats
  with `Permissive`, protecting the vertices of a location that differ in more than the normal (uv,
  uv1, color, material, tangent sign): the outline between materials and the UV islands are not
  crossed. `lod_inputs` builds those inputs once for the importer.
- **Attributes.** Every vertex of a level is a vertex of level 0 as is, with its skin and its morph
  deltas; only pruned islands move.
- **Foliage pruning** (Cook et al., *Stochastic Simplification of Aggregate Detail*, Pixar 2007).
  An island is a piece of a submesh that shares no position with the rest. A submesh is of islands
  if it has at least `ISLANDS_MIN` small islands: leaves and cards, of up to `ISLAND_MAX_TRIANGLES`
  and of `1/ISLAND_MAX_SHARE` of its triangles. Those islands are not simplified by quadrics, which
  shrink them to nothing: they are split into classes by octave of radius below the largest of
  their submesh (up to `ISLAND_CLASSES`), and a class pruned j times keeps the first 1/2^j of its
  islands in a fixed order (a hash of its first triangle, spread over the submesh; each level is a
  subset of the previous one) and enlarges the remaining ones around their center to the area they
  all had, up to `ISLAND_GROW_MAX` times their radius. The rest of the submesh (trunk, body) is
  simplified like any other. Bushes of hundreds of triangles are not small islands: quadrics
  simplify them with less error than pruning them. Only the levels of `lods=Auto`; level 0 from
  `max_triangles` is simplified whole.
- **How much is pruned.** Each level prunes each class as far as the error that the rest already
  has simplified allows; if that would keep more than `LOD_KEEP` of the previous level, it allows
  the smallest error that prunes one more class, until it does not. The leaves of a tree whose
  trunk is simplified with little error go away when they are small, and a few large islands (a
  vine, the large piece of a panel) stay in their class without holding back the others.
- **Error.** `Mesh_Lod.error` is how far the simplifier moved the surface of level 0 (its position
  error, without that of the attributes), in object units; with islands, the larger of that and,
  of each pruned class, the radius of its largest island already enlarged over `ISLAND_PIXELS`. The
  renderer takes a level where its projection falls within `lod_error_pixels` and that of the next
  does not ([cut](../../mirai-rendering/references/scene.md#scene-and-instances)).
- The triangles of a level are grouped by submesh of level 0, with its slot and its box.

## Collision

The colliders that the source brings (`Imported_Mesh.collision`, in the source's space until the
import moves them to the engine's) are those of the `.mesh`; the settings make them only if the
source brings none or with `force_collision`. The engine's formats do not bring them; a plugin's
does.

`collision` adds to the `.mesh` `asset.Collider` rows in the space of the mesh, made from the
surface welded by position: `Hull`, a convex hull (of a flat surface, its outline); `Pieces`, hulls
that together cover a non-convex mesh (up to `collision_hulls`); `Mesh`, the simplified triangles
(`COLLISION_MESH_SHARE`); `Exact` (`--collision exact`), every triangle, for geometry made to
collide (a clip map of another game), which a simplification would open. A surface from which the
collider cannot be made is left without colliders with a warning. How they are used:
[host](../../mirai-core/references/host.md#loaded-assets) and [the physics
libraries](../../mirai-physics/references/engine.md).

## Textures (`cook/textures`)

- **Source** (`Source`): RGBA texels with rows from the top, image after image (the layers of an
  array or the faces of cubes, in the order of the
  [texture](../../mirai-assets/references/kinds.md#texture)), in `RGBA8` or `RGBA16` (with the sRGB
  curve under `srgb`, linear otherwise) or in `RGBA16F` and `RGBA32F` (linear light: HDR).
  `source_decode` reads with `vendor:stb/image` a Radiance `.hdr` as `RGBA32F`, a 16-bit-per-channel
  PNG as `RGBA16` and any other image that stb decodes (PNG, JPEG, BMP, TGA, GIF, PSD) as `RGBA8`,
  with bounded sides and pixels; stb does not read OpenEXR. `image_decode` gives RGBA8 of any of
  them, for what only looks at the image (verdicts, atlas).
- **A single algorithm** (`build`) for all formats: each layer goes down its complete chain to 1x1
  separately (the faces of a cube are not mixed), each level reduced from the previous one in the
  source's format, each texel as a weighted average in linear values (`texel_read`/`texel_write`)
  of the source texels it covers:
  - **Color (`srgb`)**: averaged in linear light and returned to the source's curve.
  - **Normal map**: averaged as a vector and renormalized; with `green_down` the green is inverted
    first, so that +Y points up as in glTF and in the renderer.
  - **Other maps and HDR**: direct average of their values; light above 1 is kept.
- **Channels** (`Build_Options.channels`, `Imported_Image.channels`): before anything else each
  channel can take another channel of the image or a constant, inverted or not; a gloss map in
  red becomes the roughness of a metallic-roughness texture (`from={.One,.R,.One,.One}`,
  `invert={1}`) without the reader decoding it. Part of the settings hash; the zero value keeps
  the channels.
- **Alpha coverage**: with `alpha_coverage > 0` each level scales its alpha, by bisection, until
  it keeps the proportion of texels above the cutoff that the original image had.
- **Maximum size**: a larger image starts at the first level that fits.
- **Format** (`stored_format`), decided by the whole source image before reducing it:
  - `.Uncompressed`, or a 16-bit or float source with `keep_precision`: what the source has,
    `RGBA8`, `RGBA16` or `RGBA16F`.
  - In blocks, by use: normal map, BC5 (the shader reconstructs the third channel); a float source
    is HDR, BC6H unless some texel is not opaque or has a negative channel, which BC6H does not
    store (`RGBA16F`); color, BC7 with or without alpha; another map with no transparent texel,
    BC1, and with alpha, BC3. A 16-bit source without `keep_precision` is compressed by use like an
    8-bit one.
  - It is stored linear except in 8-bit formats with `srgb` (`level_store`).
- **Encoder**: every block format goes through `cook/compressor/texture`
  (`level_encode`, the only implementation), with the perceptual metric and the lambda of
  `rdo_lambda`: the rate-distortion optimization picks blocks a little worse that repeat endpoints
  and indices, so LZ (after BC7Split for BC7) compresses the file smaller. Each layer of a level
  is one surface. Alpha keeps exact 0 and 255; a BC7 layer with every texel opaque is encoded
  without alpha and decodes 255. BC1 may use the three-color mode, whose fourth color decodes
  black with alpha 0: a BC1 map is read for its RGB. BC6H is encoded from half floats (light beyond
  them clamped, a NaN 0) in any of its modes. On a worker of the job system the blocks of a level
  go in parallel with scratch from the heap; a large level without one runs on a job system of the
  build's own. `asset` decodes ([texture](../../mirai-assets/references/kinds.md#texture)).
- **Devices without BC.** The file carries no alternative formats: `host` decodes the blocks when
  loading, to RGBA8 and BC6H to RGBA16F, when the device does not sample them; the renderer's
  limits discard large levels without re-encoding
  ([rendering](../../mirai-rendering/references/materials.md#textures)).
- Bump `BUILD_VERSION` when `build` would give other bytes for the same image.

### Heightmaps (`cook/textures/heightmap.odin`)

`heightmap_decode` reads the height channel of an image into values in `[0,1]` (X contiguous, rows
from top to bottom): a 16-bit PNG keeps its steps, 8-bit sources are expanded before normalizing,
it applies no sRGB and generates no mips, and alpha does not count. It rejects HDR (its conversion
to integers would introduce gamma) and PNM (read failures and precision of the integrated stb
version) before the decoder, and checks header and size before decoding. The caller passes the
heights to its units and decides the size of its terrain.

## OBJ

- Vertices (with color `v x y z r g b`), `vt`, `vn`, objects and groups (`o`/`g` split the mesh),
  negative indices, faces of any size and `usemtl`/`mtllib`; one mesh per object and one node per
  mesh.
- The file states neither its units nor its axes: `obj.FORMAT` declares meters, +Y up and V from
  the bottom, as Blender writes it. Without normals the face is flat.
- Triangulation: a convex quad by its 0-2 diagonal and the rest with `std/geom` (concave ones
  included). Faces without area are omitted with a warning; `l`, `p`, `s` and a missing or
  unreadable MTL do not fail the import.
- Slots: one per `usemtl` name in order of first appearance in the mesh, also those the MTL does
  not define; the id is the position plus one.
- MTL: `Kd` (0.8 if missing), `Ke`, `Pr`, `Pm`, `Ns` (without `Pr`, `roughness = 1 - sqrt(Ns/1000)`,
  as Blender exports), `d`/`Tr` (less than 1 is `blend`), `map_Kd`, `map_Ke` and
  `norm`/`map_Bump`/`bump` (with `-bm` for scale), with paths relative to the OBJ. `map_Pr` and
  `map_Pm` are not read.

## glTF and GLB

Standard PBR materials and their textures become `.mat` and `.tex` deterministically, and the
slots of the `.mesh`, one per primitive, reference them.

- Base color, emission and specular color are sRGB; the other maps, linear data (ORM: occlusion R,
  roughness G, metallic B). An image shared between color and data gives two textures; several maps
  of the same use share a texture with their UVs and transforms. Two different images never share
  identity because they have the same name.
- With cgltf: default scene (or the first, or the roots of all nodes), TRS or decomposed matrix
  (negative scale is kept), one mesh for the nodes that share it, triangles, strips and fans,
  `NORMAL`, `TANGENT` (with `NORMAL`), `TEXCOORD_0/1` and `COLOR_0`; triangles without area are
  discarded.
- **Materials**: metallic-roughness with emission relative to exposure (glTF gives no unit and its
  viewers show 1 as the display white), `alphaMode`, `KHR_texture_transform` per map and the
  extensions transmission, ior, volume, specular, clearcoat (a white coat of IOR 1.5), diffuse
  transmission (from the JSON: cgltf does not read it) and unlit (emits its base color). A material
  without metallic-roughness is a rough metal; a map that asks for a missing `TEXCOORD` rejects the
  import.
  - Specular-glossiness goes through `importer.specular_glossiness`, like the Khronos converter;
    with its texture it becomes a dielectric with a warning.
  - Sheen of color `c` is a fuzz of weight `max(c)` and color `c / max(c)`, which leaves the base
    `1 − max(c)·R` as the extension asks; with a texture, the base is darkened by the factor
    (warning).
  - Anisotropy goes to the roughness and the amount of OpenPBR with the same alphas
    (`mix(r², 1, s²)` along, `r²` across); with textures it is converted texel by texel into new
    images and, if they read different coordinates, only the factors (warning).
  - Model differences, without a warning: the OpenPBR coat darkens the base and changes its
    relative IOR; the fuzz is Zeltner's LTC lobe, not glTF's Charlie. Iridescence, dispersion and
    vertex colors on unlit leave a warning.
- **Lights**: `KHR_lights_punctual` goes to the node's entity in the same units (`Sun`,
  `Point_Light` and `Spot_Light` with `outerConeAngle` clipped to its range; `innerConeAngle` is
  ignored: the soft edge is fixed). Without `range`, the reach is where it gives 0.5 lux
  (`light_range`).
- **meshopt** (`EXT_meshopt_compression`): an attribute buffer view is decoded once and cgltf reads
  it like any other (`meshopt.odin`), with the `QUATERNION` and `EXPONENTIAL` filters that
  glTF-Transform uses in clips. Compressed indices and the `OCTAHEDRAL` filter are rejected.
- **Rejected**: Draco, indices and normals with meshopt, GPU instancing, points and lines,
  matrices with shear, perspective or zero scale. Nodes outside the scene are not entities,
  although their clips are imported; cameras are not read.

### Skinned meshes

A node with `skin` produces its own mesh, without sharing it between nodes.

- Each primitive needs `JOINTS_0` and `WEIGHTS_0`, as many as `POSITION`, and admits
  `JOINTS_1`/`WEIGHTS_1` with the eight influences; incomplete sets and more than eight are
  rejected.
- Weights are quantized once to bytes that sum to 255 (`asset.skin_weights_quantize`), before
  deduplicating vertices, and a weight that ends up zero names joint 0; negative, non-finite
  weights, without a positive sum or with a joint outside the skin are rejected. Without inverse
  binds the identity is used; if they exist they must be affine, finite and invertible.
- Positions and normals keep the bind space. The skeleton is stored once per skin in a `.skeleton`,
  with the ancestors needed to preserve the source's space, also that of a skin no mesh uses (a
  clips file): it is the origin of a bake. The mesh references it ([mesh
  format](../../mirai-assets/references/kinds.md#mesh)). Bones are not entities in the prefab.
  Bounds, LODs and colliders describe the bind geometry.
- The import detects the [body map](../../mirai-std/references/anim-body.md) and stores it if it
  finds any part; when importing again it keeps the `manual` parts and axes of the previous file
  whose bones still exist, and the sockets someone added (not those the import makes: named by the
  source, `bone.*`, grips) on bones that still exist.
- The root of each clip (`Animation_Root`) is the parent bone of the pelvis of its skeleton, with
  translation and rotation, when the clip moves or turns it (the root of an Unreal skeleton in a
  clamber or a jump start), so a character whose capsule moves the body plays it in place. A
  pelvis without a parent bone, or a clip that leaves that bone still, gives no root: the track of
  the pelvis is the bob of the body. Importing again keeps the root someone set on a clip
  (`animation.clip.set`) while its bone exists.

### glTF clip markers

`extras.markers` of a glTF animation (`[{"name": "foot_l", "time": 0.27}]`) become the markers of
its clip, sorted by time: the events a source keeps on a timeline (notifies, footsteps), which
importing again keeps. A marker without a name or at a time that is not finite and nonnegative
fails the import.

### glTF morph targets

The targets of a mesh go to its `morphs` and `morph_deltas` tables ([mesh
format](../../mirai-assets/references/kinds.md#mesh)), with the deltas before the skin.

- Name from `extras.targetNames` (or `Morph N`), unique; weight from `mesh.weights`; up to
  `asset.MESH_MAX_MORPHS` targets. All primitives declare the same targets, and an attribute that a
  target does not bring does not move.
- `POSITION` and `NORMAL` add to the base; a target `NORMAL` without a base `NORMAL` is rejected. A
  primitive without `NORMAL` has flat normals and each face that deforms takes that of its shape.
  A target `TANGENT` is read where the primitive declares its tangent; elsewhere, MikkTSpace
  ([builder](#the-reader)). Other target attributes are ignored with a warning.
- `node.weights` has one weight per target; the prefab stores in `Morph_Weights` those that differ
  from the mesh's, and more than `asset.MORPH_WEIGHTS` distinct ones are rejected: give them to the
  mesh or animate them.

### glTF clips

Each TRS channel is stored in a track of the `.anim`.

- The target is the path of names from the root, with `%` and `/` escaped as `%25` and `%2F`, and
  bones and nodes store their `name_hash`: reordering the source indices keeps the references.
  Renaming or reparenting a node changes it: there is no implicit remapping or identity invented
  from indices.
- Repeated names are valid in different paths; siblings with the same name are rejected and the
  error asks to tell them apart before exporting. A node without a name is `Skeleton` if it carries
  a skin, `Mesh` if it carries geometry or `Node` (so the separate mesh and clip exports of Unreal
  match).
- Clips with a repeated name receive a deterministic suffix. The animation asset is one per source:
  reimporting finds it by that, without depending on clip names.
- STEP, LINEAR and CUBICSPLINE are preserved: the latter keeps the tangents per second and is
  evaluated as Hermite per component; a rotation is normalized afterwards, without squad. Times are
  finite, non-negative and strictly increasing. A rotation may come in normalized integers, as the
  meshopt quaternion filter leaves it; translation and scale, in floats.
- Duplicate channels of one property, animated nodes with a matrix, null quaternions, non-finite
  data, inconsistent counts and exceeded capacities are rejected.
- A `weights` channel gives a Float track per target, `<node path>/@morph/<target>`.
- glTF provides no events or arbitrary curves; they are added to the `.anim` with its asset API.

## USD

Composition and the binary crate come from `usdcat --flatten --skipSourceFileComment`, which is
searched in `usd.Options.usdcat`, `USD_CAT`, the system's binary folders and `PATH`. Without it (or
with `usd.Options.no_usdcat`) a USDA that needs no composition is read: references, payloads,
inherits, variants, sublayers and binary files fail with a `Tool` error that says so.

- **Polygonal meshes** (`subdivisionScheme = "none"` required) with each primvar in its
  interpolation and indices: normals (`primvars:normals` wins over `normals`) and `primvars:st` and
  `st1`. `displayColor` colors meshes without a material (0.8 gray if missing); with a material,
  white.
- **Hierarchy**: the reader declares the file's space (`metersPerUnit`, 0.01 if missing, and
  `upAxis`), which the import bakes; no node stores the units. Each prim is a node with its local
  transform (all xform ops, inverted ones and `!resetXformStack!`), `visibility` and `active`;
  Material, Shader and NodeGraph are not nodes.
- **Materials** `UsdPreviewSurface` bound on the mesh or its nearest ancestor, with their
  `UsdUVTexture` images (an input with an image leaves its factor at 1) and the mapping of a
  `UsdPrimvarReader_float2` and a `UsdTransform2d`. Metallic and roughness come from a packed image
  (roughness in `g`, metallic in `b`), occlusion from `r` and opacity from the alpha of the color;
  `opacityThreshold > 0` is `mask` and an opacity below 1, `blend`. `clearcoat` is a white coat
  with the surface's IOR, as MaterialX builds it. Two materials with the same name: the second is
  named by its prim path; one without `UsdPreviewSurface` is not imported. Images that `usdcat`
  does not resolve are searched next to the file.
- **Lights** UsdLux on the node of their prim, in the units of `Imported_Light`
  ([units](../../mirai-rendering/references/display.md#units)). Luminance is
  `intensity · 2^exposure · color`, times the color of `colorTemperature` if enabled, and with
  `normalize` divided by the area of the light in the world, in stage units. `SphereLight` is a
  `Point_Light` of its radius (0 with `treatAsPoint`) with the candelas of that luminance times the
  area it shows (πr², in m²); `RectLight` is a `Rect_Light` in nits that its size scales, and
  `DiskLight` the square of its area (warning). With `shaping:cone:angle` below 90° it is a
  `Spot_Light` (`softness` gives the inner cone); if it was a rectangle, a sphere that shows its
  area (warning). `DistantLight` is a `Sun` in lux: `intensity` with `normalize`; without it, the
  luminance times the sky disc that `angle` covers (π sin²(angle/2)), as UsdLux defines it. A color
  channel above 1 passes the excess to the intensity. Focus, IES, `CylinderLight`, `DomeLight` and
  the other lights leave a warning.
- **Rejected**: Subdivision, PointInstancer, curves, NURBS, implicit primitives, native instances,
  time samples, `useSpecularWorkflow`, more than one `UsdTransform2d`, readers other than
  `st`/`st1`, shear and prims under a `RectLight` or a `DiskLight`, whose scale sizes it.
  `GeomSubset`, purposes, collections, MaterialX, the scale and bias of `UsdUVTexture` and USDZ are
  not read.

## FBX

FBX 7 (2010 and later), binary and ASCII, through
[ufbx](../../../../third_party/ufbx/UPSTREAM.md), forced to FBX: ufbx does not read OBJ through
this path. FBX 6 files are rejected with their version.

- **Space.** The reader declares that of `GlobalSettings`: `UnitScaleFactor` (centimeters if
  missing) and the axes that ufbx normalizes as right, up and front: the engine's +X is its left,
  +Y its up and +Z its back, half a turn so that the front lands on -Z; V from the bottom. ufbx
  converts nothing: the import bakes it.
- **Hierarchy.** Each node under the ufbx root, with the local transform that already includes
  pivots, pre- and post-rotations and rotation order. Names lose their namespace
  (`mixamorig:Hips` is `Hips`), unless that makes two siblings equal; the path is those names from
  the root and two siblings with the same one are rejected.
- **Scale inheritance.** ufbx keeps it without helper nodes. The engine multiplies scales per axis,
  like MotionBuilder's `RrSs` inheritance, which stays as it is. A node that does not inherit the
  scale of its parent (Maya's segment scale compensate, `Rrs`) carries its scale divided by its
  parent's, in the transform of the node and of the bone and in every key of the clips: the
  position still takes the parent's scale, as in FBX. Where the parent's scale changes, the
  quotient is sampled as ufbx samples a curve and reduced with its tolerance, in linear time; a
  node without curves under a parent that animates its scale receives its scale track. A parent
  whose animated scale reaches zero is rejected. It was only tested with synthetic fixtures
  (`inherit.fbx`), not with files from Maya, Blender or Mixamo.
- **Meshes.** Polygons triangulated with `std/geom`, normals, the first two UV layers, the first
  vertex color and tangents when UV layer 0 brings tangent and bitangent. One slot per material
  index of the faces, with id the index plus one and the material of the instance (FBX gives
  materials per node). The geometry transform (`Geometric*`) is baked into the node's mesh: nodes
  that share geometry, materials and geometry transform share the mesh. Points and lines are
  omitted with a warning.
- **Skin.** One joint per cluster, with `geometry_to_bone` as inverse bind and the vertices as the
  geometry gives them. One skeleton per root node that contains bones, with the ancestors they
  need: the skins of a character share it. Each vertex keeps its eight largest influences and one
  without influences follows the first joint, each case with a warning that counts them.
- **Blend shapes.** Each channel is a morph target with its weight and the full-weight shape;
  in-betweens are counted in a warning.
- **Materials.** From the PBR model that ufbx builds from each shader (Lambert, Phong, Standard
  Surface, 3ds Max Physical, Stingray, Blender's Phong as PBR): base color and factor, metalness,
  roughness, normal map, occlusion and emission relative to exposure, as glTF. In Lambert and Phong
  transparency is coverage: opacity `1 − factor·color` as in the FBX SDK, and its texture counts
  if it is the base color's (its alpha). The other shaders also give specular, IOR, coat and
  transmission, by value. Roughness and metalness, which FBX gives as single-channel images, are
  assembled into a `.Metallic_Roughness` image (red of each to green and blue). The texture of a
  Phong that gives roughness is a gloss one and is left out; bump, sheen, subsurface, rotated
  textures and those of specular, coat and transmission leave a warning.
- **Textures.** Embedded ones by their bytes; the others by the path that ufbx resolves next to the
  model, the stored absolute one or its name next to the model. The UV set is searched by name in
  the mesh; one after the second is rejected.
- **Animation.** One clip per animation stack, which ufbx samples at the scene's frames per second
  (FBX interpolates Euler angles) and reduces where the linear one already repeats the curve. The
  clip is the stack's range: keys outside are cropped with a key at each edge they cross. A
  constant span is a `Step` key; if another channel of the same property moves up to the jump, a
  key one float before stores the value it arrives at. `DeformPercent` of a channel is the `@morph`
  track of each node that shows its mesh, in weight (percentage / 100). A number property that a
  user added to a node (a custom attribute) and the stack animates is a Float curve of its name,
  as animation tools export the curves of faces; the same name on two nodes keeps the first. A stack
  without curves, like Mixamo's `Take 001`, is not a clip.
- **Rejected**: NURBS, trimmed and procedural surfaces, several skins in a mesh and bones of a skin
  under nodes other than the root. Lights and cameras are empty nodes with a warning (FBX gives
  the light no unit), and so are curves.

## Sounds

`cook/import/sound.odin`. `import_sound` decodes the file with `audio.decode` (integer or float
WAV and Ogg Vorbis, mono or stereo) and writes `<name>.sound`, the root of its import
([identity](#identity-and-reimport)).

- **Short: lossless, kept encoded.** Under `SOUND_STREAM_SECONDS` its 16 bit samples, at its
  frequency and channels, are stored `Lossless` (a 16-bit WAV arrives bit for bit; anything else
  is rounded without dither); the mixer keeps that coding in memory and each voice decodes it.
- **Long: streamed.** From that limit it has the `Stream` flag: the mixer decodes it while it plays
  and it is never whole in memory. A WAV whose samples are exactly 16 bit ones is stored
  `Lossless`; an Ogg Vorbis, already lossy, and a WAV that 16 bits would round keep their file as
  is. `Sound_Options` forces a mode or changes the limit.
- **Intact Ogg.** `sound_build` keeps, from the first, the complete pages whose CRC matches: only
  those reach stb_vorbis and the streamed asset, because stb_vorbis does not check a page and, with
  a damaged one, reads outside its memory. With no intact one it is `Malformed`; a cut one keeps
  what precedes the cut.
- More than two channels or a sample format that the mixer does not play is `Unsupported`. A failed
  import leaves no file and creates no folder.

## Fonts

`cook/import/font.odin`. `import_font` writes `<name>.font` with the bytes of the file as is
(LZ in the asset), the root of its import.

- It reads TrueType and OpenType with TrueType or CFF outlines, and before writing it opens it like
  the UI does (`ui.font_init`): what is imported loads.
- It rejects a collection (TTC) saying how to extract a font
  (`fonttools ttLib -y 0 <file> -o font.ttf`) and a web font (WOFF), which must be converted to
  `.ttf` or `.otf`. What FreeType does not open is `Malformed`.
- The report's detail says the outlines and how many glyphs of the atlas it has
  ([coverage](../../mirai-ui/references/ui.md#font)).

## Texts

`cook/import/strings.odin`. `import_strings` reads a UTF-8 CSV per RFC 4180 (`csv_records`) and
writes `<name>.strings`, the root of its import.

- The first row is `key` and the code of each language (`key,es,en,pt-BR`); each following row is a
  unique key and its text in each language. An empty cell is a missing text, and the report says
  how many are missing.
- An error (`Malformed`) names the line: unclosed or stray quotes, invalid or repeated language or
  key, more cells than languages.

## Prompts

`cook/import/prompts.odin`. `import_prompts` takes the folder of a pack or a manifest
`<name>.prompts.json`.

- **Folder** (`prompts_names.odin`): the names of the images and of their folders say what each one
  shows, as Kenney, Xelu and others name them (`keyboard_a.png`, `PS5_Cross.png`). Among the
  variants of an entry the simplest wins: the one with the fewest words that do not say the entry
  (`outline`, `pressed`, an older controller), then the shortest name and then the largest file; a
  modifier without a side counts for both. Images that do not say an entry are left out and a
  notice counts them. `source_kind` takes as a pack a folder in which it recognizes any, so it is
  also imported by dropping it into the editor.
- **Manifest**:

```json
{"entries": [
    {"family": "Xbox", "input": "South", "image": "xbox/xbox_button_color_a.png"},
    {"family": "Keyboard", "input": "Key", "key": "Space", "image": "keys/keyboard_space.png"}
]}
```

- `family` and `input` are named like `ui.Prompt_Family` and `ui.Prompt_Input`, and `key`, only in
  the `Key` entry, like `core.Key`. Keys and mouse belong to `Keyboard`; gamepad buttons, to the
  other families. Images are relative to the manifest.
- It packs each image once, with its border repeated, into sRGB atlases with a power-of-two side
  (`prompts_pack`); the atlases are parts of the `.prompts`, the root, which is written last with
  the `uv` and the `aspect` of each entry.
- Errors that name the entry: unknown family, input or key, an extra key, a family that does not
  correspond, a repeated entry or an image that does not exist or does not decode.

## What it does not do

The model importer writes no scenes (those of a whole source are written by the plugin that
imports it) and imports no USD blend shapes, model cameras or USDZ, and does not compile OpenUSD
(`usdcat` is a precompiled external tool).

The prefab that `import_source` writes (`cook/prefab.model_prefab`):

- Keeps rigid nodes with `Animation_Target.path`, meshes with `Mesh_Renderer` and shared pose
  (`Pose_Source.rig`), and omits bone entities.
- Rigid objects attached to bones receive `Bone_Attachment`, with a socket `bone.<path hash>`
  defined in the `.skeleton`.
- Several roots, clips or skins create a placement root. One skeleton uses that root as the rig;
  several use one rig entity each. The rig draws the first skinned mesh of its skeleton and the
  others follow it with `Pose_Source.rig`.
- With clips it adds `Animation`. Invisible nodes keep `Hidden`.
