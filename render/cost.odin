package mirai_render

import "mirai:rhi"
import "mirai:render/abi"

// What a frame of the first view of the window costs by mesh and by material,
// counted only in the frame after a request (renderer_cost_ask): the variants
// `cost` of the cull, of the raster rounds and of the cull of the maps add to
// it where they count the totals of the frame (cost.slang), and a pass over
// the visibility target counts its pixels. A frame nobody asked about runs
// the stages without them.
Cost_Row :: struct {
	instances:        u32, // that passed the cull of the view; of a mesh alone
	clusters:         u32, // the view listed for its raster
	triangles:        u32, // of those clusters
	raster_triangles: u32, // of them the raster drew: those that may cover a pixel
	pixels:           u32, // of the visibility target it ends up owning
	shadow_clusters:  u32, // the maps of the shadows of the view drew, once for each page they cover
	shadow_triangles: u32, // the raster of the maps drew of them
	shadow_units:     u32, // of raster work they took (abi.SHADOW_UNIT_TEXELS)
	shadow_over:      u32, // clusters left over the bound of the frame or the room of the lists: their pages wait
}
#assert(size_of(Cost_Row) == abi.COST_ROW_WORDS * size_of(u32))
#assert(offset_of(Cost_Row, instances) == abi.COST_INSTANCES * size_of(u32))
#assert(offset_of(Cost_Row, clusters) == abi.COST_CLUSTERS * size_of(u32))
#assert(offset_of(Cost_Row, triangles) == abi.COST_TRIANGLES * size_of(u32))
#assert(offset_of(Cost_Row, raster_triangles) == abi.COST_RASTER_TRIANGLES * size_of(u32))
#assert(offset_of(Cost_Row, pixels) == abi.COST_PIXELS * size_of(u32))
#assert(offset_of(Cost_Row, shadow_clusters) == abi.COST_SHADOW_CLUSTERS * size_of(u32))
#assert(offset_of(Cost_Row, shadow_triangles) == abi.COST_SHADOW_TRIANGLES * size_of(u32))
#assert(offset_of(Cost_Row, shadow_units) == abi.COST_SHADOW_UNITS * size_of(u32))
#assert(offset_of(Cost_Row, shadow_over) == abi.COST_SHADOW_OVER * size_of(u32))

// A count: a row for each Mesh_Handle and each Material_Handle the scene had
// when it was asked for.
Cost :: struct {
	frame:     u64, // of the renderer, that drew what it counts
	meshes:    []Cost_Row,
	materials: []Cost_Row,
}

@(private)
Cost_Phase :: enum u8 {None, Asked, Recorded, Ready}

@(private)
Cost_State :: struct {
	phase:             Cost_Phase,
	buffer, readback:  rhi.Buffer,
	meshes, materials: u32,   // rows of each the request counts
	words:             []u32, // what was read back
	frame:             u64,   // of the renderer that counted
	number:            u64,   // of the device frame that counted
	counting:          bool,  // the frame being recorded counts, in the first view of the window that draws
	taken:             bool,  // a view of it counted
}

@(private)
COST_PIPELINES :: [?]Pipeline_Id{.Cull_Cost, .Raster_Vertices_Cost, .Raster_Vertices_Shadow_Cost, .Shadow_Clusters_Cost, .Cost_Pixels}

// Asks the next frame that draws a view of the window to count what it costs
// by mesh and by material; renderer_cost gives the count some frames later.
// A transaction that may allocate: its buffers hold a row for each mesh and
// material of the scene. One asked while another is pending is that one.
renderer_cost_ask :: proc(r: ^Renderer) -> (problem: string) {
	c := &r.cost
	if c.phase == .Asked || c.phase == .Recorded {return ""}
	for id in COST_PIPELINES {
		if r.pipelines[id] == 0 {return "the device did not make the pipelines that count the cost of a frame; a newer GPU driver may make them"}
	}
	meshes, materials := u32(len(r.scene.meshes)), u32(len(r.scene.materials))
	if meshes == 0 {return "the scene has no meshes to count: give the renderer a scene first"}
	words := abi.COST_FIRST_ROW + int(meshes + materials) * abi.COST_ROW_WORDS
	size := u64(words) * size_of(u32)
	buffer_ok, _ := ensure_buffer(r, &c.buffer, size, {.Storage, .Transfer_Dst, .Transfer_Src}, "cost")
	readback_ok, _ := ensure_buffer(r, &c.readback, size, {.Transfer_Dst}, "cost readback", .Readback)
	if !buffer_ok || !readback_ok {return "the GPU has no memory for the count of the cost of a frame"}
	if len(c.words) != words {
		delete(c.words, r.allocator)
		made, error := make([]u32, words, r.allocator)
		if error != nil {c.words = nil; return "out of memory for the count of the cost of a frame"}
		c.words = made
	}
	c.meshes, c.materials, c.phase = meshes, materials, .Asked
	return ""
}

// The count asked for, once the GPU drew and counted it.
renderer_cost :: proc(r: ^Renderer) -> (cost: Cost, ready: bool) {
	c := &r.cost
	if c.phase != .Ready {return}
	rows := ([^]Cost_Row)(raw_data(c.words[abi.COST_FIRST_ROW:]))[:c.meshes + c.materials]
	return {frame = c.frame, meshes = rows[:c.meshes], materials = rows[c.meshes:][:c.materials]}, true
}

// At the start of a frame: the count of a frame the GPU finished is read, and
// one asked for starts with nothing counted.
@(private)
cost_begin :: proc(r: ^Renderer, cmd: ^rhi.Command_List) -> bool {
	c := &r.cost
	if c.phase == .Recorded && rhi.frame_number(r.device) >= c.number + rhi.MAX_FRAMES_IN_FLIGHT {
		if mapped := rhi.buffer_mapped(r.device, c.readback); mapped != nil {
			copy(c.words, ([^]u32)(mapped)[:len(c.words)])
			c.phase = .Ready
		}
	}
	if c.phase != .Asked {return true}
	rhi.cmd_fill_buffer(cmd, c.buffer, abi.COST_FIRST_ROW * size_of(u32), u64(len(c.words) - abi.COST_FIRST_ROW) * size_of(u32), 0)
	header := [abi.COST_FIRST_ROW]u32{c.meshes, c.materials, 0, 0}
	c.counting = upload_transient(r, cmd, header[:], c.buffer)
	return c.counting
}

// The buffer the first view of the window that draws counts into; 0 for the others.
@(private)
cost_take :: proc(r: ^Renderer, first, texture: bool) -> rhi.Buffer {
	c := &r.cost
	if !c.counting || !first || texture {return 0}
	c.counting, c.taken = false, true
	return c.buffer
}

// At the end of a frame: what a view counted goes to be read back.
@(private)
cost_end :: proc(r: ^Renderer, cmd: ^rhi.Command_List) {
	c := &r.cost
	c.counting = false
	if !c.taken {return}
	c.taken = false
	rhi.cmd_copy_buffer(cmd, c.buffer, 0, c.readback, 0, u64(len(c.words)) * size_of(u32))
	rhi.cmd_barrier_buffer(cmd, c.readback, .Host_Read)
	c.phase, c.number, c.frame = .Recorded, rhi.frame_number(r.device), r.frame
}

// The pixels of the visibility target each mesh and material owns (cost_pixels.comp).
@(private)
cost_pixels :: proc(p: ^Pass) {
	r, cmd, t := p.r, p.cmd, p.t
	Params :: struct {capacity, pad0, pad1, pad2: u32}
	params := Params{capacity = r.scene.cull_capacity[.Visible]}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Cost_Pixels])
	set_params(cmd, &params)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, r.scene.visible_buffer)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.visibility)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS8, p.cost)
	rhi.cmd_dispatch(cmd, groups(t.width, 8), groups(t.height, 8))
}

@(private)
cost_destroy :: proc(r: ^Renderer) {
	c := &r.cost
	for b in ([]rhi.Buffer{c.buffer, c.readback}) {if b != 0 {rhi.buffer_destroy(r.device, b)}}
	delete(c.words, r.allocator)
	c^ = {}
}
