# Asset formats and API

Related: [std/serial](serial.md), [asset types in detail](kinds.md),
[scene and prefab](scenes.md), [`mirai asset` CLI](cli.md).

## Container

Little-endian (`asset/container.odin`): fixed header (`MIRA`, fourcc, container/type versions,
flags, `id`, `owner`, `content_hash` of payload), chunk directory (tag, `None`/`Stream`, alignment,
offset, sizes), and aligned chunks.

- **Identity**: header `id` is sole identity (path/rename invariant). `owner` marks part-of-import
  assets (`Document.owner`, `*_Desc.owner`; `header_owner_set`/`file_owner_set` keep
  `content_hash`).
- **Validation**: `header_read` validates header only (scans); `blob_open` checks size, chunk
  bounds/alignment, `PACK_MAX`, and `DEFAULT_MEMORY_LIMIT`.
- **Store objects** (`asset/parts.odin`): [store](../../mirai-store/SKILL.md) object with header +
  directory as root meta and one group per chunk in canonical `Codecs.None` layout (`object_put`
  strips outer compression; splits `texels` by mip smallest-first, mesh `page_data` and block
  tables by block). `object_file` reconstructs exact bytes. `asset_open_object` validates meta vs
  groups and reads chunks lazily (`Not_Here` if absent; no whole-file hash check).
- `blob_build` compresses a chunk only if smaller; `DEPS`, `STRS`, `SCHM`, `TDIR` stay uncompressed
  so scans need no decoder.

### Compression

Streams (`asset/compress.odin`): version byte, `data.Format` (`STORED` or MDC2), piece count/sizes.
`pack`, `Stream_Encoder`, `unpack` compress non-chunk data (mesh pages, net journals, thumbnails,
embedded shaders).

- **MDC2** (`std/compressor/data`): entropy tags with inline short lengths, aligned distances,
  prev-distance literal deltas, cross-block matches, preallocated scratch. Texture blocks encode on
  GPU ([texture cooking](../../mirai-imports/references/imports.md#textures-cooktextures)).
- **Profiles & codecs**: `data.Profile` `Fast` (editor/imports/runtime), `Balanced` (dev cook),
  `Ultra` (ship cook), `profile_streamed` (`Speed` for streamed assets). `Codecs` is `None` or
  `Compressed` (cook uses `build.compression`; unknown format -> `Codec_Missing`).
- **Block tables & pieces**: `<name>_blocks` + `<name>_pages` (`Block_Record`) self-code and skip
  outer/store compression. Chunks `> PACK_PIECE` split into independent parallel pieces
  (`Piece_Decoders`). Reuse `Decoder` / `Stream_Decoder` per worker thread. `texels` stores
  smallest mip first ([texture](kinds.md#texture), `texture_decode`).

## Typed tables

Chunk order: `DEPS` (sorted unique ids), `STRS`, `SCHM`, `TDIR`, `RECS`/`IMPT`, `BULK`. Table
flags: `Single` (1 row), `Bulk` (heavy data), `Import`. Unnamed column = sole row column; `key`
identifies rows; `ref` indexes another table; names forbid dots, brackets, `@`, `=`, quotes,
spaces, controls; `rows > 1` requires a sized column.

- **Reading (`Asset`)**: `asset_rows` returns zero-copy slice when uncompressed, aligned, and same
  layout; else owned decoded/migrated copy. `asset_row` reads a `Single` table. `asset_load_front`
  skips bulk (`Truncated` if touched, no hash check). `asset_column_*` reads against an external
  schema.
- **Writing (`Document`, `asset/document.odin`)**: deterministic `document_write`/`document_save`
  (runs `document_check`, derives `DEPS`). Reservations are OOM-safe (`Out_Of_Memory`, index `-1`,
  retryable; failed name reserve is not treated as unnamed). Paths/text/diff: `document_locate`,
  `document_get`, `document_set` ([syntax](cli.md#paths)), `document_text_write`/`read`,
  `document_diff`.
- **`asset.Types`**: `types_index` caches schema, hashes, transient flags, layouts (`Types.error`
  is `Invalid` or `Out_Of_Memory`, retryable; incomplete hashes rejected by `document_from_asset`
  and text reader).

```odin
// Read typed rows (zero-copy when uncompressed + matching layout)
types: asset.Types; asset.types_init(&types); defer asset.types_destroy(&types)
a: asset.Asset
if asset.asset_load(&a, path) == .None {
    defer asset.asset_close(&a)
    info, err := asset.asset_row(&a, &types, "material", asset.Material_Info, whole=true)
    params, _ := asset.asset_rows(&a, &types, "parameters", "", asset.Material_Parameter)
    _ = info; _ = params; _ = err
}
```

```odin
// Build and save a custom Document deterministically
doc: asset.Document
asset.document_init(&doc, asset.KIND_SOUND_SET, id)
defer asset.document_destroy(&doc)
doc.kind_version = asset.SOUND_SET_VERSION
info := asset.SOUND_SET_DEFAULTS
_ = asset.document_put_row(&doc, &types, "sound_set", &info)
_ = asset.document_save(&doc, out_path)
```

## Asset types

`asset.KINDS` registers engine fourcc/version (`mirai asset info`). Details in [kinds.md](kinds.md)
and [scenes.md](scenes.md). Plugin kinds (`.character`, `.pcg`, `.terrain`, `.physics_cache`)
live in their plugins.

| Kind | Fourcc | Tables |
| --- | --- | --- |
| `.mesh` | `MESH` | `mesh`, bulk `clusters`/`vertices`(`vertex`,`uv1`,`color`,`skin`,`surface`)/`triangles`, `levels`, `slots`, `joints`, `morphs`/`morph_deltas`, `colliders`/`collision_*` |
| `.skeleton` | `SKEL` | `skeleton`, `bones`, `sockets` |
| `.tex` | `TEX ` | `texture` (`layers` default 1), `mips`, bulk `texels` |
| `.mat` | `MAT ` | `material`, `imported`, `parameters`, `overlays`, `hidden` |
| `.scene` | `SCEN` | `entities`, per-component tables, `scene`, `overrides`, `off` (`Header_Flag.Prefab` -> [prefab](scenes.md#prefab)) |
| `.anim` | `ANIM` | `clips`, `tracks`, `keys`, `markers`, bulk `streams` (cooked only) |
| `.sound` / `.sound_set` | `SND ` / `SSET` | `sound` + bulk `samples`/`file`; `sound_set` |
| `.ui` / `.records` | `UI  ` / `RCDS` | `ui.Tree_Data` tables (`ui/tree_data.odin`); `records`, `rows` (`id`,`name`,`value`), `texts`, bulk `text` |
| `.particle` / `.fracture` | `PART` / `FRAC` | [`vfx`](../../mirai-world/references/vfx.md#format); `fracture`, `pieces`, `connections`, `clusters`, `vertices`, `indices` |
| `.pcg` / `.physics_cache` | `PCGG` / `PCAC` | `pcg`, `layers`, `cells` (`plugins/pcg/runtime/source.odin`); [`physics_cache`](../../mirai-plugins/references/physics-cache.md) |

Optional `import` table (`Import_Info`, sets `Cooked` via `import_put`) is the
[import cache](../../mirai-imports/references/imports.md#import-cache). `import_peek(path,&types)`
reads header + `IMPT` before bulk chunks.

### Versions

- **Exact version**: every `*_view` calls `kind_check(&a, KIND, VERSION)` (`Invalid` wrong kind,
  `Version` mismatch). Plugin kinds get `<STEM>_VERSION` from manifest `asset_kinds`
  ([manifests](../../mirai-projects/references/projects.md#manifests)).
- **Bump = rebuild**: format/meaning changes bump version; next build refreshes imports
  ([library](../../mirai-imports/references/imports.md#library)). `version_message` reports the
  reimport command (`mirai asset verify`, `asset_errors`).
- **Schema migration**: game types migrate by field name (`serial.Migration`, missing fields get
  `default`); asset-kind rows require `whole=true` (missing field -> `Version`); optional tables
  use `table_rows`. Typed saves stamp current version; generic `Document` preserves file version.

## Registry

`asset.Registry` (`asset/registry.odin`) maps folder files to id/kind/deps via header-only scans
(skips dotfiles and active writes), cached by size+mtime in `.mirai/cache/registry` (invalidated
on `REGISTRY_CACHE_VERSION` or container `VERSION` mismatch; player/cook/`mirai asset` skip cache).

- `registry_refresh` updates given paths only
  ([watching](../../mirai-core/references/host.md#failures-unloading-and-watching)).
  `Registry.revision` increments before every scan/refresh/load swap (even on failure); cached
  borrowed strings must check it. `Registry.removed` tracks vanished ids for
  [previews](../../mirai-editor/references/panels.md#previews). `registry_prefab` reads
  `Registry_File.flags`. `registry_dependents` uses a live inverse index (`used_by`).
- **Listed outputs** (`asset/packages_root.odin`): unedited import blobs live in the store via
  `root_packages` / `packages_resolve` (`Registry_File.listed`; `Not_Built` if missing, `Broken`
  if mismatched, invalid paths in `Registry.refused`; `registry_file_path` returns `""`; read via
  `registry_listed_object` / `registry_read` from `Registry.store`). Cooked folders have none.
- **Mounts**: `registry_mount` adds plugin folders (`plugins/<name>`); dot prefixes (`.editor`)
  are hidden from `registry_listed`; resolve disk paths with `registry_file_path`.
- **Guest mounts**: `registry_mount_guest` / `registry_unmount` load runtime user/mod folders;
  shipped assets win id collisions (losers go to `Registry.refused`); `host` enforces
  `ASSETS_GUEST_LIMIT`.
- **In-memory & index**: `registry_memory.odin` shadows uncommitted edits (`registry_memory_write`,
  `registry_outside` for `.slang`). Cooked `.index` (`REGISTRY_INDEX`) loads via `registry_load`
  (`Assets.indexed`, disables rescan outside guests).
- **Duplicates**: `Registry.resolve_duplicates` (editor/host) assigns deterministic in-memory ids
  to newer copies (`file_newer`), dropping owner/import flags; cook disables it and fails with
  `Duplicate_Id`.

```odin
reg: asset.Registry
if asset.registry_init(&reg, "demo/assets", "demo/.mirai/cache/registry") {
    defer asset.registry_destroy(&reg)
    _ = asset.registry_mount(&reg, "plugins/physics/assets", "plugins/physics")
    _ = asset.registry_scan(&reg)
    _ = asset.registry_refresh(&reg, {"control/control.scene"})
}
```

## Packages

Import records in the [machine store](../../mirai-store/SKILL.md) (`asset/packages.odin`):

- **`Package` manifest**: `manifests/<BLAKE3>` object (`packages/<id>` ref on ingest machine;
  versioned copy in `packages/<id>.mirai` via `package_file`). Holds source `identity`, `origin`
  (root-relative for in-root sources), and asset ids (random on first ingest, preserved on
  re-ingest). No engine-version data.
- **`Build` manifest**: `imports/<import_key>` (Final), `imports-fast/<import_key>`, and
  `builds/<build_select>` (chosen by refresh). Lists outputs and generated shader program objects.
- **`Packages` list**: versioned `packages.mirai`, written only by `project_pin`/`project_unpin`.
  Projects pin manifests, never builds; `package_load` verifies manifest file bytes against pin
  hash; `packages_resolve` lists outputs read-only.

## Text

`document_text_write` emits JSON (`mirai asset dump`/`unpack`, all kinds except scene/`.ui` which
use document JSON; [CLI](cli.md#subcommands)): `mirai_asset`, header (`kind`, `kind_version`,
`id`, optional `owner`, `flags`), `dependencies`, optional `schema` (`Text_Options.schema`), and
`tables` (1 row/line; `Bulk` omits `data`, `bulk=.Files` names files; `Text_Options.diff` omits
column type indices). `document_text_read` uses `Bulk_Loader` and reports
`Text_Problem{code, rule, offset}`.
