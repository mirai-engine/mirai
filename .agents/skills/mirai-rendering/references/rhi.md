# RHI (`rhi/`)

Explicit, common GPU API: Vulkan on Linux and Windows, Metal on macOS. The backend is chosen at
compile time with build tags, without virtual dispatch. `render` does not see native handles.

## RHI contract

## Resources and capacities

- **Generational handles** (`Buffer`, `Texture`, `Sampler`, `Pipeline`, `Accel`), zero is
  invalid. A destroyed handle returns `nil`; destruction is deferred until the GPU has finished
  the frames that could use the resource.
- **Fixed capacities** (`Device_Desc.capacities`, `DEFAULT_DEVICE_CAPACITIES` by default),
  allocated once with `Device_Desc.allocator`. Creating one more returns the zero handle, leaves
  the message in `device_error` and adds to `device_stats().exhausted`. The live counts of
  `device_stats` are those the user made: what the device does for itself (rings and what goes
  past them, scratch, upload staging, structure blocks, the table default)
  does not count.
- **Device memory.** On Vulkan, buffers and textures take ranges of blocks of memory, per memory
  type (`rhi/vulkan_memory.odin`), with the range allocator of the acceleration structures
  (`rhi/arena.odin`). Only a resource too large for a block, or one the driver prefers alone,
  takes an allocation of the driver, and their count never passes `maxMemoryAllocationCount`; a
  refusal says in `device_error` whether the memory or that count ran out. `GPU` memory is
  device memory, never the small heap the CPU sees of a discrete GPU (BAR); with device memory
  full a resource goes to system memory instead of being refused, counted in
  `device_stats().host_memory` and reported in the renderer's `Stats.problem`.
- **New contents.** A new buffer reads zero on both backends; the texels of a new texture are
  undefined until something writes them (`Buffer_Desc`, `Texture_Desc`). On Vulkan a range held
  another resource before, so the device zeroes a buffer of `GPU` memory with a fill in the next
  command list, which an upload of the whole buffer spares.
- Each frame slot keeps up to `deletions` destroyed objects. Between frames, a full slot waits
  for the GPU and frees them; within a frame the list grows and is counted in
  `deletion_overflows`.

## Device

- **Selection.** Discrete, integrated, virtual GPU and finally CPU. `Device_Desc.preferred_device`
  selects by part of the name; `MIRAI_GPU=<text>` overrides it. Without a GPU, Linux can use
  lavapipe. The window comes in `Device_Desc.surface` and is made with the device: on Vulkan
  its surface exists before the selection, which passes over every device without a
  graphics+compute queue that presents to it, the preferred one included.
- **Messages.** The device does not print: errors and validation reach `Device_Desc.on_message`;
  `message_print` writes them to stderr.
- **Per-device tables.** Vulkan calls through the tables loaded per device (`Device.ivk`,
  `Device.dvk`), never through the package pointers of `vendor:vulkan`: devices with different
  extensions coexist in one process.
- **Loader lock.** Whoever creates or destroys devices from several threads passes the same
  `sync.Mutex` in `Device_Desc.loader_lock` to all of them (`App_Desc.gpu_loader_lock` in `host`);
  with `nil` there is no lock. Metal does not read it.
- **Validation.** `Device_Desc.validation` or `MIRAI_VALIDATION=1` enables the Khronos layer with
  synchronization validation; on Metal, `MTL_DEBUG_LAYER=1`
  ([GPU environment](verification.md#gpu-environment)).
- **Classification.** Only an ERROR of type VALIDATION or PERFORMANCE counts in
  `device_validation_errors`. A GENERAL one (loader, third-party layers such as the Epic overlay)
  goes to `device_loader_errors` and arrives as `Loader_Warning` (`[loader]`).
  `device_validation_messages` reads the last ones (`VALIDATION_HISTORY`). On Metal both counts
  are 0.

## Device loss

- **A single path.** Every point where the API reports a loss (submit, present, acquiring an
  image, waits, fences, queries, maps) passes its result through `device_fail`
  (`rhi/rhi.odin`), which keeps the first failure with the call that saw it; each backend
  translates its result in its own file: Vulkan, `VK_ERROR_DEVICE_LOST`; Metal, a command buffer
  with an error. `device_failure` returns it typed: `Lost` (the API reported it: a watchdog reset,
  an access fault, a removed GPU) or `Hung` (the work did not finish). With
  `VK_EXT_device_fault` the text carries what the driver says about the fault.
- **Afterwards nothing is waited on or submitted.** `frame_begin`, `immediate_end`,
  `device_wait_idle`, uploads and reads return `false` at once, without aborting; destroying is
  still allowed.
- **Waits with a limit.** On Vulkan no wait exceeds `GPU_WAIT_LIMIT_NS`, above what drivers give a
  submit before the reset (2 s on Windows): a driver that resets reports `Lost` earlier. A
  swapchain image that does not arrive within that limit skips the frame without marking
  anything: a compositor holds the images of a hidden window. Metal waits with no limit of its
  own: the system watchdog cuts a hung command buffer and reports it as `Timeout`, which is
  `Hung`.
- A Vulkan device whose wait exceeded the limit does not destroy its objects when destroyed: the
  GPU may still be working on them; the driver frees them when the process ends.
- `device_lose` makes the next submit report the loss after its work went and finished: tests
  provoke the reaction without resetting the machine's GPU, and the text says so
  (`provoked by device_lose`). What the application does afterwards:
  [host](../../mirai-core/references/host.md#gpu-that-stops-working).

## Frames and presentation

- Two frames in flight (`MAX_FRAMES_IN_FLIGHT`); the CPU does not wait for the GPU on every
  frame. Each frame has an upload ring for constants and dynamic data, which a GPU copy
  (`cmd_copy_buffer`) can write before the shaders read it. A `frame_alloc` past the room of the
  ring takes a buffer of its own, released with the frame, so an upload of any size (a load, a
  table that grew) reaches the GPU in the frame that asks for it; only a size past
  `max_storage_range`, or more of them in a frame than `MAX_FRAME_OVERSIZED`, is refused and adds
  to `device_stats().exhausted`.
- **Blocking transactions** (immediate uploads, initial BLAS builds, readback and capture): only
  between frames.
- **Presentation on Metal.** A thread acquires at most one drawable ahead. With VSync,
  `frame_begin` waits for the delivery; without VSync, a frame with no free image renders
  offscreen (`swapchain_texture` zero) and keeps its LDR for capture.
- **Vulkan swapchain.** Without `VK_EXT_swapchain_maintenance1`: the presentation semaphores are
  recycled after `vkDeviceWaitIdle`. A surface the platform reports lost (a display change, a
  driver reset) skips that frame; the next one makes surface and swapchain again from the window
  through `Surface_Desc.vulkan_create`. After `VK_SURFACE_TRIES` frames that cannot, the window
  stays without images and `device_error` says so; the device keeps working.

## Paced presentation

For a renderer that generates frames (`rhi/present.odin`):

- `swapchain_set_paced(d, true)` makes every frame, from the next `frame_begin`, draw into a
  pair of device images (`PRESENT_PAIRS` pairs, of the swapchain size and format): the generated
  one (`swapchain_generated_texture`) and the own one (`swapchain_texture`). `frame_end(cmd,
  generated)` hands the pair to a device thread; without `generated` it shows only the own one.
- The thread waits for the frame's GPU work, copies each image to a swapchain one and presents
  it: the generated one half an interval after the previous own one and the own one half an
  interval after the generated one, each counted from when the previous one was handed over. The
  interval is that of the frames, smoothed and without what they waited for their pair: counted,
  that wait is the thread's own pace, which would grow with its work on each frame. It sleeps and
  spins the last millisecond.
- A single algorithm; each backend provides `present_gpu_wait` and `present_image`. On Vulkan the
  thread has its own pool, its own semaphores and its own timeline, which the frame that draws
  into the pair again waits on; the queue is used under `queue_lock`. On Metal the textures are
  tracked and the thread takes the drawables (the acquisition one stops).
- A frame waits for the thread to release its pair; an old swapchain, a resize or turning the pace
  off first drain the thread. A swapchain whose images do not accept copies is not requested again
  until it is turned off.
- `present_stats` gives the presented and generated images, the sum and the sum of squares of
  their intervals and the latency: from the start of the frame to its image going to the display
  with its GPU work finished. Without the thread, the GPU is assumed to start each frame when it
  is submitted and when the previous one finishes.

## Bindings and texture table

- **Bindings by slot.** Binding N of a shader is binding N of set 0 on Vulkan (push
  descriptors) and index N of buffer, texture or sampler on Metal. Parameters go in uniform
  buffers of the ring, not in push constants. The limits are `MAX_*_BINDING_SLOTS`; a slot does
  not have two types in the same pipeline.
- **Texture table.** The textures that a shader chooses by index (material maps) are an array
  without a size in set 1: on Vulkan, a non-uniform indexed descriptor set of a variable count
  (`runtimeDescriptorArray`, `descriptorBindingVariableDescriptorCount`); on Metal, an argument
  buffer (Tier 2) in device memory at buffer index `TEXTURE_TABLE_METAL_BUFFER`, with the table as
  its member `TEXTURE_TABLE_SLOT` (SPIRV-Cross `--msl-device-argument-buffer 1`).
  - It starts with `TEXTURE_TABLE_FIRST` entries and doubles when `texture_table_set` names an
    entry past it, up to `texture_table_limit`: `TEXTURE_TABLE_MAX` (what Metal's Tier 2 argument
    buffers give an application), or less on a Vulkan device whose sampled image limits are lower.
    Growing makes new copies with every entry, between frames, and defers the old ones; a stable
    frame allocates nothing.
  - Every entry is a valid texture: it starts as a white texel and returns to it when its texture
    is destroyed.
  - There is one copy of the table per frame in flight and one for the immediate lists
    (`TEXTURE_TABLE_COPIES`). `texture_table_set`, between frames, does not wait for the GPU: it
    records the entry, and each copy takes the ones that changed when its list begins, when the
    GPU no longer reads it. A texture that leaves the table stays alive in the copies in flight
    because its destruction is deferred.
  - Metal does not track the references of an argument buffer: each encoder that binds the table
    makes its textures resident (`useResources`).
- An upload writes a whole mip or a region in whole blocks (`texture_region_resolve`) of all the
  layers, one after another in the data; `texture_read` leaves in shader-read state a texture that
  has only the `Sampled` usage. BC1, BC3, BC5, BC6H and BC7 are uploaded by blocks where
  `Features.texture_bc` says the device samples them.
- `cmd_copy_texture` copies mip 0 of a texture into another on the GPU, with its bytes as they
  are: the two have one size and layers, and one format or two that differ only in the sRGB
  encoding (`texture_copy_problem`). Metal blits between textures of one pixel format, so its
  source is read through a view with the encoding of the destination, made by the first such copy.
- **Arrays and cubes** (`Texture_Desc.layers`, `cube`): a single 2D texture with layers, with an
  array, cube or cube-array view (on Vulkan, the latter with `imageCubeArray`). A cube is square
  and has six faces per cube; the layers do not exceed `Device_Info.max_texture_layers`
  (`texture_layers_problem`). Metal counts cubes in `arrayLength` and the faces are its slices.
  The texture table only takes single-layer 2D textures: shaders read it as `Texture2D`.
- **3D textures** (`Texture_Desc.depth` greater than 1): only shaders write them (usage
  `Storage`); they are not targets, do not receive `texture_upload` and do not enter the table.

## Synchronization and commands

- **Hazards.** Each resource keeps its last access; barriers are derived from what each dispatch
  and draw binds (and its index and indirect buffers) and only the necessary ones go out. A render
  pass holds no barriers, so Vulkan records it and sends it at `cmd_end_render_pass`, after the
  barriers of everything its draws used; a resource it writes takes one, and one of its targets
  that a draw samples is an error. `cmd_barrier_*` declares what nothing binds: a buffer the host
  reads, a texture sampled through the texture table or by another process. Metal tracks hazards
  by itself.
- **Clip space.** Y up and depth in [0,1] on both backends; the renderer uses reversed Z.
- `cmd_fill_buffer` repeats a byte; a word of another value is written with `buffer_upload`
  before the frame, from a shader or by copying a buffer that has it (the GPU-counted indirect
  dispatches copy the renderer's `dispatch_start`).

## Textures shared between processes

- `texture_create_shared` creates a one-level texture of 4 bytes per texel that another process
  of the same machine and GPU opens with `texture_open_shared`; `device_shares_textures` says
  whether it is possible. Opening with another size or format fails on both backends.
- Metal: global IOSurface, opened by id; its format is the byte order, so sRGB and Unorm of the
  same order open the same surface.
- Vulkan: the memory does not carry its size and a driver accepts importing it under another
  image, so `Shared_Texture` carries a sum of width, height and format. On Linux, `pidfd_getfd`
  requires that the opener be the parent or be able to trace the other; on Windows, the creator
  keeps the named handle open.
- No shared semaphores: whoever draws waits for the GPU before announcing which texture is ready
  and leaves it in shader-read layout.

## Hardware ray tracing

- Vulkan: `VK_KHR_acceleration_structure` + `VK_KHR_ray_query`; Metal: `MTLAccelerationStructure`
  instanced with user IDs.
- Vulkan: it is enabled if the device supports it, the self-test at start (`render/selftest.odin`)
  gives the expected hits and its pipelines are made; otherwise, the software BVH, whose pipelines
  are made only then ([tracer in use](gi.md#bvh-and-acceleration-structures)).
  `MIRAI_RT=software` forces the software BVH.
- Metal traces rays by hardware alone: its shaders have no software tracer, `MIRAI_RT` is not read,
  and a device without ray tracing, a failed self-test or a missing `_hw` pipeline is an error of
  `renderer_create` that says which, never a switch of tracer.
- **TLAS instances.** `cmd_build_tlas` reads the instances from a GPU buffer in a neutral layout
  (`Tlas_Instance`: row-wise transform, the BLAS `accel_id`, mask and flags, own index), which the
  caller writes with the CPU or with a compute. An RHI compute (`tlas_instances.comp.slang`, a
  single source) makes them native in a TLAS buffer that grows to what is requested: what changes
  between backends is data the RHI writes, a table with the native value of each BLAS by id
  (Vulkan, its address; Metal, its place in the build array) and the layout (row-wise or
  column-wise transform, where flags and index go). The shader travels in the renderer's
  generation, which provides it with `tlas_translator_set` before the self-test.
- **Structure memory.** BLAS and TLAS live in ranges of large blocks (`ACCEL_BLOCK_BYTES`, or a
  dedicated one for a larger structure), with a common range allocator (`rhi/arena.odin`):
  on Vulkan each block is a buffer, on Metal a placement heap with tracked hazards. A structure
  does not occupy a buffer of the device pool; its range returns to the block when the frames
  that could use it finish, and an empty block goes away with the next creation.
- `accel_memory` gives the bytes of the structure blocks and what they occupy.
- `cmd_build_tlas` returns whether it recorded the build; if not, the message stays in
  `device_error`. The renderer leaves the TLAS pending, retries every frame and says why in
  `Stats.problem`, which `engine.status` (`renderer_problem`) and `engine.diagnostics`
  (`renderer`) show.

## Shader constants

- A shader names boolean constants (`Shader_Code.constants`, by id; up to `MAX_SHADER_CONSTANTS`)
  and a pipeline says which are true (`Shader_Constants` of `Compute_Pipeline_Desc.constants`,
  `Graphics_Pipeline_Desc.vertex_constants` and `fragment_constants`); the others are false. The
  driver compiles the code with them folded: one code, a pipeline per combination.
- Vulkan gives them as specialization constants (`VkSpecializationInfo`, each a `VkBool32` at
  constant id = its id). Metal, as function constants: SPIRV-Cross emits each specialization
  constant of the SPIR-V as `[[function_constant(id)]]` and the function is made with
  `MTLFunctionConstantValues`; the library of a source is compiled once and each set of constants
  is a function of it.
- A constant the shader does not declare makes no pipeline: the error names both.
  `shader_constant(code, name)` finds one by name, for the stages found by name.

## Pipeline cache

- Vulkan keeps in `Device_Desc.pipeline_cache_path` one driver blob per pipeline
  (`rhi/pipeline_store.odin`), under a key of the code, constants and state it compiles, never its
  name: each pipeline is created with a `VkPipelineCache` of its own, because a driver cache
  returns every entry it was ever given and grows without end. Blobs are stored as chunks cut by
  their content, each once: a driver repeats in every blob what they all share (NVIDIA a
  dictionary of megabytes).
- The file belongs to one device, driver and cache UUID, and is read whole or not at all: another
  device, another version or a file that does not read back exactly is ignored and replaced.
- It is rewritten in one rename each time the run added a part of its limit
  (`PIPELINE_STORE_SAVE_PARTS`), from the thread that compiled, and when the device is destroyed:
  a run that crashes, is killed or loses its device keeps what it compiled. A write holds the
  blobs this run used, the last used first, then those of earlier runs that are still young; a
  pipeline no run asks for (its shader changed) ages out, and nothing past `PIPELINE_STORE_BYTES`
  goes in. Several processes share the file: a write first takes in the entries another process
  wrote there since this one read or wrote it.
- Reading it removes the staging files of writers that ended (`serial.file_remove_stale`); that
  of a process that runs stays. `host` uses `pipelines.bin` in the
  [project user folder](../../mirai-core/references/host.md#the-application).
- Metal shares library and function between identical sources; the caller may free `Shader_Code`
  after creating the pipeline.

## Pipelines from other threads

- The device is used from the thread that records the frames, except `pipeline_create_compute`
  and `pipeline_create_graphics`, which run on other threads, several at a time, while that one
  records: the driver takes seconds for a shader generation
  ([loading in host](shaders.md#loading-in-host)). The Vulkan pipeline caches are created without
  `EXTERNALLY_SYNCHRONIZED`: the driver synchronizes it.
- `Device.pipeline_lock` guards the pipeline pool and `message_lock` the messages; `pool_get`
  reads only the slot of its handle, so a new pipeline does not touch the ones the frame uses.
  Destroying stays on the frame thread.

## Limits

- Metal compiles MSL with fast math, which can cancel the NaN protections: NaN sources are
  eliminated without relying on them.
