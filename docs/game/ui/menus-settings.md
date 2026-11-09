# Menus, pause and settings

The shell of a new game: `game/shell.odin` holds the logic and `assets/ui/shell.ui` the look, a
`Switcher` whose pages are named after the members of `Shell_Page`, written by `write_shell` of
`tools/content`. Change both and run the content tool.

## Restyle

The look of every screen is `write_theme` of `tools/content`: tokens first (the colors and sizes
to change), then the styles and the `button`, `panel` and setting rows the screens use
([styles.md](styles.md)). `write_shell` only names them; keep its node names, since `shell_events`
matches them.

## Add a page

1. A member of `Shell_Page` before `Playing`, in the order of the pages of `shell.ui`.
2. A `panel(&s,pages,.Controls,"Controls",560)` call in `write_shell`, in the same order, with its
   controls; `button(&s,menu,"menu_controls","Controls")` on the page that opens it.
3. A line in `shell_events` that sets `shell.page`, and one in the `gui.menu_pressed` switch of
   `shell_frame` if the page should go back.

```odin
if gui.clicked(events,screen,"menu_controls") {shell.page=.Controls}
if gui.clicked(events,screen,"controls_back") {shell.page=.Menu}
```

The first control of a page is `button(...,true)`, which sets `.Focus_First`: keys work at once.

## Add an option

One line of the content tool, no game code: a selector bound to a field of a setting
(`Graphics_Settings`, `Display_Settings`, `Audio_Volumes`, `UI_Preferences` or your own
`@(storage,setting)`) writes it, and the engine keeps it for the next run.

```odin
// label, node name, the field, options
select(&s,settings,"Rays","settings_rays","Graphics_Settings.shadowed_lights","Low=4|High=16")
select(&s,settings,"Anti-aliasing","settings_aa","Graphics_Settings.antialiasing","Off=off|TAA=taa")
check(&s,settings,"VSync","settings_vsync","Graphics_Settings.vsync")
```

`Label=Value` names what the option writes: a number, the name of a member of an enum, or text for
a text field. Without values the selector binds the index, as an enum declared in that order does.
A value no option has shows as empty. Bound to anything else, a control reports `Changed` and the
game writes the field.

## Apply settings

The settings page writes the settings directly. To set them from code, in a frame step, write the
fields; the engine brings the window and the renderer to them at once:

```odin
graphics.quality=.Medium        // ^render.Graphics_Settings: naming a preset applies it
graphics.render_scale=0.75      // the fraction of the window drawn; 0: the target of the preset
graphics.sun_shadows=false      // no ray goes to the sun
graphics.frame_limit,graphics.vsync=60,true // 0: no limit
display.mode=.Fullscreen        // ^render.Display_Settings; .Project as authored
```

`frame_limit`, `vsync`, `antialiasing` and `show_fps` do not count for a preset. `quality` reads
the preset the fields are at, and changing a field by hand reads as `Custom`. Naming a preset
resets `render_scale` to 0, which follows the target of the preset: a height of lines over the
window, never above a pixel per point.

## Persist

The machine settings a settings page binds are kept by themselves, and a first run starts at the
preset the engine gives the machine. Choices that are the game's own go in a `@(storage,persist)`
struct of plain data ([core](../core/saves.md)).

## Pause

A `Modal` screen with `pause=true` stops the clock while it shows and gives it back when it hides.
A network session does not stop it. `shell_frame` turns `UI_Screen.pause` on for the pause and
settings pages, and off for the main menu, behind which the world runs. It runs every frame, also
with the clock stopped, because the `Menu` action and the buttons must reach it.
`scene.request_restart(scenes)` loads the scene again, which is how Quit to Menu starts over;
`scene.request_path(scenes,path)` loads another.

## Mouse

The engine captures the mouse while the seat with it drives a body whose look the mouse turns and
no `Modal` screen is up; a game does not call the window for it. For a free cursor, in the order
to try:

- Over gameplay for a moment: a `Modal` screen, the one way to free it while a body is driven.
- For good, a cursor game: leave the look without a mouse binding in `input.mirai`, or let the seat
  drive nothing (`inp.release`, `inp.drive` to take the body back): no capture happens.
- A `Menu` or `Passive` screen leaves the mouse where it is.

## Pitfalls that fail silently

- Menu logic in a fixed step never runs while the clock is stopped: use `@(step="frame")`.
- A `Switcher` bound to an enum shows the page named like the member, and nothing when there is
  none, so a new member needs a page of its name in `shell.ui`.
- Stepping a Quality selector onto `Custom` does nothing: it reads what the fields are, and only
  a change of a field or a preset moves it.
- `UI_Screen.pause` on a screen that is not `Modal` does nothing: problem `gui.pause_modal`.
- In a network game Quit leaves the game instead of loading a scene.
