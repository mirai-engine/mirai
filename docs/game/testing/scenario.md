# Scenarios

A scenario is a gameplay test written once as a file, `tests/scenarios/<name>.mirai`. It plays a
scene from its first tick, runs its steps in order as calls of `play.*` methods with their params,
and stops the game. Only its steps advance the game, so the same file plays the same ticks every
time. The first step that fails ends it.

## Map

- The smallest file: [Write one](#write-one). The template's `shell.mirai` is a larger one.
- Test a value: [Conditions](#conditions). Wait for something: [Wait](#wait).
- Press keys, click, hold an action: [Input](#input).
- Run them, read a failure: [Run](#run). Add the monitors of QA: [Monitors](#monitors).

## Write one

```json
{"scene": "scenes/main.scene", "start": {"players": 1}, "steps": [
  {"name": "the game opens", "method": "play.step", "params": {"ticks": 30}},
  {"name": "walk forward", "method": "play.step", "params": {"seconds": 1, "keys": ["W"]}},
  {"name": "the player walked", "method": "play.check", "params": {"conditions": [
    {"entity": "Player", "field": "world_position.2", "compare": "Below", "number": 4.5}]}}
]}
```

- `start` takes the params of `play.start` (`players`); leave it out for the defaults.
- A step's `method` is any `play.*` method but `play.start`, `play.stop` and scenarios: the game
  starts before the first step and stops after the last. Params are checked against the method's
  schema before the game starts; a wrong key is refused with the keys it takes.
- One step per intention, with a `name` that says it: a failure prints that name. Begin with a
  step of about 30 ticks so the world and seats exist.

## Conditions

`play.check` reads conditions on the game now; all must hold.

```json
{"entity": "Player", "field": "world_position.2", "compare": "Below", "number": 4.5}
{"storage": "Shell", "field": "page", "compare": "Equal", "text": "Pause"}
{"storage": "Clock", "field": "paused", "compare": "Equal", "number": 1}
{"entity": "Door", "component": "Open", "compare": "Exists"}
{"entity": "Pickup", "compare": "Gone"}
```

- The subject is an `entity`, by its name, a path Parent/Child, its id or its handle, or a
  `storage`; `component` and `field` go inside it, joined by dots (`velocity.1`).
- `compare`: `Exists` (the default), `Gone`, `Equal`, `Not_Equal`, `Below`, `At_Most`, `Above`,
  `At_Least`. A number is `number` (a bool is 1 or 0); an enum member or a text is `text`.
- Names of components, storages and fields: `component.list` and `play.inspect`; `Open`,
  `Door` and `Pickup` above stand for your own.

## Wait

`play.step` with `until` runs ticks until the conditions hold; `ticks` is the most it runs, and
none run when they hold already. If they never hold, the step and the scenario fail.

```json
{"name": "the scene starts over", "method": "play.step", "params": {"ticks": 900, "until": [
  {"entity": "Player", "field": "world_position.2", "compare": "Above", "number": 4.5}]}}
```

## Input

- `keys` are held on every tick of the step, `tap_keys` pressed and released inside its first
  tick, `mouse_buttons` and `tap_buttons` likewise; `mouse_position` is in window points from the
  top left and stays; `mouse_delta` turns the view; `text` types into a focused field.
- `segments` change the input along the step, each for its `ticks` or `seconds`:

```json
{"method": "play.step", "params": {"segments": [{"ticks": 2, "keys": ["Escape"]}, {"ticks": 10}]}}
```

- Ten quiet ticks after a key let a menu change page before the next check.
- Click a button: a segment with `mouse_position` at the center of its `rect` (from
  `play.observe`), then `{"ticks": 2, "mouse_buttons": ["Left"]}`.
- Hold a game action by name for some ticks: `play.input`; teleport or change an entity:
  `play.set`; place a prefab: `play.spawn`.

## Run

```bash
mirai play test . shell            # one scenario by name; no name: all of tests/scenarios
```

One line per file, `PASS` or `FAIL` with the step and what its method answered; exit 0 all
passed, 1 one failed, 2 could not run. `play.scenario.run` (`path`: a file or a folder) answers
every step with its tick and result.

## Monitors

`play.scenario.run` takes `qa` with the params of `play.qa.start`; a violation fails the scenario:

```bash
mirai rpc --project . play.scenario.run '{"qa":{"fall_below":-5,"non_finite":true,"problems":true}}'
```

A condition `{"qa": true, "field": "Fell", "compare": "Equal", "number": 0}` tests it inside a
file, which is how a repro ends ([explore-qa.md](explore-qa.md#qa)).

## Pitfalls that fail silently

- Steps after the first failure do not run: fix in order, one failure at a time.
- `ticks` and `seconds` in one step are refused; `seconds` rounds to whole ticks, at least 1.
- A condition on a `name` reads the first entity with it; give test entities distinct names.
- A scenario file in `tests/scenarios` that is a left-over `bug_*.mirai` runs with the rest.
