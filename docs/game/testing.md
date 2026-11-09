---
name: testing
description: Verify a Mirai game cheaply - scenario files and mirai play test, play.explore,
  play.qa.start and play.qa.report, the playtester agent, play.observe, play.get, captures.
---

# Testing a game

The game advances only when a call asks for ticks, so every check is repeatable and a slow
model plays as well as a fast one.

## Map

Prefer the first that answers the question:

1. A behavior you can state ("Escape pauses", "the door opens"), forever after:
   [scenario.md](testing/scenario.md) and `mirai play test .`.
2. "Does anything break?", no tokens: [explore-qa.md](testing/explore-qa.md#explore).
3. A violation to reproduce and look at: [explore-qa.md](testing/explore-qa.md#qa).
4. A goal that needs judgment, or a screen to look at: give `.claude/agents/playtester.md` the
   goal ([playtester.md](testing/playtester.md)).
5. One look at the state: [Look](#look) and [playtester.md](testing/playtester.md#inspect).
6. Menus and HUD: [UI and menus](#ui-and-menus).

## Look

- `play.observe`: tick, the body's place and facing, `stuck`, `problems`, the buttons of the top
  screen and the nearest `targets`; with `step` it runs those ticks first.
- `play.get` reads one field of one entity; `play.check` tests conditions on the game now.

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
- `play.stop` discards what the game changed; read what you need before it.
