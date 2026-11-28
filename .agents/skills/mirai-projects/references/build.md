# Project build: `cook/build`

Generates worlds, compiles project libraries and executables, compiles project shaders, cooks
assets, and assembles shipped games. See [engine binaries](projects.md#engine-binaries) and
[packages](projects.md#which-packages-go-in).

## Targets

`world_write_files(&p)` writes changed generated packages to `.mirai/gen/`.

- **`Editor`:** Exports `mirai_project_info` over `gen/editor_world` as `-build-mode:dll`
  (`.mirai/editor<ext>`), linking engine `decl/` and
  [plugin libraries](projects.md#plugin-libraries). Loaded by `mirai-editor` and `mirai-player`
  (`mirai play`, `player.start`). `Size`/`Speed`/`Aggressive` compile as one LLVM module
  (cross-package `#force_inline`); `Minimal`/`None` use `-use-separate-modules`
  (`library_optimization_append`).
- **`Game`:** Standalone `main` calling `host.player_run` over `gen/shipped_world` (no
  `development` plugins), compiling engine + plugins + game from source (`-o:speed` with
  `--release`, else `-o:minimal`) into `.mirai/game` or `--out`. `Desc.server` builds the
  [dedicated server](#dedicated-server) (`.mirai/server`).

- **`Program` action (of `Editor`):** a `package main` of the project (`tools/content`) built as
  a test executable is (`test_build_plan` with `tests=false`, probe flags, fingerprint) into
  `.mirai/build/programs`; `mirai content` runs it in the project root with
  `program_environment`. `Check` with `package_folder` checks that package alone
  (`mirai check <project>` does it for the content tool).

## Flags and environment

- All targets/checks/tests apply manifest `defines` (engine libs take only `#config` ones),
  `platform_flags`, `MIRAI_ODIN_FLAGS`, `Desc.flags`, and `platform_environment`. SDL3 resolves from
  `.deps/linux-amd64/sdl3` (Linux), `.deps/macos-arm64/sdl3` or Homebrew (macOS), or compiler
  `vendor/sdl3` (Windows).
- **Compiler memory cap (`compiler_memory`):** Half of RAM by default; `MIRAI_COMPILER_MEMORY`
  sets GiB (`0` = uncapped; unsupported on macOS, reported by `mirai doctor`). LLVM OOM fails with
  `Out_Of_Memory` (hints odin-lang/Odin#7937 and `no_store_of_an_aggregate_of_more_than_64_bytes`);
  hard OOM (`0xC0000005` on Windows) reports exit code and cap hint.
- **Tools:** Compiler from `Desc.compiler`, `MIRAI_ODIN`, `deps_folder(root)`, or `PATH`. Slang and
  SPIR-V tools come from `deps_folder(root)` (`mirai setup slang`).

## Dependencies and worktrees

`cook/workspace` resolves shared paths via `project.shared_root(root)` (main checkout of a
worktree):

- `deps_folder(root)`: `<root>/.deps`, else main checkout's `.deps`.
- `cache_folder(root, name)`: `<main>/.mirai/cache/<name>` (FreeType keyed by `<library>.key`,
  engine/plugin libraries, shader stages). New worktrees copy nothing.

### Turns between processes

OS-released locks live in `<main>/.mirai/cache/locks/` (`<lock>.owner` shown by `mirai locks`).

- **Build turns:** Up to 4 (`build.lock`, `build-1.lock`..., 1 per 2 physical cores, extra turns
  require 4 GB free) + `.mirai/build-turn.lock` of each folder it writes: the engine's only while
  engine binaries build (`project_engine_ready`) or a game compiles the engine from its sources,
  the project's for its libraries, tests and content tool, so two projects build side by side
  (`two_projects_build_side_by_side`). `shaders.lock` is independent. Commands
  check currency unlocked (`engine_current`, `shaders_current`, `target_state`) and print
  "unchanged" without waiting (`build game` always locks). `workspace.builds_since` detects builds
  during measurements; editor builds neither lock nor annotate.
- **Measurement turn (`measure.lock`):** Exclusive across checkouts (`mirai measure`, benchmark
  `mirai test` with `BENCH` define, `bench compare`/`flight`, `render check` without `--quality`,
  `profile.capture` with `advance`). Non-GPU builds/tests run at `subprocess.Priority.Low` without
  waiting; non-user GPU work waits (`workspace.measured`). `workspace.gpu_load` reports concurrent
  load. `MIRAI_MEASURE` propagates membership to child processes and `mirai rpc`.
- **GPU turns (`gpu-<n>.lock`, max `workspace.GPU_TURNS`, under `gpu.lock`):** Admits one process
  no person runs at a time (`GPU_AGENTS`; a measurement's own editors run together), beside
  persons' turns whose VRAM charges fit the card (`gpu/card`, per-project peaks in `gpu/peaks/`)
  minus desktop headroom (`gpu_admits`; first turn always admitted). Waiters queue first come,
  first served by a ticket lock each in `gpu-queue/`; a ticket or a turn whose process ended is
  skipped, and the wait names the holders, for how long, and the waiters before it. Dedicated GPU
  outranks integrated; mismatched non-`MIRAI_GPU` sessions close with reason. Editors inherit
  turns via `--gpu-turn` (`lock_hand_over`) and auto-close after `api.SESSION_IDLE`. User windowed
  `edit`/`play` never waits. Measurements take GPU turns *before* `measure.lock` (`measure_try`
  marks own turn idle) so deadlocks cannot occur and `bench compare` runs both editors together;
  a turn of a measurement that already holds one does not queue.
- `bin/mirai` self-refresh serializes via `bin/.refresh.lock`.

### Implicit Vulkan layers

`mirai test` and `--headless` runs point `VK_IMPLICIT_LAYER_PATH` to an empty cache folder to block
broken overlays (Epic/Steam/OBS). Set `MIRAI_KEEP_LAYERS=1` to keep them.

## Jobs

```odin
import "mirai:cook/build"

job := build.job_start({project=&p, target=.Editor})
for !build.job_poll(job) { /* next frame */ }
res := &job.result
defer build.job_destroy(job)
```

- `Desc`, `Result`, `Status`, `Failure`: `cook/build/build.odin`. `job_destroy` cancels active work
  and frees `Result`. `target_state` checks staleness without writing.
- After target compile/up-to-date, the job refreshes pinned packages via `mirai-import` before
  completing; `job_cancel` kills compiler + import trees, leaving prior output intact.
- `Result.diagnostics` holds `-json-errors` + generator warnings; `Result.text` holds unstructured
  output (linker). Compile or `Engine_Time_Code` failures never publish; `Game` `Copy_Failed`/
  `Cook_Failed` leave the executable published and re-run on next job.

## Outputs

Compiles to `.mirai/build/<target>-<moment>-<pid>.*` and atomically renames into place (Windows
renames busy files to `.old` for later cleanup; `-debug` `.pdb` stays until next build). Each job
cleans its own temp files; only a successful compile sweeps other jobs' files older than
`STALE_AFTER`.

## Fingerprint

`<target>.sources.json` and `<target>.stamp` (`cook/build/compiler.odin`) hash compiler size+mtime
(or size + `engine.mirai` for [installed engines](projects.md#installed-engine)), flags except
`-thread-count:N`, engine-relative paths, and CR-stripped contents of `.odin` (excluding
`*_test.odin` except for test executables) and `#load` files.

- If a source mutates after compile start, no stamp is saved.
- `Game` with a new `--out` and matching fingerprint copies the executable without recompiling.

## Project shaders

Compiles `<project>/shaders/` + active plugin `shaders/` into `project.shader_generation(root)`
([rendering](../../mirai-rendering/references/shaders.md#project-generation)).

```odin
job := build.shaders_start(&p)
for !build.shaders_poll(job) { /* next frame */ }
res := &job.result
build.shaders_destroy(job) // waits if still running
```

- `first` stages build early (`shaders_first(job)`); `shaders_cancel` kills compilers (`Cancelled`).
- Transactional: failure/cancel preserves prior generation; `None` deletes any old generation.
- Missing Slang/SPIR-V tools or `engine_root` fail with install guidance. `mirai build editor`
  exits 1 on shader failure; `edit`/`play` report and continue.

## Shipped game

`Game` output (`Desc.output` or `.mirai/game`) receives: executable, `project.mirai`, `icon`,
merged `settings.mirai`, cooked `assets/` (project + `assets/plugins/<name>/`), compiled `shaders/`
(no Slang sources), SDL3 if needed, `.mirai/cache` scene capacities and `render_features`.
Replaces `assets/` cleanly (no raw sources); skips code, `cook.mirai`, and `plugin.mirai`.
`mirai play` copies nothing.

- `shaders/` leaves out the code of `abi.TOOL_STAGES` (the manifest keeps their entries without
  files) and their program stages; the renderer never starts with Tools in a player.
- `render_features` lists what every material of the project draws of Glass and Decals, with the
  values scenes give it (`program_uses`, `abi.material_features`); the player starts without the
  others and makes them in the frame that first needs one (a material made at run time). `Decal`
  entities of the `decals` plugin draw no decal material and are not counted: a game whose only
  decals are those makes the decal pipelines in the first frame that shows one.
- A game without `.mirai/shaders/manifest.json` runs the shaders embedded in its executable, and
  still leaves the pipelines of Tools for later (`Renderer_Desc.later`).

## Dedicated server

`mirai build server` ships the `Game` executable (reused by fingerprint) for `--dedicated`
([player](../../mirai-core/references/host.md#arguments)), omitting icon, `shaders/`, and
`presentation` asset kinds (textures, sounds, UI, fonts, prompts), while keeping `settings.mirai`
and SDL3.

```sh
./mirai build game demo --release --out bin/demo-ship
./mirai build server demo --out bin/demo-server
```

## Imported sources

Imported assets live in a content-addressed store (`store.default_root` or `--store <dir>`, passed
to `Desc.store_root`, `mirai-import`, cook, editor, and player).

- Every project build refreshes `packages.mirai` (`job_imports`/`build.imports_refresh`) using
  `mirai-import`: checks local store -> `--from` / installed engine `builds/` -> local source
  ingest (`Import_Failed` if unavailable). Dev accepts Fast imports; `mirai build game --release`
  requires Final.
- Asset path literals of `project:` code (`Generated.asset_refs`, extensions of `asset.KINDS` and
  the active plugins' `asset_kinds`) are checked only after that refresh (`job_target_done`), and
  by a check of the project after `odin check`: `Asset_Paths` with `file(line:col)`. Generation,
  `refresh_skip` builds (`mirai import`, `join`), tests and `mirai content` never read assets, so
  what makes an asset the code names builds first. `library_current` re-checks
  (`build.asset_paths_check`) so a current library does not hide a missing asset.
- Store-only machines build and ship without raw sources. Cooking writes resolved assets + `.index`
  as loose container files so shipped games never open a store.

## Asset cooking

`cook_assets` (`cook/build/cook.odin`) writes reachable game assets (failure: `Cook_Failed` with
`Result.cook.error` + `detail`).

```json
{
  "roots": ["surfaces/metal/Chrome.mat", "characters/player/",
            "3b4cb4195321a2f7fe61aa57ece0c255"],
  "textures": "blocks",
  "retargets": [["characters/npc/npc.character", "characters/guard/guard.mesh"]]
}
```

- **Roots & plugins:** Every `.scene`, prefab, `.records`, `.strings`, asset path literal of
  shipped code (`Asset_Ref.shipped`: not `editor/` or a `development` plugin;
  `Cook_Desc.code_roots`), `cook.mirai` (`COOK_FILE`: `assets/` paths, trailing-`/` dirs, or asset
  IDs), and all plugin `assets/` files (minus package sources) mounted at `plugins/<name>`.
  Errors: `Root_Missing`, `Manifest_Invalid`, `Package_Missing`, `Source_Failed` (Fast texture
  in release), `Duplicate_Id`, `Resolve_Failed`.
- **Scope & transforms:** Transitive dependencies (`dropped` / `missing` reported); parallel worker
  cook (deterministic order; `Balanced` in dev `quick`, `Ultra` in release).
  - *Textures:* `"blocks"` (default) BCn-encodes RGBA8 (UI-only copied), cached by `content_hash`;
    `"keep"` copies raw. Release requires Final.
  - *Animations:* Pre-compressed via `asset.animation_compress`. Each `.anim` a scene or prefab
    plays (`Animation` asset, library or `.character`) on a `Mesh_Renderer` of another skeleton
    gets its retarget beside it, `<anim>.<skeleton id>.anim` (`retargets_cook`,
    `asset.animation_retarget_cooked`), and so does each `retargets` pair of `cook.mirai` (an
    `.anim`/`.character` and a `.skeleton`/`.mesh`, both shipped as roots); pairs that fail are
    listed as `unretargeted`.
  - *Prefabs / Far / Collision:* Resolves stale prefab instances (`asset.Prefab_Resolver`), emits
    `<scene>.far.mesh` when `streaming` is active (`Cook_Desc.far`), and bakes `Auto` dynamic mesh
    convex pieces (`asset.mesh_pieces_put`, `Cook_Desc.collision_cache`).
  - *Compression & check:* Respects `build.compression` (`document_repack` `SHIP`, skips RDO if
    `"none"`), writes `.index` (`asset.REGISTRY_INDEX`), verifies ID/type/hash on readback, removes
    stale outputs, and skips unchanged files via `Cook_Desc.keys` (`COOK_KEYS_VERSION`).

## Exclusion guarantee

Before publishing `Game`, `engine_time_packages` inspects `-export-dependencies:json` for engine
`editor/`/`cook/`, `plugins/*/editor/`, project `editor/`/editor gen, and `development` plugins,
failing with `Engine_Time_Code` on any match. Because Odin parses `_test.odin` imports too,
runtime package tests must not import engine-time packages (GPU tests use `package_test_shaders`).

## Known limits

- Cooked assets ship as loose files with `.index` (not packed into a single archive).
- Assets only a path the code formats at run time names (`fmt.tprintf`) are not cooked unless
  `cook.mirai` roots them.
- First project shader build or Surface code edits recompile all material stages (metadata-only
  edits skip stages; PostProcess compiles one stage).
- `shaders_destroy` and editor exit wait for an active shader generation instead of cancelling.
- Removing all project shaders leaves old `shaders/` in an already-shipped output folder.
- Windows shipped games build as console executables.
