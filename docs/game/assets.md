---
name: assets
description: Import models, textures, fonts, sounds and texts into a Mirai game project and write
  assets from a content tool. Use for mirai import, glTF/FBX/OBJ, .mesh .tex .sound .strings
  .records, asset ids, cook.mirai, tools/content, or an asset missing from the built game.
---

# Game assets

Assets are binary files under `assets/`; art sources stay in `source/`, never shipped. Every
asset has an id in its header: code and scenes name assets by id, never by path.

## Map

- Import a file: [Import](#import). Kinds: [Kinds](#kinds). Use an asset: [Reference](#reference).
- Check or edit a file: [Inspect](#inspect). Generate assets by code:
  [content-tool.md](assets/content-tool.md).

## Import

Put the file in `source/`; from the project folder, one `--out` folder per model (names clash):

```sh
mirai import source/models/hero.glb --out assets/models/hero --root .
mirai import source/textures/rock_n.png --out assets/textures --root .
mirai import source/sounds/step.wav --out assets/sounds --root .
```

- Formats: OBJ, glTF/GLB, USD, FBX; PNG, JPEG, TGA, BMP, GIF, PSD, HDR; WAV and Ogg Vorbis (mono
  or stereo); TTF, OTF; CSV texts (`key,en,es`); prompt manifests. `mirai import` with no
  arguments lists every flag.
- A model writes meshes, materials, textures, skeletons, clips and a `.prefab`: instantiate that.
- An image is color unless its name says otherwise (`normal`, `_n`, `rough`, `metal`, `orm`,
  `_ao`, `height`, `mask`); force it with `--srgb`, `--data`, `--normal`, `--normal-green-down`.
- Flags are saved in `<file>.import` beside the source and repeat on the next import.
- `--max-triangles N`, `--max-texture N`, `--collision none|hull|pieces|mesh|exact`; colliders a
  source brings win unless `--force-collision`.
- A model without a skeleton that must animate: `--rig humanoid` (or `fox`, `horse`, `bird`,
  `dragon`, `kaiju`, `shark`, `snake`, `spider`). Clips of another file onto a skeleton the
  project has: `--skeleton <id>` ([animation](animation.md)).
- Importing again from the same path updates in place, keeping ids and material edits; after
  moving or renaming the source pass `--into <id>` of its prefab, texture or sound.
- With an editor session: `asset.import` (MCP `asset_import`), then `mirai rpc
  asset.import_status --project . --wait-until importing=false`; after a CLI import,
  `asset.reload`. `asset.list` shows what exists; `engine.describe` the method fields.

## Kinds
- Engine: `.mesh` `.skeleton` `.mat` `.tex` `.anim` `.sound` `.sound_set` `.ui` `.font`
  `.strings` `.prompts` `.records` `.scene` `.prefab` `.fracture` `.physics_cache`.
- Plugins add `.particle`, `.terrain`, `.foliage`, `.navmesh`, `.match`, `.agraph`, `.pose`,
  `.blend`, `.motion`, `.action`.
- The editor imports into `models/<name>`, `textures`, `sounds`, `fonts`, `texts`, `prompts`.
  Sound sets: [audio](audio.md); particles: [vfx](vfx.md).

## Reference

- A `base.Asset_Id` field of a component holds an id; tag it `mirai:"kind=.tex"` (several:
  `kind=.anim .match`) so the inspector lists only those; fill it in the scene or prefab.
- Imported ids are random: read them with `asset.list` or `mirai asset ls assets`. A constant in
  code is only for assets your own tool writes with `base.asset_id_named`.
- What only code refers to (a prefab spawned by id) ships only as a root in `cook.mirai`:
  `{"roots":["prefabs/Enemy.prefab","sounds/"]}` (path under `assets/`, folder with `/`, or id).
- Texts: `host.strings_text(host.content_strings(app,id),base.name_hash("en"),
  base.name_hash(key))` gives `(text,found)`. `mirai texts export|import <file.csv>` moves the
  translations of `.ui` files through the open editor.
- Game data: a struct tagged `@(record)` is a catalog (items, dialogue, waves) whose rows live in
  a `.records` file (`asset.create` kind `records`; `records.add`, `records.set`). A
  `core.Record(T)` field names a row; read it with `core.record(rows,ref,problems,entity)`.

## Inspect

- `mirai asset ls <folder>`, `info`, `verify <file>...`, `deps <file> --users`, `dump`,
  `get <file> <path>`, `set <file> <path>=<value>` (`entities[@0x20].name=Lamp`); rows are
  added by `unpack`, editing `asset.json`, `pack`.

## Pitfalls that fail silently
- A hard-coded id of an imported asset matches nothing in another checkout: ids are random.
- An asset only code uses, missing from `cook.mirai`: works in Play, absent from the build.
- Roughness or ORM imported as color: `--data`. DirectX normals: `--normal-green-down`.
- `.ttc` and `.woff` fonts, three or more audio channels, Draco or meshopt indices: refused.
