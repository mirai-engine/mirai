# Shaders (`cook/shaders/`)

Single Slang source in `shaders/`; generated outputs (`shaders/build/`, `render/shaders_gen.odin`,
`rhi/shaders_gen_test.odin`) are untracked. `cook/shaders` (`shaders.generate(Options) -> Result`)
drives builds and editor hot-reload; `mirai shaders` (`tools/mirai/shaders.odin`) is its CLI.
`build.engine_build`, `mirai check`, `mirai test`, and `mirai build game` run it automatically
(no-op when current).

## Shader toolchain

## Tools

- `mirai setup slang [--archive <file>]` installs pinned `SLANG_VERSION` (SHA-256 verified) into
  `.deps/slang/`, keeping the previous install until complete. `MIRAI_SLANGC` / `MIRAI_SLANG`
  override it; older compilers trigger auto-install or fail with version + update instructions
  (env-pinned ones are never overwritten). `mirai doctor` reports the active version.
- Requires precompiled `spirv-val`, `spirv-opt`, and `spirv-cross` (Vulkan SDK; macOS:
  `brew install --force-bottle spirv-tools spirv-cross`), resolved in `.deps/` then `PATH`.
- `mirai shaders --project <path>` includes active plugin `shaders/` (`build.shader_sources`)
  and compiles Surface programs for project asset uses (`build.shaders_uses`).
- **Compiler workers:** Generation spawns `mirai shaders compiler <slangc>` processes
  (`runner_close`) that load the Slang shared library once and run sequential requests with
  byte-identical `slangc` output/reflection while isolating Slang crashes.

```sh
# Install Slang, compile project shaders (or all backends), and check a program:
mirai setup slang
mirai shaders --project demo
mirai shaders --backends all
mirai shaders check templates/empty/shaders/pulse.slang --project demo
```

## Compilation

- **Targets & flags:** Column-major, `sm_6_5`, SPIR-V 1.5 (Vulkan 1.2), Slang `-O0` +
  `SLANG_FLAGS` (`spirv-opt` `-O3` passes minus first redundancy pass), `-fvk-use-scalar-layout`
  (matches Odin/Metal flat ABI; requires `scalarBlockLayout`, validated by
  `spirv-val --scalar-block-layout`).
- **Metal:** Same SPIR-V -> `spirv-opt -O --strip-debug` (avoids MSL keyword collisions like
  `ray_data`) -> SPIRV-Cross MSL 2.4 (`--msl-decoration-binding`, set 1 argument buffer,
  [table](rhi.md#bindings-and-texture-table)). Stages with `OpImageTexelPointer` emit MSL 3.1
  (RHI sets `ShaderAtomic` on `R32_Uint` storage textures).
- **Shared ABI & constants:**
  - `SHARED_STRUCTS` (`cook/shaders/layouts.odin`): every variant must match layout;
    `render/shaders_gen.odin` emits `#assert` for `size_of` and every `offset_of` (`Frame_Data`
    checked up to `batches`).
  - `include/material_schema.slang` is generated from `mirai:asset` (`Material_Map_Kind`,
    `Alpha_Mode`, `MATERIAL_DEFAULTS`).
  - `include/shared_constants.slang` (`cook/shaders/schema.odin`) mirrors constants from
    `render/abi`, `asset`, and `rhi`. No `.slang` file may redefine them
    (`no_shader_source_defines_a_constant_the_generation_writes`).
  - Plugin/project constants: `//! mirai constant <NAME> <int|uint|float> <file.odin>`
    (`owned_constants` in `cook/shaders/extensions.odin`) generates
    `include/constants/plugins/<name>.slang` (or `project` for project); stamp tracks the Odin
    file.
- **Local memory:** Stages inline all calls; dynamic-indexed local arrays inflate driver
  `outside_bytes` (`profile.gpu_memory`) across every thread. Share non-nested scratch via
  `static` include arrays, read struct arrays from buffers (`material_of`), and accumulate
  inline (`polygon_projected_angle`).
- **Constants vs variants:**
  - `//! constant <name> <DEFINE>` (`native.slang`): specialization boolean (`if (DEFINE)`,
    `<STAGE>_<NAME>`, `pipeline_of`) with zero extra shader compilations. Bound resources need a
    stand-in when off; shared headers guard with `#ifdef DEFINE`. Startup builds mandatory sets
    (`pipelines_list`); `optional` sets (`unlayered`, `color`) build via `pipeline_variants_ask`
    on `pipeline_thread` (frame falls back or skips with `Stats.problem` if unready).
  - `//! variant <name> <DEFINE>...`: separate compilation (`<stage>_<name>`) only when device
    interface changes (`hw` ray queries, `clip` distance, fragment outputs `plain`/`layers`/
    `values`/`impostor`, `batches`, `sharpen`).
  - Non-`hw` bases of `hw` stages and `//! software rays` skip Metal codegen (Metal traces HW
    only; [RHI](rhi.md#hardware-ray-tracing)) and run reflection-only (`reflected_only` cache).
    SPIR-V validation does not certify GPU execution.

```slang
// Stage directives for specialization constants, variants, per-program stages, shared consts:
#include "native.slang"
//! constant unlayered MIRAI_GBUFFER_NO_LAYERS
//! variant hw MIRAI_HW_RT=1
//! per surface program opaque blend
//! mirai constant MY_LIMIT uint ../runtime/my_plugin.odin
```

## Backends of a generation

- Default builds only `HOST_BACKEND`; `--backends all` (`Options.backends`) verifies
  cross-backend compilation; `mirai check <pkg> -target:<sys>` requests that target's backend.
- Odin tables embed compiled backends only (uncompiled branches `#panic` asking for
  `mirai shaders --backends all`). Backend bytes are identical whether built alone or together.

## Programs

Every program declares `//! mirai surface|postprocess|vfx|ui Name` and `//! parameter field {json}`
(`group` sets Details card); parameters pack into a fixed reflected block.

| Domain | Contract & key helpers |
| --- | --- |
| Surface | `mirai_material.slang`: `evaluate(Mirai_Surface_Context, Parameters)`, optional `//! vertex [reach <m>\|<param>]` + `vertex(...)` ([vertex functions](materials.md#vertex-functions)). `mirai_surface_standard`, `mirai_surface_mix`, `mirai_noise`, `mirai_sample_triplanar`, `mirai_height_blend`, `origin.slang` (`origin_phase`/`wrap`/`lattice` with `ORIGIN_STEP`). Duals (`mirai_dual.slang`, `mirai_uv0`/`uv1`/`world_position`/`vertex_normal`) avoid quad re-eval (`mirai_program_derivatives`). `mirai_sample_texture_projected` works in branches and rays; `mirai_sample_texture_level`/`mirai_texture_size` pin all mips; `mirai_load_texture` skips residency. `surface_probe` computes `abi.Program_Reads` (time, view, place, particle). `ctx.view_direction` points at the eye of the view (also for a ray hit); `ctx.scene_depth` set on blended passes; `ctx.particle_*` (`data`, `given`, `random`, `radius`, `color`, `life`) set on sprites and blended mesh particles, where `ctx.vertex_color` stays the mesh's (white on quads). |
| Vfx | `mirai_vfx.slang`: `Attributes` (`<= ATTRIBUTE_BYTES`), `initialize`, `update`, `render`, optional `//! moves`, `//! births` (`births`), up to `PROGRAM_RESOURCES` `//! resource <name> surface\|channel\|grid\|emitter\|data words` (`mirai_vfx_surface_*`, `_channel_*`, `_grid_*`, `_emitter_*`, `_data_*`), up to `MAX_STAGES` `//! stage <name> over particles\|<res> [iterations N]` (`mirai_vfx_particle_stage`/`_cell_stage`). `mirai_vfx_texture`, `mirai_vfx_random`, `mirai_vfx_trace` (opaque hits outside `render`). Example: `Orbit` (`plugins/vfx/shaders/orbit.slang`). |
| PostProcess | `Mirai_PostProcess_Context`, `mirai_scene_color`/`depth`/`normal`, `mirai_outline` (`Mirai_Outline`). Builtins: `Blur` (`shaders/materials/screen_blur.slang`), `ColorGrade` (`shaders/materials/color_grade.slang`). |
| UI | `evaluate(Mirai_Ui_Context, Parameters)` -> straight-alpha display color; receives 4 node floats (16 bytes, no catalog defaults). Builtins (`shaders/materials/ui_*.slang`): `Ui_Radial_Wipe`, `Ui_Dissolve`, `Ui_Shine`, `Ui_Gradient_Sweep`, `Ui_Slant`, `Ui_Polygon`, `Ui_Radial_Gradient`, `Ui_Rays` ([UI](ui.md#ui-world-panels-and-debug-lines)). |

```slang
//! mirai vfx Spark_Drift
//! parameter speed {"default":2,"min":0,"max":50}
//! resource hits channel
namespace Spark_Drift {
struct Parameters { float speed; };
struct Attributes { float phase; };
void initialize(
    Mirai_Vfx_Context ctx, Parameters p,
    inout Mirai_Vfx_Particle pt, inout Attributes a
) { a.phase = mirai_vfx_random(pt.seed) * 6.2831853; }
void update(
    Mirai_Vfx_Context ctx, Parameters p,
    inout Mirai_Vfx_Particle pt, inout Attributes a
) {
    a.phase += p.speed * ctx.delta_time;
    pt.velocity.y += sin(a.phase) * ctx.delta_time;
}
void render(
    Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle pt,
    Attributes a, inout Mirai_Vfx_Visual v
) {}
}
```

## Programs and stages

- **Domain includes:** `include/surface_programs.slang` (no-program stub) + per-program
  `include/surface/<Name>/surface_programs.slang`; `include/postprocess_programs.slang`;
  `include/vfx_programs.slang` (included by `particle_programs.slang`, `PARTICLES_WRITABLE`);
  `include/ui_programs.slang` (`ui.frag`). No program alpha include: `alpha_probe` flags
  `coverage` in catalog, and masked materials whose program writes alpha error with `Coverage`.
- **Stage expansion:** `//! per surface program <uses>` (`abi.Program_Use`: `opaque`, `blend`,
  `overlay`, `mesh`, `particle_sprite`, `preview`, `impostor`, `decal`; `<variant>=<use>`,
  `only`) emits `<root>__<Program>[_<variant>]<suffix>` for matching programs;
  `//! per vertex program` emits `surface_vertices.comp` for vertex-moving programs only.
  Editing a program recompiles only its domain stages (never tracing, visibility, or shadows).
- **Program uses (`build.program_uses`):** Inferred from project materials, overlays, plugin
  `program_uses` (`.particle`, `.pcg`), `//! use <uses>`, and editor on-demand `preview`
  (tests build all uses). Missing runtime use falls back to plain stage and reports
  `Stats.problem` with the `//! use` line to add (`renderer_programs_missing`).
- Program IDs are consecutive across domains in file order (engine, project, plugins).

## Inputs and outputs

- `--project <path>` adds `<path>/shaders`; `Options.sources` adds plugin `shaders/` under
  `include/programs/plugins/<name>/`. Project default output is `<project>/.mirai/shaders`
  (`PROJECT_OUTPUT`, never writes Odin tables). `--output <path> --no-odin` writes loadable
  `catalog.json` + manifest (`shader_assets_load`).
- Engine generation compiles RHI test shaders (`rhi.TEST_SHADERS` / `MIRAI_TEST_SHADERS`,
  `test_shader`), writes `@(rodata)` `render/shaders_gen.odin` and `rhi/shaders_gen_test.odin`,
  and packs code into `shaders/build/shaders.spv.lz` / `.metal.lz` (MDC2 `PACK_EDIT` or `SHIP`,
  `shaders_packed`, decoded once by `embedded_shaders_decode`). Code-only edits leave
  `render/shaders_gen.odin` unchanged.
- `Renderer_Desc.shaders` loads at startup; `renderer_reload_shaders` swaps live.

### Texture cook shaders

- Engine generation builds `shaders/cook` into `shaders/build/cook` (shipped in installed engine
  for cooker). BC6H/BC7 share tables with asset decoders.
- `cook/textures.Gpu_Context` encodes all mips/layers in one immediate transaction. Final cook
  with positive lambda runs a second threadgroup pass searching causal neighbors to price
  endpoint and selector reuse against decoded error; BC7 preserves exact alpha extrema and
  cutoff side.
- GPU benchmark (`bin/bench/gpu-bcn-polish.csv`):
  `mirai test cook/textures bench_gpu_blocks_on_demo_textures -define:COOK_GPU_BENCH=true`.

## Cache and fingerprints

- **Shared cache (`cache.odin`):** `<main checkout>/.mirai/cache/shaders`
  (`workspace.cache_folder`), shared across worktrees/projects: `stages/<fp>.json/.spv/.metal`
  (`.reflected.json` separate), `reflection/<fp>.json/.attributes.json`,
  `embedded/<digest>.edit|ship.spv|metal.lz`, `peaks/<stage>`, and `compiling`. Writes are
  atomic (`.json` last), hash-verified on read, and pruned of 30-day-unused entries once daily
  (`pruned`). Per-output `generation.json` uses `<cache>.lock`.
- **Declaration-level fingerprint (`cook/shaders/declarations.odin`):** Tool versions/flags,
  binding ABI, `GENERATOR_CONTRACT`, own source, and only reachable declarations from transitive
  includes (`__LINE__`/`__COUNTER__`/raw strings/binary modules take full file; `##` not
  followed). Backend- and checkout-independent.
- **Per-stage `extensions.slang`:** Defines only macros the stage's dependencies name
  (`MIRAI_NESTED_VIEWS`, `MIRAI_INSTANCE_IDS`, `MIRAI_HOOK_RAY|LIGHTS|PROBES|VERTEX`,
  `MIRAI_FRAME_EXTENSIONS`, `MIRAI_FRAME_NESTED`). Unused includes waste recompiles
  (`common.slang` names none; `depth.slang`/`pixel.slang`/`probe_light.slang` are opt-in).
- **Refused programs & metadata edits:** Failing programs cache `<fp>.refused.txt` (cancelled
  runs do not). Project/plugin failures go into `Result.refused` without blocking others; engine
  failures fail generation. Compilation hash strips `//! parameter` comment lines (preserving
  line numbers), so default/range/color edits republish catalog without recompiling.
- **Parallelism & memory admission:** Default 1 worker/CPU (`--workers`, max 64). Each compile
  is charged its cached peak (`peaks/<stage>`, else largest known / `SLANGC_PEAK_BYTES`) against
  free RAM minus `MEMORY_RESERVE` and in-flight charges across processes (`compiling`),
  scheduled largest-peak first.

## Early stages and cancellation

- `Options.first` (`thumbnail.frag`) compiles first and publishes a loadable partial generation
  to `Options.first_output` (`Progress.first`).
- `Options.idle` compiles last; once active stages finish, `Options.active_output` publishes
  (`Progress.active`, skipped if no idle stages).
- `cancel(&progress)` kills running compilers and exits with `Result.cancelled` without
  publishing.

## Generation without changes

`generation.json` records request, tools, source hashes, missing includes, and outputs. Matching
generations skip all compilers (`Result.current`, prints `up to date`; lockless
`shaders.current`).

## Publication

- Staged atomic directory swap with rollback on failure (keeps previous generation intact).
- Executables embed `SHADERS_INTERFACE` (`engine_interface`: contract, ABI, shared structs,
  per-stage kind/workgroup/bindings/constants). `shader_assets_load` rejects mismatches; edits
  preserving the interface hot-reload via `mirai shaders` or `mirai build editor`, while
  interface changes rebuild `render` and restart the editor.

## Diagnostics

`slang_diagnostics` parses Slang diagnostics into `Diagnostic` mapped back to original source
paths (`Result.diagnostics`, `error`).

## Check of a program

`program_check(Check_Options) -> Check_Result` (`check.odin`) validates any domain without
publishing (`material.program.check`/`create`/`edit`,
`mirai shaders check <program.slang> [--project <path>]`, exit 1 on errors):

- **Compile:** `-O0` in temp dir after reflecting `Parameters` (`Attributes` + resources in
  Vfx). Surface checks fragment + compute (`ctx.ray`); PostProcess/UI check `CHECK_STAGES`; Vfx
  checks `//! per vfx program` plugin stages (warns `mirai.stages` if none).
  `undefined identifier` receives Slang/API `fix` suggestions.
- **Rules (`mirai.<rule>` on [derived graph](materials.md#derived-graph)):** Errors on bad
  headers/signatures (`ENTRIES`), Vfx `//! resource`/`//! stage`, own texture objects, GLSL API,
  mismatched/unpacked parameters (proposes `fix` order), UI > 4 floats, Vfx `Attributes`
  overflow, and derivatives/`.Sample` in Surface/Vfx. Warns on manual sRGB (except UI) and
  Surface issues (unnormalized/non-tangent normals, emission <= 1 nit, base color > 1, roughness
  < min, loops ignoring `ctx.ray`). Diagnostics include graph `node` ID. `program_template`
  returns minimal warning-free stubs.

```json
// RPC payloads via `mirai rpc` (material.program.check / build.start):
{"method": "material.program.check", "params": {"program": "shaders/pulse.slang"}}
{"method": "build.start", "params": {"target": "shaders"}}
```

## Project generation

- `mirai build editor|game`, `mirai edit`, `mirai play` generate `<project>/.mirai/shaders`
  (engine stages from shared cache, `program_stages` listed separately). Program names are
  global and unique (`pbr` reserved; no built-in engine Surface programs — see
  `templates/empty/shaders/pulse.slang`, `plugins/terrain/shaders/terrain_slope.slang`,
  `render/testdata/`).
- Callers may also supply immutable Surface/Vfx source text with an identifier independent of
  its Slang namespace (no editable catalog path; runs reflection/probes and invalidates users on
  change).
- Plugin/project `shaders/` also supply extension stages (`name.comp.slang`, `.vert`, `.frag`)
  and [hooks/constants](views.md#extension-hooks-and-constants).

### Publication from the editor

`editor/material_programs.odin`: edits via `material.program.create`/`edit`, undo, or revert
write to disk immediately and trigger a background generation:

- Preview stages (`render.preview_shader`, `thumbnail__<Program>.frag`) publish early so
  previews and `material.preview.capture` update in seconds.
- Program-only edits call `program_stages_publish`, dropping only changed program pipelines
  ([program pipelines](materials.md#program-pipelines)). Idle stages
  (`render.renderer_shaders_idle`) compile last while viewport runs the active generation.
- Newer edits cancel in-flight jobs; failed/unchanged jobs restore the published generation.
- External edits sync on next API call (`api_disk_sync`). `mirai shaders --project P` delegates
  to an open editor (`build.start` `target:"shaders"`; `--whole` forces offline). Engine source
  edits report `Stale` and require rebuilding the editor.

### Loading in `host`

`host/shaders.odin`:

- **Startup:** `app_create` finds `<project>/.mirai/shaders` (or `<folder>/shaders` in shipped
  games) via `project.shader_generation_find`; falls back to embedded shaders if missing.
- **Polling & reload:** Checks `manifest.json` every `SHADERS_POLL_FRAMES`; `app_shaders_reload`
  and `app_shaders_load` return deduped tickets (0 = rejected). Content-identical loads update
  catalog/ownership without rebuilding pipelines; differing loads compile pipelines off-thread
  ([rhi](rhi.md#pipelines-from-other-threads), `create_pipelines`, largest code first).
- **Publish & states:** `app_shaders_poll` swaps pipelines in ticket order (`app_shaders_drop`
  cancels superseded loads), keeps temporal history/probes on preview/idle-only updates, and
  runs `assets_programs_refresh`. `app.shaders.state`: `Stale` (interface mismatch, ignored with
  warning), `Failed` (keeps resident pipelines). Missing program on a material sets
  `Unsupported` and draws PBR.
