# Playable game: physics character, destructible wall, animated interface, sound, save game and network

A small game made only with the public API of the engine, to copy from. It is played in the scene `assets/arena/main.scene`.

| File | What it is |
| --- | --- |
| `project.mirai` | Name, version, identifier, icon, start scene (`arena/main.scene`), window and build options. |
| Actions | `move` (W A S D, left stick), `look` (mouse, right stick), `jump` (Space, South), `hit` (left button, right trigger), `save` (F5, Start) and `load` (F9, Back). |
| `settings.mirai` | `Spawn_Settings.players = true`: the `spawn` plugin gives each player (the one of this machine and, on a server, the one of each connection) the character of the spawn point, and destroys it when the player leaves. |
| `game/game.odin` | The game library. `Player` is the character component; `Status` is what the two interfaces show. `HIT`, `SAVE` and `LOAD` are its actions, whose keys `Game_Actions` gives in code (`move` and `jump` belong to locomotion and `look` to the engine, which give theirs); `game_mouse` captures the mouse; `game_hit` (`server`: only where the rules are decided) damages what is in front of the view with `HIT` (`destruct.damage`, which ignores what is not destructible); `game_play` counts the hits the wall received (`Destruct_Events`) and saves or loads the `quick` slot with `SAVE` and `LOAD`. |
| `editor/editor.odin` | The engine-time package of the project, empty: its own tools and panels go there. It never enters the distributed game. |
| `tools/content/main.odin` | Writes every asset of `assets/` and the WAV of `source/`. Run it from the project folder with `odin run tools/content -collection:mirai=<engine> -collection:plugins=<engine>/plugins -collection:project=. -custom-attribute:component,storage,step,loops,stage,after,before,server,shared,locks,host,by_world,copy,copy_kept,swap,free,replicated,setting,description,queue,events,keep,persist,single,far,reset,net_message,from,reliable,params,names,name_bits,name,name_requires,presentation,record`; it gives the same bytes every time. |
| `assets/arena/main.scene` | Floor, spawn point (`Spawn_Point`) with `Player.prefab`, the wall (`Destructible`, 24 pieces, anchored to the floor), a speaker with a looping sound (`Audio_Source`), a sign over it (`World_Widget`) and the HUD (`UI_Screen`). The sign and the HUD carry a `Status`. |
| `assets/player/Player.prefab` | The character (`Character`, `Locomotion`, which walks it, jumps and makes it fall with the actions of the seat that drives it, `Move_Input`, `Player`, `Drivable`, `Replicate`) with its camera at the eyes (`Camera_Follow` in `Eyes` mode, which looks where the character looks): what appears for each player and what a client creates for each replica. |
| `assets/hud/hud.ui`, `assets/arena/sign.ui` | The interfaces: they show `message` and `hits` of `Status`; the HUD has a badge that pulses (a looping animation). |
| `assets/hud/badge.tex` | The badge image. |
| `assets/arena/hum.sound`, `source/sounds/hum.wav` | The hum of the speaker and its source. |

To play: `mirai play <project>`, or Play in the editor (`mirai edit <project>`). With network: `mirai play <project> --server` and, in another terminal, `mirai play <project> --connect 127.0.0.1`. The server decides the hits and breaks the wall; each client predicts its character. A network session does not save games. `mirai build game` builds the game to distribute in `.mirai/game`.

To test how it plays: write each behavior as a scenario in `tests/scenarios/<name>.mirai` (the scene, then steps that are calls of the play methods: input, ticks, checks) and run them all with `mirai play test <project>`, which exits with 1 when one fails.

Escape releases the mouse and captures it again.
