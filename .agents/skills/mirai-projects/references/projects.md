# Projects, plugins and build

Build targets, jobs, fingerprint, shaders, cooking, and shipping (`cook/build`): [build](build.md).

## Layout

```text
<project>/
  project.mirai       project manifest (required)
  settings.mirai      project/machine settings overrides (optional)
  cook.mirai          extra cooking roots (optional)
  packages.mirai      pinned store package manifests + folders (optional)
  packages/           <package id>.mirai texts pinned by packages.mirai
  assets/             authored assets, art sources, import documents
  game/               runtime game library
  editor/             engine-time editor package
  plugins/<name>/     plugin.mirai, runtime/, editor/, shaders/, assets/
  shaders/            custom Slang programs
  panels/             chat-built editor panels (engine-time)
  tests/scenarios/    mirai play test scenarios (optional)
  .mirai/             generated (git-ignored): gen/, plugins/, editor<ext>, play<ext>,
                      *-live-<pid>-*, game/, shaders/, build/, cache/, share/, thumbs/,
                      tmp/ (scratch)
```

First-party plugins live in `<engine>/plugins/<name>/`; engine binaries in
`<engine>/.mirai/engine/<dev|release>/`; the shaders GPU tests load in
`<engine>/.mirai/test-shaders/<package>`. Constants: `project/project.odin`.

### Scratch

`<folder>/.mirai/tmp` of a project or the engine is scratch (`tools/mirai/scratch.odin`). What a
command makes there for its own run it removes when it ends: a session copy at `session stop`, the
scenes `render check` edits (`render-<pid>`) when its editor closes, a package take's project and
a join's temporary files. `scratch_sweep` removes what outlives its command or a killed one: `mirai
test` runs it for the engine, `session start --copy`, `session stop --orphans`, `play audit --copy`
and `bench flight` for their project. A session copy goes once no start holds it and no editor of
it runs; any other entry once no lock keeps it (a held `.lock` at its top or in its `.mirai/`, or
`<name>.lock` beside a file) and nothing in it changed for `SCRATCH_AGE` (three days). Results
meant to stay go to `bin/` or a folder of the project; what must outlive three days unchanged
while in use holds a lock in its entry.

## Manifests

`project.Manifest` and `project.Plugin_Manifest` (`project/manifest.odin`) serialize via
`std/serial` JSON schema (enums by name, `bit_set` as string list, missing fields use defaults,
unknown fields error).

- **Project fields:** `version`/`identifier` (`SDL_SetAppMetadata`), `icon` (shipped PNG),
  `thumbnail` (project list PNG), `start_scene`, `plugins`, `sources` (git-pinned plugins at full
  commit; `catalog` tracks catalog commit; managed by `mirai plugin`), `window`, `build`
  (`optimization`/`debug` for `editor`/`play`; shipped game always `-o:speed`; `compression` empty
  = MDC2 or `"none"`). `section=` tags drive settings dialog (`plugins`/`sources` are `hidden`).
- **Plugin fields:** `dependencies`, `test_dependencies` (test-only imports, never auto-active),
  `parts`, `development` (omitted from `shipped_world`; reaching it fails `Engine_Time_Code`),
  `automatic` (auto-activates when all dependencies are active; forbidden in `project.mirai`),
  `icon` (<=128 px PNG), `import_sources` (LFS extensions), `asset_kinds` (writes tracked
  `kinds_gen.odin` with `<STEM>_KIND`/`_EXTENSION`/`_VERSION`; `program_uses` declares material
  shader uses).
- **Errors & merge:** `project.Error` carries `Error_Code`, `plugin`, `subject`, and `.Text`
  `line`/`column`/`detail`; `error_text` formats for CLI/editor. `manifest_merge` applies partial
  JSON (`project.set`).

```json
{
  "name": "MyGame",
  "version": "0.1.0",
  "start_scene": "main.scene",
  "plugins": ["physics", "multiplayer"],
  "window": {"title": "My Game", "mode": "Windowed", "width": 1280, "height": 720},
  "build": {"optimization": "Speed", "debug": false, "defines": [], "compression": ""}
}
```

```json
{
  "name": "my_plugin",
  "version": "0.1.0",
  "dependencies": ["physics"],
  "parts": ["Runtime", "Editor"]
}
```

## Project settings

`@(storage,setting)` stores project settings; `@(storage,setting="machine")` stores machine
preferences. Layered bottom to top (`SETTINGS_FROM_TOP`: `.Player`, `.Project`, `.Engine`):

1. Code defaults (`NAME_DEFAULT` or GPU `name_for_device` -> `Setting.base`).
2. `machine_folder(engine_root)/settings.mirai` (`shared_root` `.mirai`, shared across worktrees;
   machine settings only — project sections there warn via `settings_misplaced`).
3. `<project>/settings.mirai` (any setting).
4. Player `<user data>/Mirai/<project>/settings.mirai` (`.Player`, machine settings + bindings via
   `host.app_options_save`).

- Files store only diffs against lower layers; `keyed` struct arrays layer by first text field.
  Unknown fields are ignored on read; inactive-plugin sections are preserved on write.
  `MIRAI_NO_MACHINE_SETTINGS` skips `.Engine` layer. Writes go through a synced temporary file
  renamed into place: a crash leaves the old file or the new one, whole.
- **Only a person writes the machine's files.** An editor with a window (`editor.machine_kept`)
  writes the `.Engine` layer, `projects.mirai`, `editor.mirai` and the AI agents; a game in its
  own window that no `--frames`/`--input`/`--capture` drives (`App.options_kept`) writes the
  `.Player` layer. Every other run (headless editors, so every `mirai session` with or without
  `--copy`, scripted players, tests) reads them and keeps its changes in memory until it ends:
  the engine layer as the text its file would have (`settings_text_of`, `settings_load`
  `machine`). `editor.show` hands a session to a person and drops that text.
- Shipped games merge `.Engine` machine sections + `.Project` (`settings_merge`); malformed JSON
  fails with `Settings_Invalid`.
- **API (`project`):** `Setting`, `Settings_Layer`, `shared_root`, `machine_folder`,
  `settings_file`, `settings_under`, `settings_held`, `settings_load`, `settings_save`,
  `settings_merge`, `settings_misplaced`, `settings_parse`/`read`/`default`/`clone`/`text`/
  `write`, `Rest` (debounced writer). Editor UI: File > Project settings; API: `settings.get` /
  `settings.set`.
- **Built-in settings:** `Graphics_Settings` (machine), `Display_Settings` (machine),
  `Audio_Output` (machine), `Input_Settings` (machine, keyed), `Particle_Settings`,
  `Physics_Settings`, `Net_Settings` (`Shared`), `Spawn_Settings`.

```odin
import "mirai:project"

p, err := project.open(".", project.engine_root_find("."))
if err.code != .None {return}
defer project.close(&p)

layers := project.settings_layers_of_process()
_ = project.settings_load(settings, p.root, p.engine_root, layers)
_ = project.settings_save(settings, .Project, p.root, p.engine_root)
```

## The `project` package

`open(root, engine_root)` reads `project.mirai`, validates all plugins in `<root>/plugins/` and
`<engine_root>/plugins/` (even inactive ones; missing/undeclared part folders error), and
topologically orders `active` plugins (dependencies first; inactive cycles ignored).

- Deleting `.mirai/cache` (`cache_path`) or `.mirai/thumbs` costs only rebuild time. Caches key on
  format/version and self-heal on mismatch: **a cache never makes a valid asset fail**.
- `shader_generation(root)` / `shader_generation_find(root)` locate published or shipped shaders;
  `user_folder(root)` resolves per-user saves/options/pipeline cache.

## Which packages go in

Generator scans `core`, `engine/**`, active plugin `runtime/`, and `game/` for game+editor;
`editor/`, active plugin `editor/`, and project `editor/` for editor only. Collections:
`project:game`, `project:editor`, `project:plugins/<n>/<part>`, `plugins:<n>/<part>`, `generated`
(`.mirai/gen`), plus `-custom-attribute:`.

- Folders need at least one non-`_test.odin` file (skipping `.*` and `testdata`); plugin folders
  must be declared in `parts`.
- Shipped `game` maps `mirai`/`plugins` to sources; library builds map them to `decl/` and plugin
  decls. Runtime packages never import `editor/` ([exclusion](build.md#exclusion-guarantee)).

## Plugin libraries

`cook/build/plugins.odin`. Every active plugin part (`runtime`, `editor`), plus project `game/` and
`editor/`, compiles into its own shared library per optimization (`minimal` in dev, manifest's
otherwise); the project library holds only the generated world.

- **Naming & staging:** Published to `project.PLUGIN_LIBRARIES` as
  `plugin|project-<name>-<part>-<opt>-<fingerprint>` (old copies delete once unloaded). Under
  `plugins/<opt>/`: `decl/`, `decl-project/`, `stage-<id>/` (`staged` collection), `<id>.stamp`.
- **Declarations:** `#force_inline`, generic, and `where` procs copy bodies; others are foreign
  exports. Private procs export only when referenced (`@(private="file")` exports as
  `mirai.<pkg>.<file>.<name>`).
- **Currency & parallel build:** Fingerprints hash sources, imported plugin decls, referenced
  [engine declarations](#engine-binaries), compiler, and flags. Windows builds import libs upfront
  via `lld-link` so all libraries compile in parallel; macOS/Linux compile in dependency order up
  to `compilers_at_once()` (`MIRAI_COMPILERS`).
- **Shared cache:** `<main>/.mirai/cache/plugins/` (`PLUGIN_CACHE_ENTRIES` LRU) shares engine
  plugin libs across projects/worktrees when `build.debug` is false. Each library isolates Odin's
  per-thread cleaner array (`-unexported_symbol` on macOS, `-Bsymbolic` on Linux; Windows uses
  `SetDllDirectoryW`).

## Engine binaries

`build.engine_build({engine_root, mode, defines, force})` generates engine shaders (`.Shaders` on
failure) and compiles into `<engine>/.mirai/engine/<mode>/`.

- **Defines:** Project defines read by engine `#config` (`engine_defines`) isolate binaries in
  `<mode>-<hash>/`. Installed engines refuse them; mismatching a running editor fails
  `Engine_Defines`.
- **Layers & units:** `ENGINE_PACKAGES` (`cook/build/engine.odin`) orders packages bottom-up across
  `Base`, `Engine`, `Cook`, `Editor`. Release compiles 1 library/layer; dev compiles 1 library/unit
  (fast body-only rebuilds). Release carries debug info; dev omits it (`MIRAI_ODIN_FLAGS=-debug`).
- **Boundary:** Each library has its own Odin runtime/type table (no cross-library `typeid` lookup;
  no shared globals). `build.declare` exports `mirai.<pkg>.<name>`, copying generic/`inline`/
  `where`/`defer`/`deferred_*`/any-taking procs into `decl/`, and indexes transitive hashes in
  `engine.declared` (`cook/build/declared.odin`).
- **Programs:** `mirai-editor`, `mirai-player`, `mirai-import` (`import`/`share`/`join`), and
  `mirai-author` (`ui`/`scene`) keep `mirai` CLI free of renderer/importers.
- **Mode & cache:** Dev (`-o:minimal`) by default; `--release` (`-o:speed`) when requested
  (`package engine` always `--release`). `build.engine_current` checks without locking. Shared
  cache: `<main>/.mirai/cache/engine-libraries/` (`ENGINE_CACHE_ENTRIES`). SDL3 flags combine into a
  single `-extra-linker-flags`.
- **In-place hot-swap (dev only):** Exports dispatch through `Declare_Desc.slots`
  (`host.engine_library_swap`). `mirai build editor` pushes rebuilt libraries + shaders to the
  open session (`build.start` `built`); `build.engine_swap` restarts the editor if decls/layouts,
  compiler/flags, or `pinned` (C lib/globals/`@(thread_local)`) libraries changed.
- **LLVM workaround (odin-lang/Odin#7937):** Avoid multi-assignment/swaps of >64-byte values under
  `-o:speed` (use single stores + `slice.ptr_swap_non_overlapping`; caught by `mirai test
  cook/build`, see [ODIN_WORKAROUNDS.md](../../../../docs/ODIN_WORKAROUNDS.md)).

## Installed engine

Assembled by `mirai package engine --out <folder>` (CI `.github/workflows/release.yml` on tag
`v<ENGINE_VERSION>`), marked by `engine.mirai` (`project.ENGINE_FILE`). Compiles projects, never
itself.

- **Root lookup (`project.engine_root_find`):** `--engine`, `MIRAI_ROOT`, or nearest ancestor with
  `engine.mirai` (or `AGENTS.md` + `tools/mirai`). CLI propagates `MIRAI_ROOT`.
- **Contents:** `engine.mirai`, `bin/mirai`, `.mirai/engine/release/` (with `decl/`, stamps),
  `.mirai/cache/plugins/` (`minimal` + `speed`), `.deps/` (Odin, Slang, SPIR-V tools, SDL3),
  `builds/` (Final plugin package store), non-test engine/plugin sources (for generator + shipped
  `build game`), `shaders/`, `templates/`, fonts, `.agents/skills/`, `THIRD_PARTY_NOTICES.md`.
- **Behavior:** `engine_build` verifies presence only (`Engine_Incomplete` if missing); dev projects
  link `-o:minimal` against `--release` engine binaries. `build tools`, `worktree`, `package`,
  `bench`, `render`, and bare `shaders` require a checkout. Compiler fingerprints by size +
  `engine.mirai`. Needs system C/C++ linker (`mirai doctor`); unsigned on macOS (remove quarantine);
  keep Windows install path short (<260 chars).

## Commands

Run `mirai <command>` for usage. Area CLIs:
[shaders](../../mirai-rendering/references/shaders.md#shader-toolchain),
[assets](../../mirai-assets/references/cli.md),
[imports](../../mirai-imports/references/imports.md#what-is-written),
[images](../../mirai-agent-api/references/image.md),
[`render check`](../../mirai-rendering/references/verification.md#render-check),
[`bench compare`](../../mirai-agent-api/references/methods.md#profiling),
[`texts`](../../mirai-assets/references/kinds.md#texts), and
[sessions/`rpc`/`mcp`/`capture`](../../mirai-agent-api/references/api.md#sessions). Diagnostics
print `file(line:column) Error: message`; exit 1 on failure.

## Common commands

Omit `[project]` for cwd (`demo` for demo). Use `./mirai` in bash; absolute `mirai.cmd` in
PowerShell/cmd/Python. Builds default to dev (`--release` only when requested/needed).

| Operation | Command |
| --- | --- |
| New worktree | `mirai worktree new <name> [--from <branch>]` |
| Edit / Play | `mirai edit\|play [project] [--release] [--store dir] [args]` |
| Build targets | `mirai build editor\|game\|server\|engine [project] [--release] [--out dir] [--store dir] [--force]` |
| Generate / Content | `mirai generate [project] [--store dir]` / `mirai content [project] [-- args]` |
| Import / Refresh | `mirai import <file> [--project P] [--folder F]` / `mirai import --refresh <root> [--final]` |
| Share / Join | `mirai share [project] [--port N] [--store S]` / `mirai join <invite> [dir] [--address A]` |
| Docs without editor | `mirai ui\|scene read\|write\|check ... [--project P]`, `mirai records create\|read\|write\|check ...` |
| Git plugins | `mirai plugin add\|update\|remove\|sync\|list\|catalog\|check ...` |
| Typecheck + lints | `mirai check [<pkg> [-flag...]]` (alloc lint `tools/mirai/alloc_lint.odin`; solver/render lint `tools/mirai/solver_lint.odin`) |
| Run tests | `mirai test [<pkg>] [test\|file.odin...] [--list\|--failed\|--no-gpu\|--quiet] [-flag...]` |
| Editor session | `mirai session start\|restart\|stop\|status [project] [--release] [--copy] [--store dir]` |
| RPC / Capture | `mirai rpc <method> [k=v\|json] [--select c] [--wait-until c=v]` / `mirai capture [P] --out x.png [--camera N] [--reference r.png]` |
| Perf / Images | `mirai render check` / `mirai bench compare --base main` / `mirai bench flight\|pipelines` / `mirai image ...` |
| Locks / Measure | `mirai measure -- <cmd>` / `mirai locks` / `mirai doctor [project]` / `mirai setup git\|path\|rg` / `mirai package engine --out dir` |

```sh
./mirai session start demo
./mirai rpc scene.inspect --select entity
./mirai capture demo --out bin/view.png --camera Main
./mirai session stop demo
./mirai check core && ./mirai test core --no-gpu
```

- Do not pass `-thread-count` (shared turns handle concurrency;
  [turns](build.md#turns-between-processes)).
- Handing commands to the user: pre-build first so it prints "unchanged"; separate `cd` with `;`
  for PowerShell 5.1. Remove worktrees with `git worktree remove`, other folders with `rm -rf`.

## Project

- `mirai new [dir]` copies `templates/<T>` (`empty` default) + `templates/common`, writes
  `.gitattributes`, and runs `git init` if needed (`--list` lists templates).
- `mirai docs [topic] [section]` (and MCP `docs`) serves `docs/game` from the engine root;
  `mirai docs --search <word>...` (MCP `docs` with `search`) gives the sections that say them.
- `mirai worktree new` creates `<main>/.worktrees/<name>` sharing `.deps` and caches.
- `mirai doctor [project]` validates machine/project (exit 1 on error; requires `core.symlinks` and
  `.claude/skills` -> `.agents/skills`).

## Sharing a project

`cook/share` transfers projects peer-to-peer over `net` and
[exchange](../../mirai-store/references/exchange.md).

- **Snapshot:** Content-chunked store tree of `project.own_path` files (excludes `.mirai`, VCS, and
  sources of pinned packages whose build the host has whole). Preserves bytes + executable bit
  only; skips symlinks/special files with a notice. `.mirai/share` caches settled file hashes.
- **Share (`mirai share`):** Maps port, prints invite, serves ref `shares/<hash(secret)>` plus
  snapshots, manifests, Final/Fast builds, and `cook/cache` (never raw origins/sources) under a
  lease.
- **Join (`mirai join`):** Fetches offer only from host, validates tree paths/bounds/case-folding
  (APFS/NTFS in-place case renames) and disk space, downloads manifest + start scene first into
  atomic temp files, builds editor for plugin importers, and batch-refreshes packages from peers
  before falling back to local import (release builds still require Final). Re-joins do 3-way merge
  against `.mirai/share` base (preserving local edits), never follow symlinks/junctions, serve
  while downloading, and exit `3` if any file failed (retry completes remaining).

```sh
./mirai share demo
./mirai join <invitation-code> ./demo-copy
```

## Tool and machine

- `mirai setup git [dir]` installs asset git drivers; `mirai setup path` prepends `bin/` to `PATH`;
  `mirai setup rg` installs pinned ripgrep in `.deps`.
- **Launcher:** `mirai` (sh / Git Bash) builds `bin/mirai` only if missing `bin/mirai` or
  `bin/mirai[.exe].sources.json` (Odin from `MIRAI_ODIN`, `.deps`, or `PATH`), replacing
  atomically. `mirai.cmd` invokes Git for Windows `bash.exe` (avoiding WSL).
- **Self-refresh & FreeType:** Tool checks non-test sources on start and rebuilds itself with
  `-ignore-unknown-attributes`. Builds/tests build or fetch FreeType from shared cache.

## Checks and tests

`mirai check` and `mirai test` inject Mirai collections (`mirai`, `plugins`, `project`) and
attributes, generating engine shaders first (`check` sets `-define:MIRAI_TEST_SHADERS=true`).

- **Runner (`cook/build/tests.odin`):** Engine packages compile into `bin/tests/`; project packages
  compile via `Test` job into `<project>/.mirai/build/tests/` against editor libraries (seeing only
  public engine `decl/`). All test binaries run with cwd = engine root and 8 MB stack
  (`TEST_STACK_FLAG`), cached by [fingerprint](build.md#fingerprint) (including `_test.odin`).
- **Selection & flags:** Validates `@(test)` names and `.odin` files before compiling (exit 2 on
  unknown); passes `-tests:` without recompiling. `--no-gpu` skips files touching
  `rhi/shared_device` or `rhi.device_create`; `--list` previews; `--failed` re-runs failures;
  `--timeout` (`TEST_TIMEOUT`, via `ODIN_TEST_LOG_STATE_CHANGES`) kills hung runs. Runs at
  `-o:minimal`, low priority during measurements.
- **CPU suites & CI:** `.github/workflows/checks.yml` runs on PRs to `main` (Windows,
  `MIRAI_ALLOW_GPU_SKIP=1`), executing `mirai check` on all non-`third_party`/`templates` packages
  and listed CPU `mirai test` suites (`core`, `cook/build`, `engine/*`, `std/*`, `plugins/*`,
  `audio`, `host`, `editor/api`).

## Paths in Git Bash

Leading `/` converts to Windows paths (prefix `MSYS_NO_PATHCONV=1` for POSIX args). JSON in
`mirai rpc` is unconverted; `project.path_native` translates `/c/x` and `/cygdrive/c/x` and rejects
drive-less roots (`/x`, `\x`).

## External scripts

`scripts/*.py` are standalone PEP 723 scripts run via `uv run scripts/<script>.py` (no `.venv`, no
engine dependency). Wrap timed scripts with `mirai measure -- uv run scripts/<script>.py`.

- `scripts/check_docs.py` (tested by `scripts/tests/test_check_docs.py`): validates doc links,
  anchors, frontmatter, 100-char width, headings, tracked source names, Verification test names,
  `README.md` skill table, and `CLAUDE.md` `@AGENTS.md`.
- `scripts/bench_compare.py`: custom benchmarks (`mirai bench compare`/`flight` handle standard).
- `scripts/video_frames.py` (Windows): extracts reference strips/audio into
  `.mirai/tmp/video_frames` ([scratch](#scratch)).

## ACP agents

`mirai agent` installs Codex/Claude ACP adapters into `<user data>/Mirai/Editor agents/<agent>/`
(`project.agents_folder` or `--home`) only on explicit user action (public npm registry; Bun ->
Node -> pnpm `--silent`; `--claude-code` runs Anthropic installer). Atomic swap via temp dir;
`--cancel-file` aborts safely; `installation.json` records `codex_binary` (`CODEX_PATH`).

## Templates

See [demo and templates](../../mirai-gameplay/references/demo.md#templates).

## Known limits

- Plugin assets reload in an open editor only on `assets_scan` (watcher monitors project dir).
- First plugin-library build is slower than a single library; plugin libs are untested on Linux.
- Build/cook/shader limits: [build](build.md#known-limits).
