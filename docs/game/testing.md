---
name: testing
description: Verify a Mirai game cheaply - scenario files and mirai play test, play.explore,
  play.qa.start and play.qa.report, the playtester agent, play.observe, play.check, captures.
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
7. A rule of one step, in milliseconds and without the editor: [Tests of steps](#tests-of-steps).

## Tests of steps

A `@(test)` in a `_test.odin` of the game builds a world of the tables the step reads and writes,
runs the step and checks them; `mirai test game` (or `mirai test` inside the project) runs it.

- The world is a struct marked `@(test_world)` at the top of the test file, which starts with
  `using world:Test_World` and has a `core.Table(T)` per component and the value of each storage:
  `mirai test` writes what the attributes of its types say into `worlds_gen_test.odin` of the
  package (not for git), `test_world_init(t,&w)` makes the world and `test_world_destroy(&w)`
  frees it.
- A path in a test is relative to the root of the engine, not of the project.

## Look

- `play.check` tests conditions on the game now and answers the value each one read: one field
  of one entity is a condition with no `compare`.

## Play by hand

- Keys across consecutive `play.step` calls: [input](testing/scenario.md#input).
- Walk to something without a bot: `play.step` with `drive`
  ([scenario.md](testing/scenario.md#drive)).

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
