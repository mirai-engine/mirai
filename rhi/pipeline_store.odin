package rhi

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:slice"
import "core:sync"
import "mirai:std/base"
import "mirai:std/serial"

// The compiled pipelines of a device kept across runs: one driver blob per
// pipeline, under a key of what the pipeline compiles. A run writes back the
// blobs it used and, while they fit, those of earlier runs still young, so
// pipelines of shaders that changed age out. The file belongs to one device and
// driver; that of another is discarded whole, as is a file that does not read
// back exactly.
PIPELINE_STORE_MAGIC :: u32(0x5350_494d) // "MIPS"
PIPELINE_STORE_VERSION :: u32(1)
PIPELINE_STORE_BYTES :: 256 << 20 // the most a store file holds, and the blobs a run adds in memory
PIPELINE_STORE_RUNS :: 8          // runs an entry stays in the file without being used

// What a driver blob is valid for: the device, its driver, and the cache UUID
// the driver gives its blobs.
Pipeline_Device :: struct {
	vendor, device, driver: u32,
	uuid:                   [16]u8,
}

Pipeline_Entry :: struct {
	key:   u64,
	data:  []u8,
	age:   u32, // runs since one used it
	used:  u64, // when this run used it, counted in uses of the store; 0 = not used
	owned: bool, // data was allocated for it; else it points into Pipeline_Store.file
}

Pipeline_Store :: struct {
	device:    Pipeline_Device,
	limit:     int, // the most bytes of the file, and of the blobs this run uses
	file:      []u8,
	entries:   [dynamic]Pipeline_Entry,
	owned:     int, // bytes of the blobs of this run
	reused:    int, // bytes of the blobs of the file this run used
	uses:      u64,
	lock:      sync.Mutex, // pipelines are created on several threads
	allocator: runtime.Allocator,
}

@(private = "file")
STORE_HEADER :: 40
@(private = "file")
ENTRY_HEADER :: 24

pipeline_store_init :: proc(s: ^Pipeline_Store, device: Pipeline_Device, limit := PIPELINE_STORE_BYTES, allocator := context.allocator) {
	s^ = {device = device, limit = limit, allocator = allocator}
	s.entries.allocator = allocator
}

pipeline_store_destroy :: proc(s: ^Pipeline_Store) {
	for e in s.entries {if e.owned {delete(e.data, s.allocator)}}
	delete(s.entries)
	delete(s.file, s.allocator)
	s^ = {}
}

// Reads the store of path, after removing what processes that ended left of
// their writes. A file that is missing, too large, of another device or
// version, or that does not read back exactly leaves the store empty: the next
// save replaces it.
pipeline_store_load :: proc(s: ^Pipeline_Store, path: string) {
	serial.file_remove_stale(path)
	data, error := serial.file_read(path, s.allocator, limit = i64(s.limit))
	if error != .None || data == nil {return}
	if !pipeline_store_decode(s, data) {delete(data, s.allocator)}
}

// Takes data as the file of the store when it is valid for its device.
pipeline_store_decode :: proc(s: ^Pipeline_Store, data: []u8) -> bool {
	if len(data) < STORE_HEADER || len(data) > s.limit {return false}
	if store_read_u32(data, 0) != PIPELINE_STORE_MAGIC || store_read_u32(data, 4) != PIPELINE_STORE_VERSION {return false}
	device := Pipeline_Device{vendor = store_read_u32(data, 8), device = store_read_u32(data, 12), driver = store_read_u32(data, 16)}
	copy(device.uuid[:], data[24:40])
	if device != s.device {return false}
	count := int(store_read_u32(data, 20))
	if count > (len(data) - STORE_HEADER) / ENTRY_HEADER {return false}
	entries, error := make([dynamic]Pipeline_Entry, 0, count, s.allocator)
	if error != nil {return false}
	at := STORE_HEADER
	for _ in 0 ..< count {
		if len(data) - at < ENTRY_HEADER {delete(entries); return false}
		key, check, age, size := store_read_u64(data, at), store_read_u64(data, at + 8), store_read_u32(data, at + 16), int(store_read_u32(data, at + 20))
		at += ENTRY_HEADER
		if size == 0 || size > len(data) - at || age >= PIPELINE_STORE_RUNS {delete(entries); return false}
		blob := data[at:][:size]
		at += size
		if base.hash64(blob) != check || pipeline_store_index(entries[:], key) >= 0 {delete(entries); return false}
		append(&entries, Pipeline_Entry{key = key, data = blob, age = age})
	}
	if at != len(data) {delete(entries); return false}
	for e in s.entries {if e.owned {delete(e.data, s.allocator)}}
	delete(s.entries)
	delete(s.file, s.allocator)
	s.entries, s.file, s.owned, s.reused = entries, data, 0, 0
	return true
}

@(private = "file")
pipeline_store_index :: proc(entries: []Pipeline_Entry, key: u64) -> int {
	for e, i in entries {if e.key == key {return i}}
	return -1
}

// The blob of key, marked as used by this run; nil without one. The caller
// holds s.lock while it reads the blob.
pipeline_store_find :: proc(s: ^Pipeline_Store, key: u64) -> []u8 {
	i := pipeline_store_index(s.entries[:], key)
	if i < 0 {return nil}
	e := &s.entries[i]
	if !e.owned && e.used == 0 {s.reused += len(e.data)}
	s.uses += 1
	e.used = s.uses
	return e.data
}

// Keeps a blob of this run, allocated with s.allocator, which the store then
// owns, under key. Past the limit, with what the run used of the file, the
// oldest blobs of this run go first; one that does not fit at all is freed.
pipeline_store_put :: proc(s: ^Pipeline_Store, key: u64, data: []u8) {
	if i := pipeline_store_index(s.entries[:], key); i >= 0 {pipeline_store_drop(s, i)}
	if len(data) == 0 || len(data) > s.limit - s.reused {delete(data, s.allocator); return}
	for s.owned + len(data) > s.limit - s.reused {
		oldest := -1
		for e, i in s.entries {if e.owned && (oldest < 0 || e.used < s.entries[oldest].used) {oldest = i}}
		pipeline_store_drop(s, oldest)
	}
	s.uses += 1
	if _, error := append(&s.entries, Pipeline_Entry{key = key, data = data, used = s.uses, owned = true}); error != nil {
		delete(data, s.allocator)
		return
	}
	s.owned += len(data)
}

@(private = "file")
pipeline_store_drop :: proc(s: ^Pipeline_Store, i: int) {
	e := s.entries[i]
	if e.owned {delete(e.data, s.allocator); s.owned -= len(e.data)} else if e.used != 0 {s.reused -= len(e.data)}
	unordered_remove(&s.entries, i)
}

// The file the next run reads: the entries this run used, the last used
// first, then those of earlier runs, the youngest first, while they fit in
// s.limit; nil when nothing goes in it. Not ok without memory.
pipeline_store_encode :: proc(s: ^Pipeline_Store, allocator := context.allocator) -> (out: []u8, ok: bool) {
	order, order_error := make([]Pipeline_Entry, len(s.entries), context.temp_allocator)
	if order_error != nil {return nil, false}
	copy(order, s.entries[:])
	slice.sort_by(order, proc(a, b: Pipeline_Entry) -> bool {
		if (a.used != 0) != (b.used != 0) {return a.used != 0}
		return a.used > b.used if a.used != 0 else a.age < b.age
	})
	size, count := STORE_HEADER, 0
	for &e in order {
		if e.used == 0 && e.age + 1 >= PIPELINE_STORE_RUNS || ENTRY_HEADER + len(e.data) > s.limit - size {e.data = nil; continue}
		size += ENTRY_HEADER + len(e.data)
		count += 1
	}
	if count == 0 {return nil, true}
	error: runtime.Allocator_Error
	out, error = make([]u8, size, allocator)
	if error != nil {return nil, false}
	store_write_u32(out, 0, PIPELINE_STORE_MAGIC)
	store_write_u32(out, 4, PIPELINE_STORE_VERSION)
	store_write_u32(out, 8, s.device.vendor)
	store_write_u32(out, 12, s.device.device)
	store_write_u32(out, 16, s.device.driver)
	store_write_u32(out, 20, u32(count))
	copy(out[24:40], s.device.uuid[:])
	at := STORE_HEADER
	for e in order {
		if e.data == nil {continue}
		store_write_u64(out, at, e.key)
		store_write_u64(out, at + 8, base.hash64(e.data))
		store_write_u32(out, at + 16, 0 if e.used != 0 else e.age + 1)
		store_write_u32(out, at + 20, u32(len(e.data)))
		copy(out[at + ENTRY_HEADER:], e.data)
		at += ENTRY_HEADER + len(e.data)
	}
	return out, true
}

// Replaces the file of path with what pipeline_store_encode gives, in one
// rename; with nothing to keep it removes it.
pipeline_store_save :: proc(s: ^Pipeline_Store, path: string) -> bool {
	data, ok := pipeline_store_encode(s, s.allocator)
	defer delete(data, s.allocator)
	if !ok {return false}
	if data == nil {return os.remove(path) == nil || !os.exists(path)}
	return serial.file_write_atomic(path, data) == .None
}

// The keys of pipelines: what the driver compiles of them, never their names.
pipeline_key_compute :: proc(desc: Compute_Pipeline_Desc) -> u64 {
	return base.hash64(shader_code_bytes(desc.shader^), u64(Shader_Stage.Compute) + 1)
}

pipeline_key_graphics :: proc(desc: Graphics_Pipeline_Desc) -> u64 {
	State :: struct #packed {
		formats:                    [MAX_COLOR_TARGETS]Format,
		blend:                      [MAX_COLOR_TARGETS]Blend_Mode,
		count:                      u8,
		depth_format:               Format,
		depth_test, depth_write:    bool,
		depth_compare:              Compare,
		cull:                       Cull_Mode,
		topology:                   Topology,
	}
	state := State{depth_format = desc.depth_format, depth_test = desc.depth_test, depth_write = desc.depth_write, cull = desc.cull, topology = desc.topology}
	if desc.depth_test {state.depth_compare = desc.depth_compare}
	count := clamp(desc.color_count, 0, MAX_COLOR_TARGETS)
	state.count = u8(count)
	formats, blend := desc.color_formats, desc.blend
	copy(state.formats[:count], formats[:count])
	copy(state.blend[:count], blend[:count])
	key := base.hash64(shader_code_bytes(desc.vertex^))
	key = base.hash64(shader_code_bytes(desc.fragment^), key)
	return base.hash64(([^]u8)(&state)[:size_of(state)], key)
}

@(private)
store_read_u32 :: #force_inline proc "contextless" (data: []u8, at: int) -> u32 {return u32(intrinsics.unaligned_load((^u32le)(&data[at])))}
@(private)
store_read_u64 :: #force_inline proc "contextless" (data: []u8, at: int) -> u64 {return u64(intrinsics.unaligned_load((^u64le)(&data[at])))}
@(private)
store_write_u32 :: #force_inline proc "contextless" (data: []u8, at: int, value: u32) {intrinsics.unaligned_store((^u32le)(&data[at]), u32le(value))}
@(private)
store_write_u64 :: #force_inline proc "contextless" (data: []u8, at: int, value: u64) {intrinsics.unaligned_store((^u64le)(&data[at]), u64le(value))}
