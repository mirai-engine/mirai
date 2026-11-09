# Styles, tokens and shared components

The look of a `.ui` is by name, in its document ([writing-ui.md](writing-ui.md)): tokens, styles
that extend others, states inline, the layout nodes share, components with parameters and named
animations. Each resolves when the file is written and linked, never per frame. The template's
`assets/ui/theme.ui` is the example: read it with `ui.inspect asset=ui/theme.ui`.

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
- `variants`: `"variants": {"gold": {"fill": "#ffd700"}}` is a look a node picks with `variant` or
  `bind_variant`.

## Share across files

A document that says `"use": ["ui/theme.ui"]` names the tokens, styles and components of that file;
no file is special. A node that takes a style of it follows the changes of that file when it loads.

## Components

A component is a piece a screen uses by name, declared with what it takes and where each goes:

```json
"components": {
  "panel": {"params": {"heading": "heading.text"}, "kind": "Box", "style": "panel", "slot": true,
    "children": [{"name": "heading", "kind": "Text", "style": "heading"}]},
  "select_row": {"params": {"label": "label.text", "options": "control.text", "bind": "data"},
    "kind": "Box", "style": "row",
    "children": [{"name": "label", "kind": "Text", "style": "row_label"},
                 {"name": "control", "kind": "Selector", "style": "selector", "bind_value": "@"}]}
}
```

```json
{"name": "pause", "kind": "panel", "heading": "Paused", "width": 470, "children": [
  {"name": "resume", "kind": "Button", "style": "button", "text": "Resume"}]}
{"name": "quality", "kind": "select_row", "label": "Quality", "options": "Low|High",
 "bind": "Graphics_Settings.quality"}
```

- A use says the parameters by name, the keys of a node for its root, and `children` for what it
  holds. A parameter goes to `node.field` (`text`, `style`, `bind_text`, `bind_value`, `data`...) or
  to `field` of the root. A node with `"slot": true`, the last of the template, holds what a use
  holds.
- `data` gives what paths in `@` read in the template: a path of the game. The visual editor shows
  the parameters of a use in its Widget card.

## Animations

```json
"animations": {"pulse": {"scale": [1, 1.2], "seconds": 0.6, "ease": "In_Out_Quad",
                         "loop": "Ping_Pong"}}
```

A property (`offset`, `scale`, `rotation`, `opacity`, `color`, `width`, `height`, `value`, `frame`,
`reveal`) goes from one value to another; nodes play it with `"events": {"shown": "pulse"}`. Keyed
tracks, sequences and parallels are in `ui.anim.set`.

## Pitfalls that fail silently

- A name that resolves to nothing fails `ui.write` with what to fix, and `ui.check` says it for
  every `.ui` of the project (a style renamed in the theme after a screen named it).
- A `.ui` that uses another needs that file at runtime: keep it in `assets/`.
