package fog

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:testing"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import mm "mirai:std/math"

// The passes of the plugin on the GPU, with the shaders of the engine and the
// stages of the plugin: a generation into .mirai/tmp of the engine, which the
// tests after the first find up to date.

@(private = "file")
ROOT :: #directory + "/../../.."

@(private = "file")
Gpu_Fixture :: struct {
	device:   ^rhi.Device,
	renderer: gpu.Renderer,
	assets:   host.Assets,
	app:      host.App,
	cube:     gpu.Mesh_Handle,
	state:    Fog_Gpu,
}

@(private = "file")
WIDTH :: 192
@(private = "file")
HEIGHT :: 128

@(private = "file")
gpu_fixture_init :: proc(t: ^testing.T, f: ^Gpu_Fixture) -> bool {
	root, _ := filepath.clean(ROOT, context.temp_allocator)
	// mirai test generates them: cook is not shipped, and the game compiles its test files.
	output := fmt.tprintf("%s/.mirai/tmp/fog-test-shaders", root)
	loaded, problem := gpu.shader_assets_load(output)
	if !testing.expect(t, problem == "", problem) {return false}
	device := shared_device.take_or_skip(t)
	if device == nil {
		gpu.shader_assets_destroy(&loaded)
		return false
	}
	f.device = device
	settings := gpu.DEFAULT_SETTINGS
	settings.taa = false
	settings.probe_budget = 4096
	settings.probe_rays = 64
	settings.probe_grid, settings.probe_cascades = 8, 2
	settings.probe_spacing = 1.5
	if !testing.expect(t, gpu.renderer_init(&f.renderer, {device = device, width = WIDTH, height = HEIGHT, settings = settings, shaders = &loaded}), f.renderer.error) {return false}
	folder := base.test_folder(t, "fog-gpu")
	if folder == "" || !testing.expect(t, host.assets_init(&f.assets, {root = folder, renderer = &f.renderer})) {return false}
	f.app = host.App{allocator = context.allocator, renderer = &f.renderer, assets = &f.assets, device = device}
	cube := host.assets_shape(&f.assets, .Cube)
	if !testing.expect(t, cube != nil) {return false}
	f.cube = cube.handle
	f.state.hidden = 4
	gpu.scene_world(&f.renderer, 1)
	return true
}

@(private = "file")
gpu_fixture_destroy :: proc(f: ^Gpu_Fixture) {
	if f.device == nil {return}
	host.assets_destroy(&f.assets)
	gpu.renderer_destroy(&f.renderer)
}

@(private = "file")
trs :: proc(position, scale: [3]f32) -> matrix[4, 4]f32 {
	m: matrix[4, 4]f32 = 1
	m[0, 0], m[1, 1], m[2, 2] = scale.x, scale.y, scale.z
	m[0, 3], m[1, 3], m[2, 3] = position.x, position.y, position.z
	return m
}

// One frame of the fog volumes at a time of the world.
@(private = "file")
fog_frame :: proc(t: ^testing.T, f: ^Gpu_Fixture, camera: gpu.Camera, seconds: f32, fogs: []Fog_Volume, places: []volume.Volume, poses: []mm.Transform, cut := false) {
	f.state.count = 0
	for fog, i in fogs {volume_gpu(&f.state, fog, places[i], poses[i])}
	f.app.time = seconds
	fog_submit(&f.state, &f.app)
	testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = camera, time = seconds, camera_cut = cut}), f.renderer.error)
}

@(private = "file")
Image :: struct {
	pixels: []u8,
	width:  int,
}

@(private = "file")
capture :: proc(t: ^testing.T, f: ^Gpu_Fixture) -> (image: Image, ok: bool) {
	rhi.device_wait_idle(f.device)
	pixels, w, _, captured := gpu.renderer_capture(&f.renderer)
	testing.expect(t, captured, f.renderer.error)
	return {pixels, w}, captured
}

@(private = "file")
luma :: proc(image: Image, x, y: int) -> f32 {
	i := (y * image.width + x) * 4
	return 0.2126 * f32(image.pixels[i]) + 0.7152 * f32(image.pixels[i + 1]) + 0.0722 * f32(image.pixels[i + 2])
}

@(private = "file")
expect_clean :: proc(t: ^testing.T, d: ^rhi.Device) {
	testing.expectf(t, rhi.device_validation_errors(d) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(d), rhi.device_validation_message(d))
}

// Looking down at a dark ground under a fog of the whole world, the fog of
// the ground thickens with the distance past the 128 m of the grid, without
// a step where the grid ends: the medium past it goes on in closed form.
@(test)
fog_goes_on_past_the_grid_without_a_seam :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set(r, {{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, -2000}, {8000, 0.2, 8000}), tint = {0.02, 0.02, 0.02}}}, nil, {direction = linalg.normalize([3]f32{0.4, 0.5, 0.6}), color = {1, 1, 1}, illuminance = 2 * math.PI, enabled = true}, {sky = {0.3, 0.4, 0.6}})
	HIGH :: f32(40)
	forward := linalg.normalize([3]f32{0, -0.3, -1})
	camera := gpu.Camera{position = {0, HIGH, 0}, forward = forward, up = {0, 1, 0}, fov_y = 60, near = 0.1, exposure = gpu.UNIT_EXPOSURE}
	haze := Fog_Volume{density = 0.004, color = {1, 1, 1}, anisotropy = 0.3, wisp_size = 3}
	fogs := []Fog_Volume{haze}
	places := []volume.Volume{{shape = .Unbounded}}
	poses := []mm.Transform{{rotation = 1, scale = 1}}
	for i in 0 ..< 40 {fog_frame(t, f, camera, f32(i) / 60, fogs, places, poses)}
	image, ok := capture(t, f)
	if !ok {return}
	defer delete(image.pixels)
	// The view depth of the ground under each row of the middle column.
	right := linalg.normalize(linalg.cross(forward, [3]f32{0, 1, 0}))
	up := linalg.cross(right, forward)
	focal := 1 / math.tan(math.to_radians(f32(30)))
	depths: [HEIGHT]f32
	lumas: [HEIGHT]f32
	for y in 0 ..< HEIGHT {
		ndc_y := 1 - 2 * (f32(y) + 0.5) / HEIGHT
		ray := forward + up * (ndc_y / focal)
		depths[y] = ray.y < -1e-3 ? HIGH / -ray.y : max(f32)
		lumas[y] = 0
		for x in WIDTH / 2 - 2 ..< WIDTH / 2 + 2 {lumas[y] += luma(image, x, y) / 4}
	}
	// Rows from near to far go up the image; the step where the grid ends is no bigger than those around it.
	boundary := -1
	for y in 1 ..< HEIGHT {
		if depths[y] <= render.MEDIA_DISTANCE && depths[y - 1] > render.MEDIA_DISTANCE {boundary = y; break}
	}
	if !testing.expectf(t, boundary > 2 && boundary < HEIGHT - 2, "the ground crosses the end of the grid in the view: %d", boundary) {return}
	step := abs(lumas[boundary - 1] - lumas[boundary])
	around := max(abs(lumas[boundary - 2] - lumas[boundary - 1]), abs(lumas[boundary] - lumas[boundary + 1]))
	testing.expectf(t, step <= around * 1.5 + 2, "the step where the grid ends %.2f must be like those around it %.2f (rows %v)", step, around, lumas[boundary - 3:boundary + 3])
	// Far past the grid the ground is fogged more than where the grid ends.
	far := -1
	for y in 0 ..< HEIGHT {
		if depths[y] < 600 && depths[y] > 400 {far = y; break}
	}
	if testing.expect(t, far >= 0) {
		testing.expectf(t, lumas[far] > lumas[boundary] + 8, "the ground %.0f m away (%.1f) must be foggier than at the end of the grid (%.1f)", depths[far], lumas[far], lumas[boundary])
	}
	// Each row further is foggier.
	for y in far + 1 ..< boundary {
		testing.expectf(t, lumas[y] <= lumas[y - 1] + 1, "row %d (%.0f m) %.1f, row %d %.1f", y, depths[y], lumas[y], y - 1, lumas[y - 1])
	}
	expect_clean(t, f.device)
}

// The mean of a block of rows and columns of the image.
@(private = "file")
block :: proc(image: Image, low, high: [2]int) -> f32 {
	sum, n: f32
	for y in low.y ..< high.y {
		for x in low.x ..< high.x {
			sum += luma(image, x, y)
			n += 1
		}
	}
	return sum / n
}

@(private = "file")
difference :: proc(a, b: Image, low, high: [2]int) -> f32 {
	sum, n: f32
	for y in low.y ..< high.y {
		for x in low.x ..< high.x {
			sum += abs(luma(a, x, y) - luma(b, x, y))
			n += 1
		}
	}
	return sum / n
}

// A variable volume lit by the sun: its wisps vary where a homogeneous one
// of the same density is even, about as much fog on the whole, and they
// drift. What the history keeps is the light alone: after a second of
// drifting the image is the one a view without history draws at that time.
@(test)
fog_wisps_vary_drift_and_leave_no_trail :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set(r, {
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {80, 0.2, 80}), tint = {0.05, 0.05, 0.05}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 6, -14}, {40, 12, 0.5}), tint = {0.02, 0.02, 0.02}},
	}, nil, {direction = linalg.normalize([3]f32{0.5, 0.6, 0.4}), color = {1, 1, 1}, illuminance = 3 * math.PI, enabled = true}, {sky = {0.05, 0.06, 0.08}})
	camera := gpu.Camera{position = {0, 2, 10}, forward = {0, -0.05, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 200, exposure = gpu.UNIT_EXPOSURE}
	// A slab across the view: what the eye sees of it crosses a wisp or two.
	even := FOG_VOLUME_DEFAULT
	even.density, even.anisotropy = 0.3, 0.3
	varied := even
	varied.variable = true
	places := []volume.Volume{{shape = .Box, extents = {0.5, 0.5, 0.5}}}
	poses := []mm.Transform{{position = {0, 3, -2}, rotation = 1, scale = {24, 6, 2}}}
	DT :: f32(1.0 / 60)
	low, high := [2]int{WIDTH / 8, HEIGHT / 3}, [2]int{WIDTH * 7 / 8, HEIGHT * 2 / 3}
	for i in 0 ..< 30 {fog_frame(t, f, camera, f32(i) * DT, {even}, places, poses)}
	plain, plain_ok := capture(t, f)
	if !plain_ok {return}
	defer delete(plain.pixels)
	seconds := f32(100)
	for i in 0 ..< 30 {fog_frame(t, f, camera, seconds + f32(i) * DT, {varied}, places, poses, cut = i == 0)}
	seconds += 29 * DT
	first, first_ok := capture(t, f)
	if !first_ok {return}
	defer delete(first.pixels)
	plain_mean := block(plain, low, high)
	mean := block(first, low, high)
	varies := difference(plain, first, low, high)
	testing.expectf(t, varies > 2, "the wisps are thicker and thinner than an even fog here and there: %.2f", varies)
	testing.expectf(t, abs(mean - plain_mean) < 0.15 * plain_mean, "about as much fog on the whole: %.1f against %.1f", mean, plain_mean)
	for i in 1 ..= 60 {fog_frame(t, f, camera, seconds + f32(i) * DT, {varied}, places, poses)}
	seconds += 60 * DT
	later, later_ok := capture(t, f)
	if !later_ok {return}
	defer delete(later.pixels)
	moved := difference(first, later, low, high)
	testing.expectf(t, moved > 1, "a second later the wisps moved: %.2f", moved)
	// The same time again with no history.
	fog_frame(t, f, camera, seconds, {varied}, places, poses, cut = true)
	fresh, fresh_ok := capture(t, f)
	if !fresh_ok {return}
	defer delete(fresh.pixels)
	trail := difference(later, fresh, low, high)
	testing.expectf(t, trail < 0.25 * moved, "what the history kept leaves no trail: %.2f against the %.2f the wisps moved", trail, moved)
	expect_clean(t, f.device)
}

// The mean of each channel over a block of the image.
@(private = "file")
channels :: proc(image: Image, low, high: [2]int) -> (mean: [3]f32) {
	n: f32
	for y in low.y ..< high.y {
		for x in low.x ..< high.x {
			i := (y * image.width + x) * 4
			mean += {f32(image.pixels[i]), f32(image.pixels[i + 1]), f32(image.pixels[i + 2])}
			n += 1
		}
	}
	return mean / n
}

// A pane of blue glass before a black wall: the fog between the eye and the
// pane goes over the glass, as white as beside it, and the fog between the
// pane and the wall comes through the glass, blue.
@(test)
fog_in_front_of_glass_goes_over_it :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	blue := gpu.DEFAULT_MATERIAL
	blue.base_color, blue.alpha_mode, blue.roughness, blue.transmission = {0.02, 0.02, 1}, .Blend, 0.05, 1
	gpu.materials_set(r, {blue})
	wall := gpu.Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, 0, -30}, {200, 200, 1}), tint = {0, 0, 0}}
	pane := gpu.Instance_Desc{object_id = 2, mesh = f.cube, transform = trs({0, 0, -6}, {4, 4, 0.05}), material = 1, tint = {1, 1, 1}}
	gpu.scene_set(r, {wall, pane}, nil, {direction = linalg.normalize([3]f32{0.6, 0.5, 0.3}), color = {1, 1, 1}, illuminance = 3 * math.PI, enabled = true}, {sky = {0.02, 0.02, 0.02}})
	camera := gpu.Camera{position = {0, 0, 0}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 200, exposure = gpu.UNIT_EXPOSURE}
	haze := Fog_Volume{density = 0.25, color = {1, 1, 1}}
	places := []volume.Volume{{shape = .Box, extents = {0.5, 0.5, 0.5}}}
	through_low, through_high := [2]int{WIDTH / 2 - 6, HEIGHT / 2 - 6}, [2]int{WIDTH / 2 + 6, HEIGHT / 2 + 6}
	beside_low, beside_high := [2]int{WIDTH * 7 / 8, HEIGHT / 2 - 6}, [2]int{WIDTH - 4, HEIGHT / 2 + 6}
	// From the eye to just in front of the pane, and from just behind it to the wall.
	in_front := []mm.Transform{{position = {0, 0, -2.4}, rotation = 1, scale = {60, 60, 6.8}}}
	behind := []mm.Transform{{position = {0, 0, -18}, rotation = 1, scale = {60, 60, 23.6}}}
	for poses, side in ([2][]mm.Transform{in_front, behind}) {
		for i in 0 ..< 20 {fog_frame(t, f, camera, f32(i) / 60, {haze}, places, poses, cut = i == 0)}
		image, ok := capture(t, f)
		if !ok {return}
		defer delete(image.pixels)
		beside, through := channels(image, beside_low, beside_high), channels(image, through_low, through_high)
		if !testing.expectf(t, beside.r > 40, "the fog beside the pane shows: %v", beside) {continue}
		if side == 0 {
			testing.expectf(t, through.r > 0.8 * beside.r && through.g > 0.8 * beside.g, "the fog in front of the glass is not filtered by it: %v through, %v beside", through, beside)
		} else {
			testing.expectf(t, through.r < 0.25 * beside.r && through.b > 2 * through.r, "the fog behind the glass comes through its filter: %v through, %v beside", through, beside)
		}
	}
	expect_clean(t, f.device)
}
