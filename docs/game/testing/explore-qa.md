# Explore and QA monitors

`play.explore` is a bot with no model: it costs no tokens, and the same seed on the same game
plays the same ticks. The QA monitors watch every tick the API runs (`play.step`, a scenario,
`play.explore`, a filmstrip) and turn what goes wrong into a violation you can replay. Both come
with the `playtest` plugin, which the game template enables.

## Explore

```bash
mirai rpc --project . play.start '{}'            # builds first when Odin changed
mirai rpc --project . play.explore '{"mode":"Ui","seconds":20}' \
  --select stopped,pages,activated,never,exits,passed
mirai rpc --project . play.explore '{"mode":"World","seed":7,"seconds":60}' \
  --select stopped,cells,passed,violations,repros
mirai rpc --project . play.stop
```

- `mode` `World`: the seat walks and jumps with its actions toward the cells of the world it
  has been in the least. `Ui`: it presses every button it sees with the pointer, goes back with
  Escape and follows the pages it reaches.
- Give `seconds` or `ticks`, not both. `seed` varies the walk; `cell` is the side of a coverage
  cell in meters.
- `World` finds the action that moves (an `Axis2` bound to keys or the left stick) and the one
  that jumps (`Space` or the south button); name them with `move` and `jump` when it cannot.
  `input.get` lists the actions.
- It arms the monitors itself when none are armed (stuck, falling, non-finite, problems).

## Read the result

- `stopped`: `Ticks` (its time ran out; raise it for more coverage), `Ui_Covered` (every
  button it reached was pressed: done), `No_Ui` (no screen with buttons), `No_Body` (the seat
  drives nothing: no `Spawn_Point` or prefab), `No_Progress` (presses lead nowhere new),
  `Blocked_By_Ui` (a modal screen that nothing closes: a menu bug), `Run_Ended`.
- `cells`: places of the world it stood in. A level it cannot cross shows fewer cells than you
  expect; compare seeds.
- `activated` and `never`: buttons pressed, and buttons seen or laid out and never pressed
  (disabled, hidden or behind a page it could not reach). Each is `screen|node`.
- `exits`: each time a button asked the game to quit. The bot holds the request and goes on, so
  an Exit button is expected to appear here, with its tick; if it does not, it is broken.
- `passed` is false when a monitor saw a violation; `violations` lists them and `repros` are
  scenario files written for the first kinds of them.

## QA

Arm it from any tick. A repro plays the run from tick 0, so every tick from the first must come
from the API or the violation cannot write one:

```bash
mirai rpc --project . play.qa.start '{"frame_ms":50}'
mirai rpc --project . play.step '{"seconds":10,"keys":["W"]}'
mirai rpc --project . play.qa.report '{}' --select passed,violations
```

- Monitors: `frame_ms`, `memory_mb`, `stuck_seconds` (the body asks to move and does not),
  `fall_below` (a height), `non_finite` (a NaN or infinite `Transform`) and `problems` (a
  `core.report` problem). `stuck_seconds` (3), `non_finite` and `problems` are on unless turned
  off; `frame_ms` and `memory_mb` are off at 0. `fall_below` is a little under the lowest of the
  scene when absent, and `falls:false` turns it off.
- A violation has `kind` (`Frame_Time`, `Memory`, `Stuck`, `Fell`, `Non_Finite`, `Problem`), a
  `severity`, the `tick` it first happened, the `position` of the body and, for a problem, its
  `code` and `text`.

## Repro and filmstrip

```bash
mirai rpc --project . play.qa.report '{"violation":0,"repro":true}' --select repro
mirai play test . bug_412
mirai rpc --project . play.qa.report '{"violation":0,"filmstrip":"C:/work/bug.png"}'
```

- `repro` writes `tests/scenarios/bug_<tick>.mirai`: the inputs from tick 0 up to the violation,
  ending in a `play.qa.report` that says whether its kind happened. It fails while the bug
  exists and passes once fixed; keep it as a regression test, renamed.
- `filmstrip` writes one PNG of the ticks around the violation, from the run's past; the game
  stays where it is. Open the image only if the position and tick are not enough.
- `violation` is the `index` in the report; `-1` or absent writes neither.
- A repro plays the inputs from tick 0 (holds, devices and the changes of `play.set`,
  `play.spawn`, `play.destroy` and `play.push`), starts only the monitor of its kind where the run
  did, and clicks replay at the same window size. `Frame_Time` and `Memory` measure the machine
  (`Memory` is growth since the start): their repros do not fail reliably.

## Pitfalls that fail silently

- The monitors count only the ticks the API runs: what an unpaused Play runs is not seen, and a
  run that advanced or went back outside the API cannot write a repro (the answer says why).
- `play.explore` in `World` mode on a game with no `Axis2` action fails with a message that says
  to name the action with `move`; `Ui` mode needs a screen with buttons on top (`No_Ui` if none).
- An exit button never ends the run: look in `exits`, not at `stopped`.
- `play.stop` discards the run: copy `repros` paths and read violations first.
