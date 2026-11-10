# HUD and world panels

A HUD shows data the game already keeps: its `.ui` binds paths to a component and the screen
re-reads them each frame. The game never pushes text into widgets; it writes the component.
The template does this with `Status` (`message`, `hits`) shown by `hud.ui` and by `sign.ui`.

## HUD

```odin
// game: a component per thing the HUD shows
@(component)
Status :: struct {message:[48]u8 `mirai:"text"`, hits:i32, health:f32}
// any step: write the field; the screen follows
base.text_set(status.message[:],"Hit the wall")
status.hits+=1
```

The nodes of `hud.ui` bind by path; the entity of the screen carries `Status`:

```json
{"name": "panel", "kind": "Box", "style": "chip",
 "float": {"to": "Safe", "anchor": "Top_Left", "pivot": "Top_Left", "offset": [16, 16]},
 "children": [
   {"name": "message", "kind": "Text", "style": "chip_value", "bind_text": "Status.message"},
   {"name": "hits", "kind": "Text", "style": "chip_label", "bind_text": "Status.hits"},
   {"name": "health", "kind": "Progress", "style": "bar", "bind_value": "Status.health"}]}
```

Write it with [ui.write](writing-ui.md). In the scene, the screen and its data on one entity:

```json
{"method":"scene.add","params":{"name":"Hud","components":{
 "UI_Screen":{"asset":"hud/hud.ui"},"Status":{"message":"Hit the wall"}}}}
```

- A path starts at a component of the entity of the screen (`UI_Screen.entity` names another
  one) or at a storage of the world, then follows fields: `Hotbar.slots.2.count`. A field of
  type `Entity` leads to the component the next name gives: `Hero.target.Health.value`.
- Hang a box from the window with `"float": {"to": "Safe", "anchor": "Top_Left", "pivot":
  "Top_Left", "offset": [16, 16]}`: `Safe` keeps it clear of notches. `Surface` is the whole
  window.
- Repeat a node per element of an array with a `List` and `bind_items`.
- Several local players: `UI_Screen.player` is `0` for the window and `n` for the part of
  player `n`.

## Custom drawing

A minimap, a graph or a radar is a `Draw` node: a leaf the layout places and a style colors,
whose pixels a procedure of the game draws. The node names it in `draw` and binds in
`bind_value` the field the procedure reads, of any type:

```json
{"name": "map", "kind": "Draw", "draw": "minimap", "style": "map",
 "bind_value": "Minimap", "width": 160, "height": 160}
```

```odin
@(component)
Minimap :: struct {marks:[16][2]f32, count:i32}

@(draw="minimap")
minimap_draw :: proc(ctx:^ui.Context, node:ui.Draw_Node) {
    ui.draw_rounded(ctx, node.rect, 6, node.fill)
    map := ui.draw_value(node, Minimap) or_return
    r, dot := node.rect, node.mark
    for at in map.marks[:map.count] {ui.draw_circle(ctx, {r.x, r.y} + at*{r.w, r.h}, 3, dot)}
}
```

- The procedure draws from `node` alone: its `rect`, the colors and text of its style and
  `data`, the bytes of what it binds (`ui.draw_value`). A frame step writes the component; the
  screen is drawn again only when it changed.
- It uses the `ui.draw_*` procedures; what it draws past the container that clips it is cut.
- A `draw` no procedure has is refused by `mirai ui check` and is a problem `gui.draw`.

## World panel

An entity with a `World_Widget` shows a `.ui` at its place; its paths name components of that
entity first, so one `.ui` serves every entity that has them.

```json
{"method":"scene.add","params":{"name":"Sign","position":[-3,1.6,2],"components":{
 "World_Widget":{"asset":"arena/sign.ui","size":[220,70],"scale":0.01,
  "facing":"Billboard_Upright","pivot":"Bottom_Center"},
 "Status":{"message":"Hit the wall"}}}}
```

`scale` is metres per layout unit; `Status` is what its paths read.

- `facing`: `Billboard` (parallel to the screen), `Billboard_Upright` (turns about up) or `Fixed`
  (the rotation of the entity: its face shows toward the forward of the entity, -Z, as anything
  else does, so a panel on a body reads from in front of it with no turn of its own).
  `sizing=.Screen` keeps a constant size on screen at any distance.
- `depth_test` hides it behind the scene; `passive` lets the pointer through.
- A player sees the nearest panels only: use few, and hide the far ones.
- `preview` shows it in the editor while the world does not play.

## On a mesh

`target=.Mesh` draws the `.ui` into a texture that a material slot of the entity's mesh shows,
lit and fogged like the scene: `slot` is the slot, `pixels` the texels per layout unit and
`emission` above 0 makes it glow in nits.

## Input

`input=.Interactive` lets the player point at the panel (the pointer, or the center of the view
while the mouse is captured or a gamepad plays) and use its focus, keys and actions while no
screen of that player takes input. `Passive` receives only the pointer.

## Pitfalls that fail silently

- Zeroed `World_Widget`: size 0, nothing shows. Start from `gui.WORLD_WIDGET_DEFAULT`.
- The component its paths name is missing on the entity: the widget is not shown, and the reason
  is a problem `gui.bind` in `engine.diagnostics`.
- An entity with `Hidden` hides its screen and its panels.
- A `UI_Screen` set to `Menu` or `Modal` takes the actions of the seats it covers: a HUD is
  `Passive`.
