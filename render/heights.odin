package mirai_render

import "mirai:rhi"

// The heights of the scene around the camera of a view (heights.slang): the
// top of what a ray of the view can meet over each place of the ground, in
// the entry HEIGHTS_TEXTURE of the texture table. A view draws them with its
// shadow maps (shadow_maps_plan), straight down from over the scene, while it
// draws a solid of glass, whose rays go on through the scene: a ray that
// stays over the heights is not sent. They only say where nothing is, so
// their detail changes what the rays cost and not what they find. A view
// writes them before the passes of its glass read them.
HEIGHTS_TEXTURE :: 4
HEIGHT_MAPS :: 2
HEIGHTS_SIDE :: u32(512)
HEIGHTS_BLOCK :: u32(16)
// Half the side of each map, metres, the nearest first; and the side each is
// drawn with, twice that of its heights.
HEIGHT_REACHES :: [HEIGHT_MAPS]f32{64, 256}
HEIGHTS_DRAWN :: 2 * HEIGHTS_SIDE
// The light of a map of the heights among the maps a plan wants.
@(private)
HEIGHTS_LIGHT :: -2

// heights.slang Heights.
Gpu_Heights :: struct {
	count:  u32,
	bottom: f32,
	top:    f32,
	pad0:   f32,
	maps:   [HEIGHT_MAPS]Vec4, // x and z of its middle, and half its side
}

// The texture of the heights and the buffer its pass writes them in.
Heights_State :: struct {
	texture: rhi.Texture,
	written: rhi.Buffer,
}

@(private)
HEIGHTS_SIZE :: [2]u32{HEIGHT_MAPS * HEIGHTS_SIDE, HEIGHTS_SIDE + HEIGHTS_SIDE / HEIGHTS_BLOCK}

@(private)
heights_build :: proc(r: ^Renderer) -> bool {
	d := r.device
	size := HEIGHTS_SIZE
	h := &r.heights
	h.texture = rhi.texture_create(d, {width = size.x, height = size.y, format = .R32_Float, usage = {.Sampled}, name = "heights"})
	h.written = rhi.buffer_create(d, {size = u64(size.x * size.y) * 4, usage = {.Storage, .Transfer_Src}, name = "heights written"})
	if h.texture != 0 {
		cmd := rhi.immediate_begin(d)
		rhi.cmd_barrier_texture(cmd, h.texture, .Shader_Read)
		if !rhi.immediate_end(d, cmd) {
			set_error(r, "heights: %s", rhi.device_error(d))
			return false
		}
	}
	if h.texture == 0 || h.written == 0 || !rhi.texture_table_set(d, HEIGHTS_TEXTURE, h.texture) {
		set_error(r, "heights: %s", rhi.device_error(d))
		return false
	}
	return true
}

@(private)
heights_destroy :: proc(r: ^Renderer) {
	if r.heights.texture != 0 {rhi.texture_destroy(r.device, r.heights.texture)}
	if r.heights.written != 0 {rhi.buffer_destroy(r.device, r.heights.written)}
	r.heights = {}
}

// Whether a view draws the heights: while the scene has a solid of glass and
// its box is known.
@(private)
heights_wanted :: proc(r: ^Renderer) -> bool {
	if !r.scene.has_bounds || r.heights.texture == 0 {return false}
	for entry in r.scene.translucent {if entry.solid {return true}}
	return false
}

// The maps of the heights among those a plan wants: squares around the eye,
// from over the box of the scene down to under it.
@(private)
heights_wants :: proc(wants: ^[SHADOW_MAPS_MAX]Shadow_Want, count: ^int, eye, scene_low, scene_high: Vec3) {
	top, bottom := scene_high.y + 1, scene_low.y - 1
	for reach in HEIGHT_REACHES {
		if count^ >= SHADOW_MAPS_MAX {break}
		wants[count^] = {
			m = {
				origin = {eye.x, top, eye.z}, right = {1, 0, 0}, up = {0, 0, 1}, forward = {0, -1, 0},
				near = 0, far = top - bottom, kind = SHADOW_MAP_HEIGHTS, span = {-reach, -reach, reach, reach},
			},
			light = HEIGHTS_LIGHT, weight = 1, side = HEIGHTS_DRAWN,
		}
		count^ += 1
	}
}

// The heights of the view from the maps of them the atlas holds: `first` of
// the maps of the frame and those after it, whose places `found` has.
@(private)
heights_pass :: proc(p: ^Pass, found: Gpu_Heights, first, rows: u32) {
	if found.count == 0 {return}
	r, cmd, t := p.r, p.cmd, p.t
	h := &r.heights
	size := HEIGHTS_SIZE
	Params :: struct {first, rows, count, pad0: u32}
	params := Params{first = first, rows = rows, count = found.count}
	rhi.cmd_timestamp(cmd, "heights")
	rhi.cmd_barrier_buffer(cmd, h.written, .Shader_Write)
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Heights])
	set_params(cmd, &params)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, t.shadow_buffers.table)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.shadow_atlas)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS2, h.written)
	rhi.cmd_dispatch(cmd, size.x / HEIGHTS_BLOCK, HEIGHTS_SIDE / HEIGHTS_BLOCK)
	rhi.cmd_copy_buffer_to_texture(cmd, h.written, 0, h.texture)
	rhi.cmd_barrier_texture(cmd, h.texture, .Shader_Read)
	p.heights = found
}
