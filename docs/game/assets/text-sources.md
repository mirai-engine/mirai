# Interfaces and scenes as text

A `.ui` and a `.scene` are files of `assets/`, and each reads and writes as a document of text.
One command reads the document of an asset and makes an asset say a document, with no editor: an
agent writes the text with its own tools. The asset is the source; the text is kept nowhere.

## The loop

```sh
mirai build editor .                              # once, and again after the code changes
mirai scene read arena/main.scene --out main.json # the document of the scene
mirai scene write arena/main.scene main.json      # the scene says the document
mirai ui write hud/score.ui score.json            # an asset that does not exist is made
mirai play test .                                 # the scenarios of tests/scenarios
```

- `read <asset>` prints the document, or writes it to `--out`: start from it.
- A write refuses what it cannot check and exits with 1, saying where in the document and what
  the game has there; the asset stays as it was. `mirai ui check` and `mirai scene check` say what
  would fail without writing.
- Documents are checked against the game as it was built: a component or a field the code just
  declared is unknown until `mirai build editor .`, and a write says so when the library
  is missing or older than the code.
- An asset that already says its document is left alone.

## An interface

The document of [writing-ui.md](../ui/writing-ui.md):

```json
{"use": ["menu/theme.ui"],
 "nodes": [{"name": "score", "kind": "Text", "style": "chip_value", "bind_text": "Status.hits"}]}
```

A widget is a file of its own, named in `use` by its path under `assets/`. Writing a widget whose
`params` moved also writes the files that use it, so what they give still goes where it should.

## A scene

The entities at the top of the scene, nesting by `children`. It is the document `scene.write` of
the editor takes and `scene.inspect` with `root` gives: one grammar, with or without an editor.

```json
{"entities": [
  {"name": "Sun", "preset": "sun"},
  {"name": "Floor", "preset": "cube", "position": [0, -0.05, 0], "scale": [20, 0.1, 20],
   "components": {"Material_Values": {"color": [0.35, 0.38, 0.42, 1]}, "Collider": {}}},
  {"name": "Lamp", "preset": "point_light", "position": [2, 3, 0],
   "components": {"Point_Light": {"intensity": 7}}},
  {"name": "Hero", "prefab": "player/Player.scene", "position": [0, 1, 4]},
  {"name": "Hud", "components": {"UI_Screen": {"asset": "hud/score.ui"}}}
]}
```

- `preset` is a recipe (`cube`, `sphere`, `plane`, `point_light`, `sun`, `camera`...) or the card
  of a plugin (`spawn`, `fog`...): it gives the components, and `components` changes their fields
  or adds others. A field left out starts as its component does. Every component an entity has
  is in its document; one with no field to show, a marker, is `{}`.
- `prefab` with the path or the id of a `.scene` that has one entity at the top is a linked
  instance of it, placed the first time. What the document leaves out of it and of its children
  stays as the prefab gives it; what it says of them, by their names, the instance holds on its own.
- An asset in a field is its path under `assets/` or its id. An entity in a field is the `id` of
  another entity of the document, which `mirai scene read` shows once the file exists.
- Entities are matched by `id`, else by `name` among their siblings, else by place: keep the names
  and a later write changes those entities instead of making new ones. What the document leaves
  out goes.
- `"merge": true` beside `entities` keeps what the document leaves out: it names only the
  entities, components and fields it adds or changes, an entity says `"delete": true` to go and a
  component `null`. `"root"` names the one entity the document declares instead of the whole
  scene, by its name, a path `Parent/Child` or its id.
- A prefab is a scene with one entity at the top: the same document, and no other kind of file.
