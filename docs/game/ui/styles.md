# Styles, tokens and shared components

A content tool writes a `.ui` through a `ui.Sheet`: tokens and styles by name, nodes that name
their style, states inline. It compiles to the same records as a `.ui` written by hand, so the
frame costs the same. The template's `write_theme` is the example to copy: every screen of a new
game names the styles and components of `assets/ui/theme.ui`.

## Tokens and styles

```odin
theme:=ui.sheet_make("theme")
ui.sheet_tokens(&theme,{
    {"ink","#3a1d4f"},  // colors: "#rrggbb", "#rrggbbaa", or a ui.Color
    {"sun","#ffb238"},
    {"round",20},       // sizes: a number
})
ui.sheet_styles(&theme,{
    {name="base",stroke="ink",border=4,radius="round",size=24,color="ink",font=ui.FONT_SEMIBOLD},
    {name="button",extends={"base"},fill="#ff8fa9",fill2="#f0467f",   // fill2: vertical gradient
        shadow={color="ink",y=7},transition=0.09,                     // no blur: a hard edge
        hover={fill="sun",move_y=-3,shadow={y=10}},
        focus={stroke="#46dfc4",border=6},
        pressed={move_y=5,shadow={y=2},scale=0.98},
        disabled={fill="#b5acc4",color="#ece6f4"}},
    {name="dim",fill="#2c163f8c",blur=6},                             // blurs the world behind it
})
```

- A style lists only what it sets. `extends` takes others, in order, each over the last; then the
  style itself. A value is a token name, or written out.
- States: `hover`, `focus`, `pressed`, `disabled`, `selected`, `over`. Each lists what differs and
  the rest stays; a shadow, an outline or a text shadow changes only the parts it names. `focus`
  is the ring of keys and gamepad: give it a look that is not `hover`.
- `move_x`, `move_y` and `scale` draw the node somewhere else without moving the layout or the
  pointer; with `transition` they animate.
- `blur` makes a node blur what is behind it, for a pause screen.
- `variants={{name="gold",fill="#ffd700"}}` is a look a node picks with `variant` or
  `bind_variant`.

## Nodes

```odin
s:=ui.sheet_make("hud")
panel:=ui.sheet_node(&s,-1,"chip",{kind=.Box,name="panel",layout={gap=12}}) // the style by name
ui.sheet_node(&s,panel,"chip_value",{kind=.Text,bind_text="Status.message"})
host.ui_sheet_save(c,"assets/ui/hud.ui",hud_id,&s)
```

`sheet_node` returns what its children name as `parent`. `host.ui_sheet_save` prints what is wrong
(a style or a token that does not exist, a text with no size or color) and fails the content tool.

## Share across files

Any `.ui` written from a sheet lends its styles and tokens; no file is special. `sheet_take` makes
them, and its components, names here too:

```odin
ui.sheet_take(&s,theme_id,&theme) // theme: the Sheet written to the file theme_id
```

A node that names a style of `theme` takes it from `assets/ui/theme.ui` when the file loads, states
included, so rewriting that file restyles every screen that takes it. A local style can extend one
of them, and the tokens of `theme` name values here at write time.

## Components

A template the same way a screen is written, its root with parent `-1`:

```odin
if ui.sheet_component(&theme,"button") {
    ui.sheet_node(&theme,-1,"button",{kind=.Button,layout={width=ui.fixed(300),height=ui.fixed(60)}})
}
if ui.sheet_component(&theme,"panel") {
    root:=ui.sheet_node(&theme,-1,"panel",{kind=.Box,flags={.Slot,.Wrap_Y},layout={direction=.Column}})
    ui.sheet_node(&theme,root,"heading",{kind=.Text,name="heading"})
}
```

```odin
panel:=ui.sheet_use(&s,page,"panel",{},{{"heading",{text="Paused"},""}})
ui.sheet_use(&s,panel,"button",{name="pause_resume",text="Resume",flags={.Focus_First}})
```

- The second argument of a use names the component; `name` is the instance's name, and what its
  events carry. A template's root may be a `Button`, a `Box` or any other node.
- What `desc` sets replaces the root of the template, the rest stays as it is there.
- The third argument changes inner nodes by their name; `""` keeps their style, a name replaces it.
- A node flagged `.Slot`, the last of the template, holds what the instance holds:
  `sheet_use` returns its `parent`.
- A control in a template binds `@` (or `@field`); the instance's `data` says what that is, as
  `data="Graphics_Settings.quality"` in the template's `select_row`.

## Pitfalls that fail silently

- A token, a style or a component is a plain name: read `sheet_problem`, or let
  `host.ui_sheet_save` print it. A typo is a failed content tool, never an empty style.
- Rename a style in the theme and the screens that name it fail on the next content run: both
  live in the same tool.
- A `.ui` that takes a style by name needs that file at runtime: keep it in `assets/`.
