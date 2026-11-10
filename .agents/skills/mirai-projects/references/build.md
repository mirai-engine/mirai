# Project build: `cook/build`

`cook/build` (engine-time) generates the world, compiles the libraries and the game of a project,
generates its shaders, cooks its assets and assembles the shipped game. The engine binaries it
compiles against: [engine binaries](projects.md#engine-binaries). Which folders go in:
[packages](projects.md#which-packages-go-in).

## Targets

`world_write_files(&p)` writes the generated packages that changed to `.mirai/gen/`, with the
errors of the attributes.

- `Editor`: exports `mirai_project_info` over `gen/editor_world` (world of the editor, the game,
  the `editor/` of the project and the active plugins). A library (`-build-mode:dll`) of the
  generated world alone, against the engine `decl/` and the declarations of the
  [plugin libraries](projects.md#plugin-libraries), which hold the code of the active plugins and
  of the project and which the job compiles first if they are stale; with the optimization and
  the `-debug` of the manifest; output `.mirai/editor<ext>`. The editor loads it, and
  `mirai-player` runs its game (`mirai play`, `player.start`, the editor's attached players).
  Optimized (`Size`, `Speed`, `Aggressive`) it is a single LLVM module, as the shipped game
  compiles it, because a `#force_inline` procedure of another package is not inlined across
  modules; in dev (`minimal`) or `None`, one module per package
  (`library_optimization_append`).
- `Game`: a `main` that calls `host.player_run` over `gen/shipped_world`, the world without the
  development plugins, which only this target generates. It compiles the whole engine, the
  plugins and the game from the sources, `-o:speed` with `--release` (the build that ships) and
  `-o:minimal` otherwise; executable `<output>/<executable><ext>` (`.mirai/game` or `--out`). With
  `Desc.server` (`mirai build server`) it is the [dedicated server](#dedicated-server), the same
  executable in `.mirai/server`.

A library compiles only the code of the project: it sees the engine through its declarations. A
check and a test build read the project itself, with its tests.

## Flags and environment

- Every target gets the `defines` of the manifest, `platform_flags`, `MIRAI_ODIN_FLAGS` and
  `Desc.flags`; `mirai` applies the same flags and the same environment (`platform_environment`) to
  `test`, `check` and `build`. SDL3 comes from `.deps/linux-amd64/sdl3` on Linux (from
  `scripts/setup_linux_deps.py`, with its folder as `rpath`), on macOS from
  `.deps/macos-arm64/sdl3` if `scripts/setup_macos_deps.py` prepared it (with id `@rpath`, it
  travels next to the programs and the game) or from Homebrew, and from the compiler's `vendor/sdl3`
  on Windows.
- Memory cap of each compiler process (`compiler_memory`,
  [limit](../../mirai-std/references/subprocess.md#api)): by default half of the machine's memory,
  bounded to stay above the largest compilation; `MIRAI_COMPILER_MEMORY` sets it in GiB (`0`: no
  cap). macOS has no reliable limit for another process: there is no cap there and `mirai doctor`
  says so.
  - Past the cap, LLVM stops with `LLVM ERROR: out of memory` instead of taking the machine's
    memory: the build fails with `Out_Of_Memory`, and `mirai` and the editor say it is most likely
    odin-lang/Odin#7937 and that the `no_store_of_an_aggregate_of_more_than_64_bytes` test of
    `cook/build` finds it.
  - If the cap cuts the compiler outside LLVM, it crashes without a message (on Windows,
    `0xC0000005`); the failure gives the code and says the cap may be low.
- The compiler is `Desc.compiler` or `compiler_find(root)`: `MIRAI_ODIN`, the Odin of
  `deps_folder(root)` or `odin` in `PATH`; in a worktree nothing needs to be set. Slang and the
  SPIR-V tools are looked up in `deps_folder(root)` (`mirai setup slang`); generation requires the
  pinned Slang or a later one
  ([toolchain](../../mirai-rendering/references/shaders.md#tools)).

## Dependencies and worktrees

`cook/workspace` (engine-time) resolves where the dependencies and the cache live, for `cook/build`
and `tools/mirai`. The main checkout of a worktree is `project.shared_root(root)`
([settings](projects.md#project-settings)).

- `deps_folder(root)`: `<root>/.deps` or, if it does not exist, the one of the main checkout; if
  neither exists, `<root>/.deps`, where the installations write.
- `cache_folder(root, name)`: `<main>/.mirai/cache/<name>`, shared between checkouts.
- C libraries (FreeType): in the cache under a key of the hash of their sources without carriage
  returns and of their definitions. `<library>.key`, next to the one of a checkout, stores the key
  it was built with: with the same one nothing else is looked at; with another, it is copied from
  the cache or compiled and stored.
- Engine plugin libraries, by the fingerprint of each part
  ([plugin libraries](projects.md#plugin-libraries)), and shader stages, by content
  ([cache](../../mirai-rendering/references/shaders.md#cache-and-fingerprints)): a new worktree
  copies nothing.

### Turns between processes

- The locks (`workspace.lock_*`, in `<main>/.mirai/cache/locks/`) are between processes and the
  system releases them when the process ends; `<lock>.owner` says who holds it and the one waiting
  reports it, like `mirai locks`.
- The builds of a machine share up to four turns (`build.lock`, `build-1.lock`…), one per two
  physical cores, those after the first only with 4 GB free; a generation of shaders has
  `shaders.lock` and waits for no compilation. Within a checkout or a project they go one at a
  time (`<folder>/.mirai/build-turn.lock`), because they write the same files. They take them only
  when there is something to compile:
  - `build`, `edit`, `play`, `session start` and `import` first check, without the lock, the C
    libraries, the engine and its shaders (`build.engine_current`), the project shaders
    (`build.shaders_current`) and the library (`target_state`). If everything is up to date they
    say "unchanged" without waiting; if not, they take the lock and each step checks again.
    `build game` always takes it.
  - `mirai test` and `mirai check` generate the engine shaders under the lock only if there are
    stages to compile; `mirai test` compiles the executables of all its packages of the engine
    under one lock and runs them outside it; a package of a project holds it until its executable
    runs.
  - `workspace.builds_since` says whether someone compiled since a moment, so that whoever measures
    knows whether builds happened during the measurement. The editor's builds neither take the lock
    nor are annotated.
- What measures times runs alone among all checkouts: it takes `measure.lock` and then waits until
  there are no builds. `mirai measure`, `mirai bench compare`, `mirai render check` (except
  `--quality`), `mirai test` when it runs a benchmark (a `-define` whose name has `BENCH` and whose
  value is neither `false` nor `0`) and `profile.capture` with `advance` take it; the latter waits
  at most its `wait` and then fails saying who holds the turns
  ([profiling](../../mirai-agent-api/references/methods.md#profiling)).
  - Builds and tests that are not benchmarks do not wait for the measurement: each compiler
    (`build.compiler_limits`, also the editor's) and each test run that starts while one is
    running goes with `subprocess.Priority.Low`. The priority is decided when each process starts;
    what started earlier is not stopped.
  - A process with `MIRAI_MEASURE` is part of a measurement: it neither takes `measure.lock` nor
    waits for it. Whoever measures sets it for its children, and an editor opened inside them
    inherits it. The editor of a session is no child of the command that calls it: `mirai rpc`
    sends its `MIRAI_MEASURE` with the call, and `profile.capture` runs in that turn while the
    lock names the same measurement.
- The self-refresh of `bin/mirai` uses one lock per checkout (`bin/.refresh.lock`): if another
  process already rebuilt it, it uses that one.

### Implicit Vulkan layers

`mirai test` and the `--headless` programs (edit, play, session, capture) run with
`VK_IMPLICIT_LAYER_PATH` pointing at an empty cache folder: an installed overlay (Epic, Steam, OBS)
with a broken manifest would be reported as a loader error. `MIRAI_KEEP_LAYERS=1` keeps the layers.

## Jobs

```odin
job:=build.job_start({project=&p,target=.Editor})   // does not wait for the compiler
for !build.job_poll(job) {/* another frame */}
result:=&job.result
build.job_destroy(job)
```

- `Desc`, `Result`, `Status` and `Failure` are in `cook/build/build.odin`, with what each value
  means. The job owns everything `Result` points to; `job_destroy` cancels if needed.
- `job_cancel` kills the compilers, not the linker they may have launched. A job that fails leaves
  no compilers running.
- `target_state` says, without writing, whether the output is missing, stale or up to date.
- `Result.diagnostics` are the messages of `-json-errors` and the warnings of the generator; `text`,
  everything else the compiler printed (the linker is not structured).
- A compilation failure or a failure of the engine-time check does not publish the executable or
  store its fingerprint. In `Game`, copy and cooking happen after the executable is published,
  inside the call that finishes the job: `Copy_Failed` and `Cook_Failed` do not revert that
  publication and may leave the folder incomplete; a later job distributes again even if the
  executable is up to date.

## Outputs

- The compiler writes to `.mirai/build/<target>-<moment>-<pid>.*` and, if it compiles, the output
  goes with a rename to the published path. If the system does not allow replacing a file in use
  (Windows), the previous one is renamed to `.old` in `.mirai/build` and deleted when it is free;
  with `-debug`, the `.pdb` stays there with the job's name until another job compiles the target.
- A job deletes its files when it ends. Only one that compiled deletes those of other jobs of the
  same target, and only the ones older than `STALE_AFTER` (they may belong to a running job of
  another process).

## Fingerprint

`.mirai/build/<target>.sources.json` lists the sources the compiler exported in the last
successful build and `<target>.stamp` stores their fingerprint (`fingerprint`,
`cook/build/compiler.odin`): the size and date of the compiler (for an
[installed engine](projects.md#installed-engine), its size and `engine.mirai`: decompressing the
package changes the dates), the flags except `-thread-count:N`, the name and **content** of the
`.odin` files of each folder the build read a source from, **except the `*_test.odin`** (a test
invalidates no build, not even the self-refresh of `bin/mirai`), and what is loaded with `#load`.
A test executable counts the `*_test.odin` too: a build of tests reads those of every package it
imports ([checks and tests](projects.md#checks-and-tests)).

- The content is read without carriage returns and paths count relative to the engine root: the
  same content in another checkout, or after a checkout or merge that leaves the files the same,
  gives the same fingerprint. The output does not count, nor do the folders next to the compiler,
  which change with it.
- If a source changed after the compiler started, the fingerprint is not stored.
- `Game`: with another `--out` and the same fingerprint, the executable is copied instead of
  recompiled.

## Project shaders

The Slang programs of `<project>/shaders/` and of the `shaders/` of each active plugin with the
`Shaders` part are compiled in the **project generation**: the engine stages with the catalog of
programs that includes them, published in `project.shader_generation(root)`. Contract of the
programs, cache, loading and reload:
[rendering](../../mirai-rendering/references/shaders.md#project-generation).

```odin
job:=build.shaders_start(&p)          // does not wait: generates on its own thread
for !build.shaders_poll(job) {/* another frame */}
result:=&job.result
build.shaders_destroy(job)            // waits for a generation in progress
```

- `first` names stages that are compiled before the rest; while the job runs, `shaders_first(job)`
  gives a generation that loads by itself with them
  ([first stages](../../mirai-rendering/references/shaders.md#early-stages-and-cancellation)).
  `shaders_cancel` does not block: it kills the compilers and the job ends `Cancelled`.
- The generation is a transaction: a failure or a cancellation leave what is published as it was;
  `None` (neither the project nor its plugins have programs) deletes the one of a previous build.
- Without Slang or without the SPIR-V tools it fails with the generator's message, which names the
  tool and how to install it; without `engine_root` it fails without trying.
- `mirai build editor` ends with 1 if the project shaders fail; `edit` and `play` continue and
  report it.

## Shipped game

The `Game` folder (`Desc.output`, or `.mirai/game`) receives the executable, `project.mirai`, the
icon it names if it exists, `settings.mirai` with the
[combined](projects.md#project-settings) settings, `assets/` with what was
[cooked](#asset-cooking) of the project and of each active plugin that declares `Assets` (in
`assets/plugins/<name>/`), `shaders/` with the manifest, the catalog and the code of this system of
the published generation (no Slang sources; `mirai build game` generates the shaders first) and
SDL3 if the system does not provide it.

The copy replaces files and merges folders without deleting anything from the destination, except
`assets/`, which ends up exactly with what was cooked. `source/`, the code, `cook.mirai` and the
`plugin.mirai` are not copied. `mirai play` copies nothing: `mirai-player` runs with
`--project <project>` and reads assets and shaders from the project.

## Dedicated server

`mirai build server` builds the folder of a server nobody plays on: the same executable as `Game`
(with the same fingerprint it copies it), run with `--dedicated`
([player](../../mirai-core/references/host.md#arguments)). It leaves out what is only seen or
heard: neither the icon nor `shaders/` (it does not generate the project's), and its cooking leaves
behind the `presentation` asset kinds of `asset.KINDS` (textures, sounds, interfaces, fonts and
prompts) without counting them as missing. It carries `settings.mirai`, with the bindings Project
Settings > Input changed, and SDL3, which the executable links.

## Imported sources

The meshes, textures, sounds and fonts an import builds are not versioned: they are in
`.mirai/imported/` of the project and of each plugin with assets, and are built again from the
sources and their sidecars ([sync](../../mirai-imports/references/imports.md#sync)).

- **A build imports first, and says so.** Every build of a project starts by running the sync of
  the project and of its active plugins (`job_start`, `build.imports_sync`): the editor, the game,
  the server, `mirai play` and the builds the editor starts. It uses the engine's import program,
  since the tool builds without the importers, and builds the engine first when that program is
  not current. A source that does not import fails the build naming it (`Import_Failed`). There is
  no other step: a checkout that was just cloned runs after any build.
- **What ships.** A game has no imported folder and no sources: the cook writes every asset it
  reaches at its path in the assets of the game, whichever of the two folders it came from.
- **The installed engine** carries the imported folder of each of its plugins, built when it is
  packaged (`mirai package engine`): nothing is imported on the machine that installs it.

## Asset cooking

`cook_assets` (`cook/build/cook.odin`) leaves in a folder the assets the game can reach. The `Game`
job calls it with the project assets, `cook.mirai`, the asset folders of the active plugins and the
texture cache of the project; a failure is `Cook_Failed` with `Result.cook.error` and `detail`.

- **Roots.** Every `.scene` (code reaches a prefab only by instantiating it) and `.records`
  of the folder and what `cook.mirai` (`COOK_FILE`) names: the other assets only code refers to (a
  material chosen by name).

  ```json
  {
    "roots": ["surfaces/metal/Chrome.mat", "characters/player/",
    "3b4cb4195321a2f7fe61aa57ece0c255"], "textures": "blocks"
  }
  ```

  A root is a path from `assets/` (a file, whether or not it is an asset), a folder ending in `/`
  or an asset id. A root that names nothing is `Root_Missing`; a malformed `cook.mirai` or one with
  another key, `Manifest_Invalid`; in both cases nothing is cooked.
- **Plugins.** The folder of each plugin is mounted under `plugins/<name>` and everything in it is
  a root (its code uses it).
- **Parallel.** Files are cooked on a job system (`Cook_Desc.worker`, else one of the cook with a
  thread per core), the largest first; what is written and the report are those of a cook on one
  thread, and an error is the first by path. Prefab resolution and texture cache writes take a lock.
  A dev game is cooked with the pack `QUICK` of `cook/compressor/lz` (`Cook_Desc.quick`), a
  release one with `SHIP`.
- **Scope.** The roots and, transitively, the dependencies each asset declares; the rest goes to
  `dropped`. A dependency that is not any file goes to `missing` and does not stop the cooking.
- **Textures.** With `"textures": "blocks"` (default), an RGBA8 texture is written in blocks
  according to its use (`textures.blocks_of`), except one that only interfaces (`.ui`) display,
  which is copied; `"keep"` copies them all. The blocks stay in the texture cache by the
  `content_hash` of the `.tex`
  ([texture cache](../../mirai-imports/references/imports.md#texture-cache)).
- **Fast textures.** A texture the editor imported Fast ships Final, whatever `"textures"` says:
  the [sync](#imported-sources) a game build starts with builds it again from its source, with the
  id it has, and fills the texture cache, so the editor takes that Final from then on. A cook that
  finds one still Fast fails with `Source_Failed` and says so.
- **Animations.** An `.anim` is written cooked: its clips sampled as the runtime plays them
  (`asset.animation_compress`, [storage](../../mirai-std/references/anim-storage.md)).
- **Prefab instances.** A scene with a stale instance is written with its instances up
  to date, by an `asset.Prefab_Resolver` of the project prefabs
  ([instances](../../mirai-assets/references/scenes.md#resolution-against-the-current-prefab)); the
  shipped game loads them without checking them. If it cannot, `Resolve_Failed` with the file.
- **Far meshes.** A game with the `streaming` plugin (`Cook_Desc.far`) ships beside each scene a
  section references its far mesh, `<scene>.far.mesh` with the id `asset.far_mesh_id` gives
  (`cook/far`): the game shows it and makes none
  ([far shape](../../mirai-gameplay/references/libraries.md#plugin-streaming)).
- Every other asset is written again compressed for shipping (`asset.document_repack` with
  `SHIP`, [compression](../../mirai-assets/references/formats.md#compression)), and so are the
  textures it writes in blocks; a file that is not an asset is copied byte by byte.
- **Index.** The folder receives `.index` (`asset.REGISTRY_INDEX`), what a scan would find; with
  it `host.assets_init` does not look at the files
  ([registry](../../mirai-assets/references/formats.md#registry)).
- **Check.** Each written asset is read again and must have the same id, type and hash. The files
  of a previous cooking that this one did not write are deleted.
- `mirai build game` prints the report (`cook_summary`), verifies each cooked asset with the rules
  of `mirai asset verify` (it ends with 1 if one fails) and says how much the game weighs.

## Exclusion guarantee

After compiling the game and before publishing it, `engine_time_packages` looks, among the sources
the compiler says it read (`-export-dependencies:json`), for those of the engine's `editor/` and
`cook/`, the `plugins/*/editor/`, the `editor/` and the generated editor packages of the project,
and the development plugins. If there is any, the job fails with `Engine_Time_Code` and does not
publish. A new engine-time folder of the engine is added there.

The compiler also reads the `_test.odin` files of every package the game imports, with their
imports: a test of a runtime package does not import an engine-time one. A GPU test of a plugin
loads the shaders that `mirai test` generates for it (`package_test_shaders`) instead of generating
them with `cook/shaders`.

## Known limits

- Cooking does not group assets in a file: they are loose files with an index.
- What code refers to and is not in `cook.mirai` is not shipped: cooking does not read code.
- The first shader generation of a project and each edit of the code of a Surface program compile
  all the stages that evaluate materials for the system's backend, because each one contains the
  code of all the programs. An edit of only metadata publishes and validates the catalog without
  compiling stages ([toolchain](../../mirai-rendering/references/shaders.md#shader-toolchain));
  PostProcess code compiles one stage.
- A shader generation in progress is not cancelled on close: `shaders_destroy` and closing the
  editor wait for it.
- If the project stops having programs, an already shipped game keeps its `shaders/`.
- The game on Windows is a console one.
