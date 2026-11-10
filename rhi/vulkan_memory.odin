#+build linux, windows
package rhi

import "base:runtime"
import vk "vendor:vulkan"

// Buffers and textures share blocks of device memory instead of taking a
// vkAllocateMemory each: a driver only has to give maxMemoryAllocationCount
// of them at once, fewer than the resources a device holds. Each memory type
// has its blocks, whose ranges an Arena keeps. A resource of more than half a
// block takes memory of its own, and so does one the driver prefers alone
// while less than half of the allocations it gives are taken.
VK_MEMORY_BLOCK_BYTES :: u64(64) << 20
// A block is at most one part in this many of its heap, so a small heap (the
// 256 MiB a card without resizable BAR lets the CPU see) holds several.
VK_MEMORY_HEAP_PARTS :: 8

// Buffers and images take different blocks on a device that wants room
// between them in one allocation (bufferImageGranularity above 1).
@(private)
Vk_Memory_Class :: enum u8 {Buffer, Image}

// Whether the driver wants the resource in an allocation of its own.
@(private)
Vk_Memory_Alone :: enum u8 {No, Preferred, Required}

// The memory of a resource: a range of a block, or an allocation of its own.
@(private)
Vk_Memory :: struct {
	handle: vk.DeviceMemory,
	offset: u64,
	size:   u64,
	block:  u32,
	pool:   u8, // the pool of the block + 1; 0: an allocation of its own
}

@(private)
Vk_Memory_Request :: struct {
	size, align: u64,
	types:       []u32, // memory types that take it, the best first
	class:       Vk_Memory_Class,
	alone:       Vk_Memory_Alone,
	mapped:      bool, // the CPU reads or writes it
}

// Count: the driver gives no more allocations. Tables: the allocator of the
// device has no memory to track one more.
@(private)
Vk_Memory_Problem :: enum u8 {None, Invalid, Count, Memory, Tables}

// Where device memory comes from: the driver, or a table in a test.
@(private)
Vk_Memory_Source :: struct {
	user:     rawptr,
	allocate: proc(user: rawptr, type: u32, size: u64, alone: bool) -> (vk.DeviceMemory, vk.Result),
	// The whole allocation, mapped until it is released.
	view:     proc(user: rawptr, memory: vk.DeviceMemory) -> (rawptr, vk.Result),
	release:  proc(user: rawptr, memory: vk.DeviceMemory),
}

@(private)
Vk_Memory_Block :: struct {
	handle: vk.DeviceMemory,
	mapped: rawptr, // nil until a resource the CPU reads or writes takes a range of it
}

@(private)
Vk_Memory_Pool :: struct {
	arena:  Arena,
	blocks: [dynamic]Vk_Memory_Block, // of each block of the arena
}

@(private)
Vk_Memory_Pools :: struct {
	pools:       [vk.MAX_MEMORY_TYPES * len(Vk_Memory_Class)]Vk_Memory_Pool,
	heap_bytes:  [vk.MAX_MEMORY_TYPES]u64, // of the heap of each memory type
	block_bytes: [vk.MAX_MEMORY_TYPES]u64, // of a block of each memory type
	count:       u32, // allocations of the driver alive: blocks and those of one resource
	limit:       u32, // maxMemoryAllocationCount
	apart:       bool, // buffers and images take different blocks
	alone_bytes: u64,  // of the allocations of one resource
}

@(private)
vk_memory_init :: proc(m: ^Vk_Memory_Pools, properties: ^vk.PhysicalDeviceMemoryProperties, limit: u32, granularity: u64, allocator: runtime.Allocator) {
	m^ = {limit = limit, apart = granularity > 1}
	for type in 0 ..< min(properties.memoryTypeCount, vk.MAX_MEMORY_TYPES) {
		heap := properties.memoryTypes[type].heapIndex
		if heap >= vk.MAX_MEMORY_HEAPS {continue}
		m.heap_bytes[type] = u64(properties.memoryHeaps[heap].size)
		m.block_bytes[type] = min(VK_MEMORY_BLOCK_BYTES, m.heap_bytes[type] / VK_MEMORY_HEAP_PARTS)
	}
	for &pool in m.pools {
		pool.arena.allocator = allocator
		pool.blocks = make([dynamic]Vk_Memory_Block, allocator)
	}
}

// The memory of a request, from the first of its types that has it, and where
// the CPU sees it when the request asks. said: what the driver answered last.
@(private)
vk_memory_take :: proc(m: ^Vk_Memory_Pools, source: Vk_Memory_Source, request: Vk_Memory_Request) -> (memory: Vk_Memory, mapped: rawptr, problem: Vk_Memory_Problem, said: vk.Result) {
	if request.size == 0 || request.align == 0 || request.align & (request.align - 1) != 0 || len(request.types) == 0 {
		return {}, nil, .Invalid, .SUCCESS
	}
	memory, mapped, problem, said = vk_memory_take_once(m, source, request)
	// The empty blocks kept for the next resource are what is left to give up.
	if (problem == .Count || problem == .Memory) && vk_memory_trim(m, source) {
		memory, mapped, problem, said = vk_memory_take_once(m, source, request)
	}
	return
}

@(private = "file")
vk_memory_take_once :: proc(m: ^Vk_Memory_Pools, source: Vk_Memory_Source, request: Vk_Memory_Request) -> (memory: Vk_Memory, mapped: rawptr, problem: Vk_Memory_Problem, said: vk.Result) {
	said = .ERROR_OUT_OF_DEVICE_MEMORY
	counted := false
	for type in request.types {
		// More than its heap holds is not a request the device may get.
		if type >= vk.MAX_MEMORY_TYPES || request.size > m.heap_bytes[type] {continue}
		alone := request.alone == .Required || request.size > m.block_bytes[type] / 2 || request.alone == .Preferred && m.count < m.limit / 2
		ok, tables: bool
		if alone {
			if memory, mapped, ok = vk_memory_take_alone(m, source, request, type, &said, &counted); ok {return memory, mapped, .None, .SUCCESS}
			if request.alone == .Required {continue}
		}
		if memory, mapped, ok, tables = vk_memory_take_range(m, source, request, type, &said, &counted); ok {return memory, mapped, .None, .SUCCESS}
		if tables {return {}, nil, .Tables, said}
		// A block the driver does not have may still be memory for this one resource.
		if !alone {
			if memory, mapped, ok = vk_memory_take_alone(m, source, request, type, &said, &counted); ok {return memory, mapped, .None, .SUCCESS}
		}
	}
	return {}, nil, .Count if counted else .Memory, said
}

@(private = "file")
vk_memory_take_alone :: proc(m: ^Vk_Memory_Pools, source: Vk_Memory_Source, request: Vk_Memory_Request, type: u32, said: ^vk.Result, counted: ^bool) -> (memory: Vk_Memory, mapped: rawptr, ok: bool) {
	if m.count >= m.limit {counted^ = true; return}
	handle, result := source.allocate(source.user, type, request.size, true)
	if result != .SUCCESS {said^ = result; return}
	if request.mapped {
		if mapped, result = source.view(source.user, handle); result != .SUCCESS {
			source.release(source.user, handle)
			said^ = result
			return {}, nil, false
		}
	}
	m.count += 1
	m.alone_bytes += request.size
	return {handle = handle, size = request.size}, mapped, true
}

@(private = "file")
vk_memory_take_range :: proc(m: ^Vk_Memory_Pools, source: Vk_Memory_Source, request: Vk_Memory_Request, type: u32, said: ^vk.Result, counted: ^bool) -> (memory: Vk_Memory, mapped: rawptr, ok, tables: bool) {
	index := int(type) * len(Vk_Memory_Class) + (int(request.class) if m.apart else 0)
	pool := &m.pools[index]
	block, offset, found := arena_take(&pool.arena, request.size, request.align)
	if !found {
		bytes := m.block_bytes[type]
		if request.size > bytes {return}
		if m.count >= m.limit {counted^ = true; return}
		handle, result := source.allocate(source.user, type, bytes, false)
		if result != .SUCCESS {said^ = result; return}
		at, added := arena_add(&pool.arena, bytes)
		if added && len(pool.blocks) <= at && resize(&pool.blocks, at + 1) != nil {
			arena_drop(&pool.arena, at)
			added = false
		}
		if !added {
			source.release(source.user, handle)
			return {}, nil, false, true
		}
		pool.blocks[at] = {handle = handle}
		m.count += 1
		block, offset, found = arena_take(&pool.arena, request.size, request.align)
		// A whole block has the room: what is missing is memory to track the range.
		if !found {
			vk_memory_drop(m, source, pool, at)
			return {}, nil, false, true
		}
	}
	b := &pool.blocks[block]
	if request.mapped {
		if b.mapped == nil {
			seen, result := source.view(source.user, b.handle)
			if result != .SUCCESS {
				said^ = result
				vk_memory_give(m, source, {handle = b.handle, offset = offset, size = request.size, block = u32(block), pool = u8(index + 1)})
				return
			}
			b.mapped = seen
		}
		mapped = rawptr(uintptr(b.mapped) + uintptr(offset))
	}
	return {handle = b.handle, offset = offset, size = request.size, block = u32(block), pool = u8(index + 1)}, mapped, true, false
}

// Whether the driver gives one allocation more, for memory made outside the
// pools (what another process imports) that vk_memory_adopt then counts.
@(private)
vk_memory_room :: proc "contextless" (m: ^Vk_Memory_Pools) -> bool {return m.count < m.limit}

@(private)
vk_memory_adopt :: proc "contextless" (m: ^Vk_Memory_Pools, handle: vk.DeviceMemory, size: u64) -> Vk_Memory {
	m.count += 1
	m.alone_bytes += size
	return {handle = handle, size = size}
}

// Gives back the memory of a resource already destroyed. One empty block of a
// pool stays for the next resource: one made and destroyed over and over (a
// readback buffer) would otherwise take a block and free it each time.
@(private)
vk_memory_give :: proc(m: ^Vk_Memory_Pools, source: Vk_Memory_Source, memory: Vk_Memory) {
	if memory.handle == 0 {return}
	if memory.pool == 0 {
		source.release(source.user, memory.handle)
		m.count -= min(m.count, 1)
		m.alone_bytes -= min(m.alone_bytes, memory.size)
		return
	}
	if int(memory.pool) > len(m.pools) {return}
	pool := &m.pools[memory.pool - 1]
	block := int(memory.block)
	if block >= len(pool.blocks) || pool.blocks[block].handle != memory.handle {return}
	if !arena_give(&pool.arena, block, memory.offset, memory.size) {return}
	for b, i in pool.arena.blocks {
		if i != block && b.size != 0 && b.used == 0 {
			vk_memory_drop(m, source, pool, block)
			return
		}
	}
}

@(private = "file")
vk_memory_drop :: proc(m: ^Vk_Memory_Pools, source: Vk_Memory_Source, pool: ^Vk_Memory_Pool, block: int) {
	source.release(source.user, pool.blocks[block].handle)
	pool.blocks[block] = {}
	arena_drop(&pool.arena, block)
	m.count -= min(m.count, 1)
}

// Lets the empty blocks go. Whether there was one.
@(private)
vk_memory_trim :: proc(m: ^Vk_Memory_Pools, source: Vk_Memory_Source) -> (trimmed: bool) {
	for &pool in m.pools {
		for b, i in pool.arena.blocks {
			if b.size == 0 || b.used != 0 {continue}
			vk_memory_drop(m, source, &pool, i)
			trimmed = true
		}
	}
	return
}

// The bytes of device memory the pools hold and what resources take of them.
@(private)
vk_memory_bytes :: proc "contextless" (m: ^Vk_Memory_Pools) -> (held, used: u64) {
	held, used = m.alone_bytes, m.alone_bytes
	for &pool in m.pools {
		block_held, block_used := arena_bytes(&pool.arena)
		held += block_held
		used += block_used
	}
	return
}

// Releases the blocks, those of resources never destroyed too, when release is
// set, and the tables.
@(private)
vk_memory_destroy :: proc(m: ^Vk_Memory_Pools, source: Vk_Memory_Source, release: bool) {
	for &pool in m.pools {
		for b in pool.blocks {if release && b.handle != 0 {source.release(source.user, b.handle)}}
		delete(pool.blocks)
		arena_destroy(&pool.arena)
	}
	m^ = {}
}

// ---------------------------------------------------------------- device

@(private = "file")
Vk_Memory_Ask :: struct {
	d:       ^Device,
	buffer:  vk.Buffer,
	image:   vk.Image,
	address: bool, // shaders take the address of the buffer
}

@(private = "file")
vk_memory_source :: proc "contextless" (ask: ^Vk_Memory_Ask) -> Vk_Memory_Source {
	return {
		user = ask,
		allocate = proc(user: rawptr, type: u32, size: u64, alone: bool) -> (memory: vk.DeviceMemory, result: vk.Result) {
			ask := cast(^Vk_Memory_Ask)user
			d := ask.d
			info := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, allocationSize = vk.DeviceSize(size), memoryTypeIndex = type}
			// A block may come to hold a buffer whose address shaders take.
			flags := vk.MemoryAllocateFlagsInfo{sType = .MEMORY_ALLOCATE_FLAGS_INFO, flags = {.DEVICE_ADDRESS}}
			if (ask.address if alone else d.info.features.ray_query) {info.pNext = &flags}
			dedicated := vk.MemoryDedicatedAllocateInfo{sType = .MEMORY_DEDICATED_ALLOCATE_INFO, pNext = info.pNext, buffer = ask.buffer, image = ask.image}
			if alone {info.pNext = &dedicated}
			result = d.dvk.AllocateMemory(d.handle, &info, nil, &memory)
			return
		},
		view = proc(user: rawptr, memory: vk.DeviceMemory) -> (mapped: rawptr, result: vk.Result) {
			d := (cast(^Vk_Memory_Ask)user).d
			result = d.dvk.MapMemory(d.handle, memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &mapped)
			return
		},
		release = proc(user: rawptr, memory: vk.DeviceMemory) {
			d := (cast(^Vk_Memory_Ask)user).d
			d.dvk.FreeMemory(d.handle, memory, nil)
		},
	}
}

// Takes the memory of a buffer or of an image and binds it. mapped: where the
// CPU reads and writes it, for every kind but GPU.
@(private)
vk_memory_bind :: proc(d: ^Device, buffer: vk.Buffer, image: vk.Image, kind: Memory, address: bool, name: string) -> (memory: Vk_Memory, mapped: rawptr, ok: bool) {
	wants := vk.MemoryDedicatedRequirements{sType = .MEMORY_DEDICATED_REQUIREMENTS}
	asked := vk.MemoryRequirements2{sType = .MEMORY_REQUIREMENTS_2, pNext = &wants}
	if image != 0 {
		info := vk.ImageMemoryRequirementsInfo2{sType = .IMAGE_MEMORY_REQUIREMENTS_INFO_2, image = image}
		d.dvk.GetImageMemoryRequirements2(d.handle, &info, &asked)
	} else {
		info := vk.BufferMemoryRequirementsInfo2{sType = .BUFFER_MEMORY_REQUIREMENTS_INFO_2, buffer = buffer}
		d.dvk.GetBufferMemoryRequirements2(d.handle, &info, &asked)
	}
	requirements := asked.memoryRequirements
	required, preferred: vk.MemoryPropertyFlags
	switch kind {
	case .GPU:      required = {.DEVICE_LOCAL}
	case .Upload:   required = {.HOST_VISIBLE, .HOST_COHERENT}; preferred = {.DEVICE_LOCAL}
	case .Readback: required = {.HOST_VISIBLE, .HOST_COHERENT}; preferred = {.HOST_CACHED}
	case .Staging:  required = {.HOST_VISIBLE, .HOST_COHERENT}
	}
	types, count := vk_memory_candidates(d, requirements.memoryTypeBits, required, preferred, {.DEVICE_LOCAL} if kind == .Staging else {})
	if count == 0 && kind == .GPU {types, count = vk_memory_candidates(d, requirements.memoryTypeBits, {}, {})}
	if count == 0 {set_error(d, "%s: no Vulkan memory type for %v", name, kind); return}
	ask := Vk_Memory_Ask{d = d, buffer = buffer, image = image, address = address}
	source := vk_memory_source(&ask)
	request := Vk_Memory_Request{
		size = u64(requirements.size), align = u64(requirements.alignment), types = types[:count],
		class = .Image if image != 0 else .Buffer, mapped = kind != .GPU,
	}
	switch {
	case bool(wants.requiresDedicatedAllocation): request.alone = .Required
	case bool(wants.prefersDedicatedAllocation):  request.alone = .Preferred
	}
	problem: Vk_Memory_Problem
	said: vk.Result
	memory, mapped, problem, said = vk_memory_take(&d.memory, source, request)
	held, used := vk_memory_bytes(&d.memory)
	switch problem {
	case .None:
	case .Invalid:
		set_error(d, "%s: %d bytes aligned to %d is no memory the driver can ask for", name, request.size, request.align)
	case .Count:
		set_error(d, "%s: %v memory of %d bytes needs one more allocation of the driver, which gives %d at once (maxMemoryAllocationCount) and all are taken, holding %d bytes of which %d are in use: destroy resources, of which those of more than %d bytes take one each", name, kind, request.size, d.memory.limit, held, used, VK_MEMORY_BLOCK_BYTES / 2)
	case .Memory:
		set_error(d, "%s: no %v memory for %d bytes: vkAllocateMemory said %v, with %d bytes held in %d of the %d allocations the driver gives, %d of them in use", name, kind, request.size, said, held, d.memory.count, d.memory.limit, used)
	case .Tables:
		set_error(d, "%s: out of memory for the tables of the device memory", name)
	}
	if problem != .None {return {}, nil, false}
	result: vk.Result
	if image != 0 {
		result = d.dvk.BindImageMemory(d.handle, image, memory.handle, vk.DeviceSize(memory.offset))
	} else {
		result = d.dvk.BindBufferMemory(d.handle, buffer, memory.handle, vk.DeviceSize(memory.offset))
	}
	if !vk_check(d, result, "binding memory") {
		vk_memory_give(&d.memory, source, memory)
		return {}, nil, false
	}
	return memory, mapped, true
}

// Gives back the memory of a buffer or of an image already destroyed.
@(private)
vk_memory_unbind :: proc(d: ^Device, memory: Vk_Memory) {
	ask := Vk_Memory_Ask{d = d}
	vk_memory_give(&d.memory, vk_memory_source(&ask), memory)
}

@(private)
vk_memory_shutdown :: proc(d: ^Device, release: bool) {
	ask := Vk_Memory_Ask{d = d}
	vk_memory_destroy(&d.memory, vk_memory_source(&ask), release)
}
