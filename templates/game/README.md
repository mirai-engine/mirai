# Playable game: physics character, destructible wall, animated interface, sound, save game and network

A small game made only with the public API of the engine, to copy from. It is played in the scene `assets/scenes/main.scene`.

| File | What it is |
| --- | --- |
| `project.mirai` | Name, version, identifier, icon, start scene (`scenes/main.scene`), window and build options. |
| Actions | `move` (W A S D, left stick), `look` (mouse, right stick), `jump` (Space, South), `hit` (left button, right trigger), `save` (F5, Start) and `load` (F9, Back). |
| `settings.mirai` | `Spawn_Settings.players = true`: the `spawn` plugin gives each player (the one of this machine and, on a server, the one of each connection) the character of the spawn point, and destroys it when the player leaves. |
| `game/game.odin` | The game library. `Player` is the character component; `Status` is what the two interfaces show. `HIT`, `SAVE` and `LOAD` are its actions, whose keys `Game_Actions` gives in code (`move` and `jump` belong to locomotion and `look` to the engine, which give theirs); `game_hit` (`server`: only where the rules are decided) damages what is in front of the view with `HIT` (`destruct.damage`, which ignores what is not destructible); `game_play` counts the hits the wall received (`Destruct_Events`); `game_saves` saves or loads the `quick` slot with `SAVE` and `LOAD`. |
| `game/shell.odin` | Main menu, pause (Esc) and graphics settings, with mouse and keyboard. `Shell.page` is the page `assets/ui/shell.ui` shows; `Shell_Options` is what the player chose, kept in the profile by itself (`@(storage,persist)`), and `shell_apply` brings `Graphics_Settings` and `Display_Settings` to it. Pause stops the clock; Quit to Menu restarts the scene (`scene.request_restart`). It is the only code that captures the mouse. |
| `tests/scenarios/shell.mirai` | Plays menu, Play, pause, a setting and Quit to Menu with real keys: `mirai play test <project> shell`. |
| `editor/editor.odin` | The engine-time package of the project, empty: its own tools and panels go there. It never enters the distributed game. |
| `tools/content/main.odin` | Writes every asset of `assets/` and the WAV of `source/`. Run it from the project folder with `odin run tools/content -collection:mirai=<engine> -collection:plugins=<engine>/plugins -collection:project=. -ignore-unknown-attributes`; it gives the same bytes every time. |
| `assets/scenes/main.scene` | Floor, spawn point (`Spawn_Point`) with `Player.prefab`, the wall (`Destructible`, 24 pieces, anchored to the floor), a speaker with a looping sound (`Audio_Source`), a sign over it (`World_Widget`) and the HUD (`UI_Screen`). The sign and the HUD carry a `Status`. |
| `assets/prefabs/Player.prefab` | The character (`Character`, `Locomotion`, which walks it, jumps and makes it fall with the actions of the seat that drives it, `Move_Input`, `Player`, `Drivable`, `Replicate`) with its camera at the eyes (`Camera_Follow` in `Eyes` mode, which looks where the character looks): what appears for each player and what a client creates for each replica. |
| `assets/ui/hud.ui`, `assets/ui/sign.ui` | The interfaces: they show `message` and `hits` of `Status`; the HUD has a badge that pulses (a looping animation). |
| `assets/ui/shell.ui` | The pages of `game/shell.odin`; its colors, styles and sizes are in `write_shell` of `tools/content/main.odin`. |
| `assets/textures/badge.tex` | The badge image. |
| `assets/sounds/hum.sound`, `source/sounds/hum.wav` | The hum of the speaker and its source. |

To play: `mirai play <project>`, or Play in the editor (`mirai edit <project>`). With network: `mirai play <project> --server` and, in another terminal, `mirai play <project> --connect 127.0.0.1`. The server decides the hits and breaks the wall; each client predicts its character. A network session does not save games. `mirai build game` builds the game to distribute in `.mirai/game`.

To test how it plays: write each behavior as a scenario in `tests/scenarios/<name>.mirai` (the scene, then steps that are calls of the play methods: input, ticks, checks) and run them all with `mirai play test <project>`, which exits with 1 when one fails.

Escape pauses the game and frees the mouse; Escape again resumes.
