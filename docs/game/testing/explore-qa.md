# Explore and QA monitors

`play.explore` is a bot with no model: it costs no tokens, and the same seed on the same game
plays the same ticks. The QA monitors watch every tick the API runs (`play.step`, a scenario,
`play.explore`, a filmstrip) and turn what goes wrong into a violation you can replay. Both come
with the `playtest` plugin, which the game template enables.

## Audit gate

Run a one-command preflight before handing a build to a player:

```bash
mirai play audit . --ticks 60 --copy                 # headless Play + play.audit (+ --explore)
mirai rpc --project . scene.audit '{"world":"Auto"}' # static scene flags & fixes
mirai rpc --project . play.audit '{"ticks":60,"frame_ms_budget":16.7}'
```

Both RPC calls return `{passed, flags: [{severity, area, code, entity, message, fix}], summary}`.
Both flag a material, effect or post-process layer whose program the shaders do not have
(`material.program_missing`, `render.particle_program`, `render.post_process_program`): it draws
nothing and reports nothing else. They flag a mesh drawn 30 times its size or more, a source in
other units (`render.scale_far`, the import's rule), or 10 times the scale of the others of its mesh
(`render.scale_odd`), and an attachment whose drawn box is farther from its bone than a quarter of
its size (`animation.attachment_far`).

`play.audit` adds live UI cursor-capture and keyboard-focus checks, NaN/stuck checks, GPU/CPU
frame budget checks and, with a GPU, the frame of the game measured:

- mostly crushed black or clipped white (`render.frame_dark`: 90 % under 0.02 linear;
  `render.frame_blown`: half of it clipped with a near-white median);
- the window clipped white while the same view metered at once is not: the exposure starts at its
  floor and the first frames of Play are white (`render.exposure_adapting`);
- an effect in view with particles alive that changes fewer than 16 pixels of the 256-wide frame
  (`render.effect_unseen`): each such effect is left out of one more frame and the pixels compared.

Along its `ticks` it watches the rigs in their own space: one that plays and never moves a bone
(`animation.rig_frozen`) and a bone that jumps in one tick (`animation.bone_snap`). An Error means
the build is not ready, whatever the scenarios say.

## Explore

```bash
mirai rpc --project . play.start '{}'            # builds first when Odin changed
mirai rpc --project . play.explore '{"mode":"Ui","for":"20s"}' \
  --select stopped,pages,activated,never,exits,passed
mirai rpc --project . play.explore '{"mode":"World","seed":7,"for":"60s"}' \
  --select stopped,cells,passed,violations,repros
mirai rpc --project . play.stop
```

- `mirai rpc --project . describe play.explore` lists its params and the results.
- `mode` `World`: the seat goes with its actions to the cells of the world it has been in the
  least, each as a [drive](scenario.md#drive) goes to a position: along the navigation meshes,
  over gaps and around what blocks it. `Ui`: it presses every button it sees with the pointer,
  goes back with Escape and follows the pages it reaches. `seed` varies the walk.
- `World` finds the action that moves (an `Axis2` bound to keys or the left stick) and the one
  that jumps (`Space` or the south button); name them with `move` and `jump` when it cannot.
  `input.get` lists the actions.
- It arms the monitors itself when none are armed (stuck, falling, non-finite, problems).

## Read the result

- `stopped` says why it ended (`describe` lists the reasons). `Ticks`: its time ran out; raise
  `for` for more coverage. `Ui_Covered`: every button it reached was pressed, done. `No_Body`: the
  seat drives nothing, so there is no `Spawn_Point` or prefab. `Blocked_By_Ui`: a modal screen
  that nothing closes, a menu bug.
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
mirai rpc --project . play.step '{"for":"10s","keys":["W"]}'
mirai rpc --project . play.qa.report '{}' --select passed,violations
```

- `describe play.qa.start` lists the monitors with their defaults and `describe play.qa.report`
  the fields of a violation. Stuck means the body asks to move and does not; non-finite, a NaN or
  infinite `Transform`; a problem, one that `core.report` stored. Stuck, non-finite and problems
  are on unless turned off; the frame time and memory limits are off until given. Without
  `fall_below` the fall height is a little under the lowest of the scene.
- A violation has its `kind`, the `tick` it first happened and the `position` of the body.

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
- A repro plays the inputs from tick 0 (holds, devices and the changes of `scene.write` with
  `"world": "Game"` and of `play.push`), starts only the monitor of its kind where the run
  did, and clicks replay at the same window size. `Frame_Time` and `Memory` measure the machine
  (`Memory` is growth since the start): their repros do not fail reliably.

## Pitfalls that fail silently

- The monitors count only the ticks the API runs: what an unpaused Play runs is not seen, and a
  run that advanced or went back outside the API cannot write a repro (the answer says why).
- `play.explore` in `World` mode on a game with no `Axis2` action fails with a message that says
  to name the action with `move`; `Ui` mode needs a screen with buttons on top (`No_Ui` if none).
- An exit button never ends the run: look in `exits`, not at `stopped`.
- `play.stop` discards the run: copy `repros` paths and read violations first.
