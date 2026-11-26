package mirai_render

import "core:math"
import "mirai:render/abi"
import "mirai:rhi"

// The color of the ground (mirai_ground_color of mirai_material.slang): what
// stands on a terrain (grass, a path, a rock) reads the base color of the
// ground under it with one sample, instead of evaluating the material of the
// terrain again. A chunk of terrain is registered with the instance that draws
// it and the square of the world it covers (ground_chunk_set); the renderer
// bakes it once, and again when its revision changes: a point per sample of
// the chunk, found by a ray straight up from under the instance, evaluated by
// the stage of its program (points.odin) with the footprint of a sample, its
// base color kept in the texture of the slot of the chunk, with its levels.
// Where the ray meets no ground (a hole, past the edge of the mesh) the texel
// covers nothing and what reads it takes its own fallback.
//
// The chunks are those of one regular grid, each GROUND_TEXELS samples a side
// that share the samples of their edges with their neighbors: the texel of a
// sample is centered on it, so two chunks hold the same along the edge they
// share and a read never leaves its chunk. A table of GROUND_TABLE chunks a
// side names the texture of each baked chunk; a place of the world finds its
// chunk by arithmetic. The slots, the table and the texels of a bake are made
// when the first chunk is registered; a frame with nothing to bake records
// nothing.

GROUND_TEXELS :: abi.GROUND_TEXELS
GROUND_TABLE :: abi.GROUND_TABLE
GROUND_MIPS :: 5
GROUND_CHUNKS_MAX :: 64 // the most Settings.ground_chunks asks for
@(private) GROUND_LEVEL_TEXELS :: GROUND_TEXELS * GROUND_TEXELS * 341 / 256 // of the GROUND_MIPS levels of a chunk
GROUND_CHUNK_BYTES :: GROUND_LEVEL_TEXELS * 4 // GPU memory of a slot

Ground_Chunk :: struct {
	instance: u32,    // of the scene, by its descriptor: what draws the chunk, which the rays of its bake meet
	low:      [2]f32, // x and z of its first sample, in the world
	size:     f32,    // metres from its first sample to its last, along x and along z
	revision: u64,    // another when what the chunk shows changed: it is baked again
}

@(private)
Ground_Slot :: struct {
	chunk:   Ground_Chunk,
	cell:    [2]i32, // of the chunk on the grid
	used:    bool,
	stale:   bool, // its texture does not hold what the chunk shows now
	baked:   bool, // its texture holds a bake of the chunk: the table names it
	handle:  Texture_Handle,
	texture: rhi.Texture,
}

Ground :: struct {
	slots:        [GROUND_CHUNKS_MAX]Ground_Slot,
	made:         int,     // slots with a texture
	world:        u64,     // the world the chunks are of (scene_world)
	origin:       [2]f32,  // x and z of the first sample of the chunk of cell 0, in the world
	size:         f32,     // of every chunk
	low:          [2]i32,  // the cell of the first chunk of the table
	table:        rhi.Texture,
	table_handle: Texture_Handle,
	table_stale:  bool, // the table does not name the baked chunks
	staging:      rhi.Buffer, // the texels of the levels of a bake, a word each, level after level
}

// The cell of the grid a chunk that starts at low is in; false off the grid.
@(private)
ground_cell :: proc "contextless" (g: ^Ground, low: [2]f32) -> (cell: [2]i32, ok: bool) {
	at := (low - g.origin) / g.size
	if !(abs(at.x) < 1e6 && abs(at.y) < 1e6) {return}
	cell = {i32(math.round(at.x)), i32(math.round(at.y))}
	return cell, abs(at.x - f32(cell.x)) < 0.01 && abs(at.y - f32(cell.y)) < 0.01
}

// Registers a chunk of the ground of a world, or changes the one registered
// where it is: it is baked in a frame after, and again when its revision is
// another. The chunks of another world go. False with an error for a chunk
// off the grid of those registered, and without one when the slots
// (Settings.ground_chunks) are taken: what reads the color there takes its
// fallback.
ground_chunk_set :: proc(r: ^Renderer, world: u64, chunk: Ground_Chunk) -> bool {
	g := &r.ground
	if world != g.world {
		for &slot in g.slots {slot.used, slot.baked = false, false}
		g.world, g.table_stale = world, true
	}
	held := false
	for slot in g.slots {held ||= slot.used}
	if !held && chunk.size > 0 {g.origin, g.size = chunk.low, chunk.size}
	cell, on_grid := ground_cell(g, chunk.low)
	if !on_grid || chunk.size != g.size {
		set_error(r, "ground color: the chunk at %v, %v m across, is off the grid of the chunks registered (%v m across, from %v); register the chunks of one regular grid", chunk.low, chunk.size, g.size, g.origin)
		return false
	}
	free: ^Ground_Slot
	for &slot in g.slots[:min(int(r.settings.ground_chunks), GROUND_CHUNKS_MAX)] {
		if slot.used && slot.cell == cell {
			slot.stale ||= slot.chunk.revision != chunk.revision
			slot.chunk = chunk
			return true
		}
		if !slot.used && free == nil {free = &slot}
	}
	if free == nil {return false}
	free.chunk, free.cell, free.used, free.stale, free.baked = chunk, cell, true, true, false
	return true
}

// Lets go of the chunk of a world that starts at low; false without one.
ground_chunk_remove :: proc(r: ^Renderer, world: u64, low: [2]f32) -> bool {
	g := &r.ground
	cell, on_grid := ground_cell(g, low)
	if world != g.world || !on_grid {return false}
	for &slot in g.slots {
		if !slot.used || slot.cell != cell {continue}
		slot.used, slot.baked, g.table_stale = false, false, true
		return true
	}
	return false
}

// Every chunk is baked again: what its programs give changed.
@(private)
ground_stale :: proc "contextless" (r: ^Renderer) {
	for &slot in r.ground.slots {slot.stale = true}
}

// A texture of the texture table, square, which the renderer writes on the
// GPU: it covers nothing until then.
@(private)
ground_texture :: proc(r: ^Renderer, side, levels: u32, format: rhi.Format, name: string) -> (texture: rhi.Texture, handle: Texture_Handle) {
	state := &r.textures
	index := texture_slot(state)
	if !textures_room(r, index, name) {return}
	empty, error := make([]u8, int(side) * int(side) * 4, r.allocator)
	defer delete(empty, r.allocator)
	if error != nil {
		set_error(r, "%s: out of memory for its %d texels", name, side * side)
		return
	}
	each: [GROUND_MIPS][]u8
	for level in 0 ..< levels {each[level] = empty[:int(side >> level) * int(side >> level) * 4]}
	texture = rhi.texture_create(r.device, {width = side, height = side, mip_levels = levels, format = format, usage = {.Sampled}, name = name})
	if texture == 0 || !rhi.texture_upload_levels(r.device, texture, each[:levels]) || !rhi.texture_table_set(r.device, texture_entry(index), texture) {
		set_error(r, "%s: %s", name, rhi.device_error(r.device))
		if texture != 0 {rhi.texture_destroy(r.device, texture)}
		return 0, 0
	}
	state.textures[index] = texture
	state.keys[index] = 0
	state.sizes[index] = {int(side), int(side)}
	state.count = max(state.count, index + 1)
	return texture, Texture_Handle(index + 1)
}

// Between frames, once a chunk is registered: the slots the settings ask for,
// the table and the texels of a bake. Without memory for them the chunks
// without a slot are not baked, and the error says so.
@(private)
ground_prepare :: proc(r: ^Renderer) {
	g := &r.ground
	wanted := 0
	for slot in g.slots {
		if slot.used {wanted = min(int(r.settings.ground_chunks), GROUND_CHUNKS_MAX)}
	}
	if wanted <= g.made {return}
	if g.staging == 0 {
		g.staging = rhi.buffer_create(r.device, {size = GROUND_LEVEL_TEXELS * size_of(u32), usage = {.Storage, .Transfer_Src}, name = "ground color bake"})
		if g.staging == 0 {
			set_error(r, "ground color: %s", rhi.device_error(r.device))
			return
		}
	}
	if g.table == 0 {
		g.table, g.table_handle = ground_texture(r, GROUND_TABLE, 1, .RGBA8_Unorm, "ground color table")
		if g.table == 0 {return}
	}
	for g.made < wanted {
		slot := &g.slots[g.made]
		slot.texture, slot.handle = ground_texture(r, GROUND_TEXELS, GROUND_MIPS, .RGBA8_Srgb, "ground color")
		if slot.texture == 0 {return}
		g.made += 1
	}
}

@(private)
ground_destroy :: proc(r: ^Renderer) {
	g := &r.ground
	for slot in g.slots[:g.made] {texture_remove(r, slot.handle)}
	if g.table != 0 {texture_remove(r, g.table_handle)}
	if g.staging != 0 {rhi.buffer_destroy(r.device, g.staging)}
	g^ = {}
}

// What a frame gives its shaders of the table (Gpu_Frame.ground and
// ground_table): nothing while the world shown is not that of the chunks.
@(private)
ground_frame :: proc "contextless" (r: ^Renderer) -> (ground: [3]f32, table: u32) {
	g := &r.ground
	if g.table == 0 || g.world != r.world_key {return}
	for axis in 0 ..< 2 {ground[axis] = f32(f64(g.origin[axis]) + f64(g.low[axis]) * f64(g.size) - f64(r.origin[2 * axis]))}
	return {ground.x, ground.y, 1 / g.size}, texture_entry(int(g.table_handle) - 1)
}

// At the start of a frame, before its views: the table, when the baked chunks
// changed. It starts at the lowest cell of them; a chunk past its side has no
// entry.
@(private)
ground_table_record :: proc(r: ^Renderer, cmd: ^rhi.Command_List) -> bool {
	g := &r.ground
	if !g.table_stale || g.table == 0 {return true}
	t := rhi.frame_alloc(r.device, GROUND_TABLE * GROUND_TABLE * 4, 16)
	if t.ptr == nil {
		set_error(r, "transient ring exhausted uploading the table of the color of the ground")
		return false
	}
	g.low = ground_table_fill(g, ([^][4]u8)(t.ptr)[:GROUND_TABLE * GROUND_TABLE])
	rhi.cmd_copy_buffer_to_texture(cmd, t.buffer, t.offset, g.table)
	rhi.cmd_barrier_texture(cmd, g.table, .Shader_Read)
	g.table_stale = false
	return true
}

// The entries of the table, by chunk along x and then along z: the place in
// the texture table of the texture of each baked chunk, in two bytes; 0 for
// none. low: the cell of its first chunk.
@(private)
ground_table_fill :: proc "contextless" (g: ^Ground, entries: [][4]u8) -> (low: [2]i32) {
	low = {max(i32), max(i32)}
	for slot in g.slots[:g.made] {
		if slot.used && slot.baked {low = {min(low.x, slot.cell.x), min(low.y, slot.cell.y)}}
	}
	for &entry in entries {entry = {}}
	for slot in g.slots[:g.made] {
		at := slot.cell - low
		if !slot.used || !slot.baked || at.x >= GROUND_TABLE || at.y >= GROUND_TABLE {continue}
		index := texture_entry(int(slot.handle) - 1)
		entries[at.x + GROUND_TABLE * at.y] = {u8(index), u8(index >> 8), 0, 0}
	}
	return
}

// Whether the stage of the points of every Surface program of the scene has
// its pipeline. While one is made its points read as the rows of their
// materials (points.odin), which a bake would keep: it waits.
@(private)
ground_programs_ready :: proc(r: ^Renderer) -> bool {
	m := &r.points
	for program in renderer_programs(r) {
		if program.domain != .Surface || program.id >= m.programs || r.scene.program_rows[program.id] == 0 {continue}
		if points_pipeline(r, program) == 0 && m.codes[program.id] != nil {return false}
	}
	return true
}

// The slot whose chunk a frame bakes: one at most, the first that is stale and
// whose instance rays meet now, once the programs are ready.
@(private)
ground_bake_next :: proc(r: ^Renderer) -> ^Ground_Slot {
	g, s := &r.ground, &r.scene
	if g.world != r.world_key {return nil}
	for &slot in g.slots[:g.made] {
		if !slot.used || !slot.stale || int(slot.chunk.instance) >= len(s.instances) {continue}
		inst := &s.instances[slot.chunk.instance]
		mesh := inst.meta.x & INSTANCE_MESH_MASK
		if inst.meta.w & INSTANCE_FLAG_HIDDEN != 0 || mesh_pending(s, mesh) || inputs_queued(s, mesh) {continue}
		return &slot if ground_programs_ready(r) else nil
	}
	return nil
}

// With the first view of a frame, among what lights the world: the bake of
// one stale chunk (ground_bake.comp), its rays, the programs of what they
// found, its levels, and their texels into the texture of its slot.
@(private)
ground_bake :: proc(p: ^Pass) {
	r, cmd := p.r, p.cmd
	g := &r.ground
	slot := ground_bake_next(r)
	pipeline := pipeline_of(r, .Ground_Bake) if slot != nil else nil
	if pipeline == nil || pipeline^ == 0 {return}
	inst := &r.scene.instances[slot.chunk.instance]
	Params :: struct {resume, level, instance, pad0: u32, low: [2]f32, step, bottom, height: f32, pad1: [3]f32}
	params := Params {
		instance = slot.chunk.instance,
		low = {f32(f64(slot.chunk.low.x) - f64(r.origin.x)), f32(f64(slot.chunk.low.y) - f64(r.origin.z))},
		step = g.size / (GROUND_TEXELS - 1),
		bottom = inst.bounds_min.y - 1,
		height = inst.bounds_max.y - inst.bounds_min.y + 2,
	}
	rhi.cmd_timestamp(cmd, "ground color")
	batch := points_begin(p)
	rhi.cmd_bind_pipeline(cmd, pipeline^)
	set_params(cmd, &params)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, g.staging)
	points_bind(p)
	rhi.cmd_dispatch(cmd, groups(GROUND_TEXELS * GROUND_TEXELS, 32))
	points_rounds(p, batch, pipeline^, &params, 1)
	for level in u32(1) ..< GROUND_MIPS {
		params.level = level
		set_params(cmd, &params)
		rhi.cmd_dispatch(cmd, groups((GROUND_TEXELS >> level) * (GROUND_TEXELS >> level), 32))
	}
	offset := u64(0)
	for level in u32(0) ..< GROUND_MIPS {
		rhi.cmd_copy_buffer_to_texture(cmd, g.staging, offset * size_of(u32), slot.texture, level)
		offset += u64(GROUND_TEXELS >> level) * u64(GROUND_TEXELS >> level)
	}
	rhi.cmd_barrier_texture(cmd, slot.texture, .Shader_Read)
	slot.stale = false
	if !slot.baked {slot.baked, g.table_stale = true, true}
}
