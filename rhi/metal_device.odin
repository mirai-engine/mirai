#+build darwin
package rhi

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "base:runtime"
import "mirai:std/base"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

Mtl_Buffer :: struct {
	handle: ^MTL.Buffer,
	size:   u64, // reported size, max(desc.size, 16) as on Vulkan
	length: u64, // MTLBuffer length: size rounded up to 16 so 4-byte blit ranges always fit
	mapped: rawptr,
	usage:  Buffer_Usage,
	kind:   Memory,
}

Mtl_Texture :: struct {
	handle:    ^MTL.Texture,
	mip_views: [MAX_TEXTURE_MIPS]^MTL.Texture, // single-level views when mip_levels > 1
	encoded:   ^MTL.Texture, // a view with the other sRGB encoding of its format, made by the first copy into a texture of it (cmd_copy_texture)
	desc:      Texture_Desc,
	format:    MTL.PixelFormat,
	swapchain: bool, // handle is the current drawable texture, not owned
	surface:   rawptr, // the IOSurface of a shared texture, owned
	table:     Table_Refs,
}

Mtl_Slot :: struct {
	used:   bool,
	kind:   Binding_Kind,
	stages: Shader_Stages,
}

Mtl_Pipeline :: struct {
	compute:     ^MTL.ComputePipelineState,
	render:      ^MTL.RenderPipelineState,
	depth_state: ^MTL.DepthStencilState,
	is_compute:  bool,
	threadgroup: MTL.Size,
	cull:        MTL.CullMode,
	primitive:   MTL.PrimitiveType,
	slots:       [MAX_BINDING_SLOTS]Mtl_Slot,
	slot_mask:   u32,
	table:       Shader_Stages, // stages that declare the texture table
	name:        string,
	shaders:     [2]base.Handle, // shared functions/libraries while this generation has pipelines
}

Mtl_Shader :: struct {
	fingerprint: [32]u8, // source and entry bytes; Shader_Code can be released after creation
	constants: Shader_Constants, // what the function was specialized with
	library: ^MTL.Library, // of the source: the functions of its other constants share it
	function: ^MTL.Function,
	users: u32,
}

Mtl_Accel :: struct {
	handle:          ^MTL.AccelerationStructure,
	descriptor:      ^MTL.AccelerationStructureDescriptor, // BLAS: retained primitive descriptor reused by every build
	top_level:       bool,
	blas:            Blas_Desc,
	max_instances:   u32,
	scratch_size:    u64,
	instanced:       ^NS.Array, // TLAS: retained array of the BLASes referenced by the last build
	referenced:      [dynamic]^MTL.AccelerationStructure, // contents of instanced (kept alive by it), for useResource
	instance_buffer: ^MTL.Buffer, // TLAS: retained instance descriptor buffer of the last build
	built:           bool,        // a build was recorded; tracing an unbuilt structure is undefined
	// TLAS: the instance descriptors its builds translate, kept and grown to the count asked.
	native:          Buffer,
	native_room:     u32,
	block:           i32, // the heap of the arena it lives in + 1
	offset, size:    u64, // its range of that heap
	// BLAS of Blas_Desc.compact: the slot + 1 its compacted size waits in, and the frame that wrote it.
	compact_slot:      i32,
	compact_frame:     u64,
	compact_immediate: bool,
}

Mtl_Frame :: struct {
	cmd:         ^MTL.CommandBuffer, // retained; the last command buffer committed from this slot
	list:        Command_List,
	pool:        ^NS.AutoreleasePool, // drained by frame_end
	upload:      Buffer,
	upload_ptr:  [^]u8,
	upload_size: u64,
	upload_used: u64,
	oversized:       [MAX_FRAME_OVERSIZED]Buffer, // see frame_alloc
	oversized_count: int,
	deletions:   [dynamic]^NS.Object, // released once the slot's command buffer completed
	ranges:      [dynamic][3]u64,     // block, offset and size of the arena given back then
	queries:     ^MTL.CounterSampleBuffer, // two samples per encoder, at its start and its end; nil without stage boundary sampling
	passes:      bool, // the frame samples its encoders: timestamps_want was on when it began
	query_count: u32,  // cmd_timestamp marks
	query_names: [MAX_TIMESTAMPS]string,
	query_bytes: [MAX_TIMESTAMPS][MAX_TIMESTAMP_NAME_BYTES]u8,
	encoder_count: u32,
	encoder_marks: [MAX_TIMESTAMPS]u16, // of each sampled encoder: the mark it runs after
	paced:         bool, // the frame draws into a pair of the presenter
	begun_ns:      i64,
	submitted_ns:  i64,
}

// The textures the thread of the presenter copies from, taken while it does not run.
@(private)
Mtl_Present :: struct {
	pairs: [PRESENT_PAIRS][2]^MTL.Texture,
}

Mtl_Swapchain :: struct {
	layer:         ^CA.MetalLayer,
	texture:       Texture, // reserved pool slot pointing at the current drawable's texture
	drawable:      ^CA.MetalDrawable, // retained between frame_begin and frame_end
	width, height: u32,
	vsync:         bool,
	acquire:       Mtl_Acquire,
}

Mtl_Acquire :: struct {
	worker:   ^thread.Thread,
	mutex:    sync.Mutex,
	ready:    sync.Cond,
	wake:     sync.Sema,
	drawable: ^CA.MetalDrawable,
	state:    enum {Idle, Pending, Ready},
	quit:     bool,
}

@(private)
mtl_acquire_worker :: proc(worker: ^thread.Thread) {
	sc := cast(^Mtl_Swapchain)worker.data
	a := &sc.acquire
	for {
		sync.sema_wait(&a.wake)
		sync.mutex_lock(&a.mutex)
		quit := a.quit
		sync.mutex_unlock(&a.mutex)
		if quit {return}
		pool := NS.AutoreleasePool.alloc()->init()
		drawable := CA.MetalLayer_nextDrawable(sc.layer)
		if drawable != nil {mtl_retain(drawable)}
		NS.AutoreleasePool_drain(pool)
		sync.mutex_lock(&a.mutex)
		a.drawable = drawable
		a.state = .Ready
		sync.cond_signal(&a.ready)
		sync.mutex_unlock(&a.mutex)
	}
}

@(private)
mtl_acquire_request :: proc(a: ^Mtl_Acquire) {
	sync.mutex_lock(&a.mutex)
	if a.state == .Idle && !a.quit {
		a.state = .Pending
		sync.sema_post(&a.wake)
	}
	sync.mutex_unlock(&a.mutex)
}

@(private)
mtl_acquire_take :: proc(a: ^Mtl_Acquire, wait: bool) -> ^CA.MetalDrawable {
	mtl_acquire_request(a)
	sync.mutex_lock(&a.mutex)
	for wait && a.state == .Pending {sync.cond_wait(&a.ready, &a.mutex)}
	drawable: ^CA.MetalDrawable
	if a.state == .Ready {
		drawable = a.drawable
		a.drawable = nil
		a.state = .Idle
	}
	sync.mutex_unlock(&a.mutex)
	return drawable
}

@(private)
mtl_acquire_destroy :: proc(a: ^Mtl_Acquire) {
	if a.worker == nil {return}
	sync.mutex_lock(&a.mutex)
	a.quit = true
	sync.sema_post(&a.wake)
	sync.mutex_unlock(&a.mutex)
	thread.join(a.worker)
	thread.destroy(a.worker)
	a.worker = nil
	mtl_release(a.drawable)
	a.drawable = nil
}

Device :: struct {
	info:           Device_Info,
	allocator:      runtime.Allocator,
	capacities:     Device_Capacities,
	stats:          Device_Stats,
	on_message:     Message_Proc,
	message_user:   rawptr,
	name_buffer:    [256]u8,
	device:         ^MTL.Device,
	queue:          ^MTL.CommandQueue,
	frames:         [MAX_FRAMES_IN_FLIGHT]Mtl_Frame,
	frame_number:   u64,
	slot:           int,
	in_frame:       bool,
	swapchain:      Mtl_Swapchain,
	has_swapchain:  bool,
	buffers:        Pool(Mtl_Buffer),
	textures:       Pool(Mtl_Texture),
	samplers:       Pool(^MTL.SamplerState),
	pipelines:      Pool(Mtl_Pipeline),
	shaders:        Pool(Mtl_Shader),
	accels:         Pool(Mtl_Accel),
	immediate:      Command_List,
	immediate_pool: ^NS.AutoreleasePool,
	scratch:        Buffer,
	tlas_translator: Pipeline, // tlas_translator_set
	accel_arena:    Arena,                  // where acceleration structures live
	accel_heaps:    [dynamic]^MTL.Heap,     // the placement heap of each block of the arena
	accel_empty:    [dynamic]int,           // blocks a release left empty, which go at the next creation
	compact_sizes:  Buffer,                 // the compacted sizes of BLASes, a u32 a slot (accel_compact.odin)
	compact_free:   [dynamic]u32,           // its free slots
	scratch_size:   u64,
	table_textures: [dynamic]Texture, // an entry per entry of the table; 0: it shows table_default
	table_views:    [dynamic]^MTL.Texture,
	table_default:  Texture,
	table_encoder:  ^MTL.ArgumentEncoder,
	table_buffers:  [TEXTURE_TABLE_COPIES]^MTL.Buffer, // the argument buffers shaders read the table from, one per copy
	table_changes:  Table_Changes,
	table_taken:    []u32, // as long as the table: what a copy takes
	table_limit:    int,   // the most entries the table grows to
	table_resident: [dynamic]^MTL.Resource, // the default and the textures of the entries: what an encoder that reads the table makes resident
	timings:        [MAX_TIMESTAMPS]Gpu_Timing,
	timing_bytes:   [MAX_TIMESTAMPS][MAX_TIMESTAMP_NAME_BYTES]u8,
	timing_count:   int,
	timestamps_wanted: bool,
	clock_cpu, clock_gpu: MTL.Timestamp, // sampled together when the device was made: the rate of the GPU clock
	error_buffer:   [512]u8,
	error:          string,
	failure:        Device_Failure,
	failure_text:   string,
	failure_buffer: [FAILURE_TEXT_BYTES]u8,
	lose_asked:     bool, // device_lose
	lose_provoked:  bool,
	refuse:         Pipeline_Refusal,
	presenter:      Presenter,
	present:        Mtl_Present,
	pipeline_lock:  sync.Mutex, // pipelines are made on other threads too: guards their pool and that of shaders
	message_lock:   sync.Mutex, // guards the error and the failure
}

@(private)
set_error :: proc(d: ^Device, format: string, args: ..any) {
	sync.guard(&d.message_lock)
	d.error = fmt.bprintf(d.error_buffer[:], format, ..args)
	if d.on_message != nil {d.on_message(.Error, d.error, d.message_user)}
}

@(private)
env_flag :: proc(name: string) -> string {
	value, found := os.lookup_env(name, context.temp_allocator)
	if !found {return ""}
	return value
}

// ---------------------------------------------------------------- Objective-C helpers

@(private)
mtl_release :: proc "contextless" (object: ^$T) {
	if object != nil {(cast(^NS.Object)object)->release()}
}

@(private)
mtl_retain :: proc "contextless" (object: ^$T) {
	if object != nil {(cast(^NS.Object)object)->retain()}
}

// Returns an owned (+1) NSString copy of s; the caller releases it.
@(private)
mtl_string :: proc(s: string) -> ^NS.String {
	// NSString copies the exact bytes. No intermediate C string consumes the
	// caller's bounded API scratch, and retained GPU labels own their contents.
	return NS.String.alloc()->initWithBytes(raw_data(s), NS.UInteger(len(s)), NS.UTF8StringEncoding)
}

@(private)
mtl_set_label :: proc(object: ^$T, name: string) {
	if object == nil || name == "" {return}
	label := mtl_string(name)
	MTL.Resource_setLabel(cast(^MTL.Resource)object, label)
	mtl_release(label)
}

// Copies an NSError description into the device error. The description is
// autoreleased, so it is only read inside a local pool.
//
// Procedures that call Metal outside frames and immediate transactions open
// their own autorelease pool: the host thread may have none.
@(private)
mtl_set_ns_error :: proc(d: ^Device, err: ^NS.Error, format: string, args: ..any) {
	NS.scoped_autoreleasepool()
	what := fmt.tprintf(format, ..args)
	if err == nil {set_error(d, "%s", what); return}
	set_error(d, "%s: %s", what, NS.String_odinString(NS.Error_localizedDescription(err)))
}

@(private)
mtl_ns_string :: proc(s: ^NS.String) -> string {
	if s == nil {return ""}
	return NS.String_odinString(s)
}

// ---------------------------------------------------------------- device

// error is a message in context.temp_allocator when no device could be created.
device_create :: proc(desc: Device_Desc) -> (device: ^Device, error: string) {
	allocator := desc.allocator if desc.allocator.procedure != nil else context.allocator
	d, allocation := new(Device, allocator)
	if allocation != nil {return nil, "out of memory"}
	d.allocator = allocator
	d.capacities = device_capacities(desc.capacities)
	d.on_message, d.message_user = desc.on_message, desc.message_user
	ok := mtl_create_pools(d) && mtl_create_device(d, desc)
	// Every Metal device of a Mac presents to the layer of its windows.
	if ok && desc.surface != {} {ok = mtl_swapchain_create(d, desc.surface)}
	if !ok {
		error = strings.clone(d.error, context.temp_allocator)
		device_destroy(d)
		return nil, error
	}
	return d, ""
}

@(private)
mtl_create_pools :: proc(d: ^Device) -> bool {
	c := d.capacities
	ok := pool_init(&d.buffers, c.buffers, d.allocator)
	ok &&= pool_init(&d.textures, c.textures, d.allocator)
	ok &&= pool_init(&d.samplers, c.samplers, d.allocator)
	ok &&= pool_init(&d.pipelines, c.pipelines, d.allocator)
	ok &&= pool_init(&d.shaders, c.pipelines * 2, d.allocator)
	ok &&= pool_init(&d.accels, c.accels, d.allocator)
	for &f in d.frames {
		err: runtime.Allocator_Error
		f.deletions, err = make([dynamic]^NS.Object, 0, c.deletions, d.allocator)
		ok &&= err == nil
	}
	if !ok {set_error(d, "out of memory for the resource tables")}
	return ok
}

@(private)
mtl_create_device :: proc(d: ^Device, desc: Device_Desc) -> bool {
	NS.scoped_autoreleasepool()
	d.info.backend = .Metal
	preferred := env_flag("MIRAI_GPU")
	if preferred == "" {preferred = desc.preferred_device}
	if preferred != "" {
		devices := MTL.CopyAllDevices()
		defer mtl_release(devices)
		wanted := strings.to_lower(preferred, context.temp_allocator)
		count := devices != nil ? NS.Array_count(devices) : 0
		for i in 0 ..< count {
			candidate := cast(^MTL.Device)NS.Array_object(devices, i)
			name := strings.to_lower(mtl_ns_string(MTL.Device_name(candidate)), context.temp_allocator)
			if strings.contains(name, wanted) {
				mtl_retain(candidate)
				d.device = candidate
				break
			}
		}
	}
	if d.device == nil {d.device = MTL.CreateSystemDefaultDevice()}
	if d.device == nil {set_error(d, "no Metal device"); return false}
	d.queue = MTL.Device_newCommandQueue(d.device)
	if d.queue == nil {set_error(d, "newCommandQueue failed"); return false}

	name := mtl_ns_string(MTL.Device_name(d.device))
	n := copy(d.name_buffer[:], name)
	d.info.name = string(d.name_buffer[:n])
	// Every Apple GPU has unified memory: only the low power one of a Mac that also has a discrete one is integrated.
	d.info.type = .Integrated if MTL.Device_isLowPower(d.device) else .Discrete
	d.info.max_texture_size = 16384
	d.info.max_texture_layers = 2048
	d.info.timestamp_period_ns = 1
	d.info.uniform_alignment = 256
	d.info.storage_alignment = 256
	d.info.max_storage_range = u64(MTL.Device_maxBufferLength(d.device))
	d.info.memory = MTL.Device_recommendedMaxWorkingSetSize(d.device)

	// API validation is a process-wide switch read by Metal itself
	// (MTL_DEBUG_LAYER=1, or the Xcode scheme); it cannot be enabled here.
	d.info.features.validation = env_flag("MTL_DEBUG_LAYER") == "1"
	if (desc.validation || env_flag("MIRAI_VALIDATION") == "1") && !d.info.features.validation {
		if d.on_message != nil {d.on_message(.Validation_Warning, "validation requested; run with MTL_DEBUG_LAYER=1 to enable Metal API validation", d.message_user)}
	}
	// Metal traces rays by hardware alone: allow_hardware_ray_tracing and MIRAI_RT choose the tracer only on Vulkan.
	d.info.features.ray_query = bool(MTL.Device_supportsRaytracing(d.device))
	d.info.features.draw_indirect_count = false
	d.info.features.texture_bc = bool(MTL.Device_supportsBCTextureCompression(d.device))
	d.info.features.timestamps = false
	d.info.features.clip_distance = true
	d.info.features.stop_place = true

	upload_size := desc.upload_bytes_per_frame if desc.upload_bytes_per_frame > 0 else 16 * 1024 * 1024

	// Apple GPUs sample counters only at the boundaries of encoders
	// (AtStageBoundary): each encoder of a frame that wants timings gets a
	// sample at its start and one at its end, from the common "timestamp" set.
	timestamp_set: ^MTL.CounterSet
	if MTL.Device_supportsCounterSampling(d.device, .AtStageBoundary) {
		if sets := MTL.Device_counterSets(d.device); sets != nil {
			for i in 0 ..< NS.Array_count(sets) {
				set := cast(^MTL.CounterSet)NS.Array_object(sets, i)
				if strings.equal_fold(NS.String_odinString(MTL.CounterSet_name(set)), "timestamp") {
					timestamp_set = set
					break
				}
			}
		}
	}
	counter_descriptor: ^MTL.CounterSampleBufferDescriptor
	if timestamp_set != nil {
		counter_descriptor = MTL.CounterSampleBufferDescriptor.alloc()->init()
		MTL.CounterSampleBufferDescriptor_setCounterSet(counter_descriptor, timestamp_set)
		MTL.CounterSampleBufferDescriptor_setSampleCount(counter_descriptor, NS.UInteger(2 * MAX_TIMESTAMPS))
		MTL.CounterSampleBufferDescriptor_setStorageMode(counter_descriptor, .Shared)
	}
	MTL.Device_sampleTimestamps(d.device, &d.clock_cpu, &d.clock_gpu)

	for &f, i in d.frames {
		f.upload = mtl_create_buffer(d, Buffer_Desc{size = upload_size, usage = TRANSIENT_USAGE, memory = .Upload, name = fmt.tprintf("frame upload %d", i)})
		if f.upload == 0 {
			if counter_descriptor != nil {mtl_release(counter_descriptor)}
			return false
		}
		f.upload_ptr = cast([^]u8)pool_get(&d.buffers, base.Handle(f.upload)).mapped
		f.upload_size = upload_size
		f.list.device = d
		if counter_descriptor != nil {
			counter, counter_error := MTL.Device_newCounterSampleBufferWithDescriptor(d.device, counter_descriptor)
			if counter_error == nil {f.queries = cast(^MTL.CounterSampleBuffer)counter}
		}
	}
	if counter_descriptor != nil {mtl_release(counter_descriptor)}
	if timestamp_set != nil {
		timestamps := true
		for &f in d.frames {if f.queries == nil {timestamps = false}}
		d.info.features.timestamps = timestamps
	}
	d.immediate.device = d
	d.immediate.immediate = true
	return mtl_create_texture_table(d)
}

// The table is an argument buffer per copy (TEXTURE_TABLE_COPIES) in device
// memory, each shared by every pipeline that declares it: the textures of
// its entries at the member TEXTURE_TABLE_SLOT, as SPIRV-Cross lays out
// descriptor set 1 without a size (cook/shaders). It starts with
// TEXTURE_TABLE_FIRST entries.
@(private)
mtl_create_texture_table :: proc(d: ^Device) -> bool {
	if MTL.Device_argumentBuffersSupport(d.device) != ._2 {
		set_error(d, "device lacks Tier 2 argument buffers for the texture table")
		return false
	}
	d.table_limit = TEXTURE_TABLE_MAX
	d.table_default = texture_create(d, {width = 1, height = 1, format = .RGBA8_Unorm, usage = {.Sampled}, name = "texture table default"})
	white := [4]u8{255, 255, 255, 255}
	if d.table_default == 0 || !texture_upload(d, d.table_default, white[:], 4) {return false}
	d.table_textures = make([dynamic]Texture, d.allocator)
	d.table_views = make([dynamic]^MTL.Texture, d.allocator)
	d.table_resident = make([dynamic]^MTL.Resource, d.allocator)
	for &copy in d.table_changes {copy = make([dynamic]u64, d.allocator)}
	return mtl_table_grow(d, TEXTURE_TABLE_FIRST)
}

// Makes the copies of the table with capacity entries, each with the texture
// of its entry or the default, and lets the ones before go once the GPU no
// longer reads them. Between frames.
@(private)
mtl_table_grow :: proc(d: ^Device, capacity: int) -> bool {
	taken, taken_error := make([]u32, capacity, d.allocator)
	if taken_error != nil {set_error(d, "texture table of %d entries: out of memory", capacity); return false}
	argument := MTL.ArgumentDescriptor_argumentDescriptor()
	MTL.ArgumentDescriptor_setIndex(argument, TEXTURE_TABLE_SLOT)
	MTL.ArgumentDescriptor_setDataType(argument, .Texture)
	MTL.ArgumentDescriptor_setTextureType(argument, ._2D)
	MTL.ArgumentDescriptor_setArrayLength(argument, NS.UInteger(capacity))
	MTL.ArgumentDescriptor_setAccess(argument, .ReadOnly)
	arguments := NS.Array.alloc()->initWithObjects(cast(^NS.id)&argument, 1)
	defer mtl_release(arguments)
	encoder := MTL.Device_newArgumentEncoderWithArguments(d.device, arguments)
	if encoder == nil {delete(taken, d.allocator); set_error(d, "newArgumentEncoderWithArguments failed for a texture table of %d entries", capacity); return false}
	default_view := pool_get(&d.textures, base.Handle(d.table_default)).handle
	before := len(d.table_views)
	buffers: [TEXTURE_TABLE_COPIES]^MTL.Buffer
	grown := false
	defer if !grown {
		for made in buffers {mtl_release(made)}
		mtl_release(encoder)
		delete(taken, d.allocator)
		base.truncate(&d.table_textures, before)
		base.truncate(&d.table_views, before)
	}
	if resize(&d.table_textures, capacity) != nil || resize(&d.table_views, capacity) != nil || reserve(&d.table_resident, capacity + 1) != nil {
		set_error(d, "texture table of %d entries: out of memory", capacity)
		return false
	}
	for &view in d.table_views[before:] {view = default_view}
	length := MTL.ArgumentEncoder_encodedLength(encoder)
	for &buffer in buffers {
		buffer = MTL.Device_newBufferWithLength(d.device, length, {.CPUCacheModeWriteCombined, .HazardTrackingModeTracked})
		if buffer == nil {
			set_error(d, "newBufferWithLength(%d) failed for the texture table", length)
			return false
		}
		mtl_set_label(buffer, "texture table")
		MTL.ArgumentEncoder_setArgumentBuffer(encoder, buffer, 0)
		MTL.ArgumentEncoder_setTextures(encoder, d.table_views[:], NS.Range{TEXTURE_TABLE_SLOT, NS.UInteger(capacity)})
	}
	if !table_changes_reset(&d.table_changes, capacity) {
		set_error(d, "texture table of %d entries: out of memory", capacity)
		return false
	}
	grown = true
	for buffer in d.table_buffers {mtl_defer(d, buffer)}
	mtl_defer(d, d.table_encoder)
	d.table_encoder, d.table_buffers = encoder, buffers
	delete(d.table_taken, d.allocator)
	d.table_taken = taken
	mtl_table_resident(d)
	return true
}

// Writes into a copy of the table the entries it has not taken, once the
// GPU no longer reads it.
@(private)
mtl_table_take :: proc(d: ^Device, copy: int) {
	entries := d.table_taken
	count := table_take(&d.table_changes, copy, entries)
	if count == 0 {return}
	MTL.ArgumentEncoder_setArgumentBuffer(d.table_encoder, d.table_buffers[copy], 0)
	for index in entries[:count] {MTL.ArgumentEncoder_setTexture(d.table_encoder, d.table_views[index], NS.UInteger(TEXTURE_TABLE_SLOT + index))}
}

// The textures of the table, the default once, for the encoders that read it
// to make them resident: Metal does not follow the references of an argument
// buffer.
@(private)
mtl_table_resident :: proc(d: ^Device) {
	clear(&d.table_resident)
	append(&d.table_resident, cast(^MTL.Resource)pool_get(&d.textures, base.Handle(d.table_default)).handle)
	for texture, i in d.table_textures {
		if texture == 0 {continue}
		append(&d.table_resident, cast(^MTL.Resource)d.table_views[i])
	}
}

device_destroy :: proc(d: ^Device) {
	if d == nil {return}
	NS.scoped_autoreleasepool()
	if !d.in_frame {present_stop(d)}
	// An open frame is abandoned: its command buffer was never committed.
	if d.in_frame {
		f := &d.frames[d.slot]
		mtl_list_abandon(&f.list)
		mtl_release(f.cmd)
		f.cmd = nil
		if d.swapchain.drawable != nil {mtl_release(d.swapchain.drawable); d.swapchain.drawable = nil}
		if f.pool != nil {NS.AutoreleasePool_drain(f.pool); f.pool = nil}
		d.in_frame = false
	}
	mtl_acquire_destroy(&d.swapchain.acquire)
	for &f in d.frames {
		if f.cmd != nil {
			MTL.CommandBuffer_waitUntilCompleted(f.cmd)
			mtl_release(f.cmd)
			f.cmd = nil
		}
		if f.queries != nil {
			mtl_release(f.queries)
			f.queries = nil
		}
	}
	// Resources the caller did not destroy are released here.
	for &a, i in d.accels.items {
		if !d.accels.alive[i] {continue}
		mtl_release(a.handle)
		mtl_release(a.descriptor)
		mtl_release(a.instanced)
		mtl_release(a.instance_buffer)
		delete(a.referenced)
	}
	for &p, i in d.pipelines.items {
		if !d.pipelines.alive[i] {continue}
		mtl_release_pipeline(d,&p)
	}
	for &t, i in d.textures.items {
		if !d.textures.alive[i] || t.swapchain {continue}
		for v in t.mip_views {mtl_release(v)}
		mtl_release(t.encoded)
		mtl_release(t.handle)
	}
	for &b, i in d.buffers.items {
		if d.buffers.alive[i] {mtl_release(b.handle)}
	}
	for &s, i in d.samplers.items {
		if d.samplers.alive[i] {mtl_release(s)}
	}
	for &f in d.frames {
		mtl_flush_deletions(&f)
		delete(f.deletions)
		delete(f.ranges)
	}
	for heap in d.accel_heaps {mtl_release(heap)}
	arena_destroy(&d.accel_arena)
	delete(d.accel_heaps)
	delete(d.accel_empty)
	if d.compact_sizes != 0 {buffer_destroy(d, d.compact_sizes)}
	delete(d.compact_free)
	mtl_release(d.table_encoder)
	for buffer in d.table_buffers {mtl_release(buffer)}
	delete(d.table_textures)
	delete(d.table_views)
	delete(d.table_resident)
	delete(d.table_taken, d.allocator)
	table_changes_destroy(&d.table_changes)
	mtl_release(d.swapchain.layer)
	mtl_release(d.queue)
	mtl_release(d.device)
	pool_destroy(&d.buffers, d.allocator)
	pool_destroy(&d.textures, d.allocator)
	pool_destroy(&d.samplers, d.allocator)
	pool_destroy(&d.pipelines, d.allocator)
	pool_destroy(&d.shaders, d.allocator)
	pool_destroy(&d.accels, d.allocator)
	free(d, d.allocator)
}

device_info :: proc(d: ^Device) -> ^Device_Info {return &d.info}

// Bytes of the memory this process holds on the device, and what Metal
// recommends it holds at most before the system pages some of it out.
device_memory :: proc(d: ^Device) -> (used, budget: u64) {
	return u64(MTL.Device_currentAllocatedSize(d.device)), d.info.memory
}
device_error :: proc(d: ^Device) -> string {return d.error}
// Metal API validation aborts the process on errors instead of reporting them
// through a callback, so there is nothing to count.
device_validation_errors :: proc(d: ^Device) -> int {return 0}
device_validation_message :: proc(d: ^Device) -> string {return ""}
device_loader_errors :: proc(d: ^Device) -> int {return 0}
device_validation_messages :: proc(d: ^Device, out: []string) -> int {return 0}
device_validation_forget :: proc(d: ^Device) {}

// What the device made for itself, which device_stats leaves out.
@(private)
device_own :: proc(d: ^Device) -> (buffers, textures, pipelines: int) {
	for f in d.frames {buffers += int(f.upload != 0) + f.oversized_count}
	if d.scratch != 0 {buffers += 1}
	if d.compact_sizes != 0 {buffers += 1}
	if d.table_default != 0 {textures += 1}
	if d.tlas_translator != 0 {pipelines += 1}
	return
}

// Waits for every committed command buffer; false when the device failed.
// The command buffer of a frame that is still being recorded has not been
// committed and is skipped.
// Whether the timings of the device are placed by a sampled pair of clocks.
device_timestamps_calibrated :: proc(d: ^Device) -> bool {return true}

device_wait_idle :: proc(d: ^Device) -> bool {
	for &f, i in d.frames {
		if f.cmd == nil || (d.in_frame && i == d.slot) {continue}
		mtl_wait(d, f.cmd, "frame")
	}
	return d.failure == .None
}

// Waits for a committed command buffer. The watchdog of the system ends one
// the GPU does not finish, as an error: the wait needs no limit of its own.
// A command buffer that failed fails the device.
@(private)
mtl_wait :: proc(d: ^Device, cmd: ^MTL.CommandBuffer, what: string) -> bool {
	if cmd == nil {return true}
	MTL.CommandBuffer_waitUntilCompleted(cmd)
	if MTL.CommandBuffer_status(cmd) == .Error {
		NS.scoped_autoreleasepool()
		err := MTL.CommandBuffer_error(cmd)
		failure := Device_Failure.Lost
		description := "no description"
		if err != nil {
			if MTL.CommandBufferError(NS.Error_code(err)) == .Timeout {failure = .Hung}
			description = NS.String_odinString(NS.Error_localizedDescription(err))
		}
		stopped_buffer: [256]u8
		stopped := mtl_stopped(err, stopped_buffer[:])
		device_fail(d, failure, "the %s command buffer failed: %s%s%s", what, description, "; the GPU stopped in " if stopped != "" else "", stopped)
		return false
	}
	return d.failure == .None
}

// The encoder of a failed command buffer that faulted, or else the first that
// did not complete, by its label and the debug groups open in it; "" when
// the error does not say.
@(private)
mtl_stopped :: proc(err: ^NS.Error, out: []u8) -> string {
	if err == nil {return ""}
	infos := cast(^NS.Array)NS.Dictionary_objectForKey(NS.Error_userInfo(err), cast(NS.id)MTL.CommandBufferEncoderInfoErrorKey)
	if infos == nil {return ""}
	stopped: ^MTL.CommandBufferEncoderInfo
	for i in 0 ..< NS.Array_count(infos) {
		info := cast(^MTL.CommandBufferEncoderInfo)NS.Array_object(infos, i)
		state := MTL.CommandBufferEncoderInfo_errorState(info)
		if state == .Faulted {stopped = info; break}
		if state != .Completed && stopped == nil {stopped = info}
	}
	if stopped == nil {return ""}
	signposts := MTL.CommandBufferEncoderInfo_debugSignposts(stopped)
	names: [MAX_LABEL_DEPTH + 1]^NS.String
	names[0] = MTL.CommandBufferEncoderInfo_label(stopped)
	count := 1
	for i in 0 ..< (NS.Array_count(signposts) if signposts != nil else 0) {
		if count < len(names) {names[count] = cast(^NS.String)NS.Array_object(signposts, i); count += 1}
	}
	return mtl_labels_text(names[:count], out)
}

// Names joined by " > ", the empty ones left out.
@(private)
mtl_labels_text :: proc(names: []^NS.String, out: []u8) -> string {
	text := strings.builder_from_bytes(out)
	for name in names {
		value := NS.String_odinString(name) if name != nil else ""
		if value == "" {continue}
		if strings.builder_len(text) > 0 {strings.write_string(&text, " > ")}
		strings.write_string(&text, value)
	}
	return strings.to_string(text)
}

// ---------------------------------------------------------------- deletion

@(private)
mtl_flush_deletions :: proc(f: ^Mtl_Frame) {
	for object in f.deletions {object->release()}
	clear(&f.deletions)
}

// Releases an object once the GPU finished every frame that could use it.
// Inside a frame the current slot covers everything recorded so far. Between
// frames the most recent submission belongs to the previous slot, so the object
// waits for that slot instead of the next one.
@(private)
mtl_defer :: proc(d: ^Device, object: ^$T) {
	if object == nil {return}
	slot := d.slot if d.in_frame else (d.slot + MAX_FRAMES_IN_FLIGHT - 1) % MAX_FRAMES_IN_FLIGHT
	list := &d.frames[slot].deletions
	if len(list) == cap(list) {
		d.stats.deletion_overflows += 1
		// Between frames nothing is being recorded: once the GPU is idle every
		// object that waits can go. Inside a frame the list grows instead.
		if !d.in_frame {
			device_wait_idle(d)
			for &f in d.frames {mtl_flush_deletions(&f);mtl_flush_ranges(d, &f)}
		}
	}
	append(list, cast(^NS.Object)object)
}

// Gives a range of the arena back once the GPU finished every frame that
// could use it, as mtl_defer releases an object.
@(private)
mtl_defer_range :: proc(d: ^Device, block: i32, offset, size: u64) {
	if block <= 0 {return}
	slot := d.slot if d.in_frame else (d.slot + MAX_FRAMES_IN_FLIGHT - 1) % MAX_FRAMES_IN_FLIGHT
	f := &d.frames[slot]
	if f.ranges == nil {f.ranges = make([dynamic][3]u64, d.allocator)}
	append(&f.ranges, [3]u64{u64(block - 1), offset, size})
}

// The ranges a frame slot held back; the blocks they leave empty go at the next creation.
@(private)
mtl_flush_ranges :: proc(d: ^Device, f: ^Mtl_Frame) {
	for r in f.ranges {
		if arena_give(&d.accel_arena, int(r[0]), r[1], r[2]) {append(&d.accel_empty, int(r[0]))}
	}
	clear(&f.ranges)
}

// ---------------------------------------------------------------- frames

frame_timings :: proc(d: ^Device) -> []Gpu_Timing {return d.timings[:d.timing_count]}

// Asks for one timing per cmd_timestamp interval in the frames that begin
// from now on; without it a frame reports only its whole GPU time.
timestamps_want :: proc(d: ^Device, on: bool) {d.timestamps_wanted = on}

// A sample of the counter Metal did not write.
@(private)
MTL_COUNTER_ERROR :: max(u64)

// The timings of the slot's completed command buffer. Each interval between
// two marks spans the encoders that ran in it, from the first start to the
// last end; one without encoders has no length. A frame without marks (or
// without counters) reports its command buffer as one "frame" interval.
// Times are moved to the clock of time.tick_now with a pair of CPU and GPU
// timestamps sampled now, and the rate measured since the device was made.
@(private)
mtl_collect_timestamps :: proc(d: ^Device, f: ^Mtl_Frame) {
	NS.scoped_autoreleasepool()
	d.timing_count = 0
	marks, encoders := f.query_count, f.encoder_count
	f.query_count, f.encoder_count = 0, 0
	if begun, ended := MTL.CommandBuffer_GPUStartTime(f.cmd), MTL.CommandBuffer_GPUEndTime(f.cmd); ended > begun && begun > 0 {
		present_latency(d, f.begun_ns, f.submitted_ns, i64((ended - begun) * 1e9))
	}
	cpu, gpu: MTL.Timestamp
	MTL.Device_sampleTimestamps(d.device, &cpu, &gpu)
	now := time.duration_nanoseconds(time.tick_diff({}, time.tick_now()))
	rate := 1.0
	if gpu > d.clock_gpu && cpu > d.clock_cpu {rate = f64(cpu - d.clock_cpu) / f64(gpu - d.clock_gpu)}
	tick_of :: proc "contextless" (t: u64, gpu: MTL.Timestamp, now: i64, rate: f64) -> i64 {return now + i64((f64(t) - f64(gpu)) * rate)}
	if f.passes && marks >= 2 && encoders > 0 && f.queries != nil {
		data := MTL.CounterSampleBuffer_resolveCounterRange(f.queries, NS.Range{0, NS.UInteger(encoders * 2)})
		if data != nil && u32(NS.Data_length(data)) >= encoders * 2 * size_of(u64) {
			samples := cast([^]u64)NS.Data_bytes(data)
			intervals := int(marks) - 1
			starts, ends: [MAX_TIMESTAMPS]u64
			for i in 0 ..< intervals {starts[i] = max(u64)}
			for k in 0 ..< int(encoders) {
				mark := int(f.encoder_marks[k])
				first, last := samples[2 * k], samples[2 * k + 1]
				if mark >= intervals || first == 0 || last == 0 || first == MTL_COUNTER_ERROR || last == MTL_COUNTER_ERROR {continue}
				starts[mark] = min(starts[mark], first)
				ends[mark] = max(ends[mark], max(first, last))
			}
			previous := u64(0)
			for i in 0 ..< intervals {
				if ends[i] != 0 {previous = starts[i]; break}
			}
			if previous != 0 {
				for i in 0 ..< intervals {
					start, end := previous, previous
					if ends[i] != 0 {start, end = max(starts[i], previous), ends[i]}
					previous = end
					start_ns, end_ns := tick_of(start, gpu, now, rate), tick_of(end, gpu, now, rate)
					name := string(d.timing_bytes[i][:copy(d.timing_bytes[i][:], f.query_names[i])])
					d.timings[i] = {name = name, ms = f32(f64(end_ns - start_ns) / 1e6), start_ns = start_ns, end_ns = end_ns}
				}
				d.timing_count = intervals
				return
			}
		}
	}
	// The command buffer's times are seconds of the host clock the CPU timestamps count in.
	start_seconds := MTL.CommandBuffer_GPUStartTime(f.cmd)
	end_seconds := MTL.CommandBuffer_GPUEndTime(f.cmd)
	if end_seconds > start_seconds && start_seconds > 0 {
		start_ns := now + i64(start_seconds * 1e9) - i64(cpu)
		end_ns := now + i64(end_seconds * 1e9) - i64(cpu)
		d.timings[0] = {name = "frame", ms = f32((end_seconds - start_seconds) * 1000), start_ns = start_ns, end_ns = end_ns}
		d.timing_count = 1
	}
}

// Begins recording a frame. Without present it takes no image of the
// swapchain: the frame draws only into textures, for a capture.
frame_begin :: proc(d: ^Device, present := true) -> (cmd: ^Command_List, ok: bool) {
	if d.in_frame {set_error(d, "frame_begin while a frame is being recorded: end it with frame_end first"); return nil, false}
	f := &d.frames[d.slot]
	d.timing_count = 0
	if f.cmd != nil {
		if mtl_wait(d, f.cmd, "frame") {mtl_collect_timestamps(d, f)}
		mtl_release(f.cmd)
		f.cmd = nil
	}
	if d.failure != .None {return nil, false}
	mtl_table_take(d, table_copy(false, d.slot))
	mtl_flush_deletions(f)
	mtl_flush_ranges(d, f)
	f.upload_used = 0
	f.pool = NS.AutoreleasePool.alloc()->init()
	f.paced = false
	f.begun_ns = present_now_ns()
	if d.has_swapchain && present {
		paced, ready := present_frame_begin(d)
		if !ready {mtl_drain_frame_pool(f); return nil, false}
		f.paced = paced
	}
	if d.has_swapchain && present && !f.paced {
		sc := &d.swapchain
		if sc.width == 0 || sc.height == 0 {mtl_drain_frame_pool(f); return nil, false}
		drawable := mtl_acquire_take(&sc.acquire, sc.vsync)
		if drawable == nil && sc.vsync {mtl_drain_frame_pool(f); return nil, false}
		sc.drawable = drawable
		if drawable != nil {
			texture := CA.MetalDrawable_texture(drawable)
			if t := pool_get(&d.textures, base.Handle(sc.texture)); t != nil {
				t.handle = texture
				t.desc.width = u32(MTL.Texture_width(texture))
				t.desc.height = u32(MTL.Texture_height(texture))
			}
		}
	}
	// A failed frame says which encoder faulted (mtl_stopped).
	cmd_desc := MTL.CommandBufferDescriptor.alloc()->init()
	MTL.CommandBufferDescriptor_setErrorOptions(cmd_desc, {.EncoderExecutionStatus})
	f.cmd = MTL.CommandQueue_commandBufferWithDescriptor(d.queue, cmd_desc)
	mtl_release(cmd_desc)
	if f.cmd == nil {
		mtl_release_drawable(d)
		mtl_drain_frame_pool(f)
		set_error(d, "commandBuffer failed")
		return nil, false
	}
	mtl_retain(f.cmd)
	mtl_list_reset(&f.list, f.cmd)
	f.passes = d.timestamps_wanted && f.queries != nil
	d.in_frame = true
	return &f.list, true
}

@(private)
mtl_drain_frame_pool :: proc(f: ^Mtl_Frame) {
	if f.pool != nil {NS.AutoreleasePool_drain(f.pool)}
	f.pool = nil
}

@(private)
mtl_release_drawable :: proc(d: ^Device) {
	sc := &d.swapchain
	if sc.drawable == nil {return}
	mtl_release(sc.drawable)
	sc.drawable = nil
	if t := pool_get(&d.textures, base.Handle(sc.texture)); t != nil {t.handle = nil}
}

// generated: the frame drew swapchain_generated_texture, which is shown before its own image.
frame_end :: proc(d: ^Device, cmd: ^Command_List, generated := false) -> bool {
	if !d.in_frame || cmd != &d.frames[d.slot].list {set_error(d, "frame_end without the list its frame_begin gave"); return false}
	f := &d.frames[d.slot]
	frame_oversized_release(d)
	if cmd.in_render_pass {cmd_end_render_pass(cmd)}
	mtl_end_encoder(cmd)
	// A provoked loss names the labels the frame left open: where a GPU that completed it stopped.
	open_buffer: [256]u8
	open := mtl_labels_text(cmd.labels[:cmd.label_count], open_buffer[:]) if d.lose_asked else ""
	mtl_release_labels(cmd)
	presented := d.swapchain.drawable != nil
	if presented {
		MTL.CommandBuffer_presentDrawable(f.cmd, cast(^MTL.Drawable)d.swapchain.drawable)
	}
	MTL.CommandBuffer_commit(f.cmd)
	f.submitted_ns = present_now_ns()
	if presented {present_count_direct(d)}
	mtl_release_drawable(d)
	if f.paced {
		// The thread waits for the frame on its own reference.
		mtl_retain(f.cmd)
		present_frame_end(d, generated, 0, f.cmd)
	} else if d.has_swapchain {mtl_acquire_request(&d.swapchain.acquire)}
	cmd.cmd = nil
	// A failed command buffer reports at the next wait; this one, once it completed.
	if device_lose_take(d) {
		MTL.CommandBuffer_waitUntilCompleted(f.cmd)
		device_fail(d, .Lost, "the frame command buffer failed: the GPU device was lost%s%s", "; the GPU stopped in " if open != "" else "", open)
	}
	// f.cmd stays retained until frame_begin reuses this slot, so draining the
	// pool only drops the autoreleased encoders and the drawable.
	mtl_drain_frame_pool(f)
	d.in_frame = false
	d.frame_number += 1
	d.slot = int(d.frame_number % MAX_FRAMES_IN_FLIGHT)
	return d.failure == .None
}

frame_number :: proc(d: ^Device) -> u64 {return d.frame_number}

// ---------------------------------------------------------------- immediate transactions

// Begins a blocking command list for load-time work (uploads, BLAS builds,
// readback). nil, with the error of the device, while a frame is being
// recorded: immediate_end of it fails.
immediate_begin :: proc(d: ^Device) -> ^Command_List {
	if d.in_frame {set_error(d, "immediate_begin while a frame is being recorded: a load transaction runs between frame_end and frame_begin"); return nil}
	if d.immediate.cmd != nil {set_error(d, "immediate_begin inside an immediate transaction: end it with immediate_end first"); return nil}
	mtl_table_take(d, table_copy(true, 0))
	d.immediate_pool = NS.AutoreleasePool.alloc()->init()
	cmd := MTL.CommandQueue_commandBuffer(d.queue)
	mtl_retain(cmd)
	mtl_list_reset(&d.immediate, cmd)
	return &d.immediate
}

immediate_end :: proc(d: ^Device, cmd: ^Command_List) -> bool {
	if cmd != &d.immediate {
		if cmd != nil {set_error(d, "immediate_end of a list immediate_begin did not give")}
		return false
	}
	if cmd.in_render_pass {cmd_end_render_pass(cmd)}
	mtl_end_encoder(cmd)
	mtl_release_labels(cmd)
	ok := cmd.cmd != nil && d.failure == .None
	if ok {
		MTL.CommandBuffer_commit(cmd.cmd)
		ok = mtl_wait(d, cmd.cmd, "immediate")
		if ok && device_lose_take(d) {
			device_fail(d, .Lost, "the immediate command buffer failed: the GPU device was lost")
			ok = false
		}
	} else if d.failure == .None {
		set_error(d, "immediate commandBuffer failed")
	}
	if cmd.cmd != nil {mtl_release(cmd.cmd)}
	cmd.cmd = nil
	if d.immediate_pool != nil {NS.AutoreleasePool_drain(d.immediate_pool)}
	d.immediate_pool = nil
	return ok
}

// ---------------------------------------------------------------- swapchain

// Surface_Desc.metal_layer is the CAMetalLayer of the window (for example from
// SDL_Metal_GetLayer). The layer is retained until device_destroy.
@(private)
mtl_swapchain_create :: proc(d: ^Device, surface: Surface_Desc) -> bool {
	NS.scoped_autoreleasepool()
	if surface.metal_layer == nil {set_error(d, "a window needs Surface_Desc.metal_layer, the CAMetalLayer the platform layer gives"); return false}
	sc := &d.swapchain
	sc.layer = cast(^CA.MetalLayer)surface.metal_layer
	mtl_retain(sc.layer)
	CA.MetalLayer_setDevice(sc.layer, d.device)
	CA.MetalLayer_setPixelFormat(sc.layer, .BGRA8Unorm)
	CA.MetalLayer_setFramebufferOnly(sc.layer, false)
	CA.MetalLayer_setDisplaySyncEnabled(sc.layer, NS.BOOL(surface.vsync))
	sc.vsync = surface.vsync
	sc.width = surface.width
	sc.height = surface.height
	if sc.width > 0 && sc.height > 0 {
		CA.MetalLayer_setDrawableSize(sc.layer, NS.Size{NS.Float(sc.width), NS.Float(sc.height)})
	}
	if !device_room(d, &d.textures, "textures") {return false}
	t := Mtl_Texture{
		format = .BGRA8Unorm, swapchain = true,
		desc = {width = sc.width, height = sc.height, mip_levels = 1, format = .BGRA8_Unorm, usage = {.Color_Target, .Transfer_Src, .Transfer_Dst}},
	}
	sc.texture = Texture(pool_add(&d.textures, t))
	previous_allocator := context.allocator
	context.allocator = d.allocator
	sc.acquire.worker = thread.create(mtl_acquire_worker, name = "Metal drawable")
	context.allocator = previous_allocator
	if sc.acquire.worker == nil {set_error(d, "drawable acquisition thread failed"); return false}
	sc.acquire.worker.data = sc
	sc.acquire.worker.init_context = runtime.Context{allocator = d.allocator}
	thread.start(sc.acquire.worker)
	d.has_swapchain = true
	return true
}

// Gives a device made without a window the swapchain of one, between frames.
// False, with device_error, when it already has one; the device goes on
// drawing without it.
swapchain_attach :: proc(d: ^Device, surface: Surface_Desc) -> bool {
	if d.has_swapchain || d.in_frame {set_error(d, "swapchain_attach on a device that has a swapchain or is recording a frame"); return false}
	return mtl_swapchain_create(d, surface)
}

swapchain_resize :: proc(d: ^Device, width, height: u32) {
	if !d.has_swapchain {return}
	sc := &d.swapchain
	if sc.width == width && sc.height == height {return}
	NS.scoped_autoreleasepool()
	sc.width = width
	sc.height = height
	// A zero size (minimized window) is not forwarded; frame_begin skips frames
	// until the window has an area again.
	if width > 0 && height > 0 {
		CA.MetalLayer_setDrawableSize(sc.layer, NS.Size{NS.Float(width), NS.Float(height)})
	}
}

// Takes effect when the next frame begins.
swapchain_set_vsync :: proc(d: ^Device, vsync: bool) {
	if !d.has_swapchain || d.swapchain.vsync == vsync {return}
	NS.scoped_autoreleasepool()
	CA.MetalLayer_setDisplaySyncEnabled(d.swapchain.layer, NS.BOOL(vsync))
	d.swapchain.vsync = vsync
}

swapchain_texture :: proc(d: ^Device) -> Texture {
	if d.in_frame && d.frames[d.slot].paced {return d.presenter.pairs[d.presenter.pair].textures[1] if d.presenter.pair >= 0 else 0}
	if !d.has_swapchain || d.swapchain.drawable == nil {return 0}
	return d.swapchain.texture
}

swapchain_format :: proc(d: ^Device) -> Format {return .BGRA8_Unorm}
swapchain_size :: proc(d: ^Device) -> (u32, u32) {return d.swapchain.width, d.swapchain.height}

// ---------------------------------------------------------------- paced presentation (present.odin)

// The layer gives drawables of its new size by itself.
@(private)
swapchain_stale :: proc(d: ^Device) -> bool {return false}

@(private)
swapchain_refresh :: proc(d: ^Device) -> bool {return true}

@(private)
present_backend_start :: proc(d: ^Device) -> bool {
	// The thread takes the drawables from now on; one the acquisition worker holds goes back.
	if drawable := mtl_acquire_take(&d.swapchain.acquire, true); drawable != nil {mtl_release(drawable)}
	return present_backend_refresh(d)
}

@(private)
present_backend_refresh :: proc(d: ^Device) -> bool {
	for &pair, i in d.presenter.pairs {
		for texture, j in pair.textures {
			t := pool_get(&d.textures, base.Handle(texture))
			if t == nil {return false}
			d.present.pairs[i][j] = t.handle
		}
	}
	return true
}

@(private)
present_backend_stop :: proc(d: ^Device) {
	d.present = {}
	if d.has_swapchain {mtl_acquire_request(&d.swapchain.acquire)}
}

@(private)
present_gpu_wait :: proc(d: ^Device, job: ^Present_Job) -> bool {
	cmd := cast(^MTL.CommandBuffer)job.cmd
	ok := mtl_wait(d, cmd, "frame")
	mtl_release(cmd)
	job.cmd = nil
	return ok
}

// Copies image (0 the generated one, 1 the real one) of the pair of a job
// into a drawable and presents it, from the thread of the presenter. The
// textures are tracked: a frame that draws into the pair later waits for the copy.
@(private)
present_image :: proc(d: ^Device, job: ^Present_Job, image: int) -> (u64, bool) {
	if d.failure != .None {return 0, false}
	NS.scoped_autoreleasepool()
	source := d.present.pairs[job.pair][image]
	drawable := CA.MetalLayer_nextDrawable(d.swapchain.layer)
	if drawable == nil || source == nil {return 0, false}
	target := CA.MetalDrawable_texture(drawable)
	width := min(MTL.Texture_width(source), MTL.Texture_width(target))
	height := min(MTL.Texture_height(source), MTL.Texture_height(target))
	cmd := MTL.CommandQueue_commandBuffer(d.queue)
	if cmd == nil {return 0, false}
	blit := MTL.CommandBuffer_blitCommandEncoder(cmd)
	MTL.BlitCommandEncoder_copyFromTexture(blit, source, 0, 0, MTL.Origin{0, 0, 0}, MTL.Size{width, height, 1}, target, 0, 0, MTL.Origin{0, 0, 0})
	MTL.CommandEncoder_endEncoding(blit)
	MTL.CommandBuffer_presentDrawable(cmd, cast(^MTL.Drawable)drawable)
	MTL.CommandBuffer_commit(cmd)
	return 0, true
}
