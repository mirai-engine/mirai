# Interfaces and scenes as text

A project keeps its interfaces, scenes and prefabs as files of text under `source/`, and one
command turns them into the assets the game loads. No editor runs: an agent writes the files with
its own tools, and git shows what changed.

```
source/hud/hud.ui.json          ->  assets/hud/hud.ui
source/arena/main.scene.json    ->  assets/arena/main.scene
source/player/Player.prefab.json ->  assets/player/Player.prefab
```

## The loop

```sh
mirai build editor . --dev      # once, and again after the code of the game changes
mirai ui write source           # every .ui.json under source/
mirai scene write source        # every .scene.json and .prefab.json
mirai play test .               # the scenarios of tests/scenarios
```

- `mirai ui read --sources` and `mirai scene read --sources` write the text of every asset the
  project already has: start from them. `read <asset>` prints one.
- A write refuses what it cannot check and exits with 1, saying where in the document and what
  the game has there; the asset stays as it was. `mirai ui check` and `mirai scene check` say what
  would fail without writing.
- Documents are checked against the game as it was built: a component or a field the code just
  declared is unknown until `mirai build editor . --dev`, and a write says so when the library
  is missing or older than the code.
- A file that already says its document is left alone, so writing the whole folder is cheap.

## An interface

`source/hud/score.ui.json`, the document of [writing-ui.md](../ui/writing-ui.md):

```json
{"use": ["menu/theme.ui"],
 "nodes": [{"name": "score", "kind": "Text", "style": "chip_value", "bind_text": "Status.hits"}]}
```

A widget is a file of its own, named in `use` by its path under `assets/`. Writing a widget whose
`params` moved also writes the files that use it, so what they give still goes where it should.

## A scene

`source/arena/yard.scene.json`: the entities at the top of the file, nesting by `children`.

```json
{"entities": [
  {"name": "Sun", "preset": "sun"},
  {"name": "Floor", "preset": "cube", "position": [0, -0.05, 0], "scale": [20, 0.1, 20],
   "components": {"Tint": {"color": [0.35, 0.38, 0.42, 1]}, "Collider": {}}},
  {"name": "Lamp", "preset": "point_light", "position": [2, 3, 0],
   "components": {"Point_Light": {"intensity": 7}}},
  {"name": "Hero", "prefab": "player/Player.prefab", "position": [0, 1, 4]},
  {"name": "Hud", "components": {"UI_Screen": {"asset": "hud/score.ui"}}}
]}
```

- `preset` is a recipe of `scene.add` (`cube`, `sphere`, `plane`, `point_light`, `sun`, `camera`...)
  or the card of a plugin (`spawn`, `fog`...): it gives the components, and `components` changes
  their fields or adds others. A field left out starts as its component does.
- `prefab` with the path or the id of a `.prefab` is a linked instance of it, placed the first
  time. What the document leaves out of it and of its children stays as the prefab gives it; what
  it says of them, by their names, the instance holds on its own.
- An asset in a field is its path under `assets/` or its id. An entity in a field is the `id` of
  another entity of the document, which `mirai scene read` shows once the file exists.
- Entities are matched by `id`, else by `name` among their siblings, else by place: keep the names
  and a later write changes those entities instead of making new ones. What the document leaves
  out goes.
- A prefab is the same document with one entity at the top.
