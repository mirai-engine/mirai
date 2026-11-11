package mirai_render

import "core:testing"
import "mirai:rhi"

// On the GPU: a streamed sheet seen from near asks for its pages, the CPU
// loads them, and they stay; seen from far, only its root draws.
@(test)
gpu_streamed_pages_load_what_a_near_view_asks_for :: proc(t: ^testing.T) {
	settings := DEFAULT_SETTINGS
	settings.taa = false
	settings.page_pool_bytes = 64 * PAGE_SLOT_WORDS * 4
	f: Fixture
	if !fixture_init(t, &f, 256, 256, settings) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	g, ok := streamed_sheet(256)
	if !testing.expect(t, ok, "the sheet has pages out of its root") {return}
	mesh, added := mesh_add_geometry(r, g, nil)
	if !testing.expect(t, added, r.error) {return}
	scene_given(r, {Instance_Desc{object_id = 1, mesh = mesh, transform = Mat4(1)}}, nil, {}, {})
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

// The cull lists each page it asks for once, with the highest priority any
// cluster gave it: a sheet near the eye loads the same pages behind 2,000
// instances of another streamed mesh that ask for theirs as it does alone,
// whatever order the GPU culled them in, and no request is dropped.
@(test)
gpu_page_requests_list_each_page_once_whatever_asks_for_it :: proc(t: ^testing.T) {
	g, ok := streamed_sheet(128)
	if !testing.expect(t, ok, "the sheet has pages out of its root") {return}
	alone := -1
	for crowd in ([]int{0, 2000}) {
		settings := DEFAULT_SETTINGS
		settings.taa = false
		settings.page_pool_bytes = 1024 * PAGE_SLOT_WORDS * 4
		f: Fixture
		if !fixture_init(t, &f, 256, 256, settings) {return}
		defer fixture_destroy(&f)
		r, device := f.renderer, f.device
		near, near_added := mesh_add_geometry(r, g, nil)
		other, other_added := mesh_add_geometry(r, g, nil)
		if !testing.expect(t, near_added && other_added, r.error) {return}
		instances := make([]Instance_Desc, crowd + 1, context.temp_allocator)
		// The near sheet under the eye, and the crowd under it, hidden by it: a
		// cluster asks for its pages before the depth pyramid hides it.
		place :: proc(y: f32) -> Mat4 {
			m := Mat4(1)
			m[1, 3] = y
			return m
		}
		instances[crowd] = {object_id = 1, mesh = near, transform = place(0)}
		for k in 0 ..< crowd {instances[k] = {object_id = u64(k + 2), mesh = other, transform = place(-1 - 0.01 * f32(k))}}
		scene_given(r, instances, nil, {}, {})
		camera := Camera{position = {64, 4, -2}, forward = {0, -1, 2}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 1000, exposure = UNIT_EXPOSURE}
		dropped: u32
		for _ in 0 ..< 60 {
			testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
			dropped = max(dropped, r.stats.page_requests_dropped)
		}
		stream := r.scene.meshes[near].stream
		resident := 0
		for page in 0 ..< stream.root {resident += 1 if stream.slots[page] != PAGE_SLOT_NONE else 0}
		if crowd == 0 {
			alone = resident
			testing.expect(t, resident > 0, "alone, the near sheet loads pages")
		} else {
			testing.expectf(t, resident == alone, "behind the crowd the near sheet has %d pages in the pools, alone %d", resident, alone)
		}
		testing.expectf(t, dropped == 0, "with %d instances of the other mesh, %d requests were dropped", crowd, dropped)
		testing.expect_value(t, rhi.device_validation_errors(device), 0)
	}
}
