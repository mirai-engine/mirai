package mirai_render

import "mirai:rhi"

// Distortion: the Blend stage of a side of glass adds into one target how far
// each pixel of the lit image is displaced, and after its passes the renderer
// displaces the image once by what they added (distortion.frag), so the cost
// is that of a pixel whatever overlaps there and nothing is shown twice. The
// image is read from scene_copy, which the glass of the view also reads at
// other moments of the frame: the side behind glass displaces before the glass
// copies the scene, that in front after the glass took it. A view that does
// not distort has neither target.

// The copy of the image of a view (Frame_Targets.scene_copy), with the levels
// the glass blurs it with.
@(private)
scene_copy_target :: proc(r: ^Renderer, t: ^Targets) -> bool {
	if t.scene_copy != 0 {return true}
	t.scene_copy, _ = shared_target(r, {
		width = t.width, height = t.height, format = .RGBA16_Float, usage = HISTORY_USAGE + {.Transfer_Dst},
		mip_levels = glass_scene_levels(t), name = "scene copy",
	})
	return t.scene_copy != 0
}

// Begins the pass in which an extension adds, in the Blend stage, how far each
// pixel of the lit image of its side of glass is displaced, with the depth
// buffer of the view to test against: in red and green x right and y down in
// uv (a pixel is 1 / Stage_Pass.width across), in blue its view depth times
// its weight and in alpha that weight, its coverage (rgba16f, added). Its
// pipelines are of a Stage_Pipeline_Desc with distortion. After the passes of
// the side the image shows at each pixel what the copy of it holds at its
// place plus its offset, unless what is there lies in front of what displaces
// it (the depth its weights average); the coverage TAA reads grows with the
// shift.
// Ends with pass_end. False where there is no image to displace: in the
// Effect stage, without room for its targets or without the pipeline that
// displaces it, which the first frame that distorts makes (renderer_feature).
pass_distortion_begin :: proc(s: ^Stage_Pass, name := "distortion") -> bool {
	p := s.pass
	if s.stage != .Blend || p.view == nil {return false}
	r, t := p.r, p.t
	if !renderer_feature(r, .Distortion) {return false}
	if !scene_copy_target(r, t) || !target(r, nil, &t.distortion, t.width, t.height, .RGBA16_Float, {.Color_Target, .Sampled}, "distortion", shared = true) {return false}
	rhi.cmd_timestamp(p.cmd, name)
	pass := rhi.Render_Pass_Desc{color_count = 1, name = name}
	pass.colors[0] = {texture = t.distortion, load = .Load if p.distorted else .Clear, store = .Store}
	pass.depth = {texture = t.depth, load = .Load, store = .Store}
	rhi.cmd_begin_render_pass(p.cmd, &pass)
	p.distorted = true
	p.distortion_drawn = true
	return true
}

// After the Blend stage of a side: the image displaced by what it drew.
@(private)
distortion_apply :: proc(p: ^Pass) {
	if !p.distorted {return}
	p.distorted = false
	r, cmd, t := p.r, p.cmd, p.t
	pipeline := r.pipelines[.Distortion]
	if pipeline == 0 {return}
	rhi.cmd_timestamp(cmd, "distortion apply")
	rhi.cmd_copy_texture(cmd, t.display, t.scene_copy)
	target := rhi.Render_Pass_Desc{color_count = 2, name = "distortion apply"}
	target.colors[0] = {texture = t.display, load = .Load, store = .Store}
	target.colors[1] = {texture = t.reactive, load = .Load if p.blended else .Clear, store = .Store}
	rhi.cmd_begin_render_pass(cmd, &target)
	rhi.cmd_bind_pipeline(cmd, pipeline)
	Params :: struct {size, inv_size: [2]f32}
	params := Params{{f32(t.width), f32(t.height)}, {1 / f32(t.width), 1 / f32(t.height)}}
	set_params(cmd, &params)
	rhi.cmd_bind_sampler(cmd, SLOT_LINEAR_SAMPLER, r.linear_sampler)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.scene_copy, 0)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.distortion)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.linear_depth)
	rhi.cmd_draw(cmd, 3)
	rhi.cmd_end_render_pass(cmd)
	p.blended = true
}

// Before the Blend stage of a view: the targets of distortion go back when the
// frame before did not distort, scene_copy too without glass.
@(private)
distortion_targets_settle :: proc(r: ^Renderer, t: ^Targets) {
	if t.distorted || t.distortion == 0 {return}
	shared_target_release(r, t.distortion)
	t.distortion = 0
	if t.glass_zbuffer == 0 && t.scene_copy != 0 {
		shared_target_release(r, t.scene_copy)
		t.scene_copy = 0
	}
}
