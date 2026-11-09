# How this game is made

This is a Mirai game project.

## Documentation

- The engine serves the documentation: the MCP tool `docs`, or `mirai docs` in a shell.
- Call it before writing game code, and read only the section the task needs.
- Start from the code already here: `game/game.odin` and `assets/scenes/main.scene` play as they
  are; `game/shell.odin` is the main menu, pause and graphics settings, and
  `tests/scenarios/shell.mirai` drives them. Extend them instead of studying the engine.
- Engine sources are not the documentation. Do not read them to learn the API.

## Verify

- Write a scenario in `tests/scenarios/<name>.mirai` and run it in one call with
  `mirai play test . <name>`, instead of stepping and inspecting by hand.
- While looking at state, read only what you need with `play.get` and `--select`.
- Give `capture` a `path`: it answers only where the image is.

## Commands

Run them from the project folder. Never talk to an editor without `--project`.

- `mirai rpc --project . <method> key=value... --select <fields>` calls a method; the first call
  opens a headless editor and `mirai session stop .` closes it.
- `mirai rpc --project . describe <method>` gives the params of a method; `component.list` with
  `name=<component>` the fields and defaults of a component.
- `mirai play .` plays the game; `mirai play test .` plays every scenario.
- `mirai check` checks the types of the code of the project, from any folder inside it;
  `mirai check game` and `mirai test game` take a package relative to the folder you are in.
- `mirai build game .` builds the game fast; add `--release` for the build you ship.
- `mirai build editor .` builds the library of the editor.
