# Instructions for Mirai agents

From `references/` open only the sections the Map of the `SKILL.md` points to.
[The architecture](docs/ARCHITECTURE.md) is read when changing layers, packages or contracts between
areas. Tell apart requested design, implemented behavior and validation coverage. In a worktree its
own `AGENTS.md` applies, not the one of the checkout that contains it.

## Principles

- **Mirai engine.** Native 3D engine with an editor, plugins and a main workflow through code and
  API/MCP, without manual programming. Platforms: Windows, Linux and macOS ARM64; consoles and
  mobile are out.
- **All in Odin.** C libraries are allowed; C++ dependencies are consumed prebuilt: **do not write
  or compile C++ code** in the engine. Tools are subcommands of `mirai`; what is external to the
  engine are
  [Python scripts with uv](.agents/skills/mirai-projects/references/projects.md#external-scripts).
- **Layers with one-way dependencies** ([map](docs/ARCHITECTURE.md#package-map)), through the
  `mirai:` collection. What is *engine-time* (`editor/`, `cook/`, the `editor/` part of a plugin or
  project) is never imported from *runtime*: a game binary does not contain it.
- **No global state.** No package declares mutable package-level variables; state lives in explicit
  contexts that use the allocator they receive. That way a world can be copied (Play, rollback),
  several worlds run in one process, and everything can be tested. A fixed value is a constant
  (`NAME :: value`), not a parameterless procedure that returns it. The only exception is
  `rhi/shared_device`, imported only by tests: the device the GPU tests of a process share.
- **Data and functions.** A game is a generated world (component tables and storages) and loop
  functions that transform it. A function receives exactly what it reads and writes; a piece of
  data has one writer and the others request changes through a queue. Entities are generational
  handles, never pointers kept between functions. Plain data, copyable in blocks. No classes,
  inheritance, virtual objects per entity or widget, or per-entity Update.
- **Preallocated capacities.** A stable frame or tick does not allocate. Loads, imports, cooking,
  snapshots and reloads are transactions that may allocate.
- **Each algorithm is implemented once**: no copies per operating system, graphics API,
  runtime/editor or client/server. `rhi` translates to Metal and Vulkan; window, input and audio go
  through SDL3; platform differences go in files with build tags and the same signatures. A single
  Slang source: SPIR-V, MSL and bindings are generated and never edited by hand. No empty backends.
- **No legacy or backward compatibility.** Formats and APIs are versioned; an incompatible change
  updates all its consumers in the same task. What was deleted leaves no alias, flag, fallback or
  hint: a removed method is an unknown method. A default or a behavior is decided on its merits,
  not to keep what there is or the assets of today.
- **Common entities and capabilities through components.** Identity, transform and hierarchy are
  the base of every entity; presets are creation recipes
  ([core](.agents/skills/mirai-core/SKILL.md)). A generic component plus data, never a component
  per case; a rule about a type is an attribute on the type that the generator records, never a
  list of types kept elsewhere.
- **Games and plugins use a simple public API** (`core`, `host`, `engine/*`, `std`, `ui`, `asset`);
  the engine has no rules of a game. Whoever uses the API, a person or an AI over MCP, declares the
  result they want, and on invalid input gets an error that says what failed and how to fix it. A
  plugin extends the renderer through `engine/render`, without importing `render` or `rhi`.
- **Few concepts, a simple surface.** The API, the editor and the formats show as few concepts as
  the job needs. Where what is simple to use and what is simple to build pull apart, the
  difficulty stays inside the engine, never with whoever uses it.
- **Physics and game networking are first-party plugins** (`physics`, `multiplayer`): fixed step,
  authoritative server, prediction and rollback, no bit-exact lockstep across architectures. The
  `net` transport stays in the engine: editor collaboration uses it and cannot be turned off.
- **UI.** Own layout in Odin (`ui`). Editor UI changes are made directly in the native editor.
  Text: [typography](.agents/skills/mirai-ui/SKILL.md); editable text is US-keyboard ASCII; no
  IME, HTML, CSS or embedded browser. The editor UI animates only the text cursor, the dot of what
  is working (an agent, a load) and the composer of the AI chat going down on its first message,
  and has no help texts except the description of a component above its header and that of a
  field when hovering its name; game UI does allow animations.
- **The engine does not crash on valid input.** No public function terminates the process for any
  input: it validates what it receives and returns an error, also when it runs out of memory;
  `#no_bounds_check` goes only where the inputs were already validated. Tests with hostile inputs
  (random data, NaN, out-of-range indices, low memory) cover it under bounds checking, the memory
  tracker and the sanitizer. A native error of the game may end the editor; recovery keeps the
  document from before the run.
- **Odin.** Do not reintroduce the patterns of the [current workarounds](docs/ODIN_WORKAROUNDS.md).
- **Comments only when strictly necessary**: a unit, the meaning of a field, a non-obvious reason.
  Do not narrate changes or requests.

## Scope and done

- **Root fixes, not workarounds.** A problem is fixed where it is caused, also in third-party code
  that lives in the repository, which is ours to edit or rewrite: no wrapper, define, suppressed
  warning or special case around it. If the root fix is large, tell the user its size and wait
  for the answer instead of choosing the workaround.
- **A defect found during a task** is fixed in it if it blocks the task or is in what the task
  touches; if it is a large change that needs a decision, ask the user.
- **A defect of a dependency** (Odin, Slang, SDL): prepare the upstream fix (minimal repro, PR or
  issue) and, until it is released and integrated, a workaround with a comment that names it; an
  Odin one also gets its entry in [Odin workarounds](docs/ODIN_WORKAROUNDS.md). Publishing the PR
  or issue requires the user's confirmation.
- **Code or data taken from another project** under an open-source license (MIT, Apache, BSD,
  zlib, GPL and the like), translated or adapted, gets its entry in
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) in the same task: the project, its license, the
  copyright holder as its repository states it and where it ends up. The final report lists it
  under **Derived code**.
- **Done** is every requested point implemented and verified as [Verification](#verification)
  says. The final message lists what was left unverified or approximate.
- **If what is missing is structural** (another technique, a new system), stop and ask.
- **No new pending items.** What was requested is finished in the task; what could not be finished
  or a defect elsewhere is stated in the final report, not written to a pending file. A `PLAN_*.md`
  of work in progress is not a file of pending items.

## Less code, simpler and faster

- **One piece of data, one place, one writer.** Do not copy state into another struct or deliver
  it twice.
- **Each frame does only what changed**, and where it changes: what is decided per instance is
  computed once on the CPU when it changes, never again per pixel in a shader.
- **A simplification ends with fewer lines** of code that is not tests than it started with
  (`git diff --shortstat main...HEAD -- '*.odin' ':!*_test.odin'`, and the same for `*.slang`); if
  it cannot, the report says why.
- **What is optional goes in a plugin**: what some games use adds no state or code to the core.
- **Performance.** If the task seeks performance or adds measurable work per frame or tick, measure
  once, when it is finished, with `mirai bench compare --base main`
  ([profiling](.agents/skills/mirai-agent-api/references/methods.md#profiling)): it alternates
  pairs of both builds, built alike in dev, without validation, VSync or frame limit, and
  writes the table. Never after
  each step nor with homemade pair scripts. A change that does not move the cost (UI, tools) needs
  no base: `profile.capture` in the open session is enough. If other tasks are compiling or
  testing, CPU time per phase counts; wall clock and frame time are measured in the unloaded window
  the integrator sets up. The results table goes in the final report; raw output goes to `bin/`.
  Measurements are not committed.

## Documentation and skills

- Everything in English: documentation, skills, identifiers, commit messages, and every message of
  the engine, its CLI, API and MCP. Lines of at most 100 characters (except a lone URL); the YAML
  frontmatter of a `SKILL.md` stays YAML: `---` on line 1 and indented continuation lines.
- `SKILL.md`: `name` equal to its folder and a `description` with the words that should trigger it;
  then the Map (task → section), the workflow, the invariants and the verification with its focal
  tests. `references/` describes the current behavior, without measurements or history. A single
  source per topic, linked.
- **Documentation keeps what the code does not say:** invariants, reasons, the Map and the
  workflows. It does not repeat what the code and its comments, the tests, `engine.describe` or git
  already say: no figures that are constants of the code (points, milliseconds, sizes), no lists of
  fields, parameters or methods, no record of who integrated what. When an area changes, its skill
  is updated only if an invariant, the Map or a workflow changes, and what was replaced is removed.
  Documentation is not a changelog: it describes the latest version; on contradictions, the one
  that matches the code stays.
- **A concept has one owning skill** that defines its contract; the others link it from their Map
  without copying it.
- **No decision records.** Docs do not record rejected alternatives, past measurements or what was
  tried: skills and code say how things work. A rule the user decided is one line in the
  invariants of the owning skill.
- `docs/game` is the documentation for writing games, owned by the engine and served by `mirai docs`
  and the MCP tool `docs`, so projects keep no copy; `mirai-*` skills may link to it, it never links
  out.
- `docs/`: [architecture](docs/ARCHITECTURE.md),
  [dependency workarounds and defects](docs/ODIN_WORKAROUNDS.md), `game/` (above) and the
  `PLAN_*.md` of work in progress. Third-party code and assets that ship with the engine are listed
  in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- Contracts are checked against the code: `engine.describe` reports the methods and schemas of an
  open build and `mirai asset` inspects binary assets.

## Common commands

The shell, the command table, the flow of a session and how to hand a command to the user:
[common commands](.agents/skills/mirai-projects/references/projects.md#common-commands).

- Every command builds in dev unless `--release` is given; `render check` and `bench compare`
  build both sides alike: two builds of the same mode compare. **`--release` only when the task
  cannot do without it or the user asks for it**: a budget in absolute numbers.
  If the user's editor holds the dev build of the checkout, work in a worktree.
- Against an editor: `mirai session start`, `mirai rpc` or `mirai capture`, and
  `mirai session stop`. Do not launch `mirai-editor` by hand, write HTTP clients, or parse the
  output of `rpc` with scripts: `--select` and `--wait-until` instead of `json.load` and `sleep`.
- **Search** with the Grep tool or `rg`, which skip `.worktrees`, `.deps` and `bin`; never
  `grep -r` or `find | xargs grep` from the root. `rg` always takes a folder (`rg pattern .`):
  without one it reads standard input and hangs. A file list built with `$(...)` may come out
  empty: close it with `/dev/null` (`rg pattern $(...) /dev/null`) or go through `xargs -r rg`.

## Verification

Three levels, each run by one party; none repeats what another runs, and the report of each says
what ran and what it left for the next.

- **The agent that writes a change**: `mirai check` of each touched package, always, then the tests
  of what it touched with `mirai test` (the focal ones the area's skill names; the GPU ones, with
  validation, only if `render`, `shaders`, `rhi` or the GPU part of the area changed). Only
  documentation or skills: `uv run scripts/check_docs.py` (links, anchors, frontmatter and
  symlink); `ui` or `editor`: `uv run scripts/check_ui_style.py` too. A change to `tools/mirai`,
  the generator, a component or a step also takes one real build of the affected project, which
  runs the generator.
- **The integrator, once for each batch of branches it merges**: `mirai build editor` of the
  affected project, the touched packages whole without GPU, the scenarios (`mirai play test`),
  `mirai scene check` and, if the batch touches `render`, `shaders` or `rhi`, the cost of one view
  against `main` (`mirai render check --views`). A merge without code conflicts takes only
  `mirai check` of the packages it brings.
- **The close of a task of many branches**, on a machine with no other load: every test package
  with validation, the
  [render check](.agents/skills/mirai-rendering/references/verification.md#render-check) and the
  build of the game. Full suites, reference captures of all areas, and build and frame times run
  only here.

Whoever works alone on a change does the integrator's part for it. If it runs in the engine: one
real call per touched method or flow, in a session. If it is visible: a capture without validation
errors compared with its reference; for rendering or importing, `mirai capture` from the reference
camera with `--reference` and an SSIM threshold; for editor UI, `capture` with `ui`. At most two
capture iterations of your own before showing the user the image and the doubt; in a visual review
with the user, each round is shown to them. Crops, zoom and pixels with `mirai image`, not with
scripts. Looking at how something looks does not require removing the frame limit or VSync.

- If a protocol, an authentication or persistence changes, check the minimal real path early,
  before extending the implementation.
- **Only the tests of what was touched.** Each run resolves a new doubt or verifies a change. While
  iterating, `mirai test <package> <test...>` of what changed, or `--failed`; the whole touched
  package, once at the end. No suites of other areas nor GPU tests if `render`, `shaders`, `rhi` or
  the GPU part of the area was not touched (`mirai test <package> --no-gpu`). A run that passed is
  not repeated without a code change in between. What fails in another area is not investigated in
  the task: it is reported.
- **Iterate on what is visible in seconds.** Before touching a shader or a material, confirm in the
  scene what draws what is seen (`scene.inspect` of the entity, its material and its program).
  While iterating, a single dev session open on that scene: a material program is changed with
  `material.program.edit`, another shader of the project or of a plugin with
  `mirai shaders --project P`, which asks the open editor for it; both publish first what the
  viewport draws. An engine shader (`shaders/`) is published by `mirai build editor` into the
  open session the same way; one that changes its bindings rebuilds and restarts it. Then
  `capture` or `mirai capture` and `mirai image`. No `render check` or `--release` builds per
  round: the check runs once at the end and only if the change is global; a quality one does not
  measure cost.
- **New tests.** Before adding one, look for the one that already covers that behavior and extend
  it. One test per behavior or contract, not one per parameter variant (cases go in a table), in
  the layer that implements it and not again from each consumer. It checks invariants, not sizes,
  bytes, counts or full texts that change with each version, and it fails without the fix. A test
  that does not use the device lives in a file without GPU; an invariant that several plugins
  share is tested once, in its helper, and each plugin tests only its wiring.
- A path is not verified without its build and run. What only runs on another platform is stated in
  the final report, with its command and its expected result; there is no separate file for that.
- If a test fails, first tell a product defect apart from a wrong fixture. A test that already
  fails on `main` is stated in the report. A change does not land by deleting a test case or
  widening a limit: a case that no longer applies is named in the report, with the reason.
- Preserve local changes. Report what was checked and in which environment.
- Against an open editor, work on a copy: `scene.save` only to `.mirai/tmp/`, never over a
  versioned asset.

## Parallel work

- **Integration branch.** Every session or subagent that writes code starts from `main`, unless the
  user names another integration branch; if it started from another one, it rebases onto it before
  touching code. The integrator merges each branch when its task finishes; a long task merges the
  integration branch into its own every time it advances, so conflicts do not pile up.
- **Contracts first.** What several tasks share (types, APIs, formats) is settled first in a small
  branch and integrated before the rest is split.
- **One owner per topic.** Two tasks may touch the same file if they change different parts. If both
  need the same function, type or contract, that change goes first, as a contract.
- **Closed scope.** Questions go together at the start, each with its default. If the task grows
  beyond the assignment, ask the user before widening it.
- **Dependencies.** Before investigating a defect of Odin, Slang or SDL, look for it in the
  [workarounds](docs/ODIN_WORKAROUNDS.md) and in the upstream issues and PRs.
- A subagent that writes code delivers at the first level of [Verification](#verification),
  without opening sessions, capturing or measuring; whoever launched it integrates and validates.
  A research one does not modify versioned files and may build and measure. A failure found at
  integration becomes a check of the integrator, not a step added to the brief of every agent.

## Token spending

Every turn rereads the whole context: the cost grows with its size and with the number of turns.

- **Short waits.** No command blocks for more than 4 minutes or polls with `sleep`, `until`,
  `tail -f` or a long `timeout`: what takes longer runs in the background and is read once when it
  finishes. A longer wait expires the cache and the next turn writes the context again.
- **Closed assignment.** The prompt of a session or subagent names a concrete item, the result
  that makes it done and the test that proves it, not the mechanism, unless the mechanism is a
  contract already decided; "solve section X" is not an assignment. The final report has at most
  150 words and does not copy diffs or outputs.
- **Child sessions.** A child session does not launch subagents except for large, independent
  parts. After a cutoff by limit they are resumed in batches, not with a message to all.
- **Model and effort per task.** Research, audits, triage, documentation and merges without
  conflicts: a cheaper model (Sonnet) or medium effort. Implementing: high effort. xhigh only to
  design architecture, never in a session that coordinates others.
- **Read just enough.** Large files by range or section, `rg -m`, outputs with `--select`,
  `--quiet` or `tail`; independent searches together in one call or in parallel. Transcripts of
  other sessions are not read: their report is enough. The source of another engine is read to
  design a new shape, not to fix a defect.
