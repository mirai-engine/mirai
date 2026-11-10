# How this game is made

This is a Mirai game project.

## Documentation

- The engine serves the documentation: the MCP tool `docs`, or `mirai docs` in a shell. It lists
  the topics and their sub-pages, each with what it holds.
- Read what the step at hand needs, with `section` for part of a topic (`mirai docs core prefabs`);
  do not sweep it in advance.
- Start from the code already here: it runs as it is and `README.md` says what each file is.
  Extend it instead of studying the engine.
- A scene (a prefab is one with a single root) and a `.ui` are files of `assets/`, the source of
  the game: change them with
  `scene.write`, `scene.add`, `scene.set` and `scene.save` (or `ui.write`) or in the editor. Only
  generated assets (`tools/content`) come from code, and nothing writes over what the API saved.
- Engine sources are not the documentation. Do not read them to learn the API.

## Verify

- Write a scenario in `tests/scenarios/<name>.mirai` and run it in one call with
  `mirai play test . <name>`, instead of stepping and inspecting by hand.
- A route or a chase is a scenario with the drive step of `play.step` (it steers the player to a
  point), never a bot script around `mirai rpc`.
- Few turns: every turn pays for the whole context. Plan the change, make it in one edit, run
  `mirai rpc --batch` for several calls, and verify once.
- While looking at state, read only what you need with `play.get` and `--select`.
- Give `capture` a `path`: it answers only where the image is.

## Commands

Run them from the project folder. Never talk to an editor without `--project`. On Windows, from
bash it is `mirai`; from PowerShell `mirai.cmd`; from Python `subprocess` the absolute path of
`mirai.cmd` at the engine root (a relative `./mirai.cmd` fails in `cmd`).

- `mirai rpc --project . <method> key=value... --select <fields>` calls a method; the first call
  opens a headless editor and `mirai session stop .` closes it.
- `mirai rpc --project . describe <method>` gives the params of a method; `component.list` with
  `name=<component>` the fields and defaults of a component.
- `mirai play .` plays the game; `mirai play test .` plays every scenario.
- `mirai check` checks the types of the code of the project, from any folder inside it;
  `mirai check game` and `mirai test game` take a package relative to the folder you are in.
- `mirai build game .` builds the game fast; add `--release` for the build you ship.
- `mirai build editor .` builds the library of the editor.
