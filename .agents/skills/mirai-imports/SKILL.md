---
name: mirai-imports
description: Mirai importers that convert OBJ, glTF/GLB, USD, FBX, static and skinned meshes, morph
  targets, sockets and animations, and images (HDR, 16-bit, cubes and arrays) to .mesh, .skeleton,
  .mat, .tex and .anim, WAV and Ogg Vorbis to .sound, TrueType and OpenType fonts to .font and
  prompt manifests to .prompts with their atlases (`cook/import`, its formats
  `cook/import/obj`, `gltf`, `usd` and `fbx` (ufbx), `cook/import/sources`, `cook/textures`,
  `cook/rig` template rigs, `cook/cache`, the `mirai import` command), and the formats and whole
  sources a plugin adds to the editor (`Import_Format_Provider`, `Import_Source_Provider`). Use when
  importing or verifying a model, animation, texture, font or prompts, when changing or
  adding an import format, when importing with a plugin or when regenerating the demo's imported
  assets.
---

# Importing models and textures

Importers are *engine-time*: they read art sources and write binary assets; the game only reads
the assets.

## Map

- Packages, `import_source`, the imported model and CLI: [imports.md](references/imports.md#api).
- The package of a source in the store (settings, ids, build of objects), documents written or
  followed in a project (`documents_follow`), reimporting and parts with `owner`:
  [Identity](references/imports.md#identity-and-reimport).
- The records of the store (package and build manifests, refs, `packages.mirai`):
  [packages](../mirai-assets/references/formats.md#packages).
- Ingesting a source from anywhere, adding it to a project (`packages.mirai`), what a build
  refreshes, a peer without sources, and when a source is imported again:
  [Library](references/imports.md#library).
- Adding or changing a format (`Format`, `Reader`, `Source_Space`, version):
  [Formats](references/imports.md#formats).
- Import cache and versions: [Cache](references/imports.md#import-cache),
  [texture cache](references/imports.md#texture-cache) and
  [mesh cache](references/imports.md#mesh-cache); mips, BC format, green of normal maps and
  heightmaps: [Textures](references/imports.md#textures-cooktextures).
- Importing in parallel (`model_cook`, `Import_Options.worker`) and `mirai import --profile`:
  [in parallel](references/imports.md#in-parallel).
- A character or an animal without a rig (`rig=Humanoid`, `Fox`, `Spider`..., `cook/rig`):
  [template rigs](references/imports.md#template-rigs-cookrig); how an agent animates it:
  [auto-rig](../mirai-animation/references/animation-autorig.md#workflow).
- Rules per format: [OBJ](references/imports.md#obj),
  [glTF/GLB](references/imports.md#gltf-and-glb) (skeletons, morph targets, clips, meshopt),
  [USD](references/imports.md#usd), [FBX](references/imports.md#fbx) (ufbx, its binding and its
  fixtures), [sounds](references/imports.md#sounds), [fonts](references/imports.md#fonts),
  and [prompts](references/imports.md#prompts).
- Formats of `.mesh`, `.mat`, `.tex`, `.anim` and the version rule: [asset
  types](../mirai-assets/references/formats.md#asset-types) and
  [versions](../mirai-assets/references/formats.md#versions); verifying what was written: [asset
  CLI](../mirai-assets/references/cli.md#subcommands).
- Formats and whole sources a plugin adds to the editor (`Import_Format_Provider`,
  `Import_Source_Provider`): [plugins](references/imports.md#plugin-formats) and
  [editor extension](../mirai-editor/references/extensions.md#importers-of-a-plugin). The
  Unreal content importer is the catalog plugin `unreal`, with its `unreal_*` bridges
  ([git plugins](../mirai-plugins/references/plugins.md#git-plugins-and-catalog)).

## Workflow

1. **Importing a file.** An import takes the store (`Import_Options.store`) and puts in it the
   package of the source and a build of its objects; given `documents`, it also writes or follows
   the documents in that folder of a project. Review the assets with `mirai asset verify`, `ls`
   and `info`; commit `packages.mirai` and the documents, never the objects. The editor, the CLI,
   the library and the content tools import with the same `sources.import_source`: same assets,
   prefab included. `mirai import <file>` ingests it and adds it to a project
   ([library](references/imports.md#library)).
2. **From code.** `sources.import_source(path,options)` writes everything; for the model
   without writing it, `importer.import_model(path,sources.FORMATS[:],options)` reads it into an
   `Imported_Model` (plain data, no engine components) and `importer.import_write` writes its
   assets; `cook/prefab.model_prefab` builds the prefab in the types of the game
   (`Import_Options.world`: the session's, or those of the project's editor library).
3. **Adding a format.** A `cook/import/<format>` package that does not import the other formats,
   with its `FORMAT :: importer.Format{...}` and a line in `sources.FORMATS`
   ([how](references/imports.md#adding-a-format)). Its own options live in it (`Format.data`).
4. **Changing a reader.** If it gives other bytes for the same source, raise `Format.version`; if
   the writer changes, `IMPORTER_VERSION`. Assets of the previous version are rebuilt on the next
   import.
5. **Importing with a plugin.** An editor plugin provides an `Import_Format_Provider` (one more
   model format) or an `Import_Source_Provider` (a source that imports whole); the editor and the
   import program of the engine add its formats to `sources.FORMATS`, which holds only the
   engine's own ([plugins](references/imports.md#plugin-formats)).
6. **Regenerating imported assets.** `mirai build` refreshes the packages a project and its
   plugins pin once its target stands (`mirai import --refresh <root>`): builds from the store,
   from a peer, or by ingesting a source this machine has
   ([library](references/imports.md#library)).

## Invariants

- **A format does not know the others** and the core knows none: the concepts of another engine
  or format are translated in its package. The core only provides the `Reader`, the model and the
  writer.
- **Source space is applied once.** The reader stores positions, transforms and UVs as the source
  says them and declares its `Source_Space`; the import bakes units, axes, mirroring and V origin
  into the geometry, transforms, bones, clips and maps. What is written is in meters and in the
  engine's axes, with no added nodes or negative scales.
- **Every model faces -Z, and the source is parsed once.** What faces elsewhere is turned in
  place after the read: from the `front` its settings state, or else, for a file that is a rig,
  from where its body is found facing ([front](references/imports.md#front)).
- **The source is not modified.** The same bytes and options give the same assets.
- **A refresh preserves the package when its source is missing.** It takes a build from the
  store or the caller's source, finalizes a current local build, or ingests an origin on this
  machine. If it cannot build the package, it names what is missing.
- **A source imports from anywhere.** In a project, in a plugin or in no project: what it makes
  goes to the store, and its documents to the folder of the project given. In a project, it lives
  beside what it makes, in folders by theme, never a folder per asset type.
- **The ids of an import live in the manifest of its package, and nothing derives them.** The
  first ingest gives random ids; importing the package again, on any machine, gives each part
  the asset it had by its kind and name, even if its document was moved
  ([identity](references/imports.md#identity-and-reimport)). A part renamed in the source is a
  new asset. Only what is surely part of a model belongs to its prefab (`owner`), and it is
  decided once ([parts](references/imports.md#parts)).
- **An import never touches another.** Two models that embed the same image get a texture each,
  encoded once in the content cache; no import edits the documents or the package of another
  source. Decided by the owner.
- **Every output is an immutable object of the store, the same on every machine**
  (`asset.object_put`, cut where its format reads alone). The build lists the objects, documents
  among them as their baseline. No object is rewritten in place (a changed owner is a new
  object), and the source an asset names is relative to its package. A document of a plugin's
  kind a refresh writes takes the extension the plugin's manifest gives its kind. Materials,
  prefabs, skeletons, clips, texts and prompts, which the editor edits, are also documents of a
  project, followed from the baseline. Decided by the owner.
- **The identity holds no engine version; the key holds the identity and the versions.** The
  identity (package, source, inputs, settings, plugin code: two packages of the same bytes never
  share a build, since its objects hold their ids) is in the manifest; the key
  (`asset.import_key`) adds the writer, format, kind and texture builder versions, so any machine
  with the manifest finds a build without the source. A Final build is named under `imports`, a
  Fast one under `imports-fast`, and peers share both; `builds` names the one this machine chose.
  The editor never imports by itself.
- **A share serves what the host has; a refresh takes what its build accepts.** A refresh that
  does not cook (the editor's, a play build's, a join's) takes a Final or a Fast build, from the
  store first and then from the source, before importing anything; one that cooks asks only
  `imports` and can finalize a current local build. Only a Final build reaches a cook, and a
  package with no Final reachable fails by name.
- **What imports and cooks build is kept as refs into the machine store** (`cook/cache`): an
  object named by `(cache-<name>, <key>-<version>)`, found by any program or machine that shares
  the store's objects; a miss asks the caller's `cache.Source` before building, what a pass needs
  is looked up at once (`cache.lookup`, one fetch for the pass), and `cook/cache` removes nothing:
  the store owns space ([texture cache](references/imports.md#texture-cache)).
- **Following a package is a pure function of the package, its build and the game's types**:
  two refreshes on any machine give the same bytes, and a document, prefab or record that would
  be written as it is is not written (`serial.file_write_changed`).
- **Reimporting keeps what a person changed.** A material stores what the source gave and the next
  import rewrites only that: fields changed afterwards stay, like the overrides of a prefab
  ([materials](references/imports.md#what-is-written)). Any other document it writes over is
  never written over unasked: one changed since the import wrote it stops the import, which names
  it, and only `discard_changes` writes over it; a refresh leaves it as it is and warns
  ([changed documents](references/imports.md#changed-documents)).
- **What an asset was built from is its `Import_Info`**: source (size and hash), writer and format
  version, and only the settings the asset is made from. Reuse is a ref lookup: a mesh or a
  texture that a build of the package has, recording what it would be built from now, is taken;
  the rest is rebuilt, and a texture of the same image and settings or a mesh of the same
  geometry and settings comes from the content cache.
- **In parallel, the same bytes.** What is expensive (levels, clusters and colliders of a mesh,
  levels of a texture) is built in jobs; what decides ids and files is written in a single thread,
  in the usual order. Importing with or without the job system gives the same files.
- **Without an optimizer, close and with the same bytes.** The hot loops (BLAKE3 of the payloads,
  the quadrics of simplification) do four values per instruction with `#simd[4]` and add in the
  order of the scalar loop: the tool and the dev engine (`-o:minimal`) write the same as
  `--release`.
- **Importing is a transaction.** `import_model` leaves nothing if it fails (own arena, freed by
  `model_destroy`); `import_write` removes the documents it created and names nothing if it fails
  midway. Errors name the file, the line or the prim.
- **A source does not choose what is read from disk.** A path with a control character or, on
  Windows, a device (`CON`, `NUL`, `COM1`) is not opened. Models only ask for files next to them
  or by path, never more than `MAX_SOURCE_BYTES`, and the hierarchy is bounded (`MAX_DEPTH`).
- **No memory in the caller's scratch.** Reading uses its own arena as `temp_allocator`; a model
  of any size does not exhaust the scratch of a frame or request. `Error` messages live in the
  caller's `temp_allocator`.
- **Immutable bind geometry.** A mesh keeps bind positions and normals, up to eight normalized
  weights and its own inverse binds, and references a reusable skeleton asset; the pose is applied
  once ([rig contract](references/imports.md#skinned-meshes)). glTF clips keep their tangents and
  bind nodes by escaped nominal path: reordering node indices does not change the binding, and a
  path that a clip or a skin binds and other nodes share is rejected with a diagnostic; siblings
  that share a name and that nothing binds import.
- **Each hand of a body gets a grip measured on its skin.** `grip_left` and `grip_right`
  (`cook/import/grip.odin`) lie on the palm: X toward the fingertips, Y across the palm, Z out of
  it, in meters; a source socket of that name wins and a skinned hand it cannot measure warns.
- **A mesh is a buffer indexed by slots.** Equal vertices are shared; the triangles of each slot
  occupy a contiguous range of the index; each slot keeps its source id (OBJ: `usemtl` order;
  glTF: primitive index plus one; USD: 1) and it is never inferred from editable names.
- **Reject rather than approximate.** Shear, perspective, zero scale, UVs outside
  `TEXCOORD_0/1`, Draco, meshopt indices and normals, GPU instancing, subdivision surfaces and
  time samples fail with a named error. What is ignored without breaking the source (material
  extensions with no equivalent, missing images) leaves a warning.
- **Settings live in the package.** Its manifest decides how the source is imported again and wins
  over the options of whoever imports (except `ignore_stored`). Everything that changes an asset
  is a setting, also the alpha coverage of a loose image. An unreadable manifest is an error, not
  the defaults nor new ids.
- **What is imported is used as is.** Levels of detail are made on import and stored in the
  `.mesh`; loading does not recompute them.
- **Collision is the source's, as authored.** The colliders the source brings are the mesh's and
  the import makes none; a mesh without them collides only through an `Auto` collider, whose
  geometry physics derives and caches. Decided by the owner.
- **No limits of size or triangles are settings.** Texture memory is decided by what the view
  samples (mip streaming); an image above `asset.TEXTURE_MAX_SIZE` is refused, never scaled.
  Levels of detail are chosen by projected error. Decided by the owner.
- **Textures in blocks are encoded with a perceptual metric and RDO** at
  `RDO_LAMBDA_DEFAULT` unless the setting `rdo_lambda` says otherwise.
- **The editor never waits for the final encode** (`textures.Encode_Speed`): its imports take the
  Final of the texture cache, else build Fast (no RDO, low effort, `Texture_Flag.Fast`). The
  refresh of a build that does not cook (the editor's) and `mirai import` build Fast too and take
  Fast or Final, so the command takes what the editor's import left; only the refresh of a build
  that cooks, or of `mirai package engine` (`--final`), requires Final, and the editor builds
  Final a texture that is a document.
- **One algorithm, once.** Mips, color rules and block compression in `cook/textures` (the
  encoders are `compressor:blocks`); PBR conversions in `cook/import/pbr.odin`; triangulation,
  simplification, hulls and convex decomposition in `std/geom`; transforms with `std/math`.
- USD is composed with the prebuilt `usdcat` when it exists; without it only USDA that needs no
  composition is read.

## Verification

- `mirai test cook/import` (source space, PBR, levels, sounds, hand grips),
  `cook/rig` (fit and weights over a body of boxes, each animal stretched by its skin, meshes
  that are neither a person nor an animal), `cook/import/obj`, `cook/import/gltf` (with the rig
  fits of `rig_test.odin` and the decoding of `meshopt_test.odin`), `cook/import/usd`,
  `cook/import/fbx` (each format with its fixtures) and `cook/import/sources` (sniffing, writing,
  cache, settings, fuzz, CLI); `cook/textures` (decoding, mips, BC blocks and their RDO lambda,
  inverted green, round trip through `.tex`, cache by content; HDR, every BC6H mode, 16-bit and
  layers in `layers_test.odin`). The fixtures of `assets/fixtures/` and the models of
  `demo/assets` import (without warnings) and what is written reads back with `asset`.
- Caches: `cook/cache/cache_test.odin` (a result kept through one store is found through another
  of its root or through a source on a miss; an object not here is a miss; a lookup of many keys
  asks once; hostile names), `cook/textures/cache_test.odin` (and one texel changed changes few
  chunks of the object) and `cook/import/sources/cache_test.odin` (a texture or a mesh
  that another import built is taken from the cache or from a source; one whose file under another
  key records what it is built from now is taken without writing it, and one that records other
  encoders or another builder is built again);
  `cook/build/cook_cache_test.odin` (a cook takes the blocks of a texture from the cache of its
  content, ships package assets from their objects and looks the cache up once per pass) and
  `cook/import/sources/cook_test.odin` (Final refresh reuses a current whole-source build
  and encodes only its Fast textures from the cache, with the same outputs as a clean import;
  a refresh that does not cook accepts either quality; a peer with only fetched builds cooks
  what the sources cook, sources inside a root stay behind and a missing build fails by package;
  a refresh takes builds from a second store and asks that store for Final when cooking).
- Parallel: import a map with `mirai import --rebuild` over a copy of an import made without the
  job system (or before the change) and compare the trees with `diff -r`: the same bytes.
- Also test `cook/prefab` if the imported hierarchy changes, and `asset` if an asset format or its
  version changes.
- Fonts and prompts: `cook/import/interface_test.odin` (rejected collections, power-of-two
  atlases without overlap) and `cook/import/sources/fuzz_test.odin`
  (damaged files are imported or refused). After changing the prompt importer, import the
  `prompts_kenney` pack again
  ([command](../mirai-plugins/references/plugins.md#first-party-plugins)) and verify it with
  `mirai asset verify`.
- Identity: `cook/import/sources/reimport_test.odin` (the parts of an import name their prefab and
  keep their ids where they were moved, a source keeps the ids of its package with the manifest a
  project pins and a copy is another package, a part renamed in the source is a new one, two
  models with the same image get a texture each and neither touches the other, when a material is
  a part of a model), `cook/import/outputs_test.odin` (the outputs of a source are the assets its
  package lists, the models of a whole source share their parts by name, inputs count in the
  identity, importing again keeps ids and objects, a source outside any project imports, a setting
  changes the identity and an engine version only the key, a Fast build is named apart, two stores
  hold the same objects), `cook/import/sources/settings_test.odin` (the package keeps the settings;
  settings that are not this build's are refused) and `cook/import/sources/write_test.odin`
  (importing again keeps what was changed in a material and takes the rest from the source).
- Library: `cook/import/sources/library_test.odin` (a peer without sources fetches, lists and
  loads what a project pins, and without a source of builds reports by package and neither
  removes nor builds; a source outside any project ingests once and two projects list the same
  objects; an engine change ingests again where the source is and is reported by name elsewhere;
  hostile `packages.mirai` and manifests are
  reported; two ingests of one source at once import it once; a copy of a root with its sources
  and an empty store builds the same ids, manifests and objects, and without them reports each
  package; refreshing from two empty stores writes nothing the second time) and
  `cook/import/sources/reimport_test.odin` (a refresh reads a source again with the formats of
  the plugins, ingests a whole source again when what it is built from changes, and finds the
  build of a whole source by key without the source, missing it for another importer).
- Changed documents: `an_import_does_not_write_over_a_document_changed_since_it_wrote_it` and
  the edited case of `a_refresh_ingests_again_a_whole_source_when_what_it_is_built_from_changes`
  (reimport tests), the question of the editor in `editor/import_api_test.odin`.
- `cook/import/sources/cli_test.odin` needs `MIRAI_ROOT` (defined by `mirai test`); run it when
  touching `cook/import/sources/command.odin`. It imports in-process with `command`; the whole
  path (`mirai import` → `mirai-import`) needs the built engine.
- The tests that compose USD (`referenced.usda`) or decode the crate (`hierarchy.usdc`) need
  `usdcat` and report that they did not run if it is missing; the process is tested with a fake
  `usdcat`.
- Plugin formats and sources: the integration tests of the plugin that provides them, with the
  providers as the editor finds them (`mirai test plugins/<plugin>/editor`).
- FBX: fixtures are written with `uv run assets/fixtures/fbx.py` (binary and ASCII of the same
  scene); after changing the reader or updating ufbx, also import the FBX files of the ufbx corpus
  (`data/` of its repository) and real files from Maya, Blender and Mixamo, and compare what is
  rejected. The binding is regenerated with `uv run scripts/ufbx_binding.py`
  ([ufbx](../../../third_party/ufbx/UPSTREAM.md)).
- `fuzz_test.odin` truncates each fixture to all its lengths and changes bytes (OBJ, glTF, GLB,
  USDA, binary and ASCII FBX, WAV, Ogg, PNG, fonts and prompts): each attempt is imported or
  rejected, without crashes, hangs or leaks. A new format extends those tests.
- A change that must give the same bytes is compared by importing with the CLI before and after
  (`--rebuild` on the second pass, or in new folders) and with `cmp` of each asset.
