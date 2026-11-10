---
name: ship
description: Build, play, capture and ship a Mirai game - mirai play, build game, build server,
  package, headless runs, --capture, --input scripts, window, display and graphics settings.
---

# Game ship

Run every command from the project folder. `mirai doctor .` checks the machine and the project and
says how to fix each finding.

## Map

- Which command, and which is fast: [Commands](#commands).
- Run the game headless, take a picture, press keys and click: [player.md](ship/player.md).
- Graphics quality, window mode and size, which display, where each setting is stored:
  [settings.md](ship/settings.md).
- A gameplay test that runs in CI: `mirai play test .` ([testing](testing.md)).
- Servers, `--server` and `--connect`: [networking](networking.md).
- An asset missing from the built game: [assets](assets.md).

## Commands

| Command | What it is for |
| --- | --- |
| `mirai check` | types of the Odin code only: the fastest answer |
| `mirai generate .` | the generator's errors (attributes, parameters, order), no build |
| `mirai play .` | compile the project, run it from its folder: iterate with this |
| `mirai play test . [name]` | run `tests/scenarios` in a headless editor, exit 1 on a failure |
| `mirai edit .` | the editor, to author scenes and use Play |
| `mirai build editor .` | the editor's library without opening it |
| `mirai build game . [--out dir]` | the game, fast and incremental: see below |
| `mirai build game . --release [--out dir]` | the game you ship: slow |
| `mirai build server . [--out dir]` | a dedicated server folder, run with `--dedicated` |
| `mirai package engine --out dir` | assembles the engine itself as an installed engine |

- Every command builds `--dev` (`-o:minimal`) unless `--release` is given, which compiles the
  project at the `build.optimization` of `project.mirai`. `package engine` is always `--release`.
- `play` compiles the project and reads assets and shaders from the project: nothing is cooked,
  so it starts fast.
- `build game` generates the shaders, cooks the assets that every scene and `cook.mirai`
  reach and writes `.mirai/game` (or `--out`): the executable, `project.mirai`, `input.mirai`,
  `settings.mirai`, `assets/` and `shaders/`. It alone shows what the built game lacks.
- `mirai build game` without `--release` is the fast incremental path: the engine and its
  plugins come from a cached library, `mirai-shipped.dll` next to the executable
  (`libmirai-shipped.so` or `.dylib` elsewhere), and only the game compiles. What crosses into
  that library does not inline, so it is about a tenth slower in CPU.
- `build server` is the same executable without what is only seen or heard; run it with
  `--dedicated` (no window, renderer or local players).
- `package` belongs to the engine's own checkout and release; a game never runs it. A game is
  shipped by `build game --release`, whose folder runs on its own (SDL3 included where the system
  lacks it).
- An open editor session loads code changes with `build.start` and plays with `play.start`: the
  fastest loop while you author.

## Pitfalls that fail silently

- An asset only code names works in `mirai play` and is missing from `build game` unless it is
  a [root](assets.md#reference). Build before delivering.
- `source/` (art sources) never ships, and a game package that imports an editor package fails the
  build with `Engine_Time_Code`.
- The shipped game on Windows is a console program.
