package mirai_render

import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:rhi"

@(private = "file")
square_stream :: proc(side: u32, top: u8, lod: f32, shown := true) -> (stream: Texture_Stream) {
	stream.size, stream.format, stream.top, stream.target = {side, side}, .RGBA8_Unorm, top, top
	stream.span = math.log2(f32(side))
	for s := side; ; s /= 2 {
		stream.levels += 1
		if s <= 1 {break}
	}
	texture_chain(&stream)
	stream.lod, stream.shown = lod, shown
	return
}

// A texture comes to the level its distance asks for, TEXTURE_FILTER_LEVELS
// finer, at once when it needs more levels and only TEXTURE_KEEP_LEVELS past
// it when it needs fewer; between the largest max_size takes and the one of
// side TEXTURE_TAIL. One nothing shows keeps the levels it has.
@(test)
a_streamed_texture_follows_its_distance_with_hysteresis_within_its_range :: proc(t: ^testing.T) {
	target :: proc(top: u8, lod: f32, max_size := 4096) -> u8 {
		stream := square_stream(1024, top, lod)
		return texture_target(&stream, max_size, 0)
	}
	testing.expect_value(t, target(0, 4.5), 3)
	testing.expect_value(t, target(3, 4.2), 3)
	testing.expect_value(t, target(3, 3.9), 2)
	testing.expect_value(t, target(2, 4.1), 2) // without the hysteresis it would be 3
	testing.expect_value(t, target(2, 4.4), 3)
	testing.expect_value(t, target(5, -8), 0)
	testing.expect_value(t, target(0, 20), 3) // 1024 >> 3 is TEXTURE_TAIL
	testing.expect_value(t, target(0, -8, 512), 1)
	testing.expect_value(t, target(0, math.F32_MAX), 3) // shown where its uv do not change
	unseen := square_stream(1024, 1, 9, shown = false)
	testing.expect_value(t, texture_target(&unseen, 4096, 0), 1)
	small := square_stream(64, 0, 9)
	first, last := texture_level_range(&small, 4096)
	testing.expect(t, first == 0 && last == 0, "a texture smaller than the tail keeps every level")
}

// While the levels their distance asks for take more than the room of the
// pool, every streamed texture takes the same share of a level more: the
// farther comes coarser, and what is left fits.
@(test)
past_the_pool_every_texture_takes_the_same_share_of_a_level_more :: proc(t: ^testing.T) {
	streams := []Texture_Stream{square_stream(1024, 0, 1.5), square_stream(1024, 0, 0.5)}
	whole := streams[0].chain[0]
	bias, reduced, pending := texture_targets(streams, 4096, u64(f64(whole) * 1.1))
	total := streams[0].chain[streams[0].target] + streams[1].chain[streams[1].target]
	testing.expectf(t, total <= u64(f64(whole) * 1.1), "%d bytes do not fit the room", total)
	testing.expectf(t, bias > 0 && streams[0].target > streams[1].target, "bias %v, targets %d and %d", bias, streams[0].target, streams[1].target)
	testing.expect_value(t, reduced, 2)
	testing.expect_value(t, pending, 2)
	// With room, each keeps what its distance asks for.
	bias, reduced, _ = texture_targets(streams, 4096, max(u64))
	testing.expect(t, bias == 0 && reduced == 0 && streams[0].target == 0 && streams[1].target == 0)
	// One nothing shows gives its levels up only past a level and its hysteresis of bias.
	streams[1].shown = false
	texture_targets(streams, 4096, streams[0].chain[0] + streams[1].chain[1])
	testing.expect_value(t, streams[1].target, 0)
}

// The level a view asks for: the distance to the box of the instance over the
// pixels a metre spans one metre away, the uv the mesh spans per metre, the
// scale of the instance, the transform of the map and the size of the source.
@(test)
the_estimate_takes_the_nearest_instance_that_shows_a_texture :: proc(t: ^testing.T) {
	s: Scene_State
	defer {delete(s.instances);delete(s.overlays);delete(s.meshes);delete(s.indices);delete(s.materials)}
	append(&s.meshes, Mesh_Record{vertex_count = 4, slot_count = 1})
	append(&s.indices, 0)
	row: Gpu_Material_Row
	for &index in row.textures {index = GPU_NONE}
	row.textures[.Base_Color] = texture_entry(0)
	row.map_transforms[.Base_Color].linear = {1, 0, 0, 1}
	row.textures[.Normal] = texture_entry(1)
	row.map_transforms[.Normal].linear = {4, 0, 0, 4} // tiles four times
	append(&s.materials, row)
	place :: proc(s: ^Scene_State, x, scale: f32, flags: u32 = 0) {
		append(&s.instances, Gpu_Instance{
			world = {{scale, 0, 0, x}, {0, scale, 0, 0}, {0, 0, scale, 0}},
			meta = {0, GPU_NONE, 1, flags},
			bounds_min = {x - 1, 0, -1, 0}, bounds_max = {x + 1, 0, 1, 0},
		})
		append(&s.overlays, Instance_Overlays{})
	}
	place(&s, 9, 1)
	place(&s, 3, 1, INSTANCE_FLAG_HIDDEN) // nearer, hidden
	streams := make([]Texture_Stream, 3)
	defer delete(streams)
	for &stream in streams {stream = square_stream(1024, 0, 0)}
	viewers := []Texture_Viewer{{position = {0, 0, 0}, scale = math.log2(f32(1000))}}
	textures_estimate(streams, &s, nil, viewers)
	// 8 m away: log2(8 / 1000) + log2(1024).
	want := math.log2(f32(8)) - math.log2(f32(1000)) + 10
	testing.expectf(t, abs(streams[0].lod - want) < 1e-3, "lod %v, want %v", streams[0].lod, want)
	testing.expectf(t, abs(streams[1].lod - (want + 2)) < 1e-3, "a map that tiles four times asks for two levels more: %v", streams[1].lod)
	testing.expect(t, streams[0].shown && streams[1].shown && !streams[2].shown, "a texture no row names is not shown")
	// An instance twice as large shows the texture twice as large.
	place(&s, 9, 2)
	textures_estimate(streams, &s, nil, viewers)
	testing.expectf(t, abs(streams[0].lod - (want - 1)) < 1e-3, "lod %v", streams[0].lod)
	// The nearest of the viewers.
	far := []Texture_Viewer{{position = {-100, 0, 0}, scale = math.log2(f32(1000))}, {position = {0, 0, 0}, scale = math.log2(f32(1000))}}
	textures_estimate(streams, &s, nil, far)
	testing.expectf(t, abs(streams[0].lod - (want - 1)) < 1e-3, "lod %v", streams[0].lod)
	// A view of 90 degrees and 900 pixels spans 450 of them per metre one
	// metre ahead; at its corner, 1/cos of its angle more.
	camera := Camera{fov_y = 90, projection = .Perspective}
	viewer := texture_viewer(camera, 1600, 900)
	aspect := f32(1600) / 900
	corner := math.log2(450 * math.sqrt(2 + aspect * aspect))
	testing.expectf(t, abs(viewer.scale - corner) < 1e-3, "scale %v, want %v", viewer.scale, corner)
	ortho := texture_viewer({projection = .Orthographic, height = 10}, 1600, 900)
	testing.expect(t, ortho.ortho && abs(ortho.scale - math.log2(f32(90))) < 1e-3, "an orthographic view spans its pixels over its height anywhere")
}

// The uv a mesh spans per metre, by entry of its materials, up to a quarter
// of a level above it; a set whose uv do not change has none.
@(test)
the_uv_density_of_a_mesh_is_by_entry_of_its_materials :: proc(t: ^testing.T) {
	quad :: proc(vertices: ^[dynamic]asset.Vertex, indices: ^[dynamic]u32, x, side, uv: f32, slot: u32) {
		first := u32(len(vertices))
		for corner in ([4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}) {
			append(vertices, asset.Vertex{position = {x + corner.x * side, 0, corner.y * side}, uv = corner * uv, uv1 = corner * uv, material = slot})
		}
		append(indices, first, first + 1, first + 2, first, first + 2, first + 3)
	}
	vertices: [dynamic]asset.Vertex
	indices: [dynamic]u32
	defer {delete(vertices);delete(indices)}
	quad(&vertices, &indices, 0, 2, 1, 0)  // 2 m across one uv: half a uv per metre
	quad(&vertices, &indices, 5, 1, 8, 1)  // 8 uv per metre
	g: asset.Mesh_Geometry
	if !testing.expect(t, asset.mesh_build({vertices = vertices[:]}, indices[:], nil, &g, context.temp_allocator)) {return}
	density := mesh_uv_density(g)
	testing.expectf(t, density[0][0] >= -1 && density[0][0] <= -0.75, "%v", density[0][0])
	testing.expectf(t, density[1][0] >= 3 && density[1][0] <= 3.25, "%v", density[1][0])
	testing.expect_value(t, density[0][1], density[0][0]) // without a set of its own, uv1 is uv
}

@(test)
an_image_sky_is_read_from_the_entry_of_its_texture :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	textures_init(r)
	defer textures_destroy(r)
	append(&r.textures.textures, rhi.Texture(1))
	append(&r.textures.sizes, [2]int{1024, 512})
	r.textures.count = 1
	testing.expect_value(t, sky_map(r, 1, false), Vec4{f32(texture_entry(0)), 0, 10, 1})
}

// The textures that need more levels go first, the farthest from their target
// first, unless the pool is past its room; those being read are left out.
@(test)
texture_requests_put_what_is_most_blurred_first :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	resize(&r.textures.residency.streams, 3)
	defer delete(r.textures.residency.streams)
	streams := r.textures.residency.streams
	streams[0] = square_stream(1024, 0, 0);streams[0].target = 3
	streams[1] = square_stream(1024, 5, 0);streams[1].target = 2
	streams[2] = square_stream(1024, 4, 0);streams[2].target = 3
	r.textures.count, r.textures.residency.pending = 3, 3
	out: [4]Texture_Request
	count := texture_requests(r, out[:], nil)
	testing.expect(t, count == 3 && out[0].handle == 2 && out[1].handle == 3 && out[2].handle == 1, "grows first, the largest first")
	testing.expect(t, out[0].level == 2 && out[0].stamp == streams[1].stamp)
	count = texture_requests(r, out[:1], {2})
	testing.expect(t, count == 1 && out[0].handle == 3, "what is being read is left out")
	r.settings.texture_pool_megabytes, r.textures.bytes = 1, 2 << 20
	count = texture_requests(r, out[:], nil)
	testing.expect(t, count == 3 && out[0].handle == 1, "past the pool, what frees memory first")
}

// A request is answered only while the texture is the one it asked about.
@(test)
a_stream_forgets_its_texture_with_a_new_stamp :: proc(t: ^testing.T) {
	state: Texture_State
	resize(&state.residency.streams, 2)
	defer delete(state.residency.streams)
	data := Texture_Data{format = .RGBA8_Unorm, width = 256, height = 256, level = 2, source = {1024, 1024}}
	for _ in 0 ..< 9 {append(&data.levels, nil)}
	defer delete(data.levels)
	texture_stream_set(&state.residency.streams[0], data, 1)
	stream := state.residency.streams[0]
	testing.expect(t, stream.levels == 11 && stream.top == 3 && stream.target == 3, "levels of the source, and the first it holds")
	row, rows := rhi.format_rows(.RGBA8_Unorm, 1024, 1024)
	testing.expect_value(t, stream.chain[0] - stream.chain[1], row * rows)
	stamp := stream.stamp
	texture_stream_forget(&state, 0)
	testing.expect(t, state.residency.streams[0].levels == 0 && state.residency.streams[0].stamp == stamp + 1)
	testing.expect(t, state.residency.stale)
}

// The views of the window see textures from the camera of the detail while
// it holds; one drawn into a texture keeps its own.
@(test)
the_detail_camera_sees_the_textures_of_the_views_of_the_window :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	game := Camera{position = {4, 2, 9}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1}
	editor := Camera{position = {4, 2, 1}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1}
	views := [2]Frame_View{{camera = editor, rect = {0, 0, 800, 600}}, {camera = editor, rect = {0, 0, 256, 256}, texture = 1}}
	for on in ([2]bool{false, true}) {
		textures_views_record(r, {camera = editor, detail = {camera = game, on = on}, views = views[:]})
		seen := r.textures.residency.views[:r.textures.residency.view_count]
		testing.expect_value(t, len(seen), 2)
		testing.expectf(t, seen[0].position == (game.position if on else editor.position), "the window sees from the game camera: %v", on)
		testing.expect(t, seen[1].position == editor.position, "a view into a texture sees from its own")
	}
	// An offscreen frame leaves what the window sees unless it asks for its textures to stream.
	textures_views_record(r, {camera = editor, views = views[:1]})
	textures_views_record(r, {camera = game, offscreen = true, views = {{camera = game, rect = {0, 0, 64, 64}, texture = 1}}})
	testing.expect(t, r.textures.residency.views[0].position == editor.position, "a preview does not move what textures are seen from")
	textures_views_record(r, {camera = game, offscreen = true, streamed = true, views = {{camera = game, rect = {0, 0, 64, 64}, texture = 1}}})
	testing.expect(t, r.textures.residency.view_count == 1 && r.textures.residency.views[0].position == game.position, "a capture that waits for its textures is seen from its camera")
}

// An instance that moves asks its textures again alone, without the scene
// being estimated again: nearer, they take the finer level at once; farther,
// the estimate is marked only when a texture was at the level that instance
// asked and it went TEXTURE_FAR_STEP past it, or shows it no more. A level is
// never coarser than the estimate of the scene would give.
@(test)
a_touched_instance_asks_its_textures_again_without_estimating_the_scene :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	r.allocator = context.allocator
	// No row has a program: the catalog is not read.
	r.programs.loaded = true
	scene_init(r)
	defer scene_destroy(r)
	textures_init(r)
	defer textures_destroy(r)
	vertices, indices := edit_grid(1, 2)
	defer {delete(vertices);delete(indices)}
	mesh, _ := edit_add(r, vertices[:], indices[:], {0, 0})
	materials_set(r, {DEFAULT_MATERIAL, DEFAULT_MATERIAL})
	s := &r.scene
	s.meshes[mesh].uv_density = {}
	for row in 1 ..= 2 {
		s.materials[row].textures[.Base_Color] = texture_entry(row - 1)
		s.materials[row].map_transforms[.Base_Color].linear = {1, 0, 0, 1}
	}
	at :: proc(x: f32) -> Mat4 {m := Mat4(1);m[0, 3] = x;return m}
	descs := [3]Instance_Desc{
		{object_id = 1, mesh = mesh, material = 1, transform = at(10), tint = {1, 1, 1}},
		{object_id = 2, mesh = mesh, material = 1, transform = at(20), tint = {1, 1, 1}},
		{object_id = 3, mesh = mesh, material = 2, transform = at(40), tint = {1, 1, 1}},
	}
	testing.expect(t, scene_given(r, descs[:], nil, {}, {}))
	state := &r.textures.residency
	resize(&state.streams, 2)
	r.textures.count = 2
	for &stream in state.streams {stream = square_stream(1024, 0, 0)}
	state.seen_views[0], state.seen_count = {position = {0, 0, 0}, scale = math.log2(f32(1000))}, 1
	// The level a texture of 1024 is asked from `distance` metres to the box, two across.
	lod :: proc(distance: f32) -> f32 {return math.log2(distance / 1000) + 10}
	estimate :: proc(r: ^Renderer) {
		state := &r.textures.residency
		resize(&state.seen_near, len(r.scene.instances))
		textures_estimate(state.streams[:], &r.scene, nil, state.seen_views[:state.seen_count], state.seen_near[:])
		// As after the frame that sent the scene.
		state.stale, state.retarget, r.scene.instances_dirty, r.scene.materials_dirty = false, false, false, false
	}
	// What the frame does with the touched instances: it looks at their textures, sends them and settles them.
	frame :: proc(r: ^Renderer) {
		textures_touched(r)
		touched_settle(&r.scene)
		touched_settle(&r.scene)
	}
	// The estimate of the scene as it is, which the levels are never coarser than.
	never_coarser :: proc(t: ^testing.T, r: ^Renderer, loc := #caller_location) {
		state := &r.textures.residency
		whole: [2]Texture_Stream
		copy(whole[:], state.streams[:])
		textures_estimate(whole[:], &r.scene, nil, state.seen_views[:state.seen_count])
		for stream, i in state.streams {
			testing.expectf(t, stream.shown == whole[i].shown && stream.lod <= whole[i].lod && stream.lod >= whole[i].lod - TEXTURE_FAR_STEP, "texture %d: lod %v, the scene asks %v", i, stream.lod, whole[i].lod, loc = loc)
		}
	}
	estimate(r)
	streams := state.streams[:]
	testing.expectf(t, abs(streams[0].lod - lod(9)) < 1e-3 && abs(streams[1].lod - lod(39)) < 1e-3, "%v %v", streams[0].lod, streams[1].lod)

	// One that is not the nearest to show its texture comes nearer, and farther: nothing to do.
	testing.expect(t, scene_move(r, {1}, {at(15)}))
	frame(r)
	testing.expect(t, !state.stale && !state.retarget && abs(streams[0].lod - lod(9)) < 1e-3)
	testing.expect(t, scene_move(r, {1}, {at(30)}))
	frame(r)
	testing.expect(t, !state.stale && !state.retarget, "what another shows nearer keeps its level")
	never_coarser(t, r)
	// It comes the nearest: its texture takes the finer level at once.
	testing.expect(t, scene_move(r, {1}, {at(5)}))
	frame(r)
	testing.expect(t, !state.stale && state.retarget, "a finer level is asked without an estimate")
	testing.expectf(t, abs(streams[0].lod - lod(4)) < 1e-3, "%v", streams[0].lod)
	never_coarser(t, r)
	state.retarget = false
	// A tint, and a step away shorter than TEXTURE_FAR_STEP, ask for nothing.
	testing.expect(t, scene_tint(r, {0, 1}, {{1, 0, 0}, {0, 1, 0}}, {{}, {}}))
	testing.expect(t, scene_move(r, {1}, {at(5.5)}))
	frame(r)
	testing.expect(t, !state.stale && !state.retarget)
	never_coarser(t, r)
	// The one that gave the level goes past the step: the scene is estimated again.
	testing.expect(t, scene_move(r, {1}, {at(8)}))
	frame(r)
	testing.expect(t, state.stale, "the nearest to show a texture went away")
	estimate(r)
	testing.expectf(t, abs(streams[0].lod - lod(7)) < 1e-3, "%v", streams[0].lod)

	// The only one to show a texture is hidden: its texture is shown no more.
	hidden := descs[2]
	hidden.hidden = true
	testing.expect(t, scene_update(r, 2, {hidden}))
	frame(r)
	testing.expect(t, state.stale, "what showed a texture alone shows it no more")
	estimate(r)
	testing.expect(t, !streams[1].shown)
	// Shown again, it gives its texture its level alone.
	testing.expect(t, scene_update(r, 2, {descs[2]}))
	frame(r)
	testing.expect(t, !state.stale && state.retarget && streams[1].shown)
	never_coarser(t, r)
	state.retarget = false
	// One that shows other materials shows other textures.
	other := descs[0]
	other.material = 2
	testing.expect(t, scene_update(r, 0, {other}))
	frame(r)
	testing.expect(t, state.stale, "another material")
	estimate(r)
	// The whole table, as a set gives it, is estimated.
	testing.expect(t, scene_given(r, descs[:], nil, {}, {}))
	frame(r)
	testing.expect(t, state.stale)
}
