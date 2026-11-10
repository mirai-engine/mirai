package rhi

import "base:runtime"

// Ranges of large blocks of GPU memory, which many resources share instead of
// taking an object of the driver each: the device memory of buffers and
// textures on Vulkan (vulkan_memory.odin) and the acceleration structures of
// both backends (accel_arena.odin). The arena keeps the free ranges of each
// block; what a block is, and letting an empty one go, is for its owner.
@(private)
Arena_Free :: struct {offset, size: u64}

@(private)
Arena_Block :: struct {
	size: u64, // 0: a slot a block left, for the next one
	used: u64,
	live: int, // ranges taken: free has room for the entry each may need when it comes back
	free: [dynamic]Arena_Free, // by offset, none touching
}

@(private)
Arena :: struct {
	blocks:    [dynamic]Arena_Block,
	allocator: runtime.Allocator,
}

// A range of size bytes aligned to align, a power of two, first fit. ok false:
// no block has room for it, or there is no memory to track one range more.
@(private)
arena_take :: proc(arena: ^Arena, size, align: u64) -> (block: int, offset: u64, ok: bool) {
	if size == 0 || align == 0 || align & (align - 1) != 0 {return}
	for &b, i in arena.blocks {
		if b.size - b.used < size {continue}
		for k in 0 ..< len(b.free) {
			f := b.free[k]
			start := align_up(f.offset, align)
			lead := start - f.offset
			if start < f.offset || lead > f.size || f.size - lead < size {continue}
			// Ranges taken leave at most one free range more than they are.
			if reserve(&b.free, b.live + 2) != nil {return}
			tail := Arena_Free{start + size, f.size - lead - size}
			switch {
			case lead > 0:
				b.free[k].size = lead
				if tail.size > 0 {inject_at(&b.free, k + 1, tail)}
			case tail.size > 0:
				b.free[k] = tail
			case:
				ordered_remove(&b.free, k)
			}
			b.used += size
			b.live += 1
			return i, start, true
		}
	}
	return
}

// Takes a new block of size bytes, free whole, in the slot an empty one left
// or a new one. Its index; ok false without memory to track it.
@(private)
arena_add :: proc(arena: ^Arena, size: u64) -> (block: int, ok: bool) {
	if size == 0 {return}
	if arena.blocks.allocator.procedure == nil {arena.blocks = make([dynamic]Arena_Block, arena.allocator)}
	at := -1
	for b, i in arena.blocks {if b.size == 0 {at = i; break}}
	if at < 0 {
		if _, err := append(&arena.blocks, Arena_Block{}); err != nil {return}
		at = len(arena.blocks) - 1
	}
	b := &arena.blocks[at]
	if b.free.allocator.procedure == nil {b.free = make([dynamic]Arena_Free, arena.allocator)}
	clear(&b.free)
	if _, err := append(&b.free, Arena_Free{0, size}); err != nil {return}
	b.size, b.used, b.live = size, 0, 0
	return at, true
}

// Gives a range back to its block, joined with the free ranges beside it,
// without asking for memory. True when the block is left empty: its owner
// lets it go (arena_drop) or keeps it. A range the block did not give, or one
// already back, changes nothing.
@(private)
arena_give :: proc(arena: ^Arena, block: int, offset, size: u64) -> (empty: bool) {
	if block < 0 || block >= len(arena.blocks) {return false}
	b := &arena.blocks[block]
	if size == 0 || b.live == 0 || size > b.used || offset > b.size || size > b.size - offset {return false}
	at, end := 0, len(b.free)
	for at < end {
		middle := (at + end) / 2
		if b.free[middle].offset > offset {end = middle} else {at = middle + 1}
	}
	before := at > 0
	after := at < len(b.free)
	if before && b.free[at - 1].offset + b.free[at - 1].size > offset {return false}
	if after && offset + size > b.free[at].offset {return false}
	before &&= b.free[at - 1].offset + b.free[at - 1].size == offset
	after &&= offset + size == b.free[at].offset
	switch {
	case before && after:
		b.free[at - 1].size += size + b.free[at].size
		ordered_remove(&b.free, at)
	case before:
		b.free[at - 1].size += size
	case after:
		b.free[at] = {offset, size + b.free[at].size}
	case:
		inject_at(&b.free, at, Arena_Free{offset, size})
	}
	b.used -= size
	b.live -= 1
	return b.used == 0
}

// Forgets an empty block: its slot takes the next one.
@(private)
arena_drop :: proc(arena: ^Arena, block: int) {
	if block < 0 || block >= len(arena.blocks) {return}
	b := &arena.blocks[block]
	b.size, b.used, b.live = 0, 0, 0
	clear(&b.free)
}

@(private)
arena_destroy :: proc(arena: ^Arena) {
	for &b in arena.blocks {delete(b.free)}
	delete(arena.blocks)
	arena^ = {}
}

// The bytes of the blocks of an arena and what the ranges taken hold of them.
@(private)
arena_bytes :: proc "contextless" (arena: ^Arena) -> (held, used: u64) {
	for b in arena.blocks {held += b.size; used += b.used}
	return
}
