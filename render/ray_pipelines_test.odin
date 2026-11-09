package mirai_render

import "core:fmt"
import "core:testing"
import "mirai:rhi"
import "mirai:rhi/shared_device"

@(private = "file")
rays_renderer :: proc(t: ^testing.T, trace_mode: Trace_Mode) -> ^Renderer {
	device, err := shared_device.take(t)
	if device == nil {
		if rhi.gpu_skip_allowed() {fmt.eprintln("ray pipeline tests skipped:", err)} else {testing.expectf(t, false, "no GPU device: %s (set MIRAI_ALLOW_GPU_SKIP=1 to skip)", err)}
		return nil
	}
	settings := DEFAULT_SETTINGS
	settings.trace_mode = trace_mode
	r := new(Renderer)
	if !renderer_init(r, {device = device, width = 64, height = 48, settings = settings, rays_later = true}) {
		testing.expect(t, false, r.error)
		free(r)
		return nil
	}
	// The scene shows a flat gray around nothing; a frame of the UI alone is black.
	renderer_set_backdrop(r, {0.5, 0.5, 0.5})
	return r
}

@(private = "file")
rays_lit :: proc(t: ^testing.T, r: ^Renderer) -> bool {
	testing.expect(t, renderer_frame(r, {camera = {position = {0, 1, 4}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}}), r.error)
	pixels, _, _, ok := renderer_capture(r)
	defer delete(pixels)
	if !testing.expect(t, ok, "capture") {return false}
	for i := 0; i + 3 < len(pixels); i += 4 {
		if pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 0 {return true}
	}
	return false
}

// With rays_later the renderer opens without the pipelines of software rays:
// its frames draw only the UI, black here, until they are in place, and the
// sky after.
@(test)
rays_made_later_hold_the_scene_until_they_are_in_place :: proc(t: ^testing.T) {
	r := rays_renderer(t, .Software)
	if r == nil {return}
	defer {renderer_destroy(r); free(r)}
	total := renderer_rays_total(r)
	testing.expect(t, total > 0, "software rays are made later")
	testing.expect(t, renderer_rays_pending(r) <= total, "pending counts down as the driver makes them")
	testing.expect_value(t, r.pipelines[.Reflect], 0)
	made := renderer_pipelines_made(r)
	// A frame puts in place those made before it begins: still not all made
	// after it, they were not as it began. On a warm cache they may be by then.
	lit := rays_lit(t, r)
	if renderer_rays_pending(r) > 0 {testing.expect(t, !lit, "a frame without the pipelines of its rays draws no scene")}
	renderer_rays_wait(r)
	testing.expect_value(t, renderer_rays_pending(r), 0)
	testing.expect(t, r.pipelines[.Reflect] != 0, "the pipelines are in place")
	testing.expect_value(t, renderer_pipelines_made(r), made + u64(total))
	failed, _ := renderer_rays_failed(r)
	testing.expect(t, !failed, r.error)
	testing.expect(t, rays_lit(t, r), "once they are in place the frame draws the scene")
}

// A device that traces rays by hardware never makes those of software, until
// the settings ask for them.
@(test)
rays_by_hardware_leave_the_software_ones_unmade :: proc(t: ^testing.T) {
	r := rays_renderer(t, .Auto)
	if r == nil {return}
	defer {renderer_destroy(r); free(r)}
	if !r.hardware_rt {
		testing.expect(t, renderer_rays_total(r) > 0, "without rays by hardware the software ones are made later")
		return
	}
	testing.expect_value(t, renderer_rays_total(r), 0)
	testing.expect_value(t, renderer_rays_pending(r), 0)
	testing.expect_value(t, r.pipelines[.Reflect], 0)
	settings := r.settings
	settings.trace_mode = .Software
	testing.expect(t, renderer_apply_settings(r, settings), r.error)
	testing.expect(t, renderer_rays_total(r) > 0, "Trace_Mode.Software starts them")
	renderer_rays_wait(r)
	testing.expect_value(t, renderer_rays_pending(r), 0)
}

// At least one thread, at most a physical core each, and one alone for a
// pipeline the free memory holds once.
@(test)
pipeline_threads_follow_the_cores_and_the_free_memory :: proc(t: ^testing.T) {
	threads := pipeline_threads(1)
	testing.expect(t, threads >= 1 && threads <= PIPELINE_THREADS_MAX, fmt.tprintf("%d threads", threads))
	testing.expect_value(t, pipeline_threads(1 << 40), 1)
	testing.expect(t, pipeline_threads(0) >= 1, "without a cost, the cores")
}
