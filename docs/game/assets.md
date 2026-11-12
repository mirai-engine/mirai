---
name: assets
description: Import models, textures, fonts, sounds and texts into a Mirai game project and write
  generated assets from a content tool. Use for mirai import, glTF/FBX/OBJ, .mesh .tex .sound
  .strings .records, asset ids, cook.mirai, tools/content, or an asset missing from the built game.
---

# Game assets

Assets are binary files under `assets/`, in folders by theme, beside the art sources they are
imported from (never shipped). Components and scenes name an asset by its id; code, by its path.

## Map

- Import a file: [Import](#import). Kinds: [Kinds](#kinds). Use an asset: [Reference](#reference).
- Check or edit a file: [Inspect](#inspect). Interfaces and scenes as text:
  [text-sources.md](assets/text-sources.md). By code: [content-tool.md](assets/content-tool.md),
  props [props.md](assets/props.md), terrain and sea [whole-scene.md](assets/whole-scene.md).

## Import

Put the file in `assets/`, in the folder of what it is for, and import it where it is:

```sh
mirai import assets/player/hero.glb     # its materials and prefab go to assets/player/hero/
mirai import assets/arena/rock_n.png    # its texture is listed as assets/arena/rock_n.tex
mirai import assets/player/step.wav     # assets/player/step.sound
```

- Formats: OBJ, glTF/GLB, USD, FBX; PNG, JPEG, TGA, BMP, GIF, PSD, HDR; WAV and Ogg Vorbis (mono
  or stereo); TTF, OTF; prompt manifests. Texts are `.strings`: [texts](ui/texts.md).
- A model writes meshes, materials, textures, skeletons, clips and a prefab: instantiate that.
- An image is color unless its name says otherwise (`normal`, `_n`, `rough`, `metal`, `orm`,
  `_ao`, `height`, `mask`); force it with `--srgb`, `--data`, `--normal`, `--normal-green-down`.
- `<file>.import` beside the source keeps the flags, the folder of its assets and the id of each
  asset, so importing again updates in place, keeping ids and material edits: commit it, and move
  it with its source. A part renamed in the source is a new asset.
- Meshes, textures, sounds and fonts are built into `.mirai/imported/`, never committed: `mirai
  build` makes them again on a fresh clone. Edit their source, not them.
- Triangle and texture limits and the collision shape are flags too (`mirai import` without
  arguments prints them); colliders a source brings win unless `--force-collision`.
- A model without a skeleton that must animate: `--rig` with the template that fits it. Clips of
  another file onto a skeleton the project has: `--skeleton <id>` ([animation](animation.md)).
- With an editor session: `asset.import` (MCP `asset_import`) answers when it ends, with what it
  wrote; a CLI import is picked up by the editor at its next call. `asset.list` shows what exists.

## Kinds
- Engine: `.mesh` `.skeleton` `.mat` `.tex` `.anim` `.sound` `.sound_set` `.ui` `.font` `.strings`
  `.prompts` `.records` `.scene` (its header says Scene or Prefab).
- Plugins add `.particle`, `.terrain`, `.foliage`, `.navmesh`, `.character` (`animation`),
  `.fracture` (`destruct`), `.physics_cache`.
- Folders are named after what they hold (`player`, `arena`), never after a kind; the browser
  filters by kind. Sound sets: [audio](audio.md); particles: [vfx](vfx.md).

## Reference

- A `base.Asset_Id` field of a component holds an id; tag it `mirai:"kind=.tex"` (several:
  `kind=.anim .character`) so the inspector lists only those; fill it in the scene.
- The API takes an asset by its path under `assets/`, with or without its extension, or its id;
  code, by its path as the file is spelled, and a field it fills by `host.assets_id(assets,path)`.
  A constant id in code is only for assets your own tool writes with `asset.content_id`.
- Scenes, `.records` and `.strings` ship. Other assets only code names need a root in
  `cook.mirai`: `{"roots":["arena/Chrome.mat","player/"]}` (path under `assets/`, folder with
  `/`, or id).
- Texts: every `.strings` is one table of keys, which a node of a `.ui`, a `core.Text` of a row
  and `core.text(texts,"menu.start",language)` show: [texts](ui/texts.md).
- Game data: a `.records` declares a catalog (items, dialogue, waves): its columns, from which the
  build generates the struct, and its rows. A `core.Record(T)` field names a row; read it with
  `core.record(rows,ref,problems,entity)`: [records](core/records.md).

## Inspect

- `mirai asset ls <folder>`, `info`, `verify <file>...`, `deps <file> --users`, `dump`, `get <file>
  <path>`, `set <file> <path>=<value>`; rows are added by `unpack`, editing `asset.json`, `pack`; a
  scene or a `.ui`, by the document `dump` prints ([text](assets/text-sources.md)).

## Pitfalls that fail silently
- A hard-coded id of an imported asset matches nothing in another checkout: ids are random.
- Roughness or ORM imported as color: `--data`. DirectX normals: `--normal-green-down`.
- `.ttc` and `.woff` fonts, three or more audio channels, Draco or meshopt indices: refused.
