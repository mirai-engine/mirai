package mirai_render

import "core:testing"
import "mirai:rhi"

// On the GPU: a streamed sheet seen from near asks for its pages, the CPU
// loads them, and they stay; seen from far, only its root draws.
@(test)
gpu_streamed_pages_load_what_a_near_view_asks_for :: proc(t: ^testing.T) {
	settings := DEFAULT_SETTINGS
	settings.reflections, settings.taa = false, false
	settings.page_pool_bytes = 64 * PAGE_SLOT_WORDS * 4
	f: Fixture
	if !fixture_init(t, &f, 256, 256, settings) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	g, ok := streamed_sheet(256)
	if !testing.expect(t, ok, "the sheet has pages out of its root") {return}
	mesh, added := mesh_add_geometry(r, g, nil)
	if !testing.expect(t, added, r.error) {return}
	scene_set(r, {Instance_Desc{object_id = 1, mesh = mesh, transform = Mat4(1)}}, nil, {}, {})
	far := Camera{position = {128, 2000, -2000}, forward = {0, -2000, 2128}, up = {0, 1, 0}, fov_y = 50, near = 0.1, far = 10000, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 8 {testing.expect(t, renderer_frame(r, {camera = far}), r.error)}
	from_far := r.stats.pages_resident
	near := Camera{position = {128, 3, 120}, forward = {0, -1, 2}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 1000, exposure = UNIT_EXPOSURE}
	loaded := 0
	for _ in 0 ..< 60 {
		testing.expect(t, renderer_frame(r, {camera = near}), r.error)
		loaded += int(r.stats.pages_loaded)
	}
	testing.expectf(t, loaded > 0 && r.stats.pages_resident > from_far, "near, pages load: %d loaded, %d resident against %d from far", loaded, r.stats.pages_resident, from_far)
	testing.expect_value(t, r.stats.page_requests_dropped, 0)
	testing.expect_value(t, r.stats.problem, "")
	testing.expect_value(t, rhi.device_validation_errors(device), 0)
}
