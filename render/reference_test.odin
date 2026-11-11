package mirai_render

import "mirai:rhi"

// What the tests compare the renderer with, as an extension of it that the
// engine does not ship: a pipeline whose custom passes give, in place of the
// Direct and Indirect stages, the direct light of every pixel through rays to
// points of the sun and of every light (reference_lights.comp) and its
// diffuse indirect light by paths, their mean while the camera stays
// (gi_reference.comp). Their stages are in testdata/, in TEST_GENERATION.
Reference :: enum u8 {Lights, Gi}
Reference_Set :: bit_set[Reference]

// What the paths of the indirect reference of a view were gathered for: they
// start again when it changes.
Reference_Gi :: struct {
	view:     Mat4,
	eye:      Vec3,
	settings: Settings,
}

// Paths of each pixel in a frame of the indirect reference, and the most
// surfaces each meets.
GI_REFERENCE_PATHS :: u32(4)
GI_REFERENCE_BOUNCES :: u32(32)

@(private = "file", rodata)
REFERENCE_LIGHTS_USES := [?]Render_Use{{.Normal, .Read, false}, {.Linear_Depth, .Read, false}, {.Albedo, .Read, false}, {.Direct, .Write, false}}
@(private = "file", rodata)
REFERENCE_GI_USES := [?]Render_Use{{.Normal, .Read, false}, {.Linear_Depth, .Read, false}, {.Gi, .Write, false}}

// The pipeline of Full with the references of which in place of its stages.
reference_pipeline :: proc(r: ^Renderer, which: Reference_Set, gi: ^Reference_Gi) -> Render_Pipeline_Handle {
	passes: [RENDER_PASS_CAPACITY]Render_Pass_Desc
	count := 0
	for pass in standard_pipeline_passes(.Full) {
		switch {
		case pass.stage == .Direct && .Lights in which:
			passes[count] = {stage = .Custom, name = "reference lights", uses = REFERENCE_LIGHTS_USES[:], record = reference_lights_record}
		case pass.stage == .Indirect && .Gi in which:
			passes[count] = {stage = .Custom, name = "reference gi", uses = REFERENCE_GI_USES[:], record = reference_gi_record, user = gi}
		case:
			passes[count] = pass
		}
		count += 1
	}
	handle, _ := renderer_pipeline(r, {passes = passes[:count]})
	return handle
}

// A frame whose views of the window are drawn with the references of which;
// gi keeps the paths of the indirect one from frame to frame.
reference_frame :: proc(r: ^Renderer, frame: Frame_Desc, which: Reference_Set, gi: ^Reference_Gi) -> bool {
	handle := reference_pipeline(r, which, gi)
	if handle == 0 || !renderer_main_pipeline(r, handle) {return false}
	return renderer_frame(r, frame)
}

@(private = "file")
reference_lights_record :: proc(s: ^Stage_Pass, user: rawptr) {
	p := s.pass
	r, cmd, t := p.r, p.cmd, p.t
	pipeline := stage_pipeline(r, {stage = .Custom, shader = "reference_lights", name = "reference lights"})
	if pipeline == 0 {return}
	Params :: struct {sun_radius: f32, pad0, pad1, pad2, resume, pad3, pad4, pad5: u32}
	params := Params{sun_radius = r.settings.sun_radius}
	batch := shadows_colored(r) && points_begin(p, filters = true)
	rhi.cmd_bind_pipeline(cmd, pipeline)
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.direct)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.albedo)
	points_bind(p)
	rhi.cmd_dispatch(cmd, groups(t.width * t.height, DIRECT_TRACED_GROUP))
	points_rounds(p, batch, pipeline, &params, 1)
}

@(private = "file")
reference_gi_record :: proc(s: ^Stage_Pass, user: rawptr) {
	p := s.pass
	r, cmd, t := p.r, p.cmd, p.t
	gi := (^Reference_Gi)(user)
	pipeline := stage_pipeline(r, {stage = .Custom, shader = "gi_reference", name = "reference gi"})
	if pipeline == 0 {return}
	restart := !s.history || gi.view != p.frame.view_proj_unjittered || gi.eye != p.camera.position || gi.settings != r.settings
	gi.view, gi.eye, gi.settings = p.frame.view_proj_unjittered, p.camera.position, r.settings
	Params :: struct {paths, bounces, reset: u32, sun_radius: f32, resume, pad0, pad1, pad2: u32}
	params := Params{paths = GI_REFERENCE_PATHS, bounces = GI_REFERENCE_BOUNCES, reset = u32(restart), sun_radius = r.settings.sun_radius}
	batch := points_begin(p)
	rhi.cmd_bind_pipeline(cmd, pipeline)
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, p.gi)
	points_bind(p)
	rhi.cmd_dispatch(cmd, groups(t.width, 8), groups(t.height, 8))
	// A pixel goes on from each surface with a program its paths meet: a round for each, at most.
	points_rounds(p, batch, pipeline, &params, int(GI_REFERENCE_PATHS * GI_REFERENCE_BOUNCES))
}
