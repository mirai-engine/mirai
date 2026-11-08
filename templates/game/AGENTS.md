# How this game is made

This is a Mirai game project.

## Documentation

- The engine serves the documentation: the MCP tool `docs`, or `mirai docs` in a shell.
- Without arguments it lists the topics; `topic` reads one and `section` only a part of it.
- Call it before writing game code, and read only the section the task needs.
- Start from the code already here: `game/game.odin` and `assets/scenes/main.scene` play as they
  are; `game/shell.odin` is the main menu, pause and graphics settings, and
  `tests/scenarios/shell.mirai` drives them. Extend them instead of studying the engine.
- Engine sources are not the documentation. Do not read them to learn the API.

## Work in few turns

- Write whole modules in one go. Do not reread what you just wrote.
- Send independent reads and searches together, in one message.
- Batch Odin changes and build once per batch: a shipped build is slower than a play build.

## Verify

- Write a scenario in `tests/scenarios/<name>.mirai` and run it in one call with
  `mirai play test . <name>`, instead of stepping and inspecting by hand.
- While looking at state, read only what you need with `play.get` and `--select`.
- Give `play.capture` a `path`: it answers only where the image is. Open only what you need.

## Commands

Run them from the project folder. Never talk to an editor without `--project`.

- `mirai session start .` opens the headless editor; `mirai session stop .` closes it.
- `mirai rpc --project . <method> '<json>' --select <fields>` calls a method of that editor.
- `mirai rpc --project . describe <method>` gives the params of a method.
- `mirai play .` plays the game; `mirai play test .` plays every scenario.
- `mirai check <absolute path of game>` checks the types of the code.
- `mirai build game .` builds the game fast; add `--release` for the build you ship.
- `mirai build editor .` builds the library of the editor.
