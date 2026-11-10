package rhi

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:std/base"

@(private = "file")
TEST_DEVICE :: Pipeline_Device{vendor = 0x10de, device = 0x2484, driver = 7, uuid = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}}

@(private = "file")
test_blob :: proc(key: u64, size: int) -> []u8 {
	data := make([]u8, size)
	for &b, i in data {b = u8(key) ~ u8(i)}
	return data
}

// A run: reads the store of path, uses the keys it finds and puts those it
// does not, and writes it back. Returns the keys it found.
@(private = "file")
test_run :: proc(path: string, keys: []u64, size := 1000, limit := PIPELINE_STORE_BYTES, device := TEST_DEVICE) -> (found: [dynamic]u64) {
	found.allocator = context.temp_allocator
	s: Pipeline_Store
	pipeline_store_init(&s, device, limit)
	defer pipeline_store_destroy(&s)
	pipeline_store_load(&s, path)
	for key in keys {
		if blob := pipeline_store_find(&s, key); blob != nil {
			if len(blob) == size && blob[size - 1] == u8(key) ~ u8(size - 1) {append(&found, key)}
		} else {
			pipeline_store_put(&s, key, test_blob(key, size))
		}
	}
	pipeline_store_save(&s, path)
	return
}

@(private = "file")
test_has :: proc(found: []u64, key: u64) -> bool {
	for k in found {if k == key {return true}}
	return false
}

@(test)
pipeline_store_keeps_the_pipelines_of_its_runs_within_its_limit :: proc(t: ^testing.T) {
	folder := base.test_folder(t, "pipeline-store")
	if folder == "" {return}
	path := fmt.tprintf("%s/pipelines.bin", folder)
	limit := 40 + 5 * (24 + 1000)
	first := test_run(path, {1, 2, 3}, limit = limit)
	testing.expect_value(t, len(first), 0)
	again := test_run(path, {1, 2, 3}, limit = limit)
	testing.expect(t, test_has(again[:], 1) && test_has(again[:], 2) && test_has(again[:], 3), "a second run finds what the first compiled")
	// A run that compiles more than fits keeps the last it used.
	test_run(path, {4, 5, 6, 7, 8, 9, 10, 11}, limit = limit)
	info, error := os.stat(path, context.temp_allocator)
	testing.expect(t, error == nil && info.size <= i64(limit), "the file stays within the limit")
	kept := test_run(path, {11, 10, 9, 8, 7, 1}, limit = limit)
	testing.expect(t, test_has(kept[:], 11) && test_has(kept[:], 10) && test_has(kept[:], 7), "the last used are kept")
	testing.expect(t, !test_has(kept[:], 1), "the oldest went to make room")
}

// The pipelines of shaders that changed are never asked for again: they leave
// after PIPELINE_STORE_RUNS runs, and those of another device or driver at once.
@(test)
pipeline_store_drops_what_runs_no_longer_use :: proc(t: ^testing.T) {
	folder := base.test_folder(t, "pipeline-store")
	if folder == "" {return}
	path := fmt.tprintf("%s/pipelines.bin", folder)
	test_run(path, {1, 2})
	for _ in 0 ..< PIPELINE_STORE_RUNS {test_run(path, {1})}
	last := test_run(path, {1, 2})
	testing.expect(t, test_has(last[:], 1), "a key every run uses stays")
	testing.expect(t, !test_has(last[:], 2), "a key no run used for PIPELINE_STORE_RUNS runs left")
	other := TEST_DEVICE
	other.driver += 1
	testing.expect_value(t, len(test_run(path, {1}, device = other)), 0)
	testing.expect_value(t, len(test_run(path, {1})), 0)
}

@(test)
pipeline_store_replaces_a_file_it_cannot_read :: proc(t: ^testing.T) {
	folder := base.test_folder(t, "pipeline-store")
	if folder == "" {return}
	path := fmt.tprintf("%s/pipelines.bin", folder)
	test_run(path, {1, 2}, size = 64)
	valid, read_error := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, read_error == nil && len(valid) > 0) {return}

	Case :: struct {name: string, data: []u8}
	cases := make([dynamic]Case, context.temp_allocator)
	for size in ([]int{0, 1, 39, 40, 63, len(valid) - 1}) {append(&cases, Case{"truncated", valid[:size]})}
	flipped := make([]u8, len(valid), context.temp_allocator)
	copy(flipped, valid)
	flipped[len(flipped) - 1] ~= 0xff
	append(&cases, Case{"a byte of a blob changed", flipped})
	huge := make([]u8, len(valid), context.temp_allocator)
	copy(huge, valid)
	store_write_u32(huge, 20, max(u32))
	append(&cases, Case{"a count past the file", huge})
	overflow := make([]u8, len(valid), context.temp_allocator)
	copy(overflow, valid)
	store_write_u32(overflow, 40 + 20, max(u32))
	append(&cases, Case{"a blob past the file", overflow})
	longer := make([]u8, len(valid) + 3, context.temp_allocator)
	copy(longer, valid)
	append(&cases, Case{"bytes after the last entry", longer})
	driver := [?]u8{32, 0, 0, 0, 1, 0, 0, 0, 0xde, 0x10, 0, 0, 0x84, 0x24, 0, 0}
	append(&cases, Case{"a driver blob of before", driver[:]})
	state := u64(0x9e3779b97f4a7c15)
	for _ in 0 ..< 32 {
		random := make([]u8, 40 + int(state % 512), context.temp_allocator)
		for &b in random {state = state * 6364136223846793005 + 1442695040888963407; b = u8(state >> 56)}
		copy(random, valid[:40])
		store_write_u32(random, 20, u32(state % 4))
		append(&cases, Case{"random entries", random})
	}
	for c in cases {
		testing.expect_value(t, os.write_entire_file(path, c.data), nil)
		testing.expectf(t, len(test_run(path, {1, 2}, size = 64)) == 0, "%s: nothing is taken from it", c.name)
		testing.expectf(t, len(test_run(path, {1, 2}, size = 64)) == 2, "%s: the next run reads the file that replaced it", c.name)
	}
}

// What a process that ended left of its write goes when the store is read; the
// write of a process that runs stays.
@(test)
pipeline_store_removes_what_ended_writes_left :: proc(t: ^testing.T) {
	folder := base.test_folder(t, "pipeline-store")
	if folder == "" {return}
	path := fmt.tprintf("%s/pipelines.bin", folder)
	ended := fmt.tprintf("%s.%d.tmp", path, 1 << 30)
	running := fmt.tprintf("%s.%d.tmp", path, os.get_ppid()) // this process writes its own in each run
	partial := [?]u8{1, 2, 3}
	testing.expect_value(t, os.write_entire_file(ended, partial[:]), nil)
	testing.expect_value(t, os.write_entire_file(running, partial[:]), nil)
	test_run(path, {1})
	testing.expect(t, !os.exists(ended), "the write of a process that ended is removed")
	testing.expect(t, os.exists(running), "the write of a process that runs is kept")
	testing.expect_value(t, len(test_run(path, {1})), 1)
}
