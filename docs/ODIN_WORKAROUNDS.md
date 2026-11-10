# Dependency workarounds and defects

Workarounds for defects in dependencies that Mirai does not control. When moving to a new version,
test each one without its workaround and remove those that are no longer needed, with their comment
and their mention in the skills. An entry without an issue is not yet reported; publishing it
requires the user's confirmation.

## Odin

Entries are for Odin `dev-2026-11`.

| Marker in code | Upstream | Remove when |
| --- | --- | --- |
| `inner_procs_odin` (`cook/build/declare.odin`): writes the procedure types of a `foreign` block as `proc "odin"` | none | `@(default_calling_convention="odin") foreign x { f :: proc(cb:proc()) --- }` compiles with an Odin procedure passed as `cb` |
| `job_plugin_name` (`cook/build/build.odin`): names the output of a plugin library by its index, so the objects of `-use-separate-modules` stay under `MAX_PATH` on Windows | none | `odin build pkg -build-mode:dll -use-separate-modules` of a package that imports another links with an output folder of about 250 characters |
| `schema_push` (`std/serial/schema.odin`): never takes a key back out of a `map[typeid]T` | none | `delete_key` on a `map[typeid]u32` builds at `-o:speed` (a `main` that puts `typeid_of(int)` in it and takes it out) |
| `preview_shader` (`render/shader_assets.odin`): a `switch` instead of `for e in S` over a `bit_set` of an enum of more than 128 values | odin-lang/Odin#8047 | `for e in S {}` over `S :: bit_set[E; [4]u64]{.A, .B}` with `E :: enum u8 {A, B = 129}` builds and iterates both values |
| `child_environment` (`cook/build/platform.odin`): skips the empty entries of `os.environ` | odin-lang/Odin#7964 | `env -i A=1 B=2` gives `["A=1","B=2"]` on Linux, and no repeated first entry on Darwin and the BSDs |
| `// One store per value until odin-lang/Odin#7937` and `core.world_swap` (`core/world_data.odin`, which swaps the storages by memory): one assignment per value instead of a multiple assignment of more than 64 bytes | odin-lang/Odin#7937 | the multiple form no longer reaches LLVM as a whole-aggregate `store` or temporaries; `mirai test cook/build no_store_of_an_aggregate_of_more_than_64_bytes` (limit `IR_SPLIT_LIMIT`) lists the sites to revert, and `mirai build engine --release --force` does not get slower |
| `std/subprocess` on Windows (`subprocess_windows.odin`): creates the processes instead of `core:os` (no console window, handles that are not inherited, empty arguments kept, a wait that sleeps) | odin-lang/Odin#7966, #7967, #7968, #7969 | `core:os` does all of that; go back to it in `std/subprocess` and run `mirai test std/subprocess` |
| `.ptr spelled out` (`engine/render/render.odin`, `plugins/multiplayer/runtime`, `plugins/ragdoll/runtime`): the ternaries on a field of a `core.Ref` name `.ptr` | odin-lang/Odin#8093 (relative of #6548) | with `R :: struct($T:typeid) {using ptr:^T}`, `r.ptr!=nil?r.b:7` returns 7 for a nil `r.ptr` at `-o:none` |
| `swap_values` (`editor/documents.odin`): the eight swaps of `document_tab_exchange` | odin-lang/Odin#8113 (same lowering as #7937) | the Odin of Linux and macOS ships LLVM 22; go back to the multiple form and run `mirai test editor prefab_selection_and_file_overrides_share_the_undo_history --release` on Linux |
| `process_kill_pid` (`tools/mirai/session_windows.odin`): opens the process with `PROCESS_TERMINATE` | odin-lang/Odin#8092 | `os.process_kill` terminates a process from `os.process_open` (a `ping -n 30 127.0.0.1`) |
| `process_alive` (`std/subprocess/subprocess.odin`): takes a handle 0 for a process that is not there | odin-lang/Odin#8091 | `os.process_open` of the pid of an ended process returns an error |
| `base.dynamic_arena_allocator` (`std/base/alloc.odin`): every `Dynamic_Arena` of the engine uses it instead of `mem.dynamic_arena_allocator` | odin-lang/Odin#8103 | `dynamic_arena_without_memory_keeps_refusing` of `std/base` passes with `mem.dynamic_arena_allocator` |
| `registry_scan` (`asset/registry.odin`): walks with `os.read_directory_iterator` and destroys each iterator | odin-lang/Odin#8112 | after `os.walker_walk` and `os.walker_destroy` over `W/D/maps`, `W/D` can be renamed on Windows; go back to the walker and run `mirai test editor a_folder_moves_and_copies_with_all_it_holds` |
| the BC7Split kernels (`std/compressor/bc7split/kernels.odin`): `[4]u64` arrays between procedures and `#simd` only inside one | odin-lang/Odin#7780, #6410 | `-o:none` inlines `#force_inline` calls (or warns), so a `#simd[4]u64` passed from an `enable_target_feature="avx2"` procedure survives; go back to `Lanes :: #simd[LANES]u64` and run `mirai test std/compressor/bc7split` at `-o:none` |
| `sad_u8x16` (`cook/compressor/texture/common/vector.odin`) and `sad_halves` (`vector_other.odin`): `simd.reduce_add_ordered` | llvm/llvm-project#239204 | `simd.reduce_add_bisect` of a widened byte difference returns the whole sum at `-o:minimal` and `-o:speed` |
| the 256-bit kernels (`cook/compressor/texture/common/dispatch_amd64.odin`, `cook/compressor/texture/bc7/dispatch_amd64.odin`): `x86._mm256_shuffle_epi8` and `x86._mm256_permutevar8x32_epi32` | odin-lang/Odin#8199 | `simd.runtime_swizzle` of two `#simd[32]u8` in an `avx2` procedure has no `vpinsrb` with `-build-mode:asm -o:speed` |
| `base.remove_all` (`std/base/remove_all.odin`): every folder of the engine and its tests is removed with it instead of `os.remove_all`, whose Windows version calls `SHFileOperationW`; the shell raises first-chance C++ exceptions inside it, and the vectored handler of `core:testing` stops the test for any of them ("Signal caught: Unknown"), or kills the runner when the cleanup of a stopped test runs on the main thread | none | `os.remove_all` on Windows walks the folder with `DeleteFileW` and `RemoveDirectoryW`, and `core:testing` on Windows lets an exception that a handler of the program catches go by; go back to `os.remove_all` and run the editor tests of `ai_subagents_test.odin` and `sections_test.odin` together |
| `constant_field_compare` (`engine/render/graphics_test.odin`): compares a field of a constant through `testing.expect_value` | none | with `A :: struct {x:f32, e:E}` and `C :: A{x=1}`, `C.e == .Off` (a field the literal leaves out compared with `==`) is true; today it folds to false |
| one kernel body per vector width (`cook/compressor/texture/common/vqhelp.odin`, `bc7/quant.odin`, `dispatch_amd64.odin`) | odin-lang/Odin#8198 | `total :: proc($W:int,v:#simd[W]u32) -> u32` builds |

## Slang and SPIRV

Defects of the tools that translate the shaders (`cook/shaders`).

| Marker in code | Upstream | Remove when |
| --- | --- | --- |
| `SURFACE_COVERAGE_INCLUDE` (`cook/shaders/programs.odin`): the stages that trace include the alpha of the programs with coverage, and their fingerprint follows it | shader-slang/slang#14212, #6607 | `slangc -incomplete-library -target spirv` compiles a stage that calls an `extern` function in a loop and a module that only exports functions links; a ray stage with the `extern` alpha plus the alpha of each program linked with `spirv-link` then costs the same |
| `shader_reduced` (`cook/shaders/shaders.odin`): compiles `fsr3_prepare_reactivity` and `fsr3_shading_change` with `-O1` | KhronosGroup/SPIRV-Tools#7005 | the `spirv-opt -O` of `.deps` and of the Vulkan SDK optimizes both stages |
| `metal_table_buffer` (`cook/shaders/shaders.odin`): moves the argument buffer of the texture table to `TEXTURE_TABLE_METAL_BUFFER` (`rhi/rhi.odin`) | none | the SPIRV-Cross of `.deps` and of the SDK has `--msl-resource-binding`; use it to place the table |

## Drivers

Defects of GPU drivers that the GPU tests reach.

| Marker in code | Upstream | Remove when |
| --- | --- | --- |
| `keep_one` (`rhi/shared_device/shared_device.odin`): the GPU tests of a process keep one device alive from the first `hold` to the end; the NVIDIA Windows driver 616.92 (`nvoglv64.dll`) frees the context of the worker threads of the last device of a process while they still run, and one of them then calls through freed memory (0xC0000005) | none | without `keep_one`, `mirai test rhi/tests rhi_devices_are_created_and_destroyed_in_turn_and_on_several_threads` passes 20 runs in a row under `MIRAI_VALIDATION=1` on that driver's successor |
