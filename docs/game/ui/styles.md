# Styles, tokens and shared components

The look of a `.ui` is by name, in its document ([writing-ui.md](writing-ui.md)): tokens, styles
that extend others, states inline, the layout nodes share, and named animations. Each resolves when
the file is written and linked, never per frame. A reusable piece is a widget, a `.ui` of its own.
The template's `assets/menu/theme.ui` is the example of tokens and styles, and its `panel.ui`,
`select_row.ui`, `check_row.ui` and `button.ui` of widgets: read them with `ui.inspect`.

## Tokens and styles

```json
{
  "tokens": {"ink": "#3a1d4f", "sun": "#ffb238", "round": 20},
  "styles": {
    "base": {"stroke": "ink", "border": 4, "radius": "round", "size": 24, "color": "ink",
      "font": "semibold"},
    "button": {"extends": "base", "fill": "#ff8fa9", "fill2": "#f0467f",
      "shadow": {"color": "ink", "y": 7}, "transition": 0.09, "width": 300, "height": 60,
      "text_x": "center", "text_y": "center",
      "hover": {"fill": "sun", "move_y": -3, "shadow": {"y": 10}},
      "focus": {"extends": "hover", "stroke": "#46dfc4", "border": 6},
      "pressed": {"move_y": 5, "shadow": {"y": 2}, "scale": 0.98},
      "disabled": {"fill": "#b5acc4", "color": "#ece6f4"}},
    "dim": {"fill": "#2c163f8c", "blur": 6}
  }
}
```

- A style says only what it sets; `extends` names another one, here or in a file it uses, and takes
  the rest. Changing a token or a style reaches everything that names it.
- Values: a color is `#rrggbb` or `#rrggbbaa`, a size a number; the name of a token instead of
  either. `shadow` and `text_shadow` are `{color, blur, x, y}` and a state lists only the parts it
  changes. A hard shadow has no blur: it is an edge of the shape.
- States: `hover`, `focus`, `pressed`, `disabled`, `selected`, `over`. Each lists what differs;
  `extends` makes one start from another (`"focus": {"extends": "hover", ...}`). `focus` is the
  ring of keys and gamepad: give it a look that is not `hover`.
- `move_x`, `move_y` and `scale` draw the node somewhere else without moving the layout or the
  pointer; with `transition` they animate. `blur` blurs what is behind the node, for a pause
  screen.
- Layout goes in a style too: `width`, `height`, `direction`, `gap`, `padding`, `align_x`,
  `align_y`. A node takes it and states only what differs; a change of the style reaches every node
  that uses it.
- A `Text` or a `Rich_Text` with `"wrap": "words"` breaks at whatever width it ends with (`"grow"`,
  `"50%"`, a number, or `"fit"` inside something narrower) and is as high as its lines.
  `"align_y": "baseline"` on a row puts texts of different sizes on one baseline.
- `variants`: `"variants": {"gold": {"fill": "#ffd700"}}` is a look a node picks with `variant` or
  `bind_variant`.

## Share across files

A document that says `"use": ["menu/theme.ui"]` names the tokens and styles of that file. No file is
special. A node that takes a style of it follows the changes of that file when it loads.

## Widgets

A component is a widget: a `.ui` of its own, made and edited like any other, one root and what a
use says by name. `use` it and name it by its file, without an extension. This is
`assets/menu/select_row.ui`:

```json
{"use": ["menu/theme.ui"],
 "params": {"label": "label.text", "options": "control.text", "bind": "data"},
 "nodes": [{"name": "row", "kind": "Box", "style": "row", "children": [
   {"name": "label", "kind": "Text", "style": "row_label"},
   {"name": "control", "kind": "Selector", "style": "selector", "bind_value": "@"}]}]}
```

And a screen that uses it:

```json
{"use": ["menu/theme.ui", "menu/select_row.ui"],
 "nodes": [{"name": "sun", "kind": "select_row", "label": "Sun shadows",
            "options": "Off|On", "bind": "Graphics_Settings.sun_shadows"}]}
```

- `params` says where each goes: `node.field` (`text`, `style`, `bind_text`, `bind_value`,
  `data`...) or `field` of its root. Past a widget it uses, `node.parameter` hands a parameter of
  that one to its own uses. A use says them by name, and the keys of a node for its root;
  `children` is what it holds.
- A node with `"slot": true`, the last of its file, holds what a use holds.
- `data` gives what paths that start with `@` read: `@` is that path of the game, `@hp` its field
  `hp`. Paths of the rest of the widget read what the screen reads.
- The visual editor shows them: a root has a Parameters card, each use a row per parameter in its
  Widget card, and "Make widget" makes one of a Box with a parameter per named text or binding.
  What a use gave follows a parameter moved or renamed.

## Animations

```json
"animations": {"pulse": {"scale": [1, 1.2], "seconds": 0.6, "ease": "In_Out_Quad",
                         "loop": "Ping_Pong"}}
```

A property (`offset`, `scale`, `rotation`, `opacity`, `color`, `width`, `height`, `value`, `frame`,
`reveal`) goes from one value to another; nodes play it with `"events": {"shown": "pulse"}`. Keyed
tracks go in `tracks` (`[{"property": "Scale", "keys": [{"time": 0, "value": [1, 1, 0, 0]}]}]`) and
a `"kind": "Sequence"` or `"Parallel"` names others in `parts`.

## Pitfalls that fail silently

- A name that resolves to nothing fails `ui.write` with what to fix, and `ui.check` says it for
  every `.ui` of the project (a style renamed in the theme after a screen named it; a parameter
  whose node is gone; a file that uses another that uses it back or is missing).
- A `.ui` that uses another needs that file at runtime: keep it in `assets/`.
