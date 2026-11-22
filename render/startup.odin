package mirai_render

import "mirai:rhi"

// What the window shows while renderer_init makes the pipelines it starts
// with: screen UI alone, drawn with the one pipeline create_pipelines makes
// before the others. Its images go with renderer_init.
@(private)
Startup_Screen :: struct {
	target: rhi.Texture, // the UI, of the size of the window
	size:   [2]u32,
	lut:    rhi.Texture, // in place of the display LUT, not made yet: the UI reads it only for previews
	materials: rhi.Buffer, // a row of the material table, for what binds it: the UI reads it only for previews
	layers: [UI_LAYER_DEPTH_CAPACITY]rhi.Texture, // none: an isolated layer of the UI is not drawn
	blur:   [2]rhi.Texture,
}

// A frame of the window from Renderer_Desc.on_pipelines, while renderer_init
// makes the pipelines: the screen layers over clear (encoded for the display,
// as the colors of the UI are), at width by height pixels for points of the
// UI. False when it presented nothing: the device gave no frame (a minimized
// window) or the UI cannot draw.
renderer_startup_frame :: proc(r: ^Renderer, ui: []Ui_Layer, width, height: u32, points: Vec2, clear: Vec4) -> bool {
	d := r.device
	s := &r.startup
	if r.pipelines[.Ui] == 0 || width == 0 || height == 0 || points.x <= 0 || points.y <= 0 {return false}
	if s.size != {width, height} {
		if s.target != 0 {rhi.texture_destroy(d, s.target)}
		s.target = rhi.texture_create(d, {width = width, height = height, format = .RGBA8_Unorm, usage = {.Sampled, .Color_Target}, name = "startup screen"})
		s.size = {width, height} if s.target != 0 else {}
	}
	if s.lut == 0 {
		s.lut = rhi.texture_create(d, {width = 1, height = 1, depth = 1, format = .RGBA16_Float, usage = {.Sampled}, name = "startup display lut"})
	}
	if s.materials == 0 {
		s.materials = rhi.buffer_create(d, {size = size_of(Gpu_Material_Row), usage = {.Storage}, name = "startup materials"})
	}
	if s.target == 0 || s.lut == 0 || s.materials == 0 {return false}
	rhi.swapchain_resize(d, width, height)
	cmd, began := rhi.frame_begin(d)
	if !began {return false}
	slot := int(rhi.frame_number(d) % rhi.MAX_FRAMES_IN_FLIGHT)
	r.ui_shape_written, r.ui_shape_cache_count, r.ui_vertex_cache_count = 0, 0, 0
	written := 0
	drawn := font_record(r, cmd, slot)
	if drawn {
		rhi.cmd_bind_sampler(cmd, SLOT_LINEAR_SAMPLER, r.linear_sampler)
		rhi.cmd_bind_sampler(cmd, SLOT_POINT_SAMPLER, r.point_sampler)
		rhi.cmd_bind_sampler(cmd, SLOT_MATERIAL_SAMPLER, r.material_sampler)
		rhi.cmd_bind_buffer(cmd, SLOT_MATERIALS, s.materials)
		rhi.cmd_bind_transient(cmd, SLOT_FRAME, frame_constants(r, {resolution = {f32(width), f32(height)}}))
		pass := rhi.Render_Pass_Desc{color_count = 1, name = "startup screen"}
		pass.colors[0] = {texture = s.target, load = .Clear, store = .Store, clear = clear}
		rhi.cmd_begin_render_pass(cmd, &pass)
		rhi.cmd_set_viewport(cmd, 0, 0, f32(width), f32(height))
		lut := r.display_lut
		r.display_lut = s.lut
		ui_layers_pass(r, cmd, {s.target, s.layers[:], s.blur[:], width, height}, slot, &written, ui, points, f32(width) / points.x, r.dummy_texture)
		r.display_lut = lut
		rhi.cmd_end_render_pass(cmd)
	}
	swap := rhi.swapchain_texture(d)
	if drawn && swap != 0 {present_blit(r, cmd, swap, rhi.swapchain_format(d), s.target)}
	return rhi.frame_end(d, cmd) && drawn && swap != 0
}

// When renderer_init has made its pipelines, or failed to.
@(private)
startup_screen_destroy :: proc(r: ^Renderer) {
	s := &r.startup
	if s.target != 0 {rhi.texture_destroy(r.device, s.target)}
	if s.lut != 0 {rhi.texture_destroy(r.device, s.lut)}
	if s.materials != 0 {rhi.buffer_destroy(r.device, s.materials)}
	s^ = {}
}
