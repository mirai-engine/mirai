# Scenarios: gameplay tests as files

A scenario is a gameplay test written once as a file, `tests/scenarios/<name>.mirai`. It plays a
scene from its first tick, runs its steps in order as calls of `play.*` methods with their params,
and stops the game. Only its steps advance the game, so the same file plays the same ticks every
time. The first step that fails ends it.

## Write one

```json
{"scene": "arena/main.scene", "start": {"players": 1}, "steps": [
  {"name": "the game opens", "method": "play.step", "params": {"for": 30}},
  {"name": "walk forward", "method": "play.step", "params": {"for": "1s", "keys": ["W"]}},
  {"name": "the player walked", "method": "play.check", "params": {"conditions": [
    {"entity": "Player", "field": "world_position.2", "compare": "Below", "number": 4.5}]}}
]}
```

- `scene` names the scene it plays; without it, the one open. `start` takes the params of
  `play.start` (`players`); leave it out for the defaults.
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
{"entity": "Door", "field": "Open", "compare": "Exists"}
{"entity": "Pickup", "compare": "Gone"}
```

- The subject is an `entity`, by its name, a path Parent/Child, its id or its handle, or a
  `storage`. `field` names the value inside it: `Component.field.0.field` for an entity
  (`Motion.linear.1`, where `a[0].b` is `a.0.b`), and `play.get` takes the same path.
- `compare`: `Exists` (the default), `Gone`, `Equal`, `Not_Equal`, `Below`, `At_Most`, `Above`,
  `At_Least`. A number is `number` (a bool is 1 or 0); an enum member or a text is `text`.
- Names of components, storages and fields: `component.list` and `play.inspect`; `Open`,
  `Door` and `Pickup` above stand for your own.

## Wait

`play.step` with `until` runs ticks until the conditions hold; `for` is the most it runs, and
none run when they hold already. If they never hold, the step and the scenario fail.

```json
{"name": "the scene starts over", "method": "play.step", "params": {"for": 900, "until": [
  {"entity": "Player", "field": "world_position.2", "compare": "Above", "number": 4.5}]}}
```

## Input

- `keys` are held on every tick of the step, `tap_keys` pressed and released inside its first
  tick, `mouse_buttons` and `tap_buttons` likewise; `mouse_position` is in window points from the
  top left and stays; `mouse_delta` turns the view; `text` types into a focused field.
- `segments` change the input along the step, each for its `for`:

```json
{"method": "play.step", "params": {"segments": [{"for": 2, "keys": ["Escape"]}, {"for": 10}]}}
```

- Ten quiet ticks after a key let a menu change page before the next check.
- Click a button of the screen on top by its name: `{"press": "start", "for": 10}`; it holds
  the pointer and the button as a click takes, and `for` runs after it.
- A key named in consecutive steps stays held, with no release between them; a step that omits it
  releases it: a jump held over several steps is not cut.
- Hold a game action by name for some ticks: `play.input`; teleport or change an entity:
  `play.set`; place a prefab: `play.spawn`.

## Drive

`drive` in `play.step` walks the focused player to a target by the game's own move action, re-aimed
every tick: an `entity`, followed where it goes, or a `position`. It takes off at the edge of a gap
and when blocked, holding the jump as long as it still rises, then tries each side; it stops within
`within` meters across the ground (1 by default), at the `for` of the step (30 s if
neither is given), when `until` holds, or when it gets no closer:
`{"drive": {"entity": "Checkpoint 2", "within": 1.5}, "for": "20s"}`.

- An `entity` with a solid top raised off the floor, or out of reach above or below its feet
  (about the height of the player's body), arrives only standing on it; it climbs by itself and
  jumps again from farther if it fell short.
- A `position` compares `y` within `within` plus about the height of the player's body: give the
  ground's, not 0.
- The answer says `drive.stopped`, where it ended (`drive.position`, `drive.distance`,
  `drive.height` of its feet over the target) and `ran`. In a scenario a drive that does not arrive
  (or end at `until`) fails.
- A moving platform is not predicted: wait for it with `until` on its `world_position`, then drive.
- `look_at` (an `entity` or `position`) turns the view; `play.view` says the live `follow.yaw_deg`.

## Run

```bash
mirai play test . shell            # one scenario by name; no name: all of tests/scenarios
```

One line per file, `PASS` or `FAIL` with the step and what its method answered; exit 0 all
passed, 1 one failed, 2 could not run. `play.scenario.run` (`path`: a file or a folder) answers
every step with its tick and result; a file its methods would not take fails whole before the
game starts, and it fails while a game of the caller already plays or when the game does not build.
Outside a turn it opens the scene of the scenario if the document is another without unsaved
changes; in a turn the document must be that scene. A long trace or filmstrip goes in a run of its
own: the response buffer bounds the results of its steps.

## Monitors

A step `play.qa.start` arms the monitors and a step `play.qa.report`, the last, fails the scenario
on any violation, which is how a repro ends ([explore-qa.md](explore-qa.md#qa)).

## Pitfalls that fail silently

- A duration is `for`: a number is ticks, exact, and a text ending in `s` is seconds (`"1.5s"`),
  rounded to whole ticks, at least 1.
- A `name` two entities share fails with their paths: give test entities distinct names.
- A scenario file in `tests/scenarios` that is a left-over `bug_*.mirai` runs with the rest.
