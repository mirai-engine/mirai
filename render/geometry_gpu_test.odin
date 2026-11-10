package mirai_render

import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:rhi"
import mm "mirai:std/math"

// Traced by hardware, a coarser cut of a mesh gets its native BLAS once an
// instance wants it, the instance traces it from then on, and the BLAS goes
// RAY_CUT_KEEP frames after no instance wants it.
@(test)
gpu_a_coarser_ray_cut_is_built_while_an_instance_wants_it :: proc(t: ^testing.T) {
	f: Fixture
	if !skin_fixture(t, &f, true) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	if !r.hardware_rt {return}
	// A rolling grid: its DAG has coarser cuts rays may trace far away.
	CELLS :: 48
	vertices := make([dynamic]asset.Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	for z in 0 ..= CELLS {for x in 0 ..= CELLS {
		p := Vec3{f32(x) * 0.25, 0.4 * math.sin(f32(x) * 0.7) * math.cos(f32(z) * 0.5), f32(z) * 0.25}
		append(&vertices, asset.Vertex{position = p, normal = mm.normal_pack({0, 1, 0}), uv = {f32(x), f32(z)} / CELLS, color = 0xffffffff, tangent = mm.tangent_pack({1, 0, 0}, 1)})
	}}
	for z in 0 ..< u32(CELLS) {for x in 0 ..< u32(CELLS) {
		a := z * (CELLS + 1) + x
		append(&indices, a, a + CELLS + 1, a + 1, a + 1, a + CELLS + 1, a + CELLS + 2)
	}}
	g: asset.Mesh_Geometry
	if !testing.expect(t, asset.mesh_build_dag({vertices = vertices[:]}, indices[:], &g, context.temp_allocator)) {return}
	if !testing.expect(t, g.ray_errors[0] > 0, "the grid has a coarser cut") {return}
	mesh, added := mesh_add_geometry(r, g, nil)
	if !testing.expect(t, added) {return}
	accels := rhi.device_stats(device).accels
	far := Mat4(1)
	far[0, 3], far[2, 3] = 0, -400
	scene_set(r, {{object_id = 1, mesh = mesh, transform = far, tint = 1}}, nil, {}, {})
	camera := Camera{position = {6, 8, 20}, forward = {0, -0.3, -1}, up = {0, 1, 0}, fov_y = 50, near = 0.1, far = 1000, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	m := &r.scene.meshes[mesh]
	cut := r.scene.instances[0].meta.x >> INSTANCE_RAY_SHIFT & 3
	testing.expectf(t, cut > 0 && m.rays[cut].blas != 0, "far away the instance traces a coarser cut with its BLAS: cut %d", cut)
	testing.expect(t, rhi.device_stats(device).accels > accels, "the BLAS of the cut was made")
	built := 0
	for ray in m.rays[1:m.ray_count] {if ray.blas != 0 {built += 1}}
	testing.expectf(t, built == 1, "only the cut wanted has its BLAS: %d", built)
	// Without instances nothing wants it: it stays a while, then goes.
	scene_set(r, nil, nil, {}, {})
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	testing.expect(t, m.rays[cut].blas != 0, "a cut nobody wants keeps its BLAS a while")
	r.frame += RAY_CUT_KEEP + 1
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	testing.expect(t, m.rays[cut].blas == 0, "and lets it go after RAY_CUT_KEEP frames")
	testing.expect(t, m.rays[0].blas != 0, "level 0 keeps its BLAS")
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}

// Phase 1 of the occlusion draws once what the pyramid of the frame before
// hid and this one shows: a field behind a wall that goes is drawn as many
// times as when it stays in sight, and the pyramid the next frame tests
// against holds it.
@(test)
gpu_what_phase_1_rescues_is_drawn_once :: proc(t: ^testing.T) {
	f: Fixture
	if !skin_fixture(t, &f, false) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	box := [8]Mesh_Vertex{}
	for &v, i in box {v = {position = {f32(i & 1) - 0.5, f32(i >> 1 & 1) - 0.5, f32(i >> 2) - 0.5}, normal = {0, 1, 0}, color = 1, tangent = {1, 0, 0, 1}}}
	indices := [36]u32{0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5}
	cube, added := mesh_add(r, box[:], indices[:])
	if !testing.expect(t, added) {return}
	wall := Mat4(1)
	wall[0, 0], wall[1, 1], wall[2, 2], wall[2, 3] = 60, 60, 1, 5
	scene_set(r, {{object_id = 1, mesh = cube, transform = wall, tint = 1}}, nil, {}, {})
	N :: 30
	field := make([]Batch_Instance, N * N, context.temp_allocator)
	for &b, i in field {b = batch_instance({f32(i % N) - N / 2, f32(i / N) * 0.7 - 10, 20}, 1, 0.5, 0.5)}
	_, error := batch_set(r, 0, r.world_key, {mesh = cube, tint = 1}, field)
	testing.expect_value(t, error, "")
	camera := Camera{position = {0, 0, -10}, forward = {0, 0, 1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 200, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 6 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	testing.expectf(t, r.stats.visible_kinds[.Batch].clusters == 0, "behind the wall the field is hidden: %v", r.stats.visible_kinds[.Batch])
	// The wall goes: the pyramid of the frame before still hides the field, phase 1 draws it.
	scene_set(r, nil, nil, {}, {})
	most: u32
	late: u32
	for _ in 0 ..< 6 {
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
		most = max(most, r.stats.visible_kinds[.Batch].clusters)
		late = max(late, r.stats.visible_late.clusters)
	}
	steady := r.stats.visible_kinds[.Batch].clusters
	testing.expect(t, late > 0, "phase 1 rescued the field")
	testing.expectf(t, steady > 0 && most == steady, "drawn once: at most %d clusters, %d once it settles", most, steady)
	testing.expect_value(t, r.stats.visible_late.clusters, u32(0))
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}

// An instance of a batch smaller on the screen than Settings.batch_min_pixels
// is not rasterized; one twice as large is, and without the setting every one.
@(test)
gpu_instances_of_batches_smaller_than_a_pixel_are_not_rasterized :: proc(t: ^testing.T) {
	f: Fixture
	if !skin_fixture(t, &f, false) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	box := [8]Mesh_Vertex{}
	for &v, i in box {v = {position = {f32(i & 1) - 0.5, f32(i >> 1 & 1) - 0.5, f32(i >> 2) - 0.5}, normal = {0, 1, 0}, color = 1, tangent = {1, 0, 0, 1}}}
	indices := [36]u32{0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5}
	cube, _ := mesh_add(r, box[:], indices[:])
	settings := r.settings
	settings.occlusion_culling = false
	testing.expect(t, renderer_apply_settings(r, settings))
	camera := Camera{position = {0, 0, 0}, forward = {0, 0, 1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 5000, exposure = UNIT_EXPOSURE}
	// At 1000 m a pixel of this view is about 9.6 m: the box of 2 m spans under half of one, that of 60 m about eleven.
	tiny := [1]Batch_Instance{batch_instance({0, 0, 1000}, 1, 2, 2)}
	large := [1]Batch_Instance{batch_instance({0, 0, 1000}, 1, 60, 60)}
	drawn :: proc(t: ^testing.T, r: ^Renderer, mesh: Mesh_Handle, instances: []Batch_Instance, camera: Camera) -> u32 {
		handle, error := batch_set(r, 0, r.world_key, {mesh = mesh, tint = 1}, instances)
		testing.expect_value(t, error, "")
		for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
		count := r.stats.visible_kinds[.Batch].instances
		batch_remove(r, handle)
		return count
	}
	testing.expect_value(t, drawn(t, r, cube, tiny[:], camera), u32(0))
	testing.expect_value(t, drawn(t, r, cube, large[:], camera), u32(1))
	settings.batch_min_pixels = 0
	testing.expect(t, renderer_apply_settings(r, settings))
	testing.expect_value(t, drawn(t, r, cube, tiny[:], camera), u32(1))
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}

// The detail of a frame can come from another camera: the view draws from
// its own eye the levels and ray cuts that camera would choose.
@(test)
gpu_the_detail_camera_chooses_the_levels_the_view_draws :: proc(t: ^testing.T) {
	f: Fixture
	if !skin_fixture(t, &f, false) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	CELLS :: 64
	vertices := make([dynamic]asset.Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	for z in 0 ..= CELLS {for x in 0 ..= CELLS {
		p := Vec3{f32(x) * 0.25, 0.4 * math.sin(f32(x) * 0.7) * math.cos(f32(z) * 0.5), f32(z) * 0.25}
		append(&vertices, asset.Vertex{position = p, normal = mm.normal_pack({0, 1, 0}), uv = {f32(x), f32(z)} / CELLS, color = 0xffffffff, tangent = mm.tangent_pack({1, 0, 0}, 1)})
	}}
	for z in 0 ..< u32(CELLS) {for x in 0 ..< u32(CELLS) {
		a := z * (CELLS + 1) + x
		append(&indices, a, a + CELLS + 1, a + 1, a + 1, a + CELLS + 1, a + CELLS + 2)
	}}
	g: asset.Mesh_Geometry
	if !testing.expect(t, asset.mesh_build_dag({vertices = vertices[:]}, indices[:], &g, context.temp_allocator)) {return}
	mesh, added := mesh_add_geometry(r, g, nil)
	if !testing.expect(t, added) {return}
	scene_set(r, {{object_id = 1, mesh = mesh, transform = Mat4(1), tint = 1}}, nil, {}, {})
	near := Camera{position = {8, 3, 18}, forward = {0, -0.3, -1}, up = {0, 1, 0}, fov_y = 50, near = 0.1, far = 1000, exposure = UNIT_EXPOSURE}
	far := near
	far.position = {8, 60, 400}
	drawn :: proc(t: ^testing.T, r: ^Renderer, frame: Frame_Desc) -> (clusters: u32) {
		for _ in 0 ..< 6 {testing.expect(t, renderer_frame(r, frame), r.error)}
		return r.stats.visible_kinds[.Levels].clusters
	}
	own := drawn(t, r, {camera = near})
	chosen := drawn(t, r, {camera = near, detail = {camera = far, on = true}})
	again := drawn(t, r, {camera = near})
	testing.expectf(t, own > 0 && chosen > 0 && chosen < own, "from far the cut is coarser: %d clusters, %d from its own eye", chosen, own)
	testing.expect_value(t, again, own)
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}
