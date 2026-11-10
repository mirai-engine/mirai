package mirai_render

import "core:mem"
import "mirai:rhi"
import "mirai:std/base"

// What an extension keeps on the GPU from one frame to the next, and what it
// counts there. A buffer of an extension belongs to a world: the renderer
// keeps it under its name until the extension releases it (buffer_release),
// so the state of a world that is not drawn waits, still, for its next frame.
// Asking for it with another size makes it again. Making one is a load
// transaction that happens the first time a pass asks: a stable frame makes
// nothing. The draws and dispatches of an extension read their arguments
// from them.

Extension_Buffer_Desc :: struct {
	name: string,
	size: u64, // bytes, a multiple of 4
}

EXTENSION_BUFFER_CAPACITY :: 64

@(private)
Extension_Buffer :: struct {
	key:    u64, // of its name; 0: a free place
	world:  u64,
	size:   u64,
	buffer: rhi.Buffer,
}

// The buffer of a world under a description, made the first time and made
// again with another size. made: it was, and what it holds is not known.
// nil when the device does not take it, or there is no room for another.
@(private)
extension_buffer :: proc(r: ^Renderer, world: u64, desc: Extension_Buffer_Desc) -> (entry: ^Extension_Buffer, made: bool) {
	if desc.size == 0 || desc.size % 4 != 0 {set_error(r, "extension buffer %s: give it a size that is a multiple of 4 bytes", desc.name); return}
	key := base.name_hash(desc.name) | 1
	free: ^Extension_Buffer
	for &place in r.extension_buffers {
		if place.key == key && place.world == world {entry = &place; break}
		if place.key == 0 && free == nil {free = &place}
	}
	if entry != nil && entry.size == desc.size {return entry, false}
	if desc.size > rhi.device_info(r.device).max_storage_range {
		set_error(r, "extension buffer %s: %d bytes are more than the device binds", desc.name, desc.size)
		return nil, false
	}
	if entry != nil {
		rhi.buffer_destroy(r.device, entry.buffer)
		entry^ = {}
	} else if free == nil {
		set_error(r, "extension buffer %s: the renderer has no room for more than %d", desc.name, EXTENSION_BUFFER_CAPACITY)
		return nil, false
	} else {
		entry = free
	}
	buffer := rhi.buffer_create(r.device, {size = desc.size, usage = {.Storage, .Indirect}, name = "extension buffer"})
	if buffer == 0 {
		set_error(r, "extension buffer %s: %s", desc.name, rhi.device_error(r.device))
		return nil, false
	}
	entry^ = {key = key, world = world, size = desc.size, buffer = buffer}
	return entry, true
}

// The buffer of a world under a description as it was made; nil without one.
@(private)
extension_buffer_find :: proc(r: ^Renderer, world: u64, desc: Extension_Buffer_Desc) -> ^Extension_Buffer {
	key := base.name_hash(desc.name) | 1
	for &entry in r.extension_buffers {
		if entry.key == key && entry.world == world {return &entry if entry.size == desc.size else nil}
	}
	return nil
}

// Binds the buffer of the world of the frame under a description at
// SLOT_PASS0 + slot, for the dispatches and draws of the pass. made: the
// renderer made it now, the first time or with another size, and what it
// holds is not known. False when the device does not take it.
pass_buffer :: proc(s: ^Stage_Pass, slot: u32, desc: Extension_Buffer_Desc) -> (ok, made: bool) {
	if slot > SLOT_PASS9 - SLOT_PASS0 {return}
	entry: ^Extension_Buffer
	if entry, made = extension_buffer(s.pass.r, s.world, desc); entry == nil {return}
	rhi.cmd_bind_buffer(s.pass.cmd, SLOT_PASS0 + slot, entry.buffer)
	return true, made
}

// Whether the world holds a buffer under a description, with that size.
pass_buffer_held :: proc(s: ^Stage_Pass, desc: Extension_Buffer_Desc) -> bool {
	return extension_buffer_find(s.pass.r, s.world, desc) != nil
}

// Copies bytes into a buffer of the world at offset, through the memory of
// the frame, outside a render pass: the extension keeps no buffer of its own
// to upload from. False for a buffer pass_buffer did not make with that
// size, and when they do not fit in it or in the memory of the frame.
pass_buffer_write :: proc(s: ^Stage_Pass, desc: Extension_Buffer_Desc, offset: u64, data: rawptr, size: int) -> bool {
	if data == nil || size <= 0 || offset % 4 != 0 || size % 4 != 0 || offset + u64(size) > desc.size {return false}
	entry := extension_buffer_find(s.pass.r, s.world, desc)
	if entry == nil {return false}
	rows := rhi.frame_alloc(s.pass.r.device, u64(size), 16)
	if rows.ptr == nil {return false}
	mem.copy(rows.ptr, data, size)
	rhi.cmd_copy_buffer(s.pass.cmd, rows.buffer, rows.offset, entry.buffer, offset, u64(size))
	return true
}

// Sets size bytes of a buffer of the world from offset to value, outside a
// render pass.
pass_buffer_fill :: proc(s: ^Stage_Pass, desc: Extension_Buffer_Desc, offset, size: u64, value: u8 = 0) -> bool {
	if offset % 4 != 0 || size % 4 != 0 || offset + size > desc.size {return false}
	entry := extension_buffer_find(s.pass.r, s.world, desc)
	if entry == nil {return false}
	rhi.cmd_fill_buffer(s.pass.cmd, entry.buffer, offset, size, value)
	return true
}

// Dispatches with the group counts a buffer of the world holds at offset
// (three u32), as a dispatch before wrote them.
pass_dispatch_indirect :: proc(s: ^Stage_Pass, desc: Extension_Buffer_Desc, offset: u64) {
	if entry := extension_buffer_find(s.pass.r, s.world, desc); entry != nil {rhi.cmd_dispatch_indirect(s.pass.cmd, entry.buffer, offset)}
}

// A part of the room for lights that a pass writes on the GPU each frame
// (light_tree.odin): its lights from first_light, capacity of them, and one
// of none after them; its nodes from root, the tree of the capacity leaves as
// light_tree.odin lays one out, then at root + 2*capacity - 1 a leaf of the
// light of none. A capacity of 0: the room has no such part.
Pass_Light_Part :: struct {
	first_light, capacity, root: u32,
}

// The room: the lights that cast shadows, whose tree starts at 1, under node
// 0, the root of them and of the scene, which takes what its two children
// give, as light_tree_group does; and those that do not, in a tree no
// traversal of shadows meets. scene_root: the root of the lights of the
// scene, or the leaf of none of the part with shadows without them.
Pass_Lights :: struct {
	shadows, shadowless: Pass_Light_Part,
	scene_root:          u32,
}

// Asks for room for lights that a pass writes on the GPU in the Simulate
// stage, which then light the scene as its own lights do: count that cast
// shadows within its budgets, and shadowless that light whatever stands in
// their way and trace no rays. From the next frame, each rounded up to a
// power of two, up to LIGHT_REGION_MAX. Ask in each frame that uses it.
lights_ask :: proc(r: ^Renderer, count, shadowless: u32) {
	r.lights_asked = max(r.lights_asked, count)
	r.shadowless_asked = max(r.shadowless_asked, shadowless)
}

// Binds the lights of the scene at SLOT_PASS0 + lights and the nodes of its
// tree at SLOT_PASS0 + nodes for the dispatches that write the room, in the
// Simulate stage. A pass that binds it writes all of it. False without room.
pass_lights :: proc(s: ^Stage_Pass, lights, nodes: u32) -> (room: Pass_Lights, ok: bool) {
	scene := &s.pass.r.scene
	region := scene.light_region
	if s.stage != .Simulate || region.lights == 0 || lights > SLOT_PASS9 - SLOT_PASS0 || nodes > SLOT_PASS9 - SLOT_PASS0 || scene.light_buffer == 0 || scene.light_tree_buffer == 0 {return}
	cmd := s.pass.cmd
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0 + lights, scene.light_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0 + nodes, scene.light_tree_buffer)
	scene.light_region_written = true
	first := light_region_first(region)
	scene_lights := u32(len(scene.lights))
	room.shadows = {first_light = scene_lights, capacity = region.lights, root = 1}
	if region.shadowless > 0 {room.shadowless = {first_light = scene_lights + region.lights + 1, capacity = region.shadowless, root = light_region_shadowless(region)}}
	room.scene_root = first if int(first) < len(scene.light_tree) else 2 * region.lights
	return room, true
}

// The indices a pass draws with: the six of a quad (0 1 2, 2 1 3). The
// meshes of the scene have none: their clusters are drawn by vertex
// (mesh_draw_range, pass_draw_indirect).
Pass_Indices :: enum u8 {Quad}

pass_indices :: proc(s: ^Stage_Pass, indices: Pass_Indices) {
	if s.pass.r.quad_indices != 0 {rhi.cmd_bind_index_buffer(s.pass.cmd, s.pass.r.quad_indices, 0)}
}

// Draws with the arguments of an indexed draw (index count, instance count,
// first index, vertex offset, first instance) a buffer of the world holds at
// offset, as a dispatch before wrote them.
pass_draw_indexed_indirect :: proc(s: ^Stage_Pass, desc: Extension_Buffer_Desc, offset: u64) {
	if entry := extension_buffer_find(s.pass.r, s.world, desc); entry != nil {rhi.cmd_draw_indexed_indirect(s.pass.cmd, entry.buffer, offset, 1, size_of(rhi.Draw_Indexed_Indirect))}
}

// The same without indices (vertex count, instance count, first vertex, first instance).
pass_draw_indirect :: proc(s: ^Stage_Pass, desc: Extension_Buffer_Desc, offset: u64) {
	if entry := extension_buffer_find(s.pass.r, s.world, desc); entry != nil {rhi.cmd_draw_indirect(s.pass.cmd, entry.buffer, offset, 1, size_of(Gpu_Draw))}
}

// Lets go of a buffer of an extension in a world: the world goes, or will
// not be drawn again. False when the renderer had none under that name.
buffer_release :: proc(r: ^Renderer, world: u64, name: string) -> bool {
	key := base.name_hash(name) | 1
	for &entry in r.extension_buffers {
		if entry.key != key || entry.world != world {continue}
		rhi.buffer_destroy(r.device, entry.buffer)
		entry = {}
		return true
	}
	return false
}

@(private)
extension_buffers_destroy :: proc(r: ^Renderer) {
	for &entry in r.extension_buffers {
		if entry.buffer != 0 {rhi.buffer_destroy(r.device, entry.buffer)}
		entry = {}
	}
	if r.quad_indices != 0 {rhi.buffer_destroy(r.device, r.quad_indices)}
	r.quad_indices = 0
}

// Rows an extension uploads once in a frame and binds in several of its
// passes: valid until the frame ends.
Pass_Rows :: rhi.Transient

// Copies rows into the memory of the frame, for pass_rows to bind in the
// passes of this frame. False when they do not fit.
pass_rows_upload :: proc(s: ^Stage_Pass, data: rawptr, size: int) -> (rows: Pass_Rows, ok: bool) {
	if data == nil || size <= 0 {return}
	rows = rhi.frame_alloc(s.pass.r.device, u64(size), 16)
	if rows.ptr == nil {return {}, false}
	mem.copy(rows.ptr, data, size)
	return rows, true
}

// Binds rows of pass_rows_upload at SLOT_PASS0 + slot.
pass_rows :: proc(s: ^Stage_Pass, slot: u32, rows: Pass_Rows) -> bool {
	if slot > SLOT_PASS9 - SLOT_PASS0 || rows.ptr == nil {return false}
	rhi.cmd_bind_transient(s.pass.cmd, SLOT_PASS0 + slot, rows)
	return true
}

// How a draw takes the clusters of level 0 of a mesh of the scene: the
// vertices of the draw, CLUSTER_DRAW_VERTICES a cluster, which a vertex shader
// reads with the mesh (geometry.slang). False for a mesh the renderer does
// not have, or whose geometry still goes to the GPU (mesh_uploading).
mesh_draw_range :: proc(r: ^Renderer, mesh: Mesh_Handle) -> (vertex_count: u32, ok: bool) {
	if int(mesh) >= len(r.scene.meshes) || r.scene.meshes[mesh].vertex_count == 0 || mesh_pending(&r.scene, u32(mesh)) {return}
	_, clusters := record_level(&r.scene, r.scene.meshes[mesh], 0)
	return clusters * CLUSTER_DRAW_VERTICES, true
}

// Counters the passes of an extension add to on the GPU, by name: four u32
// that start at zero in each frame and that the renderer reads back with its
// statistics (Stats.counters, two frames later).
EXTENSION_COUNTER_CAPACITY :: 16
EXTENSION_COUNTER_NAME_BYTES :: 32

Extension_Counter :: struct {
	name:   [EXTENSION_COUNTER_NAME_BYTES]u8,
	values: [4]u32,
}

@(private)
Extension_Counters :: struct {
	counters: [EXTENSION_COUNTER_CAPACITY]Extension_Counter,
	count:    int,
	stride:   u64, // between the counters of two names in the buffer
	buffer:   rhi.Buffer,
	readback: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	readable: [rhi.MAX_FRAMES_IN_FLIGHT]bool, // the frame of that slot copied its counters there
}

@(private)
extension_counters_init :: proc(r: ^Renderer) -> bool {
	c := &r.counters
	d := r.device
	c.stride = max(rhi.device_info(d).storage_alignment, 16)
	size := c.stride * EXTENSION_COUNTER_CAPACITY
	c.buffer = rhi.buffer_create(d, {size = size, usage = {.Storage}, name = "extension counters"})
	for &b in c.readback {b = rhi.buffer_create(d, {size = size, memory = .Readback, name = "extension counters readback"})}
	r.quad_indices = rhi.buffer_create(d, {size = 6 * size_of(u32), usage = {.Index}, memory = .Upload, name = "quad indices"})
	ok := c.buffer != 0 && c.readback[0] != 0 && c.readback[1] != 0 && r.quad_indices != 0
	if ok {
		quad := [6]u32{0, 1, 2, 2, 1, 3}
		mem.copy(rhi.buffer_mapped(d, r.quad_indices), &quad, size_of(quad))
	} else {
		set_error(r, "extension counters: %s", rhi.device_error(d))
	}
	return ok
}

@(private)
extension_counters_destroy :: proc(r: ^Renderer) {
	c := &r.counters
	for b in c.readback {if b != 0 {rhi.buffer_destroy(r.device, b)}}
	if c.buffer != 0 {rhi.buffer_destroy(r.device, c.buffer)}
	c^ = {}
}

// Binds the four counters of a name at SLOT_PASS0 + slot, for the dispatches
// of the pass to add to (RWStructuredBuffer<uint>). False without room for
// another name.
pass_counters :: proc(s: ^Stage_Pass, slot: u32, name: string) -> bool {
	c := &s.pass.r.counters
	if slot > SLOT_PASS9 - SLOT_PASS0 || name == "" || len(name) >= EXTENSION_COUNTER_NAME_BYTES {return false}
	at := -1
	for &counter, i in c.counters[:c.count] {
		if base.text_get(counter.name[:]) == name {at = i; break}
	}
	if at < 0 {
		if c.count == EXTENSION_COUNTER_CAPACITY {set_error(s.pass.r, "extension counters %s: no room for more than %d names", name, EXTENSION_COUNTER_CAPACITY); return false}
		at = c.count
		c.counters[at] = {}
		base.text_set(c.counters[at].name[:], name)
		c.count += 1
	}
	rhi.cmd_bind_buffer(s.pass.cmd, SLOT_PASS0 + slot, c.buffer, u64(at) * c.stride, 16)
	return true
}

// The counters of a name as the frame two frames ago left them.
renderer_counters :: proc(r: ^Renderer, name: string) -> (values: [4]u32, ok: bool) {
	for &counter in r.counters.counters[:r.counters.count] {
		if base.text_get(counter.name[:]) == name {return counter.values, true}
	}
	return
}

// At the start of a frame: what the frame in this slot counted, and zero for
// this one, also for the names its passes add.
@(private)
extension_counters_begin :: proc(r: ^Renderer, cmd: ^rhi.Command_List, slot: int) {
	c := &r.counters
	if c.count > 0 && c.readable[slot] {
		if ptr := rhi.buffer_mapped(r.device, c.readback[slot]); ptr != nil {
			for &counter, at in c.counters[:c.count] {
				counter.values = (cast(^[4]u32)rawptr(uintptr(ptr) + uintptr(u64(at) * c.stride)))^
			}
		}
	}
	rhi.cmd_fill_buffer(cmd, c.buffer, 0, c.stride * EXTENSION_COUNTER_CAPACITY, 0)
	c.readable[slot] = false
}

// At the end of a frame: what it counted, for the frame that takes its slot next.
@(private)
extension_counters_end :: proc(r: ^Renderer, cmd: ^rhi.Command_List, slot: int) {
	c := &r.counters
	if c.count == 0 {return}
	rhi.cmd_copy_buffer(cmd, c.buffer, 0, c.readback[slot], 0, c.stride * u64(c.count))
	rhi.cmd_barrier_buffer(cmd, c.readback[slot], .Host_Read)
	c.readable[slot] = true
}

// What the passes of an extension bring back from the GPU: a range of a
// buffer of a world copied at the end of the frame, which the CPU reads once
// that frame is done, MAX_FRAMES_IN_FLIGHT frames later, without waiting for
// it. A readback is of a world and a name; the renderer keeps it until the
// extension lets go of it (readback_release).
EXTENSION_READBACK_CAPACITY :: 16

@(private)
Extension_Readback :: struct {
	key, world: u64, // of its name; key 0: a free place
	size:       u64,
	buffers:    [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	copied:     [rhi.MAX_FRAMES_IN_FLIGHT]u64, // the frame whose copy each holds, + 1; 0: none
	data:       []u8, // what the last frame done brought back
	frame:      u64,  // that frame + 1; 0: nothing yet
}

// Copies size bytes of a buffer of the world from offset to the readback of
// that name, outside a render pass. Making the readback, the first time or
// with another size, is a load transaction. False for a buffer the world does
// not have with that size, or when the device does not take the readback.
pass_readback :: proc(s: ^Stage_Pass, buffer: Extension_Buffer_Desc, offset: u64, readback: Extension_Buffer_Desc) -> bool {
	r := s.pass.r
	source := extension_buffer_find(r, s.world, buffer)
	if source == nil || readback.size == 0 || offset + readback.size > buffer.size {return false}
	entry := extension_readback(r, s.world, readback)
	if entry == nil {return false}
	rhi.cmd_copy_buffer(s.pass.cmd, source.buffer, offset, entry.buffers[s.pass.slot], 0, readback.size)
	rhi.cmd_barrier_buffer(s.pass.cmd, entry.buffers[s.pass.slot], .Host_Read)
	entry.copied[s.pass.slot] = r.frame + 1
	return true
}

@(private)
extension_readback :: proc(r: ^Renderer, world: u64, desc: Extension_Buffer_Desc) -> ^Extension_Readback {
	key := base.name_hash(desc.name) | 1
	free: ^Extension_Readback
	for &entry in r.readbacks {
		if entry.key == key && entry.world == world {
			if entry.size == desc.size {return &entry}
			extension_readback_free(r, &entry)
			free = &entry
			break
		}
		if entry.key == 0 && free == nil {free = &entry}
	}
	if free == nil {set_error(r, "readback %s: the renderer has no room for more than %d", desc.name, EXTENSION_READBACK_CAPACITY); return nil}
	free^ = {key = key, world = world, size = desc.size}
	data_error: mem.Allocator_Error
	free.data, data_error = make([]u8, desc.size, r.allocator)
	if data_error != nil {
		set_error(r, "readback %s: out of memory for %d bytes", desc.name, desc.size)
		free^ = {}
		return nil
	}
	ok := free.data != nil
	for &b in free.buffers {
		b = rhi.buffer_create(r.device, {size = desc.size, memory = .Readback, name = "extension readback"})
		ok &&= b != 0
	}
	if !ok {
		set_error(r, "readback %s: %s", desc.name, rhi.device_error(r.device))
		extension_readback_free(r, free)
		return nil
	}
	return free
}

@(private)
extension_readback_free :: proc(r: ^Renderer, entry: ^Extension_Readback) {
	for b in entry.buffers {if b != 0 {rhi.buffer_destroy(r.device, b)}}
	delete(entry.data, r.allocator)
	entry^ = {}
}

// At the start of a frame, with its slot done: what the frame that had it
// copied comes to the CPU.
@(private)
extension_readbacks_take :: proc(r: ^Renderer, slot: int) {
	for &entry in r.readbacks {
		if entry.key == 0 || entry.copied[slot] == 0 || entry.copied[slot] <= entry.frame {continue}
		if ptr := rhi.buffer_mapped(r.device, entry.buffers[slot]); ptr != nil {mem.copy(raw_data(entry.data), ptr, int(entry.size))}
		entry.frame = entry.copied[slot]
		entry.copied[slot] = 0
	}
}

// What the readback of a world and a name brought back last, and the frame
// it is of (renderer frame + 1); none until a frame that copied it is done.
// Valid until the next frame.
readback :: proc(r: ^Renderer, world: u64, name: string) -> (data: []u8, frame: u64, ok: bool) {
	key := base.name_hash(name) | 1
	for &entry in r.readbacks {
		if entry.key == key && entry.world == world && entry.frame > 0 {return entry.data, entry.frame, true}
	}
	return
}

readback_release :: proc(r: ^Renderer, world: u64, name: string) -> bool {
	key := base.name_hash(name) | 1
	for &entry in r.readbacks {
		if entry.key != key || entry.world != world {continue}
		extension_readback_free(r, &entry)
		return true
	}
	return false
}

@(private)
extension_readbacks_destroy :: proc(r: ^Renderer) {
	for &entry in r.readbacks {if entry.key != 0 {extension_readback_free(r, &entry)}}
}
