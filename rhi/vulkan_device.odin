#+build linux, windows
package rhi

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "mirai:std/base"
import vk "vendor:vulkan"

VK_LIBRARY_NAMES :: [?]string{"vulkan-1.dll"} when ODIN_OS == .Windows else [?]string{"libvulkan.so.1", "libvulkan.so"}

Vk_Buffer :: struct {
	handle:   vk.Buffer,
	memory:   Vk_Memory,
	size:     u64,
	mapped:   rawptr,
	address:  u64,
	usage:    Buffer_Usage,
	kind:     Memory,
	write:    Access,          // last write not yet superseded (None = clean)
	reads:    bit_set[Access], // reads made visible since that write
	fresh:    bool,            // of GPU memory, waiting in Device.fresh for the fill that zeroes it
}

// The hazard state of a mip of a texture; its layers share it.
Vk_Level :: struct {
	layout: vk.ImageLayout,
	write:  Access,
	reads:  bit_set[Access],
}

Vk_Texture :: struct {
	image:       vk.Image,
	memory:      Vk_Memory,
	view:        vk.ImageView,
	mip_views:   [MAX_TEXTURE_MIPS]vk.ImageView,
	layer_views: []vk.ImageView, // a target with layers: one per mip and layer, mip after mip
	desc:        Texture_Desc,
	vk_format:   vk.Format,
	aspect:      vk.ImageAspectFlags,
	levels:      [MAX_TEXTURE_MIPS]Vk_Level, // a run of mips in one state takes one barrier
	swapchain:   bool,
	shared:      uintptr, // the handle a shared texture exports, held while it lives (a file descriptor plus one, or a HANDLE)
	table:       Table_Refs,
}

Slot_Info :: struct {
	used: bool,
	kind: Binding_Kind,
}

Vk_Pipeline :: struct {
	handle:     vk.Pipeline,
	layout:     vk.PipelineLayout,
	set_layout: vk.DescriptorSetLayout,
	descriptor_pool: vk.DescriptorPool, // of copies of the texture table it outgrew
	bind_point: vk.PipelineBindPoint,
	slots:      [MAX_BINDING_SLOTS]Slot_Info,
	slot_mask:  u32,
	uses_table: bool, // the layout has the texture table as set 1
	name:       string,
}

Vk_Accel :: struct {
	handle:        vk.AccelerationStructureKHR,
	buffer:        Buffer, // the block of the arena it lives in
	block:         i32,    // that block + 1
	offset, size:  u64,    // its range of the block
	address:       u64,
	top_level:     bool,
	blas:          Blas_Desc,
	max_instances: u32,
	scratch_size:  u64,
	built:         bool, // a build was recorded; tracing an unbuilt structure is undefined
	// TLAS: the native instances its builds translate, kept and grown to the count asked.
	native:        Buffer,
	native_room:   u32,
	// BLAS of Blas_Desc.compact: the slot + 1 its compacted size waits in, and the frame that wrote it.
	compact_slot:      i32,
	compact_frame:     u64,
	compact_immediate: bool,
}

// Raw objects whose destruction waits until the frame slot that may still use
// them has completed on the GPU.
Vk_Deferred :: struct {
	buffer:     vk.Buffer,
	memory:     Vk_Memory, // of the buffer or the image
	image:      vk.Image,
	views:      [MAX_TEXTURE_MIPS + 1]vk.ImageView,
	layer_views: []vk.ImageView,
	sampler:    vk.Sampler,
	pipeline:   vk.Pipeline,
	layout:     vk.PipelineLayout,
	set_layout: vk.DescriptorSetLayout,
	descriptor_pool: vk.DescriptorPool, // of copies of the texture table it outgrew
	accel:      vk.AccelerationStructureKHR,
	// The range of the arena the structure took: block + 1, 0 for none.
	arena_block:  i32,
	arena_offset: u64,
	arena_size:   u64,
}

Vk_Frame :: struct {
	pool:         vk.CommandPool,
	cmd:          vk.CommandBuffer,
	list:         Command_List,
	acquire:      vk.Semaphore,
	signal_value: u64,
	upload:       Buffer,
	upload_ptr:   [^]u8,
	upload_size:  u64,
	upload_used:  u64,
	oversized:       [MAX_FRAME_OVERSIZED]Buffer, // see frame_alloc
	oversized_count: int,
	deletions:    [dynamic]Vk_Deferred, // reserved once; see vk_defer
	queries:      vk.QueryPool,
	passes:       bool, // the frame writes the timestamps of cmd_timestamp: timestamps_want was on when it began
	query_count:  u32,
	query_names:  [MAX_TIMESTAMPS]string,
	query_bytes:  [MAX_TIMESTAMPS][MAX_TIMESTAMP_NAME_BYTES]u8, // the names, which a caller may build in the frame
	image_index:  u32,
	acquired:     bool,
	paced:        bool, // the frame draws into a pair of the presenter
	begun_ns:     i64,
	submitted_ns: i64,
}

Vk_Swapchain :: struct {
	surface:     vk.SurfaceKHR,
	handle:      vk.SwapchainKHR,
	vk_format:   vk.Format,
	format:      Format,
	color_space: vk.ColorSpaceKHR,
	extent:      vk.Extent2D,
	images:      [dynamic]Texture,
	present:     [dynamic]vk.Semaphore,
	desc:        Surface_Desc,
	stale:       bool,
	lost:        bool, // the platform lost the surface (vk_surface_lost): atomic
	tries:       int,  // frames that could not make the lost surface again
	copyable:    bool, // its images take copies: the presenter can show its pairs through them
}

// Frames that try to make a lost surface again before the window stays without images.
VK_SURFACE_TRIES :: 8

PRESENT_SLOTS :: 2 * PRESENT_JOBS

// What the thread of the presenter uses, made and copied while it does not run.
@(private)
Vk_Present :: struct {
	pool:      vk.CommandPool,
	cmds:      [PRESENT_SLOTS]vk.CommandBuffer,
	acquire:   [PRESENT_SLOTS]vk.Semaphore,
	values:    [PRESENT_SLOTS]u64, // of the timeline, when each slot can be used again
	timeline:  vk.Semaphore,
	value:     u64,
	next:      int,
	swapchain: vk.SwapchainKHR,
	images:    [VK_PRESENT_IMAGES]vk.Image,
	presents:  [VK_PRESENT_IMAGES]vk.Semaphore,
	pairs:     [PRESENT_PAIRS][2]vk.Image,
	extent:    vk.Extent2D,
}
VK_PRESENT_IMAGES :: 8

Device :: struct {
	info:              Device_Info,
	allocator:         runtime.Allocator,
	capacities:        Device_Capacities,
	stats:             Device_Stats,
	on_message:        Message_Proc,
	message_user:      rawptr,
	name_buffer:       [256]u8,
	loader_lock:       ^sync.Mutex, // of the application: held while the Vulkan loader walks or changes the drivers of every instance
	library:           dynlib.Library,
	get_instance_proc: vk.ProcGetInstanceProcAddr,
	ivk:               Vk_Instance_Procs, // procedures of the instance
	dvk:               vk.Device_VTable,  // procedures of the device
	shared_memory:     bool,              // textures can be shared with other processes (VK_SHARED_EXTENSION)
	shared_serial:     u32,
	instance:          vk.Instance,
	messenger:         vk.DebugUtilsMessengerEXT,
	physical:          vk.PhysicalDevice,
	handle:            vk.Device,
	queue:             vk.Queue,
	queue_family:      u32,
	properties:        vk.PhysicalDeviceProperties,
	memory_properties: vk.PhysicalDeviceMemoryProperties,
	debug_utils:       bool,
	surface_ext:       bool,
	swapchain_ext:     bool,
	scratch_alignment: u64,
	memory:            Vk_Memory_Pools,  // where buffers and textures live
	staging:           Buffer,           // what uploads copy from (vk_staging_take)
	staging_size:      u64,
	fresh:             [dynamic]Buffer,  // of GPU memory, made between lists: the next list zeroes them (vk_zero_new)
	immediate_open:    bool,             // between immediate_begin and immediate_end
	accel_arena:       Arena,            // where acceleration structures live
	accel_blocks:      [dynamic]Buffer,  // the buffer of each block of the arena
	accel_empty:       [dynamic]int,     // blocks a deletion left empty, which go at the next creation
	compact_pool:      vk.QueryPool,     // the compacted sizes of BLASes (accel_compact.odin)
	compact_free:      [dynamic]u32,     // its free slots
	tlas_translator:   Pipeline, // tlas_translator_set
	timeline:          vk.Semaphore,
	timeline_value:    u64,
	frames:            [MAX_FRAMES_IN_FLIGHT]Vk_Frame,
	frame_number:      u64,
	slot:              int,
	in_frame:          bool,
	swapchain:         Vk_Swapchain,
	has_swapchain:     bool,
	buffers:           Pool(Vk_Buffer),
	textures:          Pool(Vk_Texture),
	samplers:          Pool(vk.Sampler),
	pipelines:         Pool(Vk_Pipeline),
	accels:            Pool(Vk_Accel),
	immediate_pool:    vk.CommandPool,
	immediate_fence:   vk.Fence,
	immediate:         Command_List,
	scratch:           Buffer,
	scratch_size:      u64,
	anisotropy:        bool, // samplerAnisotropy is enabled
	cube_arrays:       bool, // imageCubeArray is enabled
	table_layout:      vk.DescriptorSetLayout,
	table_pool:        vk.DescriptorPool,
	table_sets:        [TEXTURE_TABLE_COPIES]vk.DescriptorSet,
	table_textures:    [dynamic]Texture, // an entry per entry of the table; 0: it shows table_default
	table_changes:     Table_Changes,
	table_taken:       []u32, // as long as the table: what a copy takes
	table_limit:       int,   // the most entries the table grows to on this device
	table_default:     Texture,
	pipelines_kept:    Pipeline_Store, // with a path, read when created and written as it grows and when destroyed
	store_path:        [512]u8,
	store_path_len:    int,
	timings:           [MAX_TIMESTAMPS]Gpu_Timing,
	timing_bytes:      [MAX_TIMESTAMPS][MAX_TIMESTAMP_NAME_BYTES]u8, // the names of timings, kept until the next ones
	timing_count:      int,
	timestamps_wanted: bool,
	timestamp_bits:    u32, // timestampValidBits of the queue: a GPU timestamp wraps past them
	// VK_KHR or VK_EXT_calibrated_timestamps with the device and host domains; nil without them.
	calibrate:         vk.ProcGetCalibratedTimestampsKHR,
	host_clock_rate:   i64, // ticks per second of VK_HOST_TIME_DOMAIN
	validation_errors: int,
	loader_errors:     int,
	validation_seen:   int, // messages written to validation_ring, which keeps the last VALIDATION_HISTORY
	validation_ring:   [VALIDATION_HISTORY][VALIDATION_MESSAGE_BYTES]u8,
	validation_length: [VALIDATION_HISTORY]int,
	error_buffer:      [512]u8,
	error:             string,
	failure:           Device_Failure,
	failure_text:      string,
	failure_buffer:    [FAILURE_TEXT_BYTES]u8,
	fault_info:        bool, // VK_EXT_device_fault: the driver describes a loss
	memory_budget:     bool, // VK_EXT_memory_budget: the driver says what memory the process holds and may hold
	waited_out:        bool, // a wait passed GPU_WAIT_LIMIT_NS: the GPU may still run that work
	lose_asked:        bool, // device_lose
	lose_provoked:     bool,
	presenter:         Presenter,
	present:           Vk_Present,
	queue_lock:        sync.Mutex, // the presenter submits and presents from its thread too
	pipeline_lock:     sync.Mutex, // pipelines are made on other threads too: guards their pool
	message_lock:      sync.Mutex, // guards the error, the failure and the validation messages
}

@(private)
set_error :: proc(d: ^Device, format: string, args: ..any) {
	sync.guard(&d.message_lock)
	d.error = fmt.bprintf(d.error_buffer[:], format, ..args)
	if d.on_message != nil {d.on_message(.Error, d.error, d.message_user)}
}

@(private)
vk_check :: proc(d: ^Device, result: vk.Result, what: string) -> bool {
	if result == .SUCCESS {return true}
	if vk_lost(d, result, what) {return false}
	set_error(d, "%s failed: %v", what, result)
	return false
}

// Whether a result reports the device lost, which marks it with what the
// driver says of the fault; other results are the caller's.
@(private)
vk_lost :: proc(d: ^Device, result: vk.Result, what: string) -> bool {
	if result != .ERROR_DEVICE_LOST {return false}
	description: string
	if d.fault_info && !d.lose_provoked {
		// No arrays asked for: the description alone, with INCOMPLETE.
		counts := vk.DeviceFaultCountsEXT{sType = .DEVICE_FAULT_COUNTS_EXT}
		info := vk.DeviceFaultInfoEXT{sType = .DEVICE_FAULT_INFO_EXT}
		if fault := d.dvk.GetDeviceFaultInfoEXT(d.handle, &counts, &info); fault == .SUCCESS || fault == .INCOMPLETE {
			description = strings.trim_space(string(cstring(raw_data(info.description[:]))))
		}
	}
	if description != "" {
		device_fail(d, .Lost, "%s reported the GPU device lost: %s", what, description)
	} else {
		device_fail(d, .Lost, "%s reported the GPU device lost", what)
	}
	return true
}

// Whether a wait for the GPU ended in time: one past GPU_WAIT_LIMIT_NS marks the device hung.
@(private)
vk_waited :: proc(d: ^Device, result: vk.Result, what: string) -> bool {
	if result != .TIMEOUT {return vk_check(d, result, what)}
	d.waited_out = true
	device_fail(d, .Hung, "%s: the GPU did not finish its work in %d s", what, GPU_WAIT_LIMIT_NS / 1_000_000_000)
	return false
}

// Waits until the GPU finished everything submitted, within GPU_WAIT_LIMIT_NS.
@(private)
vk_idle :: proc(d: ^Device) -> bool {
	if d.handle == nil || d.failure != .None {return false}
	if !vk_wait_timeline(d, d.timeline_value) {return false}
	// The submissions are done: what is left is presentation.
	sync.guard(&d.queue_lock)
	return vk_check(d, d.dvk.DeviceWaitIdle(d.handle), "vkDeviceWaitIdle")
}

@(private)
vk_debug_callback :: proc "system" (severity: vk.DebugUtilsMessageSeverityFlagsEXT, types: vk.DebugUtilsMessageTypeFlagsEXT, data: ^vk.DebugUtilsMessengerCallbackDataEXT, user: rawptr) -> b32 {
	context = runtime.default_context()
	d := cast(^Device)user
	message := string(data.pMessage)
	sync.guard(&d.message_lock)
	if .ERROR in severity {
		// Only the validation layer produces VALIDATION and PERFORMANCE messages;
		// GENERAL ones come from the loader or from layers of other programs.
		if .VALIDATION in types || .PERFORMANCE in types {
			slot := d.validation_seen % VALIDATION_HISTORY
			d.validation_length[slot] = copy(d.validation_ring[slot][:], message)
			d.validation_seen += 1
			d.validation_errors += 1
			if d.on_message != nil {d.on_message(.Validation_Error, message, d.message_user)}
		} else {
			d.loader_errors += 1
			if d.on_message != nil {d.on_message(.Loader_Warning, message, d.message_user)}
		}
	} else if .WARNING in severity && (.VALIDATION in types || .PERFORMANCE in types) {
		// General warnings come from the loader probing unrelated ICDs.
		if d.on_message != nil {d.on_message(.Validation_Warning, string(data.pMessage), d.message_user)}
	}
	return false
}

@(private)
env_flag :: proc(name: string) -> string {
	value, found := os.lookup_env(name, context.temp_allocator)
	if !found {return ""}
	return value
}

@(private)
has_extension :: proc(available: []vk.ExtensionProperties, name: cstring) -> bool {
	for &e in available {
		if strings.compare(string(cstring(&e.extensionName[0])), string(name)) == 0 {return true}
	}
	return false
}

// error is a message in context.temp_allocator when no device could be created.
device_create :: proc(desc: Device_Desc) -> (device: ^Device, error: string) {
	allocator := desc.allocator if desc.allocator.procedure != nil else context.allocator
	d, allocation := new(Device, allocator)
	if allocation != nil {return nil, "out of memory"}
	d.allocator = allocator
	d.capacities = device_capacities(desc.capacities)
	d.on_message, d.message_user = desc.on_message, desc.message_user
	ok := vk_create_pools(d) && vk_create_device(d, desc)
	if !ok {
		error = strings.clone(d.error, context.temp_allocator)
		device_destroy(d)
		return nil, error
	}
	return d, ""
}

@(private)
vk_create_pools :: proc(d: ^Device) -> bool {
	c := d.capacities
	ok := pool_init(&d.buffers, c.buffers, d.allocator)
	ok &&= pool_init(&d.textures, c.textures, d.allocator)
	ok &&= pool_init(&d.samplers, c.samplers, d.allocator)
	ok &&= pool_init(&d.pipelines, c.pipelines, d.allocator)
	ok &&= pool_init(&d.accels, c.accels, d.allocator)
	for &f in d.frames {
		err: runtime.Allocator_Error
		f.deletions, err = make([dynamic]Vk_Deferred, 0, c.deletions, d.allocator)
		ok &&= err == nil
		f.list.commands, err = make([]Pass_Command, PASS_COMMAND_CAPACITY, d.allocator)
		ok &&= err == nil
	}
	commands_error: runtime.Allocator_Error
	d.immediate.commands, commands_error = make([]Pass_Command, PASS_COMMAND_CAPACITY, d.allocator)
	ok &&= commands_error == nil
	images_error, present_error: runtime.Allocator_Error
	d.swapchain.images, images_error = make([dynamic]Texture, 0, 8, d.allocator)
	d.swapchain.present, present_error = make([dynamic]vk.Semaphore, 0, 8, d.allocator)
	d.fresh = make([dynamic]Buffer, d.allocator)
	ok &&= images_error == nil && present_error == nil
	if !ok {set_error(d, "out of memory for the resource tables")}
	return ok
}



@(private)
vk_create_device :: proc(d: ^Device, desc: Device_Desc) -> bool {
	d.info.backend = .Vulkan
	// The loader keeps one list of drivers for the process: opening it, making
	// the instance, listing its physical devices and making the device are done
	// by one thread at a time when the application creates devices on several.
	d.loader_lock = desc.loader_lock
	vk_loader_lock(d)
	made := vk_create_instance_and_device(d, desc)
	vk_loader_unlock(d)
	if !made || !vk_finish_device(d, desc) {return false}
	if d.swapchain.surface == 0 {return true}
	d.has_swapchain = true
	return vk_recreate_swapchain(d)
}

@(private)
vk_loader_lock :: proc(d: ^Device) {
	if d.loader_lock != nil {sync.mutex_lock(d.loader_lock)}
}

@(private)
vk_loader_unlock :: proc(d: ^Device) {
	if d.loader_lock != nil {sync.mutex_unlock(d.loader_lock)}
}

@(private)
vk_create_instance_and_device :: proc(d: ^Device, desc: Device_Desc) -> bool {
	for name in VK_LIBRARY_NAMES {
		if lib, ok := dynlib.load_library(name); ok {d.library = lib; break}
	}
	if d.library == nil {set_error(d, "Vulkan loader not found"); return false}
	get_instance_proc, found := dynlib.symbol_address(d.library, "vkGetInstanceProcAddr")
	if !found {set_error(d, "vkGetInstanceProcAddr missing in Vulkan loader"); return false}
	d.get_instance_proc = cast(vk.ProcGetInstanceProcAddr)get_instance_proc
	vk_load_procs(&d.ivk, Vk_Instance_Procs, d.get_instance_proc, nil, nil, nil)
	if d.ivk.CreateInstance == nil {set_error(d, "the Vulkan loader has no vkCreateInstance"); return false}

	layer_count: u32
	d.ivk.EnumerateInstanceLayerProperties(&layer_count, nil)
	layers := make([]vk.LayerProperties, layer_count, context.temp_allocator)
	d.ivk.EnumerateInstanceLayerProperties(&layer_count, raw_data(layers))
	ext_count: u32
	d.ivk.EnumerateInstanceExtensionProperties(nil, &ext_count, nil)
	instance_exts := make([]vk.ExtensionProperties, ext_count, context.temp_allocator)
	d.ivk.EnumerateInstanceExtensionProperties(nil, &ext_count, raw_data(instance_exts))

	want_validation := desc.validation || env_flag("MIRAI_VALIDATION") == "1"
	validation := false
	if want_validation {
		for &layer in layers {
			if string(cstring(&layer.layerName[0])) == "VK_LAYER_KHRONOS_validation" {validation = true}
		}
		if !validation && d.on_message != nil {d.on_message(.Validation_Warning, "validation requested but VK_LAYER_KHRONOS_validation is not installed", d.message_user)}
	}
	d.debug_utils = has_extension(instance_exts, "VK_EXT_debug_utils")

	extensions := make([dynamic]cstring, 0, 16, context.temp_allocator)
	for e in desc.vulkan_instance_extensions {
		append(&extensions, e)
		if string(e) == "VK_KHR_surface" {d.surface_ext = true}
	}
	if d.debug_utils {append(&extensions, "VK_EXT_debug_utils")}
	enabled_layers := make([dynamic]cstring, 0, 2, context.temp_allocator)
	if validation {append(&enabled_layers, "VK_LAYER_KHRONOS_validation")}

	app := vk.ApplicationInfo{
		sType = .APPLICATION_INFO,
		pApplicationName = desc.app_name if desc.app_name != nil else "Mirai",
		applicationVersion = vk.MAKE_VERSION(0, 2, 0),
		pEngineName = "Mirai",
		engineVersion = vk.MAKE_VERSION(0, 2, 0),
		apiVersion = vk.API_VERSION_1_3,
	}
	validation_features := [?]vk.ValidationFeatureEnableEXT{.SYNCHRONIZATION_VALIDATION}
	features_info := vk.ValidationFeaturesEXT{
		sType = .VALIDATION_FEATURES_EXT,
		enabledValidationFeatureCount = len(validation_features),
		pEnabledValidationFeatures = raw_data(validation_features[:]),
	}
	messenger_info := vk.DebugUtilsMessengerCreateInfoEXT{
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR},
		messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = vk_debug_callback,
		pUserData = d,
	}
	instance_info := vk.InstanceCreateInfo{
		sType = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &app,
		enabledLayerCount = u32(len(enabled_layers)),
		ppEnabledLayerNames = raw_data(enabled_layers),
		enabledExtensionCount = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
	}
	// Without this setting the synchronization validation ignores accesses
	// made through descriptors (storage/uniform/sampled), which is exactly
	// what the hazard tracker must get right.
	true_value: b32 = true
	layer_setting := vk.LayerSettingEXT{pLayerName = "VK_LAYER_KHRONOS_validation", pSettingName = "syncval_shader_accesses_heuristic", type = .BOOL32, valueCount = 1, pValues = &true_value}
	layer_settings := vk.LayerSettingsCreateInfoEXT{sType = .LAYER_SETTINGS_CREATE_INFO_EXT, settingCount = 1, pSettings = &layer_setting}
	if validation {
		// The layer reads the settings struct from the chain; the extension
		// itself is not enabled because older loaders reject its name.
		layer_settings.pNext = &messenger_info if d.debug_utils else nil
		features_info.pNext = &layer_settings
		instance_info.pNext = &features_info
	}
	if !vk_check(d, d.ivk.CreateInstance(&instance_info, nil, &d.instance), "vkCreateInstance") {return false}
	vk_load_procs(&d.ivk, Vk_Instance_Procs, d.get_instance_proc, d.instance, nil, nil)
	if validation && d.debug_utils {
		vk_check(d, d.ivk.CreateDebugUtilsMessengerEXT(d.instance, &messenger_info, nil, &d.messenger), "vkCreateDebugUtilsMessengerEXT")
	}
	d.info.features.validation = validation

	if desc.surface != {} {
		if desc.surface.vulkan_create == nil || !d.surface_ext {set_error(d, "a window needs Surface_Desc.vulkan_create and VK_KHR_surface in Device_Desc.vulkan_instance_extensions, which the platform layer gives"); return false}
		d.swapchain.desc = desc.surface
		if !vk_surface_make(d) {return false}
	}
	if !vk_pick_physical_device(d, desc) {return false}
	return vk_create_logical_device(d, desc)
}

@(private)
vk_finish_device :: proc(d: ^Device, desc: Device_Desc) -> bool {
	if !vk_create_frames(d, desc) {return false}
	return vk_create_texture_table(d)
}

@(private)
Vk_Candidate :: struct {
	type:   vk.PhysicalDeviceType,
	name:   string,
	family: int, // the queue family the device would use; -1: none, the device is not chosen
}

// The first queue family with graphics and compute that presents, given what
// each family answered for the window's surface; with no window (nil) the first one.
@(private)
vk_queue_family :: proc "contextless" (families: []vk.QueueFamilyProperties, presents: []b32) -> int {
	for f, i in families {
		if .GRAPHICS not_in f.queueFlags || .COMPUTE not_in f.queueFlags {continue}
		if presents == nil || i < len(presents) && presents[i] {return i}
	}
	return -1
}

// The device of those with a family: one whose name holds preferred first,
// then discrete, integrated, virtual and CPU. -1: none.
@(private)
vk_pick :: proc(candidates: []Vk_Candidate, preferred: string) -> int {
	best, best_score := -1, -1
	for c, i in candidates {
		if c.family < 0 {continue}
		score := 0
		#partial switch c.type {
		case .DISCRETE_GPU:   score = 1000
		case .INTEGRATED_GPU: score = 500
		case .VIRTUAL_GPU:    score = 200
		case .CPU:            score = 10
		}
		if preferred != "" && strings.contains(strings.to_lower(c.name, context.temp_allocator), strings.to_lower(preferred, context.temp_allocator)) {score += 100000}
		if score > best_score {best, best_score = i, score}
	}
	return best
}

// Makes the surface of the window with the callback of the platform. Made
// again after a loss, the queue of the device must still present to it.
@(private)
vk_surface_make :: proc(d: ^Device) -> bool {
	sc := &d.swapchain
	raw, ok := sc.desc.vulkan_create(d.instance, sc.desc.vulkan_user)
	if !ok {set_error(d, "the platform could not create a Vulkan surface for the window"); return false}
	sc.surface = vk.SurfaceKHR(raw)
	if d.physical == nil {return true}
	supported: b32
	if d.ivk.GetPhysicalDeviceSurfaceSupportKHR(d.physical, d.queue_family, sc.surface, &supported) != .SUCCESS || !supported {
		set_error(d, "the window's surface, made again, no longer takes images of %s: restart the application so it chooses a GPU that presents to the display", d.info.name)
		return false
	}
	return true
}

// Whether a call on the window's surface found it lost (a display change, a
// driver reset): the swapchain and the surface are made again when the next
// frame begins. From any thread.
@(private)
vk_surface_lost :: proc "contextless" (d: ^Device, result: vk.Result) -> bool {
	if result != .ERROR_SURFACE_LOST_KHR {return false}
	sync.atomic_store(&d.swapchain.lost, true)
	return true
}

// Makes the lost surface again from the window, with the GPU idle. After
// VK_SURFACE_TRIES frames that could not, the window stays without images.
@(private)
vk_surface_remake :: proc(d: ^Device) -> bool {
	sc := &d.swapchain
	if sc.tries >= VK_SURFACE_TRIES {return false}
	vk_destroy_swapchain(d)
	sc.stale = true
	if sc.surface != 0 {d.ivk.DestroySurfaceKHR(d.instance, sc.surface, nil); sc.surface = 0}
	if !vk_surface_make(d) {
		if sc.surface != 0 {d.ivk.DestroySurfaceKHR(d.instance, sc.surface, nil); sc.surface = 0}
		sc.tries += 1
		if sc.tries == VK_SURFACE_TRIES {
			cause := strings.clone(d.error, context.temp_allocator)
			set_error(d, "the window lost its Vulkan surface and %d frames could not make it again (%s): the window shows nothing until the application restarts", VK_SURFACE_TRIES, cause)
		}
		return false
	}
	sc.tries = 0
	sync.atomic_store(&sc.lost, false)
	return true
}

@(private)
vk_pick_physical_device :: proc(d: ^Device, desc: Device_Desc) -> bool {
	count: u32
	d.ivk.EnumeratePhysicalDevices(d.instance, &count, nil)
	if count == 0 {set_error(d, "no Vulkan physical devices"); return false}
	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	d.ivk.EnumeratePhysicalDevices(d.instance, &count, raw_data(devices))
	surface := d.swapchain.surface
	candidates := make([]Vk_Candidate, count, context.temp_allocator)
	for physical, i in devices {
		c := &candidates[i]
		c.family = -1
		props: vk.PhysicalDeviceProperties
		d.ivk.GetPhysicalDeviceProperties(physical, &props)
		c.type = props.deviceType
		c.name = strings.clone(string(cstring(&props.deviceName[0])), context.temp_allocator)
		if props.apiVersion < vk.API_VERSION_1_3 {continue}
		ext_count: u32
		d.ivk.EnumerateDeviceExtensionProperties(physical, nil, &ext_count, nil)
		exts := make([]vk.ExtensionProperties, ext_count, context.temp_allocator)
		d.ivk.EnumerateDeviceExtensionProperties(physical, nil, &ext_count, raw_data(exts))
		if !has_extension(exts, "VK_KHR_push_descriptor") || surface != 0 && !has_extension(exts, "VK_KHR_swapchain") {continue}
		family_count: u32
		d.ivk.GetPhysicalDeviceQueueFamilyProperties(physical, &family_count, nil)
		families := make([]vk.QueueFamilyProperties, family_count, context.temp_allocator)
		d.ivk.GetPhysicalDeviceQueueFamilyProperties(physical, &family_count, raw_data(families))
		presents: []b32
		if surface != 0 {
			presents = make([]b32, family_count, context.temp_allocator)
			for &present, f in presents {
				if d.ivk.GetPhysicalDeviceSurfaceSupportKHR(physical, u32(f), surface, &present) != .SUCCESS {present = false}
			}
		}
		c.family = vk_queue_family(families, presents)
	}
	preferred := env_flag("MIRAI_GPU")
	if preferred == "" {preferred = desc.preferred_device}
	best := vk_pick(candidates, preferred)
	if best < 0 {
		if surface != 0 {set_error(d, "no Vulkan 1.3 device with push descriptors has a graphics+compute queue that presents to the window: update the GPU driver, or connect the display to a GPU that has one"); return false}
		set_error(d, "no Vulkan 1.3 device with push descriptors and a graphics+compute queue")
		return false
	}
	d.physical = devices[best]
	d.queue_family = u32(candidates[best].family)
	d.ivk.GetPhysicalDeviceProperties(d.physical, &d.properties)
	d.ivk.GetPhysicalDeviceMemoryProperties(d.physical, &d.memory_properties)
	vk_memory_init(&d.memory, &d.memory_properties, d.properties.limits.maxMemoryAllocationCount, u64(d.properties.limits.bufferImageGranularity), d.allocator)
	name := string(cstring(&d.properties.deviceName[0]))
	n := copy(d.name_buffer[:], name)
	d.info.name = string(d.name_buffer[:n])
	#partial switch d.properties.deviceType {
	case .DISCRETE_GPU:   d.info.type = .Discrete
	case .INTEGRATED_GPU: d.info.type = .Integrated
	case .VIRTUAL_GPU:    d.info.type = .Virtual
	case .CPU:            d.info.type = .CPU
	}
	d.info.max_texture_size = d.properties.limits.maxImageDimension2D
	d.info.max_texture_layers = d.properties.limits.maxImageArrayLayers
	d.info.timestamp_period_ns = d.properties.limits.timestampPeriod
	d.info.uniform_alignment = u64(d.properties.limits.minUniformBufferOffsetAlignment)
	d.info.storage_alignment = u64(d.properties.limits.minStorageBufferOffsetAlignment)
	d.info.max_storage_range = u64(d.properties.limits.maxStorageBufferRange)
	for heap in d.memory_properties.memoryHeaps[:d.memory_properties.memoryHeapCount] {
		if .DEVICE_LOCAL in heap.flags {d.info.memory = max(d.info.memory, u64(heap.size))}
	}
	return true
}

// The calibrated timestamps extension to enable, when the device can sample its
// clock together with the one of time.tick_now. KHR is preferred to EXT.
@(private)
vk_calibrated_extension :: proc(d: ^Device, exts: []vk.ExtensionProperties) -> (name: cstring, khr: bool) {
	domains_of: vk.ProcGetPhysicalDeviceCalibrateableTimeDomainsKHR
	if has_extension(exts, vk.KHR_CALIBRATED_TIMESTAMPS_EXTENSION_NAME) && d.ivk.GetPhysicalDeviceCalibrateableTimeDomainsKHR != nil {
		name, khr, domains_of = vk.KHR_CALIBRATED_TIMESTAMPS_EXTENSION_NAME, true, d.ivk.GetPhysicalDeviceCalibrateableTimeDomainsKHR
	} else if has_extension(exts, vk.EXT_CALIBRATED_TIMESTAMPS_EXTENSION_NAME) && d.ivk.GetPhysicalDeviceCalibrateableTimeDomainsEXT != nil {
		name, domains_of = vk.EXT_CALIBRATED_TIMESTAMPS_EXTENSION_NAME, d.ivk.GetPhysicalDeviceCalibrateableTimeDomainsEXT
	} else {
		return nil, false
	}
	domains: [16]vk.TimeDomainKHR
	count := u32(len(domains))
	result := domains_of(d.physical, &count, &domains[0])
	if result != .SUCCESS && result != .INCOMPLETE {return nil, false}
	device, host := false, false
	for domain in domains[:count] {
		if domain == .DEVICE {device = true}
		if domain == VK_HOST_TIME_DOMAIN {host = true}
	}
	if !device || !host {return nil, false}
	return name, khr
}

@(private)
vk_create_logical_device :: proc(d: ^Device, desc: Device_Desc) -> bool {
	ext_count: u32
	d.ivk.EnumerateDeviceExtensionProperties(d.physical, nil, &ext_count, nil)
	exts := make([]vk.ExtensionProperties, ext_count, context.temp_allocator)
	d.ivk.EnumerateDeviceExtensionProperties(d.physical, nil, &ext_count, raw_data(exts))

	// Query everything we may enable.
	as_features := vk.PhysicalDeviceAccelerationStructureFeaturesKHR{sType = .PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR}
	rq_features := vk.PhysicalDeviceRayQueryFeaturesKHR{sType = .PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR, pNext = &as_features}
	v13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES}
	v12 := vk.PhysicalDeviceVulkan12Features{sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, pNext = &v13}
	v11 := vk.PhysicalDeviceVulkan11Features{sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, pNext = &v12}
	rt_exts_present := has_extension(exts, "VK_KHR_acceleration_structure") && has_extension(exts, "VK_KHR_ray_query") && has_extension(exts, "VK_KHR_deferred_host_operations")
	if rt_exts_present {v13.pNext = &rq_features}
	supported := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &v11}
	// A loss then comes with what the driver says of its fault.
	fault := vk.PhysicalDeviceFaultFeaturesEXT{sType = .PHYSICAL_DEVICE_FAULT_FEATURES_EXT, pNext = &v11}
	fault_ext := has_extension(exts, vk.EXT_DEVICE_FAULT_EXTENSION_NAME)
	if fault_ext {supported.pNext = &fault}
	d.ivk.GetPhysicalDeviceFeatures2(d.physical, &supported)
	// GPU culling writes firstInstance = instance index into indirect draws.
	if !v13.dynamicRendering || !v13.synchronization2 || !v12.timelineSemaphore || !supported.features.multiDrawIndirect || !supported.features.drawIndirectFirstInstance {
		set_error(d, "device lacks dynamic rendering, synchronization2, timeline semaphores, multi draw indirect or indirect first instance")
		return false
	}
	// The texture table is indexed per pixel and per ray hit.
	limits := &d.properties.limits
	if !v12.scalarBlockLayout {
		set_error(d, "device lacks scalar block layout required by the shared shader data ABI")
		return false
	}
	// It is an array without a size whose sets take the count they need.
	d.table_limit = min(TEXTURE_TABLE_MAX, int(limits.maxPerStageDescriptorSampledImages) - MAX_BINDING_SLOTS, int(limits.maxDescriptorSetSampledImages))
	if !v12.shaderSampledImageArrayNonUniformIndexing || !supported.features.shaderSampledImageArrayDynamicIndexing ||
	   !v12.runtimeDescriptorArray || !v12.descriptorBindingVariableDescriptorCount || d.table_limit < TEXTURE_TABLE_FIRST {
		set_error(d, "device lacks non-uniform indexing of an array of at least %d sampled textures of a variable count", TEXTURE_TABLE_FIRST)
		return false
	}
	if limits.maxColorAttachments < MAX_COLOR_TARGETS {
		set_error(d, "device draws to %d color targets at once and the G-buffer needs %d", limits.maxColorAttachments, MAX_COLOR_TARGETS)
		return false
	}
	rt_env := env_flag("MIRAI_RT")
	ray_query := rt_exts_present && bool(rq_features.rayQuery) && bool(as_features.accelerationStructure) && bool(v12.bufferDeviceAddress) && desc.allow_hardware_ray_tracing && rt_env != "software" && rt_env != "0"

	enable_v13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, dynamicRendering = true, synchronization2 = true, maintenance4 = v13.maintenance4}
	enable_v12 := vk.PhysicalDeviceVulkan12Features{
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, pNext = &enable_v13,
		timelineSemaphore = true,
		drawIndirectCount = v12.drawIndirectCount,
		bufferDeviceAddress = b32(ray_query),
		hostQueryReset = v12.hostQueryReset,
		samplerFilterMinmax = v12.samplerFilterMinmax,
		scalarBlockLayout = v12.scalarBlockLayout,
		shaderSampledImageArrayNonUniformIndexing = true,
		runtimeDescriptorArray = true,
		descriptorBindingVariableDescriptorCount = true,
	}
	enable_v11 := vk.PhysicalDeviceVulkan11Features{sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, pNext = &enable_v12, shaderDrawParameters = v11.shaderDrawParameters}
	enable_as := vk.PhysicalDeviceAccelerationStructureFeaturesKHR{sType = .PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR, accelerationStructure = true}
	enable_rq := vk.PhysicalDeviceRayQueryFeaturesKHR{sType = .PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR, pNext = &enable_as, rayQuery = true}
	if ray_query {enable_v13.pNext = &enable_rq}
	core_features := vk.PhysicalDeviceFeatures{
		multiDrawIndirect = true,
		drawIndirectFirstInstance = true,
		samplerAnisotropy = supported.features.samplerAnisotropy,
		textureCompressionBC = supported.features.textureCompressionBC,
		imageCubeArray = supported.features.imageCubeArray,
		shaderSampledImageArrayDynamicIndexing = true,
		fragmentStoresAndAtomics = supported.features.fragmentStoresAndAtomics,
		shaderInt64 = supported.features.shaderInt64,
		independentBlend = supported.features.independentBlend,
		shaderStorageImageWriteWithoutFormat = supported.features.shaderStorageImageWriteWithoutFormat,
		shaderClipDistance = supported.features.shaderClipDistance,
	}
	enable := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &enable_v11, features = core_features}
	d.fault_info = fault_ext && bool(fault.deviceFault)
	enable_fault := vk.PhysicalDeviceFaultFeaturesEXT{sType = .PHYSICAL_DEVICE_FAULT_FEATURES_EXT, pNext = &enable_v11, deviceFault = true}
	if d.fault_info {enable.pNext = &enable_fault}

	device_exts := make([dynamic]cstring, 0, 8, context.temp_allocator)
	append(&device_exts, "VK_KHR_push_descriptor")
	// Headless devices (tests, offline capture) skip presentation entirely.
	d.swapchain_ext = d.surface_ext && has_extension(exts, "VK_KHR_swapchain")
	if d.swapchain_ext {append(&device_exts, "VK_KHR_swapchain")}
	if ray_query {append(&device_exts, "VK_KHR_acceleration_structure", "VK_KHR_ray_query", "VK_KHR_deferred_host_operations")}
	d.shared_memory = has_extension(exts, VK_SHARED_EXTENSION)
	if d.shared_memory {append(&device_exts, VK_SHARED_EXTENSION)}
	if d.fault_info {append(&device_exts, vk.EXT_DEVICE_FAULT_EXTENSION_NAME)}
	calibrated, calibrated_khr := vk_calibrated_extension(d, exts)
	if calibrated != nil {append(&device_exts, calibrated)}
	d.memory_budget = has_extension(exts, vk.EXT_MEMORY_BUDGET_EXTENSION_NAME)
	if d.memory_budget {append(&device_exts, vk.EXT_MEMORY_BUDGET_EXTENSION_NAME)}

	priority: f32 = 1
	queue_info := vk.DeviceQueueCreateInfo{sType = .DEVICE_QUEUE_CREATE_INFO, queueFamilyIndex = d.queue_family, queueCount = 1, pQueuePriorities = &priority}
	device_info := vk.DeviceCreateInfo{
		sType = .DEVICE_CREATE_INFO,
		pNext = &enable,
		queueCreateInfoCount = 1,
		pQueueCreateInfos = &queue_info,
		enabledExtensionCount = u32(len(device_exts)),
		ppEnabledExtensionNames = raw_data(device_exts),
	}
	if !vk_check(d, d.ivk.CreateDevice(d.physical, &device_info, nil, &d.handle), "vkCreateDevice") {return false}
	vk_load_procs(&d.dvk, vk.Device_VTable, nil, nil, d.ivk.GetDeviceProcAddr, d.handle)
	d.dvk.GetDeviceQueue(d.handle, d.queue_family, 0, &d.queue)

	d.anisotropy = bool(supported.features.samplerAnisotropy)
	d.cube_arrays = bool(supported.features.imageCubeArray)
	d.info.features.texture_bc = bool(supported.features.textureCompressionBC)
	d.info.features.ray_query = ray_query
	d.info.features.clip_distance = bool(supported.features.shaderClipDistance)
	d.info.features.draw_indirect_count = bool(v12.drawIndirectCount)
	family_count: u32
	d.ivk.GetPhysicalDeviceQueueFamilyProperties(d.physical, &family_count, nil)
	families := make([]vk.QueueFamilyProperties, family_count, context.temp_allocator)
	d.ivk.GetPhysicalDeviceQueueFamilyProperties(d.physical, &family_count, raw_data(families))
	d.timestamp_bits = families[d.queue_family].timestampValidBits
	d.info.features.timestamps = bool(d.properties.limits.timestampComputeAndGraphics) && d.properties.limits.timestampPeriod > 0 && d.timestamp_bits > 0
	if calibrated_khr {
		d.calibrate = d.dvk.GetCalibratedTimestampsKHR
	} else if calibrated != nil {
		d.calibrate = d.dvk.GetCalibratedTimestampsEXT
	}
	d.host_clock_rate = vk_host_clock_rate()
	if ray_query {
		as_props := vk.PhysicalDeviceAccelerationStructurePropertiesKHR{sType = .PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_PROPERTIES_KHR}
		props2 := vk.PhysicalDeviceProperties2{sType = .PHYSICAL_DEVICE_PROPERTIES_2, pNext = &as_props}
		d.ivk.GetPhysicalDeviceProperties2(d.physical, &props2)
		d.scratch_alignment = max(u64(as_props.minAccelerationStructureScratchOffsetAlignment), 256)
	}
	// A path that does not fit, cut, would name another file: nothing is kept.
	if len(desc.pipeline_cache_path) <= len(d.store_path) {d.store_path_len = copy(d.store_path[:], desc.pipeline_cache_path)}
	if d.store_path_len > 0 {
		p := d.properties
		pipeline_store_init(&d.pipelines_kept, {vendor = p.vendorID, device = p.deviceID, driver = p.driverVersion, uuid = p.pipelineCacheUUID}, allocator = d.allocator)
		pipeline_store_load(&d.pipelines_kept, desc.pipeline_cache_path)
	}
	return true
}

@(private)
vk_create_frames :: proc(d: ^Device, desc: Device_Desc) -> bool {
	timeline_type := vk.SemaphoreTypeCreateInfo{sType = .SEMAPHORE_TYPE_CREATE_INFO, semaphoreType = .TIMELINE}
	timeline_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO, pNext = &timeline_type}
	if !vk_check(d, d.dvk.CreateSemaphore(d.handle, &timeline_info, nil, &d.timeline), "timeline semaphore") {return false}
	upload_size := desc.upload_bytes_per_frame if desc.upload_bytes_per_frame > 0 else 16 * 1024 * 1024
	for &f, i in d.frames {
		pool_info := vk.CommandPoolCreateInfo{sType = .COMMAND_POOL_CREATE_INFO, flags = {.TRANSIENT}, queueFamilyIndex = d.queue_family}
		if !vk_check(d, d.dvk.CreateCommandPool(d.handle, &pool_info, nil, &f.pool), "command pool") {return false}
		alloc := vk.CommandBufferAllocateInfo{sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = f.pool, level = .PRIMARY, commandBufferCount = 1}
		if !vk_check(d, d.dvk.AllocateCommandBuffers(d.handle, &alloc, &f.cmd), "command buffer") {return false}
		semaphore_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
		if !vk_check(d, d.dvk.CreateSemaphore(d.handle, &semaphore_info, nil, &f.acquire), "acquire semaphore") {return false}
		f.upload = vk_create_buffer(d, Buffer_Desc{size = upload_size, usage = TRANSIENT_USAGE, memory = .Upload, name = fmt.tprintf("frame upload %d", i)})
		if f.upload == 0 {return false}
		f.upload_ptr = cast([^]u8)pool_get(&d.buffers, base.Handle(f.upload)).mapped
		f.upload_size = upload_size
		if d.info.features.timestamps {
			query_info := vk.QueryPoolCreateInfo{sType = .QUERY_POOL_CREATE_INFO, queryType = .TIMESTAMP, queryCount = MAX_TIMESTAMPS}
			d.dvk.CreateQueryPool(d.handle, &query_info, nil, &f.queries)
		}
		f.list.device = d
		f.list.cmd = f.cmd
	}
	pool_info := vk.CommandPoolCreateInfo{sType = .COMMAND_POOL_CREATE_INFO, flags = {.RESET_COMMAND_BUFFER}, queueFamilyIndex = d.queue_family}
	if !vk_check(d, d.dvk.CreateCommandPool(d.handle, &pool_info, nil, &d.immediate_pool), "immediate pool") {return false}
	alloc := vk.CommandBufferAllocateInfo{sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = d.immediate_pool, level = .PRIMARY, commandBufferCount = 1}
	if !vk_check(d, d.dvk.AllocateCommandBuffers(d.handle, &alloc, &d.immediate.cmd), "immediate command buffer") {return false}
	d.immediate.device = d
	d.immediate.immediate = true
	fence_info := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO}
	return vk_check(d, d.dvk.CreateFence(d.handle, &fence_info, nil, &d.immediate_fence), "immediate fence")
}

device_destroy :: proc(d: ^Device) {
	if d == nil {return}
	// A GPU that may still run work a wait gave up on keeps its objects: the
	// driver frees them when the process ends.
	if d.handle != nil && !d.waited_out {present_stop(d)}
	if d.handle != nil && !d.waited_out {
		// A lost device returns at once; one device_lose failed still runs what it was given.
		if !vk_idle(d) {d.dvk.DeviceWaitIdle(d.handle)}
		vk_destroy_swapchain(d)
		for &f in d.frames {
			if f.upload != 0 {buffer_destroy(d, f.upload)}
		}
		if d.scratch != 0 {buffer_destroy(d, d.scratch)}
		// The blocks of the arena are buffers, released below with the others.
		arena_destroy(&d.accel_arena)
		delete(d.accel_blocks)
		delete(d.accel_empty)
		if d.compact_pool != 0 {d.dvk.DestroyQueryPool(d.handle, d.compact_pool, nil)}
		delete(d.compact_free)
		// Resources the caller did not destroy are released here so shutdown
		// stays clean under validation.
		if d.table_pool != 0 {d.dvk.DestroyDescriptorPool(d.handle, d.table_pool, nil)}
		delete(d.table_textures)
		delete(d.table_taken, d.allocator)
		table_changes_destroy(&d.table_changes)
		if d.table_layout != 0 {d.dvk.DestroyDescriptorSetLayout(d.handle, d.table_layout, nil)}
		for &a, i in d.accels.items {if d.accels.alive[i] && a.handle != 0 {d.dvk.DestroyAccelerationStructureKHR(d.handle, a.handle, nil)}}
		for &p, i in d.pipelines.items {if d.pipelines.alive[i] {vk_release_pipeline(d, &p)}}
		for &t, i in d.textures.items {if d.textures.alive[i] && !t.swapchain {vk_release_texture(d, &t)}}
		for &b, i in d.buffers.items {
			if d.buffers.alive[i] {
				d.dvk.DestroyBuffer(d.handle, b.handle, nil)
				vk_memory_unbind(d, b.memory)
			}
		}
		for &s, i in d.samplers.items {if d.samplers.alive[i] {d.dvk.DestroySampler(d.handle, s, nil)}}
		for &f in d.frames {
			vk_flush_deletions(d, &f)
			if f.pool != 0 {d.dvk.DestroyCommandPool(d.handle, f.pool, nil)}
			if f.acquire != 0 {d.dvk.DestroySemaphore(d.handle, f.acquire, nil)}
			if f.queries != 0 {d.dvk.DestroyQueryPool(d.handle, f.queries, nil)}
		}
		if d.immediate_pool != 0 {d.dvk.DestroyCommandPool(d.handle, d.immediate_pool, nil)}
		if d.immediate_fence != 0 {d.dvk.DestroyFence(d.handle, d.immediate_fence, nil)}
		if d.timeline != 0 {d.dvk.DestroySemaphore(d.handle, d.timeline, nil)}
		vk_memory_shutdown(d, true)
		if d.store_path_len > 0 {_ = pipeline_store_save(&d.pipelines_kept, string(d.store_path[:d.store_path_len]))}
		vk_loader_lock(d)
		d.dvk.DestroyDevice(d.handle, nil)
		vk_loader_unlock(d)
	}
	// Made before the device, so a device that was not made leaves it too.
	if d.swapchain.surface != 0 && !d.waited_out {d.ivk.DestroySurfaceKHR(d.instance, d.swapchain.surface, nil)}
	vk_loader_lock(d)
	if d.messenger != 0 {d.ivk.DestroyDebugUtilsMessengerEXT(d.instance, d.messenger, nil)}
	if d.instance != nil {d.ivk.DestroyInstance(d.instance, nil)}
	if d.library != nil {dynlib.unload_library(d.library)}
	vk_loader_unlock(d)
	vk_memory_shutdown(d, false)
	pipeline_store_destroy(&d.pipelines_kept)
	delete(d.fresh)
	for &f in d.frames {delete(f.deletions); delete(f.list.commands, d.allocator)}
	delete(d.immediate.commands, d.allocator)
	delete(d.swapchain.images)
	delete(d.swapchain.present)
	pool_destroy(&d.buffers, d.allocator)
	pool_destroy(&d.textures, d.allocator)
	pool_destroy(&d.samplers, d.allocator)
	pool_destroy(&d.pipelines, d.allocator)
	pool_destroy(&d.accels, d.allocator)
	free(d, d.allocator)
}

device_info :: proc(d: ^Device) -> ^Device_Info {return &d.info}

// Bytes of the memory of the device this process holds, and what the system
// lets it hold before it moves some of it out to system memory, over the
// heaps local to the device; zeros when the driver does not say.
device_memory :: proc(d: ^Device) -> (used, budget: u64) {
	if !d.memory_budget || d.ivk.GetPhysicalDeviceMemoryProperties2 == nil {return}
	said := vk.PhysicalDeviceMemoryBudgetPropertiesEXT{sType = .PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT}
	properties := vk.PhysicalDeviceMemoryProperties2{sType = .PHYSICAL_DEVICE_MEMORY_PROPERTIES_2, pNext = &said}
	d.ivk.GetPhysicalDeviceMemoryProperties2(d.physical, &properties)
	heaps := properties.memoryProperties
	for heap, i in heaps.memoryHeaps[:heaps.memoryHeapCount] {
		if .DEVICE_LOCAL not_in heap.flags {continue}
		used += u64(said.heapUsage[i])
		budget += u64(said.heapBudget[i])
	}
	return
}
device_error :: proc(d: ^Device) -> string {return d.error}
device_validation_errors :: proc(d: ^Device) -> int {return d.validation_errors}
device_loader_errors :: proc(d: ^Device) -> int {return d.loader_errors}
device_validation_message :: proc(d: ^Device) -> string {
	if d.validation_seen == 0 {return ""}
	slot := (d.validation_seen - 1) % VALIDATION_HISTORY
	return string(d.validation_ring[slot][:d.validation_length[slot]])
}

// Fills out with the last validation messages, the oldest first, and returns how many.
// The strings point into the device and hold until the next message.
device_validation_messages :: proc(d: ^Device, out: []string) -> int {
	n := min(len(out), d.validation_seen, VALIDATION_HISTORY)
	for i in 0 ..< n {
		slot := (d.validation_seen - n + i) % VALIDATION_HISTORY
		out[i] = string(d.validation_ring[slot][:d.validation_length[slot]])
	}
	return n
}

// What the device made for itself, which device_stats leaves out.
@(private)
device_own :: proc(d: ^Device) -> (buffers, textures, pipelines: int) {
	for f in d.frames {buffers += int(f.upload != 0) + f.oversized_count}
	for block in d.accel_blocks {if block != 0 {buffers += 1}}
	if d.scratch != 0 {buffers += 1}
	if d.staging != 0 {buffers += 1}
	if d.table_default != 0 {textures += 1}
	if d.tlas_translator != 0 {pipelines += 1}
	return
}

// Forgets the validation errors and messages so far: each user of a device
// lent to one after another (rhi/shared_device) counts its own.
device_validation_forget :: proc(d: ^Device) {
	sync.guard(&d.message_lock)
	d.validation_errors, d.validation_seen = 0, 0
}

// Waits until the GPU finished everything submitted, within
// GPU_WAIT_LIMIT_NS; false when the device failed.
device_wait_idle :: proc(d: ^Device) -> bool {return vk_idle(d)}

// Whether the timings of the device are placed by a sampled pair of clocks.
device_timestamps_calibrated :: proc(d: ^Device) -> bool {return d.calibrate != nil}

// ---------------------------------------------------------------- deletion

@(private)
vk_release_deferred :: proc(d: ^Device, e: ^Vk_Deferred) {
	if e.accel != 0 {d.dvk.DestroyAccelerationStructureKHR(d.handle, e.accel, nil)}
	// The block of an empty range goes later: destroying it here would defer it into the list being released.
	if e.arena_block > 0 && arena_give(&d.accel_arena, int(e.arena_block - 1), e.arena_offset, e.arena_size) {
		append(&d.accel_empty, int(e.arena_block - 1))
	}
	if e.pipeline != 0 {d.dvk.DestroyPipeline(d.handle, e.pipeline, nil)}
	if e.layout != 0 {d.dvk.DestroyPipelineLayout(d.handle, e.layout, nil)}
	if e.set_layout != 0 {d.dvk.DestroyDescriptorSetLayout(d.handle, e.set_layout, nil)}
	if e.descriptor_pool != 0 {d.dvk.DestroyDescriptorPool(d.handle, e.descriptor_pool, nil)}
	for view in e.views {if view != 0 {d.dvk.DestroyImageView(d.handle, view, nil)}}
	vk_layer_views_release(d, e.layer_views)
	if e.image != 0 {d.dvk.DestroyImage(d.handle, e.image, nil)}
	if e.buffer != 0 {d.dvk.DestroyBuffer(d.handle, e.buffer, nil)}
	vk_memory_unbind(d, e.memory)
	if e.sampler != 0 {d.dvk.DestroySampler(d.handle, e.sampler, nil)}
}

@(private)
vk_flush_deletions :: proc(d: ^Device, f: ^Vk_Frame) {
	for &e in f.deletions {vk_release_deferred(d, &e)}
	clear(&f.deletions)
}

@(private)
vk_defer :: proc(d: ^Device, e: Vk_Deferred) {
	// The current slot is reused only after the GPU finished it; that slot also
	// covers anything recorded later in this frame. Between frames d.slot
	// already names the next slot, whose wait does not cover the most recent
	// submission, so the object waits for the previous slot instead.
	slot := d.slot if d.in_frame else (d.slot + MAX_FRAMES_IN_FLIGHT - 1) % MAX_FRAMES_IN_FLIGHT
	list := &d.frames[slot].deletions
	if len(list) == cap(list) {
		d.stats.deletion_overflows += 1
		// Between frames nothing is being recorded: once the GPU is idle every
		// object that waits can go. Inside a frame the list grows instead.
		if !d.in_frame && vk_idle(d) {
			for &f in d.frames {vk_flush_deletions(d, &f)}
		}
	}
	append(list, e)
}

// ---------------------------------------------------------------- frames

@(private)
vk_wait_timeline :: proc(d: ^Device, value: u64) -> bool {
	if d.failure != .None {return false}
	if value == 0 {return true}
	wait_value := value
	info := vk.SemaphoreWaitInfo{sType = .SEMAPHORE_WAIT_INFO, semaphoreCount = 1, pSemaphores = &d.timeline, pValues = &wait_value}
	return vk_waited(d, d.dvk.WaitSemaphores(d.handle, &info, GPU_WAIT_LIMIT_NS), "vkWaitSemaphores")
}

// Asks for one timing per cmd_timestamp interval in the frames that begin
// from now on; without it a frame reports only its whole GPU time.
timestamps_want :: proc(d: ^Device, on: bool) {d.timestamps_wanted = on}

// A value of VK_HOST_TIME_DOMAIN in the nanoseconds of time.tick_now, which
// converts the same way.
@(private)
vk_host_ns :: proc "contextless" (value: u64, rate: i64) -> i64 {
	if rate == 1e9 {return i64(value)}
	v := i64(value)
	return v / rate * 1e9 + v % rate * 1e9 / rate
}

// The intervals between the timestamps of the slot's completed submission, on
// the clock of time.tick_now. With calibrated timestamps they are converted
// with a GPU and host pair sampled at collection, as Metal does. Without them
// the last one is taken as the moment they are collected, which is later than
// the GPU finished: the lengths are exact, the position is approximate.
@(private)
vk_collect_timestamps :: proc(d: ^Device, f: ^Vk_Frame) {
	count := f.query_count
	f.query_count = 0
	d.timing_count = 0
	if f.queries == 0 || count < 2 {return}
	values: [MAX_TIMESTAMPS]u64
	// The slot's submission already completed, so WAIT returns immediately.
	result := d.dvk.GetQueryPoolResults(d.handle, f.queries, 0, count, size_of(values), &values, size_of(u64), {._64, .WAIT})
	if result != .SUCCESS {vk_lost(d, result, "vkGetQueryPoolResults"); return}
	gpu, now := values[count - 1], time.duration_nanoseconds(time.tick_diff({}, time.tick_now()))
	if d.calibrate != nil {
		infos := [2]vk.CalibratedTimestampInfoKHR{{sType = .CALIBRATED_TIMESTAMP_INFO_KHR, timeDomain = .DEVICE}, {sType = .CALIBRATED_TIMESTAMP_INFO_KHR, timeDomain = VK_HOST_TIME_DOMAIN}}
		pair: [2]u64
		deviation: u64
		if d.calibrate(d.handle, 2, &infos[0], &pair[0], &deviation) == .SUCCESS {
			gpu, now = pair[0], vk_host_ns(pair[1], d.host_clock_rate)
		}
	}
	// A GPU with fewer valid timestamp bits can wrap: the difference is taken in those bits.
	tick_of :: proc "contextless" (ticks, gpu: u64, now: i64, bits: u32, period: f32) -> i64 {
		shift := 64 - min(bits, 64)
		return now + i64(f64(i64((ticks - gpu) << shift) >> shift) * f64(period))
	}
	d.timing_count = int(count) - 1
	present_latency(d, f.begun_ns, f.submitted_ns, i64(f64(values[count - 1] - min(values[0], values[count - 1])) * f64(d.info.timestamp_period_ns)))
	for i in 0 ..< d.timing_count {
		start_ns := tick_of(values[i], gpu, now, d.timestamp_bits, d.info.timestamp_period_ns)
		end_ns := max(tick_of(values[i + 1], gpu, now, d.timestamp_bits, d.info.timestamp_period_ns), start_ns)
		name := string(d.timing_bytes[i][:copy(d.timing_bytes[i][:], f.query_names[i])])
		d.timings[i] = {name = name, ms = f32(f64(end_ns - start_ns) / 1e6), start_ns = start_ns, end_ns = end_ns}
	}
}

frame_timings :: proc(d: ^Device) -> []Gpu_Timing {return d.timings[:d.timing_count]}

// Begins recording a frame. Without present it takes no image of the
// swapchain: the frame draws only into textures, for a capture.
frame_begin :: proc(d: ^Device, present := true) -> (cmd: ^Command_List, ok: bool) {
	if d.in_frame {set_error(d, "frame_begin while a frame is being recorded: end it with frame_end first"); return nil, false}
	f := &d.frames[d.slot]
	if d.failure != .None || !vk_wait_timeline(d, f.signal_value) {return nil, false}
	// Before the deletions: the copy of this slot stops naming what goes.
	vk_table_take(d, table_copy(false, d.slot))
	vk_collect_timestamps(d, f)
	vk_flush_deletions(d, f)
	f.upload_used = 0
	f.acquired = false
	f.paced = false
	f.begun_ns = present_now_ns()
	if d.has_swapchain && present {
		paced, ready := present_frame_begin(d)
		if !ready {return nil, false}
		f.paced = paced
	}
	if d.has_swapchain && present && !f.paced {
		sc := &d.swapchain
		if !swapchain_refresh(d) || sc.handle == 0 {return nil, false}
		result := d.dvk.AcquireNextImageKHR(d.handle, sc.handle, GPU_WAIT_LIMIT_NS, f.acquire, 0, &f.image_index)
		if result == .ERROR_OUT_OF_DATE_KHR {sc.stale = true; return nil, false}
		if vk_surface_lost(d, result) {return nil, false}
		// A compositor may hold the images of a hidden window: the frame is skipped, not the device.
		if result == .TIMEOUT || result == .NOT_READY {return nil, false}
		if result != .SUCCESS && result != .SUBOPTIMAL_KHR {vk_check(d, result, "vkAcquireNextImageKHR"); return nil, false}
		if result == .SUBOPTIMAL_KHR {sc.stale = true}
		f.acquired = true
		texture := pool_get(&d.textures, base.Handle(sc.images[f.image_index]))
		texture.levels = {}
	}
	d.dvk.ResetCommandPool(d.handle, f.pool, {})
	begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
	d.dvk.BeginCommandBuffer(f.cmd, &begin)
	vk_list_reset(&f.list)
	f.passes = false
	if f.queries != 0 {
		d.dvk.CmdResetQueryPool(f.cmd, f.queries, 0, MAX_TIMESTAMPS)
		f.passes = d.timestamps_wanted
		// Without passes the frame is one interval, from here to frame_end.
		if !f.passes {vk_timestamp_write(f, "frame")}
	}
	vk_zero_fresh(&f.list)
	d.in_frame = true
	return &f.list, true
}

// generated: the frame drew swapchain_generated_texture, which is shown before its own image.
frame_end :: proc(d: ^Device, cmd: ^Command_List, generated := false) -> bool {
	if !d.in_frame || cmd != &d.frames[d.slot].list {set_error(d, "frame_end without the list its frame_begin gave"); return false}
	f := &d.frames[d.slot]
	pr := &d.presenter
	frame_oversized_release(d)
	if cmd.in_render_pass {cmd_end_render_pass(cmd)}
	if f.acquired {cmd_barrier_texture(cmd, d.swapchain.images[f.image_index], .Present)}
	if f.paced && pr.pair >= 0 {
		for texture in pr.pairs[pr.pair].textures {cmd_barrier_texture(cmd, texture, .Transfer_Read)}
	}
	vk_flush_barriers(cmd)
	if f.queries != 0 && !f.passes {vk_timestamp_write(f, "")}
	d.dvk.EndCommandBuffer(f.cmd)

	d.timeline_value += 1
	cmd_info := vk.CommandBufferSubmitInfo{sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = f.cmd}
	waits: [1]vk.SemaphoreSubmitInfo
	signals: [2]vk.SemaphoreSubmitInfo
	signal_count := 1
	signals[0] = {sType = .SEMAPHORE_SUBMIT_INFO, semaphore = d.timeline, value = d.timeline_value, stageMask = {.ALL_COMMANDS}}
	submit := vk.SubmitInfo2{sType = .SUBMIT_INFO_2, commandBufferInfoCount = 1, pCommandBufferInfos = &cmd_info}
	if f.paced && pr.wait_value > 0 {
		// The thread copied what the pair held before this frame draws into it.
		waits[0] = {sType = .SEMAPHORE_SUBMIT_INFO, semaphore = d.present.timeline, value = pr.wait_value, stageMask = {.ALL_COMMANDS}}
		submit.waitSemaphoreInfoCount = 1
		submit.pWaitSemaphoreInfos = raw_data(waits[:])
	}
	if f.acquired {
		waits[0] = {sType = .SEMAPHORE_SUBMIT_INFO, semaphore = f.acquire, stageMask = {.ALL_COMMANDS}}
		signals[1] = {sType = .SEMAPHORE_SUBMIT_INFO, semaphore = d.swapchain.present[f.image_index], stageMask = {.ALL_COMMANDS}}
		signal_count = 2
		submit.waitSemaphoreInfoCount = 1
		submit.pWaitSemaphoreInfos = raw_data(waits[:])
	}
	submit.signalSemaphoreInfoCount = u32(signal_count)
	submit.pSignalSemaphoreInfos = raw_data(signals[:])
	sync.mutex_lock(&d.queue_lock)
	ok := vk_check(d, d.dvk.QueueSubmit2(d.queue, 1, &submit, 0), "vkQueueSubmit2")
	f.signal_value = d.timeline_value
	f.submitted_ns = present_now_ns()
	if ok && f.acquired {
		present := vk.PresentInfoKHR{
			sType = .PRESENT_INFO_KHR,
			waitSemaphoreCount = 1,
			pWaitSemaphores = &d.swapchain.present[f.image_index],
			swapchainCount = 1,
			pSwapchains = &d.swapchain.handle,
			pImageIndices = &f.image_index,
		}
		result := d.dvk.QueuePresentKHR(d.queue, &present)
		if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {d.swapchain.stale = true}
		else if result != .SUCCESS && !vk_surface_lost(d, result) {ok = vk_check(d, result, "vkQueuePresentKHR") && ok}
		if result == .SUCCESS || result == .SUBOPTIMAL_KHR {present_count_direct(d)}
	}
	sync.mutex_unlock(&d.queue_lock)
	if ok && f.paced {present_frame_end(d, generated, d.timeline_value, nil)}
	if ok && device_lose_take(d) {ok = vk_check(d, .ERROR_DEVICE_LOST, "vkQueueSubmit2")}
	f.acquired = false
	d.in_frame = false
	d.frame_number += 1
	d.slot = int(d.frame_number % MAX_FRAMES_IN_FLIGHT)
	return ok
}

frame_number :: proc(d: ^Device) -> u64 {return d.frame_number}

// ---------------------------------------------------------------- immediate transactions

// Begins a blocking command list for load-time work (uploads, BLAS builds,
// readback). nil, with the error of the device, while a frame is being
// recorded: immediate_end of it fails.
immediate_begin :: proc(d: ^Device) -> ^Command_List {
	if d.in_frame {set_error(d, "immediate_begin while a frame is being recorded: a load transaction runs between frame_end and frame_begin"); return nil}
	vk_table_take(d, table_copy(true, 0))
	d.dvk.ResetCommandBuffer(d.immediate.cmd, {})
	begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
	d.dvk.BeginCommandBuffer(d.immediate.cmd, &begin)
	vk_list_reset(&d.immediate)
	vk_zero_fresh(&d.immediate)
	d.immediate_open = true
	return &d.immediate
}

immediate_end :: proc(d: ^Device, cmd: ^Command_List) -> bool {
	if cmd != &d.immediate {
		if cmd != nil {set_error(d, "immediate_end of a list immediate_begin did not give")}
		return false
	}
	d.immediate_open = false
	if cmd.in_render_pass {cmd_end_render_pass(cmd)}
	vk_flush_barriers(cmd)
	d.dvk.EndCommandBuffer(cmd.cmd)
	info := vk.CommandBufferSubmitInfo{sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = cmd.cmd}
	submit := vk.SubmitInfo2{sType = .SUBMIT_INFO_2, commandBufferInfoCount = 1, pCommandBufferInfos = &info}
	if d.failure != .None {return false}
	d.dvk.ResetFences(d.handle, 1, &d.immediate_fence)
	sync.mutex_lock(&d.queue_lock)
	submitted := vk_check(d, d.dvk.QueueSubmit2(d.queue, 1, &submit, d.immediate_fence), "immediate submit")
	sync.mutex_unlock(&d.queue_lock)
	if !submitted {return false}
	if !vk_waited(d, d.dvk.WaitForFences(d.handle, 1, &d.immediate_fence, true, GPU_WAIT_LIMIT_NS), "immediate wait") {return false}
	return !device_lose_take(d) || vk_check(d, .ERROR_DEVICE_LOST, "immediate submit")
}

// ---------------------------------------------------------------- swapchain

swapchain_resize :: proc(d: ^Device, width, height: u32) {
	if !d.has_swapchain {return}
	if d.swapchain.desc.width != width || d.swapchain.desc.height != height {
		d.swapchain.desc.width = width
		d.swapchain.desc.height = height
		d.swapchain.stale = true
	}
}

// Takes effect when the next frame begins.
swapchain_set_vsync :: proc(d: ^Device, vsync: bool) {
	if !d.has_swapchain || d.swapchain.desc.vsync == vsync {return}
	d.swapchain.desc.vsync = vsync
	d.swapchain.stale = true
}

swapchain_texture :: proc(d: ^Device) -> Texture {
	if !d.has_swapchain || !d.in_frame {return 0}
	f := &d.frames[d.slot]
	if f.paced {return d.presenter.pairs[d.presenter.pair].textures[1] if d.presenter.pair >= 0 else 0}
	if !f.acquired {return 0}
	return d.swapchain.images[f.image_index]
}

swapchain_format :: proc(d: ^Device) -> Format {return d.swapchain.format}
swapchain_size :: proc(d: ^Device) -> (u32, u32) {return d.swapchain.extent.width, d.swapchain.extent.height}

@(private)
vk_destroy_swapchain :: proc(d: ^Device) {
	sc := &d.swapchain
	for texture in sc.images {
		if t, ok := pool_remove(&d.textures, base.Handle(texture)); ok {d.dvk.DestroyImageView(d.handle, t.view, nil)}
	}
	clear(&sc.images)
	for s in sc.present {d.dvk.DestroySemaphore(d.handle, s, nil)}
	clear(&sc.present)
	if sc.handle != 0 {d.dvk.DestroySwapchainKHR(d.handle, sc.handle, nil); sc.handle = 0}
}

@(private)
vk_recreate_swapchain :: proc(d: ^Device) -> bool {
	if !vk_idle(d) {return false}
	sc := &d.swapchain
	if sync.atomic_load(&sc.lost) && !vk_surface_remake(d) {return false}
	caps: vk.SurfaceCapabilitiesKHR
	asked := d.ivk.GetPhysicalDeviceSurfaceCapabilitiesKHR(d.physical, sc.surface, &caps)
	if vk_surface_lost(d, asked) || !vk_check(d, asked, "surface capabilities") {return false}
	extent := caps.currentExtent
	if extent.width == max(u32) {
		extent.width = clamp(sc.desc.width, caps.minImageExtent.width, caps.maxImageExtent.width)
		extent.height = clamp(sc.desc.height, caps.minImageExtent.height, caps.maxImageExtent.height)
	}
	if extent.width == 0 || extent.height == 0 {
		// Minimized: keep the old swapchain marked stale and skip frames.
		sc.stale = true
		return true
	}
	format_count: u32
	d.ivk.GetPhysicalDeviceSurfaceFormatsKHR(d.physical, sc.surface, &format_count, nil)
	formats := make([]vk.SurfaceFormatKHR, format_count, context.temp_allocator)
	d.ivk.GetPhysicalDeviceSurfaceFormatsKHR(d.physical, sc.surface, &format_count, raw_data(formats))
	// The renderer writes display-encoded 8-bit color; UNORM formats take it
	// as is, sRGB formats are accepted as a fallback (the blit decodes first).
	chosen: vk.SurfaceFormatKHR
	found := false
	for preference in ([]vk.Format{.B8G8R8A8_UNORM, .R8G8B8A8_UNORM, .B8G8R8A8_SRGB, .R8G8B8A8_SRGB}) {
		for f in formats {
			if f.format == preference && f.colorSpace == .SRGB_NONLINEAR {chosen = f; found = true; break}
		}
		if found {break}
	}
	if !found {set_error(d, "the surface offers no 8-bit BGRA/RGBA format"); return false}
	mode_count: u32
	d.ivk.GetPhysicalDeviceSurfacePresentModesKHR(d.physical, sc.surface, &mode_count, nil)
	modes := make([]vk.PresentModeKHR, mode_count, context.temp_allocator)
	d.ivk.GetPhysicalDeviceSurfacePresentModesKHR(d.physical, sc.surface, &mode_count, raw_data(modes))
	present_mode := vk.PresentModeKHR.FIFO
	if !sc.desc.vsync {
		for m in modes {if m == .MAILBOX {present_mode = .MAILBOX; break}}
		if present_mode == .FIFO {for m in modes {if m == .IMMEDIATE {present_mode = .IMMEDIATE}}}
	}
	image_count := max(caps.minImageCount + 1, 3)
	if caps.maxImageCount > 0 {image_count = min(image_count, caps.maxImageCount)}
	old := sc.handle
	info := vk.SwapchainCreateInfoKHR{
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = sc.surface,
		minImageCount = image_count,
		imageFormat = chosen.format,
		imageColorSpace = chosen.colorSpace,
		imageExtent = extent,
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT} + (caps.supportedUsageFlags & {.TRANSFER_DST, .TRANSFER_SRC}),
		imageSharingMode = .EXCLUSIVE,
		preTransform = caps.currentTransform,
		compositeAlpha = {.OPAQUE},
		presentMode = present_mode,
		clipped = true,
		oldSwapchain = old,
	}
	if !(.OPAQUE in caps.supportedCompositeAlpha) {
		for flag in vk.CompositeAlphaFlagKHR {if flag in caps.supportedCompositeAlpha {info.compositeAlpha = {flag}; break}}
	}
	new_handle: vk.SwapchainKHR
	made := d.dvk.CreateSwapchainKHR(d.handle, &info, nil, &new_handle)
	if vk_surface_lost(d, made) || !vk_check(d, made, "vkCreateSwapchainKHR") {return false}
	vk_destroy_swapchain(d)
	sc.handle = new_handle
	sc.vk_format = chosen.format
	#partial switch chosen.format {
	case .B8G8R8A8_UNORM: sc.format = .BGRA8_Unorm
	case .R8G8B8A8_UNORM: sc.format = .RGBA8_Unorm
	case .B8G8R8A8_SRGB:  sc.format = .BGRA8_Srgb
	case:                 sc.format = .RGBA8_Srgb
	}
	sc.color_space = chosen.colorSpace
	sc.extent = extent
	sc.copyable = .TRANSFER_DST in caps.supportedUsageFlags
	count: u32
	d.dvk.GetSwapchainImagesKHR(d.handle, sc.handle, &count, nil)
	images := make([]vk.Image, count, context.temp_allocator)
	d.dvk.GetSwapchainImagesKHR(d.handle, sc.handle, &count, raw_data(images))
	for image in images {
		if !device_room(d, &d.textures, "textures") {return false}
		view_info := vk.ImageViewCreateInfo{
			sType = .IMAGE_VIEW_CREATE_INFO, image = image, viewType = .D2, format = chosen.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		view: vk.ImageView
		d.dvk.CreateImageView(d.handle, &view_info, nil, &view)
		t := Vk_Texture{
			image = image, view = view, vk_format = chosen.format, aspect = {.COLOR}, swapchain = true,
			desc = {width = extent.width, height = extent.height, mip_levels = 1, format = sc.format, usage = {.Color_Target, .Transfer_Dst, .Transfer_Src}},
		}
		append(&sc.images, Texture(pool_add(&d.textures, t)))
		semaphore_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
		semaphore: vk.Semaphore
		d.dvk.CreateSemaphore(d.handle, &semaphore_info, nil, &semaphore)
		append(&sc.present, semaphore)
	}
	sc.stale = false
	return true
}

// ---------------------------------------------------------------- paced presentation (present.odin)

@(private)
swapchain_stale :: proc(d: ^Device) -> bool {return d.swapchain.stale || sync.atomic_load(&d.swapchain.lost)}

// Makes the swapchain again when it went stale or lost its surface; the presenter does not run.
@(private)
swapchain_refresh :: proc(d: ^Device) -> bool {
	if !swapchain_stale(d) {return true}
	return vk_recreate_swapchain(d) && !d.swapchain.stale
}

@(private)
present_backend_start :: proc(d: ^Device) -> bool {
	if !d.swapchain.copyable {set_error(d, "the swapchain images take no copies (TRANSFER_DST): frames cannot be paced"); return false}
	pv := &d.present
	pv^ = {}
	pool_info := vk.CommandPoolCreateInfo{sType = .COMMAND_POOL_CREATE_INFO, flags = {.RESET_COMMAND_BUFFER}, queueFamilyIndex = d.queue_family}
	if !vk_check(d, d.dvk.CreateCommandPool(d.handle, &pool_info, nil, &pv.pool), "present command pool") {return false}
	alloc := vk.CommandBufferAllocateInfo{sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = pv.pool, level = .PRIMARY, commandBufferCount = PRESENT_SLOTS}
	if !vk_check(d, d.dvk.AllocateCommandBuffers(d.handle, &alloc, &pv.cmds[0]), "present command buffers") {present_backend_stop(d); return false}
	binary := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	for &semaphore in pv.acquire {
		if !vk_check(d, d.dvk.CreateSemaphore(d.handle, &binary, nil, &semaphore), "present acquire semaphore") {present_backend_stop(d); return false}
	}
	timeline_type := vk.SemaphoreTypeCreateInfo{sType = .SEMAPHORE_TYPE_CREATE_INFO, semaphoreType = .TIMELINE}
	timeline := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO, pNext = &timeline_type}
	if !vk_check(d, d.dvk.CreateSemaphore(d.handle, &timeline, nil, &pv.timeline), "present timeline") {present_backend_stop(d); return false}
	if !present_backend_refresh(d) {present_backend_stop(d); return false}
	return true
}

// What the thread copies from and into: the swapchain, its images and the pairs.
@(private)
present_backend_refresh :: proc(d: ^Device) -> bool {
	pv := &d.present
	sc := &d.swapchain
	if len(sc.images) > VK_PRESENT_IMAGES {set_error(d, "the swapchain has %d images; the presenter takes %d", len(sc.images), VK_PRESENT_IMAGES); return false}
	pv.swapchain, pv.extent = sc.handle, sc.extent
	for texture, i in sc.images {
		t := pool_get(&d.textures, base.Handle(texture))
		if t == nil {return false}
		pv.images[i], pv.presents[i] = t.image, sc.present[i]
	}
	for &pair, i in d.presenter.pairs {
		for texture, j in pair.textures {
			t := pool_get(&d.textures, base.Handle(texture))
			if t == nil {return false}
			pv.pairs[i][j] = t.image
		}
	}
	return true
}

@(private)
present_backend_stop :: proc(d: ^Device) {
	pv := &d.present
	if pv.timeline != 0 && pv.value > 0 {
		value := pv.value
		info := vk.SemaphoreWaitInfo{sType = .SEMAPHORE_WAIT_INFO, semaphoreCount = 1, pSemaphores = &pv.timeline, pValues = &value}
		vk_waited(d, d.dvk.WaitSemaphores(d.handle, &info, GPU_WAIT_LIMIT_NS), "present timeline")
	}
	if d.waited_out {pv^ = {}; return}
	for semaphore in pv.acquire {if semaphore != 0 {d.dvk.DestroySemaphore(d.handle, semaphore, nil)}}
	if pv.timeline != 0 {d.dvk.DestroySemaphore(d.handle, pv.timeline, nil)}
	if pv.pool != 0 {d.dvk.DestroyCommandPool(d.handle, pv.pool, nil)}
	pv^ = {}
}

@(private)
present_gpu_wait :: proc(d: ^Device, job: ^Present_Job) -> bool {return vk_wait_timeline(d, job.value)}

// Copies image (0 the generated one, 1 the real one) of the pair of a job
// into an image of the swapchain and presents it, from the thread of the
// presenter. Returns the value of the present timeline the copy signals.
@(private)
present_image :: proc(d: ^Device, job: ^Present_Job, image: int) -> (u64, bool) {
	pv := &d.present
	if d.failure != .None {return 0, false}
	slot := pv.next % PRESENT_SLOTS
	pv.next += 1
	if pv.values[slot] > 0 {
		value := pv.values[slot]
		info := vk.SemaphoreWaitInfo{sType = .SEMAPHORE_WAIT_INFO, semaphoreCount = 1, pSemaphores = &pv.timeline, pValues = &value}
		if !vk_waited(d, d.dvk.WaitSemaphores(d.handle, &info, GPU_WAIT_LIMIT_NS), "present timeline") {return 0, false}
	}
	index: u32
	result := d.dvk.AcquireNextImageKHR(d.handle, pv.swapchain, GPU_WAIT_LIMIT_NS, pv.acquire[slot], 0, &index)
	if result == .ERROR_OUT_OF_DATE_KHR || vk_surface_lost(d, result) {sync.atomic_store(&d.presenter.out_of_date, true); return 0, false}
	if result == .TIMEOUT || result == .NOT_READY {return 0, false}
	if result != .SUCCESS && result != .SUBOPTIMAL_KHR {vk_check(d, result, "vkAcquireNextImageKHR"); return 0, false}
	if result == .SUBOPTIMAL_KHR {sync.atomic_store(&d.presenter.out_of_date, true)}
	cmd := pv.cmds[slot]
	d.dvk.ResetCommandBuffer(cmd, {})
	begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
	d.dvk.BeginCommandBuffer(cmd, &begin)
	color := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1}
	to_copy := vk.ImageMemoryBarrier2{
		sType = .IMAGE_MEMORY_BARRIER_2, srcStageMask = {.COPY}, dstStageMask = {.COPY}, dstAccessMask = {.TRANSFER_WRITE},
		oldLayout = .UNDEFINED, newLayout = .TRANSFER_DST_OPTIMAL, srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = pv.images[index], subresourceRange = color,
	}
	dependency := vk.DependencyInfo{sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = 1, pImageMemoryBarriers = &to_copy}
	d.dvk.CmdPipelineBarrier2(cmd, &dependency)
	layers := vk.ImageSubresourceLayers{aspectMask = {.COLOR}, layerCount = 1}
	region := vk.ImageCopy{srcSubresource = layers, dstSubresource = layers, extent = {pv.extent.width, pv.extent.height, 1}}
	d.dvk.CmdCopyImage(cmd, pv.pairs[job.pair][image], .TRANSFER_SRC_OPTIMAL, pv.images[index], .TRANSFER_DST_OPTIMAL, 1, &region)
	to_present := vk.ImageMemoryBarrier2{
		sType = .IMAGE_MEMORY_BARRIER_2, srcStageMask = {.COPY}, srcAccessMask = {.TRANSFER_WRITE}, dstStageMask = {.ALL_COMMANDS},
		oldLayout = .TRANSFER_DST_OPTIMAL, newLayout = .PRESENT_SRC_KHR, srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = pv.images[index], subresourceRange = color,
	}
	dependency.pImageMemoryBarriers = &to_present
	d.dvk.CmdPipelineBarrier2(cmd, &dependency)
	d.dvk.EndCommandBuffer(cmd)
	pv.value += 1
	waits := [2]vk.SemaphoreSubmitInfo{
		{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = pv.acquire[slot], stageMask = {.COPY}},
		// Reached already, as the thread waited for it: it carries the writes of the frame to the copy.
		{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = d.timeline, value = job.value, stageMask = {.COPY}},
	}
	signals := [2]vk.SemaphoreSubmitInfo{
		{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = pv.presents[index], stageMask = {.ALL_COMMANDS}},
		{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = pv.timeline, value = pv.value, stageMask = {.ALL_COMMANDS}},
	}
	cmd_info := vk.CommandBufferSubmitInfo{sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = cmd}
	submit := vk.SubmitInfo2{
		sType = .SUBMIT_INFO_2, waitSemaphoreInfoCount = 2, pWaitSemaphoreInfos = &waits[0],
		commandBufferInfoCount = 1, pCommandBufferInfos = &cmd_info, signalSemaphoreInfoCount = 2, pSignalSemaphoreInfos = &signals[0],
	}
	present := vk.PresentInfoKHR{
		sType = .PRESENT_INFO_KHR, waitSemaphoreCount = 1, pWaitSemaphores = &pv.presents[index],
		swapchainCount = 1, pSwapchains = &pv.swapchain, pImageIndices = &index,
	}
	sync.mutex_lock(&d.queue_lock)
	submitted := vk_check(d, d.dvk.QueueSubmit2(d.queue, 1, &submit, 0), "present copy")
	shown: vk.Result = .ERROR_UNKNOWN
	if submitted {shown = d.dvk.QueuePresentKHR(d.queue, &present)}
	sync.mutex_unlock(&d.queue_lock)
	if !submitted {return 0, false}
	pv.values[slot] = pv.value
	if shown == .ERROR_OUT_OF_DATE_KHR || shown == .SUBOPTIMAL_KHR || vk_surface_lost(d, shown) {sync.atomic_store(&d.presenter.out_of_date, true)}
	else if shown != .SUCCESS {vk_check(d, shown, "vkQueuePresentKHR")}
	return pv.value, shown == .SUCCESS || shown == .SUBOPTIMAL_KHR
}
