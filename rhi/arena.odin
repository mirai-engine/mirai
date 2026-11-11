package rhi

import "base:runtime"
import "mirai:std/base"

// Ranges of large blocks of GPU memory, which many resources share instead of
// taking an object of the driver each: the device memory of buffers and
// textures on Vulkan (vulkan_memory.odin) and the acceleration structures of
// both backends (accel_arena.odin). The arena keeps the free ranges of each
// block; what a block is, and letting an empty one go, is for its owner.
@(private)
Arena :: struct {
	blocks:    [dynamic]base.Ranges, // size 0: a slot a block left, for the next one
	allocator: runtime.Allocator,
}

// A range of size bytes aligned to align, a power of two, first fit. ok false:
// no block has room for it, or there is no memory to track one range more.
@(private)
arena_take :: proc(arena: ^Arena, size, align: u64) -> (block: int, offset: u64, ok: bool) {
	for &b, i in arena.blocks {
		if offset, ok = base.ranges_take(&b, size, align); ok {return i, offset, true}
	}
	return
}

// Takes a new block of size bytes, free whole, in the slot an empty one left
// or a new one. Its index; ok false without memory to track it.
@(private)
arena_add :: proc(arena: ^Arena, size: u64) -> (block: int, ok: bool) {
	if size == 0 {return}
	if arena.blocks.allocator.procedure == nil {arena.blocks = make([dynamic]base.Ranges, arena.allocator)}
	at := -1
	for b, i in arena.blocks {if b.size == 0 {at = i; break}}
	if at < 0 {
		if _, err := append(&arena.blocks, base.Ranges{}); err != nil {return}
		at = len(arena.blocks) - 1
	}
	return at, base.ranges_reset(&arena.blocks[at], size, allocator = arena.allocator)
}

// Gives a range back to its block, joined with the free ranges beside it,
// without asking for memory. True when the block is left empty: its owner
// lets it go (arena_drop) or keeps it. A range the block did not give, or one
// already back, changes nothing.
@(private)
arena_give :: proc(arena: ^Arena, block: int, offset, size: u64) -> (empty: bool) {
	if block < 0 || block >= len(arena.blocks) {return false}
	b := &arena.blocks[block]
	return base.ranges_give(b, offset, size) && b.used == 0
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
