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

```odin
// content tool: nodes of hud.ui bind by path; the entity of the screen carries Status
ui.sheet_node(&s,panel,"chip_value",{kind=.Text,name="message",bind_text="Status.message"})
ui.sheet_node(&s,panel,"chip_label",{kind=.Text,name="hits",bind_text="Status.hits"})
ui.sheet_node(&s,panel,"bar",{kind=.Progress,name="health",bind_value="Status.health"}) // 0 to 1
```

```odin
// scene, in the content tool: screen and data on one entity
hud:=asset.builder_entity(&b,"Hud")
asset.builder_set(&b,hud,gui.UI_Screen{asset=hud_id})           // Passive by default
asset.builder_set(&b,hud,status)
```

- A path starts at a component of the entity of the screen (`UI_Screen.entity` names another
  one) or at a storage of the world, then follows fields: `Hotbar.slots.2.count`. A field of
  type `Entity` leads to the component the next name gives: `Hero.target.Health.value`.
- Hang a box from the window with `float={to=.Safe,anchor=.Top_Left,pivot=.Top_Left,
  offset={16,16}}`: `Safe` keeps it clear of notches. `to=.Surface` is the whole window.
- Repeat a node per element of an array with a `List` and `bind_items`.
- Several local players: `UI_Screen.player` is `0` for the window and `n` for the part of
  player `n`.

## World panel

An entity with a `World_Widget` shows a `.ui` at its place; its paths name components of that
entity first, so one `.ui` serves every entity that has them.

```odin
widget:=gui.WORLD_WIDGET_DEFAULT                     // a zeroed World_Widget has no size
widget.asset,widget.size,widget.scale=sign_id,{220,70},0.01   // meters per layout unit
widget.facing,widget.pivot=.Billboard_Upright,.Bottom_Center  // turns to the camera, stands on it
asset.builder_set(&b,board,widget)
asset.builder_set(&b,board,status)                   // what its paths read
```

- `facing`: `Billboard` (parallel to the screen), `Billboard_Upright` (turns about up) or `Fixed`
  (the rotation of the entity, with its face toward +Z: a panel that must read from in front of a
  body is a child turned half a turn about Y).
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
