package rhi

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:slice"
import "core:sync"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

// The compiled pipelines of a device kept across runs: one driver blob per
// pipeline, under a key of what the pipeline compiles. A run writes back the
// blobs it used and, while they fit, those of earlier runs still young, so
// pipelines of shaders that changed age out. The file belongs to one device and
// driver; that of another is discarded whole, as is a file that does not read
// back exactly.
//
// A driver puts in the blob of each pipeline what all of them share (NVIDIA a
// dictionary of megabytes), so blobs are kept as chunks cut by their content,
// each stored once: the same bytes give the same chunks wherever they sit.
//
// The file is written while the run adds to it, so a run that crashes, is
// killed or loses its device keeps what it compiled; each write takes in what
// another process wrote there meanwhile.
PIPELINE_STORE_MAGIC :: u32(0x5350_494d) // "MIPS"
PIPELINE_STORE_VERSION :: u32(2)
PIPELINE_STORE_BYTES :: 256 << 20 // the most a store file holds, and the chunks a run adds in memory
PIPELINE_STORE_RUNS :: 8          // runs an entry stays in the file without being used
PIPELINE_STORE_SAVE_PARTS :: 64   // the file is written each time a run added this part of the limit
PIPELINE_CHUNK_MIN :: 2 << 10
PIPELINE_CHUNK_MAX :: 64 << 10
PIPELINE_CHUNK_BITS :: 13         // a cut after PIPELINE_CHUNK_MIN has 1 chance in 2^13 per byte

// What a driver blob is valid for: the device, its driver, and the cache UUID
// the driver gives its blobs.
Pipeline_Device :: struct {
	vendor, device, driver: u32,
	uuid:                   [16]u8,
}

Pipeline_Chunk :: struct {
	id:    [2]u64, // base.hash128 of data
	data:  []u8,   // nil once no entry holds it
	refs:  int,    // entries that hold it
	owned: bool,   // data was allocated for it; else it points into Pipeline_Store.file
}

Pipeline_Entry :: struct {
	key:    u64,
	chunks: []u32, // indices into Pipeline_Store.chunks, in the order of the blob
	size:   int,   // bytes of the blob
	age:    u32,   // runs since one used it
	used:   u64,   // when this run used it, counted in uses of the store; 0 = not used
}

Pipeline_Store :: struct {
	device:    Pipeline_Device,
	limit:     int, // the most bytes of the file, and of the chunks this run adds
	file:      []u8,
	chunks:    [dynamic]Pipeline_Chunk,
	by_id:     base.Hash_Map(u32), // id[0] of a chunk that holds data -> its index
	entries:   [dynamic]Pipeline_Entry,
	owned:     int, // bytes of the chunks this run added
	unsaved:   int, // bytes of the chunks added since the file was written
	uses:      u64,
	gear:      [256]u64, // the value of each byte in the rolling hash that cuts chunks
	lock:      sync.Mutex, // pipelines are created on several threads
	saving:    bool,       // a thread writes the file; another that would skips
	stamp:     [2]i64,     // modification time and size of the file as this store last read or wrote it
	allocator: runtime.Allocator,
}

@(private = "file")
STORE_HEADER :: 48
@(private = "file")
CHUNK_HEADER :: 24
@(private = "file")
ENTRY_HEADER :: 16

pipeline_store_init :: proc(s: ^Pipeline_Store, device: Pipeline_Device, limit := PIPELINE_STORE_BYTES, allocator := context.allocator) {
	s^ = {device = device, limit = limit, allocator = allocator}
	s.chunks.allocator = allocator
	s.entries.allocator = allocator
	for &g, i in s.gear {g = base.hash_u64(u64(i) + 1)}
}

pipeline_store_destroy :: proc(s: ^Pipeline_Store) {
	pipeline_store_clear(s)
	delete(s.file, s.allocator)
	s^ = {}
}

@(private = "file")
pipeline_store_clear :: proc(s: ^Pipeline_Store) {
	for c in s.chunks {if c.owned {delete(c.data, s.allocator)}}
	for e in s.entries {delete(e.chunks, s.allocator)}
	delete(s.chunks)
	delete(s.entries)
	base.hash_map_destroy(&s.by_id)
	s.chunks, s.entries, s.owned, s.unsaved = {}, {}, 0, 0
	s.chunks.allocator = s.allocator
	s.entries.allocator = s.allocator
}

// Reads the store of path, after removing what processes that ended left of
// their writes. A file that is missing, too large, of another device or
// version, or that does not read back exactly leaves the store empty: the next
// save replaces it.
pipeline_store_load :: proc(s: ^Pipeline_Store, path: string) {
	serial.file_remove_stale(path)
	s.stamp = pipeline_file_stamp(path, s.allocator)
	data, error := serial.file_read(path, s.allocator, limit = i64(s.limit))
	if error != .None || data == nil {return}
	if !pipeline_store_decode(s, data) {delete(data, s.allocator)}
}

@(private = "file")
pipeline_file_stamp :: proc(path: string, allocator: runtime.Allocator) -> [2]i64 {
	info, error := os.stat(path, allocator)
	if error != nil {return {}}
	defer os.file_info_delete(info, allocator)
	return {time.to_unix_nanoseconds(info.modification_time), info.size}
}

// Takes data as the file of the store when it is valid for its device.
pipeline_store_decode :: proc(s: ^Pipeline_Store, data: []u8) -> bool {
	if len(data) < STORE_HEADER || len(data) > s.limit {return false}
	if store_read_u32(data, 0) != PIPELINE_STORE_MAGIC || store_read_u32(data, 4) != PIPELINE_STORE_VERSION {return false}
	device := Pipeline_Device{vendor = store_read_u32(data, 8), device = store_read_u32(data, 12), driver = store_read_u32(data, 16)}
	copy(device.uuid[:], data[32:48])
	if device != s.device {return false}
	chunk_count, entry_count := int(store_read_u32(data, 20)), int(store_read_u32(data, 24))
	if chunk_count > (len(data) - STORE_HEADER) / CHUNK_HEADER || entry_count > (len(data) - STORE_HEADER) / ENTRY_HEADER {return false}
	pipeline_store_clear(s)
	if !pipeline_store_decode_into(s, data, chunk_count, entry_count) {pipeline_store_clear(s); return false}
	delete(s.file, s.allocator)
	s.file = data
	return true
}

@(private = "file")
pipeline_store_decode_into :: proc(s: ^Pipeline_Store, data: []u8, chunk_count, entry_count: int) -> bool {
	if reserve(&s.chunks, chunk_count) != nil || reserve(&s.entries, entry_count) != nil {return false}
	if !base.hash_map_init(&s.by_id, max(chunk_count, 1), s.allocator) {return false}
	at := STORE_HEADER
	for _ in 0 ..< chunk_count {
		if len(data) - at < CHUNK_HEADER {return false}
		id := [2]u64{store_read_u64(data, at), store_read_u64(data, at + 8)}
		size := int(store_read_u32(data, at + 16))
		at += CHUNK_HEADER
		if size == 0 || size > PIPELINE_CHUNK_MAX || size > len(data) - at {return false}
		chunk := data[at:][:size]
		at += size
		if base.hash128(chunk) != id || base.hash_map_contains(&s.by_id, id[0]) {return false}
		if !base.hash_map_set(&s.by_id, id[0], u32(len(s.chunks))) {return false}
		append(&s.chunks, Pipeline_Chunk{id = id, data = chunk})
	}
	for _ in 0 ..< entry_count {
		if len(data) - at < ENTRY_HEADER {return false}
		key, age, count := store_read_u64(data, at), store_read_u32(data, at + 8), int(store_read_u32(data, at + 12))
		at += ENTRY_HEADER
		if count == 0 || count > (len(data) - at) / 4 || age >= PIPELINE_STORE_RUNS || pipeline_store_index(s, key) >= 0 {return false}
		chunks, error := make([]u32, count, s.allocator)
		if error != nil {return false}
		size := 0
		for &c in chunks {
			c = store_read_u32(data, at)
			at += 4
			if int(c) >= len(s.chunks) {delete(chunks, s.allocator); return false}
			size += len(s.chunks[c].data)
		}
		for c in chunks {s.chunks[c].refs += 1}
		append(&s.entries, Pipeline_Entry{key = key, chunks = chunks, size = size, age = age})
	}
	if at != len(data) {return false}
	for c in s.chunks {if c.refs == 0 {return false}}
	return true
}

@(private = "file")
pipeline_store_index :: proc(s: ^Pipeline_Store, key: u64) -> int {
	for e, i in s.entries {if e.key == key {return i}}
	return -1
}

// A copy of the blob of key, in allocator, marked as used by this run; nil
// without one or without memory.
pipeline_store_find :: proc(s: ^Pipeline_Store, key: u64, allocator := context.allocator) -> []u8 {
	i := pipeline_store_index(s, key)
	if i < 0 {return nil}
	e := &s.entries[i]
	blob, error := make([]u8, e.size, allocator)
	if error != nil {return nil}
	at := 0
	for c in e.chunks {at += copy(blob[at:], s.chunks[c].data)}
	s.uses += 1
	e.used = s.uses
	return blob
}

// The length of the chunk data starts with: where the rolling hash of the last
// 64 bytes has its top PIPELINE_CHUNK_BITS clear, between PIPELINE_CHUNK_MIN
// and PIPELINE_CHUNK_MAX.
pipeline_chunk_length :: proc(gear: ^[256]u64, data: []u8) -> int {
	end := min(len(data), PIPELINE_CHUNK_MAX)
	if end <= PIPELINE_CHUNK_MIN {return end}
	h: u64
	for i in max(PIPELINE_CHUNK_MIN - 64, 0) ..< end {
		h = h << 1 + gear[data[i]]
		if i + 1 >= PIPELINE_CHUNK_MIN && h >> (64 - PIPELINE_CHUNK_BITS) == 0 {return i + 1}
	}
	return end
}

// Keeps a copy of data, the blob of this run for key. Past the limit the
// pipelines this run used longest ago go first; a blob that does not fit at all
// is not kept. due: what was added since the file was written calls for
// pipeline_store_save.
pipeline_store_put :: proc(s: ^Pipeline_Store, key: u64, data: []u8) -> (due: bool) {
	if i := pipeline_store_index(s, key); i >= 0 {pipeline_store_drop(s, i)}
	if len(data) == 0 || len(data) > s.limit {return}
	for s.owned + len(data) > s.limit {
		oldest := -1
		for e, i in s.entries {
			if e.used != 0 && pipeline_store_owns(s, e) && (oldest < 0 || e.used < s.entries[oldest].used) {oldest = i}
		}
		if oldest < 0 {break}
		pipeline_store_drop(s, oldest)
	}
	count := 0
	for at := 0; at < len(data); count += 1 {at += pipeline_chunk_length(&s.gear, data[at:])}
	chunks, error := make([]u32, count, s.allocator)
	if error != nil {return}
	at := 0
	for &c, n in chunks {
		length := pipeline_chunk_length(&s.gear, data[at:])
		index, ok := pipeline_store_chunk(s, data[at:][:length])
		if !ok {
			for taken in chunks[:n] {pipeline_store_release(s, taken)}
			delete(chunks, s.allocator)
			return
		}
		c = index
		at += length
	}
	s.uses += 1
	if _, append_error := append(&s.entries, Pipeline_Entry{key = key, chunks = chunks, size = len(data), used = s.uses}); append_error != nil {
		for c in chunks {pipeline_store_release(s, c)}
		delete(chunks, s.allocator)
		return
	}
	return s.unsaved >= s.limit / PIPELINE_STORE_SAVE_PARTS
}

@(private = "file")
pipeline_store_owns :: proc(s: ^Pipeline_Store, e: Pipeline_Entry) -> bool {
	for c in e.chunks {if s.chunks[c].owned {return true}}
	return false
}

// The index of a chunk with those bytes, held once more: the one the store has,
// or a copy. Not ok without memory.
@(private = "file")
pipeline_store_chunk :: proc(s: ^Pipeline_Store, bytes: []u8) -> (index: u32, ok: bool) {
	id := base.hash128(bytes)
	if found, exists := base.hash_map_get(&s.by_id, id[0]); exists && s.chunks[found].id == id {
		s.chunks[found].refs += 1
		return found, true
	}
	if s.by_id.keys == nil {
		if !base.hash_map_init(&s.by_id, 64, s.allocator) {return 0, false}
	} else if s.by_id.count >= s.by_id.capacity && !base.hash_map_grow(&s.by_id, 2 * s.by_id.capacity) {return 0, false}
	data, error := make([]u8, len(bytes), s.allocator)
	if error != nil {return 0, false}
	copy(data, bytes)
	index = u32(len(s.chunks))
	if _, append_error := append(&s.chunks, Pipeline_Chunk{id = id, data = data, refs = 1, owned = true}); append_error != nil {
		delete(data, s.allocator)
		return 0, false
	}
	// Another chunk with the same id[0] keeps the slot: this one is only not shared.
	if !base.hash_map_contains(&s.by_id, id[0]) {base.hash_map_set(&s.by_id, id[0], index)}
	s.owned += len(data)
	s.unsaved += len(data)
	return index, true
}

@(private = "file")
pipeline_store_release :: proc(s: ^Pipeline_Store, index: u32) {
	c := &s.chunks[index]
	c.refs -= 1
	if c.refs > 0 {return}
	if found, exists := base.hash_map_get(&s.by_id, c.id[0]); exists && found == index {base.hash_map_remove(&s.by_id, c.id[0])}
	if c.owned {
		s.owned -= len(c.data)
		delete(c.data, s.allocator)
	}
	c.data, c.owned = nil, false
}

@(private = "file")
pipeline_store_drop :: proc(s: ^Pipeline_Store, i: int) {
	e := s.entries[i]
	for c in e.chunks {pipeline_store_release(s, c)}
	delete(e.chunks, s.allocator)
	unordered_remove(&s.entries, i)
}

// The file the next run reads: the entries this run used, the last used
// first, then those of earlier runs, the youngest first, while they fit in
// s.limit, each chunk once; nil when nothing goes in it. Not ok without memory.
pipeline_store_encode :: proc(s: ^Pipeline_Store, allocator := context.allocator) -> (out: []u8, ok: bool) {
	order, order_error := make([]Pipeline_Entry, len(s.entries), context.temp_allocator)
	// The index in the file of each chunk that goes in it, plus one; 0: it does not.
	placed, placed_error := make([]u32, len(s.chunks), context.temp_allocator)
	if order_error != nil || placed_error != nil {return nil, false}
	copy(order, s.entries[:])
	slice.sort_by(order, proc(a, b: Pipeline_Entry) -> bool {
		if (a.used != 0) != (b.used != 0) {return a.used != 0}
		return a.used > b.used if a.used != 0 else a.age < b.age
	})
	size, chunk_count, entry_count := STORE_HEADER, 0, 0
	for &e in order {
		cost := ENTRY_HEADER + 4 * len(e.chunks)
		for c, n in e.chunks {
			if placed[c] != 0 || slice.contains(e.chunks[:n], c) {continue}
			cost += CHUNK_HEADER + len(s.chunks[c].data)
		}
		if e.used == 0 && e.age + 1 >= PIPELINE_STORE_RUNS || cost > s.limit - size {e.chunks = nil; continue}
		for c in e.chunks {
			if placed[c] == 0 {chunk_count += 1; placed[c] = u32(chunk_count)}
		}
		size += cost
		entry_count += 1
	}
	if entry_count == 0 {return nil, true}
	error: runtime.Allocator_Error
	out, error = make([]u8, size, allocator)
	if error != nil {return nil, false}
	store_write_u32(out, 0, PIPELINE_STORE_MAGIC)
	store_write_u32(out, 4, PIPELINE_STORE_VERSION)
	store_write_u32(out, 8, s.device.vendor)
	store_write_u32(out, 12, s.device.device)
	store_write_u32(out, 16, s.device.driver)
	store_write_u32(out, 20, u32(chunk_count))
	store_write_u32(out, 24, u32(entry_count))
	copy(out[32:48], s.device.uuid[:])
	// Chunks in the order they were placed.
	sorted, sorted_error := make([]u32, chunk_count, context.temp_allocator)
	if sorted_error != nil {delete(out, allocator); return nil, false}
	for p, c in placed {if p != 0 {sorted[p - 1] = u32(c)}}
	at := STORE_HEADER
	for c in sorted {
		chunk := s.chunks[c]
		store_write_u64(out, at, chunk.id[0])
		store_write_u64(out, at + 8, chunk.id[1])
		store_write_u32(out, at + 16, u32(len(chunk.data)))
		copy(out[at + CHUNK_HEADER:], chunk.data)
		at += CHUNK_HEADER + len(chunk.data)
	}
	for e in order {
		if e.chunks == nil {continue}
		store_write_u64(out, at, e.key)
		store_write_u32(out, at + 8, 0 if e.used != 0 else e.age + 1)
		store_write_u32(out, at + 12, u32(len(e.chunks)))
		at += ENTRY_HEADER
		for c in e.chunks {store_write_u32(out, at, placed[c] - 1); at += 4}
	}
	return out, true
}

// Replaces the file of path with what pipeline_store_encode gives, in one
// rename; with nothing to keep it removes it. The entries another process
// wrote to the file since this store read or wrote it are taken in first, as
// of earlier runs, while this run's additions leave room. Takes s.lock; one
// save runs at a time, and one asked meanwhile is skipped: false.
pipeline_store_save :: proc(s: ^Pipeline_Store, path: string) -> bool {
	if _, first := sync.atomic_compare_exchange_strong(&s.saving, false, true); !first {return false}
	defer sync.atomic_store(&s.saving, false)
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	theirs: Pipeline_Store
	stamp := pipeline_file_stamp(path, s.allocator)
	if stamp != s.stamp && stamp != {} {
		pipeline_store_init(&theirs, s.device, s.limit, s.allocator)
		pipeline_store_load(&theirs, path)
	}
	defer pipeline_store_destroy(&theirs)
	sync.lock(&s.lock)
	for e in theirs.entries {
		if pipeline_store_index(s, e.key) >= 0 || s.owned + e.size > s.limit {continue}
		blob := pipeline_store_find(&theirs, e.key, s.allocator)
		if blob == nil {continue}
		pipeline_store_put(s, e.key, blob)
		delete(blob, s.allocator)
		if n := len(s.entries); n > 0 && s.entries[n - 1].key == e.key {s.entries[n - 1].used, s.entries[n - 1].age = 0, e.age}
	}
	data, ok := pipeline_store_encode(s, s.allocator)
	s.unsaved = 0
	sync.unlock(&s.lock)
	defer delete(data, s.allocator)
	if !ok {return false}
	if data == nil {return os.remove(path) == nil || !os.exists(path)}
	if serial.file_write_atomic(path, data) != .None {return false}
	s.stamp = pipeline_file_stamp(path, s.allocator)
	return true
}

// The keys of pipelines: what the driver compiles of them, never their names.
pipeline_key_compute :: proc(desc: Compute_Pipeline_Desc) -> u64 {
	constants := desc.constants
	return base.hash64(([^]u8)(&constants)[:size_of(constants)], base.hash64(shader_code_bytes(desc.shader^), u64(Shader_Stage.Compute) + 1))
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
		constants:                  [2]Shader_Constants,
	}
	state := State{depth_format = desc.depth_format, depth_test = desc.depth_test, depth_write = desc.depth_write, cull = desc.cull, topology = desc.topology,
		constants = {desc.vertex_constants, desc.fragment_constants}}
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
