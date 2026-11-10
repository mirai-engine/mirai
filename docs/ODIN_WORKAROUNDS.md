# Dependency workarounds and defects

Workarounds for defects in dependencies that Mirai does not control. When moving to a new version,
test each one without its workaround and remove those that are no longer needed, with their comment
and their mention in the skills.

## Odin

Defects of Odin `dev-2026-11` (`nightly:e28f5d1`).
- **Procedure types in a `foreign` block ignore `default_calling_convention`** (no issue;
  publishing it requires the user's confirmation).
  - Defect: in `@(default_calling_convention="odin") foreign x { f :: proc(cb:proc()) --- }` the
    type of `cb` is `proc "cdecl" ()`, so passing an Odin procedure does not compile.
  - Workaround: `inner_procs_odin` (`cook/build/declare.odin`) writes those types as
    `proc "odin" (`.
  - To test: the example compiles passing an Odin procedure as `cb`.
- **`-use-separate-modules` objects beyond `MAX_PATH` on Windows** (no issue; publishing it
  requires the user's confirmation).
  - Defect: LLVM writes the object of each module (`<output>-<module>.obj`), but Odin's link fails
    with `Error(023): unable to find file` if its path reaches 260 characters. Reproducer: a
    package that imports another, `odin build pkg -build-mode:dll -use-separate-modules
    -out:<folder of ~250 characters>/<long name>.dll`. A `\\?\…` output is rejected with
    `Invalid -out path`.
  - Workaround: `job_plugin_name` (`cook/build/build.odin`) names the output of a plugin library
    by its index and not by its file: a project builds with a root of up to about 168
    characters.
  - To test: the reproducer builds, and `mirai build editor` of a project with `fog` under a root
    of 200 characters gets past the link.
- **`delete_key` on a `map[typeid]T` never finishes compiling at `-o:speed`** (no issue;
  publishing it requires the user's confirmation). Seen with `nightly:9a69916`.
  - Defect: `odin build` of a package that calls `delete_key(&m, id)` with `m: map[typeid]u32`
    stops after about a second of CPU, with every thread waiting, at `-o:speed` and `-o:size`;
    `-o:none` and `-o:minimal` build it. Reproducer: a `main` that puts `typeid_of(int)` in such
    a map and takes it out with `delete_key`.
  - Workaround: `schema_push` (`std/serial/schema.odin`) appends the type before it puts its
    `typeid` in `Schema.lookup` and pops it when the map has no room, so it never takes a key
    back out. No other map by `typeid` loses keys.
  - To test: the reproducer builds with `-o:speed`.
- **`for in` over an array-backed `bit_set`** (odin-lang/Odin#8047).
  - Defect: with an enum of more than 128 values the `bit_set` needs a backing array, and
    `for e in S` over a `bit_set[E; [4]u64]` constant makes the backend fail
    (`llvm_backend_const.cpp(643): Assertion Failure: sz >= max_count`): the iteration mask is
    built as an integer spread over the array. `in`, `not_in`, `card` and the set operations work.
    Reproducer: `E :: enum u8 {A, B = 129}`, `S :: bit_set[E; [4]u64]{.A, .B}` and
    `for e in S {}` in `odin run`.
  - Workaround: `preview_shader` of `render/shader_assets.odin` is a `switch` instead of the set
    that `editor/material_programs.odin` iterated when `Shader_Id` went past 128 values.
  - To test: the reproducer builds and iterates the two values.
- **`os.environ` ends with an empty entry on Linux** (odin-lang/Odin#7964).
  - Defect: `env -i A=1 B=2` gives `["A=1","B=2",""]`; `std/subprocess` rejects the whole
    environment and `mirai build engine` fails with `Compiler_Failed`. On Darwin and the BSDs the
    first entry appears twice, and on Linux a child with a nil `env` receives the first variable
    repeated.
  - Workaround: `child_environment` (`cook/build/platform.odin`) skips the empty entries.
- **Multiple assignment of more than 64 bytes** (odin-lang/Odin#7937).
  - Defect: it reaches LLVM as a `store` of the whole aggregate (when a value comes out of a call
    or a local) or as copies to and from temporaries (between lvalues, like a swap), which
    `-o:speed` (and `-o:minimal`) optimizes for seconds or minutes. Copying to locals costs
    nothing: it comes out as `memmove`. What costs is the multiple assignment:
    - restoring backups of tens of KiB in a single assignment
      (`m.connections,…=previous,…` in `editor/ai_settings.odin`) took the editor library to
      `-o:speed` in 24 minutes;
    - the generated `swap_world`, with about 46 KB of storages, took the demo library to
      `-o:speed` in more than 70 s;
    - `p.manifest,error=manifest_read(…)` in `project.open`, of a `Manifest`, took the runtime
      library to 13 minutes at `-o:speed -debug` (254 s of its 290 on one thread at
      `-use-separate-modules`);
    - `profile,error=motion_profile_read(…)` in `anim.motion_content`, with a `Motion_Profile` of
      16,712 bytes, took the runtime library of `animation` from 1 to 15 s.
  - Workaround: one assignment per value at the sites marked
    `// One store per value until odin-lang/Odin#7937`; `swap_world` swaps the storages by
    memory (`slice.ptr_swap_non_overlapping`).
  - Detecting it: `mirai test cook/build no_store_of_an_aggregate_of_more_than_64_bytes` compiles
    to IR with `-o:minimal` the engine libraries, the demo editor library with its world and the
    library of each demo plugin, and fails on every `store` of an aggregate of more than 64 bytes.
    The split form leaves no `store` either: the value that comes out of a call into a temporary
    is copied as a `load` and a `store` of the aggregate that `-o:minimal` already splits into one
    per element (`%.fca.…`, with a GEP over the integer type), which is how `motion_content` (66
    thousand lines of IR) and `project.open` (`p.manifest,error=manifest_read(…)`, which took the
    runtime library to 13 minutes at `-o:speed -debug`) got in. The same test fails on a function
    with more than `IR_SPLIT_LIMIT` of those lines. The form through
    temporaries leaves no `store`: the generator test covers `swap_world`, and in the rest there
    remain pairs of `llvm.memcpy` to and from an unnamed `alloca`, of more than 64 bytes:
    `physics.state_swap` (`a^,b^=b^,a^`, 6064 bytes), `physics_step` and `state_copy` (2624),
    `host.assets_material_values` (a ternary of 1072), `mirror.mirrors_render` (4096),
    `previews_editor.effect_merge` (3840) and `portals.portals_render` (1792), among others.
  - At `-o:minimal` the compiler's memory grows without a ceiling: two builds reached 56 and
    29 GB, and the multiple form of `ai_connection_remove` grows 1.3 GB per second. Each compiler
    process has a cap (half of the memory, between 4 and 8 GiB; `MIRAI_COMPILER_MEMORY`), except
    on macOS, where there is no reliable limit for another process.
  - To test: with the fix in Odin, remove the comment and go back to the multiple form;
    measure `mirai build engine --release --force`. On Windows, with the LLVM 20 of Odin
    `dev-2026-10`, the engine went from 81.5 to about 74 s.
- **Child processes on Windows with `core:os`.**
  - Defect: `os.process_start` calls `CreateProcessW` without `CREATE_NO_WINDOW` and with no way
    to ask for it, and it inherits all the inheritable handles. From a process without a console
    each console child opens a visible window, and a child retains the pipes of others launched at
    the same time. Also an empty argument disappears from the command line, `process_exec` spins
    without sleeping, and `core:sys/windows` does not declare `STARTUPINFOEXW`,
    `*ProcThreadAttribute*` or `GetConsoleProcessList`.
  - Workaround: `std/subprocess` creates the processes on Windows
    ([reference](../.agents/skills/mirai-std/references/subprocess.md)); nothing else calls
    `os.process_start` or `os.process_exec`.
  - Proposed fixes: handles (odin-lang/Odin#7966), window without a console
    (odin-lang/Odin#7967), empty and tab arguments (odin-lang/Odin#7968) and the wait of
    `process_exec` (odin-lang/Odin#7969).
  - To test: with a version that resolves it, go back to `core:os` in `std/subprocess` and run
    `mirai test std/subprocess`.
- **A ternary reads a `using` field before checking the pointer** (odin-lang/Odin#8093;
  a relative of odin-lang/Odin#6548, which is the same defect with `#soa^` pointers).
  - Defect: with `R :: struct($T:typeid) {using ptr:^T}` (like `core.Ref`), `r.ptr!=nil?r.b:7` and
    `r.b if r.ptr!=nil else 7` load `r.b` before the comparison and choose with a `select`: with
    `r.ptr` nil they end in `Segmentation_Fault` at `-o:none` and `-o:minimal` (the tests); at
    `-o:speed` they do not fail. `r.ptr.b`, `int(r.b)` or an `if` check before reading.
    Reproducer: those two functions called with `{}` in `odin run`.
  - Workaround: `.ptr` spelled out in the ternaries with a field of a `core.Ref`, with the comment
    `.ptr spelled out` (`engine/render/render.odin`, `plugins/multiplayer/runtime`,
    `plugins/ragdoll/runtime`).
  - To test: with a version that resolves it, the reproducer returns 7 at `-o:none`.
- **`-extra-linker-flags` does not pass quotes on Windows** (odin-lang/Odin#2741).
  - Defect: Odin changes the `"` of the value into `\`, so a path with spaces in `/DEF:` reaches
    the linker split (radlink: "failed to read DEF file").
  - Workaround: `plugin_command` (`cook/build/plugins.odin`) names the `.def` without a path and
    the compiler runs in the stage.
  - To test: pass `/DEF:` with the full path and run `mirai test cook/build
    a_plugin_library_under_a_folder_with_spaces_links_with_its_definition`.
- **Swap by multiple assignment miscompiled with `-o:speed`** (odin-lang/Odin#8113; the
  same lowering as odin-lang/Odin#7937).
  - Defect: `a^,b^=b^,a^` (or `o^,tab.ai=tab.ai,o^`) of a struct with a field before an array
    of more than 1024 elements leaves the value of `b` in both: LLVM 20.1 orders the two copies of
    the array as `memmove` and the second reads what the first already overwrote. With `[1024]u8`
    it works (the limit of `instcombine-max-array-size`), as it does without the field in front,
    with `-o:none` and `-o:minimal` and with LLVM 22. The Windows Odin ships LLVM 22.1.8 and no
    longer fails; the Linux and macOS ones are still on LLVM 20.
  - Workaround: `swap_values` (`editor/documents.odin`, with `slice.ptr_swap_non_overlapping`) in
    the eight swaps of `document_tab_exchange`.
  - Still to review: the other multiple swaps of large values (those in the entry of
    odin-lang/Odin#7937, like `physics.state_swap`): they fail if their type has an array of more
    than 1024 elements with a field in front.
  - To test: with a Linux Odin with LLVM 22, go back to the multiple form and run `mirai test
    editor prefab_selection_and_file_overrides_share_the_undo_history --release` on Linux.
- **`os.process_kill` does not terminate a process from `os.process_open` on Windows**
  (odin-lang/Odin#8092).
  - Defect: `_process_open` asks for `PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE` without
    `PROCESS_TERMINATE`, and `os.process_kill` returns `Permission_Denied`. Reproducer: launch
    `ping -n 30 127.0.0.1` with `os.process_start`, open its pid with `os.process_open` and kill
    it: it fails, and with the `Process` from `process_start` it works. That is how
    `mirai session stop` left alive, without its `api.json`, an editor that did not close in time.
  - Workaround: `process_kill_pid` (`tools/mirai/session_windows.odin`) opens the process with
    `PROCESS_TERMINATE`.
  - To test: with a version that resolves it, the reproducer terminates the process; go back to
    `os.process_kill` in `process_kill_pid`.
- **`os.process_open` of a process that already ended does not fail on Windows**
  (odin-lang/Odin#8091).
  - Defect: `_process_open` compares what `OpenProcess` returns with `INVALID_HANDLE_VALUE`,
    but `OpenProcess` returns NULL on failure: the pid of a process that no longer exists opens
    without error and with `handle` 0, and `os.process_wait` on it fails without saying that it
    ended. Reproducer: open with `os.process_open` the pid of a process that already ended and wait
    for it with timeout 0: `nil`, handle 0 and `Invalid_File`. That is how `mirai session` took
    for alive, and not responding, the editor of an old `api.json` and refused to open another.
  - Workaround: `process_alive` (`cook/workspace/workspace.odin`) takes a handle 0 for a process
    that is not there.
  - To test: with a version that resolves it, the reproducer returns an error; remove the
    comparison with 0.
- **`mem.Dynamic_Arena` hands out address 0 after a block that it failed to get**
  (odin-lang/Odin#8103).
  - Defect: `_dynamic_arena_cycle_new_block` leaves `bytes_left` at `block_size` and
    `current_pos` at nil even if the block allocator fails; the next allocation returns a pointer
    near 0 without an error, and writing to it dies with `access violation writing 0x10`. An
    importer out of memory crashed that way instead of failing.
  - Workaround: `base.dynamic_arena_allocator` (`std/base/alloc.odin`) sets `bytes_left` back to 0
    when the arena has no block; every `Dynamic_Arena` of the engine uses it instead of
    `mem.dynamic_arena_allocator`.
  - To test: `dynamic_arena_without_memory_keeps_refusing` of `std/base` with
    `mem.dynamic_arena_allocator`.
- **`os.walker` leaves the search of the last folder open on Windows** (odin-lang/Odin#8112).
  - Defect: on finishing a folder, `walker_walk` closes the file and sets `iter.f` to nil without
    `FindClose`; the next folder closes it when it opens, but the last one does not:
    `walker_destroy` arrives with `iter.f` nil and `_read_directory_iterator_destroy` returns
    early. That folder and the ones that contain it cannot be renamed while the process lives.
    Reproducer: create `W/D/maps`, walk `W` with `os.walker_walk`, destroy the walker and rename
    `W/D`: `Permission_Denied`.
  - Workaround: `registry_scan` (`asset/registry.odin`) walks the folders with
    `os.read_directory_iterator` and destroys each iterator; without it, moving a folder of the
    content browser failed. The other uses of `os.walker_walk` remain.
  - To test: with a version that resolves it, the reproducer renames the folder; go back to the
    walker and run `mirai test editor a_folder_moves_and_copies_with_all_it_holds`.
- **`#force_inline` silently not inlined at `-o:none` and `-o:minimal`** (odin-lang/Odin#7780,
  with the reproducer below in a comment; odin-lang/Odin#6410).
  - Defect: at `-o:none` no call is inlined, and at `-o:minimal` a call is not inlined when the
    package is split into several modules (`pkg-file$1`, `$2`, …) and the callee lands in another
    one (seen in the encoder, without a standalone reproducer); neither warns. Inlining that
    changes the result is then lost: a `#simd[4]u64` passed by value from an
    `enable_target_feature="avx2"` procedure to a callee built without AVX2 travels in different
    registers on each side. Reproducer: `a.odin` with
    `twice :: #force_inline proc "contextless" (x:$T) -> T {return simd.shl_masked(x,T(1))}`,
    `b.odin` with `@(enable_target_feature="avx2") work :: proc "contextless"
    (p:^#simd[4]u64) {p^=twice(p^)}` and a `main` that calls `work`; `odin run . -o:none`
    crashes with an access violation.
  - Workaround: the BC7Split kernels (`std/compressor/bc7split/kernels.odin`) pass `[4]u64` arrays
    between procedures, which go through memory, and use `#simd` only inside a procedure;
    at `-o:speed` everything is inlined and is vector code again.
  - To test: with a version that inlines or warns, the reproducer runs at `-o:none`; go back to
    `Lanes :: #simd[LANES]u64` and run `mirai test std/compressor/bc7split` with `-o:none` and the
    BC7 `.tex` files of the demo through `mirai asset verify`.
- **`simd.reduce_add_bisect` of a widened byte difference keeps half the sum**
  (llvm/llvm-project#239204; a defect of LLVM's x86 backend, also in LLVM trunk).
  - Defect: `simd.reduce_add_bisect(cast(#simd[16]u32)(simd.max(a,b)-simd.min(a,b)))` is emitted
    as a tree of shuffles and adds, which LLVM turns into `psadbw`, whose sums of bytes 0-7 and
    8-15 land in two 64-bit lanes, and returns only the low one, at every optimization level.
    Reproducer: a procedure that takes `a` and `b` by pointer and returns that sum, with bytes
    8 to 15 of `a` set to `len(os.args)*5` and bytes 0 to 3 of `b` set to `len(os.args)*3`:
    `odin run .` prints 12 instead of 52.
  - Workaround: the byte SADs of the texture encoder (`sad_u8x16` in
    `cook/compressor/texture/common/vector.odin`, `sad_halves` in `vector_other.odin`) use
    `simd.reduce_add_ordered`, which becomes `llvm.vector.reduce.add` and adds both lanes.
  - To test: with an LLVM that resolves it, the reproducer prints 52 at `-o:minimal` and
    `-o:speed`.
- **A 32-byte `simd.runtime_swizzle` is scalar code with AVX2** (odin-lang/Odin#8199).
  - Defect: in an `enable_target_feature="avx2"` procedure, `simd.runtime_swizzle` of two
    `#simd[32]u8` is lowered to one extraction and insertion per byte, scalar code with `pinsrb`,
    instead of `vpshufb` and blend sequences; of `#simd[16]u8` it is one `pshufb`. Reproducer: an
    exported `avx2` procedure that stores `simd.runtime_swizzle(a^,b^)` of two `^#simd[32]u8`,
    built with `-build-mode:asm -o:speed`.
  - Workaround: the 256-bit kernels of the texture encoder (`cook/compressor/texture/common` and
    `bc7`, `dispatch_amd64.odin`) shuffle with `x86._mm256_shuffle_epi8` and
    `x86._mm256_permutevar8x32_epi32` within 128-bit lanes, under the comment that names this.
  - To test: with a version that lowers it, the reproducer has no `vpinsrb`; the kernels can go
    back to `simd.runtime_swizzle`.
- **A `#simd[W]T` parameter with a polymorphic `$W` is rejected** (odin-lang/Odin#8198).
  - Defect: a parameter type that uses an earlier `$W:int` is checked with `W` 0, so
    `total :: proc($W:int,v:#simd[W]u32) -> u32` fails with `Invalid length for #simd, expected
    a power of two length, got '0'`; `v:$V/#simd[$W]$E`, a `#simd[W]T` return and `#simd[W]T`
    declared in the body work. Reproducer: that `total` called as `total(4,v)` with a
    `#simd[4]u32` in `odin build`.
  - Workaround: the texture encoder writes one kernel body per vector width (the 128-bit body of
    `common/vqhelp.odin` and `bc7/quant.odin`, the 256-bit and 512-bit ones of
    `dispatch_amd64.odin`) instead of one body over the width.
  - To test: with a version that resolves it, the reproducer builds and prints 10.
- **Slow Linux Odin with many modules** (no issue).
  - Defect: the nightly in `.deps/odin/linux-amd64` is static with musl. Compiling the runtime
    packages of the engine as one library at `-o:minimal` with `/usr/bin/time` gives 116 s of
    processor time, 68 of them in the kernel, against 25 s for master with the same LLVM 20 and
    glibc.
  - To test: with a Linux nightly linked against glibc, repeat that compilation.

## Slang and SPIRV

Defects of the tools that translate the shaders (`cook/shaders`).

- **Slang 2026.20 does not compile separately a stage that calls an `extern` function**
  (shader-slang/slang#14212 and #6607).
  - Defect: with `-incomplete-library -target spirv`, `slangc` crashes without a diagnostic if
    the stage calls the `extern` function inside a loop, and a module that only exports functions
    gives `E57004`.
  - Workaround: the stages that trace include the alpha of the programs with coverage
    (`surface_coverage.slang`), and their fingerprint follows that compiled alpha: an edit that
    changes it recompiles them.
  - To test: with a Slang that closes both, compile a ray stage with the `extern` alpha and link
    to it that of a program with `spirv-link`; if the linked stage costs the same, the stages that
    trace are compiled once and the alpha of each program separately.

- **SPIRV-Tools 2026.3 and 2026.4 crash when optimizing `fsr3_prepare_reactivity.comp` and
  `fsr3_shading_change.comp`** (KhronosGroup/SPIRV-Tools#7005).
  - Defect: `--loop-unroll` leaves a use before its definition when the header of a loop jumps
    straight to its continue, and `merge-blocks` crashes afterwards on that module. With what Slang
    generates at `-O1` the module optimizes.
  - Workaround: `cook/shaders` compiles those two stages with `-O1` instead of
    `SLANG_OPTIMIZATION` (`shader_reduced`).
  - To test: when the SDK ships a SPIRV-Tools with the fix, the `spirv-opt -O` of `.deps`
    (v2026.4.rc2 `ef96ed76` and the v2026.3 of the Vulkan SDK still crash on both) optimizes the
    two stages; remove the workaround.
- **SPIRV-Cross of the SDK without `--msl-resource-binding`** (KhronosGroup/SPIRV-Cross, option
  added on 2026-10-17).
  - Defect: it gives the argument buffer of the texture table the index of its set (1), among the
    slots.
  - Workaround: `metal_table_buffer` (`cook/shaders`) rewrites it to `TEXTURE_TABLE_METAL_BUFFER`.
  - To test: with a SPIRV-Cross that has it (those in `.deps`, `f11ba9f0` of 2026-09-27 and the
    one in Vulkan SDK 1.4.350, do not), pass `--msl-resource-binding 1 4294967292 30 0 0` (the
    binding is `kArgumentBufferBinding`) and remove the rewrite.
