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
// plugin: a tile of small cubes over a dark floor, seen from above.

@(private = "file")
MICRO_ROOT :: #directory + "/../../.."
@(private = "file")
MICRO_WIDTH :: 160
@(private = "file")
MICRO_HEIGHT :: 120
@(private = "file")
MICRO_DRAWS_READ :: "test micro draws"

@(private = "file")
Micro_Gpu :: struct {
	device:   ^rhi.Device,
	renderer: gpu.Renderer,
	cube:     gpu.Mesh_Handle,
	fixture:  Micro_Fixture,
}

@(private = "file")
micro_gpu_init :: proc(t: ^testing.T, g: ^Micro_Gpu) -> bool {
	root, _ := filepath.clean(MICRO_ROOT, context.temp_allocator)
	loaded, problem := gpu.shader_assets_load(fmt.tprintf("%s/.mirai/tmp/foliage-test-shaders", root))
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
	primitives, drawable := render.mesh_primitive_count(&g.renderer, g.cube)
	if !testing.expect(t, drawable && primitives > 0) {return false}
	f.micro.looks[0].row.mesh.y = primitives / CLUSTER_PRIMITIVES
	return true
}

@(private = "file")
micro_gpu_destroy :: proc(g: ^Micro_Gpu) {
	if g.device == nil {return}
	rhi.device_wait_idle(g.device)
	micro_fixture_destroy(&g.fixture)
	host.assets_destroy(&g.fixture.assets)
	gpu.renderer_destroy(&g.renderer)
}

@(private = "file")
micro_draws_read :: proc(pass: ^render.Pass, user: rawptr) {
	render.pass_readback(pass, {name = MICRO_DRAWS, size = MICRO_LOOKS * 16}, 0, {name = MICRO_DRAWS_READ, size = 16})
}

// Frames of the tile seen from above with what the step of a frame does for
// it, an occluder over it when `covered`, and the pixels of the last.
@(private = "file")
micro_frames :: proc(t: ^testing.T, g: ^Micro_Gpu, frames: int, covered := false) -> (pixels: []u8, ok: bool) {
	f := &g.fixture
	problems: core.Problems
	camera := gpu.Camera{position = {4, 7, 4.01}, forward = {0, -1, -0.001}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	for _ in 0 ..< frames {
		micro_jobs_of(f, &problems)
		render.frame_gbuffer_mesh(&g.renderer, g.cube, 0)
		render.frame_mesh_whole(&g.renderer, g.cube)
		if len(f.micro.jobs) > 0 {render.frame_pass(&g.renderer, .Simulate, foliage_micro_generate, &f.micro)}
		render.frame_pass(&g.renderer, .Gbuffer, foliage_micro_draw, &f.micro)
		render.frame_pass(&g.renderer, .Gbuffer, micro_draws_read)
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

// The micro instances of a tile are generated once in the Simulate stage,
// however many frames draw them, and each view keeps those it sees and
// draws them into the G-buffer: bright cubes over the dark floor. Under an
// occluder the depth of the scene hides every one of them, and none is
// drawn; no frame reports a validation error.
@(test)
a_micro_tile_is_generated_once_and_each_view_draws_what_it_sees :: proc(t: ^testing.T) {
	g := new(Micro_Gpu)
	defer free(g)
	if !micro_gpu_init(t, g) {return}
	defer micro_gpu_destroy(g)
	m := &g.fixture.micro
	pixels, ok := micro_frames(t, g, 6)
	if !ok {return}
	defer delete(pixels)
	testing.expect_value(t, m.stats.generated, u64(1))
	testing.expect(t, m.tiles[0].key == m.tiles[0].want && m.capacity >= m.end && m.end == 32 * 32)
	bright, dark := 0, 0
	for i := 0; i + 3 < len(pixels); i += 4 {
		if int(pixels[i]) + int(pixels[i + 1]) + int(pixels[i + 2]) > 150 {bright += 1} else {dark += 1}
	}
	testing.expectf(t, bright > len(pixels) / 4 / 20 && dark > len(pixels) / 4 / 4, "cubes over the floor: %d bright pixels, %d dark", bright, dark)
	data, _, read := render.readback(&g.renderer, m.world, MICRO_DRAWS_READ)
	if testing.expect(t, read && len(data) == 16, "the draws were read back") {
		draw := (^[4]u32)(raw_data(data))^
		testing.expectf(t, draw[0] == m.looks[0].row.mesh.y * 384 && draw[1] > 100 && draw[1] <= 32 * 32, "the cubes the view sees: %v", draw)
	}
	covered: []u8
	if covered, ok = micro_frames(t, g, 4, true); !ok {return}
	delete(covered)
	data, _, read = render.readback(&g.renderer, m.world, MICRO_DRAWS_READ)
	if testing.expect(t, read && len(data) == 16) {
		draw := (^[4]u32)(raw_data(data))^
		testing.expectf(t, draw[1] == 0, "the occluder hides them all: %v", draw)
	}
	testing.expect_value(t, m.stats.generated, u64(1))
	testing.expect(t, render.readback_release(&g.renderer, m.world, MICRO_DRAWS_READ))
	testing.expectf(t, rhi.device_validation_errors(g.device) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(g.device), rhi.device_validation_message(g.device))
}

