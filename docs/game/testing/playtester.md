# Playtester agent and inspection

When the question needs judgment ("can a new player reach the door?", "is the HUD readable?"),
a model plays. The game advances only between calls, so the model can take as long as it needs
per decision and a small, slow one plays as well as a fast one.

## Map

- Hand a goal to the agent: [Agent](#agent).
- Look at the state yourself, cheaply: [Inspect](#inspect).
- Look at the image: [Images](#images).

## Agent

A project has `.claude/agents/playtester.md`. It runs on Haiku with a short tool list (the
`mirai` MCP methods `play_start`, `play_stop`, `play_step`, `play_observe`, `capture`,
`play_qa_start`, `play_qa_report`, `play_explore`, and `Write`) and never reads code.

- Launch it with one goal that names what it needs, since it cannot look anything up: what to
  reach or do, the names of the entities to look for, when to stop, and a file to write a report
  to if you want one. "Reach the entity named Door and press Play from the main menu first."
- Its loop: `play_start`, then `play_qa_start` (with `fall_below` under the lowest floor), then
  `play_observe` once and `play_step` with `observe:true` for
  every action. It stops at the first bug (`stuck`, a problem, a violation, a wrong screen),
  calls `play_qa_report` with `repro:true` for each violation that matters, and answers in
  under 150 words with the repro paths.
- Pressing a button: one step puts `mouse_position` over the `rect` of the button from
  `ui.buttons`; the next holds `Left` in `mouse_buttons` for 2 ticks.
- Broad bug hunts: ask it to run `play_explore` in `World`, or in `Ui` for the menus
  ([explore-qa.md](explore-qa.md#explore)).
- When the goal needs judging the image, change `model: haiku` to `sonnet` in the file.

## Inspect

```bash
mirai rpc --project . play.observe '{"targets":["Door*"],"nearest":3}'
mirai rpc --project . play.step '{"ticks":20,"keys":["W"],"observe":true,"targets":["Door*"]}'
mirai rpc --project . play.get '{"entity": "Player","field":"world_position"}' --select value
mirai rpc --project . play.check '{"conditions":[{"entity":"Door","compare":"Gone"}]}' \
  --select passed
```

- `play.observe` answers the tick, the focused player (`position`, `velocity`, `grounded`,
  `facing`), `stuck`, new `problems`, the top screen with its `buttons` (`name`, `text`, `rect`
  in the window points `play.step` takes, `disabled`) and the `targets` nearest to the eye.
- A target has `distance` in meters, `bearing` in degrees right of where the camera looks
  (negative: left) and `elevation`; turn with `mouse_delta` by that much, then step forward.
  `targets` match component or entity names; `*` stands for any run of characters.
- `play.step` with `observe:true` is act plus observe in one call: use only it in a loop.
- Cost grows down the list: `play.check` (yes or no), `play.get` (one value), `play.observe`,
  `play.inspect` (whole entities), an image. Take the cheapest that answers.
- `--select a,b.c,d[0]` keeps only those fields of any answer.

## Images

```bash
mirai rpc --project . capture '{"path":"C:/work/now.png"}' --select path,width,height
mirai rpc --project . capture \
  '{"path":"C:/work/walk.png","every":10,"count":9,"follow":"Player",
    "segments":[{"ticks":80,"keys":["W"]}]}'
```

- With `path` the answer is only where the file is: open it when the numbers do not decide.
  Without it MCP also returns the image, which costs tokens.
- A filmstrip steps the game as `play.step` does and puts `count` cells `every` ticks apart in
  one image, the first before any tick; `segments` must not run longer than `every` times
  `count` less one ticks. `follow` centers each cell on an entity by name, id or handle.
- `play.observe` with `path` writes a small image beside its answer.
- Captures show the game alone with its own interfaces; a menu that is open is in the image.

## Pitfalls that fail silently

- A goal with no entity names makes the agent wander: name what to reach.
- Without `play_qa_start`, a violation the agent finds is not reported.
- A step with no `observe:true` answers the bare state: the agent then needs a second call.
- Time stands still between calls: a wait the agent wants is a `play_step` with `until`.
