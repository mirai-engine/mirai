# Import: current behavior

Packages, all *engine-time*:

- `cook/import` (`import importer "mirai:cook/import"`, because `import` is a reserved word): the
  core. The imported model, the `Reader` a format reads with, the source space, the PBR
  conversions, the asset writer, the settings, loose images, sounds, fonts, strings and prompt
  packs. It knows no model format.
- `cook/import/obj`, `cook/import/gltf`, `cook/import/usd` and `cook/import/fbx` (on top of ufbx):
  one format each, with its `FORMAT`. They import the core and nothing from the other formats.
- `cook/import/sources`: the `FORMATS` table (the engine's formats), `source_kind` and
  `import_source`, used by the [library](#library) (`ingest`, `project_ingest`, `project_add`,
  `project_refresh`), through which the editor (`editor/import.odin`) and `mirai import`
  (`command.odin`, in the engine's `mirai-import` program) import. The editor adds the formats of
  plugins ([plugin formats](#plugin-formats)).
- `cook/textures`: images to `.tex` levels.

## API

- `sources.import_source` imports a file of the assets folder of a project or a plugin: a model
  writes its assets and, if it has nodes, its prefab; an image, its `.tex`; a sound, a font or a
  prompt pack, its asset. The [package](#identity-and-reimport) of the source in the store keeps
  its settings and the id of each asset: importing it again gives the same assets. The
  [library](#library) ingests sources, pins them in projects and refreshes their builds.
- `sources.source_kind` says what a file is from its first bytes ([sniffing](#formats)), except
  what the signature does not settle: TGA by extension and prompts by `.prompts.json`. It
  carries the formats it searches with (`formats`, `FORMATS` by default), like `model_folder`
  and `import_source`. Only models and images have [settings](#settings-of-a-source).
- `importer.import_model` reads a source with the first of the formats that recognizes it
  (`sources.FORMATS[:]` or those of a test) into an `Imported_Model` in its own arena
  (`model_destroy`); `importer.import_write` writes its assets and returns the `Import_Report`.
  `prefab.model_import` does both with the prefab (`cook/prefab.model_prefab`).
- `Outputs` (`output_root`, `output_part`, `output_model`, `output_input`, `output_written`): the
  assets of an import that is not that of one model (a scene, a source a plugin imports whole) are
  those the package of their source lists, like those of a model: the root by its kind (and its
  name when the package lists several of the kind) and every other by kind and name. The caller
  writes each to the file its part gives and `output_written` takes it; `outputs_end` puts the
  manifest and the build in the store. `output_model` writes a model as parts of the import with
  the writer of `import_write` (cooking ahead, Fast textures, taken objects, the caches); its prefab
  is a scene of the model's name that the caller writes with `prefab.model_prefab`. A part whose
  kind and name the import already gave is that asset, written once: two models that name the
  same material or texture share it. `output_input` lists a file the import reads in the package
  and in its identity; every input comes before the first output of the cache, which fixes it.
- For engine-time tools: `mesh_levels` ([levels](#levels-of-detail)) and the PBR conversions of
  `pbr.odin`.
- `Error` is `{code,message}`; `message` lives in the caller's `temp_allocator`. `Import_Options`
  carries the settings and how they apply: `ignore_stored`, `store` (required), `manifest` (the
  package to ingest again), `documents` (the folder of a project its documents go to), `root` and
  `registry` (the project and its scanned assets, where documents are found by id), `rebuild`,
  the caches and `worker` ([in parallel](#in-parallel)).

## Formats

`importer.Format` describes a source format; each package declares its own as a constant
(`gltf.FORMAT`, `obj.FORMAT`...) and its own options travel in `Format.data`
(`usd.format(&options)`).

- `extensions` is an array and not a slice: a `Format` is copied and the copy keeps its
  extensions.
- `version` is the version of what `read` returns for the same bytes: it goes up when that changes,
  and assets of another version are rebuilt when importing again.
- `space` is the `Source_Space` of its files, unless `read` declares another.
- `folder` says the folder beside a file its first import puts its assets in; without it, the stem
  of the file.
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
- **In materials**, with `Bottom`, the mapping of each map is conjugated by the inversion of v; the
  identity stays the same, with no negative zeros.
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

Besides `sources.FORMATS`, the plugins of a project provide two kinds of importer in their editor
part ([extension](../../mirai-editor/references/extensions.md#importers-of-a-plugin)):

- `Import_Format_Provider{format}` is one more `importer.Format`: it is imported like the engine's,
  with the same storage (the cache and the documents, [identity](#identity-and-reimport)).
  `Format.folder` says the folder of its assets. Its extensions are in the Models filter of the
  dialog. Its `prepare` gives the format's options for an import (`Format.data`) from the store of
  the library, the root the import is for and the types of its game, and `release` frees them
  when it ends.
- The editor imports with the providers of its session, which it prepares and gives the library
  (`Library_Options.imports`); the import program of the engine (`mirai import`, the
  [refresh](#library) of every build) loads the editor library of the project and takes the same
  providers from it with its store (`editor.import_library`, `sources.Library`), only when a
  source is read by no format of the engine or a model imports, whose prefab is written in the
  types of the game the library has. `mirai import` builds a missing or stale editor library
  before importing. This preparation leaves package refresh and library loading to the import
  program.
- `Import_Source_Provider{source}` is a source that the plugin imports whole with `Outputs`: it
  is the single source of every asset it makes (a scene, the models it reads with
  `output_model`), and the files it reads besides it are its `inputs`, like the `.bin` of a glTF.
  It appears with its name as a filter of the dialog and claims a file with `claims(path, head)`
  before the formats. Its `name` is the importer its packages record (the `importer` its run gives
  `outputs_begin`) and its `version` the one its run gives `import_version`: with the identity of
  the plugin's code they make the key of a build (`importer.build_key`), so a machine with the
  plugin and without the source finds the build by key, and a changed importer builds again. The
  import program takes these importers from the same library and the [refresh](#library) runs
  them. The Unreal content importer is the `unreal` plugin of the catalog
  ([git plugins and catalog](../../mirai-plugins/references/plugins.md#git-plugins-and-catalog)).

## Import cache

The `Import_Info` of each asset says what it was built from: source (relative to its package: the
name of its file), name,
index, size and hash of what was read (the source; the image of a texture; the mesh as read, with
its slots, joints and skeleton, of a mesh), version and `settings_hash`. It is not what identifies
the asset: the [package](#identity-and-reimport) is.

- `importer_version` combines `IMPORTER_VERSION` (the writer) with `Format.version`
  (`import_version`); loose images and sounds use format version 0.
- `settings_hash` is the identity of the settings that make that asset, and of no other, with
  what builds them: for a mesh, its levels, front and rig with `MESH_CACHE_VERSION`
  (`mesh_build_hash`); for a texture, its `Build_Options` with `BUILD_VERSION` and the block
  encoders (`textures.encoders_id`); for a sound, whether it is `Stream`. Materials, skeletons and
  clips store 0. Changing a texture setting keeps the meshes, and one of the meshes, the textures.
- What is current is a ref lookup: `import_write` takes the object a build of the package has for a
  mesh or a texture (`Written.kept`), from the build of the key of what the import is made from
  now, else from the build this machine chose for the previous manifest, when the object is of the
  version its kind is written in, has the `owner` decided now and its `Import_Info` is what the
  import records now: a change that does not reach it (the code of a plugin, a setting of other
  assets) neither builds nor writes it. It builds nothing ahead when the build of the key has
  every output of the cache. A texture of an import of fast textures takes one built Fast only
  while the texture cache holds no Final of it. Materials, skeletons, clips and prefabs, which
  are cheap, are always written, also with `rebuild`.
- A change of writer or format version, of a kind version or of the builder of textures changes
  the key (`asset.import_key` of the identity and `import_versions`); one of the source, an
  input, the settings or the code of the plugin that imports it whole changes the identity too;
  `rebuild` (`mirai import --rebuild`) rebuilds everything.

## Identity and reimport

An import ingests its source as a package of the store
([packages](../../mirai-assets/references/formats.md#packages)), from wherever the source is: in
the assets of a project, of a plugin or in no project. Its manifest is what identifies the
import: the origin (where the source was, a hint), the identity (`identity_of`: the package, the
bytes of the source and its inputs, its settings and the code of a plugin that imports it whole,
no engine version), the settings, the inputs and one asset per thing the source gives, by kind,
name and index, with its id, owner and dependencies. Nothing else decides an id: the first ingest
gives each part a random one; importing again (`Import_Options.manifest`, else the manifest the ref
`origins` of this machine names for the path of the source) gives each part the asset it had. A
manifest that does not read is an error that names it, never the defaults nor new ids.

What an import writes is an object of its build (`writer_put`, `asset.object_put`), whatever the
format that reads the source, the engine's or a plugin's; each part is written to a scratch file
first, and the store dedupes its chunks. Objects never change in place and are the same on every
machine: the source an asset names is relative to the package, a changed owner is a new object.
`Written.path` is the file of a document, and an output of the cache has only its object
(`written_open` opens either; `mirai import` prints `object <address>`). An import writes with
`Codecs.None` ([compression](../../mirai-assets/references/formats.md#compression)), so its
objects never depend on a compressor and every engine of the same formats reads every build. The
build lists the object of each output and whether it is Final: the import key leaves the encoders
out, so engines with either compressor share builds, from their store or a source. It is named under
`imports/<key>` when Final, else under `imports-fast/<key>`, and as the build
this machine chose (`builds/<build_select>`), which a program without importers finds. Of two sorts
(`asset.import_cached`):

- **The cache**: meshes, textures, sounds and fonts. Nothing edits them after the import: the
  project lists them from its packages.
- **Documents**: materials, prefabs, skeletons, clips, texts and prompts. The build keeps them as
  the source gives them (their baseline); a project edits a file of each, written or followed in
  a folder of its assets by `documents_follow` (`cook/import/documents.odin`), or by the import
  itself when given `documents`: found by its id in the registry of the root wherever a person
  moved it, else a new file there ([what is written](#what-is-written)). The prefab of a model is
  written in the types of the game, by the caller, at `Import_Report.prefab_path`.
- **A name with `/`** is a folder under that of the documents: each part made safe
  (`asset.safe_path`), without empty, `.` and `..` parts.

- **The root** of an import is the prefab of a model, the texture of an image or the sound of a
  sound, without `owner`: the asset of its kind the package lists. A model with nodes that has
  none receives a new prefab.
- **A part** is the asset of its kind and name (among equal names, the one of its index); one the
  package does not list is new. A part renamed in the source is a new asset: what named the old
  one does not silently get another. An asset the source no longer gives leaves the package with
  a warning; a document of it stays in a project as a plain asset.
- **An import never touches another.** Two models that embed the same image get a texture asset
  each; the [texture cache](#texture-cache) keeps one encoded copy. No import writes a document
  or a package of another source. Decided by the owner.
- **The textures of a model** name the model as source and the image as name, with the size and
  hash of the image.

### Changed documents

An import never writes over a change it did not make without being told to. The project's pin
records, for each document of a package whose file the import or the refresh writes over, the
`content_hash` of that file's header as it last wrote it (`asset.Package_Written`): a fact of the
project, never of the manifest. The registry already has the hash of each file, so finding what
changed (`importer.documents_changed`) reads no document. A change of owner alone
(`asset.detach`) is none. A material records nothing: the import follows its source only where
nobody changed it.

- `Import_Options.changed` says what an import into a project does with a changed document:
  `Refuse` (the default) writes nothing and fails with `Error_Code.Changed`, naming the files and
  how to go on; `Discard` writes over them, with what its writer keeps of a person's (the body
  parts and sockets of a skeleton, the roots of clips); `Keep` leaves them as they are, imports
  the rest and warns of each. The objects of the build are written either way.
  `discard_changes` of `asset.import`, `--discard-changes` of `mirai import` and the question of
  the editor are `Discard` (`Library_Options.changed`); a [refresh](#library) and the follow of a
  package added are `Keep`, so a build never loses an edit and still builds the package.
- A document kept keeps what the pin recorded, so it stays changed until the changes are
  discarded; the prefab of a model it keeps has no `prefab_path`.

### Parts

The `owner` of an output says that the content browser shows it inside the model's prefab. Only
what surely belongs to that model is a part; what is doubtful stays independent and visible
(`cook/import/parts.odin`).

- Its meshes and skeletons are always parts; its clips and the textures that no material uses, not.
- A material is a part (`Parts.Auto`) only if all of this holds, in this order:
  1. it has textures;
  2. a single mesh of the model uses it;
  3. all the UVs of its triangles, where its map puts them (like the renderer), fall in 0..1 with
     the slack `PARTS_UV_SLACK`: what an exporter that crops its atlas leaves;
  4. no UV island reaches from one edge to the opposite;
  5. rasterized on a grid of `PARTS_GRID` per side, they leave at least `PARTS_MIN_UNUSED` unused;
  6. its base image (or its normal, or the first it has) does not tile at its edges: on no axis does
     the difference between opposite edges exceed `PARTS_SEAM_STEPS` times the mean step between
     neighboring interior pixels while the edge varies along itself by at least
     `PARTS_EDGE_CONTENT` of a step. A flat edge, the padding of an atlas, says nothing.
- A texture is a part if some material uses it and all those that use it are parts.
- `Written.detail` of each material says why: `part of manny: UVs inside 0..1, 38% unused,
  edges do not tile` or `of its own: <the first condition that failed>`.
- **It is decided once.** A document keeps the `owner` its file has: a part taken out of its owner
  (`asset.detach` in the editor, which only clears `owner`) is still an output of the import, which
  writes it and leaves it outside. An asset keeps what its package says (`part` of the cache,
  `owner` of a document). Only `parts` decides it again.
- `Import_Settings.parts` (`mirai import --parts auto|all|none`): `Auto` the above; `All` makes
  parts of all the materials and textures of the model, and `None` of none, also of those that
  already existed.
- A copy made outside the editor is left without `owner` and without `Import_Info` when it receives
  an id of its own: no import writes it
  ([repeated ids](../../mirai-assets/references/formats.md#registry)).

## Library

The library of the machine is what its store keeps of imports and what a project does with it
(`cook/import/sources/library.odin`). A project names the packages it uses in its
`packages.mirai` and carries the text of their manifests beside it
([packages](../../mirai-assets/references/formats.md#packages)); the store, shared by every
checkout, worktree and project of the machine, keeps manifests and builds.

- **`ingest(origin, options, settings)`** imports a file or a folder from wherever it is: in the
  assets of a project or a plugin, or in no project. Nothing is copied: the package goes to the
  store, named by `packages/<id>` and by its origin (`origins/<origin_name>`, of this machine
  alone), so ingesting the same origin again keeps its ids. `settings`, when given, replace those
  the package keeps. A source whose identity is that of its package and whose build this engine
  reads is not imported again: the report names its package and lists no assets. Two processes
  or worktrees that ingest one origin take turns with a lock per origin (`cook/workspace`, under
  `<store>/locks/`), and the second finds the work done.
- **`project_add(root, manifest, folder, assets, options)`** pins a package in the project and
  follows it there; `project_ingest` ingests a source and pins its package in one import.
  With no destination given, it uses the source's parent within the destination's assets, or
  the root of the assets for a source from outside. A whole-source importer's document folder
  goes under that destination.
  **Following** writes
  or follows its documents under `folder` of the assets: from the baselines of its build
  (`documents_follow`), and for a model whose source is here and whose game types the library
  of the project's editor gives, by importing it with that folder, which also writes its prefab
  (`prefab.model_prefab`). Without the source or those types a model's prefab cannot be written,
  and the report says so.
- **Adding a Store folder** resolves the exact manifests and their builds before following the
  documents, and keeps the destination of an existing pin when adding its remaining assets.
  It publishes all pins together in `packages.mirai`. A write failure restores the previous
  manifests and documents. Adding, ingesting and refreshing share one write lock per project.
- **`project_refresh(root, options)`** takes each package the project pins to a build this engine
  reads. A manifest the store lacks comes from the root's file of it, else from the caller's source;
  so a clone with its sources and an empty store ingests every package again with the same ids,
  manifest and key, and one without them reports each package. The key (`asset.import_key` of the
  identity and the versions of what reads its origin, an engine importer or a format of the engine
  or of the plugins) is looked up in `imports` (and `imports-fast` with `fast_textures`), then asked
  of the caller's source (`cache.Source`, the same procedure value the caches of `cook/cache` take:
  given `(imports, <keys>)` or `(imports-fast, <keys>)` it makes each build and every object it
  lists whole, given `(packages, <ids>)` the manifests; it takes many names at once, and a refresh
  asks every key and id it will need in one call before it goes package by package, `imports-fast`
  only with `fast_textures` and for the keys the source gave no Final of). When Final is required,
  a current local Fast build can supply it. The refresh keeps its outputs and encodes any Fast
  textures from the [texture cache](#texture-cache). If it lacks an input, it ingests the origin
  when available, or reports the missing build by package name. It names the chosen build under
  `builds/<build_select>` and, when that
  changed, follows the documents. A source here whose identity changed (its bytes, an input, the
  code of the plugin that imports it whole) is ingested again with the ids its manifest gives, and
  the project pins the new manifest. A document changed since it was last written is left as it is,
  with a warning that names it ([changed documents](#changed-documents)): the rest is written.
- **It never removes** an object, a ref or a file of a project because a source is missing. What
  it cannot build or fetch stays listed as not built.
- A source a plugin imports whole has a key only its importer knows: the refresh takes the build
  this machine chose for its manifest, and a machine without its source reports it.
- **Source hashes.** The address of each file an identity reads is kept per origin by size and
  modification time (`importer.Source_Hashes`, `sources/<origin_name>` in the store), so a
  refresh reads only the files that changed. A USD is composed by `usdcat`, which does not say
  which layers it read: after changing one alone, ingest the stage.
- **Progress.** `Library_Options.progress` gets a line per package and per source imported, and
  the assets written every `importer.PROGRESS_EVERY`.
- **Commands.** `mirai import <file>` ingests and adds to the project of `--project`, else the
  one whose assets hold the file, under `--folder` (else the folder of the file); `mirai import
  --refresh <root>` refreshes a project or a plugin. Both build textures Fast and take a Fast
  build, as the editor does. `--final` requires Final. Add `--release` to use the optimized
  importer for that encode. Use `--from <folder>` to name a second store as its source
  (`cache.store_source`, which copies a ref with its objects,
  as a peer gives them); an installed engine takes its `builds/` store as that source. Every
  build of a project refreshes it and its plugins with a `packages.mirai` once its target stands
  (`build.job_imports`, `imports_refresh`) with the engine's import program, which reads the
  formats of plugins from the editor library just built.

## In parallel

What costs most to write a model is built apart from writing it: `model_cook` first builds the
levels, clusters and colliders of each mesh (`mesh_cook`) and the levels of each texture
(`texture_cook`), one `Import_Options.worker` job each, in the arena of its `Cooked_Mesh` or
`Cooked_Texture`; `import_write` takes what was built for its settings and builds what is missing
when it gets to it, with the same functions. Ids, files and parts are decided on a
single thread and in the usual order: with or without a job system the same bytes are written.

- Finalizing a cached Fast build bounds the number of textures in flight by the worker count.
  Each frees its scratch after writing its object. The Final build is published in the original
  output order after all textures succeed.
- An import builds beforehand only the meshes and textures whose files it does not keep or take
  under another key, except with `rebuild`; a whole source that reads its models ahead asks
  `outputs_current` (every output of the cache has its file, under the key of now or another)
  before cooking them.
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
- The imports of a refresh share `Import_Options.registry`, which finds documents by their ids: one
  scan of the root for all of them.

### Texture cache

What matters about a built texture does not depend on its id or its path: `cook/textures/cache.odin`
keeps it by content in the cache `textures` of the machine store (`cook/cache`), one texture per
key whose id is the key. Every project, worktree and program of the machine shares it, and a
machine that shares the store's objects with another finds what that one built.

- `cook/cache` keeps each result as an object of `mirai:store` (`asset.object_put`) named by the ref
  (`cache-<name>`, `<key>-<version>`) (`asset.cache_namespace`). The store reaches it as a value
  (`Import_Options.store`, `Cook_Desc.store`; nil, none): the editor's
  imports (the session's: `--store`, else the machine's), `mirai import` (the machine's store, or
  `--store`) and the cook of a build (that of the build: `--store`, else the machine's). Tests
  make one in a temporary folder.
- A miss asks `Import_Options.cache_source` (a `cache.Source`) once before building: it makes the
  object whole in the store and sets the ref, or says it has none. What a pass needs is looked up
  at once (`cache.lookup`): the cook asks the source in one fetch for the textures of its pass and
  its jobs then read the cache without asking.
- A texture that is not kept looks for its `textures.cache_key_build` (the bytes of the image, or
  the texels the format made with their size, layers and format, and the `settings_hash`): if it is
  there, its levels are written with the id and the `Import_Info` of this import; if not, it is
  built and stored. The same image from another source, in another folder or with the settings of
  before is not compressed again. `rebuild` does not read the cache and rewrites it.
- With `Import_Options.fast_textures` (the editor's imports and `mirai import`) a
  texture of the cache takes the Final
  the texture cache keeps for its key; without one it is built Fast under the key of Fast settings,
  and a texture kept Fast is written again as soon as the cache holds its Final, or by the
  [refresh](#library) of a release game build. When it writes a Fast texture, the importer caches
  its lossless texels and settings under the Final texture's key. The texture records that key
  so Final refresh can reuse a cached encode or build it without running the source importer.
  Only textures with Fast blocks require finalization.
- [Cooking](../../mirai-projects/references/build.md#asset-cooking) stores there the blocks of
  an RGBA8 texture by `textures.cache_key_blocks`.
- A key names what made the blocks (`textures.encoders_id`), so machines with other encoders
  share the store without sharing results.
- A read checks the id (key and version) of the asset and reads its chunks: a ref whose object is
  not whole here, does not read or is of another version is a miss and is built again. The store
  checks its chunks (its scrub), not the cache.
- A result belongs to no asset and `cook/cache` removes none: the store owns space, and what goes
  is decided by the live set given to `store.sweep`.
- An image only its format decodes (`Imported_Image.make`, added with `importer.image_made`) is
  keyed by its `data`, what the format makes the texels of: a texture the cache keeps for it is
  written without decoding it, and the format raises a version inside its data when the same data
  would make other texels.

### Mesh cache

A built mesh is worth by its geometry as read and its settings, not by its id: `mesh_cook` keeps
it in the cache `meshes` of the machine store (`importer.MESH_CACHE`, the same `cook/cache` and
`Import_Options.store` as the texture cache), one mesh per key with its levels, clusters and
colliders, without materials.

- The key (`mesh_cache_key`) is the content of the mesh as the reader gives it (vertices, indices,
  skin, submeshes, morph targets and flags: `mesh_content_hash`) with `mesh_build_hash`; the
  file's id carries `MESH_CACHE_VERSION`, from `IMPORTER_VERSION`, `MESH_VERSION` and the version
  of the settings key: a change of the writer, the format or that key does not read what came
  before.
- A mesh that is not kept looks for its key; if it is there, it is written with the id, the slots,
  the skeleton and the `Import_Info` of this import, the same bytes as building it. `rebuild` does
  not read the cache and rewrites it.
- It saves simplifying, the cluster DAG and the pages; reading the source, no.

## Settings of a source

`Import_Settings` is how a source becomes assets; its zero value is the default of each setting and
its fields are the options of `mirai import` (`IMPORT_USAGE`). The package keeps only the settings
that differ from their default, so it shows what was chosen. What is not obvious:

- `image` says how a loose image is read; `Normal_Green_Down` is a normal map with green pointing
  down, as DirectX writes them, which is inverted when cooking. `alpha_coverage` is the cutoff of
  the `mask` material that samples it: each level keeps its [coverage](#textures-cooktextures).
  The images of a model take the cutoff of their materials.
- `rdo_lambda` is how much error the [encoder](#textures-cooktextures) of textures in blocks
  trades for files that compress smaller: zero is the default lambda and a negative value, which
  `--rdo-lambda 0` writes, the least error.
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
  `r.options.settings` (the settings the import applies, those of its package when it was
  ingested before): a format whose clips keep no skeleton of their own (Cast) reads that
  `.skeleton` to bring its keys to the frames of its bones, and adds its bones as a skeleton of
  the model, which is not written.

Settings live in the [package](#identity-and-reimport) of the source, one entry per field name (an
absent field is its default), and win over the options except with `ignore_stored`: importing a
source again gives the same assets whoever does it. Unreadable settings (unknown field or value,
negative number, coverage outside 0 to 1) are `Malformed`, never the defaults. Every import puts
its manifest in the store when it ends.

## The imported model

`Imported_Model` is plain data, without engine components. A rigid mesh is in the space of its node
and a skinned one keeps the bind geometry; nodes go parent before child, with their local transform
in [engine space](#source-space). A skeleton is also extracted from a skinned source without
geometry (an export of Unreal clips), and a glTF with only clips is an importable model. A single
node with a mesh is not promoted or wrapped: whoever builds the prefab decides. Materials are only
those a mesh uses; repeated names are told apart with `name (n)`.

## What is written

Every output is an object of the build. In the folder of the documents, a new document gets a flat
file (`<name>.mat`, `.skeleton`, `.anim`, a plugin's kind with the extension its manifest declares
and, with `import_source`, the model's `.scene`), with a
valid file name that does not overwrite another asset; one that already existed is followed where
it is ([identity](#identity-and-reimport)).
Each imported asset carries the `Cooked` flag and its `Import_Info` ([cache](#import-cache)).

- **Ids and owner.** Random the first time and those of the package afterwards; the
  [parts](#parts) name their prefab as `owner`. Dependencies come from the `Asset_Id`s that each
  asset names.
- **Compression.** Texels go in BC blocks ([textures](#textures-cooktextures)); the bulk columns of
  a mesh and the levels of a texture go compressed
  ([compression](../../mirai-assets/references/formats.md#compression)).
- **Materials.** The `.mat` stores in `imported` what the source gives and in `material` what the
  material is ([two layers](../../mirai-assets/references/kinds.md#material)). Over the file of the
  previous import it rewrites `imported` and follows the source except in the fields that differ
  from what it gave before (`asset.material_follow`, the algorithm of prefab overrides); the
  parameters of a program stay the same by name, and `overlays` and `hidden` are kept: what was
  changed after importing stays and a new texture of the source arrives. A skeleton keeps the body
  parts set by hand and the sockets added on bones it still has, and a clip the root set by hand
  while its bone is in its skeleton. A document keeps the `owner` its file has. The follow starts
  from the baseline: the grips of a hand are those of the body found on the bones.
- **Images that cannot be used** leave a warning and the map without a texture; a loose image that
  does not decode fails. If `import_write` fails, it deletes the documents it created in that call
  and names nothing; what already existed is replaced one at a time with atomic writes.
- `Written.detail` says what each asset has (triangles per level and colliders of a mesh; format,
  size and mips of a texture; entities of a prefab), also for a kept one.

`mirai import <file>` is `import_source`, in the `mirai-import` program that the engine build
leaves next to the editor: the importers are engine code, and the tool compiles without them. The
file is in the assets folder of a project or a plugin; it imports where it is.

- It first builds the engine if it is not up to date, in dev unless `--release` is given;
  what that build says goes to stderr and stdout is left with the report.
- It starts from the settings of the package of the source, applies the given options
  (`IMPORT_USAGE`): repeating the command without options gives the same assets. A source a format
  of a plugin reads takes the formats of the editor library of its project.
- The report gives one line per asset (`id kind bytes path (detail)`), how many were already up to
  date and the warnings. Exit codes: 0, 1 (failed) and 2 (usage).

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
their border locked and split again up to the roots, with the cuts that its distant rays trace. Its
foliage is pruned in the DAG too (below). One with skin stores simplified levels after level 0 (up
to `LOD_MAX` in total), each with its own vertices, which `asset.mesh_build` encodes as whole
levels (flag `Levels`, `geom.cluster_levels_build`): clusters that share the sphere of the mesh, so
that a view chooses only one ([mesh](../../mirai-assets/references/kinds.md#mesh)). With
`lods=None`, level 0 alone is stored. What follows describes those whole levels; the
[DAG](../../mirai-std/references/geom.md#clusters-and-dag-clusterodin-partitionodin-cluster_dagodin)
simplifies with the same weights and locks, and crosses seams where they stop it as they do.

- **Level 0.** The source's. Its error (`Mesh_Lod.error` of level 0) is how far the outlines of
  its cards draw from what their masks keep; its clusters keep an own error of 0, so a view however
  near draws it.
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
  crossed. If that still keeps more than `LOD_KEEP` of the level before (faceted pieces, a seam on
  every edge), it runs once more crossing every seam but the outlines between materials, with
  `Error_Clamped`, and the error of the level counts what its attributes lose.
  `asset.mesh_simplify_inputs` builds those inputs once for the importer.
- **Attributes.** Every vertex of a level is a vertex of level 0 as is, with its skin and its morph
  deltas; only pruned islands move.
- **Foliage pruning** (Cook et al., *Stochastic Simplification of Aggregate Detail*, Pixar 2007).
  An island is a piece of a submesh that shares no position with the rest. A submesh is of islands
  if it has at least `ISLANDS_MIN` small islands: leaves and cards, of up to `ISLAND_MAX_TRIANGLES`
  and of `1/ISLAND_MAX_SHARE` of its triangles. Those islands are not simplified by quadrics, which
  shrink them to nothing: they are split into classes by octave of radius below the largest of
  their submesh (up to `ISLAND_CLASSES`), in a fixed order (a hash of its first triangle, spread
  over the submesh), and `geom.islands_reduce` prunes them
  ([islands](../../mirai-std/references/geom.md#islands-cluster_islandsodin)): of a static mesh
  group by group of its DAG, of a skinned one all of them at each level, which it takes as far as
  the error that the rest already has simplified allows, and further while the level would keep
  more than `LOD_KEEP` of the previous one. The rest of the submesh (trunk, body) is simplified
  like any other. Bushes of hundreds of triangles are not small islands: quadrics simplify them
  with less error than pruning them. Only the levels of `lods=Auto`.
- **Cards cut to outlines.** A card of a masked material (see [masked cards](#masked-cards)) is
  one island whatever its outline holds; its rungs are the outline level 0 draws and the coarser
  ones of its cards (`Mesh_Outlines`), which it steps through before it is pruned.
- **Error.** `Mesh_Lod.error` is how far the simplifier moved the surface of level 0 (its position
  error, and that of the attributes where it crossed seams), in object units; with islands, the
  larger of that and of the errors of its islands. The renderer takes a level where its projection
  falls within `lod_error_pixels` and that of the next does not
  ([cut](../../mirai-rendering/references/scene.md#scene-and-instances)).
- The triangles of a level are grouped by submesh of level 0, with its slot and its box.

### Masked cards

A masked card is drawn opaque, cut to the outline of its mask, when it is read
(`cook/import/cutout.odin`, `cook/import/outline.odin`), for every format; no setting turns it off.

- **A card** is an island of at most `ISLAND_MAX_TRIANGLES` of a submesh, however many islands it
  has, whose material is `Mask` with a mask image, every corner of it opaque in its color, laid on
  the image without folding over at most two periods of it (the image repeats, as the material
  samples it). The mask of a material is the image of its mask map (`images[.Mask]`, which a format
  that knows what a program's opacity reads bakes), or of its base color map without one, program or
  not (`material_mask_image`). Cards of skinned and morphing meshes are cut too: a vertex of an
  outline takes the influences (the eight strongest) and the target deltas of the corners of the
  card triangle it lies on, weighed by where it lies.
- **Outlines.** Of the rectangle of the image a card covers, the texels whose alpha times the
  opacity reaches the cutoff; conservative outlines of them from `OUTLINE_FINEST` texels to a
  convex quadrilateral, each with its measured error (the farthest texel it draws from one the mask
  keeps). Cards on the same rectangle share them. An outline is laid on the card through its
  triangles, one facet per flat run of them, so a bent card stays bent. A rectangle wider than
  `OUTLINE_MASK_SIDE` is cut on cells of several texels, each kept where any of its texels is,
  its error grown by a cell; the cut works in at most `OUTLINE_WORK_BYTES` a cell, given back as
  it ends. Without that memory a card keeps its mask, and the model is cut whole or not at all.
- **Leaf or cluster**, from the mask: a card whose outline needs at most `OUTLINE_TRIANGLES` to
  draw at most `1/OUTLINE_COVERAGE` of what the mask keeps is a leaf; any other keeps its mask on
  its tightest convex outline of up to eight corners. So does a leaf whose finest outline draws
  past its mask more than `CUTOUT_LEAF_ERROR` of the radius of its mesh: level 0 is drawn however
  near, and the few large cards of a houseplant would show outlines where the mask shows gaps
  between leaves. A card whose rectangle keeps nothing is dropped. The outlines of a leaf draw at
  most `OUTLINE_TRIANGLES` each: level 0 draws the finest of them with its error, and the
  [levels](#levels-of-detail) the coarser ones.
- **Materials.** Cut cards are seen from both sides (`two_sided`). A material all of whose
  triangles became outlines is `Opaque`; one that also keeps masked triangles stays as it is and
  lends an opaque copy, `<name> outline`, to a slot of the outlines (`CUTOUT_SLOT` added to the id
  of the slot). The base color image of the outlines fills what the mask left empty with the color
  of the nearest texel it keeps (`Build_Options.alpha_fill`), so no dark rim shows at their edge.

## Collision

The colliders that the source authors are the `asset.Collider` rows of the `.mesh`, in the space
of the mesh it collides for; the import makes none of its own, and a mesh whose source authors none
has none. A format reads what it holds into `Reader.colliders` (`Source_Collider`, in the space of
the node it is at) and `colliders_resolve`, after the read and before the source space is baked,
adds what the names of nodes say, places each in the space of its mesh and takes the nodes that
are collision only, and the meshes only they show, out of the model:

- Names, in every format: `UCX_<mesh>[_n]` a hull of each piece of its geometry that shares no
  position with the rest, `UBX_` the box it is (three pairs of parallel faces), `USP_` the sphere
  it is, `UCP_` the capsule around it (along its two farthest points); a fit that fails is its hull,
  with a warning. The mesh is named without case, whole or without what follows its last `_` or
  `.`; with one drawn mesh, that one. `-colonly`/`-convcolonly` (also after `_` or `$`) are the
  triangles or hulls of a node for the nearest mesh, `-col`/`-convcol` those of its own mesh, which
  stays drawn.
- glTF: `KHR_physics_rigid_bodies` colliders with `KHR_implicit_shapes`, and `OMI_physics_body`
  with `OMI_physics_shape`; a mesh geometry is a hull with `convexHull`, else triangles. A tapered
  capsule and a cylinder are hulls of their points; planes, triggers and motion are warnings.
- USD: a prim with `PhysicsCollisionAPI`: a `Mesh` as its `physics:approximation` says (triangles
  without one, `convexDecomposition` a decomposition the source asks for), collision only with
  purpose `guide` or invisible; `Cube`, `Sphere`, `Capsule`, `Cylinder` and `Cone` as that shape.
- A plugin's format fills `Imported_Mesh.collision` itself (`unreal`, from the `BodySetup`).
- A collider with no named mesh is for that of its node, the only one below it, or the nearest
  ancestor's; one that finds none is a warning.

The prefab of a model gives an entity an `Auto` `Collider` only when its mesh has them. What a
collider of a mesh without them is made of (its triangles, or convex pieces of them for a body that
moves) is derived at run time and cached, or by the cook:
[host](../../mirai-core/references/host.md#loaded-assets) and [the physics
libraries](../../mirai-physics/references/engine.md#collider-fields).

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
- **Size**: a side above `asset.TEXTURE_MAX_SIZE` is `Too_Large`, and the image is not used; the
  rest is kept whole, and what the view loads is the renderer's.
- **Format** (`stored_format`), decided by the whole source image before reducing it:
  - `.Uncompressed`, or a 16-bit or float source with `keep_precision`: what the source has,
    `RGBA8`, `RGBA16` or `RGBA16F`.
  - In blocks, by use: normal map, BC5 (the shader reconstructs the third channel); a float source
    is HDR, BC6H unless some texel is not opaque or has a negative channel, which BC6H does not
    store (`RGBA16F`); color and data maps with non-opaque alpha use BC7; opaque data maps use BC1.
    A 16-bit source without `keep_precision` is compressed by use like an 8-bit one.
  - It is stored linear except in 8-bit formats with `srgb` (`level_store`).
- **Block encoding.** Open builds use the Slang compute encoder. A cook or import shares one
  context for pipelines and buffers, and the editor reuses one across its background imports.
  The context opens a headless GPU device at the first block encode. Decoding sources and
  building uncompressed textures need no device. Final encoding can trade distortion for
  repeated block data that compresses smaller. Fast skips rate-distortion optimization.
  The private compressor can supply its own block encoder and layouts.
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
  as Blender exports), `d`/`Tr` (less than 1 is `blend`: coverage, or with a glass `illum` (4, 6,
  7, 9) transmission `1 − d` and `Ni` as its IOR), `map_Kd`, `map_Ke` and
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
  viewers show 1 as the display white), `alphaMode`, `doubleSided` (`two_sided`),
  `KHR_texture_transform` per map and the extensions transmission, ior, volume, specular, clearcoat
  (a white coat of IOR 1.5), diffuse transmission (from the JSON: cgltf does not read it) and unlit
  (emits its base color). A material without metallic-roughness is a rough metal; a map that asks
  for a missing `TEXCOORD` rejects the import.
  - Specular-glossiness goes through `importer.specular_glossiness`, like the Khronos converter;
    with its texture it becomes a dielectric with a warning. An index of refraction of 0, the
    compatibility mode of `KHR_materials_ior`, is converted the same way
    (`importer.ior_zero_convert`): a material holds no such mode.
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
  `opacityThreshold > 0` is `mask` and an opacity below 1, `blend`: in the `transparent` mode, the
  default, glass with transmission `1 − opacity`; in `presence`, coverage. `doubleSided`, of the
  mesh, makes its material `two_sided` (a mesh without one gets a default material that is).
  `clearcoat` is a white coat with the surface's IOR, as MaterialX builds it. Two materials with
  the same name: the second is named by its prim path; one without `UsdPreviewSurface` is not
  imported. Images that `usdcat` does not resolve are searched next to the file.
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
  transmission, by value. The double-sided feature ufbx reads is `two_sided`. Roughness and
  metalness, which FBX gives as single-channel images, are
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

- **At the mixer's rate.** A sound the importer codes is brought to `audio.MIXER_RATE` by
  `resample`, a sinc windowed by Kaiser, band-limited to the lower Nyquist frequency, with its
  loop start moved to the nearest frame, so a voice at its own pitch copies it. The host refuses a
  coded `.sound` at another rate and `mirai asset` says to import its source again. A stream that
  keeps its file keeps its rate and its loop start: its voice resamples it.
- **Short: lossless, kept encoded.** Under `SOUND_STREAM_SECONDS` its 16 bit samples, at its
  channels, are stored `Lossless` (a 16-bit WAV at the mixer's rate arrives bit for bit; anything
  else is rounded without dither); the mixer keeps that coding in memory and each voice decodes it.
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
(compressed in the asset), the root of its import.

- It reads TrueType and OpenType with TrueType or CFF outlines, and before writing it opens it like
  the UI does (`ui.font_init`): what is imported loads.
- It rejects a collection (TTC) saying how to extract a font
  (`fonttools ttLib -y 0 <file> -o font.ttf`) and a web font (WOFF), which must be converted to
  `.ttf` or `.otf`. What FreeType does not open is `Malformed`.
- The report's detail says the outlines and how many glyphs of the atlas it has
  ([coverage](../../mirai-ui/references/ui.md#font)).

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

The prefab that `import_source` writes (`cook/prefab.model_prefab`), in the types of the game
(`Import_Options.world`) and through the writer of `mirai scene write` (`author.scene_file_bytes`),
so every component is in the layout the game declares and a resave changes no byte; a component
of a plugin the game lacks is left out:

- Keeps rigid nodes with `Animation_Target.path`, meshes with `Mesh_Renderer` and shared pose
  (`Pose_Source.rig`), and omits bone entities.
- Rigid objects attached to bones receive `Bone_Attachment`, with a socket `bone.<path hash>`
  defined in the `.skeleton`.
- Several roots, clips or skins create a placement root. One skeleton uses that root as the rig;
  several use one rig entity each. The rig draws the first skinned mesh of its skeleton and the
  others follow it with `Pose_Source.rig`.
- With clips it adds `Animation`. Invisible nodes keep `Hidden`.
