# Asset formats and API

Container, typed tables, asset types, registry and text. By topic:

- [std/serial](serial.md): streams, schemas, migration, paths and JSON.
- [Asset types in detail](kinds.md): mesh, skeleton, texture, material, fracture, animation, sound
  and interface.
- [Scene and prefab](scenes.md): the `asset.Scene` document and prefab instances.
- [`mirai asset` tool](cli.md).

## Container

Little endian (`asset/container.odin`): a fixed header (magic `MIRA`, type fourcc, container and
type version, flags, id, `owner`, the `content_hash` of everything that follows), a directory of
chunks (tag, compression `None`, `LZ` or `Codec`, alignment, offset and sizes) and the chunks,
each at a multiple of its alignment.

- **The header id is an asset's only identity**: nothing derives it from its path, name or source,
  and a moved or renamed asset remains the same.
- `owner` is the asset this one is a part of (the prefab of the import that made it); zero for one
  of its own. `Document.owner` and the `owner` of each importable `*_Desc` write it;
  `header_owner_set` and `file_owner_set` change it without touching the content or `content_hash`.
- `header_read` validates only the header (what a scan uses). `blob_open` validates the whole file:
  exact size, each chunk inside the file and aligned, uncompressed size reachable by an LZ
  stream of that size (`pack_reach`) and a total memory limit (`DEFAULT_MEMORY_LIMIT`).
- `blob_build` stores a chunk compressed only when that shrinks it. The dependencies, names,
  schema and table directory are stored as they are: a scan reads them without a decoder.

### Compression

A stream that is not LZ starts with a zero byte, the fourcc of its codec, its piece count and the
size of each piece: a reader knows what decodes it from the stream (`codec_stream.odin`).
`block_pack`, `Block_Encoder` and `unpack` are the entry points of what compresses outside a chunk
(mesh pages, terrain blocks, the parts a journal sends over the network, editor thumbnails, the
shaders the executables embed), and what a game's compression decides goes through them.

- **The codecs of the engine** are Zstandard (`std/zstd`) for what loads once or travels and LZ4
  HC (`std/lz4`) for what streams (`codec_open.odin`), with blocks by `cook/encoders`. A checkout
  that holds the real `std/compressor` and `cook/compressor` packages writes LZ with BC7Split
  instead and reads both; a checkout without them reads everything but LZ streams, which are
  `Codec_Missing` there.
- **Versioned assets hold no LZ.** `mirai asset repack <file>...` writes an asset again with the
  codecs of the engine, a texture with its blocks as they are; a terrain is saved again by its
  plugin, which writes the size of each block.
- **What a game ships with** is `build.compression` of its project: `compression_mirai` is LZ and
  BC7Split, `compression_open` the open codecs, `none` stores everything, and a plugin brings its
  codecs (`std/codec`). Empty is the first of LZ and the open ones the checkout has. A cook writes
  what is not LZ with `Pack_Codecs`, so that what stores blocks outside a chunk keeps its format.
  A game without LZ is built with `ASSET_LZ=false` and its textures without BC7Split nor planes of
  fields; one without the open codecs, with `ASSET_OPEN=false`.
- **What a game writes** goes through `Types.writes`: a document takes it from the types it is
  made with, so that a save compresses with the codecs of the plugin that compressed the game.
- **Block tables.** A kind whose asset stores blocks it reads alone keeps them in `<name>_blocks`,
  with the `Block_Record`s of its pages in `<name>_pages`. A cook that does not ship with LZ
  compresses them again from what the records say; a record without its `raw` size is
  `Blocks_Old`, and saving the asset again writes it.
- **Packs.** A write says how hard it compresses (`Pack`): `PACK_EDIT` for what the editor,
  imports and the game save. A cook hands the packs of `cook/compressor/lz`: `SHIP` for the
  cooking of a shipped game, which writes every asset again with `document_repack` (its chunks,
  the pages of a mesh and its block tables), and `QUICK` for the cook of a dev game, a few times
  faster and a little larger. A codec takes the level of each from its `codec.Encode`. All
  decode the same way.
- **Pieces.** A chunk over `PACK_PIECE` is a run of streams of that many raw bytes, each
  decoding without the others: a scene load decodes them at once on its workers
  (`Piece_Decoders`), and a write with a worker compresses them at once into the same bytes.
- **Decoders.** `Decoder` holds the scratch of the decoders of the streams, made once by
  whoever reads (a job keeps one per thread) and lent to `asset_open`/`asset_load`; an asset opened
  without one makes its own the first time it decodes. A mesh page or a terrain block decodes with
  a `Stream_Decoder` of its reader (the renderer keeps one per worker).
- **Texture levels.** The `texels` column holds the smallest level first: a read of the small
  levels decodes only the start of the stream. With LZ, a BC7 texture written by `cook/textures`
  stores BC7Split streams of runs of levels (the `bc7split` table), and BC1, BC3 and BC5 may store
  planes of fields ([texture](kinds.md#texture)); `texture_decode` restores them into memory of the
  asset before the renderer takes them.

#### Codec packages

- `std/zstd` and `std/lz4` (runtime): Odin translations of Zstandard and LZ4 HC, with the license
  and the commit each comes from beside them. A game saves with them, so the encoders are runtime.
- `std/codec` (runtime): the shape of a compression plugin, by the C convention: how a game
  decodes its streams and how a cook writes them and makes blocks.
- `cook/encoders/{rgbcx,bc7enc,rdo,bc6h}` (engine-time): Odin translations of bc7enc_rdo and of
  Intel's BC6H encoder, which `cook/textures` runs (`open.odin`) when the checkout has no private
  encoders.
- `std/compressor` and `cook/compressor`: optional, see [compression](#compression). Tracked here
  are only the `placeholder.odin` that keep the API the engine compiles against.

## Typed tables

An asset is a set of **tables**; a table is a set of **columns** of equal length; a column keeps
the images of values of one type of the file's schema. The chunks, in this order: `DEPS` (ids it
names, sorted and without repeats), `STRS` (names), `SCHM` (the `std/serial` schema), `TDIR`
(directory of tables and columns), the record columns (`RECS`, and `IMPT` that of the `Import`
table) and finally the `BULK` ones.

- Table flags: `Single` (one row, read without an index), `Bulk` (heavy data for direct use; the
  tools summarize them), `Import` (provenance).
- An unnamed column is the row itself and is the only one in its table.
- `key` is the column that identifies the rows; `ref` says that the values of a column (unsigned
  integers) are rows of another table.
- Names: without dots, brackets, `@`, `=`, quotes, spaces or controls.
- More than one row requires some column with size: the number of rows never exceeds the data that
  backs them.

### Reading: `Asset`

- `asset_rows(&a,&types,"table","column",T,default)` returns `[]T`: **the file itself** if the
  column is uncompressed, aligned and with `T`'s layout; otherwise, a decompressed or migrated copy
  that belongs to the `Asset`. `asset_row` is the row of a one-row table.
- `asset_load_front` reads everything but the bulk columns, which stay in the file to be read by
  range (`blob_chunk`); it does not check the hash and reaching a bulk one gives `Truncated`. A
  terrain's pages use it.
- `asset_column_*` read against another schema (that of the world's components).

### Building and editing: `Document`

Owner of everything it contains; `asset/document.odin` builds by tables, columns and rows.

- Writing (`document_write`/`document_save`) validates (`document_check`), derives dependencies and
  is a function of the content only: reading and writing again gives the same bytes.
- Adding a table or column checks the reservation of the name, the data and the destination array
  before publishing it. On out of memory it returns `Out_Of_Memory` and index `-1`, frees what was
  reserved and keeps existing tables and rows; it can be retried. An empty name produced by a
  failed reservation is not interpreted as an unnamed column.
- Paths and values: `document_locate`, `document_get`, `document_set` ([syntax](cli.md#paths));
  text: `document_text_write`/`document_text_read`; differences: `document_diff`.

`asset.Types` contains the schema of the program's types, their hashes and layouts.

- `types_index(&types,T)` adds a type the first time; it returns `ok=true` only when its hash,
  transient field and layout tables are also ready.
- `Types.error` distinguishes `Invalid` from `Out_Of_Memory`; a later call retries completing the
  tables even if the schema already knows the type.
- `document_from_asset` and text reading reject an incomplete hash update.

## Asset types

`asset.KINDS` gives extension, fourcc, name and version of each engine type; their tables are in
their `asset/<type>.odin` and `mirai asset info` shows them. Contract of each: [kinds.md](kinds.md);
scenes and their prefab instances: [scenes.md](scenes.md). The plugins' types are declared and
validated by their plugin without adding them to the core:
[`.character`](../../mirai-animation/references/animation.md#components-and-shared-data),
[`.foliage`](../../mirai-world/references/foliage.md#format),
[`.terrain`](../../mirai-world/references/terrain.md) and
[`.physics_cache`](../../mirai-plugins/references/physics-cache.md).

- **`.mesh`** (`MESH`): `mesh` (`Mesh_Info`); `clusters` bulk (`Cluster`); `levels`
  (`Mesh_Level`); `vertices` bulk with columns `vertex` (`Cluster_Vertex`), `uv1`, `color`, `skin`
  (`Skin_Vertex`) and `surface` (`Surface_Vertex`, of a far mesh, `Has_Surface`, always with
  `color`); `triangles` bulk (`u32`, `u8` indices four at a time); `slots` (`Material_Slot`);
  `joints` (the mesh's bind to the skeleton); `morphs` with `morph_deltas`; `colliders` with
  `collision_points` and `collision_indices`.
- **`.skeleton`** (`SKEL`): `skeleton` (`Skeleton_Info`), `bones` (`Skeleton_Bone`), `sockets`
  (`Skeleton_Socket`).
- **`.tex`** (`TEX `): `texture` (`Texture_Info`, with `layers` defaulting to 1), `mips`
  (`Texture_Mip`, with all the layers of each level), `texels` bulk.
- **`.mat`** (`MAT `): `material` (`Material_Info`), `imported` (`Material_Info`, of an imported
  material: what the source gave), `parameters`, `overlays`, `hidden`.
- **`.scene`** (`SCEN`): `entities`, a table per component (those of prefab instances among
  them), `scene`, `overrides` and `off` (turned-off components). `Header_Flag.Prefab` makes it a
  [prefab](scenes.md#prefab).
- **`.anim`** (`ANIM`): `clips` (`Animation_Clip`), `tracks` (`Animation_Track`), `keys`
  (`anim.Keyframe`), `markers` (`Animation_Marker`, a moment or, with a duration, a span) and the
  bulk `streams`, empty but in a cooked `.anim`.
- **`.sound`** (`SND `): `sound` (`Sound_Info`) and one of two bulk tables: `samples` (`i16`) or
  `file` (`u8`).
- **`.sound_set`** (`SSET`): `sound_set` (`Sound_Set_Info`).
- **`.ui`** (`UI  `): the records of `ui.Tree_Data` (`ui/tree_data.odin`).
- **`.records`** (`RCDS`): `records` (`Records_Info`), `rows` with `id`, `name` and `value` (the
  code's type, with the file's schema), `texts` (`Records_Text`) and `text` bulk
  ([records](kinds.md#records)).
- **`.particle`** (`PART`, of the [`vfx`](../../mirai-world/references/vfx.md#format) plugin):
  `particle` (`Particle_Info`), `parameters` (`Particle_Parameter`), `hidden` (`Particle_Field`).
- **`.fracture`** (`FRAC`, of the `destruct` plugin): `fracture` (`Fracture_Info`), `pieces`,
  `connections`, `clusters`, `vertices` (`Vertex`) and `indices` local to each piece.
- **`.foliage`** (`FOLI`): `foliage` (`Foliage_Info`), `types`, `cells`, and packed bulk `manual`
  and `overrides`; defined and validated by the
  [foliage](../../mirai-world/references/foliage.md#format) plugin.
- **`.physics_cache`** (`PCAC`): format of the
  [physics_cache](../../mirai-plugins/references/physics-cache.md) plugin (unique geometry, tracks,
  frames and poses).

Any can have the `import` table (`Import_Info`: source, name of what was taken from it, position,
size and hash of what was read, importer, its version and that of its format, and the settings
hash); the asset then carries the `Cooked` flag (`import_put`). That record is the [import
cache](../../mirai-imports/references/imports.md#import-cache) and the only thing that
says where an asset came from. `import_peek(path,&types)` reads the header and the `Import_Info`
from the
front of the file (header, directory and chunks up to `IMPT`, before the bulk ones), without loading
meshes or textures: the search for an import's outputs uses it.

### Versions

One rule for all types, of the engine and of plugins:

- **A type reads only the version it writes** (`*_VERSION`): each `*_view` (and a plugin's read)
  starts with `kind_check(&a,KIND,VERSION)`, which gives `Invalid` for another type and `Version`
  for a file of another version, older or newer. The engine's types carry theirs in `KINDS`.
- **A change in what a type stores or in what a stored value means raises its version**, and every
  file of the type is made again. `version_message` says which asset it is, its type, its version
  and the one the build reads and, if it was imported, the `mirai import` that rebuilds it in its
  folder with the root where its source is; for a newer file, a newer engine. `mirai asset verify`
  and the `asset_errors` of `engine.diagnostics` show it.
- **Rows are read by the schema the file carries**, by field name (`serial.Migration`): the types
  a game declares (components, records) change while its files stay, and a field their file lacks
  reads the default of the read (`asset_rows` with `default`). The rows of an asset type hold
  every field of its version: its read asks for them `whole`, and a file that does not store one
  fails with `Version`; `version_message` names the table and the field. A table a file may omit
  reads empty (`table_rows`, like `skin` in `vertices`).
- **Saving writes the current version**: a type's `*_document` and a scene taken as `asset.Scene`
  stamp it. A generic `Document` (`mirai asset set`, a merge, a move) keeps the version of the file
  it came from, and its rows that file's schema.

## Registry

`asset.Registry` (`asset/registry.odin`, with the behavior of each operation in its comments) knows
which file of a folder has which id, of what type and what it depends on. A scan reads only the
start of each file, skips names that start with a dot and files being written, and keeps what it
saw in a cache: a file whose size and date did not change is not opened again, not even in another
run. The editor has the cache in the project's `.mirai/cache/registry`; the player, cooking and
`mirai asset` do not use it. What a scan saw depends on how the build reads a header: a cache (or
packed index) of another `REGISTRY_CACHE_VERSION` or container `VERSION` is not read, and the
scan opens every file and writes it again.

- `registry_refresh` updates only the paths it is given, without walking the folder: the editor
  uses it with what it writes (save, import) and the watcher with what it sees change
  ([host](../../mirai-core/references/host.md#failures-unloading-and-watching)).
- `Registry.revision` advances before a scan, a refresh or a load replace files and paths, even if
  the operation fails. The rows and their borrowed strings are valid until then: whoever caches them
  checks the revision, even if the address and count of `files` repeat. It belongs to the registry,
  not to the GPU resource counter of `host.Assets`.
- With a cache, `Registry.removed` gathers the ids that no file is anymore, also those deleted with
  the program closed. Whoever keeps something per asset (the
  [previews](../../mirai-editor/references/panels.md#previews)) reads them and empties it.
- `Registry_File.flags` are those of the header: `registry_prefab` reads from them whether a scene
  is a prefab ([prefab](scenes.md#prefab)).
- `registry_dependents` comes from an inverse index built with each change: how many use an asset is
  its length, without walking the files (`asset.list` reports it as `used_by`).
- **Imported folders.** An assets folder may have an imported folder with it (that of the root
  and of each mount: `.mirai/imported/` of the project or the plugin): what the
  [imports](../../mirai-imports/references/imports.md#identity-and-reimport) of its sources build
  that nobody edits, never versioned, each file named by its id and the key of what it was built
  from. A scan reads the sidecars it walks (`asset/sidecar.odin`, the one reader of the format)
  and lists each output of the cache like any asset (`Registry_File.imported` is that key) at
  `<folder of the sidecar>/<folder it names>/<name><extension>`; two outputs of one kind and
  name are told apart by their index, and a path another file or output has takes the name of
  the source: never the order of a scan. One whose source is gone is not listed, and one that
  moved is listed there at the next scan, which a refresh of a sidecar or of its source runs.
  `registry_file_path` gives the file of either folder. A cooked folder has none: the cook
  writes every asset at its path.
- **Mounts.** `registry_mount` adds a folder under a prefix (a plugin's assets, in
  `plugins/<name>`). A prefix that starts with a dot belongs to the program's assets (the editor's,
  in `.editor`): they are found by id and by path, but a project's lists omit them
  (`registry_listed`). Whoever opens a file by its registry path resolves it with
  `registry_file_path`.
- **Guest mounts.** `registry_mount_guest` mounts while running a folder the program did not ship
  (what a player saved or downloaded, mods) and reads its files at once, also over a packed index;
  `registry_unmount` takes it out with its files. What the program has wins: a guest file whose id
  a file outside the guests has, or a guest file before it in path order, is not in the registry,
  neither by id nor by path, and stays in `Registry.refused` until a scan, a refresh of its path or
  the unmount. `host` opens a guest file with a byte limit far below the default one
  (`ASSETS_GUEST_LIMIT`, read and decompressed).
- **In-memory files** (`registry_memory.odin`): what an editor changed in a step that has not ended
  and so has not written. While a
  path is in memory, its registry entry is what that content says and `registry_read` gives its
  bytes; a scan or a refresh keep it, the cache and the index do not store it, and
  `registry_memory_write` writes it and forgets it. A file outside the folders (a program's `.slang`
  source) can also be in memory (`registry_outside`), without being a registry file: whoever reads
  it asks the memory and, without it, the disk.
- **Packed index.** `registry_save` writes what the registry has and `registry_load` reads it
  without looking at the folder.
  [Cooking](../../mirai-projects/references/build.md#asset-cooking) leaves it as `.index`
  (`REGISTRY_INDEX`) and `host.assets_init` uses it instead of scanning: the folder is then what
  its index says (`Assets.indexed`) and `assets_scan` does not look at it again, nor
  `assets_refresh` outside the guest mounts; an unreadable one is ignored and scanned. Whoever opens
  a file still checks its hash, id and type.
- **Repeated ids.** Several files with one id are copies made outside the editor of one of them.
  With `Registry.resolve_duplicates` (the registry of `host.assets_init`), the oldest is the
  original (`file_newer`) and each copy receives, in the registry's memory, an id of its own derived
  from the one it had and from its path, so it is the same on each scan until its file is written
  with it; it stops being part of another asset and an output of an import. An unedited copy follows
  its file; one that was already in memory with the repeated id is an edit and keeps it. A tool that
  only reads (`mirai asset ls`, cooking) does not activate it and sees the pair in `r.duplicates`.
  The cook refuses the pair (`Duplicate_Id`, naming both files): which one the editor takes depends
  on the creation times of a machine, so a game ships neither until the copy is written with its own
  id.

## Text

`document_text_write` produces the JSON that `mirai asset dump` prints and `unpack` saves, of
every kind but a scene and a `.ui`, whose text is their document ([CLI](cli.md#subcommands)):
`mirai_asset`, the header (`kind`, `kind_version`, `id`, `owner` only on a part of another asset,
`flags`), `dependencies`, the optional `schema` and the `tables`, each with its columns and `data`.

- One row per line. With a single unnamed column the row is the value; otherwise, an object with one
  value per column.
- `"schema"` is written with `Text_Options.schema`. `Bulk` tables carry no `"data"`: with
  `bulk=.Files` each column names its file. `Text_Options.diff` is the text
  [git diffs](cli.md#git).
- `document_text_read` rebuilds the document (with a `Bulk_Loader` for the files) and reports
  `Text_Problem {code, rule, offset}`.
