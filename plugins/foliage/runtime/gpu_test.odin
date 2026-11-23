package foliage

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:slice"
import "core:testing"
import "mirai:core"
import "mirai:asset"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

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
	delete(f.resident.winds)
	test_world_destroy(&f.world)
	delete(f.app.extras.instances)
	host.assets_destroy(&f.assets)
	gpu.renderer_destroy(&f.renderer)
}

// Frames from a camera with the field the benders of the world trample and
// the wind of the resident, a floor and the sun shining along `sun`, at
// `time` seconds, and the pixels of the last.
@(private = "file")
view_frames :: proc(t: ^testing.T, f: ^Gpu_Fixture, camera: gpu.Camera, sun: [3]f32, frames: int, illuminance := f32(3), time := f32(0)) -> (pixels: []u8, ok: bool) {
	for _ in 0 ..< frames {
		test_world_settle(&f.world)
		trample_draw(&f.resident, core.read(&f.world.benders), core.read(&f.world.volumes), core.read(&f.world.worlds), core.FRAME_TIME_DEFAULT, {}, &f.renderer)
		render.frame_pass(&f.renderer, .Mask, foliage_wind_record, &f.resident)
		// Wide enough that the levels of the sun near the eye are not its coarsest.
		floor := gpu.Instance_Desc{object_id = 1, mesh = f.cube, transform = mm.transform_matrix({{0, -0.5, 0}, mm.QUAT_IDENTITY, {600, 1, 600}}), tint = {0.05, 0.05, 0.05}}
		gpu.scene_set_environment(&f.renderer, {direction = -sun, color = {1, 1, 1}, illuminance = illuminance, indirect = 1, scattering = 1, enabled = illuminance > 0}, {sky = {0.4, 0.5, 0.6}})
		testing.expect(t, gpu.scene_update(&f.renderer, 0, {floor}, true), f.renderer.error)
		testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera, time = time}), f.renderer.error)
	}
	rhi.device_wait_idle(f.device)
	pixels, _, _, ok = gpu.renderer_capture(&f.renderer)
	testing.expect(t, ok, f.renderer.error)
	return
}

// Frames of the stalk, seen from above under a sun overhead.
@(private = "file")
stalk_frames :: proc(t: ^testing.T, f: ^Gpu_Fixture) -> (pixels: []u8, ok: bool) {
	camera := gpu.Camera{position = {0, 14, 0.01}, forward = {0, -1, -0.001}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	return view_frames(t, f, camera, {0, -1, 0}, 4)
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
	desc := render.Batch_Desc{mesh = f.cube, tint = 1, vertex = {0, 1, 0, 0}, reach = hook_reach({}, 2)}
	stalk, problem := render.batch_set(&f.renderer, f.resident.world, 0, desc, {render.batch_instance({0, 2, 0}, 1, {0.4, 4, 0.4})})
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
	// The floor of each image where nothing stands, as the light of the frames settles.
	floor = pixel_at(leaning, {-3, 0})
	testing.expect(t, differs(pixel_at(leaning, {1.4, 0}), floor), "trampled, its top leans away from the bender")
	testing.expect(t, !differs(pixel_at(leaning, {-1.4, 0}), floor), "and nothing leans toward it")
	// The same stalk, of a batch that is not of foliage, stands.
	desc.vertex = {}
	_, problem = render.batch_set(&f.renderer, f.resident.world, stalk, desc, {render.batch_instance({0, 2, 0}, 1, {0.4, 4, 0.4})})
	if !testing.expect(t, problem == "", problem) {return}
	other, drawn := stalk_frames(t, f)
	if !drawn {return}
	defer delete(other)
	testing.expect(t, !differs(pixel_at(other, {1.4, 0}), pixel_at(other, {-3, 0})), "a batch of anything else does not lean")
}

// The wind of the resident: one Wind everywhere, of `speed` m/s along -x
// with no gusts, which the batches that sway in wind 0 take their share of.
@(private = "file")
wind_blow :: proc(t: ^testing.T, f: ^Gpu_Fixture, speed: f32) -> bool {
	w: Zone_World
	if !test_world_init(t, &w) {return false}
	defer test_world_destroy(&w)
	e := core.create(&w.entities)
	core.add(&w.winds, e, volume.Wind{speed = speed, zone = volume.ZONE_DEFAULT})
	place := mm.TRANSFORM_IDENTITY
	place.rotation = mm.quat_axis_angle({0, 1, 0}, math.PI / 2)
	core.add(&w.worlds, e, core.World_Transform{place, place})
	test_world_settle(&w)
	value := volume.wind_at(core.read(&w.winds), zone_where(&w), {})
	f.resident.wind = volume.gpu_wind(core.read(&w.winds), zone_where(&w))
	return testing.expectf(t, abs(value.x + speed) < 1e-3, "the wind blows along -x: %v", value) && render.batches_wind(&f.renderer, 0, wind_share(value))
}

// A mesh of sheets, each a grid of cells by cells quads two-sided in the
// material of the mesh: a corner and its two sides, of the vertex color of
// the sheet (white when none), white swaying and fluttering all.
@(private = "file")
Sheet :: struct {corner, across, up: [3]f32, cells: int, color: u32}

@(private = "file")
sheets_mesh :: proc(t: ^testing.T, f: ^Gpu_Fixture, sheets: []Sheet) -> (mesh: gpu.Mesh_Handle, ok: bool) {
	vertices := make([dynamic]asset.Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	for sheet in sheets {
		n := sheet.cells
		normal := linalg.normalize(linalg.cross(sheet.across, sheet.up))
		first := u32(len(vertices))
		for j in 0 ..= n {
			for i in 0 ..= n {
				at := sheet.corner + sheet.across * f32(i) / f32(n) + sheet.up * f32(j) / f32(n)
				append(&vertices, asset.Vertex{position = at, normal = mm.normal_pack(normal), color = sheet.color if sheet.color != 0 else 0xffffffff, tangent = mm.tangent_pack(linalg.normalize(sheet.across), 1), uv = {f32(i) / f32(n), f32(j) / f32(n)}})
			}
		}
		for j in 0 ..< u32(n) {
			for i in 0 ..< u32(n) {
				a := first + j * u32(n + 1) + i
				append(&indices, a, a + 1, a + u32(n) + 1, a + 1, a + u32(n) + 2, a + u32(n) + 1)
			}
		}
	}
	levels := [1]asset.Level_Source{{0, u32(len(indices)), 0}}
	g: asset.Mesh_Geometry
	colored := false
	for sheet in sheets {colored ||= sheet.color != 0}
	if !testing.expect(t, asset.mesh_build({vertices = vertices[:], flags = colored ? {.Has_Colors} : {}}, indices[:], levels[:], &g, context.temp_allocator)) {return}
	return gpu.mesh_add_geometry(&f.renderer, g, {0})
}

// The batch of a kind that sways and casts swaying shadows, of a mesh with
// its farthest point `size` metres from where it stands, by the plugin's rules.
@(private = "file")
swaying_desc :: proc(f: ^Gpu_Fixture, mesh: gpu.Mesh_Handle, wind, size: f32) -> render.Batch_Desc {
	kind := Look{wind = wind, casts_shadow = true, scale = {1, 1}, height = {1, 1}}
	_, high, _ := render.mesh_bounds(&f.renderer, mesh)
	return {mesh = mesh, tint = 1, flags = {.Casts_Shadow, .Ray_Visible}, vertex = hook_vertex(kind), reach = hook_reach(kind, high.y), sway = shadow_sway(kind, high.y, size)}
}

// Where a point of the world lands on an image of a camera `width` by
// `height` pixels, and its linear depth; false off the image.
@(private = "file")
projected :: proc(camera: gpu.Camera, p: [3]f32, width, height: int) -> (x, y: int, depth: f32, inside: bool) {
	forward := linalg.normalize(camera.forward)
	right := linalg.normalize(linalg.cross(forward, camera.up))
	up := linalg.cross(right, forward)
	d := p - camera.position
	depth = linalg.dot(d, forward)
	half := math.tan(camera.fov_y * math.PI / 360)
	// Half the view up and down at the point: of an orthographic camera, half its height.
	across := camera.height * 0.5 if camera.projection == .Orthographic else depth * half
	x = int((linalg.dot(d, right) / (across * f32(width) / f32(height)) * 0.5 + 0.5) * f32(width))
	y = int((0.5 - linalg.dot(d, up) / across * 0.5) * f32(height))
	inside = x >= 0 && y >= 0 && x < width && y < height
	return
}

// The color of a point of the world on the image of a camera, -1 off it.
@(private = "file")
seen_at :: proc(f: ^Gpu_Fixture, pixels: []u8, camera: gpu.Camera, p: [3]f32) -> i32 {
	x, y, _, inside := projected(camera, p, WIDTH, HEIGHT)
	if !inside {return -1}
	i := (y * WIDTH + x) * 4
	return i32(pixels[i]) + i32(pixels[i + 1]) + i32(pixels[i + 2])
}

// A wall of many clusters 3 m tall that sways in a wind of 20 m/s along -x
// as the hook leans it, its pivot at its foot, the sun behind it at 45
// degrees: its shadow on the floor falls toward -z, the leaned top 1 m along
// -x. Near the eye (SHADOW_SWAY_REACH) the maps draw it as it sways, every
// frame as what moves, and none of its clusters is left out where its
// shadow lands; far away the maps keep it at rest and draw nothing again. In
// a light wind it sways less, and the maps hand its clusters to fewer pages.
@(test)
a_swaying_wall_casts_its_shadow_where_it_leans_only_near_the_eye :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	wall, made := sheets_mesh(t, f, {{corner = {-0.2, 0, 0}, across = {0.4, 0, 0}, up = {0, 3, 0}, cells = 24}})
	if !made {return}
	// Wind 3.5: a lean of 14.4 times its sway_amount at the phase the wave has at the origin, 0.4 rad.
	desc := swaying_desc(f, wall, 3.5, 3)
	if !testing.expect(t, desc.sway > 0, "a wall of 3 m casts swaying shadows") {return}
	_, problem := render.batch_set(&f.renderer, f.resident.world, 0, desc, {render.batch_instance({0, 0, 0}, 1, 1)})
	if !testing.expect(t, problem == "", problem) {return}
	if !wind_blow(t, f, 20) {return}
	sun := [3]f32{0, -1, -1}
	cases := [?]struct {
		name:   string,
		camera: gpu.Camera,
		near:   bool,
	}{
		{"near", {position = {-0.5, 1.2, -1.65}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 70, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}, true},
		// Past every map that sways, which hold what lies within them as it sways where no point reads it.
		{"far", {position = {-0.5, 55, -89.6}, forward = {0, -55, 87.3}, up = {0, 1, 0}, fov_y = 7, near = 0.05, far = 300, exposure = gpu.UNIT_EXPOSURE}, false},
	}
	strong: u32
	for c in cases {
		pixels, ok := view_frames(t, f, c.camera, sun, 16)
		if !ok {return}
		defer delete(pixels)
		lit := seen_at(f, pixels, c.camera, {0.3, 0, -1.2})
		rest := seen_at(f, pixels, c.camera, {0, 0, -2.2})
		testing.expectf(t, lit > 0, "%s: the floor is seen", c.name)
		// Where the shadows of its points 1 to 2.6 m up land when it leans.
		leaned: [5]i32
		for &v, k in leaned {
			h := 1 + 0.4 * f32(k)
			v = seen_at(f, pixels, c.camera, {-h * math.sin(f32(0.4)), 0, -h * math.cos(f32(0.4))})
		}
		movers, maps := f.renderer.stats.shadow_movers, f.renderer.stats.shadow
		if c.near {
			for v, k in leaned {testing.expectf(t, v >= 0 && v * 5 < lit * 3, "%s: the shadow of the leaned wall %v m up is %d against %d lit", c.name, 1 + 0.4 * f32(k), v, lit)}
			testing.expectf(t, rest * 4 > lit * 3, "%s: where it would rest the floor is lit: %d against %d", c.name, rest, lit)
			testing.expectf(t, movers == 1 && maps.clusters_moving > 0 && maps.pages_drawn == 0, "%s: it moves in the maps, the cache draws nothing again: %d movers, %d clusters moving, %d pages drawn", c.name, movers, maps.clusters_moving, maps.pages_drawn)
			strong = maps.clusters_moving
		} else {
			testing.expectf(t, rest >= 0 && rest * 5 < lit * 3, "%s: the shadow stands where it rests: %d against %d lit", c.name, rest, lit)
			testing.expectf(t, leaned[4] * 4 > lit * 3, "%s: no shadow where it leans: %d against %d", c.name, leaned[4], lit)
			testing.expectf(t, movers == 0 && maps.clusters_moving == 0 && maps.pages_drawn == 0 && maps.pages_composed == 0, "%s: the maps keep it at rest and draw nothing again: %d movers, %d clusters moving, %d pages drawn, %d composed", c.name, movers, maps.clusters_moving, maps.pages_drawn, maps.pages_composed)
		}
	}
	if !wind_blow(t, f, 4) {return}
	pixels, ok := view_frames(t, f, cases[0].camera, sun, 16)
	if !ok {return}
	delete(pixels)
	light := f.renderer.stats.shadow.clusters_moving
	testing.expectf(t, light > 0 && light < strong, "the maps hand %d clusters of it to their pages in a light wind, %d in the strongest", light, strong)
}

// A canopy of leaves closer together than the wind sways them, of one
// plant standing at the origin, under the sun in the maps that follow what
// sways (near the eye), under the sun in the maps that keep it at rest (past
// the reach), under the sun traced (the view is orthographic: no maps) and
// in the light of the probes alone: each leaf seen in the wind is lit as the
// same leaf is still, the share of leaves the others shade is the same and
// none is darker than it is still, as what hides a point swayed is what
// hides it at rest.
@(test)
a_swaying_canopy_is_shaded_as_it_is_at_rest :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	leaf := gpu.DEFAULT_MATERIAL
	leaf.two_sided = true
	if !testing.expect(t, gpu.materials_set(&f.renderer, {leaf})) {return}
	canopy := new(Canopy)
	defer free(canopy)
	canopy_grow(canopy)
	mesh, made := sheets_mesh(t, f, canopy.sheets[:])
	if !made {return}
	// Wind 1.3: a lean of 0.15 rad in the wind of the cases, the leaves 3 m
	// up move some 45 cm, farther than they lie apart.
	desc := swaying_desc(f, mesh, 1.3, 4.2)
	desc.material = 1
	if !testing.expect(t, desc.sway > 0, "the canopy casts swaying shadows") {return}
	_, problem := render.batch_set(&f.renderer, f.resident.world, 0, desc, {render.batch_instance({0, 0, 0}, 1, 1)})
	if !testing.expect(t, problem == "", problem) {return}
	near := gpu.Camera{position = {0, 3, 3}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 75, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	cases := [?]struct {
		name:        string,
		camera:      gpu.Camera,
		illuminance: f32,
		frames:      int,
	}{
		{"sun in the maps near the eye", near, 3, 12},
		{"sun in the maps past the reach", {position = {0, 3, 40}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 6.5, near = 0.05, far = 200, exposure = gpu.UNIT_EXPOSURE}, 3, 12},
		{"sun traced", {position = {0, 3, 10}, forward = {0, 0, -1}, up = {0, 1, 0}, projection = .Orthographic, height = 4, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}, 3, 12},
		{"probes", near, 0, 32},
	}
	sun := [3]f32{-1, -0.6, -0.4}
	lean := 20 * sway_amount({wind = 1.3}) * (0.6 + 0.4 * 0.3 * math.sin(f32(1.7)))
	for c in cases {
		lights: [2][CANOPY_LEAVES]i32
		for speed, k in ([2]f32{0, 20}) {
			if !wind_blow(t, f, speed) {return}
			pixels, ok := view_frames(t, f, c.camera, sun, c.frames, c.illuminance)
			if !ok {return}
			defer delete(pixels)
			if !canopy_seen(t, f, pixels, c.camera, canopy, lean if k == 1 else 0, &lights[k]) {return}
		}
		resolve, lighting := canopy_cost(t, f, c.camera)
		s := canopy_compare(canopy, c.camera, lights[0][:], lights[1][:])
		fmt.printfln("%s: %d leaves, mean %.1f still and %.1f in the wind, %.3f shaded still and %.3f in the wind, %.3f darker in the wind; resolve %.3f ms, lighting %.3f ms", c.name, s.leaves, s.mean[0], s.mean[1], s.shaded[0], s.shaded[1], s.darker, resolve, lighting)
		testing.expectf(t, s.leaves >= 50, "%s: %d leaves seen still and in the wind", c.name, s.leaves)
		testing.expectf(t, abs(s.mean[1] - s.mean[0]) <= 0.1 * s.mean[0], "%s: the leaves are %.1f in the wind against %.1f still", c.name, s.mean[1], s.mean[0])
		testing.expectf(t, abs(s.shaded[1] - s.shaded[0]) <= 0.08, "%s: %.3f of the leaves are shaded in the wind against %.3f still", c.name, s.shaded[1], s.shaded[0])
		testing.expectf(t, s.darker <= 0.04, "%s: %.3f of the leaves are darker in the wind than still", c.name, s.darker)
	}
}

@(private = "file")
CANOPY_LEAVES :: 400

// The GPU time of a frame of the canopy in the wind, ms, over 40 frames:
// that of the resolve, and that of the passes of its light (the direct
// light, reflections and contact occlusion).
@(private = "file")
canopy_cost :: proc(t: ^testing.T, f: ^Gpu_Fixture, camera: gpu.Camera) -> (resolve, lighting: f64) {
	LIGHTING :: [?]string{"direct maps", "direct rays", "direct samples", "direct points", "direct spread", "direct pixels", "reflect", "contact", "contact light", "contact pixels"}
	// The device writes the timestamps of each pass only while asked to.
	rhi.timestamps_want(f.device, true)
	defer rhi.timestamps_want(f.device, false)
	for _ in 0 ..< 40 {
		if !testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera}), f.renderer.error) {return}
		for timing in gpu.renderer_stats(&f.renderer).timings {
			if timing.name == "resolve" || timing.name == "rest" {resolve += f64(timing.ms)}
			for name in LIGHTING {if timing.name == name {lighting += f64(timing.ms)}}
		}
	}
	return resolve / 40, lighting / 40
}

// The leaves of a canopy, squares 25 cm wide turned every way in a ball 1.2 m
// in radius about a point 3 m up, and the center and normal of each.
@(private = "file")
Canopy :: struct {
	sheets:  [CANOPY_LEAVES]Sheet,
	centers: [CANOPY_LEAVES][3]f32,
	normals: [CANOPY_LEAVES][3]f32,
}

@(private = "file")
canopy_grow :: proc(c: ^Canopy) {
	random :: proc(seed: ^u32) -> f32 {
		seed^ ~= seed^ << 13
		seed^ ~= seed^ >> 17
		seed^ ~= seed^ << 5
		return f32(seed^ & 0xFFFFFF) / f32(0x1000000) * 2 - 1
	}
	seed := u32(12345)
	for k in 0 ..< CANOPY_LEAVES {
		center, normal: [3]f32
		for {
			center = {random(&seed), random(&seed), random(&seed)}
			if linalg.dot(center, center) <= 1 {break}
		}
		for {
			normal = {random(&seed), random(&seed), random(&seed)}
			if l := linalg.dot(normal, normal); l <= 1 && l > 0.01 {break}
		}
		center, normal = center * 1.2 + {0, 3, 0}, linalg.normalize(normal)
		side := [3]f32{0, 1, 0} if abs(normal.y) < 0.9 else [3]f32{1, 0, 0}
		across := linalg.normalize(linalg.cross(normal, side)) * 0.25
		up := linalg.cross(normal, across)
		c.sheets[k] = {corner = center - 0.5 * across - 0.5 * up, across = across, up = up, cells = 1}
		c.centers[k], c.normals[k] = center, linalg.normalize(linalg.cross(across, up))
	}
}

// Where the hook puts a point of the plant standing at the origin under a
// wind along -x that leans it `lean` radians (foliage_bend).
@(private = "file")
canopy_swayed :: proc(p: [3]f32, lean: f32) -> [3]f32 {
	return p + [3]f32{-math.sin(lean), math.cos(lean) - 1, 0} * max(p.y, 0)
}

// The light of each leaf of a canopy swayed `lean` radians as a camera sees
// it, the mean of 3x3 points over its middle that the view shows (the linear
// depth of the view there is theirs), -1 where others hide most of them.
@(private = "file")
canopy_seen :: proc(t: ^testing.T, f: ^Gpu_Fixture, pixels: []u8, camera: gpu.Camera, c: ^Canopy, lean: f32, lights: ^[CANOPY_LEAVES]i32) -> bool {
	width, height := int(f.renderer.targets.width), int(f.renderer.targets.height)
	depths := make([]f32, width * height)
	defer delete(depths)
	if !testing.expect(t, rhi.texture_read(f.device, f.renderer.targets.linear_depth, slice.to_bytes(depths))) {return false}
	for center, k in c.centers {
		sum, seen := i32(0), i32(0)
		for i in 0 ..< 9 {
			p := canopy_swayed(center + (f32(i % 3) - 1) * 0.3 * c.sheets[k].across + (f32(i / 3) - 1) * 0.3 * c.sheets[k].up, lean)
			x, y, depth, inside := projected(camera, p, width, height)
			if !inside || abs(depths[y * width + x] - depth) > 0.03 {continue}
			sum += seen_at(f, pixels, camera, p)
			seen += 1
		}
		lights[k] = sum / seen if seen >= 5 else -1
	}
	return true
}

// What a canopy shows in the wind against still, over the leaves seen in
// both and not edge on: their mean light, the share of them in shadow (under
// half the light of the brightest twentieth still) and the share darker in
// the wind than still by more than a tenth of that light.
@(private = "file")
Canopy_Shading :: struct {
	leaves: int,
	mean:   [2]f32,
	shaded: [2]f32,
	darker: f32,
}

@(private = "file")
canopy_compare :: proc(c: ^Canopy, camera: gpu.Camera, still, windy: []i32) -> (s: Canopy_Shading) {
	compared :: proc(c: ^Canopy, camera: gpu.Camera, still, windy: []i32, k: int) -> bool {
		view := camera.forward if camera.projection == .Orthographic else c.centers[k] - camera.position
		return still[k] >= 0 && windy[k] >= 0 && abs(linalg.dot(linalg.normalize(view), c.normals[k])) >= 0.25
	}
	seen := make([dynamic]i32, context.temp_allocator)
	for k in 0 ..< CANOPY_LEAVES {
		if compared(c, camera, still, windy, k) {append(&seen, still[k])}
	}
	if len(seen) == 0 {return}
	slice.sort(seen[:])
	lit := f32(seen[len(seen) - 1 - len(seen) / 20])
	for k in 0 ..< CANOPY_LEAVES {
		if !compared(c, camera, still, windy, k) {continue}
		a, b := f32(still[k]), f32(windy[k])
		s.leaves += 1
		s.mean += {a, b}
		s.shaded += {1 if a < 0.5 * lit else 0, 1 if b < 0.5 * lit else 0}
		s.darker += 1 if b < a - 0.1 * lit else 0
	}
	n := f32(s.leaves)
	s.mean /= n
	s.shaded /= n
	s.darker /= n
	return
}

// In the wind, the leaves of a kind that flutters (green 1) move on their own
// while what it holds still (green 0) stands where it rests, and nothing of a
// kind that does not flutter moves; neither sways (wind 0), so all that moves
// is the flutter. What the hook moves an instance by is computed for it once,
// the same for each of its clusters the view draws.
@(test)
a_kind_that_flutters_moves_its_leaves_on_their_own_and_one_that_does_not_stands :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	plant, made := sheets_mesh(t, f, {{corner = {-1.6, 0.2, 0}, across = {1, 0, 0}, up = {0, 2, 0}, cells = 24}, {corner = {0.6, 0.2, 0}, across = {1, 0, 0}, up = {0, 2, 0}, cells = 24, color = 0xffff00ff}})
	if !made {return}
	_, high, _ := render.mesh_bounds(&f.renderer, plant)
	places := [2]f32{-2.2, 2.2}
	for place, k in places {
		kind := Look{scale = {0.8, 1.2}, height = {1, 1}, flutter = 4 if k == 0 else 0}
		desc := render.Batch_Desc{mesh = plant, tint = 1, vertex = hook_vertex(kind), reach = hook_reach(kind, high.y)}
		_, problem := render.batch_set(&f.renderer, f.resident.world, 0, desc, {render.batch_instance({place, 0, 0}, 1, 1)})
		if !testing.expect(t, problem == "", problem) {return}
	}
	if !wind_blow(t, f, 12) {return}
	camera := gpu.Camera{position = {0, 1.2, 7}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	// The light settles first: what differs then is what moved.
	warm, warmed := view_frames(t, f, camera, {0.3, -1, -0.4}, 48)
	if !warmed {return}
	delete(warm)
	frames: [2][]u8
	for &pixels, k in frames {
		ok: bool
		pixels, ok = view_frames(t, f, camera, {0.3, -1, -0.4}, 2, time = 0.3 * f32(k))
		if !ok {return}
	}
	defer for p in frames {delete(p)}
	// How many pixels differ between the two times over each sheet and 0.3 m about it.
	changed: [2][2]int
	for place, kind in places {
		for sheet in 0 ..< 2 {
			left := place + (sheet == 0 ? -1.9 : 0.3)
			x0, y0, _, _ := projected(camera, {left, 2.5, 0}, WIDTH, HEIGHT)
			x1, y1, _, _ := projected(camera, {left + 1.6, 0, 0}, WIDTH, HEIGHT)
			for y in max(y0, 0) ..< min(y1, HEIGHT) {
				for x in max(x0, 0) ..< min(x1, WIDTH) {
					a, b := frames[0][(y * WIDTH + x) * 4:][:3], frames[1][(y * WIDTH + x) * 4:][:3]
					if differs({i32(a[0]), i32(a[1]), i32(a[2])}, {i32(b[0]), i32(b[1]), i32(b[2])}) {changed[kind][sheet] += 1}
				}
			}
		}
	}
	testing.expectf(t, changed[0][0] > 10, "the leaves of the kind that flutters move: %d pixels", changed[0][0])
	testing.expectf(t, changed[0][1] == 0 && changed[1] == {}, "what holds still stands: %d pixels of its stem, %v of the kind that does not flutter", changed[0][1], changed[1])
	// Of the clusters drawn, those of the instance that flutters all carry one value.
	visible := int(f.renderer.stats.visible_clusters)
	moved := make([][2][4]f32, visible)
	defer delete(moved)
	if !testing.expect(t, visible > 0 && rhi.buffer_read_slice(f.device, f.renderer.scene.visible_moved, 0, moved), "the clusters drawn are read back") {return}
	fluttering: int
	first: [4]f32
	for m in moved {
		if !(m[0].z > 0) {continue}
		if fluttering == 0 {first = m[0]}
		testing.expectf(t, m[0] == first, "a cluster of the instance moves by %v, another by %v", m[0], first)
		fluttering += 1
	}
	testing.expectf(t, fluttering > 1, "%d clusters of the instance that flutters are drawn", fluttering)
}

// No swayed copy of a mesh is made: the geometry of the renderer is the same
// with and without wind, and a still view in the wind traces no more probes
// than one without, as the rays meet foliage at rest.
@(test)
a_swaying_kind_builds_no_geometry_and_leaves_the_probes_still :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	tree, made := sheets_mesh(t, f, {{corner = {-1, 0, 0}, across = {2, 0, 0}, up = {0, 4, 0}, cells = 16}})
	if !made {return}
	desc := swaying_desc(f, tree, 1, 4)
	instances: [64]render.Batch_Instance
	for &instance, k in instances {instance = render.batch_instance({f32(k % 8) * 3 - 12, 0, f32(k / 8) * 3 - 12}, 1, 1)}
	_, problem := render.batch_set(&f.renderer, f.resident.world, 0, desc, instances[:])
	if !testing.expect(t, problem == "", problem) {return}
	camera := gpu.Camera{position = {0, 6, 16}, forward = {0, -6, -16}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	bytes, probes: [2]u64
	for speed, k in ([2]f32{0, 12}) {
		if !wind_blow(t, f, speed) {return}
		pixels, ok := view_frames(t, f, camera, {0.3, -1, 0.2}, 24)
		if !ok {return}
		delete(pixels)
		bytes[k], probes[k] = f.renderer.stats.geometry_bytes, u64(f.renderer.stats.probes_traced)
	}
	testing.expectf(t, bytes[0] == bytes[1], "the geometry holds %d bytes still and %d in the wind", bytes[0], bytes[1])
	testing.expectf(t, probes[1] <= probes[0], "a still view traces %d probes a frame still, %d in the wind", probes[0], probes[1])
}

// The view culls a swaying kind by cluster: of a long hedge only the
// clusters near what the camera looks at are drawn.
@(test)
a_swaying_kind_is_culled_by_cluster :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	hedge, made := sheets_mesh(t, f, {{corner = {-20, 0, 0}, across = {40, 0, 0}, up = {0, 1.5, 0}, cells = 48}})
	if !made {return}
	desc := swaying_desc(f, hedge, 1, 20)
	_, problem := render.batch_set(&f.renderer, f.resident.world, 0, desc, {render.batch_instance({0, 0, 0}, 1, 1)})
	if !testing.expect(t, problem == "", problem) {return}
	if !wind_blow(t, f, 12) {return}
	camera := gpu.Camera{position = {0, 1, -4}, forward = {0, -0.1, 1}, up = {0, 1, 0}, fov_y = 30, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	pixels, ok := view_frames(t, f, camera, {0.3, -1, 0.2}, 4)
	if !ok {return}
	delete(pixels)
	clusters := f.renderer.scene.meshes[hedge].cluster_count
	visible := f.renderer.stats.visible_clusters
	testing.expectf(t, visible > 0 && visible * 2 < clusters, "%d of the %d clusters of the hedge are drawn", visible, clusters)
}

// Copies the arguments of the two draws of the impostors of the frame to a
// readback, after their pass.
@(private = "file")
impostor_draws_read :: proc(pass: ^render.Pass, user: rawptr) {
	render.pass_readback(pass, {name = IMPOSTOR_DRAW, size = 32}, 0, {name = "test impostor draws", size = 32})
}

// Two impostors on the line of sight: the near one hides the far one, which
// neither draw makes, and when the near one moves away the far one shows in
// that same frame.
@(test)
an_impostor_another_hides_is_not_drawn_and_shows_when_it_moves :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	d := &f.resident.impostors
	defer impostor_draw_destroy(d)
	// A grid of 2 frames a side of 4 pixels, covered and white, the leaves on
	// the plane through the centre of the sphere.
	frames: [3]u32
	texels := [3][4]u8{{255, 255, 255, 255}, {128, 255, 128, 128}, {200, 0, 255, 0}}
	for &texel, i in texels {
		pixels: [8 * 8 * 4]u8
		for k in 0 ..< 64 {copy(pixels[k * 4:], texel[:])}
		texture, ok := render.texture_add(&f.renderer, {pixels = pixels[:], width = 8, height = 8, srgb = i == 0, name = "test impostor"})
		if !testing.expect(t, ok, f.renderer.error) {return}
		frames[i] = render.texture_index(texture)
	}
	append(&d.rows, Impostor_Row{sphere = {0, 0, 0, 1}, low = {-1, -1, -1, 0}, high = {1, 1, 1, 1e-3}, frames = {frames[0], frames[1], frames[2], 2 | 4 << 16}})
	append(&d.bases, 0)
	placed :: proc(at: [3]f32, size: f32, tint: [3]f32) -> Impostor_Instance {
		b := render.batch_instance(at, 1, size)
		return {position = b.position, rotation = b.rotation, scale = b.scale, color = render.batch_color(tint, 0)}
	}
	far := placed({0, 1, -6}, 1, {1, 0, 0})
	block: u32
	camera := gpu.Camera{position = {0, 1, 6}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	center := proc(t: ^testing.T, f: ^Gpu_Fixture, camera: gpu.Camera, frames: int) -> (color: [3]i32, ok: bool) {
		for _ in 0 ..< frames {
			render.frame_pass(&f.renderer, .Gbuffer, foliage_impostors_record, &f.resident)
			render.frame_pass(&f.renderer, .Gbuffer, impostor_draws_read)
			floor := gpu.Instance_Desc{object_id = 1, mesh = f.cube, transform = mm.transform_matrix({{0, -0.5, 0}, mm.QUAT_IDENTITY, {40, 1, 40}}), tint = {0.05, 0.05, 0.05}}
			// A sun that lights them from the first frame, whatever probes the light of the sky has reached.
			gpu.scene_set_environment(&f.renderer, {direction = {-0.3, 1, 0.6}, color = {1, 1, 1}, illuminance = 3, enabled = true}, {sky = {0.4, 0.5, 0.6}})
			testing.expect(t, gpu.scene_update(&f.renderer, 0, {floor}, true), f.renderer.error)
			testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera}), f.renderer.error)
		}
		rhi.device_wait_idle(f.device)
		pixels, _, _, captured := gpu.renderer_capture(&f.renderer)
		if !testing.expect(t, captured, f.renderer.error) {return}
		defer delete(pixels)
		i := (HEIGHT / 2 * WIDTH + WIDTH / 2) * 4
		return {i32(pixels[i]), i32(pixels[i + 1]), i32(pixels[i + 2])}, true
	}
	if !testing.expect(t, impostors_set(d, &block, {placed({0, 1, 0}, 2, {0, 1, 0}), far})) {return}
	hidden, shown: [3]i32
	ok: bool
	if hidden, ok = center(t, f, camera, 8); !ok {return}
	testing.expectf(t, hidden.g > hidden.r + 20, "the near one is in front, got %v", hidden)
	data, _, read := render.readback(&f.renderer, f.resident.world, "test impostor draws")
	if testing.expect(t, read && len(data) == 32, "the draws were read back") {
		draws := (^[8]u32)(raw_data(data))^
		testing.expectf(t, draws[1] == 1 && draws[5] == 0, "the far one is drawn neither first nor late: %v", draws)
	}
	if !testing.expect(t, impostors_set(d, &block, {placed({12, 1, 0}, 2, {0, 1, 0}), far})) {return}
	if shown, ok = center(t, f, camera, 1); !ok {return}
	testing.expectf(t, shown.r > shown.g + 20, "the far one shows in the frame the near one left, got %v", shown)
	testing.expect(t, render.readback_release(&f.renderer, f.resident.world, "test impostor draws"))
}

@(private)
@(test_world)
Sway_World :: struct {
	using world: Test_World,
	sways:      core.Table(Foliage_Sway),
	meshes:     core.Table(render.Mesh_Renderer),
	values:     core.Table(render.Material_Values),
	worlds:     core.Table(core.World_Transform),
	hidden:     core.Table(render.Hidden),
	parents:    core.Table(core.Parent),
	layers:     core.Table(render.Layers),
	elsewhere:  core.Table(render.Drawn_Elsewhere),
	highlights: core.Table(render.Highlight),
	outlines:   core.Table(render.Outline),
	colliders:  core.Table(phys.Collider),
}

@(private = "file")
sway_step :: proc(f: ^Gpu_Fixture, w: ^Sway_World, problems: ^core.Problems) {
	foliage_sway_render(&f.resident, core.read(&w.sways), core.read(&w.meshes), core.read(&w.values), core.read(&w.worlds), core.read(&w.hidden), core.read(&w.parents), core.read(&w.layers), core.read(&w.elsewhere), core.read(&w.highlights), core.read(&w.outlines), core.commands(w, test_world_info(w)), f.resident.world, &f.app, problems)
	test_world_settle(w)
}

// Whether a ray along -z at (x, y) meets a batch of the entity, at rest.
@(private = "file")
sway_met :: proc(f: ^Gpu_Fixture, e: core.Entity, x, y: f32) -> bool {
	hit, found := render.batch_ray(&f.renderer, f.resident.world, {x, y, 5}, {0, 0, -1}, 10)
	return found && hit.object_id == u64(e)
}

// A wall 3 m tall placed by hand, a mesh entity with a collider, sways as
// foliage of its wind does once it has a Foliage_Sway: it is drawn once, by a
// batch of one instance (its own mesh Drawn_Elsewhere), which rays and the
// picker meet at rest as the entity; it keeps its collider and mesh, casts
// its shadow leaned near the eye, follows the entity when it moves and
// scales, goes while it is hidden and draws as its own mesh again without
// the component.
@(test)
a_mesh_entity_that_sways_is_drawn_once_as_it_stands_and_casts_its_swaying_shadow :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	defer sways_free(&f.resident)
	n := 24
	positions := make([dynamic][3]f32, context.temp_allocator)
	normals := make([dynamic][3]f32, context.temp_allocator)
	colors := make([dynamic][4]f32, context.temp_allocator)
	uvs := make([dynamic][2]f32, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	for j in 0 ..= n {
		for i in 0 ..= n {
			append(&positions, [3]f32{-0.2 + 0.4 * f32(i) / f32(n), 3 * f32(j) / f32(n), 0})
			append(&normals, [3]f32{0, 0, 1})
			append(&colors, [4]f32{1, 1, 1, 1})
			append(&uvs, [2]f32{f32(i) / f32(n), f32(j) / f32(n)})
		}
	}
	for j in 0 ..< u32(n) {
		for i in 0 ..< u32(n) {
			a := j * u32(n + 1) + i
			append(&indices, a, a + 1, a + u32(n) + 1, a + 1, a + u32(n) + 2, a + u32(n) + 1)
		}
	}
	mesh, made := host.assets_mesh_generate(&f.assets, {positions = positions[:], normals = normals[:], uvs = uvs[:], colors = colors[:], indices = indices[:]})
	if !testing.expect(t, made) {return}
	w: Sway_World
	if !test_world_init(t, &w) {return}
	defer test_world_destroy(&w)
	problems := new(core.Problems)
	defer free(problems)
	e := core.create(&w.entities)
	place := mm.TRANSFORM_IDENTITY
	core.add(&w.meshes, e, render.Mesh_Renderer{mesh = mesh, shadows = true})
	core.add(&w.worlds, e, core.World_Transform{place, place})
	core.add(&w.colliders, e, phys.Collider{kind = .Box, size = {0.2, 1.5, 0.05}})
	// Wind 3.5: a lean of 14.4 times its sway_amount at the phase the wave has at the origin, 0.4 rad.
	core.add(&w.sways, e, Foliage_Sway{wind = 3.5})
	test_world_settle(&w)
	sway_step(f, &w, problems)
	batches, instances := gpu.batch_count(&f.renderer)
	testing.expectf(t, batches == 1 && instances == 1 && core.has(&w.elsewhere, e), "one batch of one instance draws it, and its own mesh is drawn elsewhere: %d batches, %d instances", batches, instances)
	testing.expect(t, core.has(&w.colliders, e) && core.has(&w.meshes, e), "it keeps its collider and its mesh")
	testing.expect(t, sway_met(f, e, 0, 1.5) && !sway_met(f, e, 0, 3.5), "a ray meets it at rest as the entity")
	held := core.entity_map_get(&f.resident.sways, e)
	if !testing.expect(t, held != nil && held.handle != 0) {return}
	handle := held.handle
	if !wind_blow(t, f, 20) {return}
	sun := [3]f32{0, -1, -1}
	camera := gpu.Camera{position = {-0.5, 1.2, -1.65}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 70, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	pixels, ok := view_frames(t, f, camera, sun, 16)
	if !ok {return}
	defer delete(pixels)
	lit := seen_at(f, pixels, camera, {0.3, 0, -1.2})
	rest := seen_at(f, pixels, camera, {0, 0, -2.2})
	for k in 0 ..< 5 {
		h := 1 + 0.4 * f32(k)
		v := seen_at(f, pixels, camera, {-h * math.sin(f32(0.4)), 0, -h * math.cos(f32(0.4))})
		testing.expectf(t, v >= 0 && v * 5 < lit * 3, "the shadow of the leaned wall %v m up is %d against %d lit", h, v, lit)
	}
	testing.expectf(t, rest * 4 > lit * 3, "where it would rest the floor is lit: %d against %d", rest, lit)
	testing.expectf(t, f.renderer.stats.shadow_movers == 1, "it moves in the maps near the eye: %d movers", f.renderer.stats.shadow_movers)
	// Moved and scaled, its batch follows it.
	place.position, place.scale = {2, 0, 0}, {1, 2, 1}
	core.edit(&w.worlds, e)^ = {place, place}
	test_world_settle(&w)
	sway_step(f, &w, problems)
	held = core.entity_map_get(&f.resident.sways, e)
	testing.expect(t, held != nil && held.handle == handle, "the same batch draws it")
	testing.expect(t, sway_met(f, e, 2, 4.5) && !sway_met(f, e, 0, 1.5), "it stands where the entity was moved, as tall as it was scaled")
	core.add(&w.hidden, e, render.Hidden{})
	test_world_settle(&w)
	sway_step(f, &w, problems)
	batches, _ = gpu.batch_count(&f.renderer)
	testing.expect(t, batches == 0 && core.has(&w.elsewhere, e), "hidden, it is not drawn")
	core.remove(&w.hidden, e)
	test_world_settle(&w)
	sway_step(f, &w, problems)
	batches, _ = gpu.batch_count(&f.renderer)
	testing.expect_value(t, batches, 1)
	core.remove(&w.sways, e)
	test_world_settle(&w)
	sway_step(f, &w, problems)
	batches, _ = gpu.batch_count(&f.renderer)
	testing.expect(t, batches == 0 && !core.has(&w.elsewhere, e), "without the component its own mesh draws it again")
	testing.expect_value(t, problems.count, 0)
}

// A world that runs a copy of the edited one (Play) draws the swaying
// entities it copied with their Drawn_Elsewhere, each once; what it destroys
// takes its batch, what it spawns gets one, and freeing it leaves only the
// batches of the edited world, one for each swaying entity there is.
@(test)
a_world_copied_for_play_draws_its_swaying_entities_once_and_leaves_nothing :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	defer sways_free(&f.resident)
	w: Sway_World
	if !test_world_init(t, &w) {return}
	defer test_world_destroy(&w)
	problems := new(core.Problems)
	defer free(problems)
	sway_add :: proc(w: ^Sway_World, x: f32) -> core.Entity {
		e := core.create(&w.entities)
		place := mm.TRANSFORM_IDENTITY
		place.position.x = x
		core.add(&w.meshes, e, render.Mesh_Renderer{shape = .Cube, shadows = true})
		core.add(&w.worlds, e, core.World_Transform{place, place})
		core.add(&w.sways, e, FOLIAGE_SWAY_DEFAULT)
		test_world_settle(w)
		return e
	}
	count :: proc(f: ^Gpu_Fixture) -> int {batches, _ := gpu.batch_count(&f.renderer);return batches}
	tree, bush := sway_add(&w, 0), sway_add(&w, 3)
	sway_step(f, &w, problems)
	testing.expect_value(t, count(f), 2)
	play := new(Foliage_Resident)
	defer free(play)
	play.app, play.world = &f.app, {index = 2}
	step :: proc(f: ^Gpu_Fixture, w: ^Sway_World, r: ^Foliage_Resident, problems: ^core.Problems) {
		foliage_sway_render(r, core.read(&w.sways), core.read(&w.meshes), core.read(&w.values), core.read(&w.worlds), core.read(&w.hidden), core.read(&w.parents), core.read(&w.layers), core.read(&w.elsewhere), core.read(&w.highlights), core.read(&w.outlines), core.commands(w, test_world_info(w)), r.world, &f.app, problems)
		test_world_settle(w)
	}
	step(f, &w, play, problems)
	testing.expectf(t, count(f) == 4 && len(play.sways.entities) == 2, "the copy draws both it copied with their Drawn_Elsewhere: %d batches", count(f))
	core.destroy(&w.entities, bush)
	test_world_settle(&w)
	flower := sway_add(&w, 6)
	step(f, &w, play, problems)
	testing.expectf(t, len(play.sways.entities) == 2 && core.entity_map_get(&play.sways, bush) == nil && core.entity_map_get(&play.sways, flower) != nil, "the copy drops what it destroyed and draws what it spawned")
	testing.expect(t, core.has(&w.elsewhere, flower) && core.has(&w.elsewhere, tree))
	app := f.app
	foliage_release(play, &app)
	sway_step(f, &w, problems)
	testing.expectf(t, count(f) == 2 && len(f.resident.sways.entities) == 2, "freed, the copy leaves the batches of the edited world alone, one each: %d", count(f))
	testing.expect_value(t, problems.count, 0)
}

// A swaying entity is outlined around its mesh at rest only at a level that
// shows something with the styles of the renderer, and a frame in which
// nothing of its outline changed gives the outline it made before.
@(test)
a_swaying_entity_is_outlined_only_at_a_level_that_shows :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	defer sways_free(&f.resident)
	w: Sway_World
	if !test_world_init(t, &w) {return}
	defer test_world_destroy(&w)
	problems := new(core.Problems)
	defer free(problems)
	outlined :: proc(f: ^Gpu_Fixture, w: ^Sway_World, problems: ^core.Problems) -> []gpu.Instance_Desc {
		test_world_settle(w)
		clear(&f.app.extras.instances)
		sway_step(f, w, problems)
		return f.app.extras.instances[:]
	}
	e := core.create(&w.entities)
	place := mm.TRANSFORM_IDENTITY
	core.add(&w.meshes, e, render.Mesh_Renderer{shape = .Cube})
	core.add(&w.worlds, e, core.World_Transform{place, place})
	core.add(&w.sways, e, FOLIAGE_SWAY_DEFAULT)
	// The first level of the agents, transparent until the editor gives it a color.
	core.add(&w.highlights, e, render.Highlight{level = 5})
	testing.expect(t, 5 not_in gpu.highlight_levels_shown(&f.renderer) && 1 in gpu.highlight_levels_shown(&f.renderer))
	testing.expect_value(t, len(outlined(f, &w, problems)), 0)
	core.edit(&w.highlights, e).level = 1
	shown := outlined(f, &w, problems)
	testing.expect(t, len(shown) == 1 && shown[0].highlight == 1 && shown[0].outline_only && shown[0].object_id == u64(e), "selected, it is outlined")
	f.resident.sway_outlines.instances[0].copy_variant = 7
	shown = outlined(f, &w, problems)
	testing.expect(t, len(shown) == 1 && shown[0].copy_variant == 7, "a still frame gives the outline it made before")
	core.edit(&w.highlights, e).level = 5
	testing.expect_value(t, len(outlined(f, &w, problems)), 0)
	style := f.renderer.highlight
	style.colors[4] = {1, 0, 0, 1}
	testing.expect(t, gpu.renderer_set_highlight_style(&f.renderer, style))
	shown = outlined(f, &w, problems)
	testing.expect(t, len(shown) == 1 && shown[0].highlight == 5, "once its level has a color, it is outlined")
	core.add(&w.hidden, e, render.Hidden{})
	testing.expect_value(t, len(outlined(f, &w, problems)), 0)
	testing.expect_value(t, problems.count, 0)
}
