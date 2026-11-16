package host

import "core:testing"
import render "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"

// A frame that submits twice (an offscreen capture, then its window) gets
// the GPU passes of both submissions, though they come back in later frames.
@(test)
a_recorded_frame_keeps_the_gpu_passes_of_every_submission :: proc(t: ^testing.T) {
	shared_device.hold(t)
	app, error := app_create({gpu = true, gpu_validation = true, window_desc = {size = {64, 48}}, fixed_dt = 1.0 / 60, threads = 1})
	if app == nil {
		testing.expectf(t, rhi.gpu_skip_allowed(), "no application with a GPU: %v (set MIRAI_ALLOW_GPU_SKIP=1 to skip)", error)
		return
	}
	defer app_destroy(app)
	FRAMES :: 4
	if !testing.expect(t, profile_start(app, FRAMES)) {return}
	for _ in 0 ..< FRAMES + PROFILE_GPU_LATE {
		if !app.profiler.recording {break}
		if !testing.expect(t, app_frame_begin(app)) {return}
		if app.profiler.late == 0 {testing.expect(t, render.renderer_frame(app.renderer, {offscreen = true, ui_only = true, time = app.time}), app.renderer.error)}
		app_frame_end(app)
	}
	recording := profile_recording(app)
	testing.expect(t, recording.complete, "the recording waited for the GPU times of its last frame")
	testing.expect_value(t, len(recording.frames), FRAMES)
	for frame, i in recording.frames {
		testing.expectf(t, frame.drawn, "frame %d drew", i)
		testing.expect_value(t, frame.device_end - frame.device_first, 2)
		testing.expectf(t, profile_gpu_measured(frame), "frame %d got %d of its 2 submissions", i, frame.gpu_submissions)
		total: f64
		for pass in recording.passes[frame.pass_first:][:frame.pass_count] {
			testing.expectf(t, pass.end_ns >= pass.start_ns, "frame %d: a pass ends before it starts", i)
			total += f64(pass.end_ns - pass.start_ns) / 1e6
		}
		testing.expectf(t, abs(total - f64(frame.gpu_ms)) < 0.01, "frame %d: gpu_ms %.3f is not the sum of its passes %.3f", i, frame.gpu_ms, total)
	}
	testing.expectf(t, rhi.device_validation_errors(app.device) == 0, "validation: %s", rhi.device_validation_message(app.device))
}
