package host

import "core:testing"
import render "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"

@(private = "file")
generate_shader :: proc() -> rhi.Shader_Code {
	@(static, rodata) bindings := [?]rhi.Binding_Info{
		{slot = render.SLOT_PASS0, kind = .Sampled_Texture, stages = {.Compute}},
		{slot = render.SLOT_PASS1, kind = .Storage_Texture, stages = {.Compute}},
	}
	when ODIN_OS == .Darwin {
		return {binary = {msl = #load("../shaders/build/tests/generate.comp.metal", string), msl_entry = "main0"}, name = "generate.comp", stage = .Compute, threadgroup = {8, 8, 1}, bindings = bindings[:]}
	} else {
		return {binary = {spirv = #load("../shaders/build/tests/generate.comp.spv")}, name = "generate.comp", stage = .Compute, threadgroup = {8, 8, 1}, bindings = bindings[:]}
	}
}

@(private = "file")
Generate_Pass :: struct {pipeline: rhi.Pipeline, runs: int}

@(private = "file")
generate_record :: proc(s: ^render.Stage_Pass, user: rawptr) {
	pass := cast(^Generate_Pass)user
	pass.runs += 1
	if !render.pass_resource(s, 0, .Ldr) || !render.pass_resource(s, 1, .Generated) {return}
	render.pass_pipeline(s, pass.pipeline)
	render.pass_dispatch(s, (s.output_width + 7) / 8, (s.output_height + 7) / 8)
}

// A window whose pipeline generates frames presents through the thread of
// the device: from the second frame on, the generated image and its own.
// Without generation the thread stops once it presented what it was given.
@(test)
a_window_that_generates_frames_presents_two_images_a_frame :: proc(t: ^testing.T) {
	shared_device.hold(t)
	app, error := app_create({gpu = true, gpu_validation = true, window = true, window_desc = {size = {64, 48}, hidden = true}, fixed_dt = 1.0 / 60, threads = 1})
	if app == nil {
		testing.expectf(t, rhi.gpu_skip_allowed(), "no application with a GPU: %v (set MIRAI_ALLOW_GPU_SKIP=1 to skip)", error)
		return
	}
	defer app_destroy(app)
	r := app.renderer
	shader := generate_shader()
	pipeline := rhi.pipeline_create_compute(app.device, {shader = &shader, name = "generate"})
	if !testing.expect(t, pipeline != 0, rhi.device_error(app.device)) {return}
	defer rhi.pipeline_destroy(app.device, pipeline)
	pass := Generate_Pass{pipeline = pipeline}
	uses := []render.Render_Use{{.Ldr, .Read, false}, {.Generated, .Write, false}}
	passes := make([dynamic]render.Render_Pass_Desc, context.temp_allocator)
	append(&passes, ..render.standard_pipeline_passes(.Full))
	append(&passes, render.Render_Pass_Desc{stage = .Custom, name = "generate", uses = uses, record = generate_record, user = &pass})
	camera := render.Camera{position = {0, 1, 3}, forward = {0, -1, -3}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = render.UNIT_EXPOSURE}
	before := rhi.present_stats(app.device)
	FRAMES :: 6
	for frame in 0 ..< FRAMES {
		handle, compile_error := render.renderer_pipeline(r, {passes = passes[:]})
		if !testing.expect(t, handle != 0, compile_error) {return}
		render.renderer_main_pipeline(r, handle)
		testing.expectf(t, render.renderer_frame(r, {camera = camera, time = f32(frame) / 60}), "frame %d: %s", frame, r.error)
		testing.expect_value(t, render.renderer_stats(r).generated, frame > 0)
		testing.expect(t, rhi.present_stats(app.device).paced)
	}
	testing.expect_value(t, pass.runs, FRAMES)
	// The Full pipeline generates nothing: the thread presents what it holds and stops.
	testing.expect(t, render.renderer_frame(r, {camera = camera, time = f32(FRAMES) / 60}), r.error)
	after := rhi.present_stats(app.device)
	testing.expect(t, !after.paced)
	testing.expect_value(t, after.generated - before.generated, u64(FRAMES - 1))
	testing.expect_value(t, after.presented - before.presented, u64(2 * FRAMES))
	testing.expectf(t, rhi.device_validation_errors(app.device) == 0, "validation: %s", rhi.device_validation_message(app.device))
}
