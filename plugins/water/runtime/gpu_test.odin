package water

import "core:fmt"
import "core:math"
import "core:math/linalg"
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
@(private)
@(test_world)
Water_World :: struct {
	using world:   Test_World,
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
gpu_fixture_init :: proc(t: ^testing.T, f: ^Gpu_Fixture, indirect := true) -> bool {
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
	settings.gi_enabled = indirect
	if !testing.expect(t, gpu.renderer_init(&f.renderer, {device = device, width = WIDTH, height = HEIGHT, settings = settings, shaders = &loaded}), f.renderer.error) {return false}
	folder := base.test_folder(t, "water-gpu")
	if folder == "" || !testing.expect(t, host.assets_init(&f.assets, {root = folder, renderer = &f.renderer})) {return false}
	f.app = host.App{allocator = context.allocator, renderer = &f.renderer, assets = &f.assets, device = device}
	cube := host.assets_shape(&f.assets, .Cube)
	if !testing.expect(t, cube != nil) {return false}
	f.cube = cube.handle
	gpu.scene_world(&f.renderer, 1)
	if !test_world_init(t,&f.world) {return false}
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
	test_world_destroy(&f.world)
	delete(f.media.queue.items)
	delete(f.app.extras.instances)
	host.assets_destroy(&f.assets)
	gpu.renderer_destroy(&f.renderer)
}

// The light of a frame: the sky alone, or a sun over a black sky that bounces nothing.
@(private = "file")
Frame_Light :: struct {
	sun: [3]f32, // towards the sun; zero: none
	sky: [3]f32,
}

// A frame of the water of the physics over a dark floor at y 0 and what is
// shown with it, seen straight from above, and its pixels.
@(private = "file")
water_frame :: proc(t: ^testing.T, f: ^Gpu_Fixture, light := Frame_Light{sky = {0.4, 0.5, 0.6}}, shown: []gpu.Instance_Desc = nil) -> (pixels: []u8, ok: bool) {
	camera := gpu.Camera{position = {0, 14, 0.01}, forward = {0, -1, -0.001}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	view := core.View{position = camera.position, rotation = mm.quat_between({0, 0, -1}, camera.forward), fov = mm.PI / 3, near = camera.near, far = camera.far, size = {WIDTH, HEIGHT}}
	for _ in 0 ..< 4 {
		clear(&f.app.extras.instances)
		core.queue_clear(&f.media.queue)
		test_world_settle(&f.world)
		phys.test_step(&f.world.physics, &f.host, 0)
		water_render(&f.state, &f.media, core.read(&f.world.waters), {&f.world.state}, {}, view, &f.app, {}, {})
		host.assets_commit(&f.assets)
		instances := make([dynamic]gpu.Instance_Desc, context.temp_allocator)
		append(&instances, gpu.Instance_Desc{object_id = 1, mesh = f.cube, transform = mm.transform_matrix({{0, -0.5, 0}, mm.QUAT_IDENTITY, {40, 1, 40}}), tint = {0.05, 0.05, 0.05}})
		append(&instances, ..shown)
		append(&instances, ..f.app.extras.instances[:])
		sun := gpu.Sun_Desc{direction = light.sun, color = {1, 1, 1}, illuminance = 3, enabled = light.sun != {}, scattering = 1}
		gpu.scene_set_environment(&f.renderer, sun, {sky = light.sky})
		testing.expect(t, gpu.scene_update(&f.renderer, 0, instances[:], true), f.renderer.error)
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

// Where a point at a height lands on the image of water_frame: the view looks down with -z up the image.
@(private = "file")
on_image :: proc(p: [2]f32, height: f32 = 0) -> (x, y: int) {
	half := (14 - height) * 0.57735 // tan of half the view, at the height of the camera over the point
	return int(f32(WIDTH) * 0.5 + p.x / half * f32(HEIGHT) * 0.5), int(f32(HEIGHT) * 0.5 + p.y / half * f32(HEIGHT) * 0.5)
}

@(private = "file")
differs :: proc(a, b: [3]i32) -> bool {return abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) > 12}

// A lake is a box drawn within its walls, and water along a path a ribbon
// along it: each changes the floor where its fluid is and leaves it as it was
// away from it. Probe lighting is off because the added surfaces also change
// the indirect light reaching dry pixels.
@(test)
a_lake_and_a_river_draw_where_their_fluids_are :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, indirect = false) {return}
	defer gpu_fixture_destroy(f)
	dry, dry_ok := water_frame(t, f)
	if !dry_ok {return}
	defer delete(dry)
	w := &f.world
	lake := core.create(&w.entities)
	core.add(&w.fluids, lake, phys.FLUID_DEFAULT)
	// An L 1 m deep whose notch is the square from -3 to -1 on x and from 0 to 2 on z.
	core.add(&w.volumes, lake, volume.outline(1))
	core.add(&w.splines, lake, volume.Spline{count = 6, points = {0 = {position = {-2, 0, -2}}, 1 = {position = {2, 0, -2}}, 2 = {position = {2, 0, 0}}, 3 = {position = {0, 0, 0}}, 4 = {position = {0, 0, 2}}, 5 = {position = {-2, 0, 2}}}})
	core.add(&w.transforms, lake, core.Transform{{-3, 0.25, 0}, mm.QUAT_IDENTITY, {1, 1, 1}})
	// A Spline with a Fluid: a bend 1.5 m wide and 0.4 m deep, flowing at 1 m/s, its surface over the floor.
	river := core.create(&w.entities)
	core.add(&w.fluids, river, phys.FLUID_DEFAULT)
	core.add(&w.splines, river, volume.Spline{count = 3, points = {0 = {{3, 0.3, 3}, 1.5, 0.4, 1}, 1 = {{4, 0.3, 0}, 1.5, 0.4, 1}, 2 = {{3, 0.3, -3}, 1.5, 0.4, 1}}})
	wet, wet_ok := water_frame(t, f)
	testing.expect_value(t, w.state.world.fluid_count, 2)
	if !wet_ok {return}
	defer delete(wet)
	Case :: struct {name: string, at: [2]f32, water: bool}
	for c in ([]Case{
		{"in the lake", {-4, -1}, true},
		{"in the notch of the lake", {-2, 1}, false},

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

// The light of a pixel and those around it before the display: under the
// highlights PBR Neutral takes 0.04 off each channel and the image is sRGB.
@(private = "file")
light_at :: proc(pixels: []u8, x, y: int) -> (light: [3]f32, linear: bool) {
	linear = true
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			c := pixel_at(pixels, x + dx, y + dy)
			for v, i in c {
				linear &&= v >= 56 && v <= 221
				light[i] += (mm.srgb_to_linear(f32(v) / 255) + 0.04) / 9
			}
		}
	}
	return
}

// What is under the water takes the light the water lets through on its way
// down: the light of a pillar at a depth, over that of the same pillar under
// water that takes nothing, is what the water takes of each color along the
// light under its surface and along the view, and the top of one out of the
// water keeps its light.
@(test)
the_water_takes_the_light_on_its_way_down :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	Pillar :: struct {at: [2]f32, top: f32}
	pillars := []Pillar{{{-3, -2}, 1.5}, {{3, -2}, 0.2}, {{3, 2.5}, 1}, {{-3, 2.5}, 2.6}}
	shown := make([]gpu.Instance_Desc, len(pillars), context.temp_allocator)
	for p, i in pillars {
		shown[i] = {object_id = u64(10 + i), mesh = f.cube, transform = mm.transform_matrix({{p.at.x, 0.5 * (p.top - 1), p.at.y}, mm.QUAT_IDENTITY, {1.6, p.top + 1, 1.6}}), tint = {0.5, 0.5, 0.5}}
	}
	w := &f.world
	lake := core.create(&w.entities)
	core.add(&w.fluids, lake, phys.FLUID_DEFAULT)
	core.add(&w.volumes, lake, volume.box({5, 1.5, 5}))
	core.add(&w.transforms, lake, core.Transform{{0, 0.5, 0}, mm.QUAT_IDENTITY, {1, 1, 1}})
	SURFACE :: f32(2)
	look := Water{attenuation_color = {0.3, 0.7, 0.75}, attenuation_distance = 4}
	clear := look
	clear.attenuation_distance = 0
	taken := absorption(look)
	Case :: struct {name: string, sun: [3]f32, pillar: int, out: bool}
	cases := []Case{
		{"half a metre under a high sun", {0.1, 1, 0.05}, 0, false},
		{"almost two metres under a high sun", {0.1, 1, 0.05}, 1, false},
		{"a metre under a lower sun", {0.8, 0.8, 0.3}, 2, false},
		{"out of the water under a lower sun", {0.8, 0.8, 0.3}, 3, true},
	}
	for c in cases {
		light := Frame_Light{sun = c.sun}
		core.add(&w.waters, lake, look)
		wet, wet_ok := water_frame(t, f, light, shown)
		core.add(&w.waters, lake, clear)
		through, through_ok := water_frame(t, f, light, shown)
		defer delete(wet)
		defer delete(through)
		if !wet_ok || !through_ok {return}
		p := pillars[c.pillar]
		x, y := on_image(p.at, p.top)
		taking, a := light_at(wet, x, y)
		letting, b := light_at(through, x, y)
		testing.expectf(t, a && b, "%s: the pixels are past the linear part of the display: %v and %v", c.name, pixel_at(wet, x, y), pixel_at(through, x, y))
		expected := [3]f32{1, 1, 1}
		if !c.out {
			depth := SURFACE - p.top
			sun := linalg.normalize(c.sun)
			// Under the surface the light of the sun and the view go as the surface bends them.
			sun_under := math.sqrt(1 - (1 - sun.y * sun.y) / (WATER_IOR * WATER_IOR))
			eye := [3]f32{p.at.x, 14 - p.top, p.at.y}
			seen := eye.y / linalg.length(eye)
			view_under := math.sqrt(1 - (1 - seen * seen) / (WATER_IOR * WATER_IOR))
			for &e, i in expected {e = math.exp(-taken[i] * depth * (1 / sun_under + 1 / view_under))}
		}
		for i in 0 ..< 3 {
			testing.expectf(t, abs(taking[i] / letting[i] - expected[i]) < 0.05 * expected[i], "%s: the water lets %v of the light through, not %v (%v of %v)", c.name, taking / letting, expected, taking, letting)
		}
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(f.device), rhi.device_validation_message(f.device))
}
