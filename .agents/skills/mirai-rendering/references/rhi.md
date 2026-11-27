# RHI (`rhi/`)

Explicit GPU API: Vulkan (Linux/Windows) and Metal (macOS), chosen via compile-time build tags
without virtual dispatch. `render` never sees native handles.

## RHI contract

- **Handles & capacities.** Generational handles (`Buffer`, `Texture`, `Sampler`, `Pipeline`,
  `Accel`; 0 = invalid); destruction defers until in-flight GPU frames finish. Fixed pools
  (`Device_Desc.capacities`, `DEFAULT_DEVICE_CAPACITIES`, `Device_Desc.allocator`) return 0 on
  full, set `device_error` and increment `device_stats().exhausted` (counts exclude internal
  objects). Per-slot `deletions` waits between frames and grows in-frame (`deletion_overflows`).
- **Memory, names & init.** Vulkan suballocates blocks per memory type (`rhi/vulkan_memory.odin`,
  `rhi/arena.odin`), respecting `maxMemoryAllocationCount`; `GPU` avoids BAR and spills to system
  RAM (`device_stats().host_memory`, `Stats.problem`). Names appear in debuggers and
  `device_memory_report` vs `device_memory`. New buffers read zero (Vulkan `GPU` zero-fills unless
  whole-buffer uploaded); new textures are undefined.

## Device

- **Selection.** Discrete > Integrated > Virtual > CPU (lavapipe); `Device_Desc.preferred_device`
  substring overridden by `MIRAI_GPU=<text>`. With `Device_Desc.surface`, Vulkan requires a
  presenting graphics+compute queue.
- **Messages & tables.** Silent by default; `Device_Desc.on_message` receives errors/validation
  (`message_print` -> stderr). Vulkan uses per-device `Device.ivk`/`Device.dvk`, never
  `vendor:vulkan` globals; multi-threaded create/destroy shares `Device_Desc.loader_lock`
  (`App_Desc.gpu_loader_lock`; ignored on Metal).
- **Validation.** `Device_Desc.validation` / `MIRAI_VALIDATION=1` enables Vulkan + sync validation;
  Metal uses `MTL_DEBUG_LAYER=1` ([GPU env](verification.md#gpu-environment)).
  `VALIDATION`/`PERFORMANCE` errors count in `device_validation_errors`
  (`device_validation_messages`, `VALIDATION_HISTORY`); `GENERAL` goes to `device_loader_errors` as
  `Loader_Warning` (`[loader]`). Metal reports 0.

## Device loss

- **Single path (`rhi/rhi.odin`).** All loss points call `device_fail` (keeps first);
  `device_failure` returns `Lost` (reset/fault/removed + `VK_EXT_device_fault`) or `Hung`.
- **Stop place (`Features.stop_place`).** Reports open labels, `cmd_timestamp` section and pipeline
  name via Vulkan `VK_AMD_buffer_marker` (`rhi/vulkan_marks.odin`) or Metal
  `MTLCommandBufferErrorOptionEncoderExecutionStatus`.
- **Post-failure & waits.** `frame_begin`, `immediate_end`, `device_wait_idle`, uploads/reads
  return `false` immediately; destroy stays valid. Vulkan waits cap at `GPU_WAIT_LIMIT_NS`
  (hidden-window swapchain timeout skips frame; hung Vulkan skips teardown on destroy). Metal OS
  `Timeout` maps to `Hung`. `device_lose` injects loss after next submit (`provoked by device_lose`;
  recovery: [host](../../mirai-core/references/host.md#gpu-that-stops-working)).

## GPU watchdog

- `MIRAI_GPU_WATCHDOG_MS=<limit>` (`WATCHDOG_VARIABLE`) arms on create (invalid value refuses
  device); unwatched tool runs set `WATCHDOG_UNWATCHED_MS`, interactive terminals stay unlimited.
- Submissions signal timeline/shared event (`watchdog_sent`); waiter + CPU-clock timer threads log
  one stderr line (frame, wait, stop place, `Frame_Passes`) past `limit` ms and hard-exit with
  `WATCHDOG_EXIT_CODE` (`TerminateProcess`/`_exit`). API failure disarms it.
- `Device_Desc.late_record` + `late_ms` flushes late submissions to disk and deletes on finish;
  leftovers report freezes/resets on startup. Metal cannot report stop place while hung. Kills
  backlogs, but one unpreemptable > 2 s dispatch still triggers OS TDR (`LiveKernelEvent 141`).

```odin
dev, err := rhi.device_create({
    app_name = "app", validation = true, allow_hardware_ray_tracing = true,
    upload_bytes_per_frame = 8 << 20, pipeline_cache_path = "pipelines.bin",
    on_message = rhi.message_print,
})
if dev == nil { return err }
if kind, text := rhi.device_failure(dev); kind != .None { return text }
```

## Frames and presentation

- `MAX_FRAMES_IN_FLIGHT` (2) with per-frame upload ring; oversized `frame_alloc` allocates a
  per-frame buffer (capped at `max_storage_range`, `MAX_FRAME_OVERSIZED`).
- Between frames: `buffer_upload`, `texture_upload`, `texture_upload_levels` and
  `immediate_end(wait = false)` are non-blocking; other immediates, BLAS builds and readbacks block.
- Metal acquires <= 1 drawable ahead (no-VSync renders offscreen if busy, `swapchain_texture == 0`).
  Vulkan without `VK_EXT_swapchain_maintenance1` recycles present semaphores via `vkDeviceWaitIdle`
  and recreates lost surfaces via `Surface_Desc.vulkan_create` up to `VK_SURFACE_TRIES`.

## Paced presentation

`rhi/present.odin`: `swapchain_set_paced(d, true)` renders into `PRESENT_PAIRS` image pairs
(`swapchain_generated_texture`, `swapchain_texture`); `frame_end(cmd, generated)` hands the pair to
a presenter thread (`present_gpu_wait`, `present_image`) that copies to swapchain and presents
generated then own half a smoothed interval apart (excluding pair wait; sleeps + 1 ms spin).
Resizes/stale/off drain the thread; copy-incapable swapchains stay refused until toggled off.
Vulkan uses private pool/semaphores/timeline + `queue_lock`; Metal presenter acquires drawables.
`present_stats` reports counts, interval sums and latency.

```odin
rhi.swapchain_set_paced(dev, true)
// Draw generated image to swapchain_generated_texture(dev), real to swapchain_texture(dev).
stats := rhi.present_stats(dev)
```

## Bindings and texture table

- **Slots.** Binding N -> Vulkan set 0 binding N (push descriptors) / Metal index N. Parameters use
  uniform buffers (no push constants); caps `MAX_*_BINDING_SLOTS`, one kind per slot per pipeline.
- **Texture table.** Set 1 unsized sampled array: Vulkan `runtimeDescriptorArray` +
  `descriptorBindingVariableDescriptorCount`; Metal Tier 2 arg buffer at
  `TEXTURE_TABLE_METAL_BUFFER`, member `TEXTURE_TABLE_SLOT` (`--msl-device-argument-buffer 1`,
  per-encoder `useResources`). Starts `TEXTURE_TABLE_FIRST`, doubles up to `texture_table_limit`
  (`TEXTURE_TABLE_MAX` or Vulkan cap), white-texel default; `TEXTURE_TABLE_COPIES` copies sync at
  list begin so `texture_table_set` never blocks.
- **Textures.** Uploads take full mips or block-aligned regions (`texture_region_resolve`,
  `Features.texture_bc` for BC1/5/6H/7); `texture_read` restores `Sampled`. `cmd_copy_texture`
  copies mip 0 raw bytes across matching/sRGB-pair formats (`texture_copy_problem`). Arrays/cubes
  (`layers`, `cube`, `max_texture_layers`, `texture_layers_problem`) stay outside the 2D-only table;
  3D textures (`depth > 1`) are `Storage` only.

## Synchronization and commands

- Automatic hazard tracking per resource (per-mip for textures, coalescing runs). Vulkan buffers
  render passes and emits barriers before start; targets are 1 mip/layer (sampling same mip or 2
  mips of target errors). Use `cmd_barrier_*` for host read, texture table or shared textures.
  Vulkan derives every barrier from the bindings of a dispatch or of a pass's draws, waiting in
  compute, or in the stages of the draw that bind the resource; an explicit barrier waits in every
  shader stage (texture-table reads have no binding). Metal tracks across encoders with one serial
  compute encoder at a time: concurrent dispatch measured no gain on frames that are mostly chains,
  and reads through the texture table would escape a tracker of bindings. Clip space is Y-up,
  depth `[0, 1]` (reversed Z in `render`). `cmd_fill_buffer` repeats one byte (copy
  `dispatch_start` for structured words).

## Textures shared between processes

- `texture_create_shared` / `texture_open_shared` share 1-mip, 4 B/texel textures on the same GPU
  (`device_shares_textures`; size/format mismatch fails). Metal: global IOSurface (byte-order
  format). Vulkan: size+format checksum (Linux `pidfd_getfd`, Windows keeps creator handle). No
  shared semaphores: wait GPU and leave in shader-read layout before signaling.

```odin
if rhi.device_shares_textures(dev) {
    desc := rhi.Texture_Desc{
        width = 1280, height = 720, format = .BGRA8_Unorm,
        usage = {.Color_Target, .Sampled}, name = "shared frame",
    }
    tex, shared := rhi.texture_create_shared(dev, desc)
    // Peer process opens with rhi.texture_open_shared(peer_dev, desc, shared).
    _ = tex; _ = shared
}
```

## Hardware ray tracing

- Vulkan (`VK_KHR_acceleration_structure` + `VK_KHR_ray_query`): active after `render/selftest.odin`
  passes, else software BVH (`MIRAI_RT=software`). Metal (`MTLAccelerationStructure` user IDs):
  hardware-only (`MIRAI_RT` ignored; missing RT/failed self-test/missing `_hw` pipeline errors in
  `renderer_create`).
- `cmd_build_tlas` translates neutral `Tlas_Instance` buffers via `tlas_instances.comp.slang`
  (`tlas_translator_set` before self-test). BLAS/TLAS suballocate from `ACCEL_BLOCK_BYTES` blocks
  (`rhi/arena.odin`, `accel_memory`). Build failure sets `device_error`; renderer retries and sets
  `Stats.problem` (`engine.status` `renderer_problem`, `engine.diagnostics` `renderer`).

```odin
inst := rhi.Tlas_Instance{
    transform = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}},
    custom_index = 0, blas = rhi.accel_id(dev, blas),
    mask_flags = 0xff | rhi.TLAS_ALPHA_GEOMETRY,
}
ok := rhi.cmd_build_tlas(cmd, tlas, instance_buf, 0, 1)
```

## Shader constants

- Up to `MAX_SHADER_CONSTANTS` boolean `Shader_Code.constants` per shader; pipelines set true bits
  via `Shader_Constants` (`Compute_Pipeline_Desc.constants`,
  `Graphics_Pipeline_Desc.vertex_constants`/`fragment_constants`), folded via Vulkan
  `VkSpecializationInfo` or Metal `[[function_constant(id)]]` (`MTLFunctionConstantValues`, shared
  library). Undeclared ids error; look up via `shader_constant(code, name)`.

```odin
pipe := rhi.pipeline_create_compute(dev, {
    shader = &shader_code, constants = {0}, name = "pass specialized",
})
```

## Pipeline cache

- Vulkan (`rhi/pipeline_store.odin`): per-pipeline `VkPipelineCache` content-chunked blobs at
  `Device_Desc.pipeline_cache_path` (or memory-only), keyed by code+constants+state, validated
  against device/driver/UUID, atomically renamed after `PIPELINE_STORE_SAVE_SHARE`x write cost and
  on destroy, LRU-capped at `PIPELINE_STORE_BYTES`, merging concurrent writers and cleaning stale
  staging (`serial.file_remove_stale`). Metal shares library/function; free `Shader_Code` after.

## Pipelines from other threads

- `pipeline_create_compute` and `pipeline_create_graphics` run on worker threads while the frame
  thread records ([host loading](shaders.md#loading-in-host); Vulkan caches omit
  `EXTERNALLY_SYNCHRONIZED`). `Device.pipeline_lock` guards pipelines, `message_lock` guards
  messages, `pool_get` is slot-local. Destruction stays on the frame thread.
- How many compile at once (`create_pipelines`, `Pipeline_Thread`) is bounded by physical cores and
  by memory (`Pipeline_Memory`): one compile can take gigabytes in the driver (software tracer on
  Mesa/amdvlk), so each beyond the first waits until `base.memory_stats` leaves room for the
  per-compile charge learned in this run (a quarter of RAM until one is measured).
- GPU tests share one store: `mirai test` sets `MIRAI_PIPELINES_PATH` to
  `bin/tests/gpu-test-pipelines.bin`, read by `shared_device` and by `host.app_create`.

## Limits

- Metal fast math can cancel NaN guards—eliminate NaN sources directly.
