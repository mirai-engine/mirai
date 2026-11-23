# Cursor

What the pointer of the window shows over the game. Freeing it is [Mouse](menus-settings.md#mouse).

## Shape

A style says what the pointer shows while it is on its node or holds it, and a state changes it:

```json
"styles": {"link": {"cursor": "pointer", "disabled": {"cursor": "not_allowed"}}}
```

The shapes are those of `ui.Cursor`: `default`, `text`, `pointer`, `crosshair`, `move`,
`resize_horizontal`, `resize_vertical`, `resize_diagonal_down`, `resize_diagonal_up`,
`not_allowed`, `wait`, `progress` and `hidden`. The node built last under the pointer wins; a
disabled node shows its shape while the pointer is on it.

## Images and hiding

The game writes the `gui.UI_Cursor` setting, one for the window, not one per seat:

```odin
@(step="frame")
cursor_look :: proc(cursor:^gui.UI_Cursor) {
    cursor.images[.Pointer]={texture=HAND_TEX, hotspot={6,2}} // points from its top left
    cursor.hidden=false // true for a game that draws its own pointer in a .ui
}
```

- An image is a `.tex` imported as color (RGBA8, BC1 or BC7, sRGB), a single image, at most 256
  pixels on a side, with a level `size` points wide (32 when 0). That level is the one at 1x and
  the larger ones serve denser displays: a 64-pixel texture with its mips is sharp at 2x.
- Anything else is the problem `gui.cursor`, which names the file and the fix; the shape keeps
  the system's. A change of the file shows at once, as a hot reload.
- The relative mouse hides the pointer whatever the setting says. There is no animated cursor:
  hide it and draw one in a `.ui`.

## In the editor

The game's cursor shows only while the game has the input and the pointer is on its scene. Over
the bars, paused, with the input released (F1) or in Simulate, the editor's shows, never an image
of the game. The OS cursor is in no capture: `play.status` says what shows in `cursor` (`shape`,
the `image` it shows and `relative`).
