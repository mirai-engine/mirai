# Menus, pause and settings

The shell of a new game: `game/shell.odin` holds the logic and `assets/ui/shell.ui` the look, a
`Switcher` with one page per `Shell_Page`, written by `write_shell` of `tools/content`. Change
both, run the content tool, then `asset.reload` in an open editor ([UI](../ui.md)).

## Map

- Colors, fonts, sizes, button shape: [Restyle](#restyle).
- A new button or page: [Add a page](#add-a-page).
- A new option on the settings page: [Add an option](#add-an-option).
- Quality, scale, shadows, frame limit, fullscreen: [Apply settings](#apply-settings).
- Keep the player's choices: [Persist](#persist).
- Escape, frozen clock, mouse: [Pause](#pause).

## Restyle

All styles, colors and control sizes are in `write_shell`: the constants at its top
(`PANEL_FILL`, `ACCENT`, ...), the `styles` list and the `lit` hover, focus and press variants.
Change values there (`text={size=22,color=...}`, `fill`, `stroke`, `radius`); keep the node
names, since `shell_event` matches them.

## Add a page

1. A member of `Shell_Page` before `Playing`, in the order of the pages of `shell.ui`.
2. A `page(&t,pages,"controls","Controls")` call in `write_shell`, in the same order, with its
   controls; `button(&t,panel,"menu_controls","Controls")` on the page that opens it.
3. A `case` in `shell_event` that sets `shell.page`, and one for Escape in `shell_frame` if the
   page should go back.

```odin
case base.name_hash("menu_controls"): shell.page=.Controls
case base.name_hash("controls_back"): shell.page=.Menu
```

The first control of a page is `button(...,true)`, which sets `.Focus_First`: keys work at once.

## Add an option

```odin
// content tool: label, node name, bound field, options in the order of the code
selector(&t,settings,"Shadows","settings_shadows","Shell_Options.shadows","Off|Low|High")
// shell.odin: the field in Shell_Options, then the case of shell_event
case base.name_hash("settings_shadows"): options.shadows=index
```

A selector's value is the index into its options, so the table the code reads
(`SHELL_SHADOW_RAYS`) and the text of the options list the same entries. After the `case`,
`shell_event` marks the preset `Custom`; `shell_apply` then reads the field.
A checkbox binds a `bool` and arrives as `event.on`.

## Apply settings

One procedure turns the options into the settings storages and nothing else writes them. The
engine brings the window and the renderer to them at once, from a frame step:

```odin
g:=graphics^                                       // ^render.Graphics_Settings
render.graphics_preset_apply(&g,.Medium)           // quality fields only
g.render_scale,g.render_megapixels=0.75,0          // 0: no pixel cap, the scale is what shows
g.sun_shadows=false                                // no ray goes to the sun
g.shadowed_lights=4
g.frame_limit,g.vsync=60,true                      // 0: no limit
graphics^=g
display.mode=.Fullscreen                           // ^render.Display_Settings; .Project as authored
```

`graphics_preset_apply` leaves `render_scale`, `frame_limit`, `vsync` and `antialiasing`
(`base.text_set(g.antialiasing[:],render.ANTIALIASING_TAA)`) alone. Fields: `engine.describe`.

## Persist

The player's choices are a `@(storage,persist)` struct of plain data, written to the player's
profile and read back when the world first runs:

```odin
if changed {
    shell_apply(options^,graphics,display)
    save.request_profile_save(saves)               // saves: ^save.Save_Requests
}
```

On a first run (`options.chosen` false) the shell picks the preset of the machine from
`graphics.textures`, then sets `chosen`. `save.request_options_save` instead keeps the machine
settings themselves, when the game has no options struct of its own.

## Pause

`shell_frame` runs every frame, also with the clock stopped, because Escape and the buttons must
reach it. It maps `Shell.page` to the clock (`core.pause(clock_requests)` and `core.resume`), to
the mouse (captured only while `Playing`) and to the `render.Hidden` of the screens.
`scene.request_path(scenes,path)` loads a scene, which is how Quit to Menu starts over.

## Pitfalls that fail silently

- Menu logic in a fixed step never runs while the clock is stopped: use `@(step="frame")`.
- A new page that is not in the same position in `Shell_Page` and in `shell.ui` shows the wrong
  page: the `Switcher` counts its nodes.
- Writing `Graphics_Settings` from another step is overwritten by the next `shell_apply`.
- A preset sets `render_megapixels`; leave it at 0 when the scale is the player's choice.
- In a network game the clock is not stopped and Quit leaves the game instead of loading a scene.
- Verify with a scenario, not by hand: [testing](../testing.md#ui-and-menus).
