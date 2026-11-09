# Menus, pause and settings

The shell of a new game: `game/shell.odin` holds the logic and `assets/ui/shell.ui` the look, a
`Switcher` whose pages are named after the members of `Shell_Page`. Both are the source: an agent
changes `shell.ui` with `ui.write` (or the visual editor edits it) and the game keeps its names.

## Restyle

Read the look with `mirai rpc --project . ui.inspect asset=ui/theme.ui --select document`, change
what you want and write it back with `ui.write` and `save=true`: tokens first (the colors and
sizes), then the `button`, `control` and `panel` styles the widgets take; `button.ui`, `panel.ui`,
`select_row.ui` and `check_row.ui` are the widgets the screens use ([styles.md](styles.md#widgets)).
`shell.ui` only names them; keep its node names, since `shell_events` matches them.

## Add a page

1. A member of `Shell_Page` before `Playing`.
2. A page under the `Switcher` of `shell.ui` named after the member, with its controls, and a
   button on the page that opens it:

```json
{"name": "Controls", "kind": "Box", "style": "dim", "children": [
  {"name": "controls", "kind": "panel", "heading": "Controls", "width": 560, "children": [
    {"name": "controls_back", "kind": "Button", "style": "button", "text": "Back"}]}]}
{"name": "menu_controls", "kind": "Button", "style": "button", "text": "Controls"}
```

Write the page by writing its parent: `ui.write asset=ui/shell.ui node=pages document=@pages.json
save=true`, whose `nodes` is that Switcher with its children, and only that node changes. The
same for the menu that holds the new button.

3. A line in `shell_events` that sets `shell.page`, and one in the `gui.menu_pressed` switch of
   `shell_frame` if the page should go back.

```odin
if gui.clicked(events,screen,"menu_controls") {shell.page=.Controls}
if gui.clicked(events,screen,"controls_back") {shell.page=.Menu}
```

The first control of a page takes the focus when it shows, so keys work at once.

## Add an option

One row of the document, no game code: a selector bound to a field of a setting
(`Graphics_Settings`, `Display_Settings`, `Audio_Volumes`, `UI_Preferences` or your own
`@(storage,setting)`) writes it, and the engine keeps it for the next run.

```json
{"name": "settings_rays", "kind": "select_row", "label": "Rays", "options": "Low=4|High=16",
 "bind": "Graphics_Settings.shadowed_lights"}
{"name": "settings_aa", "kind": "select_row", "label": "Anti-aliasing",
 "options": "Off=off|TAA=taa", "bind": "Graphics_Settings.antialiasing"}
{"name": "settings_vsync", "kind": "check_row", "label": "VSync",
 "bind": "Graphics_Settings.vsync"}
```

`Label=Value` names what the option writes: a number, the name of a member of an enum, or text for
a text field. Without values the selector binds the index, as an enum declared in that order does.
A value no option has shows as empty. Bound to anything else, a control reports `Changed` and the
game writes the field.

## Apply settings

The settings page writes the settings directly. To set them from code, in a frame step, write the
fields; the engine brings the window and the renderer to them at once:

```odin
graphics.quality=.Medium        // ^render.Graphics_Settings: the fields follow a preset named
graphics.render_scale=0.75      // the fraction of the window drawn; 0: the target of the preset
graphics.sun_shadows=false      // no ray goes to the sun
graphics.frame_limit,graphics.vsync=60,true // 0: no limit
display.mode=.Fullscreen        // ^render.Display_Settings; .Project as authored
```

`frame_limit`, `vsync`, `antialiasing` and `show_fps` do not count for a preset. `quality` is only
an input: writing a preset there moves its fields, and nothing writes it back.
`render.graphics_quality_of(graphics^)` gives the preset the fields are at, `Custom` when a field
was changed by hand. A preset selector is a `Selector` of its own name (inside a `select_row` every
control is named `control`), bound to a field the game fills with that value; on `Changed` the game
calls `render.graphics_preset_apply`, which also gets back to the preset `quality` already names.
Naming a preset resets `render_scale` to 0, which follows the target of the preset: a height of lines over
the window, never above a pixel per point.

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
