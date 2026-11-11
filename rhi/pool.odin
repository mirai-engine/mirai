package rhi

import "base:runtime"
import "mirai:std/base"

// Generational resource pool of a fixed capacity, shared by both backends. A
// handle is a base.Handle: the slot in the low 32 bits and its generation in
// the high 32, which starts at 1 so the zero handle stays invalid. Using a
// handle after its resource was destroyed returns nil instead of aliasing the
// slot's next occupant.
Pool :: struct($T: typeid) {
	items:       []T,
	generations: []u32,
	alive:       []bool,
	free:        []u32, // ring, FIFO: a freed slot is reused after every other free slot
	free_head:   int,
	free_count:  int,
	used:        int,   // slots handed out at least once
	count:       int,
}

pool_init :: proc(p: ^Pool($T), capacity: int, allocator: runtime.Allocator) -> bool {
	items, items_error := make([]T, capacity, allocator)
	generations, generations_error := make([]u32, capacity, allocator)
	alive, alive_error := make([]bool, capacity, allocator)
	free, free_error := make([]u32, capacity, allocator)
	if items_error != nil || generations_error != nil || alive_error != nil || free_error != nil {
		delete(items, allocator)
		delete(generations, allocator)
		delete(alive, allocator)
		delete(free, allocator)
		return false
	}
	p.items, p.generations, p.alive, p.free = items, generations, alive, free
	return true
}

pool_has_room :: proc "contextless" (p: ^Pool($T)) -> bool {
	return p.free_count > 0 || p.used < len(p.items)
}

pool_add :: proc "contextless" (p: ^Pool($T), item: T) -> base.Handle {
	index: u32
	if p.used < len(p.items) {
		// Fresh slots first: FIFO reuse then spreads generations over every
		// slot of the pool before one of them repeats.
		index = u32(p.used)
		p.used += 1
		p.generations[index] = 1
	} else if p.free_count > 0 {
		index = p.free[p.free_head]
		p.free_head = (p.free_head + 1) % len(p.free)
		p.free_count -= 1
	} else {
		return 0
	}
	p.items[index] = item
	p.alive[index] = true
	p.count += 1
	return base.handle_make(index, p.generations[index])
}

// Reads only the slot of the handle: another thread may add to the pool
// meanwhile (pipelines), as long as it does not remove that slot.
pool_get :: proc "contextless" (p: ^Pool($T), handle: base.Handle) -> ^T {
	if handle == 0 {return nil}
	index := base.handle_index(handle)
	if int(index) >= len(p.items) || !p.alive[index] || p.generations[index] != base.handle_generation(handle) {return nil}
	return &p.items[index]
}

// The handle of a live slot.
pool_handle :: proc "contextless" (p: ^Pool($T), index: int) -> base.Handle {
	return base.handle_make(u32(index), p.generations[index])
}

pool_remove :: proc "contextless" (p: ^Pool($T), handle: base.Handle) -> (item: T, ok: bool) {
	if pool_get(p, handle) == nil {return}
	index := base.handle_index(handle)
	item = p.items[index]
	p.items[index] = {}
	p.alive[index] = false
	p.generations[index] += 1
	if p.generations[index] == 0 {p.generations[index] = 1}
	p.free[(p.free_head + p.free_count) % len(p.free)] = index
	p.free_count += 1
	p.count -= 1
	return item, true
}

pool_destroy :: proc(p: ^Pool($T), allocator: runtime.Allocator) {
	delete(p.items, allocator)
	delete(p.generations, allocator)
	delete(p.alive, allocator)
	delete(p.free, allocator)
	p^ = {}
}
