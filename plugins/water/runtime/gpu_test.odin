package water

import "core:fmt"
import "core:path/filepath"
import "core:testing"
import "mirai:core"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import mm "mirai:std/math"
import fog "plugins:fog/runtime"
import phys "plugins:physics/runtime"
import volume "mirai:engine/volume"

// The water of the frame on the GPU, with the shaders of the engine and the
// stages of the plugin, over a dark floor seen from above: the water is
// where its fluid is, and nowhere else.

@(private = "file")
ROOT :: #directory + "/../../.."
@(private = "file")
WIDTH :: 160
@(private = "file")
HEIGHT :: 120

// The fluids, as physics makes them from the rows of a world.
@(private = "file")
Water_World :: struct {
	using world:   core.Test_World,
	using physics: phys.Test_Physics,
	waters:        core.Table(Water),
}

@(private = "file")
Gpu_Fixture :: struct {
	device:   ^rhi.Device,
	renderer: gpu.Renderer,
	assets:   host.Assets,
	app:      host.App,
	world:    Water_World,
	host:     phys.Test_Physics_Host,
	state:    Water_Gpu,
	media:    fog.Fog_Media,
	cube:     gpu.Mesh_Handle,
}

@(private = "file")
gpu_fixture_init :: proc(t: ^testing.T, f: ^Gpu_Fixture) -> bool {
	root, _ := filepath.clean(ROOT, context.temp_allocator)
	// mirai test generates them: cook is not shipped, and the game compiles its test files.
	loaded, problem := gpu.shader_assets_load(fmt.tprintf("%s/.mirai/tmp/water-test-shaders", root))
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
	folder := base.test_folder(t, "water-gpu")
	if folder == "" || !testing.expect(t, host.assets_init(&f.assets, {root = folder, renderer = &f.renderer})) {return false}
	f.app = host.App{allocator = context.allocator, renderer = &f.renderer, assets = &f.assets, device = device}
	cube := host.assets_shape(&f.assets, .Cube)
	if !testing.expect(t, cube != nil) {return false}
	f.cube = cube.handle
	gpu.scene_world(&f.renderer, 1)
	if !core.test_world_init(t, &f.world, test_types) {return false}
	f.world.settings = {bodies = 8, shapes = 8, contacts = 16, fluids = 4}
	return true
}

@(private = "file")
gpu_fixture_destroy :: proc(f: ^Gpu_Fixture) {
	if f.device == nil {return}
	// No frame draws them any more.
	f.state.frame += 1
	ribbons_release(&f.state, &f.assets)
	sheets_release(&f.state, &f.renderer)
	phys.test_host_destroy(&f.host)
	core.test_world_destroy(&f.world)
	delete(f.media.queue.items)
	delete(f.app.extras.instances)
	host.assets_destroy(&f.assets)
	gpu.renderer_destroy(&f.renderer)
}

// A frame of the water of the physics over a dark floor at y 0, seen straight from above, and its pixels.
@(private = "file")
water_frame :: proc(t: ^testing.T, f: ^Gpu_Fixture) -> (pixels: []u8, ok: bool) {
	camera := gpu.Camera{position = {0, 14, 0.01}, forward = {0, -1, -0.001}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	view := core.View{position = camera.position, rotation = mm.quat_between({0, 0, -1}, camera.forward), fov = mm.PI / 3, near = camera.near, far = camera.far, size = {WIDTH, HEIGHT}}
	for _ in 0 ..< 4 {
		clear(&f.app.extras.instances)
		core.queue_clear(&f.media.queue)
		core.test_world_settle(&f.world)
		phys.test_step(&f.world.physics, &f.host, 0)
		water_render(&f.state, &f.media, core.read(&f.world.waters), {&f.world.state}, {}, view, &f.app, {}, {})
		instances := make([dynamic]gpu.Instance_Desc, context.temp_allocator)
		append(&instances, gpu.Instance_Desc{object_id = 1, mesh = f.cube, transform = mm.transform_matrix({{0, -0.5, 0}, mm.QUAT_IDENTITY, {40, 1, 40}}), tint = {0.05, 0.05, 0.05}})
		append(&instances, ..f.app.extras.instances[:])
		testing.expect(t, gpu.scene_set(&f.renderer, instances[:], nil, {direction = {0.3, -1, 0.2}, color = {1, 1, 1}, illuminance = 3}, {sky = {0.4, 0.5, 0.6}}), f.renderer.error)
		testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera}), f.renderer.error)
	}
	rhi.device_wait_idle(f.device)
	pixels, _, _, ok = gpu.renderer_capture(&f.renderer)
	testing.expect(t, ok, f.renderer.error)
	return
}

@(private = "file")
pixel_at :: proc(pixels: []u8, x, y: int) -> [3]i32 {
	i := (y * WIDTH + x) * 4
	return {i32(pixels[i]), i32(pixels[i + 1]), i32(pixels[i + 2])}
}

// Where a point of the floor lands on the image of water_frame: the view looks down with -z up the image.
@(private = "file")
on_image :: proc(p: [2]f32) -> (x, y: int) {
	half := f32(14) * 0.57735 // tan of half the view, at the height of the camera
	return int(f32(WIDTH) * 0.5 + p.x / half * f32(HEIGHT) * 0.5), int(f32(HEIGHT) * 0.5 + p.y / half * f32(HEIGHT) * 0.5)
}

@(private = "file")
differs :: proc(a, b: [3]i32) -> bool {return abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) > 12}

// A lake is a box drawn within its walls, and water along a path a ribbon
// along it: each changes the floor where its fluid is and leaves it as it was
// away from it, without validation errors.
@(test)
a_lake_and_a_river_draw_where_their_fluids_are :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	dry, dry_ok := water_frame(t, f)
	if !dry_ok {return}
	defer delete(dry)
	w := &f.world
	lake := core.create(&w.entities)
	core.add(&w.fluids, lake, phys.FLUID_DEFAULT)
	core.add(&w.volumes, lake, volume.box({2, 0.5, 2}))
	core.add(&w.transforms, lake, core.Transform{{-3, 0.25, 0}, mm.QUAT_IDENTITY, {1, 1, 1}})
	// The samples a Spline of shapes hands the physics: a bend 1.5 m wide and 0.4 m deep.
	river := core.create(&w.entities)
	core.add(&w.fluids, river, phys.Fluid{density = 1000, current = {0, 0, -1}})
	path: phys.Fluid_Path
	path.count = u16(mm.path_sample({{{3, 0.4, 3}, 1.5, 0.4}, {{4, 0.4, 0}, 1.5, 0.4}, {{3, 0.4, -3}, 1.5, 0.4}}, 1, path.points[:]))
	core.add(&w.paths, river, path)
	wet, wet_ok := water_frame(t, f)
	testing.expect_value(t, w.state.world.fluid_count, 2)
	if !wet_ok {return}
	defer delete(wet)
	Case :: struct {name: string, at: [2]f32, water: bool}
	for c in ([]Case{
		{"in the lake", {-3, 0}, true},
		{"on the river", {4, 0}, true},
		{"beside the lake", {-3, 4}, false},
		{"between the lake and the river", {0.5, 0}, false},
		{"inside the bend of the river", {1.5, 0}, false},
	}) {
		x, y := on_image(c.at)
		testing.expectf(t, differs(pixel_at(dry, x, y), pixel_at(wet, x, y)) == c.water, "%s: %v without water, %v with it", c.name, pixel_at(dry, x, y), pixel_at(wet, x, y))
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(f.device), rhi.device_validation_message(f.device))
}
