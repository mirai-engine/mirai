package vfx

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import evolume "mirai:engine/volume"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import fog "plugins:fog/runtime"
import "plugins:vfx/runtime/effect"
import "plugins:vfx/runtime/gridfile"

// The passes of the plugin on the GPU, with the shaders of the engine, the
// stages of the plugin and the programs of testdata: a generation into
// .mirai/tmp of the engine, which the tests after the first find up to date.

@(private = "file")
ROOT :: #directory + "/../../.."

@(private = "file")
Gpu_Fixture :: struct {
	device:     ^rhi.Device,
	renderer:   gpu.Renderer,
	assets:     host.Assets,
	app:        host.App,
	sync:       Particle_Sync,
	cube:       gpu.Mesh_Handle,
	cube_vertices: u32, // of a draw of level 0 of the cube
	folder:     string,
}

@(private = "file")
gpu_fixture_init :: proc(t: ^testing.T, f: ^Gpu_Fixture, width, height: u32, settings: gpu.Settings) -> bool {
	root, _ := filepath.clean(ROOT, context.temp_allocator)
	// mirai test generates them: cook is not shipped, and the game compiles its test files.
	output := fmt.tprintf("%s/.mirai/tmp/vfx-test-shaders", root)
	loaded, problem := gpu.shader_assets_load(output)
	if !testing.expect(t, problem == "", problem) {return false}
	device := shared_device.take_or_skip(t)
	if device == nil {
		gpu.shader_assets_destroy(&loaded)
		return false
	}
	f.device = device
	if !testing.expect(t, gpu.renderer_init(&f.renderer, {device = device, width = width, height = height, settings = settings, shaders = &loaded}), f.renderer.error) {return false}
	f.folder = base.test_folder(t, "vfx-gpu")
	if !testing.expect(t, host.assets_init(&f.assets, {root = f.folder, renderer = &f.renderer})) {return false}
	f.app = host.App{allocator = context.allocator, renderer = &f.renderer, assets = &f.assets, device = device}
	cube := host.assets_shape(&f.assets, .Cube)
	if !testing.expect(t, cube != nil) {return false}
	f.cube = cube.handle
	f.cube_vertices, _ = erender.mesh_draw_range(f.app.renderer, f.cube)
	f.sync.world = 1
	gpu.scene_world(&f.renderer, f.sync.world)
	return true
}

@(private = "file")
gpu_fixture_destroy :: proc(f: ^Gpu_Fixture) {
	if f.device == nil {return}
	particle_sync_free(&f.sync)
	host.assets_destroy(&f.assets)
	gpu.renderer_destroy(&f.renderer)
}

// The emitters of a world for the next frame, as particles_sync gives them.
// False when one found no room.
@(private = "file")
frame_emitters :: proc(f: ^Gpu_Fixture, sync: ^Particle_Sync, emitters: []Emitter_Desc, dt: f32, capacity: u32 = CAPACITY) -> bool {
	dropped, ok := pool_emitters(&sync.pool, emitters, dt, capacity, erender.max_storage_range(&f.app))
	particles_frame(sync, &f.app)
	return ok && dropped == 0
}

// What the finish pass counted two frames ago.
@(private = "file")
particles_alive :: proc(f: ^Gpu_Fixture) -> u32 {
	values, _ := erender.counters(f.app.renderer, "particles")
	return values[0]
}

// The resource rows of an emitter, those given first, as particles_sync makes them.
@(private = "file")
test_resources :: proc(sync: ^Particle_Sync, rows: ..Resource_Desc) -> u32 {
	first := u32(len(sync.resources)) + 1
	all: [RESOURCE_ROWS]Resource_Desc
	copy(all[:], rows)
	append(&sync.resources, ..all[:])
	return first
}

@(private = "file")
GRADIENT_WHITE :: effect.Particle_Gradient{colors = {{1, 1, 1, 1}, {1, 1, 1, 1}, {1, 1, 1, 1}, {1, 1, 1, 1}, {1, 1, 1, 1}, {1, 1, 1, 1}, {1, 1, 1, 1}, {1, 1, 1, 1}}, times = {0, 1, 1, 1, 1, 1, 1, 1}}

@(private = "file")
test_settings :: proc() -> gpu.Settings {
	s := gpu.DEFAULT_SETTINGS
	s.probe_budget = 4096
	s.probe_rays = 64
	s.probe_grid, s.probe_cascades = 8, 2
	s.probe_spacing = 1.5
	return s
}

@(private = "file")
trs :: proc(position, scale: [3]f32) -> matrix[4, 4]f32 {
	m: matrix[4, 4]f32 = 1
	m[0, 0], m[1, 1], m[2, 2] = scale.x, scale.y, scale.z
	m[0, 3], m[1, 3], m[2, 3] = position.x, position.y, position.z
	return m
}

@(private = "file")
project :: proc(r: ^gpu.Renderer, c: gpu.Camera, p: [3]f32) -> [2]int {
	forward := linalg.normalize(c.forward)
	right := linalg.normalize(linalg.cross(forward, c.up))
	up := linalg.cross(right, forward)
	d := p - c.position
	focal := 1 / math.tan(math.to_radians(c.fov_y) * 0.5)
	aspect := f32(r.targets.width) / f32(r.targets.height)
	depth := linalg.dot(d, forward)
	ndc := [2]f32{linalg.dot(d, right) * focal / aspect / depth, linalg.dot(d, up) * focal / depth}
	return {int((ndc.x * 0.5 + 0.5) * f32(r.targets.width)), int((0.5 - ndc.y * 0.5) * f32(r.targets.height))}
}

@(private = "file")
pixel :: proc(pixels: []u8, width: int, p: [2]int) -> [3]f32 {
	i := (p.y * width + p.x) * 4
	return {f32(pixels[i]), f32(pixels[i + 1]), f32(pixels[i + 2])}
}

@(private = "file")
expect_clean :: proc(t: ^testing.T, d: ^rhi.Device) {
	testing.expectf(t, rhi.device_validation_errors(d) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(d), rhi.device_validation_message(d))
}

@(private = "file")
test_emitter :: proc(id: u64, position: [3]f32) -> Emitter_Desc {
	return {
		id = id, capacity = 64, transform = trs(position, {1, 1, 1}), previous = trs(position, {1, 1, 1}),
		info = {
			shape = .Point, lifetime = {0.5, 0.5}, speed = {0, 0}, size = {0.6, 0.6}, colors = {{1, 1, 1, 1}, {1, 1, 1, 1}},
			render = .Billboard, blend = .Additive, intensity = 4, flipbook = {1, 1},
			size_over_life = effect.PARTICLE_CURVE_ONE, color_over_life = GRADIENT_WHITE,
		},
	}
}

@(test)
particles_start_glow_and_die_on_the_gpu :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{sky = {0.05, 0.05, 0.05}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -0.6, 0}, {12, 0.2, 12}), tint = {0.2, 0.2, 0.2}}},true)
	camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.5, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	emitter := test_emitter(7, {0, 0.5, 0})
	DT :: f32(1.0 / 60)
	seconds: f32
	for i in 0 ..< 6 {
		emitter.spawns = test_burst(32) if i == 0 else {}
		testing.expect(t, frame_emitters(f, &f.sync, {emitter}, DT))
		seconds += DT
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = seconds}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(32))
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if ok {
		glow := pixel(pixels, w, project(r, camera, {0, 0.5, 0}))
		around := pixel(pixels, w, project(r, camera, {1.6, 0.5, 0}))
		testing.expectf(t, glow[0] > around[0] + 60, "the particles %v must glow over the scene around them %v", glow, around)
		delete(pixels)
	}
	emitter.spawns = {}
	for _ in 0 ..< 40 {
		frame_emitters(f, &f.sync, {emitter}, DT)
		seconds += DT
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = seconds}), r.error)
	}
	testing.expect_value(t, particles_alive(f), u32(0))
	expect_clean(t, f.device)
}

@(test)
particles_of_every_kind_draw_around_glass_without_validation_errors :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 96, 64, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.materials_set(r, {{base_color = {0.8, 0.9, 1}, opacity = 0.25, alpha_mode = .Blend, roughness = 0.1, ior = 1.5}})
	gpu.scene_light_update(r,0,{position = {1, 2, 1}, color = {1, 0.8, 0.6}, intensity = 8 * math.PI, range = 10})
	gpu.scene_set_environment(r,{direction = {0.3, 1, 0.2}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true},{sky = {0.2, 0.3, 0.5}})
	gpu.scene_update(r,0,{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.6, 0}, {12, 0.2, 12}), tint = {0.6, 0.6, 0.6}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 0.5, 1.2}, {3, 2, 0.05}), material = 1},
	},true)
	camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	smoke := test_emitter(1, {0, 0, 0})
	smoke.info.blend, smoke.info.lit, smoke.info.sort, smoke.info.collision = .Alpha, true, true, .World
	smoke.info.speed, smoke.info.shape, smoke.info.shape_angle, smoke.info.acceleration = {1, 2}, .Cone, 0.4, {0, -4, 0}
	smoke.info.noise, smoke.info.noise_frequency, smoke.info.noise_speed = 2, 1, 1
	smoke.info.trigger, smoke.event_target, smoke.info.sub_count = .Death, 2, 4
	smoke.info.velocity = {{-0.5, 0, -0.5}, {0.5, 1, 0.5}}
	sparks := test_emitter(2, {0, 0, 0})
	sparks.info.render, sparks.info.collision, sparks.info.speed, sparks.info.stretch, sparks.info.bounce = .Velocity, .World, {2, 3}, 0.05, 0.5
	sparks.info.emission_mode = .Relative
	trail := test_emitter(3, {0, 0.5, 0})
	trail.info.render, trail.info.lit, trail.info.lifetime = .Ribbon, true, {0.4, 0.4}
	pieces := test_emitter(4, {0, 1, 0})
	pieces.info.render, pieces.info.lit, pieces.info.collision, pieces.info.size, pieces.info.spin = .Mesh, true, .World, {0.1, 0.2}, {-3, 3}
	mesh_choices(&pieces, f.app.renderer, {f.cube}, {1})
	pieces.info.shape, pieces.info.shape_size, pieces.info.acceleration = .Sphere, {0.3, 0.3, 0.3}, {0, -9.8, 0}
	ripples := test_emitter(5, {0, -0.45, 0})
	ripples.info.render, ripples.info.flipbook, ripples.info.local_space = .Horizontal, {2, 2}, true
	DT :: f32(1.0 / 60)
	seconds: f32
	births: u32
	for i in 0 ..< 24 {
		previous := trail.transform
		trail.transform = trs({math.sin(seconds * 6), 0.5, math.cos(seconds * 6) * 0.5}, {1, 1, 1})
		trail.previous = previous
		smoke.spawns = test_rate(2, DT, births)
		trail.spawns = test_rate(2, DT, births)
		pieces.spawns = test_burst(1, births) if i % 4 == 0 else {}
		// A prewarm: births over the whole life before the first frame.
		ripples.spawns = test_rate(16, 0.5, births) if i == 0 else {}
		births += 16
		testing.expect(t, frame_emitters(f, &f.sync, {smoke, sparks, trail, pieces, ripples}, DT))
		seconds += DT
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = seconds}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expectf(t, particles_alive(f) > 20, "particles alive: %d", particles_alive(f))
	testing.expect_value(t, u32(f.sync.pool.order_count), u32(5))
	// The second set drops the trail: its range goes back to the pool.
	testing.expect(t, frame_emitters(f, &f.sync, {smoke, sparks, pieces, ripples}, DT))
	testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = seconds + DT}), r.error)
	testing.expect_value(t, u32(f.sync.pool.order_count), u32(4))
	expect_clean(t, f.device)
}

@(test)
particles_keep_steady_frames_allocation_free :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{sky = {0.2, 0.3, 0.5}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -0.6, 0}, {12, 0.2, 12})}},true)
	camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	emitters := [2]Emitter_Desc{test_emitter(1, {0, 0, 0}), test_emitter(2, {1, 0, 0})}
	emitters[1].info.blend, emitters[1].info.sort, emitters[1].info.lit = .Alpha, true, true
	for &e in emitters {e.spawns = test_rate(3, 1.0 / 60)}
	for _ in 0 ..< 4 {
		frame_emitters(f, &f.sync, emitters[:], 1.0 / 60)
		testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	}
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	{
		context.allocator = mem.tracking_allocator(&tracker)
		for _ in 0 ..< 4 {
			frame_emitters(f, &f.sync, emitters[:], 1.0 / 60)
			gpu.renderer_frame(r, {camera = camera})
		}
	}
	testing.expect_value(t, tracker.total_allocation_count, i64(0))
	expect_clean(t, f.device)
}

@(test)
ribbon_lays_a_band_along_the_path_of_its_emitter :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 128, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -1, 0}, {12, 0.2, 12}), tint = {0.1, 0.1, 0.1}}},true)
	camera := gpu.Camera{position = {0, 0, 5}, forward = {0, 0, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	trail := test_emitter(1, {-2, 0, 0})
	trail.info.render, trail.info.lifetime, trail.info.size, trail.info.soft = .Ribbon, {2, 2}, {0.3, 0.3}, 0
	DT :: f32(1.0 / 60)
	for i in 0 ..< 60 {
		trail.previous = trail.transform
		trail.transform = trs({-2 + f32(i + 1) * 4.0 / 60, 0, 0}, {1, 1, 1})
		trail.spawns = test_rate(2, DT, u32(i) * 2)
		frame_emitters(f, &f.sync, {trail}, DT)
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	band := pixel(pixels, w, project(r, camera, {0, 0, 0}))
	above := pixel(pixels, w, project(r, camera, {0, 0.6, 0}))
	testing.expectf(t, band[0] > above[0] + 60, "the ribbon %v must cover its path, unlike what is above it %v", band, above)
	expect_clean(t, f.device)
}

// Two heads leave a trail each, one ribbon of the trail emitter per head:
// two bands, nothing between them, and points that die along a trail before
// those behind them leave no gap.
@(test)
trails_of_two_heads_lay_two_bands_and_close_over_their_dead :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 192, 128, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	camera := gpu.Camera{position = {0, 0, 4}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	heads := test_emitter(1, {-2.5, 0.6, 0})
	heads.info.lifetime, heads.info.velocity, heads.info.size, heads.info.intensity = {5, 5}, {{3, 0, 0}, {3, 0, 0}}, {0.01, 0.01}, 0
	heads.info.trigger, heads.info.sub_count, heads.event_target = .Trail, 1, 2
	trail := test_emitter(2, {0, 0, 0})
	trail.capacity = 256
	trail.info.render, trail.info.soft, trail.info.size = .Ribbon, 0, {0.12, 0.12}
	// Some points of a trail die long before the older ones behind them.
	trail.info.lifetime = {0.4, 3}
	DT :: f32(1.0 / 60)
	for i in 0 ..< 48 {
		// One head at y 0.6, the next frame one at y -0.6, both leaving along +x.
		heads.spawns = {}
		if i < 2 {
			heads.transform = trs({-2.5, 0.6 if i == 0 else -0.6, 0}, {1, 1, 1})
			heads.spawns = test_burst(1, u32(i))
		}
		heads.previous = heads.transform
		testing.expect(t, frame_emitters(f, &f.sync, {heads, trail}, DT))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	for x in ([]f32{-2, -1.5, -1, -0.5}) {
		upper := pixel(pixels, w, project(r, camera, {x, 0.6, 0}))
		lower := pixel(pixels, w, project(r, camera, {x, -0.6, 0}))
		between := pixel(pixels, w, project(r, camera, {x, 0, 0}))
		testing.expectf(t, upper[0] > between[0] + 60 && lower[0] > between[0] + 60, "at x %v each trail %v %v must cover its path, and nothing between them %v", x, upper, lower, between)
	}
	expect_clean(t, f.device)
}

// The points of a quarter circle, every 45 degrees from -45 to 135, one a
// frame: the middle segments have neighbours at both ends.
@(private = "file")
quarter_circle :: proc(t: ^testing.T, f: ^Gpu_Fixture, trail: ^Emitter_Desc, camera: gpu.Camera, radius: f32) {
	for i in 0 ..< 5 {
		angle := math.to_radians(f32(-45 + 45 * i))
		trail.transform = trs({radius * math.cos(angle), radius * math.sin(angle), 0}, {1, 1, 1})
		trail.previous = trail.transform
		trail.spawns = test_burst(1, u32(i))
		testing.expect(t, frame_emitters(f, &f.sync, {trail^}, 1.0 / 60))
		testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera, time = f32(i) / 60}), f.renderer.error)
	}
	trail.spawns = {}
}

// A ribbon through points of a quarter circle follows the circle between
// them, where straight pieces would cut inside it.
@(test)
a_ribbon_follows_the_curve_through_its_points :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 256, 256, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	camera := gpu.Camera{position = {0.75, 0.75, 3.5}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	RADIUS :: f32(1.5)
	trail := test_emitter(1, {0, 0, 0})
	trail.info.render, trail.info.soft, trail.info.size, trail.info.lifetime = .Ribbon, 0, {0.06, 0.06}, {10, 10}
	quarter_circle(t, f, &trail, camera, RADIUS)
	for i in 0 ..< 3 {
		frame_emitters(f, &f.sync, {trail}, 1.0 / 60)
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(5 + i) / 60}), r.error)
	}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	for degrees in ([]f32{22.5, 67.5}) {
		angle := math.to_radians(degrees)
		on := pixel(pixels, w, project(r, camera, {RADIUS * math.cos(angle), RADIUS * math.sin(angle), 0}))
		// Where a straight piece between its points passes, inside the circle.
		chord := pixel(pixels, w, project(r, camera, {RADIUS * math.cos(f32(math.PI / 8)) * math.cos(angle), RADIUS * math.cos(f32(math.PI / 8)) * math.sin(angle), 0}))
		testing.expectf(t, on[0] > chord[0] + 60, "the ribbon %v must lie on the circle at %v degrees, not on the chord between its points %v", on, degrees, chord)
	}
	expect_clean(t, f.device)
}

// Each segment of a ribbon takes the pieces its own turn asks for (those at
// the ends, which turn less, fewer), rising at once and coming down one a
// frame where the curve asks for fewer.
@(test)
ribbon_pieces_follow_each_segment_rise_at_once_and_come_down_a_frame_at_a_time :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 64, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	near := gpu.Camera{position = {0, 0, 3.5}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 2000, exposure = gpu.UNIT_EXPOSURE}
	far := near
	far.position.z = 1000
	trail := test_emitter(1, {0, 0, 0})
	trail.info.render, trail.info.lifetime = .Ribbon, {30, 30}
	quarter_circle(t, f, &trail, near, 1.5)
	pieces :: proc(t: ^testing.T, f: ^Gpu_Fixture, trail: Emitter_Desc, camera: gpu.Camera) -> (most, instances: u32) {
		read := test_frame_read(t, f, {trail}, 1.0 / 60, camera, 0, {pool_buffer(&f.sync.pool, .Particles), pool_buffer(&f.sync.pool, .State)})
		if read[0] == nil || read[1] == nil {return}
		slot := pool_slot_find(&f.sync.pool, 1)
		range := f.sync.pool.slots[slot]
		for p in mem.slice_data_cast([]Gpu_Particle, read[0])[range.offset:][:range.capacity] {
			if p.lifetime > 0 {most = max(most, (p.flags >> RIBBON_PIECES_SHIFT) & 15)}
		}
		return most, mem.slice_data_cast([]Gpu_State, read[1])[slot].draw[1]
	}
	most, instances := pieces(t, f, trail, near)
	testing.expectf(t, most > 1 && instances > 4 && instances < 4 * most, "a curve seen from near is cut in pieces, each segment its own: at most %d, %d quads", most, instances)
	for k in 1 ..< min(most, 3) {
		got, _ := pieces(t, f, trail, far)
		testing.expectf(t, got == most - k, "seen from far, a frame comes down one piece: %d, not %d", got, most - k)
	}
	again, _ := pieces(t, f, trail, near)
	testing.expect_value(t, again, most)
	expect_clean(t, f.device)
}

// The newest point of a trail is where its head is in the frame, however fast it goes.
@(test)
a_trail_reaches_its_head :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 64, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	camera := gpu.Camera{position = {0, 0, 6}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	heads := test_emitter(1, {-3, 0, 0})
	heads.info.lifetime, heads.info.velocity = {5, 5}, {{30, 0, 0}, {30, 0, 0}}
	heads.info.trigger, heads.info.sub_count, heads.event_target = .Trail, 1, 2
	trail := test_emitter(2, {0, 0, 0})
	trail.capacity = 256
	trail.info.render, trail.info.lifetime = .Ribbon, {1, 1}
	for i in 0 ..< 7 {
		heads.spawns = test_burst(1) if i == 0 else {}
		testing.expect(t, frame_emitters(f, &f.sync, {heads, trail}, 1.0 / 60))
		testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera, time = f32(i) / 60}), f.renderer.error)
	}
	heads.spawns = {}
	read := test_frame_read(t, f, {heads, trail}, 1.0 / 60, camera, 0, {pool_buffer(&f.sync.pool, .Particles), {}})
	if read[0] == nil {return}
	particles := mem.slice_data_cast([]Gpu_Particle, read[0])
	head_range := f.sync.pool.slots[pool_slot_find(&f.sync.pool, 1)]
	trail_range := f.sync.pool.slots[pool_slot_find(&f.sync.pool, 2)]
	head: [3]f32
	for p in particles[head_range.offset:][:head_range.capacity] {if p.lifetime > 0 {head = p.position}}
	newest, youngest := [3]f32{}, f32(max(f32))
	for p in particles[trail_range.offset:][:trail_range.capacity] {
		if p.lifetime > 0 && p.age < youngest {newest, youngest = p.position, p.age}
	}
	testing.expectf(t, linalg.length(newest - head) < 0.05, "the newest point %v of the trail is at its head %v", newest, head)
	expect_clean(t, f.device)
}

@(test)
ribbon_lists_sort_by_ribbon_then_age :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 64, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	camera := gpu.Camera{position = {0, 0, 6}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	PER :: 600
	ribbons := test_emitter(1, {0, 0, 0})
	ribbons.capacity = 3 * PER
	ribbons.info.render, ribbons.info.lifetime = .Ribbon, {30, 30}
	program := erender.program_find(&f.assets, "Two_Ribbons", .Vfx)
	if !testing.expect(t, program != nil, "testdata has the Vfx program Two_Ribbons") {return}
	ribbons.program = {id = program.id, parameters = transmute([16][4]f32)erender.program_defaults(program), attributes = u32(program.attributes)}
	base.text_set(ribbons.info.program[:], program.name)
	for i in 0 ..< 3 {
		// A burst: the ages of a frame are alike, and the slot orders them.
		ribbons.spawns = test_burst(PER, u32(i) * PER)
		testing.expect(t, frame_emitters(f, &f.sync, {ribbons}, 1.0 / 60))
		testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera, time = f32(i) / 60}), f.renderer.error)
	}
	ribbons.spawns = {}
	read := test_frame_read(t, f, {ribbons}, 1.0 / 60, camera, 0, {pool_buffer(&f.sync.pool, .Particles), pool_buffer(&f.sync.pool, .Lists)})
	if read[0] == nil || read[1] == nil {return}
	particles := mem.slice_data_cast([]Gpu_Particle, read[0])
	lists := mem.slice_data_cast([]u32, read[1])
	slot := &f.sync.pool.slots[pool_slot_find(&f.sync.pool, 1)]
	drawn := lists[f.sync.pool.capacity + slot.offset:][:3 * PER]
	boundaries := 0
	for k in 1 ..< len(drawn) {
		a, b := particles[drawn[k - 1]], particles[drawn[k]]
		ra, rb := a.flags >> RIBBON_SHIFT, b.flags >> RIBBON_SHIFT
		boundaries += 1 if ra != rb else 0
		if !testing.expectf(t, ra < rb || ra == rb && (a.age < b.age || a.age == b.age && drawn[k - 1] < drawn[k]), "in order at %d: (%d, %v) then (%d, %v)", k, ra, a.age, rb, b.age) {break}
	}
	testing.expect_value(t, boundaries, 1)
	expect_clean(t, f.device)
}

// Mesh particles pick among the meshes of their effect by weight, once, and
// each mesh draws a run of the list of those that show it.
@(test)
mesh_particles_pick_their_meshes_by_weight :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 64, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	camera := gpu.Camera{position = {0, 0, 4}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	sphere := host.assets_shape(&f.assets, .Sphere)
	if !testing.expect(t, sphere != nil) {return}
	COUNT :: 800
	pieces := test_emitter(1, {0, 0, 0})
	pieces.capacity = COUNT
	pieces.info.render, pieces.info.lifetime, pieces.info.size = .Mesh, {30, 30}, {0.3, 0.3}
	pieces.info.shape, pieces.info.shape_size = .Box, {1, 1, 1}
	mesh_choices(&pieces, f.app.renderer, {f.cube, sphere.handle}, {3, 1})
	pieces.spawns = test_burst(COUNT)
	testing.expect(t, frame_emitters(f, &f.sync, {pieces}, 1.0 / 60))
	testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera}), f.renderer.error)
	pieces.spawns = {}
	picked :: proc(t: ^testing.T, f: ^Gpu_Fixture, pieces: Emitter_Desc, camera: gpu.Camera) -> (counts: [effect.PARTICLE_MESHES]u32, draws: [effect.PARTICLE_MESHES]u32) {
		read := test_frame_read(t, f, {pieces}, 1.0 / 60, camera, 0, {pool_buffer(&f.sync.pool, .Particles), pool_buffer(&f.sync.pool, .Events)})
		if read[0] == nil || read[1] == nil {return}
		slot := f.sync.pool.slots[pool_slot_find(&f.sync.pool, 1)]
		for p in mem.slice_data_cast([]Gpu_Particle, read[0])[slot.offset:][:slot.capacity] {
			if p.lifetime > 0 {counts[(p.flags >> MESH_CHOICE_SHIFT) & (effect.PARTICLE_MESHES - 1)] += 1}
		}
		for c in 0 ..< effect.PARTICLE_MESHES {
			at := int(mesh_draw(u32(pool_slot_find(&f.sync.pool, 1)), u32(c)))
			draws[c] = mem.slice_data_cast([]u32, read[1][at:][:16])[1]
		}
		return
	}
	first, draws := picked(t, f, pieces, camera)
	testing.expectf(t, first[0] + first[1] == COUNT && first[0] > 540 && first[0] < 660, "a weight of 3 to 1: %v", first)
	testing.expectf(t, draws == first, "each mesh draws those that show it: %v of %v", draws, first)
	again, _ := picked(t, f, pieces, camera)
	testing.expect_value(t, again, first)
	expect_clean(t, f.device)
}

// A long box along -Z of its mesh, which a particle that faces its velocity
// lays along where it goes.
@(test)
mesh_particles_face_their_velocity :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 128, 128, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{direction = {0.2, 0.4, 1}, color = {1, 1, 1}, illuminance = 4 * math.PI, enabled = true},{sky = {0.02, 0.02, 0.02}})
	// A box 0.1 across and 1 long, along z.
	corners := [8][3]f32{{-0.05, -0.05, -0.5}, {0.05, -0.05, -0.5}, {0.05, 0.05, -0.5}, {-0.05, 0.05, -0.5}, {-0.05, -0.05, 0.5}, {0.05, -0.05, 0.5}, {0.05, 0.05, 0.5}, {-0.05, 0.05, 0.5}}
	faces := [6][4]u32{{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {2, 3, 7, 6}, {1, 2, 6, 5}, {0, 4, 7, 3}}
	vertices := make([dynamic]gpu.Mesh_Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	for face in faces {
		a, b, c := corners[face[0]], corners[face[1]], corners[face[2]]
		normal := linalg.normalize(linalg.cross(b - a, c - a))
		first := u32(len(vertices))
		for k in face {append(&vertices, gpu.Mesh_Vertex{position = corners[k], normal = normal, color = {1, 1, 1}, tangent = {1, 0, 0, 1}})}
		append(&indices, first, first + 1, first + 2, first, first + 2, first + 3)
	}
	stick, added := gpu.mesh_add(r, vertices[:], indices[:])
	if !testing.expect(t, added) {return}
	camera := gpu.Camera{position = {0, 0, 3}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	for _ in 0 ..< 3 {testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)}
	sticks := test_emitter(1, {0, 0, 0})
	sticks.info.render, sticks.info.lifetime, sticks.info.size, sticks.info.lit = .Mesh, {30, 30}, {1, 1}, true
	// It leaves along +x until drag stops it: at rest it keeps where it went.
	sticks.info.velocity, sticks.info.facing, sticks.info.drag = {{1, 0, 0}, {1, 0, 0}}, .Velocity, 40
	if !testing.expect(t, mesh_choices(&sticks, f.app.renderer, {stick}, {1})) {return}
	for i in 0 ..< 40 {
		sticks.spawns = test_burst(1) if i == 0 else {}
		testing.expect(t, frame_emitters(f, &f.sync, {sticks}, 1.0 / 60))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) / 60}), r.error)
	}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	sky := pixel(pixels, w, project(r, camera, {0, 0.8, 0}))
	read := test_frame_read(t, f, {sticks}, 1.0 / 60, camera, 1, {pool_buffer(&f.sync.pool, .Particles), {}})
	if read[0] == nil {return}
	at: [3]f32
	for p in mem.slice_data_cast([]Gpu_Particle, read[0])[:sticks.capacity] {if p.lifetime > 0 {at = p.position}}
	for x in ([]f32{-0.35, 0.35}) {
		along := pixel(pixels, w, project(r, camera, at + {x, 0, 0}))
		testing.expectf(t, along[0] > sky[0] + 30, "the stick lies along where it went, also at rest: at x %v %v, the sky %v", x, along, sky)
	}
	above := pixel(pixels, w, project(r, camera, at + {0, 0.35, 0}))
	testing.expectf(t, abs(above[0] - sky[0]) < 10, "and not across it: %v, the sky %v", above, sky)
	expect_clean(t, f.device)
}

@(test)
mesh_particles_of_a_blending_material_cover_by_their_alpha :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 128, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	red := gpu.DEFAULT_MATERIAL
	red.base_color, red.alpha_mode = {1, 0.05, 0.05}, .Blend
	gpu.materials_set(r, {red})
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, 0, -2}, {12, 12, 0.2}), tint = {0.1, 0.1, 0.1}}},true)
	camera := gpu.Camera{position = {0, 0, 5}, forward = {0, 0, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	// Two cubes of the material: one with full alpha, one whose curve takes its alpha to zero.
	shown := test_emitter(1, {-1.2, 0, 0})
	shown.info.render, shown.material, shown.blended, shown.info.blend = .Mesh, 1, true, .Alpha
	mesh_choices(&shown, f.app.renderer, {f.cube}, {1})
	shown.info.lifetime, shown.info.size, shown.info.soft, shown.info.emission_mode, shown.info.intensity = {10, 10}, {1, 1}, 0, .Relative, 1
	faded := shown
	faded.id, faded.transform, faded.previous = 2, trs({1.2, 0, 0}, {1, 1, 1}), trs({1.2, 0, 0}, {1, 1, 1})
	faded.info.colors = {{1, 1, 1, 0}, {1, 1, 1, 0}}
	DT :: f32(1.0 / 60)
	for i in 0 ..< 8 {
		shown.spawns = test_burst(1) if i == 0 else {}
		faded.spawns = shown.spawns
		testing.expect(t, frame_emitters(f, &f.sync, {shown, faded}, DT))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, f.sync.pool.meshes, false)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	cover := pixel(pixels, w, project(r, camera, {-1.2, 0, 0.5}))
	clear := pixel(pixels, w, project(r, camera, {1.2, 0, 0.5}))
	wall := pixel(pixels, w, project(r, camera, {0, 1.5, 0}))
	testing.expectf(t, cover[0] > wall[0] + 80 && cover[0] > cover[1] + 60, "the cube of full alpha %v must show its red over the wall %v", cover, wall)
	testing.expectf(t, abs(clear[0] - wall[0]) < 12 && abs(clear[1] - wall[1]) < 12, "the cube of no alpha %v must leave the wall %v as it is", clear, wall)
	expect_clean(t, f.device)
}

@(test)
particle_lists_given_between_frames_add_up :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	emitter := test_emitter(9, {0, 0, 0})
	emitter.info.lifetime = {5, 5}
	for i in 0 ..< 3 {
		emitter.spawns = test_burst(10, u32(i) * 10)
		testing.expect(t, frame_emitters(f, &f.sync, {emitter}, 1.0 / 60))
	}
	emitter.spawns = {}
	// Frames without another list simulate what there is.
	for _ in 0 ..< 4 {
		particles_frame(&f.sync, &f.app)
		testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(30))
	expect_clean(t, f.device)
}

@(test)
particle_pool_keeps_its_size_when_the_device_refuses_another :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	emitter := test_emitter(4, {0, 0, 0})
	emitter.info.lifetime = {5, 5}
	emitter.spawns = test_burst(10)
	// A world whose first capacity the device refuses has no pool, and says so.
	testing.expect(t, !frame_emitters(f, &f.sync, {emitter}, 1.0 / 60, max(u32)))
	testing.expect(t, f.sync.pool.slots == nil)
	for _ in 0 ..< 4 {
		testing.expect(t, frame_emitters(f, &f.sync, {emitter}, 1.0 / 60, 8192))
		emitter.spawns = {}
		testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(10))
	// Asked again, the refused capacity leaves the pool and its particles as they were.
	testing.expect(t, frame_emitters(f, &f.sync, {emitter}, 1.0 / 60, max(u32)))
	testing.expect_value(t, f.sync.pool.capacity, u32(8192))
	testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(10))
	testing.expect(t, frame_emitters(f, &f.sync, {emitter}, 1.0 / 60, 4096))
	testing.expect_value(t, f.sync.pool.capacity, u32(4096))
	expect_clean(t, f.device)
}

// Each event starts its particles once, though the lists come two by two between frames.
@(test)
particle_events_start_once_when_lists_come_between_frames :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	flash := test_emitter(1, {0, 0, 0})
	flash.info.lifetime = {0.02, 0.02}
	flash.info.trigger, flash.event_target, flash.info.sub_count = .Death, 2, 3
	flash.spawns = test_burst(8)
	sparks := test_emitter(2, {0, 0, 0})
	sparks.info.lifetime = {5, 5}
	testing.expect(t, frame_emitters(f, &f.sync, {flash, sparks}, 1.0 / 60))
	testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	flash.spawns = {}
	for _ in 0 ..< 8 {
		for _ in 0 ..< 2 {testing.expect(t, frame_emitters(f, &f.sync, {flash, sparks}, 1.0 / 120))}
		testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(24))
	expect_clean(t, f.device)
}

// A burst starts at one instant: its particles die together. Births spread
// over time die one after another, and those older than the frame (a
// prewarm) start as far into their life as they got.
@(test)
particle_births_start_at_their_instant :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	DT :: f32(1.0 / 60)
	burst := test_emitter(1, {0, 0, 0})
	burst.info.lifetime = {0.1, 0.1}
	burst.spawns = test_burst(20)
	spread := test_emitter(2, {1, 0, 0})
	spread.info.lifetime = {0.4, 0.4}
	// Ages 0.375, 0.35 ... 0 at the end of the first frame: fifteen of them before it.
	spread.spawns[0] = {count = 16, per = 1, age = 0.375, spacing = 0.025}
	testing.expect(t, frame_emitters(f, &f.sync, {burst, spread}, DT))
	testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	burst.spawns = {}
	spread.spawns = {}
	// The particles alive after frames more: paused, the stats of the frames
	// that follow (two behind) count them as they were.
	alive_after :: proc(t: ^testing.T, f: ^Gpu_Fixture, camera: gpu.Camera, emitters: []Emitter_Desc, frames: int) -> u32 {
		r := &f.renderer
		for _ in 0 ..< frames {
			testing.expect(t, frame_emitters(f, &f.sync, emitters, DT))
			testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
		}
		for &e in emitters {e.paused = true}
		for _ in 0 ..< 3 {
			testing.expect(t, frame_emitters(f, &f.sync, emitters, DT))
			testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
		}
		for &e in emitters {e.paused = false}
		rhi.device_wait_idle(f.device)
		return particles_alive(f)
	}
	emitters := [2]Emitter_Desc{burst, spread}
	// Four frames on: the burst, 0.067 s old, all of it; the spread ones from 0.375 + 0.067 s, all but two.
	testing.expect_value(t, alive_after(t, f, camera, emitters[:], 4), u32(20 + 14))
	// Ten: the burst, 0.167 s old, gone at once; six spread ones gone.
	testing.expect_value(t, alive_after(t, f, camera, emitters[:], 6), u32(10))
	expect_clean(t, f.device)
}

// A long frame is simulated in steps: births and deaths inside it keep
// their times.
@(test)
particle_long_frames_take_several_steps :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	emitter := test_emitter(1, {0, 0, 0})
	emitter.info.lifetime = {0.115, 0.115}
	// Twenty-five births 0.01 s apart over a frame of 0.25 s: those born in its last 0.115 s live.
	emitter.spawns[0] = {count = 25, per = 1, age = 0.24, spacing = 0.01}
	testing.expect(t, frame_emitters(f, &f.sync, {emitter}, 0.25))
	testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	testing.expect_value(t, f.sync.pool.steps, u32(8))
	emitter.spawns = {}
	for _ in 0 ..< 2 {
		testing.expect(t, frame_emitters(f, &f.sync, {emitter}, 0))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(12))
	expect_clean(t, f.device)
}

// Another generation of an emitter starts it empty; a paused one keeps its
// particles as they are.
@(test)
particle_generations_restart_and_pauses_hold :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	DT :: f32(1.0 / 60)
	held := test_emitter(1, {0, 0, 0})
	held.info.lifetime = {0.1, 0.1}
	held.spawns = test_burst(10)
	again := test_emitter(2, {1, 0, 0})
	again.info.lifetime = {5, 5}
	again.spawns = test_burst(7)
	testing.expect(t, frame_emitters(f, &f.sync, {held, again}, DT))
	testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	held.spawns = {}
	again.spawns = {}
	held.paused = true
	again.generation = 1
	for _ in 0 ..< 20 {
		testing.expect(t, frame_emitters(f, &f.sync, {held, again}, DT))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(10))
	expect_clean(t, f.device)
}

// Each world keeps its particles while another one is drawn, and loses them
// when it goes.
@(test)
particle_worlds_keep_their_own_pools :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	DT :: f32(1.0 / 60)
	edit := test_emitter(5, {0, 0, 0})
	edit.info.lifetime = {5, 5}
	edit.spawns = test_burst(11)
	play := test_emitter(5, {0, 0, 0}) // the same id, in another world
	play.info.lifetime = {5, 5}
	play.spawns = test_burst(4)
	other: Particle_Sync
	defer particle_sync_free(&other)
	edit_world, play_world := core.World_Id{index = 1}, core.World_Id{index = 2}
	f.sync.world, other.world = erender.world_key(edit_world), erender.world_key(play_world)
	draw :: proc(t: ^testing.T, f: ^Gpu_Fixture, sync: ^Particle_Sync, emitter: Emitter_Desc, camera: gpu.Camera) {
		gpu.scene_world(&f.renderer, sync.world)
		testing.expect(t, frame_emitters(f, sync, {emitter}, DT))
		testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera}), f.renderer.error)
	}
	draw(t, f, &f.sync, edit, camera)
	draw(t, f, &other, play, camera)
	edit.spawns = {}
	play.spawns = {}
	for _ in 0 ..< 3 {draw(t, f, &other, play, camera)}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(4))
	for _ in 0 ..< 3 {draw(t, f, &f.sync, edit, camera)}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(11))
	testing.expect(t, erender.buffer_release(f.app.renderer, edit_world, "vfx particles"))
	testing.expect(t, !erender.buffer_release(f.app.renderer, edit_world, "vfx particles"))
	pool_release(f.app.renderer, edit_world, &f.sync.pool)
	pool_free(&f.sync.pool)
	for _ in 0 ..< 3 {draw(t, f, &f.sync, edit, camera)}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(0))
	expect_clean(t, f.device)
}

// The Vfx program Orbit of the plugin keeps the particles it starts on their circle, where
// the gravity of their effect would take them down.
@(test)
particle_programs_move_and_keep_their_particles :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -1.6, 0}, {12, 0.2, 12}), tint = {0.1, 0.1, 0.1}}},true)
	camera := gpu.Camera{position = {0, 3, 3}, forward = {0, -3, -3}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	program := erender.program_find(&f.assets, "Orbit", .Vfx)
	testing.expect(t, program != nil, "the plugin has the Vfx program Orbit")
	if program == nil {return}
	testing.expect(t, program.attributes > 0 && program.attributes <= erender.PARTICLE_ATTRIBUTE_BYTES)
	ring := test_emitter(1, {0, 0, 0})
	ring.capacity, ring.info.lifetime, ring.info.size = 256, {5, 5}, {0.15, 0.15}
	ring.info.shape, ring.info.shape_size, ring.info.shell = .Circle, {1, 1, 1}, 1
	ring.info.acceleration = {0, -9.8, 0}
	// Its speed is a value of the instance, as a game gives it; a name the program does not declare is refused.
	base.text_set(ring.info.program[:], "Orbit")
	override: Particle_Override
	testing.expect_value(t, value_set(&override, "parameters.heat", f32(1)), Error.None)
	testing.expect(t, particle_program_check(&f.assets, &ring.info, nil, &override, &ring.program) != "")
	value_remove(&override, "parameters.heat")
	testing.expect_value(t, value_set(&override, "parameters.speed", f32(3)), Error.None)
	testing.expect_value(t, particle_program_check(&f.assets, &ring.info, nil, &override, &ring.program), "")
	speed := erender.program_parameter(program, "speed")
	testing.expect(t, speed != nil && ring.program.parameters[speed.offset / 16][(speed.offset % 16) / 4] == 3)
	DT :: f32(1.0 / 60)
	for i in 0 ..< 40 {
		ring.spawns = test_burst(200) if i == 0 else {}
		testing.expect(t, frame_emitters(f, &f.sync, {ring}, DT))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(200))
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if ok {
		on := pixel(pixels, w, project(r, camera, {1, 0, 0}))
		below := pixel(pixels, w, project(r, camera, {1, -1.2, 0}))
		testing.expectf(t, on[0] > below[0] + 60, "the ring %v stays where gravity would have left it %v", on, below)
		delete(pixels)
	}
	expect_clean(t, f.device)
}


// A Surface shape starts its particles on the triangles of its surface,
// wherever the emitter is.
@(test)
particle_surface_shape_starts_particles_on_its_mesh :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -1, 0}, {12, 0.2, 12}), tint = {0.05, 0.05, 0.05}}},true)
	camera := gpu.Camera{position = {0, 1, 5}, forward = {0, -0.5, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	shell := test_emitter(1, {-2.5, 2, 0})
	shell.capacity, shell.info.lifetime, shell.info.size = 512, {5, 5}, {0.12, 0.12}
	shell.info.shape = .Surface
	box := trs({1.2, 0.5, 0}, {0.8, 0.8, 0.8})
	shell.resources = test_resources(&f.sync, {kind = .Surface, mesh = f.cube, triangles = f.cube_vertices / 3, transform = box, previous = box})
	DT :: f32(1.0 / 60)
	for i in 0 ..< 8 {
		shell.spawns = test_burst(400) if i == 0 else {}
		testing.expect(t, frame_emitters(f, &f.sync, {shell}, DT))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(400))
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if ok {
		on := pixel(pixels, w, project(r, camera, {1.2, 0.9, 0.4}))
		emitter := pixel(pixels, w, project(r, camera, {-2.5, 2, 0}))
		testing.expectf(t, on[0] > emitter[0] + 60, "the box %v glows with its particles, the emitter %v does not", on, emitter)
		delete(pixels)
	}
	expect_clean(t, f.device)
}

// A program keeps its particles on the triangles of a surface it reads as the
// surface moves (testdata/stick.slang).
@(test)
particle_programs_follow_a_surface_that_moves :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -1, 0}, {12, 0.2, 12}), tint = {0.05, 0.05, 0.05}}},true)
	camera := gpu.Camera{position = {0, 1, 5}, forward = {0, -0.5, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	program := erender.program_find(&f.assets, "Stick", .Vfx)
	if !testing.expect(t, program != nil && len(program.resources) == 1 && program.resources[0].kind == .Surface, "testdata has the Vfx program Stick, which reads a surface") {return}
	sticky := test_emitter(1, {0, 3, 0})
	sticky.capacity, sticky.info.lifetime, sticky.info.size = 512, {5, 5}, {0.12, 0.12}
	sticky.program = {id = program.id, parameters = transmute([16][4]f32)erender.program_defaults(program), attributes = u32(program.attributes)}
	base.text_set(sticky.info.program[:], program.name)
	DT :: f32(1.0 / 60)
	place :: proc(x: f32) -> matrix[4, 4]f32 {return trs({x, 0.5, 0}, {0.6, 0.6, 0.6})}
	for i in 0 ..< 40 {
		x := -1.5 + f32(i) * 3.0 / 39
		clear(&f.sync.resources)
		sticky.resources = test_resources(&f.sync, {}, {kind = .Surface, mesh = f.cube, triangles = f.cube_vertices / 3, transform = place(x), previous = place(max(x - 3.0 / 39, -1.5))})
		sticky.spawns = test_burst(300) if i == 0 else {}
		testing.expect(t, frame_emitters(f, &f.sync, {sticky}, DT))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(300))
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if ok {
		now := pixel(pixels, w, project(r, camera, {1.5, 0.5, 0.31}))
		before := pixel(pixels, w, project(r, camera, {-1.5, 0.5, 0.31}))
		testing.expectf(t, now[0] > before[0] + 60, "the particles %v went with the surface, away from where it started %v", now, before)
		delete(pixels)
	}
	expect_clean(t, f.device)
}

// An emitter of a channel starts particles of its effect where each birth a
// game gives the channel is, as many as it asks for.
@(test)
particle_channel_births_start_where_the_game_says :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -1, 0}, {12, 0.2, 12}), tint = {0.05, 0.05, 0.05}}},true)
	camera := gpu.Camera{position = {0, 1, 5}, forward = {0, -0.5, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	impacts := test_emitter(1, {0, 3, 0})
	impacts.capacity, impacts.info.lifetime, impacts.info.size = 512, {5, 5}, {0.15, 0.15}
	impacts.info.shape, impacts.info.shape_size = .Sphere, {0.1, 0.1, 0.1}
	DT :: f32(1.0 / 60)
	for i in 0 ..< 8 {
		clear(&f.sync.births)
		if i == 0 {
			append(&f.sync.births, Gpu_Birth{position = {-1.5, 0.5, 0}, size = 1, color = {1, 1, 1, 1}, count = 40, number = 0})
			append(&f.sync.births, Gpu_Birth{position = {1.5, 0.5, 0}, size = 1, color = {1, 1, 1, 1}, count = 60, number = 1})
		}
		impacts.births = {0, u32(len(f.sync.births))}
		testing.expect(t, frame_emitters(f, &f.sync, {impacts}, DT))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(100))
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if ok {
		left := pixel(pixels, w, project(r, camera, {-1.5, 0.5, 0}))
		right := pixel(pixels, w, project(r, camera, {1.5, 0.5, 0}))
		emitter := pixel(pixels, w, project(r, camera, {0, 3, 0}))
		testing.expectf(t, left[0] > emitter[0] + 60 && right[0] > emitter[0] + 60, "the births %v %v glow, the emitter %v does not", left, right, emitter)
		delete(pixels)
	}
	expect_clean(t, f.device)
}

// An effect whose report names death or collision tells the game, through the
// reports channel, of each particle that dies or hits the scene, once, frames
// later, with the entity of its emitter and, of a hit, the normal of the floor.
@(test)
particle_reports_tell_the_game_of_deaths_and_hits :: proc(t: ^testing.T) {
	for dt in ([]f32{1.0 / 30, 1.0 / 144}) {
		f := new(Gpu_Fixture)
		defer free(f)
		if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
		defer gpu_fixture_destroy(f)
		r := &f.renderer
		gpu.scene_update(r, 0, {{object_id = 1, mesh = f.cube, transform = trs({0, -0.6, 0}, {12, 0.2, 12}), tint = {0.05, 0.05, 0.05}}}, true)
		camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
		brief := test_emitter(1, {0, 0, 0})
		brief.info.lifetime, brief.info.report, brief.owner = {0.05, 0.05}, .Death, core.Entity(77)
		// Thrown over the floor, each dies at its first hit: one report each.
		falls := test_emitter(2, {-1.5, 0, 0})
		falls.info.lifetime, falls.info.velocity, falls.info.acceleration = {5, 5}, {{2, 0, 0}, {2, 0, 0}}, {0, -9.8, 0}
		falls.info.collision, falls.info.collision_life, falls.info.report, falls.owner = .World, 1, .Collision, core.Entity(78)
		reports: Particle_Reports
		defer particle_reports_free(&reports)
		heard: [2]int
		for i in 0 ..< int(0.75 / dt) {
			brief.spawns = test_burst(9) if i == 0 else {}
			falls.spawns = test_burst(4) if i == 0 else {}
			testing.expect(t, frame_emitters(f, &f.sync, {brief, falls}, dt))
			testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
			data_read(nil, &reports, &f.sync, f.app.renderer, core.World_Id{index = 1}, nil)
			for report in reports.reports {
				switch report.entity {
				case 77:
					testing.expect(t, report.kind == .Death)
					heard[0] += 1
				case 78:
					testing.expectf(t, report.kind == .Collision && report.normal.y > 0.9 && report.position.y > -0.5 && report.position.y < 0, "a hit over the floor %v", report)
					heard[1] += 1
				case:
					testing.expectf(t, false, "a report of no emitter %v", report)
				}
			}
		}
		testing.expectf(t, heard == {9, 4}, "at steps of %v s: %v deaths and hits, not 9 and 4", dt, heard)
		testing.expect_value(t, reports.lost, u32(0))
		expect_clean(t, f.device)
	}
}

// The Bones shape starts its particles on the bones of a skinned mesh: those
// of its file in their bind pose, and those of its skin as the renderer poses
// it, each from the joint of its parent bone, past the bones the skin does not
// name, to its own. The Surface shape of the skin starts them on its
// triangles as it is posed.
@(test)
particle_bones_and_surface_shapes_start_particles_on_the_posed_skin :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	// A root, an arm and a hand; the skin names the arm and the hand.
	skeleton_id, mesh_id := base.Asset_Id{0x7669, 1}, base.Asset_Id{0x7669, 2}
	bones: [3]asset.Skeleton_Bone
	paths := [3]string{"root", "root/arm", "root/arm/hand"}
	for &bone, i in bones {
		path := paths[i]
		base.text_set(bone.name[:], path)
		base.text_set(bone.path[:], path)
		bone.target = base.name_hash(path)
		bone.parent = i32(i) - 1
		bone.rotation = 1
		bone.scale = {1, 1, 1}
	}
	arm, hand := [3]f32{1.2, 0, 0}, [3]f32{1.2, 1.5, 0}
	joints := [2]asset.Rig_Joint{{node = 1, inverse_bind = moved(-arm)}, {node = 2, inverse_bind = moved(-hand)}}
	vertices := [3]asset.Vertex{{position = arm}, {position = hand}, {position = arm + {0, 0, 0.1}}}
	indices := [3]u32{0, 1, 2}
	// The hand moves its vertex; the arm, the others.
	skin: [3]asset.Skin_Vertex
	for &v in skin {v.weights[0] = 255}
	skin[1].joints[0] = 1
	rig_geometry: asset.Mesh_Geometry
	testing.expect(t, asset.mesh_build({vertices = vertices[:], skin = skin[:]}, indices[:], nil, &rig_geometry, context.temp_allocator))
	types := &f.assets.types
	testing.expect_value(t, asset.skeleton_save(fmt.tprintf("%s/rig.skeleton", f.folder), types, {id = skeleton_id, bones = bones[:]}), asset.Error.None)
	testing.expect_value(t, asset.mesh_save(fmt.tprintf("%s/rig.mesh", f.folder), types, {id = mesh_id, geometry = rig_geometry, joints = joints[:], skeleton = skeleton_id}), asset.Error.None)
	testing.expect(t, host.assets_scan(&f.assets))
	rig := bone_rig(&f.sync.rigs, f.app.assets, mesh_id)
	if !testing.expect(t, rig != nil && len(rig.joints) == 2) {return}
	testing.expect(t, rig.joints[0].parent == -1 && rig.joints[1].parent == 0, "the arm starts no bone; the hand's goes from the arm")
	testing.expect(t, linalg.length(rig.joints[1].bind - hand) < 1e-4)
	// In the bind pose, from the file.
	identity: matrix[4, 4]f32 = 1
	bind := bones_of(&f.sync, f.app.renderer, rig, 0, identity, false)
	testing.expect(t, bind.kind == .Bones && bind.count == 1)
	if bind.count == 1 {
		segment := f.sync.segments[bind.first]
		testing.expect(t, linalg.length(segment.start - arm) < 1e-4 && linalg.length(segment.end - hand) < 1e-4 && abs(segment.length - 1.5) < 1e-4)
	}
	// Posed: the skin one metre up.
	cube := host.assets_shape(&f.assets, .Cube)
	influences := make([]erender.Skin_Influence, cube.vertex_count, context.temp_allocator)
	for &influence in influences {influence.weights[0] = 255}
	posed, made := erender.skin_create(f.app.renderer, f.cube, influences, 2)
	if !testing.expect(t, made, r.error) {return}
	up := moved({0, 1, 0})
	testing.expect(t, erender.skin_update(f.app.renderer, posed, {up, up}, reset_motion = true))
	clear(&f.sync.segments)
	bone := bones_of(&f.sync, f.app.renderer, rig, posed, identity, true)
	testing.expect(t, bone.kind == .Bones && bone.count == 1)
	if bone.count == 1 {
		segment := f.sync.segments[bone.first]
		testing.expect(t, linalg.length(segment.start - (arm + {0, 1, 0})) < 1e-4 && linalg.length(segment.end - (hand + {0, 1, 0})) < 1e-4)
	}
	bone.previous = bone.transform
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -1, 0}, {12, 0.2, 12}), tint = {0.05, 0.05, 0.05}}},true)
	camera := gpu.Camera{position = {0, 1, 5}, forward = {0, -0.5, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	along := test_emitter(1, {-2.5, 2, 0})
	along.capacity, along.info.lifetime, along.info.size = 512, {5, 5}, {0.12, 0.12}
	along.info.shape, along.info.shape_size = .Bones, {0, 0, 0}
	along.resources = test_resources(&f.sync, bone)
	onto := test_emitter(2, {2.5, 2, 0})
	onto.capacity, onto.info.lifetime, onto.info.size = 512, {5, 5}, {0.12, 0.12}
	onto.info.shape = .Surface
	onto.resources = test_resources(&f.sync, {kind = .Surface, mesh = posed, triangles = f.cube_vertices / 3, transform = identity, previous = identity})
	DT :: f32(1.0 / 60)
	for i in 0 ..< 8 {
		along.spawns = test_burst(400) if i == 0 else {}
		onto.spawns = along.spawns
		testing.expect(t, frame_emitters(f, &f.sync, {along, onto}, DT))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(800))
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if ok {
		on := pixel(pixels, w, project(r, camera, {1.2, 1.75, 0}))
		rest := pixel(pixels, w, project(r, camera, {1.2, 0.2, 0}))
		emitter := pixel(pixels, w, project(r, camera, {-2.5, 2, 0}))
		testing.expectf(t, on[0] > emitter[0] + 60 && on[0] > rest[0] + 60, "the posed bone %v glows with its particles, its bind pose %v and the emitter %v do not", on, rest, emitter)
		skin := pixel(pixels, w, project(r, camera, {0, 1, 0.5}))
		unposed := pixel(pixels, w, project(r, camera, {0, -0.2, 0.5}))
		beside := pixel(pixels, w, project(r, camera, {2.5, 2, 0}))
		testing.expectf(t, skin[0] > beside[0] + 60 && skin[0] > unposed[0] + 60, "the posed skin %v glows with its particles, its bind pose %v and the emitter %v do not", skin, unposed, beside)
		delete(pixels)
	}
	expect_clean(t, f.device)
}

@(private = "file")
moved :: proc(offset: [3]f32) -> matrix[4, 4]f32 {
	m: matrix[4, 4]f32 = 1
	m[0, 3], m[1, 3], m[2, 3] = offset.x, offset.y, offset.z
	return m
}

// What a test reads back of the buffers of a world at the end of a frame.
@(private = "file")
Test_Read :: struct {
	sync:    ^Particle_Sync,
	buffers: [2]erender.Buffer_Desc,
}

@(private = "file")
TEST_READ_NAMES :: [2]string{"vfx test read 0", "vfx test read 1"}

@(private = "file")
test_read_pass :: proc(pass: ^erender.Pass, user: rawptr) {
	read := cast(^Test_Read)user
	if pass.world != read.sync.world {return}
	names := TEST_READ_NAMES
	for b, i in read.buffers {
		if b.size > 0 {erender.pass_readback(pass, b, 0, {names[i], b.size})}
	}
}

// The frame of the emitters, with the buffers read back at its end: what
// they held, once the frames in flight are done.
@(private = "file")
test_frame_read :: proc(t: ^testing.T, f: ^Gpu_Fixture, emitters: []Emitter_Desc, dt: f32, camera: gpu.Camera, time: f32, buffers: [2]erender.Buffer_Desc) -> (read: [2][]u8) {
	r := &f.renderer
	testing.expect(t, frame_emitters(f, &f.sync, emitters, dt))
	reader := Test_Read{sync = &f.sync, buffers = buffers}
	erender.frame_pass(f.app.renderer, .Simulate, test_read_pass, &reader)
	testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = time}), r.error)
	for i in 0 ..< rhi.MAX_FRAMES_IN_FLIGHT + 1 {
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = time}), r.error)
	}
	names := TEST_READ_NAMES
	for b, i in buffers {
		if b.size == 0 {continue}
		data, _, ok := gpu.readback(r, f.sync.world, names[i])
		if testing.expectf(t, ok && len(data) == int(b.size), "%s came back", names[i]) {read[i] = data}
	}
	return
}

// The needs of an effect whose program is name, its program, and its rows of
// resources and stages, as particles_sync gives them.
@(private = "file")
test_program :: proc(t: ^testing.T, f: ^Gpu_Fixture, desc: ^Emitter_Desc, name: string, resources: ..Resource_Desc) -> bool {
	base.text_set(desc.info.program[:], name)
	needs: Program_Needs
	if !testing.expectf(t, particle_program_check(&f.assets, &desc.info, nil, nil, &desc.program, &needs) == "", "testdata has the Vfx program %s", name) {return false}
	rows: [RESOURCE_ROWS]Resource_Desc
	copy(rows[1:], resources)
	desc.resources = test_resources(&f.sync, ..rows[:])
	problems: core.Problems
	desc.stages = emitter_stages(&f.sync, &needs, desc.resources, desc.id, core.Entity(desc.id), &problems)
	return testing.expect(t, desc.stages > 0, "its stages have rows")
}

// A grid of the world, as grids_sync makes it, drawn as a volume when one is given.
@(private = "file")
test_grid :: proc(f: ^Gpu_Fixture, name: string, cells: [3]u32, cell_size: f32, layers: u32, first: [3]i32, volume: Maybe(Particle_Volume) = nil) -> u32 {
	medium, drawn := volume.?
	append(&f.sync.grids.entries, Grid_Entry{entity = core.Entity(len(f.sync.grids.entries) + 100), name = base.name_hash(name), cells = cells, layers = layers, cell_size = cell_size, first = first, cleared = first, volume = medium, has_volume = drawn})
	f.sync.grids.layout = 0
	grids_place(&f.sync.grids, u64(len(f.sync.grids.entries)))
	return u32(len(f.sync.grids.entries) - 1)
}

// The floats of a layer of the cells of a grid in what the world buffer read back: the
// copy that holds what the last stage left.
@(private = "file")
test_grid_values :: proc(f: ^Gpu_Fixture, world: []u8, grid: u32) -> []f32 {
	entry := f.sync.grids.entries[grid]
	base := grids_base(&f.sync)
	parity := (cast(^u32)&world[base + grid * 4])^ & 1
	cells := grid_cells(entry.cells)
	values := make([]f32, cells, context.temp_allocator)
	for at in 0 ..< cells {
		address := base + entry.offset + ((parity * cells + at) * entry.layers) * 16
		values[at] = (cast(^f32)&world[address])^
	}
	return values
}

// Each iteration of a stage over a grid reads what the one before left:
// five of them add five to every cell a step.
@(test)
particle_grid_stages_iterate_over_what_the_one_before_left :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 64, 48, settings) {return}
	defer gpu_fixture_destroy(f)
	camera := gpu.Camera{position = {0, 1, 5}, forward = {0, -0.5, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	grid := test_grid(f, "counts", {4, 1, 3}, 0.5, 1, {-2, 0, -1})
	tally := test_emitter(1, {0, 0.5, 0})
	if !test_program(t, f, &tally, "Tally", Resource_Desc{kind = .Grid, first = grid}) {return}
	DT :: f32(1.0 / 60)
	FRAMES :: 6
	world: []u8
	for i in 0 ..< FRAMES {
		if i + 1 < FRAMES {
			testing.expect(t, frame_emitters(f, &f.sync, {tally}, DT))
			testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera, time = f32(i) * DT}), f.renderer.error)
			continue
		}
		world = test_frame_read(t, f, {tally}, DT, camera, f32(i) * DT, {world_buffer(&f.sync), {}})[0]
	}
	if world == nil {return}
	for value, at in test_grid_values(f, world, grid) {
		testing.expectf(t, value == 5 * FRAMES, "cell %d holds %v after %d steps of five iterations", at, value, FRAMES)
	}
	expect_clean(t, f.device)
}

// Particles splat into a grid, a stage over its cells keeps what they splat,
// and they sample it back where they are.
@(test)
particle_splats_go_into_a_grid_that_particles_sample :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 64, 48, settings) {return}
	defer gpu_fixture_destroy(f)
	camera := gpu.Camera{position = {0, 1, 5}, forward = {0, -0.5, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	// Cells of half a metre; the middle of cell (1, 0, 0) is at x 0.75.
	grid := test_grid(f, "heat", {4, 1, 1}, 0.5, 1, {-2, 0, 0})
	hot := test_emitter(1, {0.75, 0.25, 0.25})
	hot.capacity, hot.info.lifetime = 64, {5, 5}
	if !test_program(t, f, &hot, "Spread", Resource_Desc{kind = .Grid, first = grid}) {return}
	hot.program.parameters[0][0] = 1
	DT :: f32(1.0 / 60)
	FRAMES :: 4
	world: []u8
	for i in 0 ..< FRAMES {
		hot.spawns = test_burst(10) if i == 0 else {}
		if i + 1 < FRAMES {
			testing.expect(t, frame_emitters(f, &f.sync, {hot}, DT))
			testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera, time = f32(i) * DT}), f.renderer.error)
			continue
		}
		world = test_frame_read(t, f, {hot}, DT, camera, f32(i) * DT, {world_buffer(&f.sync), {}})[0]
	}
	if world == nil {return}
	values := test_grid_values(f, world, grid)
	// The cell of x 0.75 wraps to (0.75 / 0.5) mod 4 = 1.
	for value, at in values {
		want: f32 = 10 * FRAMES if at == 1 else 0
		testing.expectf(t, abs(value - want) < 1e-3, "cell %d holds %v, not %v", at, value, want)
	}
	expect_clean(t, f.device)
}

// A grid drawn as a volume: a ball of density that glows, over the scene.
@(test)
particle_volumes_draw_the_medium_of_a_grid :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -1, 0}, {12, 0.2, 12}), tint = {0.05, 0.05, 0.05}}},true)
	camera := gpu.Camera{position = {0, 1, 5}, forward = {0, -0.5, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	// Two metres of cells of an eighth around (0, 0.5, 0).
	smoke := test_grid(f, "smoke", {16, 16, 16}, 0.125, 1, {-8, -4, -8}, Particle_Volume{density = 6, albedo = {0.5, 0.5, 0.5}, emission = {4, 1.6, 0.4}})
	puff := test_emitter(1, {0, 0.5, 0})
	if !test_program(t, f, &puff, "Puff", Resource_Desc{kind = .Grid, first = smoke}) {return}
	puff.program.parameters[0] = {0.6, 1, 0, 0}
	DT :: f32(1.0 / 60)
	for i in 0 ..< 6 {
		testing.expect(t, frame_emitters(f, &f.sync, {puff}, DT))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if ok {
		ball := pixel(pixels, w, project(r, camera, {0, 0.5, 0}))
		empty := pixel(pixels, w, project(r, camera, {0.85, 1.35, 0}))
		testing.expectf(t, ball[0] > empty[0] + 60 && ball[0] > ball[2], "the ball %v glows orange, the region around it %v does not", ball, empty)
		delete(pixels)
	}
	expect_clean(t, f.device)
}

// A stage traces the scene: from outside a cube, the face it meets and how
// far; from inside, the back of the far face; past it, nothing.
@(test)
particle_stages_trace_the_scene :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 64, 48, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	// A cube from x 1 to 2, around the middles of the cells.
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({1.5, 0.25, 0.25}, {1, 1, 1})}},true)
	camera := gpu.Camera{position = {0, 1, 5}, forward = {0, -0.5, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	// Cells of half a metre from x -1 to 3, their middles at y and z 0.25.
	first := [3]i32{-2, 0, 0}
	seen := test_grid(f, "seen", {8, 1, 1}, 0.5, 1, first)
	probe := test_emitter(1, {0, 0.25, 0})
	if !test_program(t, f, &probe, "Probe", Resource_Desc{kind = .Grid, first = seen}) {return}
	probe.program.parameters[0][0] = 10
	DT :: f32(1.0 / 60)
	world: []u8
	for i in 0 ..< 3 {
		if i < 2 {
			testing.expect(t, frame_emitters(f, &f.sync, {probe}, DT))
			testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
			continue
		}
		world = test_frame_read(t, f, {probe}, DT, camera, f32(i) * DT, {world_buffer(&f.sync), {}})[0]
	}
	if world == nil {return}
	entry := f.sync.grids.entries[seen]
	base := grids_base(&f.sync)
	parity := (cast(^u32)&world[base + seen * 4])^ & 1
	phase := grid_phase(entry.first, entry.cells)
	// x of what each cell met (-1: nothing), whether from inside, the normal along x.
	Want :: struct {distance, inside, normal: f32}
	wants := [8]Want{{1.75, 0, -1}, {1.25, 0, -1}, {0.75, 0, -1}, {0.25, 0, -1}, {0.75, 1, -1}, {0.25, 1, -1}, {-1, 0, 0}, {-1, 0, 0}}
	for want, along in wants {
		at := (u32(along) + phase.x) % 8
		got := (cast(^[4]f32)&world[base + entry.offset + (parity * 8 + at) * 16])^
		testing.expectf(t, abs(got.x - want.distance) < 1e-3 && got.y == want.inside && abs(got.z - want.normal) < 1e-3, "the cell from x %v met %v, not %v", f32(first.x + i32(along)) * 0.5, got.xyz, want)
	}
	expect_clean(t, f.device)
}

// Particles with lights whose effect asks for shadows light the floor
// around them within their range and cast shadows: behind a cube the floor
// stays dark, as it is past the range.
@(test)
particle_lights_light_the_scene_and_cast_shadows :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 128, 96, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{})
	gpu.scene_update(r,0,{
		{object_id = 1, mesh = f.cube, transform = trs({0, -1, 0}, {12, 0.2, 12}), tint = {0.5, 0.5, 0.5}},
		{object_id = 2, mesh = f.cube, transform = trs({0.6, -0.3, 0}, {0.4, 0.4, 0.4}), tint = {0.5, 0.5, 0.5}},
	},true)
	camera := gpu.Camera{position = {0, 6, 0.01}, forward = {0, -6.9, -0.01}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	spark := test_emitter(1, {0, 0.3, 0})
	spark.info.lifetime, spark.info.size, spark.info.lights, spark.info.light_intensity, spark.info.light_range, spark.info.light_radius, spark.info.light_shadows = {10, 10}, {0.02, 0.02}, 4, 5, 2.5, 0.05, true
	spark.spawns = test_burst(4)
	DT :: f32(1.0 / 60)
	for i in 0 ..< 6 {
		testing.expect(t, frame_emitters(f, &f.sync, {spark}, DT))
		spark.spawns = {}
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if ok {
		near := pixel(pixels, w, project(r, camera, {-1.2, -0.9, 0}))
		shadow := pixel(pixels, w, project(r, camera, {1.2, -0.9, 0}))
		far := pixel(pixels, w, project(r, camera, {-2.4, -0.9, 0}))
		testing.expectf(t, near[1] > far[1] + 30, "the floor in range %v is lit, past it %v is not", near, far)
		testing.expectf(t, near[1] > shadow[1] + 30, "the floor in range %v is lit, behind the cube %v it is not", near, shadow)
		delete(pixels)
	}
	expect_clean(t, f.device)
}

// The room for more lights than the buffers of the scene hold grows them
// before the frame uploads the tree with it: no copy past their end, which
// left nodes of the tree unwritten and walks of it back at the root.
@(test)
particle_lights_grow_the_light_buffers_before_the_room_goes_up :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 64, 48, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -1, 0}, {12, 0.2, 12}), tint = {0.5, 0.5, 0.5}}},true)
	camera := gpu.Camera{position = {0, 6, 0.01}, forward = {0, -6.9, -0.01}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	spark := test_emitter(1, {0, 0.3, 0})
	spark.info.lifetime, spark.info.size, spark.info.lights, spark.info.light_intensity, spark.info.light_range, spark.info.light_radius = {10, 10}, {0.02, 0.02}, 40, 5, 2.5, 0.05
	spark.spawns = test_burst(40)
	for i in 0 ..< 3 {
		testing.expect(t, frame_emitters(f, &f.sync, {spark}, 1.0 / 60))
		spark.spawns = {}
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) / 60}), r.error)
	}
	rhi.device_wait_idle(f.device)
	expect_clean(t, f.device)
}

// Particles with lights whose effect asks for none of shadows light the
// floor in their range behind the cube too, with no ray, in the part of the
// room of their kind, while those of another emitter that ask for shadows
// fill the other part.
@(test)
particle_lights_without_shadows_light_through_what_stands_in_their_way :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 128, 96, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{})
	gpu.scene_update(r,0,{
		{object_id = 1, mesh = f.cube, transform = trs({0, -1, 0}, {12, 0.2, 12}), tint = {0.5, 0.5, 0.5}},
		{object_id = 2, mesh = f.cube, transform = trs({0.6, -0.3, 0}, {0.4, 0.4, 0.4}), tint = {0.5, 0.5, 0.5}},
	},true)
	camera := gpu.Camera{position = {0, 6, 0.01}, forward = {0, -6.9, -0.01}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	spark := test_emitter(1, {0, 0.3, 0})
	spark.info.lifetime, spark.info.size, spark.info.lights, spark.info.light_intensity, spark.info.light_range, spark.info.light_radius = {10, 10}, {0.02, 0.02}, 4, 5, 2.5, 0.05
	spark.spawns = test_burst(4)
	away := test_emitter(2, {40, 0.3, 0})
	away.info.lifetime, away.info.size, away.info.lights, away.info.light_intensity, away.info.light_range, away.info.light_radius, away.info.light_shadows = {10, 10}, {0.02, 0.02}, 2, 5, 2.5, 0.05, true
	away.spawns = test_burst(2)
	DT :: f32(1.0 / 60)
	for i in 0 ..< 6 {
		testing.expect(t, frame_emitters(f, &f.sync, {spark, away}, DT))
		spark.spawns, away.spawns = {}, {}
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	testing.expect_value(t, r.scene.light_region, gpu.Light_Region{2, 4})
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if ok {
		near := pixel(pixels, w, project(r, camera, {-1.2, -0.9, 0}))
		behind := pixel(pixels, w, project(r, camera, {1.2, -0.9, 0}))
		far := pixel(pixels, w, project(r, camera, {-2.4, -0.9, 0}))
		testing.expectf(t, near[1] > far[1] + 30, "the floor in range %v is lit, past it %v is not", near, far)
		testing.expectf(t, behind[1] > far[1] + 30, "behind the cube %v the floor in range is lit too, past it %v is not", behind, far)
		delete(pixels)
	}
	expect_clean(t, f.device)
}

// A layer of a grid with a texture of the world reaches the materials: the
// floor over the region of the grid glows by what its cells count, and past
// the region it does not.
@(test)
particle_world_textures_reach_the_materials :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	program := gpu.program_find(r, "Count_Ground", .Surface)
	if !testing.expect(t, program != nil, "testdata has the Surface program Count_Ground") {return}
	material := gpu.DEFAULT_MATERIAL
	material.program_id = program.id
	material.custom_params[0] = {0.01, 0, 0, 0}
	gpu.materials_set(r, {material})
	gpu.scene_set_environment(r,{},{})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), material = 1, tint = {1, 1, 1}}},true)
	camera := gpu.Camera{position = {0, 6, 0.01}, forward = {0, -6, -0.01}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	// Another grid with a texture before it: their texels lie one after the other.
	other := test_grid(f, "other", {4, 1, 4}, 0.25, 1, {10, 0, 10})
	f.sync.grids.entries[other].has_texture, f.sync.grids.entries[other].texture_name = true, world_texture_name("other")
	// Four by three cells of half a metre from x -1 and z -0.5.
	grid := test_grid(f, "counts", {4, 1, 3}, 0.5, 1, {-2, 0, -1})
	entry := &f.sync.grids.entries[grid]
	entry.has_texture, entry.texture_name = true, world_texture_name("counts")
	f.sync.world_textures[0], f.sync.world_textures[1], f.sync.world_texture_count = f.sync.grids.entries[other].name, entry.name, 2
	f.sync.grids.layout = 0
	grids_place(&f.sync.grids, 3)
	grids_place(&f.sync.grids, 2)
	tally := test_emitter(1, {0, 0.5, 0})
	tally.info.size = {0.01, 0.01}
	if !test_program(t, f, &tally, "Tally", Resource_Desc{kind = .Grid, first = grid}) {return}
	DT :: f32(1.0 / 60)
	for i in 0 ..< 6 {
		testing.expect(t, frame_emitters(f, &f.sync, {tally}, DT))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect(t, f.sync.world_shown.names[1] == world_texture_name("counts"), "the views show the texture of counts after that of other")
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if ok {
		inside := pixel(pixels, w, project(r, camera, {0.25, 0, 0.25}))
		outside := pixel(pixels, w, project(r, camera, {2.5, 0, 0}))
		testing.expectf(t, inside[0] > outside[0] + 20, "the floor over the grid %v glows, past it %v does not", inside, outside)
		delete(pixels)
	}
	expect_clean(t, f.device)
}

// Particles that collide with the traced scene land on the floor they fall
// to: with all the friction they stop where they land, and without any they
// slide on along it.
@(test)
particle_collisions_land_on_the_scene_and_slide_by_their_friction :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -0.6, 0}, {12, 0.2, 12}), tint = {0.05, 0.05, 0.05}}},true)
	camera := gpu.Camera{position = {0, 0.6, 4}, forward = {0, -0.3, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	// Thrown at 2 m/s along x from half a metre over the floor: they land 0.64 m on.
	stops := test_emitter(1, {-1.5, 0, 0})
	slides := test_emitter(2, {-1.5, 0, -1})
	for e in ([]^Emitter_Desc{&stops, &slides}) {
		e.info.lifetime, e.info.size, e.info.velocity, e.info.acceleration = {5, 5}, {0.3, 0.3}, {{2, 0, 0}, {2, 0, 0}}, {0, -9.8, 0}
		e.info.collision, e.info.bounce = .World, 0
	}
	stops.info.friction, slides.info.friction = 1, 0
	DT :: f32(1.0 / 60)
	for i in 0 ..< 90 {
		stops.spawns = test_burst(4) if i == 0 else {}
		slides.spawns = stops.spawns
		testing.expect(t, frame_emitters(f, &f.sync, {stops, slides}, DT))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(8))
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if ok {
		floor := pixel(pixels, w, project(r, camera, {0, -0.35, 0.5}))
		landed := pixel(pixels, w, project(r, camera, {-0.86, -0.35, 0}))
		slid := pixel(pixels, w, project(r, camera, {1.5, -0.35, -1}))
		left := pixel(pixels, w, project(r, camera, {-0.86, -0.35, -1}))
		testing.expectf(t, landed[0] > floor[0] + 60, "those that stop %v rest where they landed, over the floor %v", landed, floor)
		testing.expectf(t, slid[0] > floor[0] + 60, "those that slide %v went on along the floor", slid)
		testing.expectf(t, left[0] < floor[0] + 30, "those that slide are no longer where they landed %v", left)
		delete(pixels)
	}
	expect_clean(t, f.device)
}

// Particles dropped on a floor hit it while they bounce and then rest on it:
// slower than the rest speed a surface keeps them without a hit, an event or
// lost life. The hits they report and the particles alive do not depend on
// the steps the frames take.
@(test)
particles_that_land_hit_once_per_bounce_and_rest_at_any_frame_rate :: proc(t: ^testing.T) {
	for dt in ([]f32{1.0 / 30, 1.0 / 144}) {
		f := new(Gpu_Fixture)
		defer free(f)
		if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
		defer gpu_fixture_destroy(f)
		r := &f.renderer
		gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -0.6, 0}, {12, 0.2, 12})}},true)
		camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
		// From 0.45 m over the floor they land at 3 m/s, bounce once at 0.9 m/s and then rest.
		drop := test_emitter(1, {0, 0, 0})
		drop.capacity, drop.info.lifetime, drop.info.size, drop.info.acceleration = 128, {5, 5}, {0.1, 0.1}, {0, -9.8, 0}
		drop.info.collision, drop.info.bounce, drop.info.collision_life, drop.info.report, drop.owner = .World, 0.3, 0.1, .Collision, core.Entity(77)
		reports: Particle_Reports
		defer particle_reports_free(&reports)
		hits := 0
		for i in 0 ..< int(1.5 / dt) {
			drop.spawns = test_burst(100) if i == 0 else {}
			testing.expect(t, frame_emitters(f, &f.sync, {drop}, dt))
			testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
			data_read(nil, &reports, &f.sync, f.app.renderer, core.World_Id{index = 1}, nil)
			for report in reports.reports {hits += 1 if report.kind == .Collision else 0}
		}
		testing.expectf(t, hits == 200, "at steps of %v s the 100 particles report a hit per bounce, 200, not %d", dt, hits)
		testing.expectf(t, particles_alive(f) == 100, "at steps of %v s all 100 are alive, not %d", dt, particles_alive(f))
		testing.expect_value(t, reports.lost, u32(0))
		expect_clean(t, f.device)
	}
}

// A sprite runs the Surface program of its material with the data, the
// random value and the radius the program of its particle gives; a particle
// that gives none leaves the material to its own.
@(test)
particle_sprites_hand_their_data_to_the_program_of_their_material :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	surface := gpu.program_find(r, "Particle_Data", .Surface)
	if !testing.expect(t, surface != nil, "testdata has the Surface program Particle_Data") {return}
	material := gpu.DEFAULT_MATERIAL
	material.program_id = surface.id
	gpu.materials_set(r, {material})
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -1, 0}, {12, 0.2, 12}), tint = {0.05, 0.05, 0.05}}},true)
	camera := gpu.Camera{position = {0, 0, 4}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	given := test_emitter(1, {-1, 0, 0})
	plain := test_emitter(2, {1, 0, 0})
	given.material, given.info.lifetime = 1, {5, 5}
	plain.material, plain.info.lifetime = 1, {5, 5}
	program := erender.program_find(&f.assets, "Hand_Over", .Vfx)
	if !testing.expect(t, program != nil, "testdata has the Vfx program Hand_Over") {return}
	given.program = {id = program.id, parameters = transmute([16][4]f32)erender.program_defaults(program), attributes = u32(program.attributes)}
	base.text_set(given.info.program[:], program.name)
	DT :: f32(1.0 / 60)
	for i in 0 ..< 6 {
		given.spawns = test_burst(1) if i == 0 else {}
		plain.spawns = given.spawns
		testing.expect(t, frame_emitters(f, &f.sync, {given, plain}, DT))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if ok {
		blue := pixel(pixels, w, project(r, camera, {-1, 0, 0}))
		green := pixel(pixels, w, project(r, camera, {1, 0, 0}))
		testing.expectf(t, blue[2] > blue[1] + 60 && blue[2] > blue[0] + 60, "the sprite whose particle gives blue, its random value and its size %v shows it", blue)
		testing.expectf(t, green[1] > green[2] + 60 && green[1] > green[0] + 60, "the sprite whose particle gives nothing %v shows the green of its material", green)
		delete(pixels)
	}
	expect_clean(t, f.device)
}

// A grid that names a .grid of its cells starts from it, wherever its region
// wraps, and counts on from there.
@(test)
particle_grids_start_from_their_state :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 64, 48, settings) {return}
	defer gpu_fixture_destroy(f)
	camera := gpu.Camera{position = {0, 1, 5}, forward = {0, -0.5, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	DT :: f32(1.0 / 60)
	baked :: f32(20)
	info := gridfile.Grid_Info{cells = {4, 1, 3}, layers = 1, cell_size = 0.5}
	cells: [12 * 4]f32
	for c in 0 ..< 12 {cells[c * 4] = baked}
	// The state as a file, and a grid that starts from it.
	id := base.Asset_Id{0x6772696400000001, 1}
	bytes, error := gridfile.grid_bytes(&f.assets.types, {id = id, info = info, cells = cells[:]}, context.temp_allocator)
	if !testing.expect_value(t, error, asset.Error.None) {return}
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/state.grid", f.folder), bytes) == nil)
	testing.expect_value(t, asset.registry_scan(&f.assets.registry), asset.Error.None)
	started := test_grid(f, "started", {4, 1, 3}, 0.5, 1, {1, 0, 2})
	f.sync.grids.entries[started].cached = id
	tally_started := test_emitter(2, {0, 0.5, 0})
	if !test_program(t, f, &tally_started, "Tally", Resource_Desc{kind = .Grid, first = started}) {return}
	FRAMES :: 3
	world: []u8
	for i in 0 ..< FRAMES {
		if i + 1 < FRAMES {
			testing.expect(t, frame_emitters(f, &f.sync, {tally_started}, DT))
			testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera, time = f32(i) * DT}), f.renderer.error)
			continue
		}
		world = test_frame_read(t, f, {tally_started}, DT, camera, f32(i) * DT, {world_buffer(&f.sync), {}})[0]
	}
	if world == nil {return}
	testing.expect(t, f.sync.grids.entries[started].loaded == id, "the grid took the state")
	for value, at in test_grid_values(f, world, started) {
		testing.expectf(t, value > baked && value <= baked + 5 * FRAMES, "cell %d starts from the state and counts on: %v", at, value)
	}
	expect_clean(t, f.device)
}

// A Surface program sees the color of the vertices of its mesh as data and
// the object of its point, the same drawn and met by the rays of a mirror
// (testdata/surface_probe.slang).
@(test)
programs_see_the_vertex_colors_and_the_object_of_their_point_drawn_and_reflected :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa, settings.reflections = false, .Detailed
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	program := gpu.program_find(r, "Surface_Probe", .Surface)
	if !testing.expect(t, program != nil, "testdata has the Surface program Surface_Probe") {return}
	probe, mirror := gpu.DEFAULT_MATERIAL, gpu.DEFAULT_MATERIAL
	probe.program_id = program.id
	probe.custom_params[0] = {1, 0, 0, 0}
	mirror.base_color, mirror.metallic, mirror.roughness = {0.9, 0.9, 0.9}, 1, 0.05
	gpu.materials_set(r, {probe, mirror})
	red := [3]f32{1, 0, 0}
	quad := []gpu.Mesh_Vertex {
		{position = {-0.5, 0, -0.5}, normal = {0, 1, 0}, color = red, tangent = {1, 0, 0, 1}},
		{position = {0.5, 0, -0.5}, normal = {0, 1, 0}, color = red, tangent = {1, 0, 0, 1}},
		{position = {0.5, 0, 0.5}, normal = {0, 1, 0}, color = red, tangent = {1, 0, 0, 1}},
		{position = {-0.5, 0, 0.5}, normal = {0, 1, 0}, color = red, tangent = {1, 0, 0, 1}},
	}
	mesh, made := gpu.mesh_add(r, quad, []u32{0, 2, 1, 0, 3, 2})
	if !testing.expect(t, made, r.error) {return}
	// The probe is 3 by 3 m over the mirror, its object twice as tall as its mesh.
	gpu.scene_set_environment(r,{},{sky = {0, 0, 0}})
	gpu.scene_update(r,0,{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), material = 2, tint = {1, 1, 1}},
		{object_id = 2, mesh = mesh, transform = trs({0, 2, -2}, {3, 2, 3}), material = 1, tint = {1, 1, 1}},
	},true)
	seen :: proc(t: ^testing.T, f: ^Gpu_Fixture, camera: gpu.Camera, points: [2][3]f32) -> (out: [2][3]f32) {
		r := &f.renderer
		for _ in 0 ..< 3 {testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)}
		rhi.device_wait_idle(f.device)
		pixels, w, _, ok := gpu.renderer_capture(r)
		if !testing.expect(t, ok, r.error) {return}
		defer delete(pixels)
		for p, i in points {out[i] = pixel(pixels, w, project(r, camera, p))}
		return
	}
	above := gpu.Camera{position = {0, 6, -1.99}, forward = {0, -4, -0.01}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	drawn := seen(t, f, above, {{-0.8, 2, -2}, {0.8, 2, -2}})
	// The floor at x mirrors the probe at 2x: the camera is as high over it as the probe.
	floor := gpu.Camera{position = {0, 2, 2}, forward = {0, -2, -2}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	reflected := seen(t, f, floor, {{-0.4, 0, 0}, {0.4, 0, 0}})
	for side, i in ([2][2][3]f32{drawn, reflected}) {
		what := i == 0 ? "drawn" : "reflected"
		left, right := side[0], side[1]
		testing.expectf(t, left.r > left.b + 40 && right.r > 40, "%s, the probe glows with the red of its vertices: %v %v", what, left, right)
		testing.expectf(t, left.g > 20 && left.g < left.r, "%s, the scale of its object along y: %v", what, left)
		testing.expectf(t, right.b > left.b + 40, "%s, its +x side of the object: %v against %v", what, right, left)
	}
	expect_clean(t, f.device)
}

// Particles go behind the media of the view: a fog box between the eye and a
// sprite takes what the sprite sends by what the box lets through, and a
// sprite in front of the box sends as much as without it.
@(test)
particle_sprites_go_behind_the_fog_of_the_view :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 192, 128, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, 0, -20}, {40, 40, 0.2}), tint = {0.02, 0.02, 0.02}}},true)
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	camera := gpu.Camera{position = {0, 0, 0}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	BEHIND :: [3]f32{-0.8, 0, -9}
	FRONT :: [3]f32{0.8, 0, -3}
	behind := test_emitter(1, BEHIND)
	front := test_emitter(2, FRONT)
	behind.info.lifetime, front.info.lifetime = {5, 5}, {5, 5}
	behind.info.intensity, front.info.intensity = 0.5, 0.5
	// Two metres of a medium that stops 1.5 of each metre and scatters nothing: it lets through e^-3.
	medium := fog.Medium{box = {position = {0, 0, -6}, rotation = 1, scale = {6, 6, 2}}, density = 1.5}
	state := fog.Fog_Gpu{}
	settings_fog := fog.Fog_Settings{hidden = .Every_Frame}
	media: fog.Fog_Media
	defer delete(media.queue.items)
	volumes: core.Table(fog.Fog_Volume)
	places: core.Table(evolume.Volume)
	worlds: core.Table(core.World_Transform)
	hidden: core.Table(erender.Hidden)
	parents: core.Table(core.Parent)
	DT :: f32(1.0 / 60)
	seconds: f32
	seen: [2][2][3]f32 // without and with the fog: the sprite behind it and the one in front
	for &frame, foggy in seen {
		for i in 0 ..< 10 {
			behind.spawns = test_burst(1) if foggy == 0 && i == 0 else {}
			front.spawns = behind.spawns
			testing.expect(t, frame_emitters(f, &f.sync, {behind, front}, DT))
			if foggy == 1 {fog.medium_add(&media, medium)}
			fog.fog_render(&state, core.read(&volumes), core.read(&places), &media, core.read(&worlds), core.read(&hidden), core.read(&parents), {}, {}, core.ref(&settings_fog), &f.app, nil)
			seconds += DT
			testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = seconds}), r.error)
		}
		rhi.device_wait_idle(f.device)
		pixels, w, _, ok := gpu.renderer_capture(r)
		if !testing.expect(t, ok, r.error) {return}
		frame = {pixel(pixels, w, project(r, camera, BEHIND)), pixel(pixels, w, project(r, camera, FRONT))}
		delete(pixels)
	}
	open, misty := seen[0], seen[1]
	testing.expectf(t, open[0].r > 40 && open[1].r > 40, "without fog both sprites show: %v", open)
	testing.expectf(t, misty[0].r < open[0].r * 0.3, "the sprite behind the fog %v is dimmed by it, from %v", misty[0], open[0])
	testing.expectf(t, abs(misty[1].r - open[1].r) <= 0.1 * open[1].r + 2, "the sprite in front of the fog %v shows as without it %v", misty[1], open[1])
	expect_clean(t, f.device)
}

// What a test reads back of the ranges of one emitter (emitter_ranges), in
// the Simulate stage after the particles.
@(private = "file")
Range_Read :: struct {
	sync:  ^Particle_Sync,
	id:    u64,
	count: u32,
}

@(private = "file")
RANGE_NAMES :: [3]string{"vfx test particles", "vfx test attributes", "vfx test state"}

@(private = "file")
range_read_pass :: proc(pass: ^erender.Pass, user: rawptr) {
	r := cast(^Range_Read)user
	if pass.world != r.sync.world {return}
	ranges, ok := emitter_ranges(&r.sync.pool, r.id, r.count)
	if !ok {return}
	names := RANGE_NAMES
	for range, i in ([3]Pool_Range{ranges.particles, ranges.attributes, ranges.state}) {
		if range.size > 0 {erender.pass_readback(pass, range.buffer, range.offset, {names[i], range.size})}
	}
}

// Frames of the emitters of a world with the ranges of one read back, and
// what came back of them: its particles, their Attributes and its counters.
@(private = "file")
range_frames :: proc(t: ^testing.T, f: ^Gpu_Fixture, emitters: []Emitter_Desc, id: u64, count: u32) -> (particles: []Gpu_Particle, words: []u32, state: Gpu_State) {
	camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	read := Range_Read{sync = &f.sync, id = id, count = count}
	list := make([]Emitter_Desc, len(emitters), context.temp_allocator)
	copy(list, emitters)
	for i in 0 ..< 3 + rhi.MAX_FRAMES_IN_FLIGHT {
		testing.expect(t, frame_emitters(f, &f.sync, list, 1.0 / 60))
		for &e in list {e.spawns = {}}
		erender.frame_pass(f.app.renderer, .Simulate, range_read_pass, &read)
		testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera, time = f32(i) / 60}), f.renderer.error)
	}
	names := RANGE_NAMES
	if data, _, ok := gpu.readback(&f.renderer, f.sync.world, names[0]); ok {particles = ([^]Gpu_Particle)(raw_data(data))[:len(data) / size_of(Gpu_Particle)]}
	if data, _, ok := gpu.readback(&f.renderer, f.sync.world, names[1]); ok {words = ([^]u32)(raw_data(data))[:len(data) / 4]}
	if data, _, ok := gpu.readback(&f.renderer, f.sync.world, names[2]); ok && len(data) == size_of(Gpu_State) {state = (^Gpu_State)(raw_data(data))^}
	return
}

// Each pass of the particles marks the interval the profiler lists by its name.
@(test)
particle_passes_mark_the_intervals_the_profiler_lists :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	rhi.timestamps_want(f.device, true)
	defer rhi.timestamps_want(f.device, false)
	camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	emitter := test_emitter(1, {0, 0, 0})
	emitter.info.lifetime = {5, 5}
	seen: map[string]int
	defer delete(seen)
	for i in 0 ..< 6 {
		emitter.spawns = test_burst(16) if i == 0 else {}
		// Long frames take several steps; each kind of pass still marks one interval.
		testing.expect(t, frame_emitters(f, &f.sync, {emitter}, 0.2))
		testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera, time = f32(i) * 0.2}), f.renderer.error)
		frame: map[string]int
		defer delete(frame)
		for timing in gpu.renderer_stats(&f.renderer).timings {
			if strings.has_prefix(timing.name, "particle") {frame[timing.name] += 1}
		}
		for name, count in frame {
			seen[strings.clone(name, context.temp_allocator)] = max(seen[name], count)
		}
	}
	for name in ([]string{"particle begin", "particle emit", "particle simulate", "particle steps", "particle finish", "particle lights", "particle sprites"}) {
		testing.expectf(t, seen[name] == 1, "the profiler lists %q once a frame: %v", name, seen)
	}
	expect_clean(t, f.device)
}

// The ranges of each emitter point at its rows and its counters: as many
// alive as its rows hold, and the bytes it holds of the pool.
@(test)
particle_ranges_point_at_the_rows_and_counters_of_each_emitter :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	a, b := test_emitter(1, {0, 0, 0}), test_emitter(2, {1, 0, 0})
	a.info.lifetime, b.info.lifetime = {5, 5}, {5, 5}
	b.capacity = 32
	a.spawns, b.spawns = test_burst(10), test_burst(7)
	for e in ([]Emitter_Desc{a, b}) {
		particles, _, state := range_frames(t, f, {a, b}, e.id, e.capacity)
		a.spawns, b.spawns = {}, {}
		testing.expect_value(t, len(particles), int(e.capacity))
		held: u32
		for p in particles {if p.lifetime > 0 {held += 1}}
		testing.expect_value(t, held, u32(10) if e.id == 1 else u32(7))
		testing.expect_value(t, state.alive, held)
		at := pool_slot_find(&f.sync.pool, e.id)
		testing.expect(t, at >= 0 && emitter_bytes(&f.sync.pool, at) >= u64(e.capacity) * size_of(Gpu_Particle))
	}
	_, missing := emitter_ranges(&f.sync.pool, 99, 1)
	testing.expect(t, !missing, "no ranges for an emitter the pool does not hold")
	expect_clean(t, f.device)
}

// The catalog names the Attributes of a program where its particles keep
// them: a program that writes NaN into heat and 1 into calm.
@(test)
particle_attributes_are_where_the_catalog_names_them :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	emitter := test_emitter(1, {0, 0, 0})
	emitter.info.lifetime = {5, 5}
	base.text_set(emitter.info.program[:], "Glitch")
	if !testing.expect_value(t, particle_program_check(&f.assets, &emitter.info, nil, nil, &emitter.program), "") {return}
	program := erender.program_find(&f.assets, "Glitch", .Vfx)
	if !testing.expect(t, program != nil && len(program.attribute_fields) == 2) {return}
	heat, calm := program.attribute_fields[0], program.attribute_fields[1]
	testing.expect(t, heat.name == "heat" && calm.name == "calm" && heat.kind == .Float && calm.offset == 4)
	emitter.spawns = test_burst(5)
	particles, words, _ := range_frames(t, f, {emitter}, emitter.id, emitter.capacity)
	ranges, _ := emitter_ranges(&f.sync.pool, emitter.id, emitter.capacity)
	stride := int(ranges.stride / 4)
	if !testing.expect(t, stride > 0 && len(words) == len(particles) * stride) {return}
	held := 0
	for p, slot in particles {
		if !(p.lifetime > 0) {continue}
		held += 1
		testing.expect(t, math.is_nan(transmute(f32)words[slot * stride + int(heat.offset / 4)]))
		testing.expect_value(t, transmute(f32)words[slot * stride + int(calm.offset / 4)], f32(1))
	}
	testing.expect_value(t, held, 5)
	expect_clean(t, f.device)
}
