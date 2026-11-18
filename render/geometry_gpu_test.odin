package mirai_render

import "core:math"
import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:render/abi"
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
	scene_given(r, {{object_id = 1, mesh = mesh, transform = far, tint = 1}}, nil, {}, {})
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
	scene_given(r, nil, nil, {}, {})
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
	// And an instance of the scene behind it, which the wall hides as well.
	hidden := Mat4(1)
	hidden[2, 3] = 20
	scene_given(r, {{object_id = 1, mesh = cube, transform = wall, tint = 1}, {object_id = 2, mesh = cube, transform = hidden, tint = 1}}, nil, {}, {})
	N :: 30
	field := make([]Batch_Instance, N * N, context.temp_allocator)
	for &b, i in field {b = batch_instance({f32(i % N) - N / 2, f32(i / N) * 0.7 - 10, 20}, 1, {0.5, 0.5, 0.5})}
	_, error := batch_set(r, 0, r.world_key, {mesh = cube, tint = 1}, field)
	testing.expect_value(t, error, "")
	camera := Camera{position = {0, 0, -10}, forward = {0, 0, 1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 200, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 6 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	testing.expectf(t, r.stats.visible_kinds[.Batch].clusters == 0, "behind the wall the field is hidden: %v", r.stats.visible_kinds[.Batch])
	testing.expectf(t, r.stats.visible_kinds[.Single].instances == 1 && r.stats.visible_late.instances == 0, "the wall is drawn in phase 0 and hides the instance behind it: %v, late %v", r.stats.visible_kinds[.Single], r.stats.visible_late)
	// The wall goes: the pyramid of the frame before still hides the field, phase 1 draws it.
	scene_given(r, nil, nil, {}, {})
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

// Phase 0 tests an instance where it was against the pyramid of the frame
// before, which drew it there: one that moves away behind where it was is
// drawn in phase 0, not hidden by itself and left to phase 1.
@(test)
gpu_what_moves_away_is_drawn_in_phase_0 :: proc(t: ^testing.T) {
	f: Fixture
	if !skin_fixture(t, &f, false) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	box := [8]Mesh_Vertex{}
	for &v, i in box {v = {position = {f32(i & 1) - 0.5, f32(i >> 1 & 1) - 0.5, f32(i >> 2) - 0.5}, normal = {0, 1, 0}, color = 1, tangent = {1, 0, 0, 1}}}
	indices := [36]u32{0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5}
	cube, added := mesh_add(r, box[:], indices[:])
	if !testing.expect(t, added) {return}
	at :: proc(z: f32) -> (m: Mat4) {
		m = Mat4(1)
		m[0, 0], m[1, 1], m[2, 2], m[2, 3] = 3, 3, 3, z
		return
	}
	scene_given(r, {{object_id = 1, mesh = cube, transform = at(-4), tint = 1}}, nil, {}, {})
	camera := Camera{position = {0, 0, 0}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 200, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	late: Visible_Kind
	for step in 0 ..< 8 {
		testing.expect(t, scene_move(r, {0}, {at(-4 - 2 * f32(step + 1))}))
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
		late.instances = max(late.instances, r.stats.visible_late.instances)
		late.clusters = max(late.clusters, r.stats.visible_late.clusters)
	}
	testing.expectf(t, r.stats.visible_kinds[.Single].instances == 1, "the cube is drawn: %v", r.stats.visible_kinds[.Single])
	testing.expectf(t, late.instances == 0 && late.clusters == 0, "phase 1 drew none of it: %v", late)
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}

// The clusters whose pixels their alpha decides are drawn nearest first: the
// visible list holds them by the depth of their boxes, whatever order the
// cull found them in, and the triangles their draw lists follow that order,
// so the depth test turns away what they hide before their alpha runs.
@(test)
gpu_masked_clusters_are_drawn_nearest_first :: proc(t: ^testing.T) {
	f: Fixture
	if !skin_fixture(t, &f, false) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	box := [8]Mesh_Vertex{}
	for &v, i in box {v = {position = {f32(i & 1) - 0.5, f32(i >> 1 & 1) - 0.5, f32(i >> 2) - 0.5}, normal = {0, 1, 0}, color = 1, tangent = {1, 0, 0, 1}}}
	indices := [36]u32{0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5}
	cube, added := mesh_add(r, box[:], indices[:])
	if !testing.expect(t, added) {return}
	masked := DEFAULT_MATERIAL
	masked.alpha_mode = .Mask
	materials_set(r, {masked})
	// Farthest first, side by side so none hides another.
	N :: 8
	instances: [N]Instance_Desc
	for &instance, i in instances {
		transform := Mat4(1)
		transform[0, 3], transform[2, 3] = f32(i % 2) * 2 - 1, -4 - 6 * f32(N - 1 - i)
		instance = {object_id = u64(i + 1), mesh = cube, transform = transform, material = 1, tint = 1}
	}
	scene_given(r, instances[:], nil, {}, {})
	camera := Camera{position = {0, 0, 0}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 200, exposure = UNIT_EXPOSURE}
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	rhi.device_wait_idle(device)
	state: [1]Gpu_Cull_State
	if !testing.expect(t, rhi.buffer_read_slice(device, r.scene.cull_state_buffer, 0, state[:])) {return}
	counts := state[0].bin_counts[0]
	if !testing.expectf(t, counts[RASTER_BIN_TESTED] == N, "every cube is drawn tested in phase 0: %v", counts) {return}
	first := u32(0)
	for count in counts[:RASTER_BIN_TESTED] {first += count}
	visible: [N]Gpu_Visible_Cluster
	if !testing.expect(t, rhi.buffer_read_slice(device, r.scene.visible_buffer, u64(first) * size_of(Gpu_Visible_Cluster), visible[:])) {return}
	depth_of :: proc(r: ^Renderer, entry: Gpu_Visible_Cluster) -> f32 {
		inst := r.scene.instances[entry.instance]
		return -(inst.bounds_min.z + inst.bounds_max.z) * 0.5
	}
	last := f32(0)
	for entry, k in visible {
		depth := depth_of(r, entry)
		testing.expectf(t, depth >= last, "entry %d at %v m is not behind the one before, at %v m", k, depth, last)
		last = depth
	}
	// A cube shows the camera one to three of its six faces, and its draw lists no other.
	draw := state[0].draws[0][RASTER_BIN_TESTED]
	triangles := draw.index_count / 3
	if !testing.expectf(t, triangles >= 2 * N && triangles <= 6 * N && draw.first_index == draw.first_instance * 3, "the draw lists the triangles that face the camera: %v", draw) {return}
	ids := make([]u32, triangles, context.temp_allocator)
	if !testing.expect(t, rhi.buffer_read_slice(device, r.scene.raster_ids, u64(draw.first_instance) * size_of(u32), ids)) {return}
	last = 0
	for id, k in ids {
		entry := (id - 1) / asset.CLUSTER_TRIANGLES
		if !testing.expectf(t, id != 0 && entry >= first && entry < first + N, "triangle %d of the draw is of a cluster of its bin: %d", k, id) {return}
		depth := depth_of(r, visible[entry - first])
		testing.expectf(t, depth >= last, "triangle %d at %v m is not behind the one before, at %v m", k, depth, last)
		last = depth
	}
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}

// SHEETS sheets of SHEET_SIDE^2 * 2 triangles one above another, seen from
// above by SHEETS_CAMERA, each triangle wider than a pixel and half of them
// turned down, which the raster of a one-sided material leaves out: of each
// sheet, one cluster, SHEETS_SHOWN triangles show in all.
SHEET_SIDE :: 8
SHEETS :: 12
SHEETS_SHOWN :: SHEETS * SHEET_SIDE * SHEET_SIDE
SHEETS_CAMERA :: Camera{position = {0, 3, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}

test_sheet :: proc(t: ^testing.T, r: ^Renderer) -> (sheet: Mesh_Handle, ok: bool) {
	SIDE :: SHEET_SIDE
	vertices: [(SIDE + 1) * (SIDE + 1)]Mesh_Vertex
	for &v, i in vertices {
		v = {position = {f32(i % (SIDE + 1)) * 0.25 - 1, 0, f32(i / (SIDE + 1)) * 0.25 - 1}, normal = {0, 1, 0}, tangent = {1, 0, 0, 1}, color = {1, 1, 1}}
	}
	indices: [SIDE * SIDE * 6]u32
	for quad in 0 ..< u32(SIDE * SIDE) {
		a := quad / SIDE * (SIDE + 1) + quad % SIDE
		b, c, d := a + 1, a + SIDE + 2, a + SIDE + 1
		copy(indices[quad * 6:], []u32{a, c, b, a, d, c} if quad % 2 == 0 else []u32{a, b, c, a, c, d})
	}
	added: bool
	sheet, added = mesh_add(r, vertices[:], indices[:])
	return sheet, testing.expect(t, added, r.error)
}

test_sheets_placed :: proc(sheet: Mesh_Handle) -> (instances: [SHEETS]Instance_Desc) {
	for &instance, i in instances {
		transform := Mat4(1)
		transform[1, 3] = -f32(i)
		instance = {object_id = u64(i + 1), mesh = sheet, transform = transform, tint = 1}
	}
	return
}

test_sheets :: proc(t: ^testing.T, r: ^Renderer) -> bool {
	sheet := test_sheet(t, r) or_return
	instances := test_sheets_placed(sheet)
	return testing.expect(t, scene_given(r, instances[:], nil, {}, {}), r.error)
}

// The lists that grow, grow to what the frame needs most: those of the cull
// to the view of the frame that counted most, not the last one; the indices
// of the meshes drawn whole to what the frame drew of them.
@(test)
gpu_cull_lists_grow_to_the_view_of_the_frame_that_needs_most :: proc(t: ^testing.T) {
	settings := DEFAULT_SETTINGS
	settings.gi_enabled, settings.taa = false, false
	Case :: enum {Views, Meshes_Drawn_Whole}
	for c in Case {
		f: Fixture
		if !fixture_init(t, &f, 128, 128, settings) {return}
		defer fixture_destroy(&f)
		r := f.renderer
		sheet, made := test_sheet(t, r)
		if !made {return}
		instances := test_sheets_placed(sheet)
		switch c {
		case .Views:
			if !testing.expect(t, scene_given(r, instances[:], nil, {}, {}), r.error) {return}
			// The first view sees every sheet; the second, after it, looks away from them.
			away := SHEETS_CAMERA
			away.forward, away.up = {0, 1, 0}, {0, 0, 1}
			views := [2]Frame_View{{camera = SHEETS_CAMERA, rect = {0, 0, 128, 128}}, {camera = away, rect = {0, 0, 128, 128}}}
			for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = SHEETS_CAMERA, views = views[:]}), r.error)}
			testing.expectf(t, r.scene.cull_wanted[.Raster_Triangles] == (SHEETS_SHOWN + 2) / 3, "the list asks for a third of the first view: %d of %d", r.scene.cull_wanted[.Raster_Triangles], SHEETS_SHOWN)
		case .Meshes_Drawn_Whole:
			// The highlighted sheets draw their mesh whole, which the list first has no room for.
			for &instance in instances {instance.highlight = 1}
			if !testing.expect(t, scene_given(r, instances[:], nil, {}, {}), r.error) {return}
			needed := r.scene.meshes[sheet].cluster_count * CLUSTER_DRAW_VERTICES
			testing.expect(t, renderer_frame(r, {camera = SHEETS_CAMERA}), r.error)
			r.scene.mesh_draws_capacity, r.scene.mesh_draws_wanted = needed - 1, 0
			testing.expect(t, renderer_frame(r, {camera = SHEETS_CAMERA}), r.error)
			testing.expect(t, !r.scene.meshes[sheet].draw_listed, "a mesh the list has no room for is not drawn")
			for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = SHEETS_CAMERA}), r.error)}
			testing.expectf(t, r.scene.mesh_draws_wanted == needed && r.scene.meshes[sheet].draw_listed, "the list asks for what the frame drew: %d of %d", r.scene.mesh_draws_wanted, needed)
		}
		testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "%v: validation: %s", c, rhi.device_validation_message(f.device))
	}
}

// A frame that draws a mesh whole for the first time, for a first
// translucent, a first overlay and a first highlight, allocates nothing and
// takes nothing of the pools: its indices go to the list the renderer keeps. Other meshes go through the same
// first, so that the pipelines they ask for are made before.
@(test)
gpu_meshes_drawn_whole_for_the_first_time_allocate_nothing :: proc(t: ^testing.T) {
	settings := DEFAULT_SETTINGS
	settings.gi_enabled, settings.taa = false, false
	f: Fixture
	if !fixture_init(t, &f, 64, 64, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	glass, glow := DEFAULT_MATERIAL, DEFAULT_MATERIAL
	glass.alpha_mode, glass.opacity = .Blend, 0.5
	glow.emission, glow.opacity = {1, 0, 0}, 0.5
	materials_set(r, {glass, glow})
	// A mesh each, so that each change draws one whole for the first time.
	instances: [6]Instance_Desc
	for &instance, i in instances {
		sheet, made := test_sheet(t, r)
		if !made {return}
		transform := Mat4(1)
		transform[0, 3] = f32(i % 3) * 0.7 - 0.7
		instance = {object_id = u64(i + 1), mesh = sheet, transform = transform, tint = 1}
	}
	if !testing.expect(t, scene_given(r, instances[:], nil, {}, {}), r.error) {return}
	settle :: proc(t: ^testing.T, f: ^Fixture) {
		for _ in 0 ..< 3 {testing.expect(t, fixture_frame(f, {camera = SHEETS_CAMERA}), f.renderer.error)}
		renderer_pipelines_wait(f.renderer, all = true)
		testing.expect(t, fixture_frame(f, {camera = SHEETS_CAMERA}), f.renderer.error)
	}
	settle(t, &f)
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	Change :: enum {Translucent, Overlay, Highlight}
	for round in 0 ..< 2 {
		for change in Change {
			at := int(change) + round * 3
			switch change {
			case .Translucent: instances[at].material = 1
			case .Overlay: instances[at].overlays = {count = 1, entries = {0 = {id = 1, material = 2, blend = .Alpha, enabled = true}}}
			case .Highlight: instances[at].highlight = 1
			}
			if !testing.expect(t, scene_update(r, 0, instances[:]), r.error) {return}
			allocations, pooled := tracking.total_allocation_count, len(r.scene.indices)
			{
				context.allocator = mem.tracking_allocator(&tracking)
				testing.expect(t, fixture_frame(&f, {camera = SHEETS_CAMERA}), r.error)
			}
			if round == 1 {
				testing.expectf(t, tracking.total_allocation_count == allocations, "a first %v allocates %d times", change, tracking.total_allocation_count - allocations)
				testing.expectf(t, len(r.scene.indices) == pooled, "a first %v takes %d words of the index pool", change, len(r.scene.indices) - pooled)
			}
			settle(t, &f)
		}
	}
	for instance in instances {testing.expectf(t, r.scene.meshes[instance.mesh].draw_listed, "the mesh of %d is drawn whole", instance.object_id)}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A view whose triangles pass the share of the lists a round of its raster
// takes (Scene_State.raster_share) shows them all: the clusters that find no
// room in a round are listed and drawn in the round after, the last too, and
// the list then asks for a third of what the view writes: the triangles that
// show, also of a cluster the last round left out.
@(test)
gpu_triangles_past_their_list_are_drawn_in_the_rounds_after :: proc(t: ^testing.T) {
	settings := DEFAULT_SETTINGS
	settings.gi_enabled, settings.taa = false, false
	f: Fixture
	if !fixture_init(t, &f, 128, 128, settings) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	camera := SHEETS_CAMERA
	// A frame of nothing makes the lists; then a round takes less than a third of what the view shows.
	if !testing.expect(t, renderer_frame(r, {camera = camera}), r.error) || !testing.expect(t, r.scene.raster_indices != 0) {return}
	SIDE :: SHEET_SIDE
	TRIANGLES :: SHEETS_SHOWN
	ROOM :: 250
	// A sheet is one cluster of SIDE * SIDE triangles that show: the rounds hold as many as the room does, whole.
	#assert(TRIANGLES > RASTER_LIST_SHARE * ROOM && ROOM / (SIDE * SIDE) * SIDE * SIDE * abi.RASTER_ROUNDS >= TRIANGLES)
	r.scene.raster_share[1] = ROOM
	if !test_sheets(t, r) {return}
	// Its first frame has no pyramid to hide a sheet behind another with.
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	rhi.device_wait_idle(device)
	state: [1]Gpu_Cull_State
	if !testing.expect(t, rhi.buffer_read_slice(device, r.scene.cull_state_buffer, 0, state[:])) {return}
	drawn: [abi.RASTER_ROUNDS]u32
	total := u32(0)
	for round, k in state[0].draws {
		for draw in round {drawn[k] += draw.index_count / 3}
		total += drawn[k]
	}
	testing.expectf(t, drawn[0] > 0 && drawn[0] <= ROOM, "the first round draws what its list holds: %v", drawn)
	testing.expectf(t, total == TRIANGLES && drawn[abi.RASTER_ROUNDS - 1] > 0 && state[0].dropped[.Raster_Triangles] == 0, "the rounds after draw the rest, the last too, and none is left out: %v of %d, %d left out", drawn, TRIANGLES, state[0].dropped[.Raster_Triangles])
	for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	THIRD :: (TRIANGLES + RASTER_LIST_SHARE - 1) / RASTER_LIST_SHARE
	testing.expectf(t, r.scene.cull_wanted[.Raster_Triangles] == THIRD && r.scene.raster_share[1] >= THIRD, "the list asks for a third of the view: %d wanted, %d a round", r.scene.cull_wanted[.Raster_Triangles], r.scene.raster_share[1])
	// A room of one sheet a round: the last round leaves sheets out.
	r.scene.cull_wanted[.Raster_Triangles], r.scene.raster_share[1] = 0, SIDE * SIDE + 1
	for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	testing.expectf(t, r.scene.cull_wanted[.Raster_Triangles] == THIRD, "the list asks for a third of the triangles that show, of what was left out too: %d", r.scene.cull_wanted[.Raster_Triangles])
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
	camera := Camera{position = {0, 0, 0}, forward = {0, 0, 1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 5000, exposure = UNIT_EXPOSURE}
	// At 1000 m a pixel of this view is about 9.6 m: the box of 2 m spans under half of one, that of 60 m about eleven.
	tiny := [1]Batch_Instance{batch_instance({0, 0, 1000}, 1, {2, 2, 2})}
	large := [1]Batch_Instance{batch_instance({0, 0, 1000}, 1, {60, 60, 60})}
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
	scene_given(r, {{object_id = 1, mesh = mesh, transform = Mat4(1), tint = 1}}, nil, {}, {})
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
