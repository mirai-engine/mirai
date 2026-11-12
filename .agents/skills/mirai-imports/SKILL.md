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
- Where a source lives (in the assets, beside what it makes), its sidecar (settings, folder, ids),
  what an import keeps in the imported folder and what in the assets, reimporting, a moved or
  renamed source and parts with `owner`: [Identity](references/imports.md#identity-and-reimport).
- A checkout without its imported folder, what a build imports and when a source is imported
  again: [Sync](references/imports.md#sync).
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

1. **Importing a file.** Put it in `assets/`, in the folder of its theme beside what it makes
   (the editor copies a file from outside into the folder of the browser), and
   [`mirai import`](references/imports.md#what-is-written) it; review the assets with
   `mirai asset verify`, `ls` and `info`. Commit the source, its `.import` and the documents it
   wrote beside it; what it wrote in `.mirai/imported/` is never versioned. The editor, the CLI,
   the sync of builds and the content tools import with the same `sources.import_source`: same
   assets, prefab included.
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
6. **Regenerating imported assets.** `mirai build` builds what is missing or stale of a project
   and its plugins once its target stands ([sync](references/imports.md#sync)).

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
- **A source lives in the assets, beside what it makes, in folders by theme.** Never a folder per
  asset type; the browser filters by type. One outside the assets is refused. Decided by the
  owner.
- **The ids of an import live in the sidecar of its source, and nothing derives them.** The first
  import gives random ids and `<source>.import` lists them; importing again, on any machine and
  in any order of sources, gives each part the asset it had by its kind and name, even if its
  document was moved, and a source moved or renamed with its sidecar keeps its import
  ([identity](references/imports.md#identity-and-reimport)). A part renamed in the source is a
  new asset. Only what is surely part of a model belongs to its prefab (`owner`), and it is
  decided once ([parts](references/imports.md#parts)).
- **An import never touches another.** Two models that embed the same image get a texture each,
  encoded once in the content cache; no import edits the files or the sidecar of another source.
  Decided by the owner.
- **What nobody edits is a cache of the source, never versioned, whatever reads it.** The meshes,
  textures, sounds and fonts of every import, of an engine format or of a plugin's, are files of
  the imported folder of its root (`.mirai/imported/`), named by their ids and listed by where
  their sidecar is, built again from the source and its sidecar by
  [sync](references/imports.md#sync); materials, prefabs, skeletons, clips, texts and prompts,
  which the editor edits, are documents of `assets/`. Decided by the owner.
- **The source, its sidecar and the build decide the cache.** The same three give the same files,
  byte for byte: a clone, a worktree and a branch switch are brought up to date by the same sync,
  explicitly, in `mirai build`; the editor never imports by itself.
- **Reimporting keeps what a person changed.** A material stores what the source gave and the next
  import rewrites only that: fields changed afterwards stay, like the overrides of a prefab
  ([materials](references/imports.md#what-is-written)).
- **What an asset was built from is its `Import_Info`**: source (size and hash), writer and format
  version, and only the settings the asset is made from. Whether a file of the cache is current
  is said once, by its name (the key of what the import builds from); the rest is rebuilt, and a
  texture of the same image and settings or a mesh of the same geometry and settings comes from
  the content cache.
- **In parallel, the same bytes.** What is expensive (levels, clusters and colliders of a mesh,
  levels of a texture) is built in jobs; what decides ids and files is written in a single thread,
  in the usual order. Importing with or without the job system gives the same files.
- **Without an optimizer, close and with the same bytes.** The hot loops (BLAKE3 of the payloads,
  the quadrics of simplification) do four values per instruction with `#simd[4]` and add in the
  order of the scalar loop: the tool and the dev engine (`-o:minimal`) write the same as
  `--release`.
- **Importing is a transaction.** `import_model` leaves nothing if it fails (own arena, freed by
  `model_destroy`); `import_write` removes the files it created if it fails midway. Errors name
  the file, the line or the prim.
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
- **Settings live with the source.** `<source>.import` decides how it is imported and wins over the
  options of whoever imports (except `ignore_stored`); every import writes it. Everything that
  changes an asset is a setting, also the alpha coverage of a loose image. An unreadable sidecar
  is an error, not the defaults nor new ids.
- **What is imported is used as is.** Levels of detail and colliders are made on import and stored
  in the `.mesh`; loading does not recompute them.
- **Simple collision: the source's wins.** The colliders the source brings are the mesh's
  collision; the `collision` setting builds them from the geometry only if the source brings
  none, or with `force_collision` (`--force-collision`).
- **Textures in blocks are encoded with a perceptual metric and RDO** at
  `RDO_LAMBDA_DEFAULT` unless the setting `rdo_lambda` says otherwise.
- **The editor never waits for the final encode** (`textures.Encode_Speed`): its imports take the
  Final of the texture cache, else build Fast (no RDO, low effort, `Texture_Flag.Fast`). The sync
  of a build that does not cook (the editor's) builds Fast too and takes Fast or Final as current;
  only the sync of a build that cooks, or of `mirai package engine`, builds Final. `mirai import`
  and tools build Final, and so does the editor for a texture that is a document.
- **One algorithm, once.** Mips, color rules and block compression in `cook/textures` (the
  encoders are `compressor:blocks`); PBR conversions in `cook/import/pbr.odin`; triangulation,
  simplification, hulls and convex decomposition in `std/geom`; transforms with `std/math`.
- USD is composed with the prebuilt `usdcat` when it exists; without it only USDA that needs no
  composition is read.

## Verification

- `mirai test cook/import` (source space, PBR, levels, collision, sounds, hand grips),
  `cook/rig` (fit and weights over a body of boxes, each animal stretched by its skin, meshes
  that are neither a person nor an animal), `cook/import/obj`, `cook/import/gltf` (with the rig
  fits of `rig_test.odin` and the decoding of `meshopt_test.odin`), `cook/import/usd`,
  `cook/import/fbx` (each format with its fixtures) and `cook/import/sources` (sniffing, writing,
  cache, settings, fuzz, CLI); `cook/textures` (decoding, mips, BC blocks and their RDO lambda,
  inverted green, round trip through `.tex`, cache by content; HDR, every BC6H mode, 16-bit and
  layers in `layers_test.odin`). The fixtures of `assets/fixtures/` and the models of
  `demo/assets` import (without warnings) and what is written reads back with `asset`.
- Caches: `cook/textures/cache_test.odin` and `cook/import/sources/cache_test.odin` (a texture or
  a mesh that another import built is taken from the cache);
  `cook/build/cook_cache_test.odin` (a cook takes the blocks of a texture from the cache of its
  content) and `cook/import/sources/cook_test.odin` (the sync of a cook builds a fast texture
  final from its source; that of a build that does not cook keeps either).
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
- Identity, the imported folder and sync: `cook/import/sources/reimport_test.odin` (the parts of
  an import name their prefab and keep their ids where they were moved, a source keeps the ids of
  its import with its sidecar, a part renamed in the source is a new one, two models with the same
  image get a texture each and neither touches the other, a checkout without its imported folder
  gets the same assets byte for byte and only what changed is imported again, the sources of a
  plugin format build in the cache and sync reads them with the formats of the plugins, a source
  outside the assets is refused, when a material is a part of a model, sync runs the importer of
  a plugin for a whole source whose inputs changed), `cook/import/outputs_test.odin` (the models
  of a whole source share their parts by name, names with `/` go to subfolders, inputs count in
  the key),
  `asset/registry_test.odin` (the listing of the cache by where the sidecar is, never by the order
  of a scan), `cook/import/sources/settings_test.odin` (a sidecar that is not one is refused) and
  `cook/import/sources/write_test.odin` (importing again keeps what was changed in a material and
  takes the rest from the source). After changing what an import writes, prove it on the demo:
  delete `demo/.mirai/imported`, `mirai build editor demo`, and `git status` shows no sidecar
  or document changed.
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
  USDA, binary and ASCII FBX, WAV, Ogg, PNG and the `.import` text): each attempt is imported or
  rejected, without crashes, hangs or leaks. A new format extends those tests.
- A change that must give the same bytes is compared by importing with the CLI before and after
  (`--rebuild` on the second pass, or in new folders) and with `cmp` of each asset.
