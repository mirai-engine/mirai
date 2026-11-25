# Instructions for Mirai agents

From `references/` open only the sections the Map of the `SKILL.md` points to.
[The architecture](docs/ARCHITECTURE.md) is read when changing layers, packages or contracts between
areas. Tell apart requested design, implemented behavior and validation coverage. In a worktree its
own `AGENTS.md` applies, not the one of the checkout that contains it.

## Principles

- **Mirai engine.** Native 3D engine with editor, plugins and code/API/MCP workflow, without manual
  programming. Platforms: Windows, Linux, macOS ARM64 (no consoles/mobile).
- **All in Odin.** C libraries allowed; C++ consumed prebuilt only (**never write/compile C++**).
  Tools are `mirai` subcommands; external tools are
  [Python scripts with uv](.agents/skills/mirai-projects/references/projects.md#external-scripts).
- **One-way layers** ([map](docs/ARCHITECTURE.md#package-map)) via `mirai:`. *Engine-time* code
  (`editor/`, `cook/`, plugin/project `editor/`) is never imported from *runtime*.
- **No global state.** No mutable package-level variables; state lives in explicit contexts using
  the allocator they receive (enables world copies, multi-world, tests). Fixed values are constants
  (`NAME :: value`). Sole exception: `rhi/shared_device` (tests only).
- **Data and functions.** A game is a generated world (component tables and storages) and loop
  functions receiving only what they read/write; one writer per data, requests via queues. Entities
  are generational handles, never stored pointers. Plain copyable data; no classes, inheritance,
  virtual objects or per-entity Update.
- **Preallocated capacities.** Stable frames/ticks do not allocate. Loads, imports, cooking,
  snapshots and reloads are transactions that may allocate.
- **One implementation per algorithm.** No copies per OS, graphics API, runtime/editor or
  client/server. `rhi` targets Metal/Vulkan; window/input/audio use SDL3; OS splits use build tags
  with identical signatures. One Slang source generates SPIR-V, MSL and bindings (never hand-edit).
- **No legacy or backward compatibility.** Version formats/APIs and update all consumers in the same
  task. Deleted items leave no alias, flag or fallback. Decide defaults on merit.
- **Generic components and recipes.** Identity, transform and hierarchy are base; presets are
  recipes ([core](.agents/skills/mirai-core/SKILL.md)). Prefer generic components + data; type rules
  belong in attributes recorded by the generator, not external lists.
- **Simple public API** (`core`, `host`, `engine/*`, `std`, `ui`, `asset`). The engine holds no game
  rules. Callers declare intent and get actionable errors on invalid input. Plugins extend rendering
  via `engine/render`, never importing `render` or `rhi`.
- **Few concepts, simple surface.** Keep complexity inside the engine, never on the caller.
- **Physics & game networking** are first-party plugins (`physics`, `multiplayer`): fixed step,
  authoritative server, prediction/rollback, no bit-exact cross-arch lockstep. `net` stays in engine
  for editor collaboration.
- **UI.** Own Odin layout (`ui`); edit editor UI natively. Text:
  [typography](.agents/skills/mirai-ui/SKILL.md); editable text is US-keyboard ASCII (no IME, HTML,
  CSS or embedded browser). Editor UI animates only the caret, busy dot, AI composer drop on first
  message, and settings card scroll, with help text only on component headers and field hover; game
  UI allows animations.
- **No crashes on valid input.** Public functions validate inputs and return errors (including OOM);
  `#no_bounds_check` only after validation. Cover hostile inputs (random, NaN, OOB, low memory)
  under bounds checks, memory tracker and sanitizer.
- **Odin & comments.** Avoid [current workarounds](docs/ODIN_WORKAROUNDS.md). Comment only units,
  field meaning or non-obvious reasons; never narrate changes or requests.

## Scope and done

- **Root fixes for defects.** Fix the cause of a defect (including in-repo third-party code), never
  hide it with wrappers, suppressed warnings or special cases. If the root fix is large, report its
  size and ask, with the workaround and what it loses as the alternative.
- **Simplest form first for features.** Before a new feature or redesign of more than about 200
  non-test lines: read in git history why the current state exists and what the owner removed or
  decided on purpose; state what the owner needs to see or get; propose the simplest form that
  delivers it with its size and cost, and the fuller form with what it adds. A workaround is
  acceptable when the root form is disproportionate; say what it loses.
- **Defects found in flight.** Fix if blocking or in touched code; ask if large.
- **Dependency defects** (Odin, Slang, SDL): prepare minimal repro/PR/issue and a named temporary
  workaround (plus [Odin workarounds](docs/ODIN_WORKAROUNDS.md) entry for Odin). Confirm before
  publishing upstream.
- **Derived OSS code/data** (MIT, Apache, BSD, zlib, GPL, etc.): add entry to
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) in the same task and list under **Derived
  code** in the final report.
- **Data-first on ports.** When porting from an existing source game or assets, extract
  ground-truth values (physics/jump/turn constants, mocomps, material/light equations, rig weights)
  from the source before tuning by eye.
- **Live verification gate before user handoff.** Never hand a playable build or command to the user
  based on CPU tests alone; run a live check (`mirai play audit` / `play.audit` + real captures at
  `Medium` when visual, or `playtester` / `play.explore`).
- **Separate engine refactors from game ports.** Keep large engine/DoD refactors in dedicated
  threads/branches instead of mixing them into a game-port thread.
- **Done & scope.** Every requested point implemented and verified per
  [Verification](#verification); list anything unverified or approximate. Stop and ask if a missing
  piece is structural. Never write new pending-items files (`PLAN_*.md` is active work only).

## Less code, simpler and faster

- **One piece of data, one place, one writer.** Never copy state or deliver it twice.
- **Compute on change, not per frame/pixel.** Per-instance decisions run once on CPU when changed.
- **Simplifications remove non-test code** (`git diff --shortstat main...HEAD -- '*.odin'
  ':!*_test.odin'`, same for `*.slang`); if not, explain why.
- **Optional features live in plugins** so unused systems add zero core cost.
- **Performance.** For perf work or measurable per-frame/tick additions, measure once when done with
  `mirai bench compare --base main` in dev
  ([profiling](.agents/skills/mirai-agent-api/references/methods.md#profiling)). Non-perf changes
  need only `profile.capture`. Put the results table in the final report; raw output in `bin/`
  (never committed).

## Documentation and skills

- English only across docs, skills, identifiers, commits and messages. Lines <= 100 chars (except
  lone URLs and table rows); `SKILL.md` YAML frontmatter opens with `---` on line 1.
- `SKILL.md`: `name` = folder, trigger-rich `description`, then Map (task -> section), workflow,
  invariants and focal verification. Keep only what code/tests/`engine.describe`/git do not say:
  invariants, reasons, Map, workflows and executable recipes. No changelogs, decision logs, or
  duplicated parameter lists; one owning skill per concept, linked elsewhere.
- `docs/game` is engine-owned game documentation (`mirai docs` / MCP `docs`); skills may link to it,
  it never links outside `docs/game`. `docs/` holds [architecture](docs/ARCHITECTURE.md),
  [workarounds](docs/ODIN_WORKAROUNDS.md), `game/` and active `PLAN_*.md`.

## Common commands

Full table and session flow:
[common commands](.agents/skills/mirai-projects/references/projects.md#common-commands).

- Commands build in dev. `--release` builds, tests and benchmarks are made only when the owner asks
  for one, never for testing or measuring; a number that only means something in release is
  reported as such instead of built. Use a worktree if the user's editor holds the dev build.
- Against an editor: `mirai session start`, `mirai rpc` / `mirai capture`, `mirai session stop`.
  Never hand-launch `mirai-editor`, write HTTP clients, or wrap `rpc` in `json.load`/`sleep` scripts
  (use `--select` and `--wait-until`).
- Remote Windows host: one program with `eco run -- PROGRAM`, several commands as one Git Bash
  script with `eco run --sh`, never PowerShell; the editor API through `eco forward`
  ([recipe](.agents/skills/mirai-agent-api/SKILL.md#5-remote-windows-sessions-eco)).
- Search with Grep or `rg pattern <dir>` (never `grep -r` from root; always pass a folder to `rg`,
  and close `$(...)` lists with `/dev/null` or `xargs -r rg`).

## Verification

Three levels; each party reports what ran and what remains without duplicating prior runs:

- **Authoring agent:** `mirai check` on touched packages, focal `mirai test` (GPU + validation only
  if `render`, `shaders`, `rhi` or GPU code changed). Docs only: `uv run scripts/check_docs.py`;
  `ui`/`editor`: also `uv run scripts/check_ui_style.py`. Changes to `tools/mirai`, generator,
  components or steps also require a real project build.
- **Integrator (per merged batch):** `mirai build editor`, whole touched packages (`--no-gpu`),
  `mirai play test`, `mirai scene check`, and `mirai render check --views` if `render`/`shaders`/
  `rhi` changed. Clean merges without conflicts need only `mirai check`.
- **Multi-branch close (unloaded machine):** full test suite with validation,
  [render check](.agents/skills/mirai-rendering/references/verification.md#render-check), and game
  build.

Solo changes include the integrator's checks: live call per touched method/flow, plus
validation-clean captures (`mirai capture --reference` for render/import, `capture` with `ui` for
editor UI; at most two self-iterations before showing the user; crop/zoom with `mirai image`).

- Verify minimal real paths early for protocol, auth or persistence changes.
- **Only touched tests.** Iterate on targeted tests or `--failed`; run the touched package once at
  the end (`--no-gpu` unless GPU code changed). Report unrelated failures without investigating.
- **Iterate visually in seconds.** Confirm what renders via `scene.inspect` or
  `render.inspect_entity` first, then keep one dev session open: hot-edit with
  `material.program.edit`, `mirai shaders --project P`, or `mirai build editor`, then `capture` /
  `mirai image`.
- **New tests.** Extend existing tests first; one table-driven test per invariant in the owning
  layer, failing without the fix. Keep non-GPU tests in non-GPU files.
- Never delete a failing test to land; distinguish product bugs from bad fixtures.
  Report platform-only paths with command and expected output.
- Edits against an open editor write to disk immediately; experiment on a copy (`mirai session
  start --copy` or `asset.move` with `copy`).

## Parallel work

- **Integration branch.** Branch from the integration branch the brief names (else `main`) and
  update from it once, at hand-off, not at every step. Land shared contracts (types, APIs,
  formats) first.
- **Integrator.** Integrate branches in batches of three to five that are ready together. Fix
  merge and call-site fallout of about 20 lines or less in place and say so; send larger defects
  back to the author.
- **Closed scope & dependencies.** Batch upfront questions with defaults; check
  [workarounds](docs/ODIN_WORKAROUNDS.md) before debugging Odin/Slang/SDL.
- **Subagent verification & sessions.** Subagents that write code MAY and SHOULD open
  `mirai session start --copy` / `mirai-editor` to visually and interactively verify their changes
  (`capture`, `play.step`, `play.audit`, `playtester`, `render.inspect_entity`). Subagents must NOT
  run heavy performance runs concurrently (`mirai render check`, `mirai bench compare`, full-GPU
  benchmark sweeps), which serialize through the workspace measurement lock
  (`workspace.measurement_wait`) or run at integration/close. Research subagents do not edit
  versioned files.
- **Machines.** At most three agents compile on one machine at once, and one agent uses its GPU at
  a time (GPU tests, `play test`, captures, live sessions, timings): the GPU turn queues the others
  ([turns](.agents/skills/mirai-projects/references/build.md#turns-between-processes)). GPU
  captures, timings and Vulkan runs go to the Windows PC by default when it is reachable
  ([eco](.agents/skills/mirai-agent-api/SKILL.md#5-remote-windows-sessions-eco)); the Mac's GPU is
  for Metal verification.
- **Processes.** Never kill a process you did not start, nor any by name (`pkill`, `killall`,
  `taskkill //IM`). Idle sessions and editors that hold the GPU are ended by the tool: the editor's
  own idle close and `mirai session stop --orphans`.

## Token spending

- **Waits.** Wait on a build or a test suite in the foreground for up to 15 min; run what takes
  longer in the background and read it when it completes, never polling with `sleep`/`until`/
  `tail -f`. Never end a turn or report while work you started still runs.
- **Closed assignments.** Specify concrete deliverable, done criteria and proving test. Keep final
  reports <= 150 words without pasted diffs or raw logs.
- **Child sessions & models.** Child sessions avoid spawning subagents except for large independent
  slices. Use cheaper/medium effort for research/audits/docs/clean merges, high for implementation,
  xhigh only for architecture design.
- **Read just enough.** Use line ranges, `rg -m`, `--select`, `--quiet`, `tail`, and parallel
  searches. Never read other sessions' transcripts.
