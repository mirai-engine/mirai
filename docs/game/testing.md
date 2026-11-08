---
name: testing
description: Verify a Mirai game cheaply - scenario files and mirai play test, play.explore,
  play.qa.start and play.qa.report, the playtester agent, play.observe, play.get, captures.
---

# Testing a game

The game advances only when a call asks for ticks, so every check is repeatable and a slow
model plays as well as a fast one. Open a headless editor once: `mirai session start .`; later
calls are `mirai rpc --project . <method> '<json>' --select <fields>`. Params of any method:
`mirai rpc --project . describe <method>`. Never call without `--project`.

## Map

Prefer the first that answers the question:

1. A behavior you can state ("Escape pauses", "the door opens"), forever after:
   [scenario.md](testing/scenario.md) and `mirai play test .`.
2. "Does anything break?", no tokens: [explore-qa.md](testing/explore-qa.md#explore).
3. A violation to reproduce and look at: [explore-qa.md](testing/explore-qa.md#qa).
4. A goal that needs judgment, or a screen to look at: [playtester.md](testing/playtester.md).
5. One look at the state: [Look](#look) and [playtester.md](testing/playtester.md#inspect).
6. Menus and HUD: [UI and menus](#ui-and-menus).

## Smallest of each

```bash
mirai play test . shell                  # 1: tests/scenarios/shell.mirai; PASS or FAIL per file
```
```bash
mirai rpc --project . play.start '{}'    # 2: builds first when Odin changed; answers when it plays
mirai rpc --project . play.explore '{"mode":"World","seconds":30}' --select stopped,cells,passed
mirai rpc --project . play.stop
```
```bash
mirai rpc --project . play.qa.start '{"fall_below":-5,"stuck_seconds":3,"non_finite":true}'
mirai rpc --project . play.qa.report '{"violation":0,"repro":true}'   # 3: writes bug_<tick>.mirai
```

4 is an agent: give `.claude/agents/playtester.md` a goal. For 5:

```bash
mirai rpc --project . play.observe '{"targets":["Door*"]}'
mirai rpc --project . play.get '{"entity": "Player","field":"world_position"}' --select value
```

## Look

- `play.observe`: tick, the body's place and facing, `stuck`, `problems`, the buttons of the top
  screen and the nearest `targets`; `play.step` with `observe:true` runs ticks and answers it.
- `play.get` reads one field of one entity; `play.check` tests conditions on the game now.
- `--select a,b.c,d[0]` prints only those fields: always use it on a large answer.
- An image: `capture` with `path`; it answers where the file is and its size, so open
  it only when the number is not enough.

## UI and menus

- Sweep every button with no model: `play.explore {"mode":"Ui"}`; read `never` (buttons it never
  pressed) and `exits` (each time a button asked to quit; the run goes on).
- Drive them as a player in a scenario with `tap_keys` (`Enter`, `Down`, `Escape`), then check
  the storage the menu writes: `tests/scenarios/shell.mirai` does it.
- `play.ui` is the live tree: each screen, its nodes and where they are in the window;
  `play.observe` lists the pressable `buttons` with their `rect`.
- A screen that does not show: `engine.diagnostics` problems `gui.bind` and `gui.asset`.

## Pitfalls that fail silently

- A repro plays from tick 0: give the game its ticks with `play.step` from the first one (a Play
  outside a turn runs by itself until the first `play.step`).
- A call without `--project` goes to the default port, which may be another editor.
- A step with `until` fails the scenario when the ticks run out before the condition holds.
- `play.stop` discards what the game changed; read what you need before it.
- `keys` are held on every tick of a step; `tap_keys` press and release inside the first tick:
  one press of a menu is a tap, walking is a held key.
