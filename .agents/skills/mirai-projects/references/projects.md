# Projects, plugins and build

Targets, jobs, fingerprint, project shaders, cooking and shipped game (`cook/build`):
[build](build.md).

## Layout

```text
<project>/
  project.mirai     manifest: what makes the folder a project
  input.mirai       bindings Project Settings > Input changed from the code (optional, not by hand)
  settings.mirai    project settings: what differs from the engine (optional)
  cook.mirai        cooking roots that no scene names (optional)
  assets/           assets: what is authored, and the documents imports write
  source/           art sources, each with its sidecar (<source>.import): settings and asset ids
  game/             game library of the project
  editor/           editor package of the project (engine-time)
  plugins/<name>/   plugin.mirai, runtime/, editor/, shaders/, assets/
  shaders/          own Slang programs
  panels/           editor panels built by the chat agent (engine-time)
  tests/scenarios/  gameplay tests the editor plays (`mirai play test`), optional
  .mirai/           generated; not edited or versioned
    imported/       what imports build from source/ that nobody edits (meshes, textures, sounds,
                    fonts), at the paths they have among the assets; mirai build makes it again
    gen/            generated packages: the worlds and the root of each target
    plugins/        libraries of the engine plugins, with their stages and declarations
    editor<ext>     library of mirai-editor and of the players it opens; play<ext>, that of
                    mirai-player
    *-live-<pid>-*  copies each process loads; they delete themselves
    game/           shipped game, if no other folder is requested
    shaders/        shader generation of the project
    build/          files of the jobs, sources and fingerprint of the last build per target
    cache/          machine caches (asset registry, textures, built meshes, compressed .anim)
    thumbs/         asset previews of the editor
```

The first-party plugins are in `<engine>/plugins/<name>/` with the same shape; the engine binaries,
in `<engine>/.mirai/engine/<dev|release>/` ([below](#engine-binaries)). The names come from
`project.FOLDER_NAMES`, `project.PART_NAMES` and the constants of `project/project.odin`.

## Manifests

`project.Manifest` and `project.Plugin_Manifest` (`project/manifest.odin`, with the meaning of each
field) are written as JSON by the schema of the struct (`std/serial`): enums by name, `bit_set` as a
list of members, a list of names as a list of strings that replaces the whole one. A missing field
keeps its default; one the struct does not have is an error.

- `build.optimization` and `build.debug` apply to the `editor` and `play` libraries; the shipped
  game always compiles at `-o:speed` and the engine binaries always carry `-debug`.
- `version` and `identifier` are those of the game: the player gives them to the system with the
  title (`SDL_SetAppMetadata`). `icon` is a PNG relative to the project: the player puts it on its
  window and the shipped game carries it at the same path. `thumbnail`, another PNG relative to the
  project, is the image the [project list](../../mirai-editor/references/panels.md#projects)
  shows it with; it does not go into the shipped game.
- The `section=` tags of `Manifest` build the Game, Window and Build sections of the Project
  category of the
  [settings dialog](../../mirai-editor/references/panels.md#project-settings); `plugins` and
  `sources` are `hidden` because the Plugins category edits them.
- `sources`: the plugins of `plugins/` that come from git, each at a full commit; `catalog` marks
  one installed from the catalog, which updates itself to the commit the catalog lists. Its folder
  is a checkout that the project repository ignores; `mirai plugin` and the Plugins category write
  it ([git plugins](../../mirai-plugins/references/plugins.md#git-plugins-and-catalog)).
- `test_dependencies`: plugins that its tests import besides its dependencies; they are never
  activated with it
  ([imports](../../mirai-plugins/references/plugins.md#dependencies-and-compatibility)).
- `asset_kinds`: the kinds of asset a plugin adds, each by its extension and whether it is a
  document git merges and diffs ([git and assets](../../mirai-assets/references/cli.md#git)):
  what the CLI, the cook and the editor know of them without loading the plugin.
- `development`: a tool for making the game (`profiler`, `tracy`). It goes into the `editor` and
  `play` libraries; the shipped game is generated with `shipped_world`, the world without them, and
  if its code reaches them the build fails with `Engine_Time_Code`.
- `automatic`: a bridge between plugins, active exactly when all its dependencies are, after them;
  no project names it. A project that names `physics`, `destruct` and `multiplayer` adds only
  `destruct_multiplayer`. The editor's plugin lists do not show it.
- `icon` of a plugin: a PNG relative to its folder, with `/`, which the editor's plugin lists show
  next to its name (cropped to the center square, in a small cell of the preview atlas); without it
  or if it cannot be read, the generic icon. One from the catalog that is not installed uses the
  PNG of its entry
  ([catalog](../../mirai-plugins/references/plugins.md#git-plugins-and-catalog)).
- `project.Error` carries an `Error_Code` (its comment says what `subject` is in each), the plugin
  if the error is in its manifest and, for `.Text`, the line, the column and `detail`.
  `error_text` writes it for whoever fixes it: the CLI and the editor use it.
- `manifest_merge` puts on a manifest the fields a JSON object brings and validates it: what
  `project.set` uses ([catalog](../../mirai-agent-api/references/methods.md#project)).

## Project settings

A **setting** is a `@(storage,setting)` storage of an engine library, of an active plugin or of the
game ([attributes](../../../../docs/ARCHITECTURE.md#the-generated-world)). A **machine setting**,
`@(storage,setting="machine")`, is a preference of whoever uses the engine on this machine (the
graphics quality), not a design datum of the game. A settings file has one section per setting,
with the name of the type and the schema of the manifests.

- Layers, from bottom to top:
  1. the values from code: the default `NAME_DEFAULT` of each storage or, with a GPU device,
     `name_for_device(device:rhi.Device_Info)` if the package declares it
     (`Storage_Info.for_device`, which `host.app_settings` leaves in `project.Setting.base`);
  2. `settings.mirai` in `machine_folder(engine root)`, the `.mirai` of the main checkout of the
     engine (`shared_root`): the machine settings on this machine, outside git, the same for all
     worktrees of the engine;
  3. `<project>/settings.mirai`: any setting, also the machine ones (a project can fix its
     quality);
  4. in the player, `settings.mirai` of the player's options (layer `.Player`, in `App.options`,
     `<user data>/Mirai/<project>`): only machine settings, the ones the player chose; it is
     written by `host.app_options_save` with what differs from the layers below, at the request of
     the game ([options](../../mirai-gameplay/references/libraries.md#save)).
- The engine file only reads and writes machine settings, so a design datum does not pass from one
  project to another with a type of the same name: a section of a project setting there is not
  applied, it is kept and the editor warns on load (`settings_misplaced`).
- Each file stores only what differs from the layers below, field by field (an array, whole). When
  reading, a field the type does not have is omitted; when writing, the sections that no setting
  names (of an inactive plugin) are kept.
- `host` applies the layers to the `World` settings when creating each world and to the `Shared`
  ones when creating the application (`host.app_settings`); the editor and the development player
  receive the engine root ([installed engine](#installed-engine), through
  `project.engine_root_find`).
- The shipped game has no engine: `mirai build game` writes next to the executable a
  `settings.mirai` that combines the machine sections of the engine file (the ones
  `Generated.machine_settings` names) and the project file. If a file is not valid JSON, the build
  fails with `Settings_Invalid` and names file, line and column.
- API of `project`:
  - `Setting{name, info, value, default, machine}` and `Settings_Layer` (`.Project`, `.Engine`,
    `.Player`, with the player's folder in `player`); `SETTINGS_FROM_TOP` gives their order.
  - `shared_root(root)` is the main checkout of a git worktree (it reads `.git`, `gitdir:` and
    `commondir`; the root itself if it is not a worktree) and `machine_folder(engine_root)`, its
    `.mirai`: where the engine stores what belongs to the machine (the engine layer, the
    [editor preferences](../../mirai-editor/references/panels.md#preferences)).
  - `settings_file(layer, root, engine_root)` gives the path of a layer, `settings_under(layer)`
    the layers below it and `settings_held(settings, layer)` the settings its file stores.
  - `settings_load(settings, root, engine_root, layers)` applies the requested layers;
    `settings_save(settings, layer, root, engine_root)` writes one;
    `settings_merge(root, engine_root, machine)` gives the combined text the shipped game carries;
    `settings_misplaced(settings, root, engine_root)` names the sections of project settings the
    engine file has.
  - Lower level: `settings_parse(text, settings)`, `settings_read(path, settings)` (a file that
    does not exist leaves the values), `settings_default`, `settings_clone`,
    `settings_text(settings, below, kept)` and `settings_write(path, settings, below)`.
- In the editor, File > Project settings shows them with the rows of the Details panel and stores
  each change in the chosen layer
  ([dialog](../../mirai-editor/references/panels.md#project-settings)); through the API,
  `settings.get` and `settings.set`.
- The defaults are exposed in the [reflection of the generated
  world](../../mirai-core/references/generator.md#changing-the-generator); the inspector uses them
  to revert each property.

Settings of the engine and its plugins:

- `Graphics_Settings` (`render`, machine): renderer quality, with a default according to the GPU,
  frame limit, VSync and the game's FPS counter
  ([graphics](../../mirai-editor/references/panels.md#graphics)).
- `Particle_Settings` (plugin `vfx`): live particles at once across all emitters.
- `Physics_Settings` (plugin `physics`): capacities, substeps and gravity; read when its world is
  created.
- `Display_Settings` (`render`, machine): mode, size and screen of the player's window over those
  of `project.mirai`.
- `Audio_Output` (`audio`, machine): the sound output by its name.
- `Net_Settings` (plugin `multiplayer`, `Shared`): port, protocol, version, capacities and
  tolerances.
- `Spawn_Settings` (plugin `spawn`): `players` gives a body at a spawn point to each player that
  has none; off, the game gives them a body.

## The `project` package

`open(root, engine_root)` reads `project.mirai`, discovers the plugins and orders the active ones;
the `Project` owns everything it points to.

- **Discovery**: a plugin is a subfolder of `<root>/plugins/` or `<engine_root>/plugins/` with
  `plugin.mirai`; the others are ignored. The inactive ones are also validated: a broken manifest
  or a part declared without a folder (or a folder not declared in `parts`) is a project error.
- **Order**: `active` are the plugins the project names and their dependencies, each after its own
  and, apart from that, in the project's order. A cycle between inactive plugins is not an error.
- The caches of `.mirai/cache` (`cache_path`) and `.mirai/thumbs` cost only time if deleted: the
  [registry](../../mirai-assets/references/formats.md#registry), the
  [textures](../../mirai-imports/references/imports.md#texture-cache), the
  [compressed animations](../../mirai-core/references/host.md#content) and the
  [previews](../../mirai-editor/references/panels.md#previews) are made again.
- **A cache never makes a valid asset fail.** An entry is keyed on everything it depends on (the
  formats and versions of what wrote it), and every read checks it against the asset: one that
  does not read or does not match, as one an older build left in a copied project, is made again
  from the asset and written over.
- `shader_generation(root)` is where a build publishes the shader generation;
  `shader_generation_find(root)` gives the one a run loads (that one, or `<root>/shaders` of a
  shipped game).

## Which packages go in

The [generator](../../mirai-core/references/generator.md) reads `core`, `engine/**`, the `runtime/`
of each active plugin and `game/` for the game and the editor; the engine's `editor/`, that of each
active plugin and that of the project, only for the editor. The collections are `project:game`,
`project:editor`, `project:plugins/<n>/<part>` and, for the engine plugins,
`plugins:<n>/<part>`.

- A folder goes in if it has some `.odin` that is not `_test.odin` and, in a plugin, if its `parts`
  declares it. Each subfolder with sources is a package, except those starting with `.` and
  `testdata`.
- A runtime package never imports an `editor/`: the game build checks it
  ([exclusion](build.md#exclusion-guarantee)).
- In the shipped game `mirai` is `<engine>` and `plugins`, `<engine>/plugins`; in the libraries,
  `mirai` is the `decl/` of the engine binaries and `plugins`, the declarations of the plugin
  libraries. Every build adds `generated` (`.mirai/gen`) and the generator's `-custom-attribute:`.

## Plugin libraries

`cook/build/plugins.odin`. Each part (`runtime`, `editor`) of an active engine plugin is a library
of its own with all its packages, one per optimization (`minimal` with `--dev`, the manifest's
otherwise), so switching from one to the other compiles nothing. The project's plugins are compiled
with the project library.

- The library goes to `project.PLUGIN_LIBRARIES` with the name those who link it look for
  (`@rpath/`, `soname` or the `LIBRARY` of a `.def`):
  `plugin-<name>-<part>-<optimization>-<fingerprint>` (`plugin_library_name`). A build that
  changes it publishes it under another name, so an editor that loaded the previous one loads the
  new one next to it; those of its family that are no longer the current one are deleted when
  nobody has them loaded. Their declarations, their stage and their fingerprint, under
  `plugins/<optimization>/`. The compiler runs in the stage with `/DEF:` without a path: Odin does
  not pass quotes in `-extra-linker-flags` and a project under a folder with spaces would not link
  ([workaround](../../../../docs/ODIN_WORKAROUNDS.md)).
  `project.PLUGIN_LIBRARIES` is the folder of all of them.
- Under `plugins/<optimization>/`: `decl/<name>/<part>` their declarations (`build.declare`, prefix
  `plugins.`), `stage-<name>-<part>/` the copy it is compiled from, with the declarations of what
  it imports next to it and at the same depth as `decl/`, and `<name>-<part>.stamp` the fingerprint
  of the last build.
- The declarations copy the body of `#force_inline`, generic or `where` procedures and declare the
  others as functions of the library, the private ones
  [only when named](#engine-binaries). An `@(private="file")` one is private in the declarations
  file and exported with the name of its file (`mirai.<package>.<file>.<name>`), so a copied body
  can call it.
- Order: the runtime parts in the order of the plugins (dependencies first) and then, for
  `Editor`, the editor ones. A part imports the runtime of its plugin (the editor one) and the
  parts of the plugins it depends on, with its own, each with all its packages. `Play` links only
  the runtime ones.
- Flags: those of the project library, with the same [modules](build.md#targets).
- Currency: the fingerprint joins its sources, the declarations of the plugins it imports, the
  hashes `engine.stamp` stores for the engine packages those sources and declarations import, the
  compiler and the flags. An engine change that declares the same compiles no plugin, and a
  changed declaration compiles only the parts that reach its package, directly or through another.
  A part that reaches a package without a hash follows every build of the engine.
- The stale ones are declared first, in order, and each compiles as soon as the ones it links are
  published; the project's, after all. They run at once up to `compilers_at_once()` (by cores and
  free memory; `MIRAI_COMPILERS` sets it) inside a single [turn](build.md#turns-between-processes).
  If one fails, the job kills the others.
- Shared cache: `<main>/.mirai/cache/plugins/`, with the most recently used `PLUGIN_CACHE_ENTRIES`.
  The fingerprint does not name the project: the sources count relative to the engine root and the
  declarations of what it imports, relative to their folder. With the same flags, all the projects
  of an engine and its worktrees share the libraries, and an [installed engine](#installed-engine)
  brings its own. A stale part is declared anyway and, if the cache has its fingerprint, it is
  copied. A project with `build.debug` does not use it: the debug information names the files of
  the build that made it.
- Loading: the project library finds them by `rpath`; on Windows `host.project_library_load` tells
  the loader the folder (`SetDllDirectoryW`). Each library is linked with its own array of
  per-thread memory cleaners of the Odin runtime (`-unexported_symbol` on macOS, `-Bsymbolic` on
  Linux): it is a weak symbol from a few places that the loader would share.

## Engine binaries

`build.engine_build({engine_root, mode, force})` first generates the engine shaders
([shaders](../../mirai-rendering/references/shaders.md); if they fail, it ends with `.Shaders`) and
compiles into `<engine>/.mirai/engine/<mode>/` once per version of sources, compiler and flags.
Each mode has its folder: switching between them compiles nothing.

- **Libraries.** `ENGINE_LIBRARIES` and `ENGINE_PACKAGES` (`cook/build/engine.odin`) are the only
  list of the libraries, of the ones each needs and of the packages each holds: the build, the
  shipped game, the installed engine and the allocation lint read it. A library is a layer of the
  [package map](../../../../docs/ARCHITECTURE.md#package-map), linked against the ones it needs,
  and the cuts are where no import goes up: what needs no renderer (`std`, `audio`, `platform`,
  `rhi`, `project`, `core`), the rest of what a game or a plugin imports, and, engine-time, `cook`
  and the editor. A package goes in the lowest library that has what it imports, and a C library
  with the package that binds it. Physics, destruction, game networking, control and cinematics
  are [plugin libraries](#plugin-libraries).
- **What crosses between libraries** is what crosses to a project: calls, with the context and
  its allocators, and data. Each library has its own Odin runtime and type table, so none looks up
  a type of another by `typeid`
  ([reflection](../../../../docs/ARCHITECTURE.md#the-generated-world)),
  and a package-level variable would be one per library that reads it.
- `decl/` has the declarations of every library, the `mirai` collection of the project libraries,
  with the `#load` relative to each declaration so the cache serves any checkout. `engine.stamp`
  stores the fingerprint of each library and of the programs and one hash per package (of its
  declarations and of those of the engine packages they import, directly or not: what whoever
  imports it compiles against).
- Programs `mirai-editor` and `mirai-player`, which load the `editor` or `play` library of the
  project ([host](../../mirai-core/references/host.md#project-libraries)), and over the editor
  library `mirai-import`, that of `mirai import`
  ([import](../../mirai-imports/references/imports.md#what-is-written)), and `mirai-author`,
  that of `mirai ui` and `mirai scene`
  ([documents](../../mirai-agent-api/references/api.md#mirai-ui-and-mirai-scene)): this way the
  `mirai` tool links neither importers nor renderer and compiles before the generated shaders
  exist.
- **Stage and declarations.** `build.declare` reads each file with `core:odin/parser` and writes
  the stage, with each procedure exported as `mirai.<package>.<name>`, and the declaration: types
  and constants as they are, generic, `inline`, `where`, `defer` or `deferred_*` procedures and
  those with an `any` in their signature (`..any`, `[]any`) with their body (they are compiled in
  the caller: an `any` carries a typeid that only the caller's type table knows, so `fmt` in the
  library would print an enum or a struct of a plugin as nothing) and the rest `foreign` towards
  the library. A private procedure is declared and exported only when the text of the declarations
  of its package names it (a copied body or value, a default value of a declared procedure): no
  other package can call it, so changing one that is not named changes no declaration. Nothing
  of the engine is recompiled with what uses it. It writes only the files whose text changes.
- **Currency by parts.** A library is recompiled by its sources (without `_test.odin`; the one
  with `render`, also by `shaders/build/manifest.json`, which gives the hash of the code it
  embeds) or by a changed declaration of a package its sources import from the libraries it needs;
  the programs, by the compiler, the flags or a changed declaration of a package they reach. A
  change in the body of a procedure compiles its library and nothing else. Before compiling a
  part, the stamp zeroes what depends on what changed: a build that stops halfway leaves those
  parts for the next one. `stage-<library>/` is what a library compiles from, with the
  declarations of the libraries it needs; a build without a stamp of its version, `--force` and a
  copy from the shared cache remove the stages.
- **Mode.** `build`, `edit`, `play` and `session start|restart` accept `--dev` (everything at
  `-o:minimal`, to check changes) or `--release` (`-o:speed`, for the CPU figures and to ship), not
  both.
  Without either, `edit` and `play` use `--release` (a person runs them); `build`, `session start`
  and `import`, the last compiled mode (`Keep`) and the manifest's optimization; `session
  restart`, that of the previous session. An agent always passes `--dev`. `build.engine_current`
  says whether `engine_build` would do nothing, without taking a turn or writing.
- **Shared cache.** `<main>/.mirai/cache/engine/<fingerprint>-<mode>/` stores libraries, programs,
  PDB, SDL3, `decl/` and the stamp, with the most recently used `ENGINE_CACHE_ENTRIES`.
  `engine_build` copies the entry of its fingerprint before compiling ("copied from the shared
  cache") and stores what it compiles.
- **Platform.** The link options of SDL3 and of each binary go in a single
  `-extra-linker-flags`, because Odin does not allow repeating it. SDL3 is copied next to the
  programs.
- **What each binary picks up.** `mirai edit`, `mirai play` and `mirai build editor` update the
  engine binaries before compiling the project. An open editor is reopened with `mirai edit`; the
  `mirai session` session of the project that runs the binaries to be replaced is closed and
  reopened by the build, and another program that runs them stops it saying what to do
  ([sessions](../../mirai-agent-api/references/api.md#sessions)). A change in `game/`, the plugins
  or the project's `editor/` asks only for the project build.
- **`mirai edit` without a project**, in a folder that is not one, opens the last project if the
  launcher asks for it (`project.Recent_Projects.open_last`) and the
  [launcher](../../mirai-editor/references/panels.md#projects) if not.
- **LLVM that does not finish.** A multiple assignment of a value of more than 64 bytes (restoring
  backups at once, a `a,b=b,a` swap of storages) makes `-o:speed` spend minutes in that procedure,
  without an error (odin-lang/Odin#7937). One value per assignment is written with the comment
  `// One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).`, and a swap of
  storages goes through `slice.ptr_swap_non_overlapping`. `mirai test cook/build` fails with those
  `store`s ([workaround](../../../../docs/ODIN_WORKAROUNDS.md)), but it does not see the split
  form. To find another case: compile with `-use-separate-modules` and inspect the compiler that
  is left alone with `sample` or `lldb` (the LLVM values name the variable), or mark in a copy of
  the stage the procedures of a file with `@(optimization_mode="none")` until the time drops.

## Installed engine

An engine is a checkout of the repository, which compiles its binaries from the sources, or an
**installed engine**: the folder that `mirai package engine --out <folder>` assembles, with the
binaries already compiled and `engine.mirai` (`project.ENGINE_FILE`) at the root. It is for whoever
makes games and does not want to compile the engine: it compiles projects and never itself. The
workflow `.github/workflows/release.yml` assembles it on each platform with a tag
`v<ENGINE_VERSION>`, tests it decompressed away from the checkout and attaches it to a draft
release of the tag; run by hand, it leaves the packages as artifacts.

- **Root.** `project.engine_root_find` is the only lookup, for the CLI, the editor and the player:
  the given one (`--engine` of the editor), `MIRAI_ROOT` or the closest folder upwards from the
  executable or from the working one that is an engine (`engine.mirai`, or `AGENTS.md` and
  `tools/mirai`). The CLI sets `MIRAI_ROOT` for its children.
- **Shape.** That of a checkout, so `engine_paths`, `decl/` and their relative `#load`s (sources,
  SPIR-V) serve the same:

  ```text
  engine.mirai           version, commit, platform, Odin and Slang it was assembled with
  bin/mirai              the CLI, without the sh launcher: it does not need Git Bash
  .mirai/engine/release/   libraries, programs, SDL3, decl/ and engine.stamp
  .mirai/cache/plugins/  libraries of the engine plugins, minimal and speed
  .deps/                 Odin, Slang and spirv-val/opt/cross; SDL3 on Linux and macOS
  core/ engine/ ...      Odin sources without tests, plugins/, third_party/freetype already built
  shaders/ templates/ assets/fonts/ editor/assets/ .agents/skills/ THIRD_PARTY_NOTICES.md
  ```

  It carries no `cook/` or `tools/`, which are in the binaries, nor the rest of `docs/`, `demo/` or
  `scripts/`.
- **Sources.** They go because the generator reads the attributes of `core`, `engine`, `editor` and
  the plugins in their sources (`decl/` does not keep `@(step)`) and `mirai build game` compiles
  the game from them in a single module ([shipped game](build.md#shipped-game)). The editor's agent
  does not read them: it works in the project and sees the engine through `decl/`.
- **What it does not do.** `engine_build` does not compile: the engine is up to date if it has all
  its binaries and, if one is missing, it fails with `Engine_Incomplete`. It brings only the
  `--release` binaries (`ENGINE_MODE_INSTALLED`): `--dev` compiles the project and its plugins at
  `-o:minimal` against them. The CLI is not recompiled, FreeType comes built and the engine shaders
  generated. `build tools`, `worktree`, `package`, `bench`, `render` and `shaders` without
  `--project` ask for a checkout.
- **Plugins.** The package brings in its cache the libraries of the engine plugins for projects
  without `defines` or `debug`, in `minimal` and `speed`, compiled by the already packaged engine
  with a project that activates them all. The compiler of an installed engine counts in the
  fingerprints by its size and `engine.mirai`, not by its date, which changes on decompression
  ([fingerprint](build.md#fingerprint)). With other flags they are compiled and stay in the cache.
- **Machine state.** Settings, recent projects, preferences, caches and locks stay in
  `<package>/.mirai`, as in a checkout: the package is portable and is decompressed into a
  writable folder.
- **Requirements.** The system linker, for the game code: Visual Studio Build Tools with C++ on
  Windows, clang on Linux, Xcode Command Line Tools on macOS; `mirai doctor` checks it. The
  binaries are not signed: on macOS the quarantine has to be removed from them.
- **Assembling.** `mirai package engine` runs in a checkout with its dependencies in `.deps`: Odin,
  Slang from `mirai setup slang`, the SPIR-V tools (Vulkan SDK on Windows,
  `scripts/setup_linux_deps.py` with `VULKAN_SDK_VERSION` on Linux) and an SDL3 the package can
  carry: that of `scripts/setup_linux_deps.py`, or on macOS that of `scripts/setup_macos_deps.py`,
  which relocates the Homebrew one with id `@rpath` and gathers the SPIR-V tools with their
  libraries. It compiles the engine `--release` and the CLI at `-o:speed`, copies, writes
  `engine.mirai` and only then compiles the plugins, whose fingerprint depends on it.
- On Windows a path of more than 260 characters is not written: the package is assembled and
  decompressed in a short folder.

## Commands

`mirai <command>` without arguments gives the usage of each subcommand. The tools of an area are in
its skill:
[Slang and shaders](../../mirai-rendering/references/shaders.md#shader-toolchain),
[assets](../../mirai-assets/references/cli.md),
[imports](../../mirai-imports/references/imports.md#what-is-written),
[images](../../mirai-agent-api/references/image.md),
[`render check`](../../mirai-rendering/references/verification.md#render-check),
[`bench compare`](../../mirai-agent-api/references/methods.md#profiling), `mirai texts`
([texts](../../mirai-plugins/references/ui-inspector.md)) and, for an open editor,
[sessions](../../mirai-agent-api/references/api.md#sessions),
[`rpc`](../../mirai-agent-api/references/api.md#mirai-rpc),
[`mcp`](../../mirai-agent-api/references/api.md#mirai-mcp) and
[`capture`](../../mirai-agent-api/references/api.md#mirai-capture). All pass the platform flags,
print diagnostics as `file(line:column) Error: message` and end with 1 if a job fails.

## Common commands

The project is the current folder if omitted; for the demo pass `demo`. The compiler, Slang and the
tools come from `.deps`, also from a worktree. Commands are written in bash (Git Bash on Windows):
from the `mirai` root it is `./mirai`, and PowerShell, cmd and Python `subprocess` use `mirai.cmd`,
by its absolute path, which hands it to Git Bash ([launcher](#tool-and-machine)).

| Operation | Command |
| --- | --- |
| Create a worktree ready to build | `mirai worktree new <name> [--from <branch>]` |
| Build and open the editor | `mirai edit [project] [--dev] [editor arguments]` |
| Build and run the game | `mirai play [project] [--dev] [player arguments]` |
| Build the editor without opening it | `mirai build editor [project] [--dev]` |
| Build the shippable game | `mirai build game [project] [--out folder]` |
| Build its dedicated server | `mirai build server [project] [--out folder]` |
| Build only the engine | `mirai build engine [--dev\|--release] [--force]` |
| Generate the world without building | `mirai generate [project]` |
| Run the content tool of a project | `mirai content [project] [-- arguments]` |
| Documents of interfaces and scenes, no editor | `mirai ui\|scene read\|write\|check ... [--project P]` |
| Git plugins of a project | `mirai plugin add\|update\|remove\|sync\|list\|catalog\|check ...` |
| Check types | `mirai check [<package> [-flag...]]`: a package relative to the working folder or to the engine, or absolute; none inside a project: its game, editor and plugins. In a runtime package it also fails on an allocation whose error nothing receives (`tools/mirai/alloc_lint.odin` says which calls and which packages), and in the runtime or editor part of a plugin on an import of `render` or `rhi` outside its tests or of the physics solver (`tools/mirai/solver_lint.odin`) |
| Run tests | `mirai test [<package>] [test\|file.odin...] [--list\|--failed\|--no-gpu\|--quiet] [-flag...]`: the package as for `check`; none inside a project: its game |
| Headless background editor | `mirai session start\|restart\|stop\|status [project] [--dev] [--copy]` |
| Call the editor API | `mirai rpc <method> [key=value...\|json] [--select c] [--wait-until c=v] [--project P]` |
| Capture without UI | `mirai capture [project] --out x.png [--reference r.png] [--repeat]` |
| Validate demo image and cost | `mirai render check [project] [--views a,b] [--quality] [--release]` |
| Measure the cost against main | `mirai bench compare [project] --base main` |
| Compare and crop images | `mirai image diff\|mottle\|stats\|montage\|crop\|zoom\|pick ...` |
| Measure only between measurements | `mirai measure -- <command> [arguments...]` |
| See who is building or measuring | `mirai locks` |
| Search the code | `rg <pattern> [folder]` |
| Check the machine and a project | `mirai doctor [project]` |
| Merge and diff assets with git, once per clone | `mirai setup git [folder]` |
| Assemble the installed engine (binary) | `mirai package engine --out <folder>` |

- `edit` and `play` without a flag compile with `--release`, because a person uses them; `build`,
  `session`, `capture` and `record` keep the mode of the engine built last (release when there is
  none); `render check` is `--dev` by itself. An agent passes `--dev`
  ([AGENTS.md](../../../../AGENTS.md#common-commands)).
- The builds of all checkouts share a few turns by themselves; do not set `-thread-count`. Tests and
  builds do not wait for a measurement: they run with low priority while it lasts.
- **Session against the editor:** `mirai session start`, then `mirai rpc` or `mirai capture`, and
  `mirai session stop`; after a change of project code, `build.start` loads it into the open
  session; after a change of engine code, `mirai session restart` (or `mirai build editor`,
  which restarts the session that holds the build); after a failure, `mirai rpc
  engine.diagnostics`. With the project open in a window, `session start --copy` drives a copy.
- **Search:** for the Odin code in `.deps`, pass its path to `rg` or `--no-ignore`. If `rg` is not
  there, `mirai setup rg` installs it pinned in `.deps` and in the PATH.
- **When handing a command to the user** to try a change, `edit` and `play` carry `--dev`; without
  a flag only if it is for measuring. From a worktree, start with a `cd` to its path from miari,
  quoted, separated with `;` and not `&&` so that it also works in PowerShell 5.1. If it compiles,
  compile it first with the same arguments, so that it tells the user "unchanged".
- **Deleting folders:** a worktree is removed with `git worktree remove`; another folder, with
  `rm -rf`, which in Git Bash deletes a junction without following it.
- Run arguments: [editor](../../mirai-editor/references/editor.md#arguments) and
  [player](../../mirai-core/references/host.md#the-player).

## Project

- `mirai new` copies `templates/<T>` (`empty` by default) to a folder that does not exist or is
  empty, and over it `templates/common`, what every template shares, which has no `project.mirai`
  and so is no template; `--list` gives the first line of the `README.md` of each template. It
  writes the project's `.gitattributes`, which no template carries
  ([git and assets](../../mirai-assets/references/cli.md#git)).
- `mirai docs [topic] [section]` and the `docs` tool of `mirai mcp` serve `docs/game` from the root
  of the running `mirai`, with or without an editor; a project keeps no copy of it.
- `mirai worktree new` creates `<main>/.worktrees/<name>` on a new branch and prints the `cd` and
  the first build. It copies nothing: `.deps` and the caches (engine binaries, C libraries, shader
  stages) are those of the main checkout ([dependencies](build.md#dependencies-and-worktrees)).
- `mirai doctor [project]` checks the machine and the project, says how to fix each finding and
  ends with 1 if there are errors. It requires `git config core.symlinks` and `.claude/skills` as a
  symbolic link to `.agents/skills`: without it, the skills do not reach the agents (on Windows
  developer mode is needed).

## Tool and machine

- `mirai setup git [folder]` wires the clone the folder is in, once per clone
  ([git and assets](../../mirai-assets/references/cli.md#git)); `mirai doctor` reports a clone
  whose `.gitattributes` names the drivers and whose configuration lacks them.
- `mirai setup path` puts the `bin/` of this copy of the engine first in the user's `PATH` and
  removes that of another copy; it is run once per copy, because a build replaces `bin/mirai` in
  place. `mirai setup rg` installs the pinned ripgrep in `.deps` and puts it in the `PATH`: it is
  what agents search with, because it respects `.gitignore`.
- **Launcher.** `mirai` (sh; Git Bash on Windows) compiles the tool only if `bin/mirai` or its list
  of sources (`bin/mirai.sources.json`, or `mirai.exe.sources.json` on Windows so that Windows and
  WSL share a checkout) is missing, and creates no subprocesses until it reaches it, because in Git
  Bash each one is expensive. It looks for Odin in `MIRAI_ODIN`, in `.deps` (its own or, if there
  is none, that of the main checkout) and in the `PATH`. It compiles aside and puts the executable
  in place by renaming the one in use (an open `mirai mcp` does not block it); if it does not
  compile, it continues with the previous one.
- `mirai.cmd`, for PowerShell, cmd and Python `subprocess` (by its absolute path: `cmd` takes a
  relative `./mirai.cmd` for a switch), runs the launcher with the `bash.exe` of Git for Windows,
  not with the `bash` of the `PATH`, which on Windows is usually WSL's; without Git Bash it fails
  and says what to install. The extensionless `mirai` is a shell script Windows cannot run.
- **Tool refresh.** On start, the tool compares those sources (without the `*_test.odin`) with its
  executable and, if any changed, it recompiles itself and runs the command with the new one. It
  compiles with `-ignore-unknown-attributes` and without `-custom-attribute`: the new sources may
  use attributes that the running build does not know.
- **C library.** The engine and editor build and `mirai test` prepare FreeType if it is not built
  with the current sources: from the shared cache, or with the host's C toolchain (MSVC on Windows;
  `CC` or `cc` and `ar` on Linux and macOS) ([cache](build.md#dependencies-and-worktrees)).

## Checks and tests

`check`, and `test` of a package of the engine, pass the attributes and the collections of Mirai:
`mirai`, and `plugins` or
`project` when the package or what it imports uses them (`project` is the closest folder upwards
with `project.mirai`); a hand-given `-collection:` wins. `check` adds
`-define:MIRAI_TEST_SHADERS=true`, which also checks the tests with generated shaders. Before that
they generate the engine shaders, which git does not store; a `-target:` of another system also
generates its backend, because the tables embed only the generated ones.

`mirai test` takes one or more packages: an argument that is a folder with Odin sources is a
package and the following ones, tests of that package; without tests it runs the whole package. It
first compiles the executables of the engine packages that need it, at once up to
`compilers_at_once()` like the [plugin libraries](#plugin-libraries) and inside a single turn, and
then runs them one after another in the order asked.

- One runner (`cook/build/tests.odin`) builds and runs every test executable, for `mirai test` and
  for `build.test`. A package of the engine compiles from its sources (its tests use internals)
  into `bin/tests/`. A package of a project (a `project.mirai` above it) is a `Test` job of its
  editor, in its turn: it compiles against the libraries the editor links, after the engine
  binaries when their sources changed, into `<project>/.mirai/build/tests/`.
- Every test executable runs in the root of the engine, also one of a project package: a relative
  path in a test is relative to the engine root (`demo/assets/...`).
- An executable compiles again only when the [fingerprint](build.md#fingerprint) of what its last
  build read changed, the `_test.odin` of every folder it read included, or its flags or the
  compiler: a date that moves or a checkout that restores the text compiles nothing. The last
  line says how many executables were built and how many stood.

- Names are looked up among the `@(test)` of the sources before compiling: one that is not there
  cuts the command with 2 and names the similar ones. They reach the executable as `-tests:`, so
  asking for other tests does not compile.
- An argument that ends in `.odin` asks for the tests of that file: the name of a file of the
  package before it, or a path to one. A file that is not there or declares no test cuts the
  command like a wrong name.
- `--no-gpu` leaves out the tests of the files that reach the device of the GPU tests. A test
  reaches it when it names `rhi/shared_device` or `rhi.device_create`, itself or through the
  declarations of the test files of its package; it is read from the text, like the names, so a
  GPU test takes the device in its test files and not through what is no test. `--list` takes the
  files and `--no-gpu` too, and shows what would run.
- A package with no test to run (it declares none, or `--failed` or `--no-gpu` leave none) is not
  compiled: it is named in one line and is no failure, also when it is the only one asked.
- `--failed` runs those that failed last time in the package: each run removes the ones that ran
  and adds the ones that failed.
- A package that does not compile is named in its place, with what the compiler said, and the
  others run.
- Its threads reserve 8 MB of stack on every system (`TEST_STACK_FLAG`: Windows gives 1 MB),
  unless the flags of the call bring linker flags of their own.
- If no test starts or ends within `--timeout` (`TEST_TIMEOUT`; 0 does not watch; a benchmark only
  with `--timeout`), `mirai test` kills the executable and names the ones that were running; also
  if it crashes before the summary. It knows it through `ODIN_TEST_LOG_STATE_CHANGES`: a flag that
  turns it off turns the watching off.
- A run that is not a benchmark does not wait for a measurement: while one runs, it goes with low
  priority ([turns](build.md#turns-between-processes)).
- It compiles at `-o:minimal` and runs without a window. The CPU suites of the data core and of
  gameplay (tables, generator, scene, saves, input, cinematics, physics, destruction, GUI,
  animation, audio, frame and assets of the host, API protocol) run together with `mirai test core
  cook/build engine/scene engine/save engine/input std/input plugins/cinematics/runtime
  plugins/physics/runtime plugins/physics/runtime/sim
  plugins/destruct/runtime plugins/destruct/runtime/fracture engine/gui std/anim audio host
  editor/api`; `host` includes GPU tests and `editor/api` uses loopback sockets.
- **CI.** `.github/workflows/checks.yml` runs on every pull request to `main`, on Windows without
  GPU (`MIRAI_ALLOW_GPU_SKIP=1`): `mirai check` of each folder with Odin sources outside
  `third_party` and `templates`, and `mirai test` of the CPU suites it lists. A
  suite enters the list when it passes on `main`.

## Paths in Git Bash

An argument or a variable that starts with `/` reaches a native program as a Windows path
(`/tmp/x` → `C:/Users/.../Temp/x`); to pass a POSIX path (`wsl`, `docker`), prefix
`MSYS_NO_PATHCONV=1`. Inside the JSON of `mirai rpc` there is no conversion: the editor API reads
`/c/x` and `/cygdrive/c/x` as `C:/x` (`project.path_native`) and rejects a path with a root and
without a drive (`/x`, `\x`).

## External scripts

What is external to the engine (preparing dependencies, benchmarks, reports) are `scripts/*.py`:
self-contained Python (PEP 723, with the header of the existing ones) run with `uv run
scripts/<script>.py`, without a `.venv` in the repo. A script uses `mirai` or the editor API like
any user and nothing in the engine depends on them; bash remains only in the launcher.

- The frame cost against the base is measured by `mirai bench compare`, without pair scripts;
  `scripts/bench_compare.py` is for another measurement the user asks for, whose table goes in the
  task's final report.
- A script that measures times runs with `mirai measure -- uv run scripts/<script>.py`
  ([turns](build.md#turns-between-processes)); `mirai measure -- ./mirai <args>` also works on
  Windows, with the Git Bash of `mirai.cmd`.
- `scripts/check_docs.py` checks the documentation: links and anchors, frontmatter, line width,
  repeated headings, files and tests it names, the skill table of `README.md` and the import of
  `AGENTS.md`. Its rules are tested by `scripts/tests/test_check_docs.py`.
- `scripts/video_frames.py` takes the frames (a labelled strip like those of `play.capture`) and
  the sound of a section of a YouTube or X video, or of a file, to compare with Mirai captures. It
  needs Windows, and what it downloads stays in `.mirai/tmp/video_frames`, never in git.

## ACP agents

`mirai agent` installs and manages the ACP adapters of Codex and Claude in the user folder of the
machine (`project.agents_folder`, `<user data>/Mirai/Editor agents/<agent>/`, or `--home`), outside
every project and checkout; the client, the user's installation that goes first and the history
are in [AI tasks](../../mirai-editor/references/ai-tasks.md#connections-and-installation). It runs
only by an explicit action: opening Mirai or a chat downloads nothing.

- The packages come from the public npm registry even if npm or Bun have another configured.
  `Automatic` chooses Bun, Node or pnpm, whichever is available, in that order, without downloading
  any. With `pnpm` the client runs `mirai-acp` with `--silent` to reserve stdout for ACP.
- Claude is installed without optional dependencies with Bun and Node, because it uses the user's
  Claude Code; `--claude-code` first runs Anthropic's official installer.
- Each installation is prepared in a temporary folder next to the destination and published when it
  ends; on error or cancellation (`--cancel-file`) the previous one stays, and the editor waits for
  that end.
- `installation.json` stores version, runtime and `codex_binary`, the official Codex binary the
  adapter receives as `CODEX_PATH` if the user has none of their own.

## Templates

Choice and content of each template:
[demo and templates](../../mirai-gameplay/references/demo.md#templates).

## Known limits

- The assets of a plugin are reloaded in an open editor only with `assets_scan`: the watching looks
  at the project folder.
- Only the engine plugins have a library of their own. The first build of the plugin libraries is
  slower than that of a single library.
- The plugin libraries were tested on macOS and Windows; on Linux, not run.
- Those of the build, cooking and shaders: [build](build.md#known-limits).
