# Writing a .ui

A `.ui` is a flat list of nodes in preorder with its styles beside it. A game writes it from its
content tool, so the same bytes come out every run; the editor and the API edit the same file.
The template's `tools/content` writes `hud.ui`, `sign.ui` and `shell.ui`: copy the nearest one.

## Content tool

```odin
texts:=make([dynamic]u8,context.temp_allocator)
styles:=[]ui.Node_Style{               // style 0 is the plain one; nodes name a style by index
    {},
    {fill={16,22,34,220},radius=8},
    {text={size=18,color={255,255,255,255}}},
}
nodes:=[]ui.Tree_Node{                 // parents first; the parent is an index of this list
    ui.tree_node_record(&texts,-1,{kind=.Box,name="panel",style=1,
        float={to=.Safe,anchor=.Top_Left,pivot=.Top_Left,offset={16,16}},
        layout={width=ui.fixed(260),gap=12,padding=ui.padding_all(12)}}),
    ui.tree_node_record(&texts,0,{kind=.Text,name="message",style=2,bind_text="Status.message"}),
}
err:=host.ui_tree_save("assets/ui/hud.ui",&types,id_of("ui","hud"),
    ui.Tree_Data{nodes=nodes,styles=styles,text=texts[:]})      // asset.Error; .None is success
```

- `id_of` (the template's helper over `base.asset_id_named`) gives the same id every run; the
  scene's `UI_Screen.asset` or `World_Widget.asset` takes it. Write the `.ui` before the scene.
- Sizes are `ui.fixed(n)`, `ui.grow()`; `layout.direction` is `.Row` or `.Column`, `gap` and
  `padding` are layout units, `align_x` and `align_y` center content.
- A `Text` with a `fill`, `radius` or `stroke` in its style draws them behind the text as a `Box`,
  with the `padding` of its `layout` around the text: a pill needs no parent `Box`.
- `bind_text`, `bind_value`, `bind_visible`, `bind_disabled`, `bind_items` take paths:
  [hud-panels.md](hud-panels.md#hud). The kinds are the members of `ui.Node_Kind`.

## Variants

A variant changes some fields of a style while a state holds: `lit` in the template's
`write_shell` makes one with `ui.tree_variant_record`. Pass them as `variants` in `ui.Tree_Data`
and set `transition=0.08` on the style to fade between looks.

`Focused` is the keyboard ring and looks different from `Hovered`: define both, or a player on
keys cannot see where they are.

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

- A parent index after its child, or a style index past the list, makes the whole `.ui` fail to
  load: the screen does not show and `engine.diagnostics` has `gui.asset`.
- Controls need distinct `name`s: events carry only the hash of the name.
- Random ids break every scene that names the `.ui`: use `base.asset_id_named`.
- Running the content tool again overwrites the file; API edits to a `.ui` it writes are lost.
