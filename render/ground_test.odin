package mirai_render

import "core:testing"

// The chunks of the color of the ground are those of one regular grid, each in
// a slot by its cell: one off the grid is refused and says why, one past the
// slots is refused without an error, a revision that changes marks its chunk
// to be baked again and keeps what it shows, and another world starts over.
@(test)
ground_chunks_take_a_slot_by_their_cell_of_one_grid :: proc(t: ^testing.T) {
	r := new(Renderer);defer free(r)
	r.allocator = context.allocator
	r.settings.ground_chunks = 3
	g := &r.ground
	Step :: struct {
		world:    u64,
		low:      [2]f32,
		size:     f32,
		revision: u64,
		remove:   bool,
		ok:       bool,
		error:    bool,
		used:     int,    // slots taken after it
		cell:     [2]i32, // of the chunk, when it is taken
		stale:    bool,   // whether its slot waits for a bake after it
	}
	steps := []Step {
		{low = {100, -50}, size = 114.75, revision = 1, ok = true, used = 1, cell = {0, 0}, stale = true},
		{low = {214.75, -50}, size = 114.75, revision = 1, ok = true, used = 2, cell = {1, 0}, stale = true},
		{low = {100, -164.75}, size = 114.75, revision = 1, ok = true, used = 3, cell = {0, -1}, stale = true},
		// Baked since (below): the same revision leaves it, another asks for it again.
		{low = {100, -50}, size = 114.75, revision = 1, ok = true, used = 3, cell = {0, 0}, stale = false},
		{low = {100, -50}, size = 114.75, revision = 2, ok = true, used = 3, cell = {0, 0}, stale = true},
		// No slot is left.
		{low = {329.5, -50}, size = 114.75, revision = 1, used = 3},
		// Off the grid: between two cells, and of another size.
		{low = {150, -50}, size = 114.75, revision = 1, error = true, used = 3},
		{low = {100, -50}, size = 57, revision = 1, error = true, used = 3},
		{low = {100, -50}, size = 0, revision = 1, error = true, used = 3},
		{low = {214.75, -50}, remove = true, ok = true, used = 2},
		{low = {214.75, -50}, remove = true, used = 2},
		{low = {329.5, -50}, size = 114.75, revision = 1, ok = true, used = 3, cell = {2, 0}, stale = true},
		// Another world: its grid is its own.
		{world = 7, low = {3, 3}, size = 10, revision = 1, ok = true, used = 1, cell = {0, 0}, stale = true},
		{world = 7, low = {-17, 23}, size = 10, revision = 1, ok = true, used = 2, cell = {-2, 2}, stale = true},
	}
	for step, i in steps {
		r.error = ""
		if i == 3 {for &slot in g.slots {slot.stale, slot.baked = false, slot.used}}
		ok := ground_chunk_remove(r, step.world, step.low) if step.remove else ground_chunk_set(r, step.world, {instance = u32(i), low = step.low, size = step.size, revision = step.revision})
		testing.expectf(t, ok == step.ok, "step %d: %v", i, ok)
		testing.expectf(t, (r.error != "") == step.error, "step %d: error %q", i, r.error)
		used := 0
		found: ^Ground_Slot
		for &slot in g.slots {
			if !slot.used {continue}
			used += 1
			if cell, on_grid := ground_cell(g, step.low); on_grid && cell == slot.cell {found = &slot}
		}
		testing.expectf(t, used == step.used, "step %d: %d slots taken", i, used)
		if step.remove || !step.ok {continue}
		if !testing.expectf(t, found != nil, "step %d: its chunk has a slot", i) {continue}
		testing.expectf(t, found.cell == step.cell && found.stale == step.stale && found.chunk.instance == u32(i), "step %d: %v", i, found^)
		// What it showed stays until it is baked again.
		if i == 4 {testing.expect(t, found.baked)}
	}
}

// The table names the texture of each baked chunk at its cell from the lowest
// one, and nothing for a chunk that waits for its bake or is past its side;
// the frame gives where its first chunk starts relative to the origin.
@(test)
the_table_of_the_ground_names_the_baked_chunks_from_the_lowest_cell :: proc(t: ^testing.T) {
	r := new(Renderer);defer free(r)
	r.allocator = context.allocator
	r.settings.ground_chunks = 8
	g := &r.ground
	lows := [][2]f32{{0, 0}, {-20, 10}, {10, -30}, {10, 0}, {3090, 0}}
	for low, i in lows {testing.expect(t, ground_chunk_set(r, 0, {instance = u32(i), low = low, size = 10, revision = 1}))}
	g.made = len(lows)
	for &slot, i in g.slots[:g.made] {slot.handle, slot.baked = Texture_Handle(300 + i), i != 3}
	entries: [GROUND_TABLE * GROUND_TABLE][4]u8
	g.low = ground_table_fill(g, entries[:])
	testing.expect_value(t, g.low, [2]i32{-2, -3})
	named := 0
	for entry, at in entries {
		index := u32(entry[0]) | u32(entry[1]) << 8
		if index == 0 {continue}
		named += 1
		cell := [2]i32{i32(at % GROUND_TABLE), i32(at / GROUND_TABLE)} + g.low
		slot: ^Ground_Slot
		for &each in g.slots[:g.made] {if each.cell == cell {slot = &each}}
		testing.expectf(t, slot != nil && slot.baked && index == texture_entry(int(slot.handle) - 1), "entry %d names %d", at, index)
	}
	// The one that waits for its bake and the one 311 chunks away have none.
	testing.expect_value(t, named, 3)
	_, none := ground_frame(r)
	testing.expect_value(t, none, 0)
	g.table, g.table_handle = 1, 9
	r.origin = {1024, 0, -2048}
	ground, table := ground_frame(r)
	testing.expect_value(t, ground, [3]f32{-20 - 1024, -30 + 2048, 0.1})
	testing.expect_value(t, table, texture_entry(8))
	// Another world is shown: its ground has no color.
	r.world_key = 5
	_, table = ground_frame(r)
	testing.expect_value(t, table, 0)
}
