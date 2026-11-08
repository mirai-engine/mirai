# Settings: graphics, window, display

A **setting** is a storage of an engine library, a plugin or your game that the editor, the API
and files can set by name. A **machine setting** is a preference of whoever uses the machine and
not a design choice: graphics quality (`Graphics_Settings`), the window as the player chose it
(`Display_Settings`), the volume of each bus (`Audio_Volumes`), the sound output (`Audio_Output`),
the language and scale of interfaces (`UI_Preferences`). Fields and ranges: `engine.describe`.

## Where a value comes from

From the bottom: the default in code (graphics start at what suits the GPU); the engine file of
this machine (machine settings only, shared by every project); `settings.mirai` of the project
(any setting); in a shipped or played game, the player's options file (machine settings only). The
top layer that sets a field wins. A file stores only what differs from the layers below.

```json
{
  "Graphics_Settings": {"frame_limit": 0, "vsync": false, "show_fps": true},
  "Display_Settings": {"mode": "Windowed", "width": 1280, "height": 720},
  "Spawn_Settings": {"players": true}
}
```

One section per setting, named by its type; enums by name. Never hand-write `input.mirai`.
`mirai build game` writes next to the executable one `settings.mirai` that merges the machine
sections of the engine file with the project's: the shipped game reads no engine file.

## Edit them

- In an editor session: `settings.get` shows `machine` (the names of the machine settings),
  `settings` (effective values), `engine` and `project` (what each file sets).
  `settings.set {"layer":"project","settings":{"Graphics_Settings":{"vsync":true}}}` writes the
  project's file; `"layer":"engine"` takes machine sections only and writes this machine's file.
  A field the project overrides does not change under `engine`.
- The editor's Project Settings dialog and Graphics popup do the same.
- Your own `@(storage,setting)` struct is a project setting: its type name is the section.

## The window

`project.mirai` says how the game opens:

```json
"window": {"title": "My game", "mode": "Windowed", "width": 1280, "height": 720}
```

`mode` is `Maximized`, `Fullscreen` or `Windowed` (width and height apply only to `Windowed`);
`icon` (a PNG), `identifier` (reverse domain name) and `version` are beside it. `Display_Settings`
is the player's override: `mode` `Project` (as `project.mirai` says), `Windowed`, `Maximized` or
`Fullscreen`; `width` and `height` in points, 0 for the project's; `display`, the monitor, 1 for
the first one the system lists and 0 for where the system opens it. A `display` the machine does
not have is the problem `render.display`. `--window x,y,w,h` of the player places a window for a
test ([player.md](player.md)).

## An options menu in the game

A game step may write the settings storages; the engine brings the window and the renderer to
them at once. Persist the player's choices in your own `@(storage,persist)` and
`save.request_profile_save` ([core](../core/saves.md)), or let the
engine keep the machine settings with `save.request_options_save`.

```odin
@(step="frame")
game_apply_options :: proc(graphics:^render.Graphics_Settings,display:^render.Display_Settings,
                           options:core.Ref(My_Options)) {
    render.graphics_preset_apply(graphics,options.preset)   // .Low, .Medium, .High, .Ultra
    graphics.frame_limit,graphics.vsync=options.limit,options.vsync       // 0: no limit
    display.mode=options.fullscreen?.Fullscreen:.Project
}
```

`render.graphics_preset_apply` sets only the quality fields; `render_scale`, `antialiasing`
(`base.text_set(graphics.antialiasing[:],render.ANTIALIASING_TAA)`, or `ANTIALIASING_OFF`),
`frame_limit`, `vsync` and `show_fps` stay as they were. Volume is `audio.audio_volume_set`
([audio](../audio.md)); language and interface scale are `gui.UI_Preferences`.

## Pitfalls that fail silently

- A section named for a type that no active plugin declares is kept and ignored; a misspelled field
  is skipped when read and an error through `settings.set`.
- `settings.set` with `"layer":"engine"` changes every project on this machine.
- A fixed `Graphics_Settings` in `settings.mirai` of the project hides the machine's default for
  the GPU; the player's own options still override it.
