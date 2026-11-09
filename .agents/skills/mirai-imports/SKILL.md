---
name: mirai-imports
description: Mirai importers that convert OBJ, glTF/GLB, USD, FBX, static and skinned meshes,
  morph targets, sockets and animations, and images (HDR, 16-bit, cubes and arrays) to .mesh,
  .skeleton, .mat, .tex and .anim, WAV and Ogg Vorbis to .sound, TrueType and OpenType fonts to
  .font, CSV texts to .strings and prompt manifests to .prompts with their atlases (`cook/import`,
  its formats `cook/import/obj`, `gltf`, `usd` and `fbx` (ufbx), `cook/import/sources`,
  `cook/textures`, the `mirai import` command), and the formats and whole sources a plugin adds to
  the editor (`Import_Format_Provider`, `Import_Source_Provider`). Use when importing or verifying
  a model, animation, texture, font, texts or prompts, when changing or adding an import format,
  when importing with a plugin or when regenerating the demo's imported assets.
---

# Importing models and textures

Importers are *engine-time*: they read art sources and write binary assets; the game only reads
the assets.

## Map

- Packages, `import_source`, the imported model and CLI: [imports.md](references/imports.md#api).
- Ids, reimporting, moved outputs, a moved or renamed source (`into`) and parts with `owner`:
  [Identity](references/imports.md#identity-and-reimport).
- Adding or changing a format (`Format`, `Reader`, `Source_Space`, version):
  [Formats](references/imports.md#formats).
- Import cache and versions: [Cache](references/imports.md#import-cache),
  [texture cache](references/imports.md#texture-cache) and
  [mesh cache](references/imports.md#mesh-cache); mips, BC format, green of normal maps and
  heightmaps: [Textures](references/imports.md#textures-cooktextures).
- Importing in parallel (`model_cook`, `Known`, `Import_Options.worker`) and `mirai import
  --profile`: [in parallel](references/imports.md#in-parallel).
- A character or an animal without a rig (`rig=Humanoid`, `Fox`, `Spider`..., `cook/rig`):
  [template rigs](references/imports.md#template-rigs-cookrig); how an agent animates it:
  [auto-rig](../mirai-animation/references/animation-autorig.md).
- Rules per format: OBJ, glTF/GLB (skeletons, morph targets, clips, meshopt), USD,
  [FBX](references/imports.md#fbx) (ufbx, its binding and its fixtures), sounds,
  [fonts](references/imports.md#fonts), [texts](references/imports.md#texts) and
  [prompts](references/imports.md#prompts), in the same reference.
- Formats of `.mesh`, `.mat`, `.tex`, `.anim` and the version rule: [asset
  formats](../mirai-assets/references/formats.md); verifying what was written: [asset
  CLI](../mirai-assets/references/cli.md).
- Formats and whole sources a plugin adds to the editor (`Import_Format_Provider`,
  `Import_Source_Provider`): [plugins](references/imports.md#plugin-formats) and
  [editor extension](../mirai-editor/references/extensions.md#importers-of-a-plugin). The
  Unreal content importer is the catalog plugin `unreal`, with its `unreal_*` bridges
  ([git plugins](../mirai-plugins/references/plugins.md#git-plugins-and-catalog)).

## Workflow

1. **Importing a file.** [`mirai import`](references/imports.md#what-is-written) with the
   source's settings; review the assets with `mirai asset verify`, `ls` and `info`. The editor,
   the CLI and `tools/demo_content` import with the same `sources.import_source`: same assets,
   prefab included.
2. **From code.** `sources.import_source(path,folder,options)` writes everything; for the model
   without writing it, `importer.import_model(path,sources.FORMATS[:],options)` reads it into an
   `Imported_Model` (plain data, no engine components) and `importer.import_write` writes its
   assets; `cook/prefab.model_prefab` builds the prefab.
3. **Adding a format.** A `cook/import/<format>` package that does not import the other formats,
   with its `FORMAT :: importer.Format{...}` and a line in `sources.FORMATS`
   ([how](references/imports.md#adding-a-format)). Its own options live in it (`Format.data`).
4. **Changing a reader.** If it gives other bytes for the same source, raise `Format.version`; if
   the writer changes, `IMPORTER_VERSION`. Assets of the previous version are rebuilt on the next
   import.
5. **Importing with a plugin.** An editor plugin provides an `Import_Format_Provider` (one more
   model format) or an `Import_Source_Provider` (a source that imports whole); the editor adds
   them to `sources.FORMATS`, which holds only the engine's own
   ([plugins](references/imports.md#plugin-formats)).
6. **Regenerating the demo's imported assets.** `tools/demo_content` imports `demo/source/textures`
   and `demo/source/models` with `import_source`, each image with the use its name says:
   [generated content](../mirai-gameplay/references/demo.md#generated-content).

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
- **An asset's id lives in its header and nothing derives it.** The first import gives random ids;
  reimporting writes each part in its file and with its id, even if it was moved or renamed in the
  source, and a moved or renamed source keeps its import
  ([identity](references/imports.md#identity-and-reimport)). Only what is surely part of a model
  belongs to its prefab (`owner`), and it is decided once ([parts](references/imports.md#parts)).
- **Reimporting keeps what a person changed.** A material stores what the source gave and the next
  import rewrites only that: fields changed afterwards stay, like the overrides of a prefab
  ([materials](references/imports.md#what-is-written)).
- **An import's cache is each asset's `Import_Info`**: source (size and hash), writer and format
  version, and only the settings the asset is made from. A mesh or texture whose file is already
  the one that would be written is kept; the rest is rebuilt, and a texture of the same image and
  settings or a mesh of the same geometry and settings comes from the project cache.
- **In parallel, the same bytes.** What is expensive (levels, clusters and colliders of a mesh,
  levels of a texture) is built in jobs; what decides ids, files and what is shared is written in a
  single thread, in the usual order. Importing with or without the job system gives the same
  files.
- **Without an optimizer, close and with the same bytes.** The hot loops (BLAKE3 of the payloads,
  the quadrics of simplification) do four values per instruction with `#simd[4]` and add in the
  order of the scalar loop: the tool and the `--dev` engine (`-o:minimal`) write the same as
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
  options of whoever imports (except `ignore_stored`); `import_source` writes it unless
  `no_save`. Everything that changes an asset is a setting, also the alpha coverage of a loose
  image. An unreadable settings file is an error, not the defaults.
- **What is imported is used as is.** Levels of detail and colliders are made on import and stored
  in the `.mesh`; loading does not recompute them.
- **Simple collision: the source's wins.** The colliders the source brings are the mesh's
  collision; the `collision` setting builds them from the geometry only if the source brings
  none, or with `force_collision` (`--force-collision`).
- **Textures in blocks are encoded with a perceptual metric and RDO** at
  `RDO_LAMBDA_DEFAULT` unless the setting `rdo_lambda` says otherwise.
- **The editor never waits for the final encode** (`textures.Encode_Speed`): its imports take the
  Final of the texture cache, else build Fast (no RDO, low effort, `Texture_Flag.Fast`), and the
  cook encodes a Fast texture again as Final from its source. `mirai import` and tools build Final.
- **One algorithm, once.** Mips, color rules and block compression in `cook/textures` (the
  encoder is `cook/compressor/texture`); PBR conversions in `cook/import/pbr.odin`; triangulation,
  simplification, hulls and convex decomposition in `std/geom`; transforms with `std/math`.
- USD is composed with the prebuilt `usdcat` when it exists; without it only USDA that needs no
  composition is read.

## Verification

- `mirai test cook/import` (source space, PBR, levels, collision, sounds, hand grips),
  `cook/rig` (fit and weights over a body of boxes, each animal stretched by its skin, meshes
  that are neither a person nor an animal), `cook/import/obj`, `cook/import/gltf` (with
  `a_humanoid_rig_fits_the_joints_a_person_placed_and_rests_as_the_template`,
  `a_humanoid_rig_fits_a_person_whose_arms_hang`,
  `an_animal_rig_fits_the_joints_a_person_placed_and_rests_as_its_clips` and
  `meshopt_clips_decode_to_continuous_keys`), `cook/import/usd`, `cook/import/fbx` (each format
  with its fixtures) and `cook/import/sources` (sniffing, writing, cache, settings, fuzz, CLI);
  `cook/textures` (decoding, mips, BC blocks and their RDO lambda, inverted green, round trip
  through `.tex`, cache by content; HDR, every BC6H mode, 16-bit and layers in `layers_test.odin`).
  The fixtures of `assets/fixtures/` and the models of `demo/source/models` import (without
  warnings) and what is written reads back with `asset`.
- Texture cache: `built_textures_are_kept_by_image_and_settings_and_read_back_whole`,
  `an_import_takes_a_texture_that_another_import_built_from_the_texture_cache` and, in
  `cook/build`, `a_cook_takes_the_blocks_of_a_texture_from_the_cache_of_its_content` and
  `a_cook_encodes_a_fast_texture_again_as_final_from_its_source`. Mesh cache:
  `an_import_takes_a_mesh_that_another_import_built_from_the_mesh_cache`.
- Parallel: import a map with `mirai import --rebuild` over a copy of an import made without the
  job system (or before the change) and compare the trees with `diff -r`: the same bytes.
- Also test `cook/prefab` if the imported hierarchy changes, and `asset` if an asset format or its
  version changes.
- Fonts, texts and prompts: `cook/import/interface_test.odin` (rejected collections, CSV per
  RFC 4180, power-of-two atlases without overlap) and
  `damaged_fonts_texts_and_prompts_are_imported_or_refused` (`cook/import/sources`). After
  changing the prompt importer, import the `prompts_kenney` pack again
  ([command](../mirai-plugins/references/plugins.md#first-party-plugins)) and verify it with
  `mirai asset verify`.
- Identity and reimport (`cook/import/sources/reimport_test.odin`):
  - `the_parts_of_an_import_name_its_prefab_and_keep_their_ids_where_they_were_moved`;
  - `a_source_moved_or_renamed_keeps_the_ids_of_its_import`;
  - `a_material_renamed_in_the_source_keeps_its_id_and_a_part_taken_out_is_left_alone`;
  - `a_material_is_a_part_only_when_its_texture_is_an_atlas_of_one_model`;
  - `a_second_model_with_the_same_textures_takes_its_material_and_both_lose_it_as_a_part`;
  - `importing_again_keeps_what_was_changed_in_a_material_and_takes_the_rest_from_the_source`
    (over a copy of manny with its roughness changed and another texture in the source).
- `mirai_import_writes_assets_that_mirai_asset_verifies` needs `MIRAI_ROOT` (defined by
  `mirai test`); run it when touching `cook/import/sources/command.odin`. It imports in-process
  with `command`; the whole path (`mirai import` → `mirai-import`) needs the built engine.
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
