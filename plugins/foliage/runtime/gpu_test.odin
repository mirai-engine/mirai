package foliage

import "core:fmt"
import "core:path/filepath"
import "core:testing"
import "mirai:core"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import mm "mirai:std/math"

// The hook of foliage on the GPU, with the shaders of the engine and of the
// plugin: a stalk of a batch of foliage over a dark floor, seen from above.

@(private = "file")
ROOT :: #directory + "/../../.."
@(private = "file")
WIDTH :: 160
@(private = "file")
HEIGHT :: 120

@(private = "file")
Gpu_Fixture :: struct {
	device:   ^rhi.Device,
	renderer: gpu.Renderer,
	assets:   host.Assets,
	app:      host.App,
	world:    Bend_World,
	resident: Foliage_Resident,
	cube:     gpu.Mesh_Handle,
}

@(private = "file")
gpu_fixture_init :: proc(t: ^testing.T, f: ^Gpu_Fixture) -> bool {
	root, _ := filepath.clean(ROOT, context.temp_allocator)
	// mirai test generates them: cook is not shipped, and the game compiles its test files.
	loaded, problem := gpu.shader_assets_load(fmt.tprintf("%s/.mirai/tmp/foliage-test-shaders", root))
	if !testing.expect(t, problem == "", problem) {return false}
	device := shared_device.take_or_skip(t)
	if device == nil {
		gpu.shader_assets_destroy(&loaded)
		return false
	}
	f.device = device
	settings := gpu.DEFAULT_SETTINGS
	settings.taa = false
	if !testing.expect(t, gpu.renderer_init(&f.renderer, {device = device, width = WIDTH, height = HEIGHT, settings = settings, shaders = &loaded}), f.renderer.error) {return false}
	folder := base.test_folder(t, "foliage-gpu")
	if folder == "" || !testing.expect(t, host.assets_init(&f.assets, {root = folder, renderer = &f.renderer})) {return false}
	f.app = host.App{allocator = context.allocator, renderer = &f.renderer, assets = &f.assets, device = device}
	cube := host.assets_shape(&f.assets, .Cube)
	if !testing.expect(t, cube != nil) {return false}
	f.cube = cube.handle
	f.resident.app = &f.app
	f.resident.world = {index = 1}
	gpu.scene_world(&f.renderer, render.world_key(f.resident.world))
	return test_world_init(t, &f.world)
}

@(private = "file")
gpu_fixture_destroy :: proc(f: ^Gpu_Fixture) {
	if f.device == nil {return}
	rhi.device_wait_idle(f.device)
	trample_free(&f.resident)
	for &set in f.resident.winds {wind_set_free(&f.renderer, &set)}
	delete(f.resident.winds)
	test_world_destroy(&f.world)
	delete(f.app.extras.instances)
	host.assets_destroy(&f.assets)
	gpu.renderer_destroy(&f.renderer)
}

// Frames of the stalk with the field the benders of the world trample and
// the variants of the wind swayed, and the pixels of the last.
@(private = "file")
stalk_frames :: proc(t: ^testing.T, f: ^Gpu_Fixture) -> (pixels: []u8, ok: bool) {
	camera := gpu.Camera{position = {0, 14, 0.01}, forward = {0, -1, -0.001}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	for _ in 0 ..< 4 {
		test_world_settle(&f.world)
		trample_draw(&f.resident, core.read(&f.world.benders), core.read(&f.world.volumes), core.read(&f.world.worlds), core.FRAME_TIME_DEFAULT, {}, &f.renderer)
		render.frame_pass(&f.renderer, .Mask, foliage_wind_record, &f.resident)
		for &set in f.resident.winds {
			for mesh in set.variants[:set.count] {render.deformable_update(&f.renderer, mesh, set.low, set.high)}
		}
		if len(f.resident.winds) > 0 {render.frame_pass(&f.renderer, .Geometry, foliage_sway_record, &f.resident)}
		floor := gpu.Instance_Desc{object_id = 1, mesh = f.cube, transform = mm.transform_matrix({{0, -0.5, 0}, mm.QUAT_IDENTITY, {40, 1, 40}}), tint = {0.05, 0.05, 0.05}}
		gpu.scene_set_environment(&f.renderer, {direction = {0.3, -1, 0.2}, color = {1, 1, 1}, illuminance = 3}, {sky = {0.4, 0.5, 0.6}})
		testing.expect(t, gpu.scene_update(&f.renderer, 0, {floor}, true), f.renderer.error)
		testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera}), f.renderer.error)
	}
	rhi.device_wait_idle(f.device)
	pixels, _, _, ok = gpu.renderer_capture(&f.renderer)
	testing.expect(t, ok, f.renderer.error)
	return
}

// Where a point of the floor lands on the image: the view looks down with -z up the image.
@(private = "file")
pixel_at :: proc(pixels: []u8, p: [2]f32) -> [3]i32 {
	half := f32(14) * 0.57735
	x, y := int(f32(WIDTH) * 0.5 + p.x / half * f32(HEIGHT) * 0.5), int(f32(HEIGHT) * 0.5 + p.y / half * f32(HEIGHT) * 0.5)
	i := (y * WIDTH + x) * 4
	return {i32(pixels[i]), i32(pixels[i + 1]), i32(pixels[i + 2])}
}

@(private = "file")
differs :: proc(a, b: [3]i32) -> bool {return abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) > 12}

// A stalk of a batch of foliage stands up until a bender tramples the field
// beside it: then what stands over its place leans away from the bender,
// and what lies on the other side stays as it was, without validation
// errors. A batch that is not of foliage does not lean.
@(test)
a_stalk_leans_away_from_where_a_bender_trampled_the_field :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	// A white stalk 4 m tall standing at the origin, its place at its middle.
	desc := render.Batch_Desc{mesh = f.cube, tint = 1, vertex = {0, 1, 0, 0}, reach = hook_reach(0, 2)}
	stalk, problem := render.batch_set(&f.renderer, f.resident.world, 0, desc, {render.batch_instance({0, 2, 0}, 1, 0.4, 4)})
	if !testing.expect(t, problem == "", problem) {return}
	standing, ok := stalk_frames(t, f)
	if !ok {return}
	defer delete(standing)
	floor := pixel_at(standing, {-1.4, 0})
	testing.expect(t, !differs(pixel_at(standing, {1.4, 0}), floor), "standing, the stalk covers no floor beside it")
	testing.expect(t, differs(pixel_at(standing, {0, 0}), floor), "the stalk is drawn")
	e := core.create(&f.world.entities)
	place := mm.TRANSFORM_IDENTITY
	place.position = {-0.5, 2, 0}
	core.add(&f.world.benders, e, Foliage_Bender{lean = BEND_LEAN_MAX})
	core.add(&f.world.volumes, e, volume.sphere(2))
	core.add(&f.world.worlds, e, core.World_Transform{place, place})
	leaning, leaned := stalk_frames(t, f)
	if !leaned {return}
	defer delete(leaning)
	testing.expect(t, differs(pixel_at(leaning, {1.4, 0}), floor), "trampled, its top leans away from the bender")
	testing.expect(t, !differs(pixel_at(leaning, {-1.4, 0}), floor), "and nothing leans toward it")
	// The same stalk, of a batch that is not of foliage, stands.
	desc.vertex = {}
	_, problem = render.batch_set(&f.renderer, f.resident.world, stalk, desc, {render.batch_instance({0, 2, 0}, 1, 0.4, 4)})
	if !testing.expect(t, problem == "", problem) {return}
	other, drawn := stalk_frames(t, f)
	if !drawn {return}
	defer delete(other)
	testing.expect(t, !differs(pixel_at(other, {1.4, 0}), floor), "a batch of anything else does not lean")
}

// A variant of the wind of a type with shadows bends a block downwind about
// where it stands, its middle: its top over the floor downwind, none upwind,
// and what is below its place stays where it stood. Points of the floor seen
// past the block's top, 6 m up a camera 14 m up, land 14/8 times as far out.
@(test)
a_variant_leans_downwind_about_its_place :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	at := wind_set(&f.resident, &f.renderer, f.cube, 4, 0.08, -1, {})
	if !testing.expect(t, at >= 0, "the variants are made") {return}
	f.resident.winds[at].sway = {WIND_SPEED_MAX, 0, 0, 0.6}
	variant := f.resident.winds[at].variants[wind_variant(1, {0, 3, 0}, 4)]
	_, problem := render.batch_set(&f.renderer, f.resident.world, 0, {mesh = variant, tint = 1}, {render.batch_instance({0, 3, 0}, 1, 6, 6)})
	if !testing.expect(t, problem == "", problem) {return}
	pixels, ok := stalk_frames(t, f)
	if !ok {return}
	defer delete(pixels)
	floor := pixel_at(pixels, {-8, 0})
	testing.expect(t, differs(pixel_at(pixels, {6, 0}), floor), "its top leans downwind")
	testing.expect(t, !differs(pixel_at(pixels, {-6, 0}), floor), "and not upwind")
	testing.expect(t, differs(pixel_at(pixels, {-2.7, 0}), floor), "what is below its place stays")
}
