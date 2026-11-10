# Shaders (`cook/shaders/`)

- A single Slang source in `shaders/`. The engine outputs (`shaders/build/`,
  `render/shaders_gen.odin`, `rhi/shaders_gen_test.odin`) are generated and git does not store
  them.
- `cook/shaders` is the generation library (`shaders.generate(Options) -> Result`); the editor
  calls it to reload a project's programs. `mirai shaders` is its command line
  (`tools/mirai/shaders.odin`).
- `build.engine_build`, `mirai check`, `mirai test` and `mirai build game` generate the engine
  shaders before compiling; without changes, the generation runs no tools. Compiling the engine
  requires Slang and the SPIR-V tools.

## Shader toolchain

## Tools

- `mirai setup slang [--archive <file>]` installs in `.deps/slang/` the pinned precompiled Slang
  (`SLANG_VERSION`, with SHA-256 per platform) and keeps the previous installation until the new
  one is complete. `MIRAI_SLANGC` or `MIRAI_SLANG` choose another compiler.
- With a compiler older than the pinned one, the generation installs the pinned one and looks for
  it again; if it cannot (no `curl`, no network, or one named by a variable, which it does not
  replace), it does not run and the error says the version found, the pinned one and how to
  update. A generation of an older version is not reused. `mirai doctor` reports the version
  found.
- Generation and reload require precompiled `spirv-val`, `spirv-opt` and `spirv-cross` (Vulkan
  SDK; on macOS, `brew install --force-bottle spirv-tools spirv-cross`), which are looked for in
  `.deps/` and then in `PATH`.
- `mirai shaders --project <path>` adds the `shaders/` of the active plugins that declare them,
  the same ones the build passes (`build.shader_sources`).

## Compilation

- Column-major matrices, profile `sm_6_5`, SPIR-V 1.5 for Vulkan 1.2. Slang runs with `-O0` and
  the spirv-opt passes of its `-O3` without its first redundancy elimination (`SLANG_FLAGS`).
- SPIR-V with `-fvk-use-scalar-layout`: the same flat ABI as Odin and Metal (44-byte vertices).
  Vulkan requires and enables `scalarBlockLayout`; `spirv-val --scalar-block-layout` validates.
- Metal: the same SPIR-V goes through `spirv-opt -O --strip-debug` and SPIRV-Cross emits MSL 2.4
  with `--msl-decoration-binding`; set 1, the texture table, as an argument buffer at the buffer
  index the RHI binds ([table](rhi.md#bindings-and-texture-table)). Removing the debug names
  avoids collisions with MSL words (`ray_data`). A stage with image atomics
  (`OpImageTexelPointer`) comes out in MSL 3.1: before, SPIRV-Cross emulates them with a linear
  texture over a buffer that the RHI does not create, and the RHI gives `ShaderAtomic` to the
  `R32_Uint` storage textures.
- The reflection fixes slots and threadgroups of each stage; the emitted Metal entry point is
  stored in the table.
- **Structs shared with the CPU** (`SHARED_STRUCTS` of `cook/shaders/layouts.odin`, each with the
  `render` type that replicates it field by field): each variant that uses one must have the same
  layout, and `render/shaders_gen.odin` ends with an `#assert` of `size_of` and `offset_of` per
  field. A change on one side without the other does not compile. `Frame_Data` is compared up to
  `batches`: what follows belongs to the generation.
- **Material schema.** `include/material_schema.slang` is generated from `mirai:asset`
  (`Material_Map_Kind`, `Alpha_Mode`, `MATERIAL_DEFAULTS`). No shader writes those values.
- **Shared constants.** A constant the shaders share with the CPU (a binding slot, a flag bit, the
  words of a layout of a pool, a limit both size arrays with) is declared once in Odin and
  `include/shared_constants.slang` is generated from it (`shared_constants` of
  `cook/shaders/schema.odin`, which lists them). Those of the renderer live in `render/abi`, which
  `render` uses under the same names; those of a format or of the RHI, in `asset` and `rhi`. No
  `.slang` source defines one (`no_shader_source_defines_a_constant_the_generation_writes`). A
  plugin's shaders take them from the engine includes.
- Both includes are part of every fingerprint and of the stamp of a generation: changing one of
  those constants compiles the stages again.
- **Constants of a plugin.** A constant between the Odin code of a plugin, or of the project, and
  its own shaders is also declared once, in that Odin code, with its number (`NAME :: 8`). A
  `//! mirai constant <NAME> <int|uint|float> <file.odin>` line in a source of its `shaders/`
  names it, the type of its Slang literal and the Odin source, from the folder of the line's
  source; the generation writes them into `include/constants/plugins/<name>.slang` (named
  `project` instead of `plugins/<name>` for the project), which those shaders include
  (`owned_constants` of `cook/shaders/extensions.odin`). Only the stages that include it follow
  it, and the stamp follows the Odin source. The same test forbids a plugin's `.slang` from
  defining a name its Odin declares.
- The resources of a stage stay within the `rhi` limits.
- **Constants and variants.** What a pass chooses of a stage is a constant:
  `//! constant <name> <DEFINE>` makes `DEFINE` a boolean the code reads as `if (DEFINE)`, false
  unless the pipeline sets it ([rhi](rhi.md#shader-constants)), and the driver folds it. One code
  serves every combination: a constant adds no compilation. Its id is the order of its line, the
  manifest names it and `render/shaders_gen.odin` gives it as `<STAGE>_<NAME>`
  (`REFLECT_COMP_COLOR`). The stage includes `native.slang`, which declares them; a source shared
  with stages that do not declare the constant asks `#ifdef DEFINE` before reading it. What the
  constants of a stage read is bound for every pipeline of it (a stand-in where it is off).
- `//! variant <name> <DEFINE>...` is another compilation of the stage, `<stage>_<name>`, with
  those defines: only for what a constant cannot choose, because it changes what the stage declares
  to the device. A capability (`hw`: ray queries; `clip`: a clip distance), a module without which
  loads where the device lacks it. Its fragment outputs (`plain`, `layers`, `values`, `impostor`):
  Vulkan discards what is written to a target the pass lacks, but SPIRV-Cross fixes the outputs
  in the Metal source and Metal may refuse a pipeline whose function writes a target it does not
  have. The kind of a slot (`batches`), or a target the pass must not write (`sharpen`).
- Ray queries use Slang's `RayQuery` and share traversal and material filters with the software
  BVH. Validating SPIR-V does not certify GPU execution on any backend.

## Backends of a generation

- Each backend is a separate compilation of the stage (`Options.backends`, `--backends`). Every
  generation has by default only `HOST_BACKEND`, the only one the executable, `host` and
  `mirai build game` read. `--backends all` checks on one machine that a program compiles for the
  other; `mirai check <package> -target:<system>` also asks for the backend of that system.
- The Odin tables embed only the compiled backends; the branch of the other system is a `#panic`
  that asks for `mirai shaders --backends all`. The code of a backend is the same, byte for byte,
  whether compiled alone or with the other.

## Programs

- Each program declares `//! mirai surface Name`, `postprocess`, `vfx` or `ui`, and metadata
  `//! parameter field {json}`; `group` is the Details card that shows the parameter in the
  material document. Its parameters travel in a fixed block that the generated loaders read at the
  reflected offsets.
- A Vfx program (contract in `mirai_vfx.slang`) also declares `Attributes`, what it stores of each
  particle between steps (up to `ATTRIBUTE_BYTES`, reflected like the parameters), and
  `initialize`, `update` and `render`; the catalog gives its bytes in `attributes`. `//! moves`
  says it moves and ages its particles by itself; `//! births`, that its `births` function gives
  how many its emitter starts in each frame, instead of the effect's births. The stages that run
  programs are compiled once per program (`//! per vfx program`), each with the include of its
  program alone. `mirai_vfx_texture(index, uv, level)` reads the texture of a parameter and
  `mirai_vfx_random(seed)` gives a number from 0 to 1. The domain belongs to the generation (like
  Surface and PostProcess); the stages that evaluate its programs belong to the
  [`vfx` plugin](../../mirai-world/references/vfx.md#vfx-programs), and `Orbit`
  (`plugins/vfx/shaders/orbit.slang`) is its own.
- A Vfx program declares what it reads besides its parameters with `//! resource name surface`,
  `channel`, `bones`, `grid`, `emitter` or `data words` (up to `PROGRAM_RESOURCES`). The
  generation gives each one a constant with its index in the program's namespace (`hits` inside
  `Gather`) and the catalog lists them in `resources`. A surface is read with
  `mirai_vfx_surface_sample` (a point per area) and `mirai_vfx_surface_at` (the same triangle and
  barycentrics where it is now, with its normal and velocity); bones, with `mirai_vfx_bone_sample`
  (by length) and `mirai_vfx_bone_at` (the same bone and fraction); a channel, with
  `mirai_vfx_channel_count` and `mirai_vfx_channel_birth`; a grid (`grid`), with
  `mirai_vfx_grid_load`, `_sample`, `_splatted`, `_store` and `_splat`; the particles of another
  emitter (`emitter`), with `mirai_vfx_emitter_particle` and `_word`; a data channel (`data`),
  with `mirai_vfx_data_count` and `_word`, and it writes with `mirai_vfx_data_append` and
  `_store`. `mirai_vfx_trace` gives the first opaque thing a ray finds in the scene (distance,
  normal and whether it started inside a closed mesh) in `initialize`, `update` and the stages,
  which include `trace.slang` and declare the `hw` variant; in `render` it finds nothing. Which
  mesh, which skin, which channel or which grid each one is is resolved by the
  [plugin](../../mirai-world/references/vfx.md#surfaces-bones-and-resources).
- Its stages (`//! stage name over particles|resource [iterations N] [neighbors radius]`, up to
  `MAX_STAGES`) are functions of the namespace: over particles with the signature of `update` (and
  `mirai_vfx_neighbors` with `mirai_vfx_neighbor_next` if it declares `neighbors`), over the cells
  of a grid `(Mirai_Vfx_Cell, Parameters)`. The generation dispatches them in
  `mirai_vfx_particle_stage` and `mirai_vfx_cell_stage` and the catalog lists them in `stages`; the
  [plugin](../../mirai-world/references/vfx.md#grids-and-stages) runs them.
- A Surface program that moves vertices says `//! vertex [animated] [reach <metres>|reach
  <parameter>]` and declares `vertex` ([vertex functions](materials.md#vertex-functions)): reach is
  a number from 0 or a parameter of one float; another word, a reach of another type or the line
  in another domain leave the program out, and the check asks for `vertex` with its signature. The
  catalog gives it in `vertex` (`animated`, `reach`: a number or the name of the parameter).
- `mirai_sample_texture(ctx,index,uv,lod)` receives the explicit context:
  - Surface in raster: derivatives and bias.
  - Surface with `ctx.ray` (also hits rebuilt in fragment shaders): LOD of the ray footprint.
  - PostProcess: derivatives and bias.
- `mirai_sample_texture_level` receives an explicit mip; `mirai_sample_texture_grad`, gradients.
- `ctx.position_dx` and `ctx.position_dy` are the footprint of the point in the world: how much
  the position moves to the next pixel in x and in y (derivatives in raster) or, in a ray, the
  width of its cone along the surface. `mirai_sample_texture_projected(ctx,index,u,v,meters)` reads
  a texture laid over the world (uv = position over `u` and `v`, meters per repetition) with the
  gradients of that footprint: it filters the same in raster and in rays and works inside a
  branch, where implicit derivatives do not.
- `ctx.world_position` is relative to the render origin and `ctx.origin` is that origin in whole
  steps of `ORIGIN_STEP`. What a program does with the world place (a wave, a pattern, a noise
  lattice) takes what the origin adds from `origin.slang`: `origin_phase`, `origin_wrap` and
  `origin_lattice` find it by integers, exact at any distance from the center; a float of the
  world place would lose it.
- `ctx.screen`, `ctx.screen_size` and `ctx.depth` come from projecting the point with the view's
  camera (`material_context`), in raster and in rays: a hit outside the image gives a `screen`
  outside 0 to 1. `ctx.scene_depth` is the depth of the opaque scene behind the point only in the
  passes that draw over it (`fragment_evaluate(input, opaque)`: glass layers, filter and
  translucents); in the others, the view's far depth. `ctx.object_low` and `object_high` are the
  bounds of the instance's mesh in its space. `mirai_texture_size(index)` gives the texels of a
  texture at its finest resident level: a program asks for all the levels of its textures.
- `ctx.particle_data`, `ctx.particle_given`, `ctx.particle_random` and `ctx.particle_radius` are
  what the particle of a sprite that draws the point gives, which also gives its color in
  `ctx.vertex_color` ([`vfx` sprites](../../mirai-world/references/vfx.md#passes)); in
  everything else, nothing given and zero.
- A PostProcess program reads outside its pixel, at a `uv` from 0 to 1 from the top-left corner:
  `mirai_scene_color(ctx, uv)` is the image the previous effect left, exposed like `ctx.color`;
  `mirai_scene_depth` and `mirai_scene_normal`, the surface seen there; `mirai_outline`
  (`Mirai_Outline`), the style of the [game outline](frame-graph.md#outlines) and whether another
  surface covers it. `Blur` (`shaders/materials/screen_blur.slang`) is the engine one that reads
  around its pixel.
- A UI program colors the fill of a UI node: `evaluate(Mirai_Ui_Context ctx, Parameters p)` returns
  a display color with straight alpha, which the UI clips to the node's corners and tints with its
  scope. It receives only the node's four values: they fill the first 16 bytes of the parameters as
  floats and the rest stays zero, without the catalog defaults (which serve to initialize the
  node's values). A parameter that is not a float reads the bits of that float. The engine ones
  (`shaders/materials/ui_*.slang`) are `Ui_Radial_Wipe` (the sector of a cooldown), `Ui_Dissolve`
  (the node dissolves into noise), `Ui_Shine` (a stripe of brightness crosses it) and
  `Ui_Gradient_Sweep` (a gradient toward another color that shifts). Selector and registration:
  [UI](ui.md#ui-world-panels-and-debug-lines).

## Programs and stages

- The generation writes one include per domain:
  - `include/surface_programs.slang`: that of the stages without a program, whose
    `mirai_evaluate_program` evaluates none. Each Surface program has its own in
    `include/surface/<Name>/surface_programs.slang`, with its source and its loader alone.
  - `include/surface_coverage.slang`: the alpha of the programs whose alpha is not that of the
    default material (`coverage` in the catalog), for the ray traversal (`hit_covers`). The
    generation decides it by compiling the alpha of each program alone (`alpha_probe`): what reads
    nothing folds to a constant in the optimized SPIR-V. The include names each source with the
    hash of that SPIR-V (`ALPHA_INCLUDE`), and a stage's fingerprint follows that hash and not the
    text of the program: the texture reads of the probe keep all their arguments, so the same hash
    is the same alpha.
  - `include/postprocess_programs.slang`: PostProcess sources, their loaders and
    `mirai_evaluate_postprocess`.
  - `include/vfx_programs.slang`: Vfx sources, their parameter and `Attributes` loaders and
    `mirai_vfx_initialize`, `mirai_vfx_update` and `mirai_vfx_render`. The `vfx` plugin's
    `particle_programs.slang` includes it, which declares the pool data buffer (`particle_data`)
    and defines `PARTICLES_WRITABLE` in the stages that write particles.
  - `include/ui_programs.slang`: UI sources, their loaders and `mirai_evaluate_ui`, which returns
    `ctx.color` for an id it does not know. `ui.frag` includes it.
- `scene.slang` includes `<surface_programs.slang>`: the stage itself evaluates no programs. A
  source marked `//! per surface program` is also compiled once per Surface program,
  `<root>__<Program>[_<variant>]<suffix>` (`gbuffer__Water_Surface_layers.frag`), with the include
  of that program in front; `//! per surface program only` compiles only those. They are the
  raster stages that draw materials (G-buffer, glass layers and filter, translucents, overlays,
  highlight, thumbnails, UI and the `vfx` sprites) and `surface_points.comp`, that of the ray
  material points
  ([programs in rays and raster](materials.md#surface-programs-in-rays-and-raster)). A source
  marked `//! per vertex program` is compiled only for the Surface programs with `vertex`, with
  the same include, and has no stage of its own: `surface_vertices.comp`, which calls
  `mirai_vertex_program` (the include of the generation and that of a program without `vertex`
  define it as moving nothing). No other engine stage evaluates a Surface program.
- A Surface program thus reaches only its stages, and its alpha those of rays if it has coverage;
  a PostProcess one, only `postprocess.frag`; a Vfx one, the stages of the `vfx` plugin that
  include it (emit, simulate and the vertices of sprites and meshes); a UI one, `ui.frag` and its
  `world` variant. Editing a program compiles its stages and, if the edit changes its alpha with
  coverage, also those that trace (the ray ones, the overlays and those of the Vfx programs).
- In a project generation, the stages that do not depend on the catalog have the fingerprint they
  have in the engine one and are taken from the shared cache.
- Program ids are consecutive across the domains, in file order (engine, project, plugins): adding
  a program of one domain changes the other's dispatcher if it comes before any of its programs.

## Inputs and outputs

- `--project <path>` incorporates the programs of `<path>/shaders`. `Options.sources`
  (`{name, folder}` per plugin) adds the `shaders/` of plugins, copied to
  `include/programs/plugins/<name>/`. Without a project or sources, only the engine ones. A
  program includes by name the files of the plugin folders, in reflection as in the stages.
- With a project, the default output is `<project>/.mirai/shaders` (`PROJECT_OUTPUT`) and the Odin
  tables are never written.
- `--output <path> --no-odin` generates in another folder the code, `catalog.json` and a manifest
  that `shader_assets_load` reads.
- The engine generation also compiles the RHI test shaders and writes `render/shaders_gen.odin`
  and `rhi/shaders_gen_test.odin`, `@(rodata)` tables.
- The `render` table embeds the code of its stages and then of its program stages as one LZ
  stream per backend (`shaders/build/shaders.spv.lz`, `.metal.lz`), each stage an
  `Embedded_Shader` with its size in it. It is packed `PACK_EDIT`, and `SHIP` when the generation is
  asked to ship (`Options.ship`: the release builds of the engine); either serves every build.
  `renderer_init` decodes it once (`embedded_shaders_decode`) unless it starts with a loaded
  generation. The `rhi` test table loads each stage as it is.
- The `rhi` table stays under `rhi.TEST_SHADERS` (`MIRAI_TEST_SHADERS`, true in test builds and in
  `mirai check`); the tests read it with `test_shader(name)`. This way `rhi` and the `mirai` tool,
  which imports it, compile before the first generation.
- The executable embeds and the loader reads only MSL on macOS or SPIR-V on Linux and Windows.
- `renderer_init` receives a loaded generation in `Renderer_Desc.shaders`;
  `renderer_reload_shaders` replaces it at once ([loading in host](#loading-in-host)).

## Cache and fingerprints

- **Shared cache** (`cache.odin`): `<main checkout>/.mirai/cache/shaders`
  (`workspace.cache_folder`), the same for all the repository's worktrees, branches and projects.
  Each entry is named by its fingerprint:
  - `stages/<fingerprint>.json`, `.spv` and `.metal`: a compiled stage and its code;
  - `reflection/<fingerprint>.json` and `<fingerprint>.attributes.json`: the reflection of the
    `Parameters` and of the `Attributes` of a program;
  - `embedded/<digest>.edit.spv.lz`, `.ship.spv.lz` and their `.metal.lz`: the stream
    `render` embeds, by the hashes of the code it holds, taken only if it decodes to that code.
- Each file is written separately and renamed into place (process- and thread-own temporary), and
  the stage's `.json` last. Whoever reads takes an entry only if all its hashes match; if not, it
  compiles and stores it again. An entry without the code of a requested backend is completed
  keeping the one it had. A failure to store does not fail the generation.
- Using an entry updates the date of its `.json`. A generation that compiled something deletes, at
  most once per day (`pruned` file), the entries that nobody used in 30 days.
- `Options.cache` / `--cache` (by default `<project>/.mirai/shader-cache`, or
  `<root>/.mirai/shader-cache` without a project) stores only the `generation.json` stamp of the
  output. Generations with the same stamp take turns with `<cache>.lock`, next to it.
- Fingerprint of a stage: its source and its transitive includes/imports, versions of Slang,
  spirv-opt and SPIRV-Cross, flags of each tool, binding ABI limits and `GENERATOR_CONTRACT`. It
  does not depend on the requested backends or on the checkout.
- **`extensions.slang` per stage.** A stage is compiled against an `extensions.slang` that defines
  only the generation macros (`MIRAI_NESTED_VIEWS`, `MIRAI_INSTANCE_IDS`, `MIRAI_HOOK_RAY`,
  `MIRAI_HOOK_LIGHTS`, `MIRAI_HOOK_PROBES`, `MIRAI_HOOK_VERTEX`) that its dependencies name, and
  the extension frame fields (`MIRAI_FRAME_EXTENSIONS`, with the includes of their sources) when
  one of its dependencies is from the project or a plugin, the only ones that read them.
  `MIRAI_FRAME_NESTED` declares the nested views at the end of `Frame_Data` with nested views or
  before those fields. It goes in a folder of its own before that of the generation and with the
  same name in the fingerprint: a stage with none has the fingerprint of the engine one, and two
  projects with the same named macros share the stage.
- So a source names a macro only if its code changes with it: `common.slang` names none; decoding
  the depth (`depth.slang`), reading the pixels in the world (`pixel.slang`) and the probe light
  with its gates (`probe_light.slang`) are includes that only the source that uses them takes.
  Including one without using it only recompiles more.
- Resolution tries local includes before the search directories and considers both conditional
  branches. An include named by a macro depends on all the files of the search directories.
- The parameter reflection has its own fingerprint per program and authoring contract. The
  `Parameters` and `Attributes` of a program are reflected in one compilation; those the cache
  does not have run at once in the generation's workers, before the stages.
- A program that does not compile is rejected in the cache by that fingerprint
  (`<fingerprint>.refused.txt`, with what Slang said): it is not compiled again while its sources
  do not change. A compiler that ends without diagnostics (a cancelled generation) leaves nothing
  in the cache.
- A program of a project or of a plugin that does not compile is left out of the catalog, which
  names it (`Result.refused`), and the others are published; one of the engine fails the
  generation.
- `Sources` reads each source once and stores two hashes: the full one (catalog, engine identity,
  stamp) and the compilation one (stages and reflection).
- The compilation hash omits only whole `//! parameter` lines that are line comments in code,
  keeping the line breaks for `__LINE__`. Strings, block comments, binary modules and continued
  lines are not reinterpreted; with a raw string or a physical continuation the full source is
  used.
- Changing defaults, ranges, color or texture interpretation validates and publishes the catalog
  without compiling stages or reflecting again.
- An output is reused only if its hashes match and it has the code of all the requested backends.
  Order: the shared cache and, if it lost the entry, the previous output, which gives it back.
- `mirai shaders` reports the reflection time, the sum of that of the compiled stages and the
  slowest ones (`Result.reflection`, `compiling` and `slowest`).
- One worker per logical processor by default (`--workers`, at most 64). Process starts are
  serialized so each tool inherits only its pipe.
- The workers take the stages with the most code first (the size of the one the output has, or the
  engine build; a stage without previous code goes to the front): the compilation of a large stage
  is not left for the end ([early stages](#early-stages-and-cancellation)).
- A stage that fails does not stop the others: what compiles stays in the cache for the next
  generation.

## Early stages and cancellation

- `Options.first` names stages (`thumbnail.frag`) that the workers take first. When they all
  compile, `Options.first_output` receives a generation that loads by itself: the catalog and those
  new stages, and each other stage as the output has it. `Progress.first` announces it. The
  complete generation is published afterwards as usual.
- `Options.idle` names the stages that whoever loads the generation does not run now; the workers
  take them last. When all the others compile, `Options.active_output` receives in the same way a
  generation with them new and the idle ones as the output has them (`Progress.active`). Without
  any idle stage it is not written: the complete one is the same.
- `cancel(&progress)`, from another thread, stops the generation: no more stages start, the running
  tools are killed and it ends with `Result.cancelled`, without publishing.

## In-memory sources

- `Options.overlay` gives sources that the generation reads instead of their files: what an editor
  has unsaved. It goes through `Sources`, so fingerprints, stamp, listings and the copy of the
  programs see that content under the file name; a new one appears, also in a folder the disk
  does not have yet, and a `removed` one does not. A project whose only program is a new one from
  the overlay has its own generation.
- What compiles stays in the cache with the fingerprint of that content: saving it leaves the
  generation up to date without compiling.
- If a literal include or import of a stage names a source of the overlay outside the copies, the
  stage fails (`it includes ..., which has unsaved changes`) instead of storing in the cache the
  code of the file with the fingerprint of the memory.

## Generation without changes

- A published generation leaves `generation.json` with the request, the tools, the hash of each
  source, the includes not found and what was published. If everything matches, it starts no
  compilers and does not touch the output (`Result.current`; `mirai shaders` answers
  `up to date`); `shaders.current` answers the same without lock or writes. If not, the full path
  checks each stage by its fingerprint.

## Publication

- The whole directory and the Odin tables that change are prepared in staging; the renames keep the
  previous generation until finished and a failure reverts them: the visible output always
  contains a complete generation. If the filesystem prevents the rollback, the error names the
  folders that keep the previous copies.
- A generation identical by content keeps the output and its dates. The executable embeds the
  fingerprint of the engine sources (`SHADERS_FINGERPRINT`) and `shader_assets_load` rejects
  shaders from other sources.

## Diagnostics

- `slang_diagnostics` reads Slang's machine-readable diagnostics into `Diagnostic`, with the files
  named by the source (also the copy of a program). A generation that fails leaves them in
  `Result.diagnostics` and their text in `error`; the editor's Build lists them with those of the
  Odin compiler.

## Check of a program

`program_check(Check_Options) -> Check_Result` (`check.odin`) checks a program of any domain
without publishing anything; `material.program.check`, `create` and `edit` and
`mirai shaders check <program.slang> [--project <path>]` (exits with 1 if there are errors) use
it. The domain is the one the source declares.

- **Compilation.** It compiles the source (or `text`) with `-O0` in a temporary folder, in
  parallel, after the reflection of `Parameters` (and of `Attributes` in Vfx, with the indices of
  their resources), against the includes that a generation with only that program writes: the same
  code (`dispatchers_add`, `dispatchers_write`, `vfx_program_include`). A Surface runs in many
  stages: it is compiled in two of the check, fragment and compute with `ctx.ray`. PostProcess and
  UI, in the engine stages that evaluate them (`CHECK_STAGES`); Vfx, in those of the active plugins
  marked `//! per vfx program`, with its own include (with none, it is only reflected and
  `mirai.stages` warns). What the stages say about their own code is not the program's; what the
  check's wrappers and includes say is attributed to the first function of its contract.
  `undefined identifier` receives a `fix` with the Slang equivalent or the domain API.
- **Rules** (`mirai.<rule>`, over the [derived graph](materials.md#derived-graph)); these are
  errors: the declaration (`//! mirai <domain>`, `namespace`, `struct Parameters`, `Attributes` in
  Vfx and the signatures of the domain contract, `ENTRIES`), the `//! resource` and `//! stage`
  lines of Vfx, own texture objects (textures enter through parameters), GLSL API, parameter
  metadata that does not match `Parameters`, parameters that do not pack (the `fix` proposes an
  order) or that do not fit in the four floats of a node (UI) and `Attributes` that do not fit in
  a particle. Derivatives and `.Sample` are errors in Surface (it also runs in rays) and in Vfx
  (compute and vertex), not in PostProcess or UI. Manual sRGB conversions warn (except in UI,
  which colors in display values). Surface only: unnormalized normals or normals outside tangent
  space, emission that does not exceed 1 (it is in nits), base color above 1, roughness below the
  minimum and a loop that never looks at `ctx.ray`.
- `node` of each diagnostic is the id of the graph node of its line.
- `program_template` gives the new program of each domain, the minimum that compiles without
  warnings.

## Project generation

- A project and its active plugins bring programs in their `shaders/`. `mirai build editor`,
  `mirai build game`, `mirai edit` and `mirai play` produce the project generation
  ([projects](../../mirai-projects/references/build.md#project-shaders)): all the engine
  stages for the system's backend, in `<project>/.mirai/shaders`.
- The stages of the project's programs are compiled with them; the engine ones come from the
  shared cache except those that trace, when a project program has coverage
  ([programs and stages](#programs-and-stages)). The manifest lists the program stages separately
  (`program_stages`).
- Program names are unique among engine, project and plugins; `pbr` is reserved. Examples:
  `templates/empty/shaders/pulse.slang`, `plugins/terrain/shaders/terrain_slope.slang`. The engine
  has no Surface program of its own: every one is of a project, a plugin or the tests
  (`render/testdata/`, [verification](verification.md)).
- The same folders extend the renderer with their own stages (`name.comp.slang`, `.vert`, `.frag`,
  of unique name) and sources with [hooks and constants](views.md#extension-hooks-and-constants).
  With hooks, constants or nested views only the stages that read them are recompiled
  ([cache and fingerprints](#cache-and-fingerprints)).

### Publication from the editor

`editor/material_programs.odin`: when a program source changes through the editor
(`material.program.create` or `edit`, undo, reverting an AI turn, discarding it), a job generates
the project shaders again without stopping the editor. The edited source goes as an
[in-memory source](#in-memory-sources): the project's `.slang` does not change until Save, which
does not publish again
([unsaved programs](../../mirai-editor/references/document.md#unsaved-programs)).

- The preview stages (`render.preview_shader`) are the [early ones](#early-stages-and-cancellation),
  also those of each program (`thumbnail__<Program>.frag` is early with `thumbnail.frag`): the
  renderer loads them with the new catalog and the previews and `material.preview.capture` show the
  change in seconds.
- A generation that changes only program stages does not redo the engine pipelines:
  `program_stages_publish` removes those of the programs whose stages changed and keeps the others,
  and those of the edited program are requested again when drawing it
  ([program pipelines](materials.md#program-pipelines)).
- The idle ones are those of `render.renderer_shaders_idle`: those of the rays that the renderer
  does not trace (software with hardware tracing, or the reverse), those of pipelines the device
  does not make and those of lazy pipelines nobody asked for. When the others compile, the renderer
  loads the active generation and the viewport shows the program; the idle ones run the previous
  one.
- The complete generation replaces those loads when it ends. Until the active one the viewport
  draws the previous program and, if the layout of its parameters changed, reads them wrongly,
  without leaving the texture table (`material_has` bounds the indices).
- Another change while the job runs cancels it and abandons its loads, which would compete for the
  driver. If the job fails, or ends without changes after the renderer took early stages from
  another, the renderer loads the published generation again.
- A shader changed outside the editor is published at the next call of the API, and a call that
  draws waits for it (`api_disk_sync`). `mirai shaders --project P` with the editor of `P` open
  asks it (`build.start` with `target:"shaders"`, which answers when the viewport draws with it)
  instead of generating on its own; `--whole` generates everything on the command line. A
  change in the engine sources does not load in an already compiled editor (`Stale`, by the
  executable's fingerprint): the call says so and asks to compile the editor again.

### Loading in `host`

`host/shaders.odin`:

- **At start.** `app_create` with a GPU looks for the generation with
  `project.shader_generation_find` (`<project>/.mirai/shaders`, or `<folder>/shaders` in a
  distributed game). If it is from the same engine sources as the executable, the renderer uses it;
  if there is none, the embedded ones.
- **On change.** Every `SHADERS_POLL_FRAMES` frames it looks at `manifest.json`; a different one is
  loaded with `app_shaders_reload`, which is also called on request. `app_shaders_load` loads
  another folder. Both return a ticket (0: rejected); the same folder with the same manifest gives
  the same one.
- **Load.** It reads the generation between frames and compares it by content with the resident
  one. If it matches, it publishes catalog and ownership without creating pipelines; if not, a
  thread makes the driver compile the pipelines while the frames continue with the resident ones
  ([rhi](rhi.md#pipelines-from-other-threads)).
- **Pipelines.** `create_pipelines` (at renderer start and on each load) makes them on one thread
  per core, those with the most code first, and only those the device supports.
- `app_shaders_poll` publishes the ready loads in the requested order, replacing the pipelines
  whole, and discards those older than the published one; `app_shaders_drop` abandons one that
  another makes obsolete. A load that changes only preview or idle stages keeps the temporal
  accumulation and the probes; another discards them. Afterwards, `assets_programs_refresh`
  resolves again the program and parameters of each material (the ids change).
- **State** (`app.shaders.state`): `Stale` is a generation from other engine sources, which is
  ignored with a warning until the next build; `Failed`, an unreadable one or one with rejected
  pipelines, which keeps what was there. A generation that disappears does not return the renderer
  to the embedded ones until restart.
- A material that names a program absent from the catalog is left with error `Unsupported` and is
  drawn as PBR.
