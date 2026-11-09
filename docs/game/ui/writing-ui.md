# Writing a .ui

A `.ui` is a flat list of nodes in preorder with its styles beside it. A game writes it from its
content tool, so the same bytes come out every run; the editor and the API edit the same file.
The template's `tools/content` writes `hud.ui`, `sign.ui` and `shell.ui`: copy the nearest one.

## Content tool

```odin
s:=ui.sheet_make("hud")
ui.sheet_styles(&s,{{name="value",size=18,color="#ffffff"}})
panel:=ui.sheet_node(&s,-1,"",{kind=.Box,name="panel",
    float={to=.Safe,anchor=.Top_Left,pivot=.Top_Left,offset={16,16}},
    layout={width=ui.fixed(260),gap=12,padding=ui.padding_all(12)}})
ui.sheet_node(&s,panel,"value",{kind=.Text,name="message",bind_text="Status.message"})
host.ui_sheet_save(c,"assets/ui/hud.ui",id_of("ui","hud"),&s) // c: ^asset.Content, as the template
```

- Styles, tokens, states and shared components: [styles.md](styles.md). A node names its style by
  name; `sheet_node` returns what its children name as `parent`.
- `id_of` (the template's helper over `base.asset_id_named`) gives the same id every run; the
  scene's `UI_Screen.asset` or `World_Widget.asset` takes it. Write the `.ui` before the scene.
- Sizes are `ui.fixed(n)`, `ui.grow()`; `layout.direction` is `.Row` or `.Column`, `gap` and
  `padding` are layout units, `align_x` and `align_y` center content.
- A `Text` with a `fill`, `radius` or `stroke` in its style draws them behind the text as a `Box`,
  with the `padding` of its `layout` around the text: a pill needs no parent `Box`.
- `bind_text`, `bind_value`, `bind_visible`, `bind_disabled`, `bind_items` take paths:
  [hud-panels.md](hud-panels.md#hud). The kinds are the members of `ui.Node_Kind`.

## Controls

`Button` reports `Clicked`; `Checkbox`, `Slider`, `Selector`, `Dropdown`, `Radio`, `Number` and
`Field` report `Changed`; `Field` also `Submitted`. A `Selector` takes its options in `text`
separated by `|`; what each one writes: [add an option](menus-settings.md#add-an-option). The game
answers on each event: [events](../ui.md#events).

## API

With `ui_inspector` in the `plugins` of `project.mirai`, an open editor edits a `.ui`:
`ui.inspect` reads it as a document, `ui.write` replaces it from one, and `ui.node.add`,
`ui.node.set`, `ui.style.set` and `ui.variant.set` change a piece. `ui.bind` binds a node to a path
checked against the game's types, `ui.check` loads every `.ui` against this build and says which
paths are wrong, and `ui.capture` draws one alone to a PNG. Changes wait for `asset.save`.

## Texts

A `Localized` node keeps its translations in the `.ui`. `mirai texts export|import <file.csv>
--project .` moves them through a CSV; `ui.text.set` changes one.

## Pitfalls that fail silently

- A `.ui` that does not load shows nothing: `engine.diagnostics` has `gui.asset`.
- Controls need distinct `name`s: events carry only the hash of the name.
- Random ids break every scene that names the `.ui`: use `base.asset_id_named`.
- Running the content tool again overwrites the file; API edits to a `.ui` it writes are lost.
