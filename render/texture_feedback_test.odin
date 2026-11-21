package mirai_render

import "core:math"
import "core:testing"
import "mirai:rhi"

// No temporal jitter or GI, and the scenes have no lights: two frames of the
// same view are the same image.
@(private = "file")
feedback_settings :: proc() -> Settings {
	s := DEFAULT_SETTINGS
	s.reflections = .Detailed
	s.gi_enabled = false
	s.taa = false
	return s
}

// A streamed texture of noise, whose every level differs from the next: its
// levels from `first`, and all of them in `whole` to give it others.
@(private = "file")
noise_texture :: proc(t: ^testing.T, r: ^Renderer, width, height: int, first := 0, loc := #caller_location) -> (handle: Texture_Handle, whole: Texture_Data) {
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	for &p, i in pixels {p = u8((u32(i) * 2654435761) >> 24) | (0xff if i % 4 == 3 else 0)}
	built, ok := texture_build({pixels = pixels, width = width, height = height, srgb = true, name = "noise"}, 1 << 16)
	if !testing.expect(t, ok, loc = loc) {return}
	whole = built
	whole.source = {width, height}
	given := texture_levels_from(whole, first)
	added: bool
	handle, added = texture_add_data(r, given, "noise")
	testing.expect(t, added, r.error, loc = loc)
	return
}

// The levels of a texture of every level from `first`, borrowed; the list
// of them, kept until the test ends (`kept`) or freed by the caller.
@(private = "file")
texture_levels_from :: proc(whole: Texture_Data, first: int, kept: ^[dynamic][dynamic][]u8 = nil, count := -1) -> (data: Texture_Data) {
	data = whole
	data.width, data.height, data.level = max(whole.width >> uint(first), 1), max(whole.height >> uint(first), 1), first
	last := len(whole.levels) if count < 0 else first + count
	data.levels = make([dynamic][]u8, 0, last - first, context.temp_allocator if kept == nil else context.allocator)
	append(&data.levels, ..whole.levels[first:last])
	if kept != nil {append(kept, data.levels)}
	return
}

// What the streamer of the application does between frames, at once: frames
// of a view until the textures hold what the feedback of that view asks for.
// Each read gives only the levels a texture lacks; the renderer copies the
// others, and gives levels up alone.
@(private = "file")
feedback_settle :: proc(t: ^testing.T, r: ^Renderer, camera: Camera, textures: []Texture_Data, loc := #caller_location) {
	kept: [dynamic][dynamic][]u8
	defer {
		for levels in kept {delete(levels)}
		delete(kept)
	}
	for _ in 0 ..< 48 {
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error, loc = loc)
		busy := false
		for upload in r.textures.residency.uploads {busy ||= upload.active}
		if textures_update(r) == 0 && !busy {return}
		requests: [8]Texture_Request
		for request in requests[:texture_requests(r, requests[:], nil)] {
			lacking := int(r.textures.residency.streams[request.handle - 1].top) - request.level
			result := texture_levels_queue(r, request, texture_levels_from(textures[request.handle - 1], request.level, &kept, lacking))
			testing.expectf(t, result == .Set || result == .Busy, "%v", result, loc = loc)
		}
	}
	testing.expect(t, false, "the textures did not settle", loc = loc)
}

@(private = "file")
feedback_quad :: proc(r: ^Renderer) -> Mesh_Handle {
	corners := [4]Vec3{{-0.5, 0, -0.5}, {0.5, 0, -0.5}, {0.5, 0, 0.5}, {-0.5, 0, 0.5}}
	vertices: [4]Mesh_Vertex
	for c, i in corners {vertices[i] = {position = c, normal = {0, 1, 0}, tangent = {1, 0, 0, 1}, uv = {c.x + 0.5, c.z + 0.5}, color = {1, 1, 1}}}
	indices := [6]u32{0, 2, 1, 0, 3, 2}
	mesh, _ := mesh_add(r, vertices[:], indices[:])
	return mesh
}

@(private = "file")
scaled :: proc(scale: f32) -> (m: Mat4) {
	m = Mat4(1)
	m[0, 0], m[1, 1], m[2, 2] = scale, scale, scale
	return
}

@(private = "file")
feedback_image :: proc(t: ^testing.T, r: ^Renderer, camera: Camera) -> []u8 {
	for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	rhi.device_wait_idle(r.device)
	pixels, _, _, ok := renderer_capture(r, context.temp_allocator)
	testing.expect(t, ok, r.error)
	return pixels
}

// The levels the feedback keeps are never coarser than the sampler reads:
// over a set of views (near, far, grazing) the image is the one every level
// gives, byte for byte, and a far view keeps fewer levels; the same whether a
// map of the material, a program by a plain uv (testdata/sampled.slang) or
// one by a uv with its derivatives (testdata/tiled.slang) samples it.
@(test)
texture_feedback_keeps_every_level_the_image_reads :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 160, 120, feedback_settings(), programs = true) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	SIDE :: 1024
	quad := feedback_quad(r)
	floor := scaled(4)
	sampled, tiled := program_find(r, "Sampled", .Surface), program_find(r, "Tiled", .Surface)
	if !testing.expect(t, sampled != nil && tiled != nil, "the tests have the Sampled and Tiled programs") {return}
	// A texture each: the feedback of the frames before the next one does not reach it.
	wholes: [3]Texture_Data
	handles: [3]Texture_Handle
	defer for &whole in wholes {texture_data_destroy(&whole)}
	for program, at in ([]^Program{nil, sampled, tiled}) {
		sampler := "map" if program == nil else program.name
		handles[at], wholes[at] = noise_texture(t, r, SIDE, SIDE)
		texture, whole := handles[at], wholes[at]
		material := DEFAULT_MATERIAL
		if program != nil {
			material.program_id = program.id
			material.custom_params = program_defaults(program)
			testing.expect(t, program_parameter_set_texture(r, &material.custom_params, program_parameter(program, "image"), texture))
		} else {
			material.textures[.Base_Color] = texture
		}
		materials_set(r, {material})
		testing.expect(t, scene_update(r, 0, {{object_id = 1, mesh = quad, transform = floor, material = 1, tint = {1, 1, 1}}}, true))
		// A program draws as its row until its pipelines are made.
		testing.expect(t, renderer_frame(r, {}), r.error)
		renderer_pipelines_wait(r)
		// Far first: a view after another starts from the levels the one before asked for.
		cases := []struct {name: string, camera: Camera}{
			{"far", {position = {0, 30, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}},
			{"near", {position = {0, 1.5, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}},
			{"grazing", {position = {0, 0.3, 3}, forward = {0, -0.15, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}},
		}
		stream := &r.textures.residency.streams[texture - 1]
		kept: [dynamic][dynamic][]u8
		defer {
			for levels in kept {delete(levels)}
			delete(kept)
		}
		textures := make([]Texture_Data, int(texture), context.temp_allocator)
		for handle, i in handles[:at + 1] {textures[handle - 1] = wholes[i]}
		for c in cases {
			every := Texture_Request{handle = texture, level = 0,
				held = int(stream.top), stamp = stream.stamp}
			levels := texture_levels_from(whole, 0, &kept, int(stream.top))
			if stream.top > 0 {
				testing.expect_value(t, texture_levels_queue(r, every, levels), Texture_Levels_Result.Set)
				for texture_upload_pending(r, every) {testing.expect(t, renderer_frame(r, {camera = c.camera}), r.error)}
			}
			testing.expect_value(t, stream.top, 0)
			before := feedback_image(t, r, c.camera)
			feedback_settle(t, r, c.camera, textures)
			after := feedback_image(t, r, c.camera)
			testing.expectf(t, stream.shown, "%s, %s: the frames sample the texture", sampler, c.name)
			testing.expectf(t, c.name != "far" || stream.top > 0, "%s, %s: it keeps every level", sampler, c.name)
			differ := 0
			for b, i in before {if b != after[i] {differ += 1}}
			testing.expectf(t, differ == 0 && len(before) == len(after), "%s, %s: %d bytes differ from the image of every level (from level %d)", sampler, c.name, differ, stream.top)
		}
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A texture only a traced reflection shows asks for its levels by the cone
// of the ray at its hit, and gets them; one nothing shows asks for nothing
// and keeps its levels, as does one of a surface that a surface of a program
// in front of it hides whole: a material runs for what the camera sees.
@(test)
texture_feedback_takes_what_reflections_see_and_nothing_unseen :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 512, 512, feedback_settings(), programs = true) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	SIDE :: 1024
	tail := 0
	for SIDE >> uint(tail) > TEXTURE_TAIL {tail += 1}
	reflected, reflected_whole := noise_texture(t, r, SIDE, SIDE, tail)
	defer texture_data_destroy(&reflected_whole)
	unseen, unseen_whole := noise_texture(t, r, SIDE, SIDE, tail)
	defer texture_data_destroy(&unseen_whole)
	covered, covered_whole := noise_texture(t, r, SIDE, SIDE, tail)
	defer texture_data_destroy(&covered_whole)
	sampled := program_find(r, "Sampled", .Surface)
	if !testing.expect(t, sampled != nil, "the tests have the Sampled program") {return}
	mirror, shown, hidden, under, cover := DEFAULT_MATERIAL, DEFAULT_MATERIAL, DEFAULT_MATERIAL, DEFAULT_MATERIAL, DEFAULT_MATERIAL
	mirror.base_color, mirror.metallic, mirror.roughness = {0.9, 0.9, 0.9}, 1, 0.02
	shown.textures[.Base_Color], shown.emission = reflected, {2, 2, 2}
	hidden.textures[.Base_Color] = unseen
	under.textures[.Base_Color] = covered
	cover.program_id, cover.custom_params = sampled.id, program_defaults(sampled)
	materials_set(r, {mirror, shown, hidden, under, cover})
	quad := feedback_quad(r)
	// A narrow camera looks down at a mirror floor; the quad it mirrors faces
	// the floor out of its view, and the other is behind it.
	facing := Mat4(1)
	facing[1, 1], facing[1, 3], facing[2, 3] = -1, 0.5, -0.5
	behind := Mat4(1)
	behind[1, 3], behind[2, 3] = 2, 6
	// Near the eye, in the middle of the view, a small quad of a program and
	// a smaller one just under it, which it hides whole.
	covering, under_it := scaled(0.06), scaled(0.04)
	covering[1, 3], covering[2, 3] = 0.79, 0.79
	under_it[1, 3], under_it[2, 3] = 0.785, 0.79
	testing.expect(t, scene_update(r, 0, {
		{object_id = 1, mesh = quad, transform = scaled(20), material = 1, tint = {1, 1, 1}},
		{object_id = 2, mesh = quad, transform = facing, material = 2, tint = {1, 1, 1}},
		{object_id = 3, mesh = quad, transform = behind, material = 3, tint = {1, 1, 1}},
		{object_id = 4, mesh = quad, transform = under_it, material = 4, tint = {1, 1, 1}},
		{object_id = 5, mesh = quad, transform = covering, material = 5, tint = {1, 1, 1}},
	}, true))
	scene_set_environment(r, {}, {sky = {0, 0, 0.2}})
	camera := Camera{position = {0, 1, 1}, forward = {0, -1, -1}, up = {0, 1, 0}, fov_y = 30, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	feedback_settle(t, r, camera, {reflected_whole, unseen_whole, covered_whole})
	streams := r.textures.residency.streams[:]
	testing.expectf(t, streams[reflected - 1].shown && int(streams[reflected - 1].top) < tail, "the reflected texture is sampled and gets levels past its tail: from %d (shown %v, asked %v)", streams[reflected - 1].top, streams[reflected - 1].shown, streams[reflected - 1].lod)
	testing.expectf(t, !streams[unseen - 1].shown && int(streams[unseen - 1].top) == tail, "the unseen texture asks for nothing: from %d", streams[unseen - 1].top)
	testing.expectf(t, !streams[covered - 1].shown && int(streams[covered - 1].top) == tail, "the texture of a surface hidden whole asks for nothing: from %d", streams[covered - 1].top)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The resolve of the rows and that of each Surface program record what they
// sample in one window frame of TEXTURE_FEEDBACK_TURNS, and in every frame
// that waits for its textures: after a jump a texture asks for its finer
// level within a turn, and a still view settles at the levels frames that
// record every program ask for.
@(test)
texture_feedback_takes_turns :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 160, 120, feedback_settings(), programs = true) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	SIDE :: 1024
	quad := feedback_quad(r)
	sampled := program_find(r, "Sampled", .Surface)
	if !testing.expect(t, sampled != nil, "the tests have the Sampled program") {return}
	wholes: [2]Texture_Data
	handles: [2]Texture_Handle
	defer for &whole in wholes {texture_data_destroy(&whole)}
	for &handle, i in handles {handle, wholes[i] = noise_texture(t, r, SIDE, SIDE)}
	row, programmed := DEFAULT_MATERIAL, DEFAULT_MATERIAL
	row.textures[.Base_Color] = handles[0]
	programmed.program_id, programmed.custom_params = sampled.id, program_defaults(sampled)
	testing.expect(t, program_parameter_set_texture(r, &programmed.custom_params, program_parameter(sampled, "image"), handles[1]))
	materials_set(r, {row, programmed})
	left, right := scaled(2), scaled(2)
	left[0, 3], right[0, 3] = -1.1, 1.1
	testing.expect(t, scene_update(r, 0, {
		{object_id = 1, mesh = quad, transform = left, material = 1, tint = {1, 1, 1}},
		{object_id = 2, mesh = quad, transform = right, material = 2, tint = {1, 1, 1}},
	}, true))
	far := Camera{position = {0, 30, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	near := far
	near.position.y = 1.5
	feedback_settle(t, r, far, wholes[:])
	renderer_pipelines_wait(r)
	res := &r.textures.residency
	streams := res.streams[:]

	// Which frames record each texture, once the feedback of the first comes back.
	for whole in ([]bool{false, true}) {
		recorded: [2]int
		for frame in 0 ..< rhi.MAX_FRAMES_IN_FLIGHT + 2 * TEXTURE_FEEDBACK_TURNS {
			res.frames = 0
			for handle in handles {streams[handle - 1].window = max(f32)}
			testing.expect(t, renderer_frame(r, {camera = far, offscreen = whole, streamed = whole}), r.error)
			if frame < rhi.MAX_FRAMES_IN_FLIGHT {continue}
			for handle, i in handles {if streams[handle - 1].window < max(f32) {recorded[i] += 1}}
		}
		expected := 2 * TEXTURE_FEEDBACK_TURNS if whole else 2
		testing.expectf(t, recorded == [2]int{expected, expected}, "frames that wait for their textures %v: the row and the program record in %v of %d frames, not %d", whole, recorded, 2 * TEXTURE_FEEDBACK_TURNS, expected)
	}

	// A jump asks for the finer levels within a turn, and the frames in flight.
	before := [2]f32{streams[handles[0] - 1].lod, streams[handles[1] - 1].lod}
	asked := -1
	for frame in 0 ..< 4 * TEXTURE_FEEDBACK_TURNS {
		testing.expect(t, renderer_frame(r, {camera = near}), r.error)
		if streams[handles[0] - 1].lod < before[0] && streams[handles[1] - 1].lod < before[1] {
			asked = frame + 1
			break
		}
	}
	testing.expectf(t, asked > 0 && asked <= TEXTURE_FEEDBACK_TURNS + rhi.MAX_FRAMES_IN_FLIGHT, "after a jump both textures ask for finer levels within %d frames, not %d", TEXTURE_FEEDBACK_TURNS + rhi.MAX_FRAMES_IN_FLIGHT, asked)

	// Still, a window of each settles at the same levels.
	settled: [2][2]f32
	for whole, at in ([]bool{false, true}) {
		for _ in 0 ..< 2 * TEXTURE_FEEDBACK_FRAMES {testing.expect(t, renderer_frame(r, {camera = near, offscreen = whole, streamed = whole}), r.error)}
		for handle, i in handles {
			testing.expectf(t, streams[handle - 1].shown, "texture %d is shown", i)
			settled[at][i] = streams[handle - 1].lod
		}
	}
	testing.expectf(t, settled[0] == settled[1], "frames in turns settle at the levels %v, frames that record every program at %v", settled[0], settled[1])
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// Textures of hostile sizes (a texel, a line, odd sides) on quads of hostile
// scales stream without a validation error, each within its levels.
@(test)
texture_feedback_takes_hostile_sizes :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, feedback_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	sizes := [?][2]int{{1, 1}, {4096, 2}, {2, 4096}, {3, 5}, {257, 129}}
	scales := [?]f32{1, 1e-6, 1e6, 2, 0.5}
	wholes: [len(sizes)]Texture_Data
	defer for &whole in wholes {texture_data_destroy(&whole)}
	materials: [len(sizes)]Material_Desc
	instances: [len(sizes)]Instance_Desc
	quad := feedback_quad(r)
	for size, i in sizes {
		handle: Texture_Handle
		handle, wholes[i] = noise_texture(t, r, size.x, size.y)
		materials[i] = DEFAULT_MATERIAL
		materials[i].textures[.Base_Color] = handle
		at := scaled(scales[i])
		at[0, 3] = f32(i) - 2
		instances[i] = {object_id = u64(i + 1), mesh = quad, transform = at, material = Material_Handle(i + 1), tint = {1, 1, 1}}
	}
	materials_set(r, materials[:])
	testing.expect(t, scene_update(r, 0, instances[:], true))
	camera := Camera{position = {0, 3, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 90, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	feedback_settle(t, r, camera, wholes[:])
	for &stream in r.textures.residency.streams[:len(sizes)] {
		first, last := texture_level_range(&stream, texture_limits(r).max_size)
		testing.expectf(t, !math.is_nan(stream.lod) && int(stream.top) >= first && int(stream.top) <= last, "%v: from level %d of %d to %d", stream.size, stream.top, first, last)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}
