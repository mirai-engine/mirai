package rhi

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:std/base"

@(private = "file")
TEST_DEVICE :: Pipeline_Device{vendor = 0x10de, device = 0x2484, driver = 7, uuid = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}}

// The blob of a pipeline: bytes of its own, and shared, when given, between
// them, as a driver puts what all its blobs share in each.
@(private = "file")
test_blob :: proc(key: u64, size: int, shared: []u8 = nil, allocator := context.allocator) -> []u8 {
	data := make([]u8, size + len(shared), allocator)
	state := base.hash_u64(key)
	for &b in data[:size / 3] {state = state * 6364136223846793005 + 1442695040888963407; b = u8(state >> 56)}
	copy(data[size / 3:], shared)
	for &b in data[size / 3 + len(shared):] {state = state * 6364136223846793005 + 1442695040888963407; b = u8(state >> 56)}
	return data
}

// A run: reads the store of path, uses the keys it finds and puts those it
// does not, and writes it back. Returns the keys it found whole.
@(private = "file")
test_run :: proc(path: string, keys: []u64, size := 1000, limit := PIPELINE_STORE_BYTES, device := TEST_DEVICE, shared: []u8 = nil) -> (found: [dynamic]u64) {
	found.allocator = context.temp_allocator
	s: Pipeline_Store
	pipeline_store_init(&s, device, limit)
	defer pipeline_store_destroy(&s)
	pipeline_store_load(&s, path)
	for key in keys {
		expected := test_blob(key, size, shared, context.temp_allocator)
		if blob := pipeline_store_find(&s, key); blob != nil {
			if string(blob) == string(expected) {append(&found, key)}
			delete(blob)
		} else {
			pipeline_store_put(&s, key, expected)
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
	limit := 48 + 5 * (24 + 1000 + 16 + 4)
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

// What every blob of a driver holds (NVIDIA a dictionary of megabytes) is kept
// once, wherever it sits in each blob.
@(test)
pipeline_store_keeps_what_blobs_share_once :: proc(t: ^testing.T) {
	folder := base.test_folder(t, "pipeline-store")
	if folder == "" {return}
	path := fmt.tprintf("%s/pipelines.bin", folder)
	shared := test_blob(0, 2 << 20, nil, context.temp_allocator)
	keys := [?]u64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}
	own := 30000
	test_run(path, keys[:], size = own, shared = shared)
	info, error := os.stat(path, context.temp_allocator)
	if !testing.expect(t, error == nil) {return}
	testing.expectf(t, info.size < i64(len(shared) + len(keys) * (own + 2 * PIPELINE_CHUNK_MAX)), "%d bytes for %d blobs of %d", info.size, len(keys), len(shared) + own)
	testing.expect_value(t, len(test_run(path, keys[:], size = own, shared = shared)), len(keys))
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
	for size in ([]int{0, 1, 47, 48, 71, 100, len(valid) - 5, len(valid) - 1}) {append(&cases, Case{"truncated", valid[:size]})}
	flipped := make([]u8, len(valid), context.temp_allocator)
	copy(flipped, valid)
	flipped[len(flipped) - 1] ~= 0xff
	append(&cases, Case{"the last chunk index changed", flipped})
	chunk := make([]u8, len(valid), context.temp_allocator)
	copy(chunk, valid)
	chunk[48 + 24] ~= 1
	append(&cases, Case{"a byte of a chunk changed", chunk})
	huge := make([]u8, len(valid), context.temp_allocator)
	copy(huge, valid)
	store_write_u32(huge, 24, max(u32))
	append(&cases, Case{"a count past the file", huge})
	overflow := make([]u8, len(valid), context.temp_allocator)
	copy(overflow, valid)
	store_write_u32(overflow, 48 + 16, max(u32))
	append(&cases, Case{"a chunk past the file", overflow})
	index := make([]u8, len(valid), context.temp_allocator)
	copy(index, valid)
	store_write_u32(index, len(index) - 4, 99)
	append(&cases, Case{"an entry of a chunk that is not there", index})
	longer := make([]u8, len(valid) + 3, context.temp_allocator)
	copy(longer, valid)
	append(&cases, Case{"bytes after the last entry", longer})
	driver := [?]u8{32, 0, 0, 0, 1, 0, 0, 0, 0xde, 0x10, 0, 0, 0x84, 0x24, 0, 0}
	append(&cases, Case{"a driver blob of before", driver[:]})
	state := u64(0x9e3779b97f4a7c15)
	for _ in 0 ..< 32 {
		random := make([]u8, 48 + int(state % 512), context.temp_allocator)
		for &b in random {state = state * 6364136223846793005 + 1442695040888963407; b = u8(state >> 56)}
		copy(random, valid[:48])
		store_write_u32(random, 20, u32(state % 4))
		store_write_u32(random, 24, u32((state >> 8) % 4))
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

// The key of a pipeline follows what the driver compiles of it: its code, its
// state and the constants of each stage, never its name.
@(test)
pipeline_keys_follow_the_code_the_state_and_the_constants :: proc(t: ^testing.T) {
	spirv := [2][8]u8{{1, 2, 3, 4, 5, 6, 7, 8}, {8, 7, 6, 5, 4, 3, 2, 1}}
	codes: [2]Shader_Code
	for &code, i in codes {
		shader_code_set(&code, spirv[i][:], "main0")
		code.constants = {"first", "second"}
	}
	compute := Compute_Pipeline_Desc{shader = &codes[0], name = "a"}
	key := pipeline_key_compute(compute)
	Compute_Case :: struct {name: string, desc: Compute_Pipeline_Desc, same: bool}
	for c in ([]Compute_Case{
		{"another name", {shader = &codes[0], name = "b"}, true},
		{"another code", {shader = &codes[1], name = "a"}, false},
		{"a constant", {shader = &codes[0], constants = {0}, name = "a"}, false},
		{"another constant", {shader = &codes[0], constants = {1}, name = "a"}, false},
	}) {
		testing.expectf(t, (pipeline_key_compute(c.desc) == key) == c.same, "%s", c.name)
	}
	testing.expect(t, pipeline_key_compute({shader = &codes[0], constants = {0}}) != pipeline_key_compute({shader = &codes[0], constants = {1}}), "each constant is a pipeline of its own")
	graphics := Graphics_Pipeline_Desc{vertex = &codes[0], fragment = &codes[1], color_formats = {0 = .RGBA8_Unorm}, color_count = 1, name = "a"}
	graphics_key := pipeline_key_graphics(graphics)
	Graphics_Case :: struct {name: string, vertex, fragment: Shader_Constants, cull: Cull_Mode, same: bool}
	for c in ([]Graphics_Case{
		{"the same", {}, {}, .None, true},
		{"a constant of the vertex stage", {0}, {}, .None, false},
		{"a constant of the fragment stage", {}, {0}, .None, false},
		{"another state", {}, {}, .Back, false},
	}) {
		desc := graphics
		desc.vertex_constants, desc.fragment_constants, desc.cull, desc.name = c.vertex, c.fragment, c.cull, "b"
		testing.expectf(t, (pipeline_key_graphics(desc) == graphics_key) == c.same, "%s", c.name)
	}
	vertex, fragment := graphics, graphics
	vertex.vertex_constants, fragment.fragment_constants = {0}, {0}
	testing.expect(t, pipeline_key_graphics(vertex) != pipeline_key_graphics(fragment), "a constant belongs to its stage")
}

// A shader names its constants by id, as far as a pipeline can set them.
@(test)
shader_constant_is_found_by_its_name :: proc(t: ^testing.T) {
	code := Shader_Code{constants = {"color", "unlayered"}}
	Case :: struct {name: string, found: bool, constants: Shader_Constants}
	for c in ([]Case{{"color", true, {0}}, {"unlayered", true, {1}}, {"", false, {}}, {"Color", false, {}}, {"colo", false, {}}}) {
		constants, found := shader_constant(&code, c.name)
		testing.expectf(t, found == c.found && constants == c.constants, "%q", c.name)
	}
	_, of_none := shader_constant(nil, "color")
	testing.expect(t, !of_none, "no shader has no constants")
	// More names than a pipeline sets: those past the limit are not found.
	many: [MAX_SHADER_CONSTANTS + 2]string
	for &name, i in many {name = fmt.tprintf("c%d", i)}
	crowded := Shader_Code{constants = many[:]}
	last, last_found := shader_constant(&crowded, fmt.tprintf("c%d", MAX_SHADER_CONSTANTS - 1))
	testing.expect(t, last_found && last == Shader_Constants{MAX_SHADER_CONSTANTS - 1})
	_, past := shader_constant(&crowded, fmt.tprintf("c%d", MAX_SHADER_CONSTANTS))
	testing.expect(t, !past, "a constant past the limit is not one a pipeline sets")
}
