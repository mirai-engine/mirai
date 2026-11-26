package foliage

import "core:fmt"
import "core:path/filepath"
import "core:testing"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import mm "mirai:std/math"

// The micro foliage on the GPU, with the shaders of the engine and of the
// plugin: a tile of small cubes over a dark floor, seen from above, drawn
// through the batch of its look by the visibility buffer of the scene.

@(private = "file")
MICRO_ROOT :: #directory + "/../../.."
@(private = "file")
MICRO_WIDTH :: 160
@(private = "file")
MICRO_HEIGHT :: 120
@(private = "file")
MICRO_READ :: "test micro batch"
@(private = "file")
MICRO_READ_INSTANCES :: 256
@(private = "file")
MICRO_READ_WORDS :: 1 + MICRO_READ_INSTANCES * 6

@(private = "file")
Micro_Gpu :: struct {
	device:   ^rhi.Device,
	renderer: gpu.Renderer,
	cube:     gpu.Mesh_Handle,
	fixture:  Micro_Fixture,
}

@(private = "file")
micro_gpu_init :: proc(t: ^testing.T, g: ^Micro_Gpu, scale: f32 = 0.15) -> bool {
	root, _ := filepath.clean(MICRO_ROOT, context.temp_allocator)
	loaded, problem := gpu.shader_assets_load(fmt.tprintf("%s/.mirai/test-shaders/foliage", root))
	if !testing.expect(t, problem == "", problem) {return false}
	device := shared_device.take_or_skip(t)
	if device == nil {
		gpu.shader_assets_destroy(&loaded)
		return false
	}
	g.device = device
	settings := gpu.DEFAULT_SETTINGS
	settings.taa = false
	if !testing.expect(t, gpu.renderer_init(&g.renderer, {device = device, width = MICRO_WIDTH, height = MICRO_HEIGHT, settings = settings, shaders = &loaded}), g.renderer.error) {return false}
	f := &g.fixture
	folder := base.test_folder(t, "foliage-micro-gpu")
	if folder == "" || !testing.expect(t, host.assets_init(&f.assets, {root = folder, renderer = &g.renderer})) {return false}
	cube := host.assets_shape(&f.assets, .Cube)
	if !testing.expect(t, cube != nil) {return false}
	g.cube = cube.handle
	if !micro_fixture_init(t, f, g.cube, &g.renderer) {return false}
	f.micro.world = {index = 1}
	gpu.scene_world(&g.renderer, render.world_key(f.micro.world))
	look := &f.micro.looks[0]
	look.row.scale = {scale, scale, 1, 1}
	ground, _ := pcg_ground_heights(f)
	look.low, look.high = micro_tile_box(look, {0, 0}, ground)
	f.micro.tiles[0].low, f.micro.tiles[0].high = look.low, look.high
	problems: core.Problems
	micro_batches(&f.micro, &g.renderer, &problems)
	return testing.expect(t, look.batch != 0 && len(f.micro.batches) == 1, "the look has its batch")
}

@(private = "file")
pcg_ground_heights :: proc(f: ^Micro_Fixture) -> ([]f32, bool) {
	return f.grounds.owners[0].pools[0].heights[:], true
}

@(private = "file")
micro_gpu_destroy :: proc(g: ^Micro_Gpu) {
	if g.device == nil {return}
	rhi.device_wait_idle(g.device)
	micro_fixture_destroy(&g.fixture)
	host.assets_destroy(&g.fixture.assets)
	gpu.renderer_destroy(&g.renderer)
}

// What the view wrote into the batch of the look: its count and the words
// of its first instances (testdata/micro_batch_read.comp).
@(private = "file")
micro_batch_read :: proc(pass: ^render.Pass, user: rawptr) {
	m := cast(^Foliage_Micro)user
	pipeline := render.pass_stage_pipeline(pass, {stage = .Instances, shader = "micro_batch_read", name = "test micro batch read"})
	target, ok := render.pass_batch_target(pass, 3, m.looks[0].batch)
	desc := render.Buffer_Desc{name = MICRO_READ, size = MICRO_READ_WORDS * 4}
	if !ok || pipeline == 0 {return}
	if made, _ := render.pass_buffer(pass, 0, desc); !made {return}
	read := [4]u32{target.first, target.count, MICRO_READ_WORDS, 0}
	render.pass_pipeline(pass, pipeline)
	if render.pass_params(pass, &read, size_of(read)) {render.pass_dispatch(pass, (MICRO_READ_WORDS + 63) / 64)}
	render.pass_readback(pass, desc, 0, {name = MICRO_READ, size = desc.size})
}

// Frames of the tile seen from camera with what the step of a frame does for
// it, an occluder over it when `covered`, and the pixels of the last.
@(private = "file")
micro_frames :: proc(t: ^testing.T, g: ^Micro_Gpu, frames: int, camera: gpu.Camera, covered := false, read := false) -> (pixels: []u8, ok: bool) {
	f := &g.fixture
	problems: core.Problems
	for _ in 0 ..< frames {
		micro_jobs_of(f, &problems)
		if len(f.micro.jobs) > 0 {render.frame_pass(&g.renderer, .Simulate, foliage_micro_generate, &f.micro)}
		render.frame_pass(&g.renderer, .Instances, foliage_micro_fill, &f.micro)
		if read {render.frame_pass(&g.renderer, .Instances, micro_batch_read, &f.micro)}
		instances := [2]gpu.Instance_Desc {
			{object_id = 1, mesh = g.cube, transform = mm.transform_matrix({{4, -0.5, 4}, mm.QUAT_IDENTITY, {60, 1, 60}}), tint = {0.05, 0.05, 0.05}},
			{object_id = 2, mesh = g.cube, transform = mm.transform_matrix({{4, 3, 4}, mm.QUAT_IDENTITY, {12, 0.5, 12}}), tint = {0.05, 0.05, 0.05}},
		}
		gpu.scene_set_environment(&g.renderer, {direction = {-0.3, -1, 0.2}, color = {1, 1, 1}, illuminance = 3, enabled = true}, {sky = {0.4, 0.5, 0.6}})
		testing.expect(t, gpu.scene_update(&g.renderer, 0, instances[:2 if covered else 1], true), g.renderer.error)
		testing.expect(t, gpu.renderer_frame(&g.renderer, {camera = camera}), g.renderer.error)
	}
	rhi.device_wait_idle(g.device)
	pixels, _, _, ok = gpu.renderer_capture(&g.renderer)
	testing.expect(t, ok, g.renderer.error)
	return
}

@(private = "file")
micro_above :: proc(height: f32) -> gpu.Camera {
	return {position = {4, height, 4.01}, forward = {0, -1, -0.001}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 200, exposure = gpu.UNIT_EXPOSURE}
}

// The micro instances of a tile are generated once in the Simulate stage,
// however many frames draw them, and each view writes those it keeps into
// the batch of their look, which the cull of the scene draws: bright cubes
// over the dark floor. Under an occluder the occlusion of the scene hides
// every one of them; no frame reports a validation error.
@(test)
a_micro_tile_is_generated_once_and_each_view_draws_what_it_sees :: proc(t: ^testing.T) {
	g := new(Micro_Gpu)
	defer free(g)
	if !micro_gpu_init(t, g) {return}
	defer micro_gpu_destroy(g)
	m := &g.fixture.micro
	pixels, ok := micro_frames(t, g, 6, micro_above(7))
	if !ok {return}
	defer delete(pixels)
	testing.expect_value(t, m.stats.generated, u64(1))
	testing.expect(t, m.tiles[0].key == m.tiles[0].want && m.capacity >= m.end && m.end == 32 * 32)
	bright, dark := 0, 0
	for i := 0; i + 3 < len(pixels); i += 4 {
		if int(pixels[i]) + int(pixels[i + 1]) + int(pixels[i + 2]) > 150 {bright += 1} else {dark += 1}
	}
	testing.expectf(t, bright > len(pixels) / 4 / 20 && dark > len(pixels) / 4 / 4, "cubes over the floor: %d bright pixels, %d dark", bright, dark)
	counted, has := render.counters(&g.renderer, MICRO_COUNTERS)
	testing.expectf(t, has && counted[0] > 100 && counted[0] <= 32 * 32 && counted[1] == 0, "the cubes the view writes: %v", counted)
	testing.expectf(t, g.renderer.stats.visible_instances > 100, "the scene draws them: %d visible", g.renderer.stats.visible_instances)
	covered: []u8
	if covered, ok = micro_frames(t, g, 4, micro_above(7), true); !ok {return}
	delete(covered)
	testing.expectf(t, g.renderer.stats.visible_instances <= 2, "the occluder hides them all: %d visible besides the floor and it", g.renderer.stats.visible_instances)
	testing.expect_value(t, m.stats.generated, u64(1))
	testing.expectf(t, rhi.device_validation_errors(g.device) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(g.device), rhi.device_validation_message(g.device))
}

// Seen from farther and farther above, a tile of cubes a metre wide keeps
// fewer of them (the share written never grows), all near and a floor of
// them far; what it keeps far widens along the ground by MICRO_THIN_WIDEN and
// keeps its height, those at the edge of the thinning growing from the
// ground, and nothing goes past the room of the batch.
@(test)
micro_foliage_thins_by_distance_without_popping_and_widens_what_it_keeps :: proc(t: ^testing.T) {
	g := new(Micro_Gpu)
	defer free(g)
	if !micro_gpu_init(t, g, scale = 1) {return}
	defer micro_gpu_destroy(g)
	m := &g.fixture.micro
	onset := micro_thin_onset(m.looks[0].row, 60, MICRO_HEIGHT)
	Case :: struct {height: f32, kept: [2]f32, widen: [2]f32}
	// The onset of a metre cube in 120 lines is under 6 m: the floor of the chance from under 13 m.
	cases := [?]Case{{3, {0.9, 1}, {1, 1.05}}, {8, {0.4, 0.95}, {1, 1.6}}, {16, {0.2, 0.36}, {1.59, 1.61}}, {40, {0.2, 0.36}, {1.59, 1.61}}}
	testing.expectf(t, onset > 4 && onset < 7, "onset %v m", onset)
	share := f32(2)
	growing := false
	for c in cases {
		pixels, ok := micro_frames(t, g, 6, micro_above(c.height), read = true)
		if !ok {return}
		delete(pixels)
		counted, has := render.counters(&g.renderer, MICRO_COUNTERS)
		if !testing.expect(t, has && counted[0] + counted[2] > 0, "counted") {continue}
		kept := f32(counted[0]) / f32(counted[0] + counted[2])
		testing.expectf(t, kept >= c.kept[0] && kept <= c.kept[1] && kept <= share + 1e-3, "%v m: %.3f of %d kept (%v), after %.3f", c.height, kept, counted[0] + counted[2], counted, share)
		testing.expectf(t, counted[1] == 0, "%v m: none past the room", c.height)
		share = kept
		growing ||= counted[3] > 0
		data, _, read := render.readback(&g.renderer, m.world, MICRO_READ)
		if !testing.expect(t, read && len(data) == MICRO_READ_WORDS * 4, "the batch was read back") {continue}
		words := ([^]u32)(raw_data(data))[:MICRO_READ_WORDS]
		count := min(int(words[0]), MICRO_READ_INSTANCES)
		testing.expectf(t, count > 0 && u32(count) <= m.batches[0].room, "%v m: %d written", c.height, words[0])
		for k in 0 ..< count {
			w := words[1 + k * 6:][:6]
			x, y, z := mm.half_unpack(u16(w[4])), mm.half_unpack(u16(w[4] >> 16)), mm.half_unpack(u16(w[5]))
			widen := x / y
			if !testing.expectf(t, widen >= c.widen[0] - 0.01 && widen <= c.widen[1] + 0.01 && abs(z - x) < 1e-2 * x, "%v m: instance %d widens by %v (%v, %v, %v)", c.height, k, widen, x, y, z) {break}
			// Its height is that of its look, or less while it grows from the ground.
			if !testing.expectf(t, y > 0 && y <= 1.001, "%v m: instance %d stands %v high", c.height, k, y) {break}
		}
	}
	testing.expect(t, growing, "some grow from the ground at the edge of the thinning")
	testing.expectf(t, rhi.device_validation_errors(g.device) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(g.device), rhi.device_validation_message(g.device))
}
