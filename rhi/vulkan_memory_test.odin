#+build linux, windows
package rhi

import "base:runtime"
import "core:math/rand"
import "core:testing"
import vk "vendor:vulkan"

// A driver that is a table: what each allocation holds, and how many bytes
// each memory type has left to give.
@(private = "file")
Fake_Driver :: struct {
	bytes: [dynamic]u64, // of each allocation by its handle - 1; 0: released
	types: [dynamic]u32,
	alone: [dynamic]bool,
	room:  [FAKE_TYPES]u64,
	alive: int,
	most:  int, // alive at once
	blind: bool, // no allocation can be mapped
}

@(private = "file") FAKE_TYPES :: 3
@(private = "file") FAKE_SMALL_HEAP :: u64(256) << 20
// Type 1 is of a heap that holds less than VK_MEMORY_HEAP_PARTS blocks of VK_MEMORY_BLOCK_BYTES.
@(private = "file") FAKE_SMALL_TYPE :: 1

@(private = "file")
fake_source :: proc(driver: ^Fake_Driver) -> Vk_Memory_Source {
	return {
		user = driver,
		allocate = proc(user: rawptr, type: u32, size: u64, alone: bool) -> (vk.DeviceMemory, vk.Result) {
			driver := cast(^Fake_Driver)user
			if size > driver.room[type] {return 0, .ERROR_OUT_OF_DEVICE_MEMORY}
			driver.room[type] -= size
			append(&driver.bytes, size)
			append(&driver.types, type)
			append(&driver.alone, alone)
			driver.alive += 1
			driver.most = max(driver.most, driver.alive)
			return vk.DeviceMemory(len(driver.bytes)), .SUCCESS
		},
		view = proc(user: rawptr, memory: vk.DeviceMemory) -> (rawptr, vk.Result) {
			if (cast(^Fake_Driver)user).blind {return nil, .ERROR_MEMORY_MAP_FAILED}
			return fake_view(memory), .SUCCESS
		},
		release = proc(user: rawptr, memory: vk.DeviceMemory) {
			driver := cast(^Fake_Driver)user
			at := int(memory) - 1
			if at < 0 || at >= len(driver.bytes) || driver.bytes[at] == 0 {
				driver.alive = min(int)
				return
			}
			driver.room[driver.types[at]] += driver.bytes[at]
			driver.bytes[at] = 0
			driver.alive -= 1
		},
	}
}

// Where the CPU would see an allocation: an address no test reads.
@(private = "file")
fake_view :: proc "contextless" (memory: vk.DeviceMemory) -> rawptr {return rawptr(uintptr(memory) << 40)}

@(private = "file")
fake_destroy :: proc(driver: ^Fake_Driver) {
	delete(driver.bytes)
	delete(driver.types)
	delete(driver.alone)
}

// Pools over three memory types: two of a large heap and FAKE_SMALL_TYPE of a small one.
@(private = "file")
fake_pools :: proc(m: ^Vk_Memory_Pools, driver: ^Fake_Driver, limit: u32, granularity: u64, allocator := context.allocator) {
	properties := vk.PhysicalDeviceMemoryProperties{memoryTypeCount = FAKE_TYPES, memoryHeapCount = 2}
	properties.memoryHeaps[0].size = vk.DeviceSize(u64(8) << 30)
	properties.memoryHeaps[1].size = vk.DeviceSize(FAKE_SMALL_HEAP)
	properties.memoryTypes[FAKE_SMALL_TYPE].heapIndex = 1
	for &room, type in driver.room {room = u64(properties.memoryHeaps[properties.memoryTypes[type].heapIndex].size)}
	vk_memory_init(m, &properties, limit, granularity, allocator)
}

// Many resources take ranges of one allocation of the driver, each on its
// alignment and apart from the others, and the CPU sees a range where its
// block is mapped plus its offset. A resource of more than half a block, one
// the driver requires alone, and one it prefers alone while allocations are
// plentiful, take an allocation of their own.
@(test)
vk_memory_shares_blocks_and_takes_alone_what_is_large_or_asked :: proc(t: ^testing.T) {
	driver: Fake_Driver
	defer fake_destroy(&driver)
	m: Vk_Memory_Pools
	fake_pools(&m, &driver, 8, 1)
	source := fake_source(&driver)
	defer vk_memory_destroy(&m, source, true)
	testing.expect(t, m.block_bytes[0] == VK_MEMORY_BLOCK_BYTES && m.block_bytes[FAKE_SMALL_TYPE] == FAKE_SMALL_HEAP / VK_MEMORY_HEAP_PARTS, "a block is a part of a small heap")

	taken: [64]Vk_Memory
	ranges: [64]Test_Range
	for &memory, i in taken {
		align := u64(1) << uint(i % 9)
		request := Vk_Memory_Request{size = u64(1000 + 37 * i), align = align, types = {0}, mapped = i % 2 == 0}
		mapped: rawptr
		problem: Vk_Memory_Problem
		memory, mapped, problem, _ = vk_memory_take(&m, source, request)
		ranges[i] = {int(memory.block), memory.offset, memory.size}
		if !testing.expectf(t, problem == .None && memory.pool != 0 && test_range_apart(ranges[:i], ranges[i], VK_MEMORY_BLOCK_BYTES, align), "resource %d: %v, %v", i, problem, memory) {return}
		seen := rawptr(uintptr(fake_view(memory.handle)) + uintptr(memory.offset)) if request.mapped else nil
		testing.expectf(t, mapped == seen, "resource %d is seen at %p, not at %p", i, mapped, seen)
	}
	testing.expect(t, driver.alive == 1 && m.count == 1, "the resources share one allocation")
	held, used := vk_memory_bytes(&m)
	testing.expect(t, held == VK_MEMORY_BLOCK_BYTES && used > 0 && used < held)

	Case :: struct {size: u64, alone: Vk_Memory_Alone, count: u32, own: bool}
	half := VK_MEMORY_BLOCK_BYTES / 2
	cases := [?]Case {
		{half, .No, 1, false},
		{half + 1, .No, 1, true},
		{4096, .Required, 1, true},
		{4096, .Preferred, 3, true},
		// Half of the allocations the driver gives are taken: the rest are for blocks.
		{4096, .Preferred, 4, false},
		{4096, .Required, 4, true},
	}
	for c in cases {
		m.count = c.count
		memory, _, problem, _ := vk_memory_take(&m, source, {size = c.size, align = 256, types = {0}, alone = c.alone})
		testing.expectf(t, problem == .None && (memory.pool == 0) == c.own, "%v: %v, %v", c, problem, memory)
		if memory.pool == 0 {testing.expectf(t, driver.alone[int(memory.handle) - 1] && driver.bytes[int(memory.handle) - 1] == c.size, "%v: the driver gave it no memory of its size and its own", c)}
		vk_memory_give(&m, source, memory)
	}
	m.count = 1
	for memory in taken {vk_memory_give(&m, source, memory)}
	held, used = vk_memory_bytes(&m)
	testing.expect(t, used == 0 && held == VK_MEMORY_BLOCK_BYTES && driver.alive == 1, "one empty block stays for the next resource")
	testing.expect(t, vk_memory_trim(&m, source) && driver.alive == 0 && m.count == 0, "and goes when it is asked to")
}

// Buffers and images share a block only on a device that asks no room between
// them; memory types never share one.
@(test)
vk_memory_keeps_buffers_and_images_apart_when_the_device_asks :: proc(t: ^testing.T) {
	for granularity in ([?]u64{1, 4096}) {
		driver: Fake_Driver
		defer fake_destroy(&driver)
		m: Vk_Memory_Pools
		fake_pools(&m, &driver, 64, granularity)
		source := fake_source(&driver)
		defer vk_memory_destroy(&m, source, true)
		buffer, _, _, _ := vk_memory_take(&m, source, {size = 4096, align = 16, types = {0}, class = .Buffer})
		image, _, _, _ := vk_memory_take(&m, source, {size = 4096, align = 16, types = {0}, class = .Image})
		other, _, _, _ := vk_memory_take(&m, source, {size = 4096, align = 16, types = {2}, class = .Buffer})
		if !testing.expect(t, buffer.handle != 0 && image.handle != 0 && other.handle != 0) {return}
		testing.expectf(t, (buffer.handle == image.handle) == (granularity <= 1), "granularity %d: a buffer in %v and an image in %v", granularity, buffer, image)
		testing.expect(t, other.handle != buffer.handle && driver.types[int(other.handle) - 1] == 2)
	}
}

// The driver is never asked for more allocations than it gives at once. With
// all of them taken a resource still takes a range of a block that has room,
// an empty block kept for later gives its allocation up, and what needs one
// more is refused, saying it was the count.
@(test)
vk_memory_never_passes_the_allocation_limit :: proc(t: ^testing.T) {
	LIMIT :: 6
	driver: Fake_Driver
	defer fake_destroy(&driver)
	m: Vk_Memory_Pools
	fake_pools(&m, &driver, LIMIT, 1)
	source := fake_source(&driver)
	defer vk_memory_destroy(&m, source, true)
	large := Vk_Memory_Request{size = VK_MEMORY_BLOCK_BYTES, align = 256, types = {0}}
	small := Vk_Memory_Request{size = 4096, align = 256, types = {0}}
	first, _, problem, _ := vk_memory_take(&m, source, small)
	testing.expect_value(t, problem, Vk_Memory_Problem.None)
	alone: [LIMIT - 1]Vk_Memory
	for &memory in alone {
		memory, _, problem, _ = vk_memory_take(&m, source, large)
		testing.expect_value(t, problem, Vk_Memory_Problem.None)
	}
	testing.expect_value(t, m.count, LIMIT)
	_, _, problem, _ = vk_memory_take(&m, source, large)
	testing.expect_value(t, problem, Vk_Memory_Problem.Count)
	_, _, problem, _ = vk_memory_take(&m, source, {size = 4096, align = 256, types = {2}})
	testing.expect_value(t, problem, Vk_Memory_Problem.Count)
	_, _, problem, _ = vk_memory_take(&m, source, {size = 4096, align = 256, types = {0}, alone = .Required})
	testing.expect_value(t, problem, Vk_Memory_Problem.Count)
	shared, _, shared_problem, _ := vk_memory_take(&m, source, small)
	testing.expect(t, shared_problem == .None && shared.handle == first.handle, "a block with room takes a resource at the limit")
	// More than half a block would take memory of its own: at the limit it takes the room a block has.
	wide, _, wide_problem, _ := vk_memory_take(&m, source, {size = VK_MEMORY_BLOCK_BYTES / 2 + 1, align = 256, types = {0}})
	testing.expect(t, wide_problem == .None && wide.handle == first.handle)
	vk_memory_give(&m, source, wide)
	vk_memory_give(&m, source, shared)
	vk_memory_give(&m, source, first)
	testing.expect(t, m.count == LIMIT && driver.alive == LIMIT, "the block left empty is kept")
	other, _, other_problem, _ := vk_memory_take(&m, source, {size = 4096, align = 256, types = {2}})
	testing.expect(t, other_problem == .None && driver.types[int(other.handle) - 1] == 2, "and gives its allocation to a resource of another memory type")
	testing.expect(t, !vk_memory_room(&m))
	for memory in alone {vk_memory_give(&m, source, memory)}
	testing.expect(t, vk_memory_room(&m))
	// Memory made outside the pools counts as one of theirs until it is given back.
	outside, _ := source.allocate(source.user, 0, 4096, true)
	adopted := vk_memory_adopt(&m, outside, 4096)
	testing.expect_value(t, m.count, 2)
	vk_memory_give(&m, source, adopted)
	vk_memory_give(&m, source, other)
	testing.expect_value(t, driver.most, LIMIT)
	testing.expect(t, driver.alive == 1 && m.count == 1)
}

// What is no memory is refused before the driver is asked; memory a type does
// not have comes from the next type that takes the resource, as memory of its
// own where a whole block does not fit; and with no type left the refusal
// says what the driver answered.
@(test)
vk_memory_refuses_what_is_no_request_and_falls_back_between_types :: proc(t: ^testing.T) {
	driver: Fake_Driver
	defer fake_destroy(&driver)
	m: Vk_Memory_Pools
	fake_pools(&m, &driver, 64, 1)
	source := fake_source(&driver)
	defer vk_memory_destroy(&m, source, true)
	invalid := [?]Vk_Memory_Request {
		{size = 0, align = 16, types = {0}},
		{size = 64, align = 0, types = {0}},
		{size = 64, align = 3, types = {0}},
		{size = 64, align = 48, types = {0}},
		{size = 64, align = 16},
	}
	for request in invalid {
		_, _, problem, _ := vk_memory_take(&m, source, request)
		testing.expectf(t, problem == .Invalid, "%v: %v", request, problem)
	}
	never := [?]Vk_Memory_Request {
		{size = max(u64), align = 16, types = {0, 1, 2}},
		{size = FAKE_SMALL_HEAP + 1, align = 16, types = {FAKE_SMALL_TYPE}},
		{size = 64, align = 16, types = {FAKE_TYPES, 31, 32, max(u32)}},
	}
	for request in never {
		_, _, problem, _ := vk_memory_take(&m, source, request)
		testing.expectf(t, problem == .Memory, "%v: %v", request, problem)
	}
	testing.expect(t, len(driver.bytes) == 0, "the driver was asked for none of it")

	// The first type has room for the resource and not for a block.
	driver.room[0] = 8192
	tight, _, problem, _ := vk_memory_take(&m, source, {size = 4096, align = 16, types = {0, 2}})
	testing.expect(t, problem == .None && tight.pool == 0 && driver.types[int(tight.handle) - 1] == 0, "memory of its own where a block does not fit")
	driver.room[0] = 0
	next, _, next_problem, _ := vk_memory_take(&m, source, {size = 4096, align = 16, types = {0, 2}})
	testing.expect(t, next_problem == .None && next.pool != 0 && driver.types[int(next.handle) - 1] == 2, "the next type gives what the first does not have")
	driver.room[2] = 0
	filled, _, filled_problem, said := vk_memory_take(&m, source, {size = VK_MEMORY_BLOCK_BYTES, align = 16, types = {0, 2}})
	testing.expect(t, filled_problem == .Memory && said == .ERROR_OUT_OF_DEVICE_MEMORY && filled.handle == 0)
	// A block that cannot be mapped gives the range back.
	driver.blind = true
	driver.room[2] = 4096
	_, used := vk_memory_bytes(&m)
	_, _, blind_problem, blind_said := vk_memory_take(&m, source, {size = 4096, align = 16, types = {0, 2}, mapped = true})
	_, after := vk_memory_bytes(&m)
	testing.expect(t, blind_problem == .Memory && blind_said == .ERROR_MEMORY_MAP_FAILED && after == used)
	vk_memory_give(&m, source, tight)
	vk_memory_give(&m, source, next)
	// A range given twice, of a block that went, or never taken: nothing changes.
	vk_memory_give(&m, source, next)
	vk_memory_give(&m, source, {})
	vk_memory_give(&m, source, {handle = 77, offset = 0, size = 64, block = 900, pool = 200})
	testing.expect(t, driver.alive == 1 && m.count == 1)
	vk_memory_trim(&m, source)
	vk_memory_give(&m, source, next)
	testing.expect(t, driver.alive == 0 && m.count == 0)
}

// With the memory of the tables ending at each request in turn, a resource is
// refused saying so, the driver keeps no allocation for it, and with memory
// enough it goes through.
@(test)
vk_memory_without_host_memory_is_refused_and_leaks_no_allocation :: proc(t: ^testing.T) {
	limit := Memory_Limit{owner = context.allocator, remaining = max(int)}
	driver: Fake_Driver
	defer fake_destroy(&driver)
	m: Vk_Memory_Pools
	fake_pools(&m, &driver, 64, 1, runtime.Allocator{memory_limit_proc, &limit})
	source := fake_source(&driver)
	defer vk_memory_destroy(&m, source, true)
	done, refused := false, false
	for served in 0 ..< 16 {
		limit.remaining = served
		memory, _, problem, _ := vk_memory_take(&m, source, {size = 4096, align = 16, types = {0}})
		limit.remaining = max(int)
		if problem == .None {
			done = memory.handle != 0 && driver.alive == 1
			break
		}
		refused = true
		testing.expectf(t, problem == .Tables && driver.alive == 0 && m.count == 0, "%d requests served: %v with %d allocations kept", served, problem, driver.alive)
	}
	testing.expect(t, done && refused, "refused without memory, and with it it goes through")
}

// Resources of every size, kind and memory type, taken and given back in any
// order: no two share a byte of an allocation, the driver is never asked for
// more allocations than it gives, and with all of them back and the empty
// blocks trimmed it holds none.
@(test)
vk_memory_random_resources_never_overlap_and_all_goes_back :: proc(t: ^testing.T) {
	LIMIT :: 24
	state := rand.create(0xb10c)
	random := rand.default_random_generator(&state)
	driver: Fake_Driver
	defer fake_destroy(&driver)
	m: Vk_Memory_Pools
	fake_pools(&m, &driver, LIMIT, 4096)
	source := fake_source(&driver)
	defer vk_memory_destroy(&m, source, true)
	taken := make([dynamic]Vk_Memory, context.allocator)
	defer delete(taken)
	ranges := make([dynamic]Test_Range, context.allocator)
	defer delete(ranges)
	refused := 0
	for step in 0 ..< 4000 {
		if len(taken) > 0 && (rand.int_max(5, random) < 2 || step >= 3200) {
			at := rand.int_max(len(taken), random)
			vk_memory_give(&m, source, taken[at])
			unordered_remove(&taken, at)
			unordered_remove(&ranges, at)
			continue
		}
		if step >= 3200 {continue}
		types := [2]u32{u32(rand.int_max(FAKE_TYPES, random)), u32(rand.int_max(FAKE_TYPES, random))}
		align := u64(1) << uint(rand.int_max(17, random))
		request := Vk_Memory_Request {
			size = u64(1 + rand.int_max(1 << uint(8 + rand.int_max(19, random)), random)), align = align, types = types[:],
			class = Vk_Memory_Class(rand.int_max(2, random)), alone = Vk_Memory_Alone(rand.int_max(3, random)), mapped = rand.int_max(2, random) == 0,
		}
		memory, mapped, problem, _ := vk_memory_take(&m, source, request)
		if problem != .None {
			refused += 1
			// Only the small heap runs out before the allocations do.
			expected := problem == .Count || problem == .Memory && types == {FAKE_SMALL_TYPE, FAKE_SMALL_TYPE}
			if !testing.expectf(t, expected, "step %d: %v refused as %v", step, request, problem) {return}
			continue
		}
		// An allocation is the block of the ranges that name it: its handle tells blocks apart.
		range := Test_Range{int(memory.handle), memory.offset, memory.size}
		bytes := driver.bytes[int(memory.handle) - 1]
		if !testing.expectf(t, memory.size == request.size && test_range_apart(ranges[:], range, bytes, align), "step %d: %v in an allocation of %d bytes", step, memory, bytes) {return}
		testing.expect(t, (mapped != nil) == request.mapped)
		append(&taken, memory)
		append(&ranges, range)
		if !testing.expectf(t, int(m.count) == driver.alive && driver.alive <= LIMIT, "step %d: %d allocations counted and %d alive", step, m.count, driver.alive) {return}
	}
	for memory in taken {vk_memory_give(&m, source, memory)}
	testing.expect(t, refused > 0 && driver.most == LIMIT, "the limit was reached")
	_, used := vk_memory_bytes(&m)
	testing.expect_value(t, used, 0)
	vk_memory_trim(&m, source)
	testing.expect(t, driver.alive == 0 && m.count == 0, "every allocation went back to the driver")
}
