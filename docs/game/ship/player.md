# The player: headless runs, captures and scripted input

`mirai play .` hands what it does not read itself to the player, and the built game takes the
same options. A run that plays a script and writes its last frame:

```sh
mirai play . --frames 180 --input .mirai/run.txt --capture .mirai/shot.png
```

## Options

- `--scene <path>`: the start scene, relative to `assets/`, instead of `start_scene`.
- `--headless`: no window; it draws offscreen in steps of 1/60 s, so `--frames 120` is two
  seconds of game, the same every run. Needs a GPU. `--frames`, `--input` and `--capture` imply
  it; `--show-window` keeps a window for them.
- `--no-gpu`: no window and no renderer, only the simulation: fast logic checks, no picture.
- `--frames <n>`: exit after n frames. Without it the run goes on until the game quits.
- `--capture <png>`: write the last frame as a PNG on exit. The folder must exist; it fails
  with `--no-gpu` or `--dedicated`.
- `--input <script>`: press keys, move the mouse and click, as below.
- `--validation`: graphics API validation; the run ends with code 6 if it reports errors.
- `--players <n>`: 1 to 4 local split-screen players; without it, what the scene says.
- `--window <x>,<y>,<width>,<height>`: place the window, frame included, in screen coordinates.
- Network options (`--server`, `--connect`) belong to the `multiplayer` plugin
  ([networking](../networking.md)).

Exit code 0 is a normal run; 1 the application could not be created; 2 an option or a script line
it does not understand; 3 the start scene did not load; 4 the capture could not be written; 6
validation errors; 7 the GPU stopped working. An option nobody reads prints the usage and exits 2.

## Input script

A text file, one line per held input: `<first frame> <last frame> <what>...`; `#` starts a line
that is ignored. Frames count from 0 at the first frame the script plays.

```text
# open the pause menu, click the first button, then walk and jump
10 10 Escape
20 20 pointer:640,360 mouse:Left
60 120 W
90 90 Space
130 130 look:200,0
```

- `<what>` is one or more of: a key as `core.Key` names it (`W`, `A`, `Space`, `Enter`, `Escape`,
  `Tab`, `Left`, `Left_Shift`, `F5`, `One`...), `mouse:Left` (or `Right`, `Middle`), `look:dx,dy`
  and `pointer:x,y`. Separate them with spaces.
- A key or button is down from `first` to `last`, both included: pressed on `first`, released on
  the frame after `last`. A tap is `first` equal to `last`.
- `look:dx,dy` is mouse movement added on every frame of the line: a turn of 200 points in one
  frame is `130 130 look:200,0`; spread it with `130 160 look:6.7,0`.
- **`pointer:x,y`** puts the pointer at x, y in window points (origin at the top left of the
  window) on the line's first frame, and it stays there after the line ends until another line
  moves it, so a release lands where the press did. Interfaces and world panels see it as the
  mouse. To click, add `mouse:Left` on the same or a later line: `20 20 pointer:640,360
  mouse:Left`. To drag, place the pointer at the start with the press and move it with later
  `pointer:` lines.
- With `--players`, keyboard and mouse go to the focused local player.

## Pitfalls that fail silently

- A script is exact frames, not events: a click at frame 20 misses a button that is not on screen
  yet. Run with `--capture` and a smaller `--frames` to see where the game stands first.
- A key name that `core.Key` does not have, or a line with fewer than three fields, exits 2 and
  names the line.
- `--capture` without `--frames` waits for the game to quit: add `--frames`.
- A window run is real time and `--headless` steps 1/60 s a frame: a script timed in one can
  drift in the other.
