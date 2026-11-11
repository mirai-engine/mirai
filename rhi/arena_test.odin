package rhi

import "base:runtime"
import "core:math/rand"
import "core:testing"
import "mirai:std/base"

// Ranges fill a block from its start, aligned; given back they join their
// neighbours, so the block ends whole and empty, and a structure larger than
// a block takes one of its own.
@(test)
arena_takes_aligned_ranges_and_joins_what_comes_back :: proc(t: ^testing.T) {
	arena := Arena{allocator = context.allocator}
	defer arena_destroy(&arena)
	_, _, ok := arena_take(&arena, 1000, ACCEL_ALIGNMENT)
	testing.expect(t, !ok, "an arena without blocks has no room")
	block, added := arena_add(&arena, accel_block_size(1000))
	testing.expect(t, added)
	testing.expect_value(t, arena.blocks[block].size, ACCEL_BLOCK_BYTES)
	sizes := [4]u64{1000, 256, 4096, 300}
	offsets: [4]u64
	for size, i in sizes {
		at, offset, taken := arena_take(&arena, align_up(size, ACCEL_ALIGNMENT), ACCEL_ALIGNMENT)
		testing.expect(t, taken && at == block && offset % ACCEL_ALIGNMENT == 0)
		offsets[i] = offset
	}
	testing.expect(t, offsets[0] == 0 && offsets[1] == 1024 && offsets[2] == 1280 && offsets[3] == 5376, "first fit, in order")
	// A hole in the middle takes what fits there.
	testing.expect(t, !arena_give(&arena, block, offsets[1], 256))
	at, offset, taken := arena_take(&arena, 256, ACCEL_ALIGNMENT)
	testing.expect(t, taken && at == block && offset == offsets[1])
	// Given back in any order, the ranges join into the whole block.
	testing.expect(t, !arena_give(&arena, block, offsets[2], 4096))
	testing.expect(t, !arena_give(&arena, block, offsets[0], 1024))
	testing.expect(t, !arena_give(&arena, block, offsets[3], 512))
	testing.expect(t, arena_give(&arena, block, offsets[1], 256), "the last range leaves the block empty")
	testing.expect(t, len(arena.blocks[block].free) == 1 && arena.blocks[block].free[0] == base.Range{0, ACCEL_BLOCK_BYTES})
	// Larger than a block: a block of its own, in the slot an empty one left.
	arena_drop(&arena, block)
	huge := ACCEL_BLOCK_BYTES * 3 + 1
	again, added_again := arena_add(&arena, accel_block_size(huge))
	testing.expect(t, added_again)
	testing.expect_value(t, again, block)
	at, offset, taken = arena_take(&arena, align_up(huge, ACCEL_ALIGNMENT), ACCEL_ALIGNMENT)
	testing.expect(t, taken && at == again && offset == 0)
}

// What is no range is refused and leaves the block as it was: nothing to
// take, an alignment that is no power of two, more than the block, and giving
// back what the block did not give or what is already back.
@(test)
arena_refuses_what_is_no_range :: proc(t: ^testing.T) {
	BLOCK :: u64(1) << 16
	arena := Arena{allocator = context.allocator}
	defer arena_destroy(&arena)
	_, no_block := arena_add(&arena, 0)
	testing.expect(t, !no_block, "a block of no bytes is no block")
	block, added := arena_add(&arena, BLOCK)
	if !testing.expect(t, added) {return}
	_, held, taken := arena_take(&arena, 4096, 256)
	if !testing.expect(t, taken) {return}
	takes := [?][2]u64{{0, 16}, {64, 0}, {64, 3}, {64, 6}, {64, 255}, {BLOCK, 16}, {max(u64), 1}, {max(u64) - 4095, 4096}, {64, max(u64)}, {1, 1 << 63}}
	for take in takes {
		_, _, ok := arena_take(&arena, take[0], take[1])
		testing.expectf(t, !ok, "%d bytes aligned to %d is no range of the block", take[0], take[1])
	}
	Give :: struct {block: int, offset, size: u64}
	gives := [?]Give{{-1, held, 4096}, {block + 1, held, 4096}, {block, held, 0}, {block, held, 8192}, {block, BLOCK, 4096}, {block, max(u64), 4096}, {block, held + 4096, 4096}, {block, held + 2048, 4096}, {block, held, max(u64)}}
	for give in gives {
		testing.expectf(t, !arena_give(&arena, give.block, give.offset, give.size), "%v is no range the block gave", give)
		testing.expectf(t, arena.blocks[block].used == 4096 && arena.blocks[block].live == 1, "%v changed what the block holds", give)
	}
	testing.expect(t, arena_give(&arena, block, held, 4096))
	testing.expect(t, !arena_give(&arena, block, held, 4096), "a range goes back once")
	testing.expect(t, len(arena.blocks[block].free) == 1 && arena.blocks[block].free[0] == base.Range{0, BLOCK})
}

@(private)
Test_Range :: struct {block: int, offset, size: u64}

// Whether a range lies in its block, on its alignment, and apart from the others taken.
@(private)
test_range_apart :: proc(taken: []Test_Range, range: Test_Range, block_size, align: u64) -> bool {
	if range.offset % align != 0 || range.offset + range.size > block_size {return false}
	for other in taken {
		if other.block == range.block && range.offset < other.offset + other.size && other.offset < range.offset + range.size {return false}
	}
	return true
}

// Ranges of any size and alignment, taken and given back in any order, never
// share a byte; what the blocks say they hold is what is out, and with all of
// it back each block is one free range again.
@(test)
arena_random_takes_and_gives_never_overlap :: proc(t: ^testing.T) {
	BLOCK :: u64(1) << 20
	state := rand.create(0x5eed)
	random := rand.default_random_generator(&state)
	arena := Arena{allocator = context.allocator}
	defer arena_destroy(&arena)
	taken := make([dynamic]Test_Range, context.allocator)
	defer delete(taken)
	out: u64
	for step in 0 ..< 6000 {
		if len(taken) > 0 && (rand.int_max(3, random) == 0 || step >= 5000) {
			at := rand.int_max(len(taken), random)
			range := taken[at]
			unordered_remove(&taken, at)
			arena_give(&arena, range.block, range.offset, range.size)
			out -= range.size
		} else if step < 5000 {
			size := u64(1 + rand.int_max(1 << uint(rand.int_max(16, random)), random))
			align := u64(1) << uint(rand.int_max(13, random))
			block, offset, ok := arena_take(&arena, size, align)
			if !ok {
				_, added := arena_add(&arena, BLOCK)
				if !testing.expect(t, added) {return}
				block, offset, ok = arena_take(&arena, size, align)
			}
			range := Test_Range{block, offset, size}
			if !testing.expectf(t, ok && test_range_apart(taken[:], range, BLOCK, align), "step %d: %v aligned to %d", step, range, align) {return}
			append(&taken, range)
			out += size
		}
		_, used := arena_bytes(&arena)
		if !testing.expectf(t, used == out, "step %d: the blocks hold %d bytes and %d are out", step, used, out) {return}
	}
	for len(taken) > 0 {
		range := pop(&taken)
		arena_give(&arena, range.block, range.offset, range.size)
	}
	testing.expect(t, len(arena.blocks) > 1, "the ranges took more than a block")
	for b, i in arena.blocks {
		testing.expectf(t, b.used == 0 && b.live == 0 && len(b.free) == 1 && b.free[0] == base.Range{0, BLOCK}, "block %d is not whole: %v", i, b.free[:])
	}
}

// Without memory a range is refused and the block keeps what it held; giving
// ranges back asks for none, so every range out can always come back.
@(test)
arena_gives_back_without_memory :: proc(t: ^testing.T) {
	BLOCK :: u64(1) << 20
	limit := Memory_Limit{owner = context.allocator, remaining = max(int)}
	arena := Arena{allocator = runtime.Allocator{memory_limit_proc, &limit}}
	defer arena_destroy(&arena)
	block, added := arena_add(&arena, BLOCK)
	if !testing.expect(t, added) {return}
	offsets := make([dynamic]u64, context.allocator)
	defer delete(offsets)
	refused := false
	for i in 0 ..< 1024 {
		limit.remaining = max(int) if i % 4 == 0 else 0
		_, offset, ok := arena_take(&arena, 64, 64)
		if ok {append(&offsets, offset)} else {refused = true}
		if !testing.expect_value(t, arena.blocks[block].used, u64(len(offsets)) * 64) {return}
	}
	testing.expect(t, refused && len(offsets) > 64, "ranges were refused without memory and taken with it")
	limit.remaining = 0
	// Every other range first: each leaves a free range of its own.
	for offset, i in offsets {if i % 2 == 0 {arena_give(&arena, block, offset, 64)}}
	for offset, i in offsets {if i % 2 == 1 {arena_give(&arena, block, offset, 64)}}
	testing.expect(t, arena.blocks[block].used == 0 && len(arena.blocks[block].free) == 1 && arena.blocks[block].free[0] == base.Range{0, BLOCK})
	limit.remaining = max(int)
}
