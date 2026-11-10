# Playable game: character, destructible wall, animated interface, sound, saves and network

A small game made only with the public API of the engine, to copy from. It is played in the scene
`assets/arena/main.scene`.

| File | What it is |
| --- | --- |
| `project.mirai` | Name, version, identifier, icon, start scene (`arena/main.scene`), window and build options. |
| Actions | `move` (W A S D, left stick), `look` (mouse, right stick), `jump` (Space, South), `hit` (left button, right trigger), `save` (F5, D-pad up) and `load` (F9, Back), and the engine's `menu` (Esc, Start). |
| `settings.mirai` | `Spawn_Settings.prefab` names `assets/player/Player.scene`: the `spawn` plugin gives each player (the one of this machine and, on a server, the one of each connection) a body of it at the spawn point, and destroys it when the player leaves. |
| `game/game.odin` | The game library. `Player` is the character component; `Status` is what the two interfaces show. `HIT`, `SAVE` and `LOAD` are its actions, whose keys `action_defaults` gives in code (`move` and `jump` belong to locomotion and `look` to the engine, which give theirs); `game_hit` (`server`: only where the rules are decided) damages what is in front of the view with `HIT` (`destruct.damage`, which ignores what is not destructible); `game_play` counts the hits the wall received (`Destruct_Events`); `game_saves` saves or loads the `quick` slot with `SAVE` and `LOAD`. |
| `game/shell.odin` | Main menu, pause (Esc, Start) and graphics settings, with mouse and keyboard. `Shell.page` is the page `assets/menu/shell.ui` shows, and its settings page binds the fields of `Graphics_Settings` and `Display_Settings` directly, so the engine holds and keeps what the player chose. Pause stops the clock; Quit to Menu restarts the scene (`scene.request_restart`). The `pause` of its Modal screen stops the clock on those pages; the engine holds and frees the mouse. |
| `tests/scenarios/shell.mirai` | Plays menu, Play, pause, a setting and Quit to Menu with real keys: `mirai play test <project> shell`. |
| `editor/editor.odin` | The engine-time package of the project, empty: its own tools and panels go there. It never enters the distributed game. |
| `tools/content/main.odin` | Writes what code generates: the badge, the hum and its WAV of `source/`. Run it with `mirai content <project>`; it gives the same bytes every time. |
| `assets/arena/main.scene` | Floor, spawn point (`Spawn_Point`) with `Player.scene`, the wall (`Destructible`, 24 pieces, anchored to the floor), a speaker with a looping sound (`Audio_Source`), a sign over it (`World_Widget`) and the HUD (`UI_Screen`). The sign and the HUD carry a `Status`. |
| `assets/player/Player.scene` | The character (`Character`, `Walk`, which walks it, jumps and makes it fall with the actions of the seat that drives it, `Move_Input`, `Player`, `Replicate`) with its camera at the eyes (a child with `Camera_Follow` in `Eyes` mode: the player looks and walks where it looks): what appears for each player and what a client creates for each replica. |
| `assets/hud/hud.ui`, `assets/arena/sign.ui`, `assets/menu/*.ui` | The source of the interfaces: `hud.ui` and `sign.ui` show `message` and `hits` of `Status` (the HUD has a badge that pulses, a named animation), `shell.ui` the pages of `game/shell.odin` and `theme.ui` the look they share, tokens and styles, and `button.ui`, `panel.ui`, `select_row.ui` and `check_row.ui` the widgets the screens use. `mirai rpc ui.inspect` reads them, `ui.write` changes them, the editor edits the same files. |
| `assets/hud/badge.tex` | The badge image. |
| `assets/arena/hum.sound`, `source/sounds/hum.wav` | The hum of the speaker and its source. |

To play: `mirai play <project>`, or Play in the editor (`mirai edit <project>`). With network:
`mirai play <project> --server` and, in another terminal,
`mirai play <project> --connect 127.0.0.1`. The server decides the hits and breaks the wall; each
client predicts its character. A network session does not save games. `mirai build game` builds
the game to distribute in `.mirai/game`.

To test how it plays: write each behavior as a scenario in `tests/scenarios/<name>.mirai` (the
scene, then steps that are calls of the play methods: input, ticks, checks) and run them all with
`mirai play test <project>`, which exits with 1 when one fails.

Escape or Start pauses the game; while the pause menu shows, the mouse is free. Escape again
resumes.
