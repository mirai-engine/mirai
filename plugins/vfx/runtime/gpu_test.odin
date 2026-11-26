package vfx

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
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
import mm "mirai:std/math"
import fog "plugins:fog/runtime"
import "plugins:vfx/runtime/effect"

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
	cube_primitives: u32, // of level 0 of the cube
	folder:     string,
}

@(private = "file")
gpu_fixture_init :: proc(t: ^testing.T, f: ^Gpu_Fixture, width, height: u32, settings: gpu.Settings) -> bool {
	root, _ := filepath.clean(ROOT, context.temp_allocator)
	// mirai test generates them: cook is not shipped, and the game compiles its test files.
	output := fmt.tprintf("%s/.mirai/test-shaders/vfx", root)
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
	f.cube_primitives, _ = erender.mesh_primitive_count(f.app.renderer, f.cube)
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

// The emitters of a world for the next frame, the whole list: each one is
// put in the pool and those it does not name leave it. False when one found
// no room.
@(private = "file")
frame_emitters :: proc(f: ^Gpu_Fixture, sync: ^Particle_Sync, emitters: []Emitter_Desc, dt: f32, capacity: u32 = CAPACITY) -> bool {
	pool := &sync.pool
	ok := pool_frame(pool, dt, capacity, erender.max_storage_range(&f.app), false, len(emitters) > 0)
	for &desc in emitters {ok = pool_put(pool, &desc) && ok}
	listed: for i := pool.order_count - 1; i >= 0; i -= 1 {
		id := pool.slots[pool.order[i]].id
		for desc in emitters {if desc.id == id {continue listed}}
		pool_remove(pool, id)
	}
	particles_frame(sync, &f.app)
	return ok
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
    spec:=new(Emitter_Info,context.temp_allocator)
    spec.info={
        shape=.Point,lifetime={0.5,0.5},size={0.6,0.6},colors={{1,1,1,1},{1,1,1,1}},
        render=.Billboard,blend=.Additive,intensity=4,flipbook={1,1},
        size_over_life=effect.PARTICLE_CURVE_ONE,color_over_life=GRADIENT_WHITE,
    }
    return {id=id,capacity=64,transform=trs(position,{1,1,1}),previous=trs(position,{1,1,1}),spec=spec}
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
	gpu.scene_light_update(r,0,{position = {1, 2, 1}, color = {1, 0.8, 0.6}, intensity = 8 * math.PI, range = 10, indirect = 1, scattering = 1})
	gpu.scene_set_environment(r,{direction = {0.3, 1, 0.2}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true, indirect = 1, scattering = 1},{sky = {0.2, 0.3, 0.5}})
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

// The GPU keeps the rows of the emitters of a world that did not change: a
// frame that changes nothing puts none in the pool and writes none, one that
// moves an emitter writes its row alone, and every emitter keeps its
// particles; frames that change nothing allocate nothing.
@(test)
particle_rows_go_to_the_gpu_only_when_their_emitter_changes :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	w := new(Emitters_World)
	defer free(w)
	if !test_world_init(t, w) {return}
	defer test_world_destroy(w)
	w.settings = PARTICLE_SETTINGS_DEFAULT
	r := &f.renderer
	gpu.scene_set_environment(r, {}, {sky = {0.2, 0.3, 0.5}})
	camera := gpu.Camera{position = {0, 1, 4}, forward = {0, -0.7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	emitters: [3]core.Entity
	for &e, i in emitters {
		e = core.create(&w.entities)
		place := mm.TRANSFORM_IDENTITY
		place.position = {f32(i) - 1, 0, 0}
		core.add(&w.emitters, e, Particle_Emitter{active = true, loop = true})
		core.add(&w.worlds, e, core.World_Transform{place, place})
		// A burst of 8 that the clock started; no tick starts more.
		births_add(clock_of(&w.clocks, e), 0, 8, 8, 0)
	}
	test_world_settle(w)
	problems: core.Problems
	tell :: proc(f: ^Gpu_Fixture, w: ^Emitters_World, problems: ^core.Problems) {
		drawn: erender.Render_Sync
		particles_sync(core.read(&w.emitters), core.read(&w.overrides), core.read(&w.worlds), core.read(&w.hidden), core.read(&w.parents), core.ref(&w.hierarchy), core.read(&w.bindings), nil, core.read(&w.meshes), core.ref(&drawn), core.read(&w.listeners), core.read(&w.grids), core.read(&w.volumes), core.read(&w.textures), core.ref(&w.clocks), core.ref(&w.settings), &f.sync, nil, {}, {index = 1}, {}, {dt = 1.0 / 60, alpha = 1}, {}, problems, &f.app, {}, {}, {}, {}, {})
	}
	for _ in 0 ..< 3 {
		tell(f, w, &problems)
		testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	}
	pool := &f.sync.pool
	tell(f, w, &problems)
	testing.expect(t, pool.pending == {} && pool.dirty == {}, "a frame that changes nothing tells the GPU nothing")
	testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	moved := core.edit(&w.worlds, emitters[1])
	moved.transform.position.y, moved.previous.position.y = 1, 1
	test_world_settle(w)
	tell(f, w, &problems)
	only: Slot_Bits
	bits_add(&only, pool_slot_find(pool, u64(emitters[1])))
	testing.expect(t, pool.pending == only && pool.dirty == only, "a frame that moves one emitter writes its row alone")
	for _ in 0 ..< 3 {
		testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
		tell(f, w, &problems)
	}
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	{
		context.allocator = mem.tracking_allocator(&tracker)
		for _ in 0 ..< 4 {
			testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
			tell(f, w, &problems)
		}
	}
	testing.expect_value(t, tracker.total_allocation_count, i64(0))
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(len(emitters) * 8))
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
	PER :: 900
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

@(test)
a_builtin_beam_arcs_between_its_endpoints :: proc(t:^testing.T) {
    f:=new(Gpu_Fixture)
    defer free(f)
    settings:=test_settings()
    settings.taa=false
    if !gpu_fixture_init(t,f,96,96,settings) {return}
    defer gpu_fixture_destroy(f)
    camera:=gpu.Camera{position={0,0,4},forward={0,0,-1},up={0,1,0},fov_y=55,
        near=0.05,far=100,exposure=gpu.UNIT_EXPOSURE}
    beam:=test_emitter(1,{-1,0,0})
    beam.info.render,beam.info.beam_end,beam.info.beam_arc=.Beam,{2,0,0},0.8
    beam.info.size,beam.info.lifetime={0.2,0.2},{5,5}
    beam.spawns=test_burst(1)
    for i in 0..<4 {
        testing.expect(t,frame_emitters(f,&f.sync,{beam},1.0/60))
        testing.expect(t,gpu.renderer_frame(&f.renderer,{camera=camera,time=f32(i)/60}),f.renderer.error)
        beam.spawns={}
    }
    pixels,w,_,ok:=gpu.renderer_capture(&f.renderer)
    if !testing.expect(t,ok) {return}
    defer delete(pixels)
    arc:=pixel(pixels,w,project(&f.renderer,camera,{0,0.8,0}))
    chord:=pixel(pixels,w,project(&f.renderer,camera,{}))
    testing.expectf(t,arc.r>chord.r+60,"arc %v and chord %v",arc,chord)
    expect_clean(t,f.device)
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
// A box 0.1 across and 1 long, along z.
@(private = "file")
stick_mesh :: proc(r: ^gpu.Renderer) -> (gpu.Mesh_Handle, bool) {
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
	return gpu.mesh_add(r, vertices[:], indices[:])
}

@(test)
mesh_particles_face_their_velocity :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 128, 128, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{direction = {0.2, 0.4, 1}, color = {1, 1, 1}, illuminance = 4 * math.PI, enabled = true, indirect = 1, scattering = 1},{sky = {0.02, 0.02, 0.02}})
	stick, added := stick_mesh(r)
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
	faded.spec=new(Emitter_Info,context.temp_allocator)
	faded.spec^=shown.spec^
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
	shell.resources = test_resources(&f.sync, {kind = .Surface, mesh = f.cube, triangles = f.cube_primitives, transform = box, previous = box})
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
		sticky.resources = test_resources(&f.sync, {}, {kind = .Surface, mesh = f.cube, triangles = f.cube_primitives, transform = place(x), previous = place(max(x - 3.0 / 39, -1.5))})
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

// The Surface shape of a skin starts its particles on its triangles as the
// renderer poses them, not where its file places them.
@(test)
particle_surface_shape_starts_particles_on_the_posed_skin :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	identity: matrix[4, 4]f32 = 1
	// Posed: the skin one metre up.
	cube := host.assets_shape(&f.assets, .Cube)
	influences := make([]erender.Skin_Influence, cube.vertex_count, context.temp_allocator)
	for &influence in influences {influence.weights[0] = 255}
	posed, made := erender.skin_create(f.app.renderer, f.cube, influences, 2)
	if !testing.expect(t, made, r.error) {return}
	up := moved({0, 1, 0})
	testing.expect(t, erender.skin_update(f.app.renderer, posed, {up, up}, reset_motion = true))
	gpu.scene_set_environment(r,{},{sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -1, 0}, {12, 0.2, 12}), tint = {0.05, 0.05, 0.05}}},true)
	camera := gpu.Camera{position = {0, 1, 5}, forward = {0, -0.5, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	onto := test_emitter(2, {2.5, 2, 0})
	onto.capacity, onto.info.lifetime, onto.info.size = 512, {5, 5}, {0.12, 0.12}
	onto.info.shape = .Surface
	onto.resources = test_resources(&f.sync, {kind = .Surface, mesh = posed, triangles = f.cube_primitives, transform = identity, previous = identity})
	DT :: f32(1.0 / 60)
	for i in 0 ..< 8 {
		onto.spawns = test_burst(400) if i == 0 else {}
		testing.expect(t, frame_emitters(f, &f.sync, {onto}, DT))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, particles_alive(f), u32(400))
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if ok {
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

@(test)
despawned_world_particles_drain_before_releasing_their_slot :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f, 64, 48, test_settings()) {return}
	defer gpu_fixture_destroy(f)
	pool := &f.sync.pool
	emitter := test_emitter(1, {0, 0, 0})
	emitter.info.lifetime = {0.4, 0.4}
	emitter.spawns = test_burst(1)
	camera := gpu.Camera{position = {0, 0, 4}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60}
	DT :: f32(0.05)
	testing.expect(t, frame_emitters(f, &f.sync, {emitter}, DT))
	testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera}), f.renderer.error)
	pool_orphan(pool, emitter.id)
	for i in 1 ..< 16 {
		testing.expect(t, pool_frame(pool, DT, CAPACITY, erender.max_storage_range(&f.app), false, false))
		testing.expect(t, particles_frame(&f.sync, &f.app))
		testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera, time = f32(i) * DT}), f.renderer.error)
		rhi.device_wait_idle(f.device)
		pool_drain(pool, f.app.renderer, {index = 1})
		if i == 5 {
			testing.expect(t, pool_slot_find(pool, emitter.id) >= 0)
			testing.expect_value(t, particles_alive(f), u32(1))
		}
	}
	testing.expect_value(t, pool_slot_find(pool, emitter.id), -1)
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

// A still volume lit by three lamps, with shadows and without: from the
// frame the lamps turn on, within a few frames each cell takes what each lamp
// gives it alone, added up (no lamp dropped, no light that leaks), and keeps
// it from frame to frame, with no light that comes and goes.
@(test)
particle_volumes_take_what_each_light_gives_and_hold_it :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 64, 48, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r, {}, {})
	camera := gpu.Camera{position = {0, 1, 5}, forward = {0, -0.5, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	// Two metres of cells of a quarter around the origin, all of them dense.
	smoke := test_grid(f, "smoke", {8, 8, 8}, 0.25, 1, {-4, -4, -4}, Particle_Volume{density = 2, albedo = {1, 1, 1}})
	puff := test_emitter(1, {0, 0, 0})
	if !test_program(t, f, &puff, "Puff", Resource_Desc{kind = .Grid, first = smoke}) {return}
	puff.program.parameters[0] = {10, 0, 0, 0}
	lamps := [3][3]f32{{1.6, 0.5, 0}, {-1.2, 1, 1.3}, {0.3, -1.5, -1.1}}
	DT :: f32(1.0 / 60)
	entry := f.sync.grids.entries[smoke]
	first := grids_base(&f.sync) + entry.light
	cells := int(grid_cells(entry.cells))
	// A read holds what the cells held in its first frame; the next one is
	// READ_FRAMES later.
	READ_FRAMES :: rhi.MAX_FRAMES_IN_FLIGHT + 2
	READS :: 10
	read :: proc(t: ^testing.T, f: ^Gpu_Fixture, puff: Emitter_Desc, camera: gpu.Camera, first: u32, cells: int) -> [][4]f32 {
		world := test_frame_read(t, f, {puff}, DT, camera, 0, {world_buffer(&f.sync), {}})[0]
		if world == nil {return nil}
		light := make([][4]f32, cells, context.temp_allocator)
		copy(mem.slice_to_bytes(light), world[first:][:cells * 16])
		return light
	}
	// The most a cell of a differs from b, against b.
	apart :: proc(a, b: [][4]f32) -> (worst: f32) {
		for cell, i in b {
			if cell.g < 1e-4 {continue}
			worst = max(worst, linalg.max(linalg.abs(a[i].rgb - cell.rgb) / cell.rgb))
		}
		return
	}
	for shadowless in ([2]bool{false, true}) {
		alone: [3][][4]f32
		seen: [READS][][4]f32
		// Each lamp alone, then the three, turned on together.
		for run in 0 ..= 3 {
			for len(r.scene.lights) > 0 {gpu.scene_light_remove(r, 0)}
			for lamp, i in lamps {
				if run < 3 && i != run {continue}
				gpu.scene_light_update(r, u32(len(r.scene.lights)), {position = lamp, color = {1, 0.9, 0.8}, intensity = 4 * math.PI, range = 6, radius = 0.05, indirect = 1, scattering = 1, shadowless = shadowless})
			}
			for k in 0 ..< READS {
				seen[k] = read(t, f, puff, camera, first, cells)
				if seen[k] == nil {return}
			}
			if run < 3 {alone[run] = seen[READS - 1]}
		}
		sum := make([][4]f32, cells, context.temp_allocator)
		lit := 0
		for &cell, i in sum {
			cell.rgb = alone[0][i].rgb + alone[1][i].rgb + alone[2][i].rgb
			lit += int(cell.g >= 1e-4)
		}
		what := "without shadows" if shadowless else "with shadows"
		testing.expectf(t, lit == cells, "%s: the lamps light %d cells of %d", what, lit, cells)
		settled := -1
		for k in 0 ..< READS {
			if apart(seen[k], sum) < 0.03 {settled = 1 + k * READ_FRAMES;break}
		}
		testing.expectf(t, settled >= 0 && settled <= 1 + READ_FRAMES, "%s: a cell takes what each lamp gives it alone, added up, %d frames after they turn on (%.3f apart then, %.3f at last)", what, settled, apart(seen[0], sum), apart(seen[READS - 1], sum))
		flicker: f32
		for k in READS / 2 ..< READS {flicker = max(flicker, apart(seen[k], seen[k - 1]))}
		testing.expectf(t, flicker < 0.01, "%s: a cell keeps its light from frame to frame, %.4f apart at most", what, flicker)
		free_all(context.temp_allocator)
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

// Particles dropped on a floor bounce and then rest on it: slower than the
// rest speed a surface keeps them without a hit or lost life, whatever steps
// the frames take.
@(test)
particles_that_land_rest_at_any_frame_rate :: proc(t: ^testing.T) {
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
		drop.info.collision, drop.info.bounce, drop.info.collision_life, drop.owner = .World, 0.3, 0.1, core.Entity(77)
		for i in 0 ..< int(1.5 / dt) {
			drop.spawns = test_burst(100) if i == 0 else {}
			testing.expect(t, frame_emitters(f, &f.sync, {drop}, dt))
			testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
		}
		testing.expectf(t, particles_alive(f) == 100, "at steps of %v s all 100 are alive, not %d", dt, particles_alive(f))
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

// A Surface program sees the color of the vertices of its mesh as data and
// the object of its point (testdata/surface_probe.slang).
@(test)
programs_see_the_vertex_colors_and_the_object_of_their_point :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	program := gpu.program_find(r, "Surface_Probe", .Surface)
	if !testing.expect(t, program != nil, "testdata has the Surface program Surface_Probe") {return}
	probe := gpu.DEFAULT_MATERIAL
	probe.program_id = program.id
	probe.custom_params[0] = {1, 0, 0, 0}
	gpu.materials_set(r, {probe})
	red := [3]f32{1, 0, 0}
	quad := []gpu.Mesh_Vertex {
		{position = {-0.5, 0, -0.5}, normal = {0, 1, 0}, color = red, tangent = {1, 0, 0, 1}},
		{position = {0.5, 0, -0.5}, normal = {0, 1, 0}, color = red, tangent = {1, 0, 0, 1}},
		{position = {0.5, 0, 0.5}, normal = {0, 1, 0}, color = red, tangent = {1, 0, 0, 1}},
		{position = {-0.5, 0, 0.5}, normal = {0, 1, 0}, color = red, tangent = {1, 0, 0, 1}},
	}
	mesh, made := gpu.mesh_add(r, quad, []u32{0, 2, 1, 0, 3, 2})
	if !testing.expect(t, made, r.error) {return}
	gpu.scene_set_environment(r,{},{sky = {0, 0, 0}})
	gpu.scene_update(r,0,{
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
	left, right := drawn[0], drawn[1]
	testing.expectf(t, left.r > left.b + 40 && right.r > 40, "drawn, the probe glows with the red of its vertices: %v %v", left, right)
	testing.expectf(t, left.g > 20 && left.g < left.r, "drawn, the scale of its object along y: %v", left)
	testing.expectf(t, right.b > left.b + 40, "drawn, its +x side of the object: %v against %v", right, left)
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
	settings_fog := fog.Fog_Settings{turns = .Every_Frame}
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

@(test)
custom_attributes_rebase_once_even_while_paused_and_the_arena_grows :: proc(t:^testing.T) {
    f:=new(Gpu_Fixture)
    defer free(f)
    if !gpu_fixture_init(t,f,64,48,test_settings()) {return}
    defer gpu_fixture_destroy(f)
    camera:=gpu.Camera{position={0,0,4},forward={0,0,-1},up={0,1,0},fov_y=60,
        near=0.05,far=14000,exposure=gpu.UNIT_EXPOSURE}
    emitter:=test_emitter(1,{0.25,0.5,0})
    emitter.info.lifetime={5,5}
    program:=erender.program_find(&f.assets,"Rebase_Test",.Vfx)
    if !testing.expect(t,program!=nil) {return}
    emitter.program.id,emitter.program.attributes=program.id,u32(program.attributes)
    base.text_set(emitter.info.program[:],program.name)
    emitter.spawns=test_burst(1)
    if !testing.expect(t,frame_emitters(f,&f.sync,{emitter},1.0/60)) {return}
    if !testing.expect(t,gpu.renderer_frame(&f.renderer,{camera=camera}),f.renderer.error) {return}
    old_size:=f.sync.pool.data_bytes
    emitter.spawns={}
    emitter.paused=true
    large:=test_emitter(2,{})
    large.spec=emitter.spec
    large.capacity=4096
    read:=Range_Read{sync=&f.sync,id=1,count=emitter.capacity}
    camera.position.x=8192
    for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT+2 {
        testing.expect(t,frame_emitters(f,&f.sync,{emitter,large},1.0/60))
        erender.frame_pass(f.app.renderer,.Simulate,range_read_pass,&read)
        testing.expect(t,gpu.renderer_frame(&f.renderer,{camera=camera,time=f32(i+1)/60}),f.renderer.error)
    }
    p,_,have_p:=gpu.readback(&f.renderer,f.sync.world,RANGE_NAMES[0])
    a,_,have_a:=gpu.readback(&f.renderer,f.sync.world,RANGE_NAMES[1])
    testing.expect(t,f.sync.pool.data_bytes>old_size && f.sync.pool.origin.x!=0)
    if !testing.expect(t,have_p && have_a) {return}
    seen:=false
    for item,i in mem.slice_data_cast([]Gpu_Particle,p) {
        if item.lifetime==0 {continue}
        seen=true
        point:=(^[3]f32)(raw_data(a[i*16:]))^
        testing.expect_value(t,point,item.position)
        testing.expect_value(t,point+f.sync.pool.origin,[3]f32{0.25,0.5,0})
    }
    testing.expect(t,seen)
    expect_clean(t,f.device)
}

@(test)
a_channel_birth_aligns_the_cone_with_its_surface_normal :: proc(t:^testing.T) {
    f:=new(Gpu_Fixture)
    defer free(f)
    if !gpu_fixture_init(t,f,64,48,test_settings()) {return}
    defer gpu_fixture_destroy(f)
    camera:=gpu.Camera{position={0,0,4},forward={0,0,-1},up={0,1,0},fov_y=60,
        near=0.05,far=100,exposure=gpu.UNIT_EXPOSURE}
    emitter:=test_emitter(1,{})
    emitter.info.shape,emitter.info.speed,emitter.info.lifetime=.Cone,{2,2},{5,5}
    append(&f.sync.births,Gpu_Birth{size=1,color={1,1,1,1},normal={0,0,1},count=1})
    emitter.births={0,1}
    read:=Range_Read{sync=&f.sync,id=1,count=emitter.capacity}
    for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT+2 {
        testing.expect(t,frame_emitters(f,&f.sync,{emitter},1.0/60))
        erender.frame_pass(f.app.renderer,.Simulate,range_read_pass,&read)
        testing.expect(t,gpu.renderer_frame(&f.renderer,{camera=camera,time=f32(i)/60}),f.renderer.error)
        clear(&f.sync.births)
        emitter.births={}
    }
    data,_,ok:=gpu.readback(&f.renderer,f.sync.world,RANGE_NAMES[0])
    if !testing.expect(t,ok) {return}
    alive:=0
    for p in mem.slice_data_cast([]Gpu_Particle,data) {
        if p.lifetime<=0 {continue}
        alive+=1
        testing.expect_value(t,p.velocity,[3]f32{0,0,2})
    }
    testing.expect_value(t,alive,1)
    expect_clean(t,f.device)
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
	for name in ([]string{"particle begin", "particle emit", "particle simulate", "particle steps", "particle finish", "particle sprites"}) {
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

// A wall lit from the front, behind what the camera at z 5 sees around the origin.
@(private = "file")
lit_wall :: proc(f: ^Gpu_Fixture) {
	gpu.scene_set_environment(&f.renderer, {direction = {0.2, 0.4, 1}, color = {1, 1, 1}, illuminance = math.PI, enabled = true, indirect = 1, scattering = 1}, {sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(&f.renderer, 0, {{object_id = 1, mesh = f.cube, transform = trs({0, 0, -2}, {12, 12, 0.2}), tint = {0.2, 0.2, 0.2}}}, true)
}

@(private = "file")
FRONT :: gpu.Camera{position = {0, 0, 5}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}

// Frames of emitters whose first frame starts one particle each.
@(private = "file")
frames_of_one :: proc(t: ^testing.T, f: ^Gpu_Fixture, emitters: []Emitter_Desc, frames: int, camera: gpu.Camera) {
	DT :: f32(1.0 / 60)
	for i in 0 ..< frames {
		for &e in emitters {e.spawns = test_burst(1) if i == 0 else {}}
		testing.expect(t, frame_emitters(f, &f.sync, emitters, DT))
		testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera, time = f32(i) * DT}), f.renderer.error)
	}
	rhi.device_wait_idle(f.device)
}

// Mesh particles of an additive material add its light over the lit scene
// without hiding what is behind them; those of an opaque one go into the
// G-buffer.
@(test)
mesh_particles_of_an_additive_material_add_their_light :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 128, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	glow := gpu.DEFAULT_MATERIAL
	glow.base_color, glow.alpha_mode = {0.3, 0, 0}, .Additive
	gpu.materials_set(r, {glow})
	lit_wall(f)
	// The blended flag is what emitter_desc gives a mesh of an additive material.
	added := test_emitter(1, {-1.2, 0, 0})
	added.info.render, added.material, added.blended = .Mesh, 1, true
	added.info.lifetime, added.info.size, added.info.soft, added.info.emission_mode, added.info.intensity = {10, 10}, {1, 1}, 0, .Relative, 1
	mesh_choices(&added, f.app.renderer, {f.cube}, {1})
	opaque := test_emitter(2, {1.2, 0, 0})
	opaque.info.render, opaque.info.lifetime, opaque.info.size = .Mesh, {10, 10}, {1, 1}
	mesh_choices(&opaque, f.app.renderer, {f.cube}, {1})
	emitters := [2]Emitter_Desc{added, opaque}
	frames_of_one(t, f, emitters[:], 8, FRONT)
	testing.expect(t, f.sync.pool.meshes && f.sync.pool.sprites, "the opaque mesh goes into the G-buffer and the additive one over it")
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	glowing := pixel(pixels, w, project(r, FRONT, {-1.2, 0, 0.5}))
	solid := pixel(pixels, w, project(r, FRONT, {1.2, 0, 0.5}))
	wall := pixel(pixels, w, project(r, FRONT, {0, 1.5, 0}))
	testing.expectf(t, wall[1] > 40, "the wall %v is lit", wall)
	testing.expectf(t, glowing[0] > wall[0] + 40, "the additive cube %v adds its red to the wall %v", glowing, wall)
	testing.expectf(t, glowing[1] > wall[1] - 8 && glowing[2] > wall[2] - 8, "and darkens nothing of it: %v over %v", glowing, wall)
	testing.expectf(t, abs(solid[0] - solid[1]) < 12 && abs(solid[0] - wall[0]) > 8, "the opaque cube %v is drawn as a gray surface, not as the wall %v", solid, wall)
	expect_clean(t, f.device)
}

// A sprite that multiplies darkens what is behind it by its color and adds nothing.
@(test)
particle_sprites_that_multiply_darken_what_is_behind :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	lit_wall(f)
	filter := test_emitter(1, {0, 0, 0})
	filter.info.blend, filter.info.lifetime, filter.info.soft = .Multiply, {10, 10}, 0
	filter.info.colors = {{0.1, 1, 1, 1}, {0.1, 1, 1, 1}}
	emitters := [1]Emitter_Desc{filter}
	frames_of_one(t, f, emitters[:], 6, FRONT)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	under := pixel(pixels, w, project(r, FRONT, {0, 0, 0}))
	wall := pixel(pixels, w, project(r, FRONT, {0, 1.5, 0}))
	testing.expectf(t, wall[0] > 40, "the wall %v is lit", wall)
	testing.expectf(t, under[0] < wall[0] * 0.75, "the sprite takes red from the wall: %v over %v", under, wall)
	testing.expectf(t, abs(under[1] - wall[1]) < 12 && abs(under[2] - wall[2]) < 12, "and keeps what its color lets through: %v over %v", under, wall)
	expect_clean(t, f.device)
}

// A trail that stops and starts again lays two ribbons: nothing between where
// the first ended and where the second began.
@(test)
ribbons_of_two_stretches_of_emission_do_not_join :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 128, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r, {}, {sky = {0.02, 0.02, 0.02}})
	trail := test_emitter(1, {-2, 0, 0})
	trail.info.render, trail.info.lifetime, trail.info.size, trail.info.soft = .Ribbon, {2, 2}, {0.3, 0.3}, 0
	DT :: f32(1.0 / 60)
	birth := u32(0)
	for i in 0 ..< 60 {
		trail.previous = trail.transform
		trail.transform = trs({-2 + f32(i + 1) * 4.0 / 60, 0, 0}, {1, 1, 1})
		trail.spawns = {}
		if i < 20 || i >= 40 {
			trail.spawns = test_rate(2, DT, birth)
			trail.spawns[0].ribbon = 1 if i < 20 else 2
			birth += 2
		}
		frame_emitters(f, &f.sync, {trail}, DT)
		testing.expect(t, gpu.renderer_frame(r, {camera = FRONT, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	first := pixel(pixels, w, project(r, FRONT, {-1.3, 0, 0}))
	gap := pixel(pixels, w, project(r, FRONT, {0, 0, 0}))
	second := pixel(pixels, w, project(r, FRONT, {1.3, 0, 0}))
	above := pixel(pixels, w, project(r, FRONT, {0, 0.6, 0}))
	testing.expectf(t, first[0] > above[0] + 60 && second[0] > above[0] + 60, "both stretches lay a band: %v and %v over %v", first, second, above)
	testing.expectf(t, abs(gap[0] - above[0]) < 10, "and nothing joins them: %v, the sky %v", gap, above)
	expect_clean(t, f.device)
}

// A ribbon wide along the up of its emitter stands on edge seen from above,
// where one that faces the camera lies flat; and its texture repeats every
// ribbon_tile metres from its head (testdata/trail_stripes.slang).
@(test)
ribbons_lie_along_the_up_of_their_emitter_and_tile_by_their_length :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 128, 128, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	surface := gpu.program_find(r, "Trail_Stripes", .Surface)
	if !testing.expect(t, surface != nil, "testdata has the Surface program Trail_Stripes") {return}
	stripes := gpu.DEFAULT_MATERIAL
	stripes.program_id = surface.id
	gpu.materials_set(r, {stripes})
	gpu.scene_set_environment(r, {}, {sky = {0.02, 0.02, 0.02}})
	above := gpu.Camera{position = {0, 6, 0.001}, forward = {0, -6, -0.001}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	flat := test_emitter(1, {-2, 0, -1})
	flat.info.render, flat.info.lifetime, flat.info.size, flat.info.soft = .Ribbon, {5, 5}, {0.3, 0.3}, 0
	flat.capacity = 256
	upright := flat
	upright.spec = new(Emitter_Info, context.temp_allocator)
	upright.spec^ = flat.spec^
	upright.id, upright.info.ribbon_axis = 2, .Emitter_Up
	tiled := flat
	tiled.spec = new(Emitter_Info, context.temp_allocator)
	tiled.spec^ = flat.spec^
	tiled.id, tiled.material, tiled.info.ribbon_tile = 3, 1, 1
	z := [3]f32{-1, 1, 2.2}
	DT :: f32(1.0 / 60)
	for i in 0 ..< 60 {
		emitters := [3]^Emitter_Desc{&flat, &upright, &tiled}
		for e, k in emitters {
			e.previous = e.transform
			e.transform = trs({-2 + f32(i + 1) * 4.0 / 60, 0, z[k]}, {1, 1, 1})
			e.spawns = test_rate(2, DT, u32(i) * 2)
		}
		frame_emitters(f, &f.sync, {flat, upright, tiled}, DT)
		testing.expect(t, gpu.renderer_frame(r, {camera = above, time = f32(i) * DT}), r.error)
	}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	sky := pixel(pixels, w, project(r, above, {0, 0, 0}))
	beside_flat := pixel(pixels, w, project(r, above, {0, 0, -1 + 0.1}))
	beside_upright := pixel(pixels, w, project(r, above, {0, 0, 1 + 0.1}))
	testing.expectf(t, beside_flat[0] > sky[0] + 60, "the ribbon that faces the camera lies flat: %v, the sky %v", beside_flat, sky)
	testing.expectf(t, abs(beside_upright[0] - sky[0]) < 10, "the one along the up of its emitter stands on edge: %v, the sky %v", beside_upright, sky)
	// Its head is at x 2: white the first half metre of each metre from it, black the second.
	for x, k in ([4]f32{1.75, 1.25, 0.75, 0.25}) {
		shown := pixel(pixels, w, project(r, above, {x, 0, z[2]}))
		white := k % 2 == 0
		testing.expectf(t, white == (shown[0] > sky[0] + 60), "at x %v, %v metres from its head, the stripes show %v", x, 2 - x, shown)
	}
	expect_clean(t, f.device)
}

// A Mesh particle that faces as its emitter turns as the emitter was when it
// was born, and the scale of its effect stretches it along each axis.
@(test)
mesh_particles_turn_as_their_emitter_was_and_scale_by_axis :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 128, 128, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r, {direction = {0.2, 0.4, 1}, color = {1, 1, 1}, illuminance = 4 * math.PI, enabled = true, indirect = 1, scattering = 1}, {sky = {0.02, 0.02, 0.02}})
	stick, added := stick_mesh(r)
	if !testing.expect(t, added) {return}
	camera := gpu.Camera{position = {0, 0, 3}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	for _ in 0 ..< 3 {testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)}
	// Born turned a quarter about y, its z along the x of the world; then the emitter turns back.
	turned: matrix[4, 4]f32 = 1
	turned[0, 0], turned[0, 2], turned[2, 0], turned[2, 2] = 0, 1, -1, 0
	sticks := test_emitter(1, {0, 0, 0})
	sticks.info.render, sticks.info.lifetime, sticks.info.size, sticks.info.lit = .Mesh, {30, 30}, {1, 1}, true
	sticks.info.facing, sticks.info.scale = .Emitter, {1, 3, 1}
	sticks.transform, sticks.previous = turned, turned
	if !testing.expect(t, mesh_choices(&sticks, f.app.renderer, {stick}, {1})) {return}
	for i in 0 ..< 12 {
		sticks.spawns = test_burst(1) if i == 0 else {}
		if i == 1 {sticks.previous, sticks.transform = turned, 1}
		if i == 2 {sticks.previous = 1}
		testing.expect(t, frame_emitters(f, &f.sync, {sticks}, 1.0 / 60))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera, time = f32(i) / 60}), r.error)
	}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	sky := pixel(pixels, w, project(r, camera, {0, 0.6, 0}))
	for x in ([]f32{-0.35, 0.35}) {
		along := pixel(pixels, w, project(r, camera, {x, 0, 0}))
		testing.expectf(t, along[0] > sky[0] + 30, "the stick lies along x, as its emitter was turned at its birth: at x %v %v, the sky %v", x, along, sky)
	}
	thick := pixel(pixels, w, project(r, camera, {0.2, 0.12, 0}))
	testing.expectf(t, thick[0] > sky[0] + 30, "three times as thick along y: %v, the sky %v", thick, sky)
	beyond := pixel(pixels, w, project(r, camera, {0.2, 0.3, 0}))
	testing.expectf(t, abs(beyond[0] - sky[0]) < 10, "and no more: %v, the sky %v", beyond, sky)
	expect_clean(t, f.device)
}

// Particles that move with their emitter take nothing more of its motion by
// inherit_velocity, and their meshes are drawn coming from where the emitter
// was the frame before (motion vectors).
@(test)
local_particles_move_with_their_emitter_once :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 128, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r, {direction = {0.2, 0.4, 1}, color = {1, 1, 1}, illuminance = 4 * math.PI, enabled = true, indirect = 1, scattering = 1}, {sky = {0.02, 0.02, 0.02}})
	ridden := test_emitter(1, {-1, 0, 0})
	ridden.info.render, ridden.info.lifetime, ridden.info.size, ridden.info.local_space = .Mesh, {30, 30}, {0.5, 0.5}, true
	mesh_choices(&ridden, f.app.renderer, {f.cube}, {1})
	inheriting := ridden
	inheriting.spec = new(Emitter_Info, context.temp_allocator)
	inheriting.spec^ = ridden.spec^
	inheriting.id, inheriting.info.inherit_velocity = 2, 1
	inheriting.transform = trs({-1, 20, 0}, {1, 1, 1})
	inheriting.previous = inheriting.transform
	STEP :: f32(0.02)
	DT :: f32(1.0 / 60)
	frame :: proc(t: ^testing.T, f: ^Gpu_Fixture, emitters: []Emitter_Desc, i: int, view: gpu.Debug_View) {
		for &e in emitters {
			e.previous = e.transform
			e.transform[0, 3] += STEP
			e.spawns = test_burst(1) if i == 0 else {}
		}
		testing.expect(t, frame_emitters(f, &f.sync, emitters, DT))
		testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = FRONT, time = f32(i) * DT, inspection = {mode = view}}), f.renderer.error)
	}
	emitters := [2]Emitter_Desc{ridden, inheriting}
	for i in 0 ..< 20 {frame(t, f, emitters[:], i, .None)}
	for i in 20 ..< 23 {frame(t, f, emitters[:], i, .Motion)}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	moving := pixel(pixels, w, project(r, FRONT, {emitters[0].transform[0, 3], 0, 0.25}))
	still := pixel(pixels, w, project(r, FRONT, {1.5, 0.5, 0}))
	delete(pixels)
	testing.expectf(t, moving[0] > still[0] + 20, "the mesh that rides its emitter moves on screen as it does: %v, what stays %v", moving, still)
	read := test_frame_read(t, f, emitters[:], DT, FRONT, 1, {pool_buffer(&f.sync.pool, .Particles), {}})
	if read[0] == nil {return}
	slot := u32(pool_slot_find(&f.sync.pool, 2))
	found := false
	for p in mem.slice_data_cast([]Gpu_Particle, read[0]) {
		if p.lifetime <= 0 || p.emitter != slot {continue}
		found = true
		testing.expectf(t, linalg.length(p.position) < 0.01 && linalg.length(p.velocity) < 0.01, "it stays where its emitter is: at %v going %v of its emitter", p.position, p.velocity)
	}
	testing.expect(t, found)
	expect_clean(t, f.device)
}

// In daylight (EV 15 under a noon sun) an unlit particle shows its emission in
// the units of its emitter: one relative to the exposure shows whether the
// emission comes from a Surface program or from its color, and ones too bright
// for the half floats of the image saturate to white instead of going black.
@(test)
unlit_particles_show_their_emission_in_their_own_units_in_daylight :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = true
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	surface := gpu.program_find(r, "Particle_Data", .Surface)
	if !testing.expect(t, surface != nil, "testdata has the Surface program Particle_Data") {return}
	glowing := gpu.DEFAULT_MATERIAL
	glowing.program_id = surface.id
	gpu.materials_set(r, {glowing})
	gpu.scene_set_environment(r, {direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = 100000, enabled = true, indirect = 1, scattering = 1}, {background = {0, 0, 0}, use_background = true})
	daylight := FRONT
	daylight.exposure = {mode = .Manual, ev100 = 15, own = true}
	program := test_emitter(1, {-1, 0, 0})
	program.material, program.info.blend, program.info.emission_mode = 1, .Alpha, .Relative
	bright := test_emitter(2, {1, 0, 0})
	bright.info.emission_mode, bright.info.intensity = .Relative, 1e6
	program.info.lifetime, bright.info.lifetime = {10, 10}, {10, 10}
	// Two of them add up over each other.
	again := bright
	again.id = 3
	emitters := [3]Emitter_Desc{program, bright, again}
	frames_of_one(t, f, emitters[:], 6, daylight)
	pixels, w, _, ok := gpu.renderer_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	green := pixel(pixels, w, project(r, daylight, {-1, 0, 0}))
	white := pixel(pixels, w, project(r, daylight, {1, 0, 0}))
	testing.expectf(t, green[1] > 100 && green[1] > green[0] + 60, "the relative emission of its Surface program shows: %v", green)
	testing.expectf(t, min(white[0], white[1], white[2]) > 200, "an emission past what the image holds saturates to white: %v", white)
	expect_clean(t, f.device)
}

// A program that gives the births of its emitter starts none while the clock
// of the emitter never emitted, whatever the frame covers of it (a frame
// longer than the ticks of its clock, the first of its range), and starts
// them once it emits (testdata/sprinkle.slang).
@(test)
program_births_wait_for_their_emitter_to_emit :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	settings := test_settings()
	settings.taa = false
	if !gpu_fixture_init(t, f, 96, 64, settings) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	program := erender.program_find(&f.assets, "Sprinkle", .Vfx)
	if !testing.expect(t, program != nil && program.births, "testdata has the Vfx program Sprinkle, which gives its births") {return}
	waiting := test_emitter(1, {0, 0, 0})
	waiting.info.lifetime = {30, 30}
	waiting.owner = core.Entity(1)
	waiting.program = {id = program.id, attributes = u32(program.attributes), births = true}
	waiting.program.parameters[0][0] = 600
	base.text_set(waiting.info.program[:], program.name)
	TICK :: f32(1.0 / 60)
	// Two ticks of the clock to each frame, the first of them one tick old.
	frames :: proc(t: ^testing.T, f: ^Gpu_Fixture, e: ^Emitter_Desc, age: ^f32, count: int, emits: bool) {
		for _ in 0 ..< count {
			age^ += TICK if age^ == 0 else 2 * TICK
			e.age = age^
			if emits {e.birth_limit = age^}
			testing.expect(t, frame_emitters(f, &f.sync, {e^}, 2 * TICK))
			testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = FRONT, time = age^}), f.renderer.error)
		}
		rhi.device_wait_idle(f.device)
	}
	age: f32
	frames(t, f, &waiting, &age, 6, false)
	testing.expect_value(t, particles_alive(f), u32(0))
	frames(t, f, &waiting, &age, 6, true)
	testing.expect(t, particles_alive(f) > 0, "once its emitter emits, its program starts particles")
	expect_clean(t, f.device)
}
