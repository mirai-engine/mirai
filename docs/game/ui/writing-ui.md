# Writing a .ui

A `.ui` is the source of an interface and it has one route: you write a document, nested and by
name, and the editor keeps it in the file. `ui.inspect` gives back the same document, and the
visual editor edits the same `.ui`; nothing regenerates over what either did. Names stay named:
`ui.write(ui.inspect(x))` changes nothing. Add `ui_inspector` to the `plugins` of `project.mirai`
for this (a new game has it).

## A working document

Save this as `screen.json` and write it (`save=true` writes the file: a path that does not exist
yet makes the `.ui`):

```
mirai rpc --project . ui.write asset=ui/screen.ui document=@screen.json save=true
```

```json
{
  "tokens": {"ink": "#3a1d4f", "cream": "#fff6e9", "round": 16},
  "styles": {
    "card": {"fill": "cream", "stroke": "ink", "border": 3, "radius": "round",
      "direction": "column", "gap": 10, "padding": 18},
    "title": {"size": 28, "color": "ink", "font": "semibold", "text_x": "center"},
    "start": {"extends": "title", "fill": "ink", "color": "cream", "radius": "round",
      "width": 200, "height": 48, "text_y": "center",
      "hover": {"fill": "#6b4a7a"},
      "focus": {"extends": "hover", "stroke": "cream", "border": 3}}
  },
  "animations": {"pulse": {"scale": [1, 1.2], "seconds": 0.6, "ease": "In_Out_Quad",
                           "loop": "Ping_Pong"}},
  "use": ["hud/stat.ui"],
  "nodes": [
    {"name": "root", "kind": "Box", "style": "card",
     "float": {"to": "Safe", "anchor": "Center", "pivot": "Center"},
     "children": [
       {"name": "start_game", "kind": "Button", "style": "start", "text": "Start",
        "events": {"shown": "pulse"}},
       {"name": "hits", "kind": "stat", "label": "Hits", "value": "Status.hits"}
     ]}
  ]
}
```

`stat` is a widget, a `.ui` of its own, written first as `stat.json` and named by its file:

```json
{"styles": {"title": {"size": 18, "color": "#3a1d4f"}},
 "params": {"label": "name.text", "value": "amount.bind_text"},
 "nodes": [{"name": "stat", "kind": "Box", "gap": 6, "children": [
   {"name": "name", "kind": "Text", "style": "title"},
   {"name": "amount", "kind": "Text", "style": "title"}]}]}
```

```
mirai rpc --project . ui.write asset=hud/stat.ui document=@stat.json save=true
```

A document only sees its own `styles` and those of what it lists in `use`.

- Read it back with `mirai rpc --project . ui.inspect asset=ui/screen.ui --select document`, change
  what you want and write it again. `ui.check` says what does not resolve.
- A node is `{name, kind, text, style, children}` plus what it sets by the name of its keys. `kind`
  is a `ui.Node_Kind` (`Box`, `Text`, `Button`, `Image`, `Selector`...) or the name of the file of
  a widget it uses: [styles.md](styles.md#widgets).
- Keys of a node: `width`, `height` (`"grow"`, `"fit"`, `"50%"` or a number for fixed),
  `direction`, `gap`, `padding` (a number, `[x, y]` or four numbers), `align_x`, `align_y`,
  `float`, `bind_text`, `bind_value`, `bind_visible`, `bind_disabled`, `bind_items`, `image`
  (`{"texture": "hud/badge.tex"}`), `events`, `flags` and the other fields of `ui.Tree_Node`.
  A style holds the common ones; a node only what differs: [styles.md](styles.md).
- Paths in `bind_*` are the data of the game: [hud-panels.md](hud-panels.md#hud). `events` by
  trigger names the animation that plays: `shown`, `hidden`, `hovered`, `pressed`, `clicked`...
- A `Text` with a `fill`, `radius` or `stroke` in its style draws them behind the text, with its
  `padding` around the text: a pill needs no parent `Box`.
- The first control of a page takes the focus when it shows; a node that must have it instead has
  `"flags": ["Focus_First"]`.

Changing a single piece: `ui.write` with `node=<name>` declares that node and what it holds, and
nothing else of the file changes; a document with only `styles` or `animations` changes those it
names. Paths: `ui.paths` lists what a binding of a node can take. `ui.write` refuses a path the
built game lacks and says what the game has there: declare the component or the field and build
before binding it. A path that starts with `@` is of a widget and is checked where it is used.
`ui.check` says what the game lacks in every `.ui`. `ui.capture` draws one alone.

## Without an editor

`mirai ui` reads, checks and writes the same documents as files of text, with no editor running;
`source/<path>.ui.json` is the asset `assets/<path>.ui`:

```
mirai ui read --sources
mirai ui write source
mirai ui check
```

- `read --sources` writes the document of every `.ui`, and `read <asset>` prints one. `write`
  takes files or a folder and makes each asset say its document, making those that do not exist.
- `write` refuses what `ui.write` refuses, with the same message, and leaves the file as it was.
  Paths are checked against the game as it was built last (`mirai build editor --dev`); before a
  first build they are not, and the command says so. `check` exits with 1 when a `.ui` fails.

## Controls

`Button` reports `Clicked`; `Checkbox`, `Slider`, `Selector`, `Dropdown`, `Radio`, `Number` and
`Field` report `Changed`; `Field` also `Submitted`. A `Selector` takes its options in `text`
separated by `|`; what each one writes: [add an option](menus-settings.md#add-an-option). The game
answers on each event: [events](../ui.md#events).

## Texts

A `Localized` node keeps its translations in the `.ui`. `mirai texts export|import <file.csv>
--project .` moves them through a CSV; `ui.text.set` changes one.

## Pitfalls that fail silently

- A `.ui` that does not load shows nothing: `engine.diagnostics` has `gui.asset`.
- Controls need distinct `name`s: events carry only the hash of the name, and asking for a name the
  screen does not have is a problem `gui.names` once at run time.
- `ui.write` without `save=true` waits for Save (the changes are one step of history); agents pass
  `save=true`.
