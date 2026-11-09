# How this game is made

This is a Mirai game project.

## Documentation

- The engine serves the documentation: the MCP tool `docs`, or `mirai docs` in a shell. It lists
  the topics and their sub-pages, each with what it holds.
- Read what the step at hand needs, with `section` for part of a topic (`mirai docs core prefabs`);
  do not sweep it in advance.
- Start from the code already here: `game/game.odin` and `plugins/sample/` are small and run as
  they are. Extend them instead of studying the engine.
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
