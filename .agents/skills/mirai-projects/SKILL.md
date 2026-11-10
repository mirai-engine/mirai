---
name: mirai-projects
description: Mirai projects and plugins - `project` (manifests, plugin discovery and order, layout),
  `cook/build` (generated world, engine binaries, libraries and shipped game, project shaders,
  fingerprint, cooking and engine-time exclusion), `cook/workspace` (worktrees, dependencies, shared
  cache and locks), the installed engine (`mirai package engine`, binary package and release
  workflow), the `tools/mirai` commands, the external scripts and the `templates`. Use when changing
  a manifest, the layout or how a project or the engine is generated, compiled or distributed, when
  investigating why something does not compile or what went into the game, or when taking reference
  frames or sound from a YouTube or X video.
---

# Mirai projects and build

## Map

- Folders of a project: [layout](references/projects.md#layout).
- `project.mirai` and `plugin.mirai`: [manifests](references/projects.md#manifests);
  `settings.mirai`: [settings](references/projects.md#project-settings).
- Plugin discovery and order: [package](references/projects.md#the-project-package); which folders
  go into each binary: [packages](references/projects.md#which-packages-go-in).
- Targets, flags, jobs, outputs and [fingerprint](references/build.md#fingerprint) of `cook/build`:
  [targets](references/build.md#targets), [flags](references/build.md#flags-and-environment),
  [jobs](references/build.md#jobs) and [outputs](references/build.md#outputs); own shaders:
  [project shaders](references/build.md#project-shaders).
- Shipping and cooking: [shipped game](references/build.md#shipped-game),
  [dedicated server](references/build.md#dedicated-server) and
  [cooking](references/build.md#asset-cooking).
- `--dev`/`--release` modes, per-part currency and the shared engine cache:
  [engine binaries](references/projects.md#engine-binaries) and
  [plugin libraries](references/projects.md#plugin-libraries).
- Engine shipped as a binary, `engine.mirai`, `mirai package engine`, engine root and release
  workflow: [installed engine](references/projects.md#installed-engine).
- CI of the pull requests to `main` (`checks.yml`):
  [checks and tests](references/projects.md#checks-and-tests).
- Dependencies, `.deps` and the cache between worktrees, `cook/workspace`:
  [dependencies and worktrees](references/build.md#dependencies-and-worktrees).
- Turns between processes, build and measurement locks and implicit Vulkan layers:
  [turns](references/build.md#turns-between-processes) and
  [layers](references/build.md#implicit-vulkan-layers).
- `mirai` launcher, `mirai worktree` and `mirai doctor`:
  [tool and machine](references/projects.md#tool-and-machine).
- `mirai` subcommands (their usage, with `mirai <command>` without arguments):
  [commands](references/projects.md#commands) and
  [common commands](references/projects.md#common-commands).
- Headless editor in the background, `rpc`, `mcp`, `capture`:
  [sessions](../mirai-agent-api/references/api.md#sessions); comparing captures:
  [images](../mirai-agent-api/references/image.md#comparing-images-mirai-image).
- `scripts/*.py`, and reference frames from a YouTube or X video:
  [external scripts](references/projects.md#external-scripts).
- Templates: [demo and templates](../mirai-gameplay/references/demo.md#templates); attributes that
  generate the world: [core](../mirai-core/SKILL.md); game code:
  [gameplay](../mirai-gameplay/SKILL.md); plugins: [plugins](../mirai-plugins/SKILL.md).

## Workflow

### Create and build a project

1. `mirai new` with the right template.
2. Arrange code and manifests according to the layout; to activate a plugin, follow
   [plugins](../mirai-plugins/SKILL.md).
3. `mirai generate` to diagnose attributes; `mirai edit` or `mirai play` to build and run.
4. To ship, `mirai build game` and review the cooking report, above all the roots that only code
   refers to (`cook.mirai`).

### Change `project` or `cook/build`

1. A new manifest field goes into the struct, with its default in `manifest_default` and its check
   in `manifest_validate` or `plugin_validate`.
2. A new engine package goes into `ENGINE_PACKAGES`, in the lowest
   [layer](references/projects.md#engine-binaries) that has what it imports and after the
   packages it imports, and, if it is engine-time, into `engine_time_packages`.
3. A change in what `declare` writes bumps `DECLARE_VERSION`.
4. Update [projects.md](references/projects.md) or [build.md](references/build.md) in the same task
   if an invariant or a workflow changes.

## Invariants

- `project` imports only `std/*`: the editor, the player and the tools use it.
- `tools/mirai` and everything it imports, counting its `_test.odin` files (the compiler reads them
  too), do not reach `render`, `host`, `platform`, `editor` or `engine/*`: the tool writes
  `render/shaders_gen.odin` and has to compile with those old tables to regenerate them. A value
  that `render` and `cook` share is declared in `render/abi`, which reads no generated table and
  the tool imports. It is guarded by `the_tool_imports_no_package_of_the_engine`.
- The generator reads syntax (`core:odin/parser`) and writes text. The generated packages are the
  only source of what goes into each binary: `gen/game` imports `host` and the libraries, nothing
  from the editor; `gen/editor` and `gen/play` only export `mirai_project_info`.
- A generic procedure, an `inline` one, one with `deferred_*` or one with an `any` in its
  signature is compiled in its caller: it is not exported. An `any` crossing into a library would
  carry a typeid its type table lacks (`%v` of a plugin's enum prints nothing).
- A private procedure is declared and exported only when the declarations of its package name it:
  what `declare` copies as text and what it looks for names in are the same set.
- What compiles against the engine declarations follows the declarations it names and what they
  reach, by the names in the text: a name that is hidden or inside a comment still counts, and a
  type reached through a pointer too. More is followed, never less.
- In dev the unit that is rebuilt is the package, and a library imports only packages listed
  before its own in `ENGINE_PACKAGES`; an optimized build never splits a layer.
- The project libraries and the engine ones share flags (`engine_flags`: `-custom-attribute` and
  the platform ones); their layouts depend on it.
- Every test executable, of `mirai test` and of `build.test`, is built and run by one runner
  (`cook/build/tests.odin`), is current by the content fingerprint of what its build read and
  runs in the engine root: a relative path in a test is relative to the engine.
- Only the shaders job (`Shaders_Job`, on its thread) writes to `project.shader_generation(root)`.
  `host` chooses what to load with `project.shader_generation_find`; do not duplicate that path.
- Manifests are flat structs read and written by their schema; an unknown field is a read error.
- Errors are codes with a position and a subject; the text for people is written by
  `project.error_text`, the only one the CLI and the editor use. A text error also carries
  `detail` (`serial.text_error_message`: where, what fails and the valid names).
- The engine-time exclusion is checked against what the compiler says it read
  (`-export-dependencies:json`), not against what was generated; `engine_time_packages` defines it.
- The compiler never writes over a published output: it writes with the job's prefix in
  `.mirai/build` and a successful build replaces it with a rename.
- A plugin library compiles only when the plugin libraries it links are published; their
  declarations are written before and do not wait.
- `job_start` does not wait for the compiler and copies to its arena what it needs from the
  project: the `Project` can be closed afterwards.
- Paths use `/` in everything that is stored, generated or compared.
- An installed engine (`engine.mirai`) does not build the engine or the CLI, and its shape is that
  of a checkout: what it reads from the engine root at run time has to be in the package
  (`PACKAGE_TRACKED` and `PACKAGE_GENERATED` of `tools/mirai/package.odin`).
- The fingerprint of a plugin library does not name the project: the libraries of an engine
  package serve any project with the same flags.
- CI runs only on pull requests to `main`: `checks.yml` runs on Windows without GPU, with `mirai
  check` of each folder with Odin sources and the CPU suites; it keeps no artifacts.
- The engine package carries its sources: the installed engine carries its binaries, `decl/` and
  the Odin sources of the engine and its plugins without the tests, and keeps the machine state
  inside its own folder, like a checkout.

## Verification

- `mirai test project` (manifests, order, paths), `mirai test cook/build` (cooking, shaders, copy,
  fingerprint, engine modes, `declare`, the IR without stores of aggregates of more than 64 bytes,
  and the test runner: currency of an executable and what it reads from the output of
  `core:testing`) and `mirai test tools/mirai` (ACP installer, C library cache, tests that declare
  the sources, known failures); `mirai check cook/build` and `mirai check
  tools/mirai` if they change. Turns: `mirai test cook/workspace` (annotation of builds, who holds a
  lock) and `mirai test std/subprocess` (low priority of a child).
- Generator or build: `mirai build editor` and `mirai build game --out <separate folder>` of the
  affected project, and the player with `--no-gpu --frames 3`.
- User commands, by hand: `mirai new`, and `mirai build game` twice (the second says "unchanged").
- Exclusion: the game of a project with plugins with `editor/` builds and fails with
  `Engine_Time_Code` if `game/` imports an editor package; the tests of the runtime packages,
  `the_tests_of_runtime_packages_import_no_engine_time_package` of `cook/build`.
- Cache: changing an engine source and opening the editor rebuilds; repeating without changes
  reuses both builds ([reload](../mirai-editor/references/editor.md#build-and-reload)).
- Fingerprint and shared cache: `mirai build engine --dev` twice (the second says "unchanged"
  without waiting for a turn), a change in the body of a procedure (rebuilds only the library of
  its package) and in a worktree from `mirai worktree new` (reports "copied from the shared
  cache").
- Environment: `mirai doctor` from a worktree without its own `.deps` finds Odin and the
  dependencies of the main checkout.
- Installed engine: `project/project_test.odin` (told by its manifest) and, in `cook/build`,
  `engine_test.odin` (builds nothing and says what it lacks), `compiler_test.odin` (the compiler
  counts by its manifest, not its date) and `plugins_test.odin` (a plugin library is the same in
  every project). If the package changes, by hand:
  `mirai package engine --out <short folder>`, compress it, decompress it into another folder and,
  with its `bin/mirai`, `new` of each template and `build editor --dev`, which does not compile
  plugin libraries; then `edit --dev` opens the editor. The workflow YAML is validated with
  `actionlint`.
- ACP installer in a temporary project: install, search, cancel and uninstall Codex, and
  `initialize` of the adapter with `CODEX_PATH` pointing at the binary, with Bun and with Bundled.
