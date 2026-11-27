package mirai_render

import "mirai:render/abi"
import "mirai:rhi"

// The lists of the lights that cast no shadows (shaders/include/light_lists.slang):
// what the walks of their tree visit for the points of a cell, decided once
// for the cell, which each point then sums with no walk. The cells of a view
// are the tiles of its screen, LIGHT_LIST_TILE pixels a side, listed again
// each frame from the depths and the normals of their pixels
// (shaders/light_lists.comp.slang). A list is a block of Targets.light_lists,
// that many texels across and LIGHT_LIST_ROWS down, a word each.
//
// What a list holds does not depend on where its cell comes from: a list of a
// cell of the world takes the same block, the same fill over the box of its
// points and the same sum.
LIGHT_LIST_TILE :: abi.LIGHT_LIST_TILE
LIGHT_LIST_ROWS :: abi.LIGHT_LIST_WORDS / LIGHT_LIST_TILE
#assert(LIGHT_LIST_ROWS * LIGHT_LIST_TILE == abi.LIGHT_LIST_WORDS)

// What the lists of a view held (Gpu_Cull_Stats.lists).
Light_List_Stats :: struct {
	cells:   u32, // with a point
	entries: u32, // of all their lists
	walked:  u32, // cells with more to list than a list holds, whose points walk the tree
	longest: u32, // the entries of the longest list
}

// Whether a frame has lights the lists hold: those without shadows of the
// scene, or those extensions write on the GPU (frame_dynamic_lights).
@(private)
lights_listed :: proc "contextless" (f: Gpu_Frame) -> bool {return f.shadowless_lights != 0 || f.dynamic_lights.x != 0}

// Lists the tiles of the view, after its G-buffer, and returns the lists for
// the pass that sums them; while no light is without shadows, none: no pass
// reads a list then. False without memory for them.
@(private)
light_lists_record :: proc(p: ^Pass) -> (lists: rhi.Texture, ok: bool) {
	r, cmd, t := p.r, p.cmd, p.t
	if !lights_listed(p.frame) {return r.dummy_uint, true}
	tiles := [2]u32{groups(t.width, LIGHT_LIST_TILE), groups(t.height, LIGHT_LIST_TILE)}
	target(r, cmd, &t.light_lists, tiles.x * LIGHT_LIST_TILE, tiles.y * LIGHT_LIST_ROWS, .R32_Uint, {.Sampled, .Storage}, "light lists", shared = true) or_return
	Params :: struct {tiles: [2]u32, pad: [2]u32}
	params := Params{tiles = tiles}
	rhi.cmd_timestamp(cmd, "light lists")
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Light_Lists])
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.light_lists)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS3, r.stats_buffer)
	rhi.cmd_dispatch(cmd, groups(tiles.x, 8), groups(tiles.y, 8))
	return t.light_lists, true
}
