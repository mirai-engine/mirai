package foliage

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
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
// the wind of the resident, a floor and the sun shining along `sun`, and the
// pixels of the last.
@(private = "file")
view_frames :: proc(t: ^testing.T, f: ^Gpu_Fixture, camera: gpu.Camera, sun: [3]f32, frames: int) -> (pixels: []u8, ok: bool) {
	for _ in 0 ..< frames {
		test_world_settle(&f.world)
		trample_draw(&f.resident, core.read(&f.world.benders), core.read(&f.world.volumes), core.read(&f.world.worlds), core.FRAME_TIME_DEFAULT, {}, &f.renderer)
		render.frame_pass(&f.renderer, .Mask, foliage_wind_record, &f.resident)
		// Wide enough that the levels of the sun near the eye are not its coarsest.
		floor := gpu.Instance_Desc{object_id = 1, mesh = f.cube, transform = mm.transform_matrix({{0, -0.5, 0}, mm.QUAT_IDENTITY, {600, 1, 600}}), tint = {0.05, 0.05, 0.05}}
		gpu.scene_set_environment(&f.renderer, {direction = -sun, color = {1, 1, 1}, illuminance = 3, indirect = 1, scattering = 1, enabled = true}, {sky = {0.4, 0.5, 0.6}})
		testing.expect(t, gpu.scene_update(&f.renderer, 0, {floor}, true), f.renderer.error)
		testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera}), f.renderer.error)
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
	desc := render.Batch_Desc{mesh = f.cube, tint = 1, vertex = {0, 1, 0, 0}, reach = hook_reach(0, 2)}
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
// material of the mesh: a corner and its two sides, white, its vertices all
// swaying (red 1).
@(private = "file")
Sheet :: struct {corner, across, up: [3]f32, cells: int}

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
				append(&vertices, asset.Vertex{position = at, normal = mm.normal_pack(normal), color = 0xffffffff, tangent = mm.tangent_pack(linalg.normalize(sheet.across), 1), uv = {f32(i) / f32(n), f32(j) / f32(n)}})
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
	if !testing.expect(t, asset.mesh_build({vertices = vertices[:]}, indices[:], levels[:], &g, context.temp_allocator)) {return}
	return gpu.mesh_add_geometry(&f.renderer, g, {0})
}

// The batch of a kind that sways and casts swaying shadows, of a mesh with
// its farthest point `size` metres from where it stands, by the plugin's rules.
@(private = "file")
swaying_desc :: proc(f: ^Gpu_Fixture, mesh: gpu.Mesh_Handle, wind, size: f32) -> render.Batch_Desc {
	kind := FOLIAGE_TYPE_DEFAULT
	kind.wind, kind.casts_shadow, kind.scale, kind.height = wind, true, {1, 1}, {1, 1}
	_, high, _ := render.mesh_bounds(&f.renderer, mesh)
	amount := sway_amount(kind)
	return {mesh = mesh, tint = 1, flags = {.Casts_Shadow, .Ray_Visible}, vertex = {amount, 1, 0, 0}, reach = hook_reach(amount, high.y), sway = shadow_sway(kind, high.y, size)}
}

// Where a point of the world lands on the image of a camera, and its color.
@(private = "file")
seen_at :: proc(f: ^Gpu_Fixture, pixels: []u8, camera: gpu.Camera, p: [3]f32) -> i32 {
	forward := linalg.normalize(camera.forward)
	right := linalg.normalize(linalg.cross(forward, camera.up))
	up := linalg.cross(right, forward)
	d := p - camera.position
	z := linalg.dot(d, forward)
	half := math.tan(camera.fov_y * math.PI / 360)
	// Half the view up and down at the point: of an orthographic camera, half its height.
	across := camera.height * 0.5 if camera.projection == .Orthographic else z * half
	x := int((linalg.dot(d, right) / (across * f32(WIDTH) / f32(HEIGHT)) * 0.5 + 0.5) * f32(WIDTH))
	y := int((0.5 - linalg.dot(d, up) / across * 0.5) * f32(HEIGHT))
	if x < 0 || y < 0 || x >= WIDTH || y >= HEIGHT {return -1}
	i := (y * WIDTH + x) * 4
	return i32(pixels[i]) + i32(pixels[i + 1]) + i32(pixels[i + 2])
}

// A wall of many clusters 3 m tall that sways in a wind of 20 m/s along -x
// as the hook leans it, its pivot at its foot, the sun behind it at 45
// degrees: its shadow on the floor falls toward -z, the leaned top 1 m along
// -x. Near the eye (SHADOW_SWAY_REACH) the maps draw it as it sways, every
// frame as what moves, and none of its clusters is left out where its
// shadow lands; far away the maps keep it at rest and draw nothing again.
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
		{"far", {position = {-0.5, 25, -42}, forward = {0, -25, 39.7}, up = {0, 1, 0}, fov_y = 15, near = 0.05, far = 200, exposure = gpu.UNIT_EXPOSURE}, false},
	}
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
		} else {
			testing.expectf(t, rest >= 0 && rest * 5 < lit * 3, "%s: the shadow stands where it rests: %d against %d lit", c.name, rest, lit)
			testing.expectf(t, leaned[4] * 4 > lit * 3, "%s: no shadow where it leans: %d against %d", c.name, leaned[4], lit)
			testing.expectf(t, movers == 0 && maps.clusters_moving == 0 && maps.pages_drawn == 0 && maps.pages_composed == 0, "%s: the maps keep it at rest and draw nothing again: %d movers, %d clusters moving, %d pages drawn, %d composed", c.name, movers, maps.clusters_moving, maps.pages_drawn, maps.pages_composed)
		}
	}
}

// A canopy of two upright leaves of one plant facing a low sun whose shadow
// is traced, not mapped (the view is orthographic): a wind pushes them away from the sun, out of their
// leaves at rest, which rays meet. The near leaf is lit as it is without
// wind, without the dark of meeting itself at rest, also in the light of the
// probes; the half of it the far leaf hides, a metre toward the sun, stays
// in its shadow.
@(test)
a_swaying_canopy_under_a_traced_light_meets_no_leaf_of_its_own_at_rest :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	leaf := gpu.DEFAULT_MATERIAL
	leaf.two_sided = true
	if !testing.expect(t, gpu.materials_set(&f.renderer, {leaf})) {return}
	// The near leaf in the plane x = 0 from 1 to 2 m up; the far one at x = 1 over its half toward +z.
	canopy, made := sheets_mesh(t, f, {{corner = {0, 1, 1}, across = {0, 0, -2}, up = {0, 1, 0}, cells = 8}, {corner = {1, 1, 1.2}, across = {0, 0, -1.2}, up = {0, 1.4, 0}, cells = 4}})
	if !made {return}
	desc := swaying_desc(f, canopy, 0.6, 2.5)
	desc.material = 1
	if !testing.expect(t, desc.sway > 0, "a canopy of 2.5 m casts swaying shadows") {return}
	_, problem := render.batch_set(&f.renderer, f.resident.world, 0, desc, {render.batch_instance({0, 0, 0}, 1, 1)})
	if !testing.expect(t, problem == "", problem) {return}
	camera := gpu.Camera{position = {3, 1.5, -3}, forward = {-3, 0, 3}, up = {0, 1, 0}, projection = .Orthographic, height = 3, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	sun := [3]f32{-1, -0.3, 0}
	light: [2][2]i32
	for speed, k in ([2]f32{0, 20}) {
		if !wind_blow(t, f, speed) {return}
		pixels, ok := view_frames(t, f, camera, sun, 8)
		if !ok {return}
		defer delete(pixels)
		// The leaf leans 0.07 rad: its points move some 11 cm, rays meet nothing of it within 23.
		light[k] = {seen_at(f, pixels, camera, {0, 1.6, -0.5}), seen_at(f, pixels, camera, {0, 1.4, 0.5})}
	}
	still, windy := light[0], light[1]
	testing.expectf(t, still[0] > 0 && windy[0] * 10 > still[0] * 9, "the lit half of the near leaf is %d in the wind, %d still", windy[0], still[0])
	testing.expectf(t, windy[1] * 2 < windy[0], "the half the far leaf hides stays in its shadow: %d against %d", windy[1], windy[0])
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
			gpu.scene_set_environment(&f.renderer, {direction = {0.3, -1, -0.6}, color = {1, 1, 1}, illuminance = 3}, {sky = {0.4, 0.5, 0.6}})
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
