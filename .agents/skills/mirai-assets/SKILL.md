---
name: mirai-assets
description: Mirai binary assets (.scene, .prefab, .mat, .mesh, .tex, .anim, .sound, .sound_set,
  .ui, .font, .strings, .prompts, .records and those of plugins, such as .terrain and .foliage),
  their container, the `asset` package, the registry, prefab resolution (`cook/prefab`), the
  compression of assets (`std/compressor`, `cook/compressor`), `std/serial` and the `mirai asset`
  tool. Use when reading, creating or editing an asset, adding an asset type or a serialized
  component, compressing or decoding asset data, or when an asset does not load.
---

# Mirai assets

The packages are `std/serial` (streams, schemas, migration, paths, JSON), the codecs
(`std/compressor` and its packages, `cook/compressor/lz`, `cook/compressor/bc7split`) and
`asset` (container, compression, typed tables, asset types, scene/prefab, registry).

## Map

- Inspecting or editing a file: [subcommands](references/cli.md#subcommands),
  [paths](references/cli.md#paths) and
  [editing by unpack and pack](references/cli.md#editing-by-unpackpack); three-way merge:
  [merge](references/cli.md#merge).
- Which kinds git merges and diffs, `.gitattributes` and the drivers of a clone
  (`mirai setup git`): [git](references/cli.md#git).
- Container, tables, `Asset`/`Document`, types, versions, registry and asset JSON:
  [container](references/formats.md#container), [typed tables](references/formats.md#typed-tables),
  [asset types](references/formats.md#asset-types), [versions](references/formats.md#versions),
  [registry](references/formats.md#registry) and [text](references/formats.md#text).
- LZ, packs and decoders: [compression](references/formats.md#compression); what each codec
  package does: [codec packages](references/formats.md#codec-packages).
- Streams, schemas, migration, paths, text: [serial](references/serial.md#stdserial).
- Mesh, skeleton, texture, material, fracture, animation, sound, sound set, `.ui`, font, texts,
  prompts and game data tables (`.records`): [mesh](references/kinds.md#mesh),
  [skeleton](references/kinds.md#skeleton), [texture](references/kinds.md#texture),
  [material](references/kinds.md#material), [fracture](references/kinds.md#fracture),
  [animation](references/kinds.md#animation), [sound](references/kinds.md#sound),
  [sound set](references/kinds.md#sound-set), [interface](references/kinds.md#interface),
  [font](references/kinds.md#font), [texts](references/kinds.md#texts),
  [records](references/kinds.md#records) and [prompts](references/kinds.md#prompts). A plugin's
  types are its own: `.particle` ([vfx](../mirai-world/references/vfx.md#format)), `.terrain`,
  `.foliage`.
- Scenes, prefabs, instances and overrides:
  [scene and prefab](references/scenes.md#scene-and-prefab),
  [prefab instances](references/scenes.md#prefab-instances) and
  [resolution](references/scenes.md#resolution-against-the-current-prefab).

## Workflow

1. **Look before touching.** Inspect with the [CLI](references/cli.md); the file's schema allows
   reading any type.
2. **Editing an existing asset.** `mirai asset set` or `unpack`/`pack`
   ([CLI](references/cli.md)). From code: `asset.Document`, or `asset.Scene` for scenes and
   prefabs. In a game they are files of `assets/` written through the API or the editor; only the
   demo's tool writes them with `asset.Scene_Builder`. Meshes from code go through
   `asset.content_mesh` over the shapes of `std/geom`
   ([content tool](../../../docs/game/assets/content-tool.md)).
3. **Changing a serialized struct.** A component or a record of a game changes without a version
   or a converter: the reader migrates its rows by field name.
   - Renaming a field makes it another one: the previous value is lost and the new one takes the
     default.
   - A change in what an asset type stores (a field of its rows too) or in what a value means
     raises its `*_VERSION`: files of another version fail with `Version` and are made again
     ([version rule](references/formats.md#versions)).
4. **Adding an asset type.** Choose a fourcc and extension, declare the flat structs of its tables,
   write them with `document_put`/`document_put_row` and read them with `asset_rows`/`asset_row`.
   Minimal example: `asset/texture.odin` (description, `*_document`, `*_view`, `*_check`).
   `mirai asset` reads it unchanged.
5. **`.ui` interfaces.** When changing their records, keep `host.ui_tree_document`/`ui_tree_view`
   and `asset.ui_check` in line with the expansion and validation of `ui.tree_load`
   ([contract](references/kinds.md#interface)).
6. **Animation, skeleton and skin.** Keep the bind contract of the [mesh](references/kinds.md#mesh),
   the independent `.skeleton` and the `Keyframe` tangents. The limits of clips, tracks, keys and
   markers are checked before building the document; a mesh and its skeleton are checked together
   with `mesh_skeleton_check`.
7. **Pre-authored fracture.** Follow [`.fracture`](references/kinds.md#fracture): `Fracture_Builder`
   for separate meshes and proximity, or explicit tables. The runtime consumes the source by
   persistent identity and validates its budgets before creating bodies.

## Invariants

- **Flat data.** A table keeps images of structs without pointers, strings or slices: texts are
  `[N]u8` with tag `mirai:"text"`. What varies in length is another table.
- **The image is canonical.** `serial.value_write` zeroes the padding, the `transient` fields and
  what follows a text's NUL: equal values are equal bytes and writing the same document twice gives
  the same file. Do not write raw memory into a column.
- The JSON view may omit fields (`text_write.omit_fields`, [serial.md](references/serial.md));
  hiding authoring fields does not remove them from the persistent image.
- **The header id is an asset's identity**: nothing derives it from its path, name or source;
  `owner` says which asset it is a part of ([container](references/formats.md#container)).
- **Persistent identity.** What is stored names entities by `Entity_Id` and assets by `Asset_Id`,
  never by runtime index. The only stored position is the `entity` column of a component table. In
  scenes and prefabs a `base.Entity` field contains the `Entity_Id` of its target.
- **Dependencies are derived** from the `Asset_Id`s the values name; there is no separate list.
- **Nothing in the file is trusted without validating.** `blob_open`, `schema_read` and
  `asset_open` validate header, directory, schema and tables; each `*_view` validates ranges of its
  type. Code that indexes with file data validates first or uses checked accesses. The decoders
  (`unpack`, `bc7split.decode`, `schema_read`, `text_read`) allocate no more than the input backs.
- **LZ is the only codec** (the user's choice), for every class of data: load-once chunks,
  streamed mesh pages and texture levels (BC7 after BC7Split). Its decode with the loader's jobs
  keeps up with an NVMe; a stream of another codec is `Unsupported`.
- **Decoders are preallocated.** `compressor.Decoder` and `bc7split.Decoder` hold all the scratch,
  allocated once by whoever reads; `decompress` and `bc7split.decode` never allocate, and for any
  input never read outside `src` nor write outside `dst`.
- **The decoder side stays light.** `std/compressor` and `std/compressor/bc7split` import no
  encoder; the
  encoders import the decoder's format. A rule both sides share (a header, a constant, the
  prediction of packed code lengths) is written once, in `std/compressor/format.odin`.
- **A game compiles only the fast encoder.** `std/compressor/lz` parses the levels a save uses;
  the optimal parser and its match finders are in `cook/compressor/lz`, and a write reaches them
  through its `Pack`: `asset` never imports `cook`, and every level is the same stream format.
- **The encoders are deterministic**: the same input, codec and level give the same bytes.
- **A block format is described once.** `asset/texture_bc7.odin` and `asset/texture_bc6h.odin`
  hold the modes, partitions, anchors, weights and decode of BC7 and BC6H; the encoders of
  `cook/compressor/texture` build their records from those tables and keep no rows of their own.
- `asset.Types` is the context with the schema of the program's types: it is created once and
  passed to reads and writes.
- **Atomic writing.** `document_save` and `scene_save` write a temporary and rename;
  `mirai asset set` does not leave the file half-written if a value is invalid.
- **A scene is one file**, not one per entity.
- **A guest mount never takes an id the registry has**: what the program shipped wins over what a
  player adds ([guest mounts](references/formats.md#registry)).

## Verification

- `mirai test std/serial` and `mirai test asset`, whose cases are named for what they check;
  generated assets, with `mirai asset verify`. Focal tests by topic:
  - merge: `asset/merge_test.odin`; git: `cook/build/git_test.odin` (the attributes follow the
    kinds), and by hand a repository after `mirai setup git` with two branches that edit different
    fields and the same field of a scene (`git diff`, `git merge`);
  - prefab instances: `asset/scene_test.odin`, `mirai test engine/scene` (on loading) and
    `cook/build/cook_test.odin` (on cooking);
  - textures: `asset/kinds_test.odin` (round trip of every format, layers, partial reads of the
    small levels) and the blocks and planes of fields in `texture_blocks_test.odin`;
  - animation, skeleton, skin and fracture: `content_test.odin`, `kinds_test.odin`,
    `skeleton_test.odin` and `fracture_test.odin` of `asset`; font, texts and prompts:
    `asset/interface_kinds_test.odin`; game data tables: `asset/records_test.odin`;
  - versions: `asset/versions_test.odin`; a plugin's own steps, in its plugin (`.match` and
    `.pose`);
  - registry: `asset/registry_test.odin` and, in the editor, `editor/content_test.odin`;
  - layers of an imported material: `asset/kinds_test.odin`, and the overrides shared with prefabs
    in the editor, `editor/prefabs_test.odin`;
  - JSON inspection with transient fields: `std/serial/text_runtime_test.odin`.
- CLI: `asset/cli_test.odin` when touching `tools/mirai/asset.odin`, `asset/doc_text.odin`,
  `asset/locate.odin` or `asset/diff.odin`; it needs `MIRAI_ROOT`, which `mirai test` defines.
- Readers: files truncated at every length and mutated bytes in `asset/fuzz_test.odin`, which a new
  format or chunk extends; damaged files must give exit 0, 1 or 2 in `asset/cli_test.odin`.
  `-sanitize:address` repeats the tests with the sanitizer.
- Out of memory: `std/serial/schema_memory_test.odin`, `asset/document_oom_test.odin` (both also
  with `--release`) and `asset/types_memory_test.odin`. If schema validation changes, add
  `hostile_schema_binary` and `hostile_random_schemas_validate` of `std/serial/hostile_test.odin`
  with `--release` and `-define:SERIAL_HOSTILE_ROUNDS=20000`.
- `.pose`, `.blend` and `.action` are verified in their [plugin](../mirai-plugins/SKILL.md).
- Compression: `mirai test std/compressor/lz` and `mirai test cook/compressor/lz` (every level
  decodes through `std/compressor`),
  `asset/container_test.odin` (chunks with alignment and compression) and the pages in
  `asset/mesh_page_code_test.odin`. Codec packages: `mirai test` of `std/compressor` (library
  streams, hostile streams, decoding without allocating), of each package under
  `std/compressor/lz` (hostile inputs, determinism), of `std/compressor/bc7split` and of
  `cook/compressor/bc7split` (the encoder matches the library).
- A change to the LZ decoder: `mutated_streams_never_escape_their_buffers` with a large budget,
  in the background, under the sanitizer and with `COMPRESSOR_CHECKED`, which compiles the tables
  the decoder builds from a stream as bounds-checked slices. The test changes bytes anywhere and
  the headers and tables of valid streams, and poisons the guards around the stream, the output
  and the scratch, so the sanitizer reports any read or write outside them:
  `mirai test std/compressor mutated_streams_never_escape_their_buffers -sanitize:address
  -define:COMPRESSOR_CHECKED=true -define:COMPRESSOR_MUTATIONS=4000000 --timeout 0`.
  `-define:COMPRESSOR_MUTATION_SEED=<n>` gives another sequence, for runs side by side.
- Benchmark (not routine):
  `mirai test asset scene_file_against_a_file_per_entity --release -define:ASSET_BENCH=true`.
