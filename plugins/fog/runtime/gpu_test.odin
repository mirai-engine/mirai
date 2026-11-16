package fog

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:path/filepath"
import "core:testing"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:host"
import gpu "mirai:render"
import "mirai:render/abi"
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
fog_frame :: proc(t: ^testing.T, f: ^Gpu_Fixture, camera: gpu.Camera, seconds: f32, fogs: []Fog_Volume, places: []volume.Volume, poses: []mm.Transform, cut := false, outlines: [][]mm.Path_Point = nil) {
	f.state.count, f.state.outlines.count = 0, {}
	for fog, i in fogs {volume_gpu(&f.state, fog, places[i], poses[i], outlines != nil ? outlines[i] : nil)}
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
	gpu.scene_set_environment(r,{direction = linalg.normalize([3]f32{0.4, 0.5, 0.6}), color = {1, 1, 1}, illuminance = 2 * math.PI, enabled = true, indirect = 1, scattering = 1},{sky = {0.3, 0.4, 0.6}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, -2000}, {8000, 0.2, 8000}), tint = {0.02, 0.02, 0.02}}},true)
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

// With no light at all, a fog that absorbs everything it stops shows its
// glow where it is thick, in the grid and past it, with the hue of its glow;
// without a glow it is black.
@(test)
a_fog_shows_its_glow_without_any_light :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r, {}, {})
	gpu.scene_update(r, 0, {{object_id = 1, mesh = f.cube, transform = trs({0, 0, -400}, {800, 800, 1}), tint = {0, 0, 0}}}, true)
	camera := gpu.Camera{position = {0, 0, 0}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, exposure = gpu.UNIT_EXPOSURE}
	places := []volume.Volume{volume.box({300, 300, 250})}
	poses := []mm.Transform{{position = {0, 0, -150}, rotation = 1, scale = 1}}
	centre :: proc(image: Image, x, y: int) -> [3]f32 {
		i := (y * image.width + x) * 4
		return {f32(image.pixels[i]), f32(image.pixels[i + 1]), f32(image.pixels[i + 2])}
	}
	shown: [2][3]f32
	for glow, k in ([2][3]f32{{0.2, 0, 1}, {}}) {
		fogs := []Fog_Volume{{density = 0.02, glow = glow}}
		for i in 0 ..< 30 {fog_frame(t, f, camera, f32(i) / 60, fogs, places, poses, cut = i == 0)}
		image, ok := capture(t, f)
		if !ok {return}
		defer delete(image.pixels)
		shown[k] = centre(image, WIDTH / 2, HEIGHT / 2)
	}
	lit := shown[0]
	testing.expectf(t, lit.b > 60 && lit.b > lit.r + 20 && lit.r > lit.g + 10, "the glow shows with its hue, blue over red over green: %v", lit)
	testing.expectf(t, max(shown[1].r, shown[1].g, shown[1].b) < 3, "without a glow the fog shows nothing: %v", shown[1])
	expect_clean(t, f.device)
}

// Looking down at a dark ground through a fog in an L outline: the L is fogged, its notch, inside the
// box of the outline, is as clear as the ground without the fog.
@(test)
fog_in_an_outline_fills_its_loop_and_not_its_box :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r,{direction = linalg.normalize([3]f32{0.4, 0.5, 0.6}), color = {1, 1, 1}, illuminance = 2 * math.PI, enabled = true, indirect = 1, scattering = 1},{sky = {0.3, 0.4, 0.6}})
	gpu.scene_update(r,0,{{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {200, 0.2, 200}), tint = {0.02, 0.02, 0.02}}},true)
	HIGH :: f32(30)
	camera := gpu.Camera{position = {0, HIGH, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.1, exposure = gpu.UNIT_EXPOSURE}
	l := []mm.Path_Point{{position = {-8, 0, -8}}, {position = {8, 0, -8}}, {position = {8, 0, 0}}, {position = {0, 0, 0}}, {position = {0, 0, 8}}, {position = {-8, 0, 8}}}
	dense := Fog_Volume{density = 0.3, color = {1, 1, 1}}
	frames :: proc(t: ^testing.T, f: ^Gpu_Fixture, camera: gpu.Camera, fogs: []Fog_Volume, l: []mm.Path_Point) -> (image: Image, ok: bool) {
		for i in 0 ..< 20 {fog_frame(t, f, camera, f32(i) / 60, fogs, {volume.outline(10)}, {{position = {0, 2, 0}, rotation = 1, scale = 1}}, outlines = {l})}
		return capture(t, f)
	}
	clear, clear_ok := frames(t, f, camera, {}, l)
	if !clear_ok {return}
	defer delete(clear.pixels)
	fogged, fogged_ok := frames(t, f, camera, {dense}, l)
	if !fogged_ok {return}
	defer delete(fogged.pixels)
	// A place of the ground in the image: +X to the right, +Z down.
	at :: proc(x, z: f32) -> (low, high: [2]int) {
		scale := f32(HEIGHT / 2) / (HIGH * math.tan(math.to_radians(f32(30))))
		p := [2]int{WIDTH / 2 + int(x * scale), HEIGHT / 2 + int(z * scale)}
		return p - 2, p + 2
	}
	in_l, in_l_high := at(-4, -4)
	notch, notch_high := at(4, 4)
	testing.expectf(t, block(fogged, in_l, in_l_high) > block(clear, in_l, in_l_high) + 8, "the L is fogged: %.1f, clear %.1f", block(fogged, in_l, in_l_high), block(clear, in_l, in_l_high))
	testing.expectf(t, difference(fogged, clear, notch, notch_high) < 1, "the notch is clear: %.1f apart", difference(fogged, clear, notch, notch_high))
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
	gpu.scene_set_environment(r,{direction = linalg.normalize([3]f32{0.5, 0.6, 0.4}), color = {1, 1, 1}, illuminance = 3 * math.PI, enabled = true, indirect = 1, scattering = 1},{sky = {0.05, 0.06, 0.08}})
	gpu.scene_update(r,0,{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {80, 0.2, 80}), tint = {0.05, 0.05, 0.05}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 6, -14}, {40, 12, 0.5}), tint = {0.02, 0.02, 0.02}},
	},true)
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
	gpu.scene_set_environment(r,{direction = linalg.normalize([3]f32{0.6, 0.5, 0.3}), color = {1, 1, 1}, illuminance = 3 * math.PI, enabled = true, indirect = 1, scattering = 1},{sky = {0.02, 0.02, 0.02}})
	gpu.scene_update(r,0,{wall, pane},true)
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

// A fog in front of a black wall shows what of the light of the sun and of a
// lamp it scatters by the share of each that media scatter: none of a light
// whose share is 0, more of one whose share is 2 than of one whose share is 1.
@(test)
fog_scatters_the_share_of_each_light :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	wall := gpu.Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, 0, -30}, {200, 200, 1}), tint = {0, 0, 0}}
	gpu.scene_update(r, 0, {wall}, true)
	camera := gpu.Camera{position = {0, 0, 0}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 200, exposure = gpu.UNIT_EXPOSURE}
	haze := Fog_Volume{density = 0.25, color = {1, 1, 1}}
	places := []volume.Volume{{shape = .Box, extents = {0.5, 0.5, 0.5}}}
	poses := []mm.Transform{{position = {0, 0, -6}, rotation = 1, scale = {60, 60, 8}}}
	low, high := [2]int{WIDTH / 2 - 12, HEIGHT / 2 - 12}, [2]int{WIDTH / 2 + 12, HEIGHT / 2 + 12}
	for lamp in ([]bool{false, true}) {
		seen: [3]f32
		for share, i in ([3]f32{0, 1, 2}) {
			sun := gpu.Sun_Desc{direction = linalg.normalize([3]f32{0.6, 0.5, 0.3}), color = {1, 1, 1}, illuminance = 2 * math.PI, enabled = !lamp, indirect = 1, scattering = share}
			gpu.scene_set_environment(r, sun, {sky = {0.002, 0.002, 0.002}})
			if lamp {
				gpu.scene_light_update(r, 0, {position = {0, 0, -6}, color = {1, 1, 1}, intensity = 6 * math.PI, range = 20, radius = 0.05, indirect = 1, scattering = share})
			} else if len(r.scene.lights) > 0 {
				gpu.scene_light_remove(r, 0)
			}
			for frame in 0 ..< 20 {fog_frame(t, f, camera, f32(frame) / 60, {haze}, places, poses, cut = frame == 0)}
			image, ok := capture(t, f)
			if !ok {return}
			c := channels(image, low, high)
			delete(image.pixels)
			seen[i] = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
		}
		what := "the lamp" if lamp else "the sun"
		testing.expectf(t, seen[1] > 30 && seen[0] < 0.2 * seen[1], "%s lights the fog by its share: %.1f with none, %.1f with all", what, seen[0], seen[1])
		testing.expectf(t, seen[2] > seen[1] + 5, "%s lights the fog more with twice its share: %.1f, not above %.1f", what, seen[2], seen[1])
	}
	expect_clean(t, f.device)
}

// A closed hall far longer than the grid, with the sun outside and a fog
// inside: the fog past the grid scatters none of the sun the roof hides, as
// the fog in it, and looks as it does with a sun media do not scatter; with
// the roof off, the same fog past the grid shows the sun.
@(test)
fog_past_the_grid_scatters_no_sun_the_scene_hides :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	LONG :: f32(400)
	dark := [3]f32{0, 0, 0}
	walls := [6]gpu.Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.5, -LONG / 2}, {44, 1, LONG + 14}), tint = dark},
		{object_id = 2, mesh = f.cube, transform = trs({-20.5, 15, -LONG / 2}, {1, 32, LONG + 14}), tint = dark},
		{object_id = 3, mesh = f.cube, transform = trs({20.5, 15, -LONG / 2}, {1, 32, LONG + 14}), tint = dark},
		{object_id = 4, mesh = f.cube, transform = trs({0, 15, -LONG - 0.5}, {44, 32, 1}), tint = dark},
		{object_id = 5, mesh = f.cube, transform = trs({0, 15, 5.5}, {44, 32, 1}), tint = dark},
		{object_id = 6, mesh = f.cube, transform = trs({0, 30.5, -LONG / 2}, {44, 1, LONG + 14}), tint = dark},
	}
	camera := gpu.Camera{position = {0, 15, 0}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 1000, exposure = gpu.UNIT_EXPOSURE}
	haze := Fog_Volume{density = 0.004, color = {1, 1, 1}}
	places := []volume.Volume{volume.box({0.5, 0.5, 0.5})}
	poses := []mm.Transform{{position = {0, 15, -LONG / 2 + 2.5}, rotation = 1, scale = {39.8, 29.8, LONG + 4.8}}}
	low, high := [2]int{WIDTH / 2 - 6, HEIGHT / 2 - 6}, [2]int{WIDTH / 2 + 6, HEIGHT / 2 + 6}
	// Under the roof with the sun, under it with a sun media do not scatter, and open with the sun.
	cases := [3]struct {roofed: bool, share: f32}{{true, 1}, {true, 0}, {false, 1}}
	seen: [3]f32
	for c, k in cases {
		gpu.scene_set_environment(r,{direction = linalg.normalize([3]f32{0.3, 0.9, 0.2}), color = {1, 1, 1}, illuminance = 3 * math.PI, enabled = true, indirect = 1, scattering = c.share},{})
		gpu.scene_update(r, 0, walls[:c.roofed ? 6 : 5], true)
		for i in 0 ..< 30 {fog_frame(t, f, camera, f32(i) / 60, {haze}, places, poses, cut = i == 0)}
		image, ok := capture(t, f)
		if !ok {return}
		seen[k] = block(image, low, high)
		delete(image.pixels)
		// Its cells marked the pages of the maps of the sun they read, which the next frame draws.
		if c.share > 0 {
			marks := make([]u32, abi.SHADOW_SUN_MAPS * abi.SHADOW_MASK_WORDS, context.temp_allocator)
			testing.expect(t, rhi.buffer_read_slice(f.device, r.main.targets.shadow_raster.pages, u64(abi.SHADOW_WORDS_LATE) * 4, marks))
			marked := 0
			for word in marks {marked += int(word != 0)}
			testing.expectf(t, marked > 0, "case %d: the fog marks the pages of the sun it reads", k)
		}
	}
	shown := seen[2] - seen[1]
	testing.expectf(t, shown > 30, "with the roof off, the fog down the hall shows the sun: %.1f, %.1f without it", seen[2], seen[1])
	testing.expectf(t, abs(seen[0] - seen[1]) < 0.03 * shown, "under the roof, the fog down the hall past the grid scatters no sun: %.1f, %.1f without it, open %.1f", seen[0], seen[1], seen[2])
	expect_clean(t, f.device)
}

// The light of the cells of the grid as the last frame left it (fog_light),
// rgb of each and a, as floats; nil without it.
@(private = "file")
fog_light_read :: proc(t: ^testing.T, f: ^Gpu_Fixture) -> [][4]f32 {
	rhi.device_wait_idle(f.device)
	key := base.name_hash("fog light") | 1
	for entry in f.renderer.main.extension_textures {
		if entry.key != key {continue}
		halves := make([][4]f16, int(entry.desc.width * entry.desc.height * max(entry.desc.depth, 1)), context.temp_allocator)
		if !testing.expect(t, rhi.texture_read(f.device, entry.textures[entry.asked % 2], mem.slice_to_bytes(halves)), rhi.device_error(f.device)) {return nil}
		light := make([][4]f32, len(halves), context.temp_allocator)
		for h, i in halves {light[i] = {f32(h.x), f32(h.y), f32(h.z), f32(h.w)}}
		return light
	}
	testing.expect(t, false, "the fog has its light")
	return nil
}

// A still fog lit by three lamps, with shadows and without, that scatters
// forward, where each lamp gives a cell more or less by where the eye looks
// from: from the frame the lamps turn on, within a few frames each cell takes
// what each lamp gives it alone, added up (no lamp dropped, no light that
// leaks), and keeps it from frame to frame, with no light that comes and goes.
@(test)
fog_cells_take_what_each_light_gives_them_and_hold_it :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	wall := gpu.Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, 0, -30}, {200, 200, 1}), tint = {0, 0, 0}}
	gpu.scene_update(r, 0, {wall}, true)
	gpu.scene_set_environment(r, {}, {})
	camera := gpu.Camera{position = {0, 0, 0}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 200, exposure = gpu.UNIT_EXPOSURE}
	haze := Fog_Volume{density = 0.1, color = {1, 1, 1}, anisotropy = 0.6}
	places := []volume.Volume{{shape = .Box, extents = {0.5, 0.5, 0.5}}}
	poses := []mm.Transform{{position = {0, 0, -6}, rotation = 1, scale = {20, 20, 12}}}
	lamps := [3][3]f32{{-2, 1, -5}, {2.5, -0.5, -7}, {0.5, 2, -9}}
	FRAMES :: 40
	// The most a cell with a medium of a differs from b, against b.
	apart :: proc(a, b: [][4]f32) -> (worst: f32) {
		for cell, i in b {
			if a[i].a < 1 || cell.a < 1 || cell.g < 1e-3 {continue}
			worst = max(worst, linalg.max(linalg.abs(a[i].rgb - cell.rgb) / cell.rgb))
		}
		return
	}
	for shadowless in ([2]bool{false, true}) {
		alone: [3][][4]f32
		seen: [FRAMES][][4]f32
		// Each lamp alone, none, then the three, turned on together.
		for run in 0 ..= 4 {
			for len(r.scene.lights) > 0 {gpu.scene_light_remove(r, 0)}
			for lamp, i in lamps {
				if run == 3 || run < 3 && i != run {continue}
				gpu.scene_light_update(r, u32(len(r.scene.lights)), {position = lamp, color = {1, 0.9, 0.8}, intensity = 4 * math.PI, range = 12, radius = 0.05, indirect = 1, scattering = 1, shadowless = shadowless})
			}
			for frame in 0 ..< FRAMES {
				fog_frame(t, f, camera, 0, {haze}, places, poses, cut = frame == 0 && run < 4)
				if run < 4 && frame + 1 < FRAMES {continue}
				seen[frame] = fog_light_read(t, f)
				if seen[frame] == nil {return}
			}
			if run < 3 {alone[run] = seen[FRAMES - 1]}
		}
		sum := make([][4]f32, len(alone[0]), context.temp_allocator)
		lit := 0
		for &cell, i in sum {
			cell = {alone[0][i].r + alone[1][i].r + alone[2][i].r, alone[0][i].g + alone[1][i].g + alone[2][i].g, alone[0][i].b + alone[1][i].b + alone[2][i].b, alone[0][i].a}
			lit += int(cell.a >= 1 && cell.g >= 1e-3)
		}
		what := "without shadows" if shadowless else "with shadows"
		testing.expectf(t, lit > 1000, "%s: the lamps light %d cells", what, lit)
		settled := -1
		for k in 0 ..< FRAMES {
			if apart(seen[k], sum) < 0.03 {settled = k + 1;break}
		}
		testing.expectf(t, settled >= 0 && settled <= 4, "%s: a cell takes what each lamp gives it alone, added up, %d frames after they turn on (%.3f apart then, %.3f at last)", what, settled, apart(seen[0], sum), apart(seen[FRAMES - 1], sum))
		flicker: f32
		for k in FRAMES - 10 ..< FRAMES {flicker = max(flicker, apart(seen[k], seen[k - 1]))}
		testing.expectf(t, flicker < 0.01, "%s: a cell keeps its light from frame to frame, %.4f apart at most", what, flicker)
		free_all(context.temp_allocator)
	}
	expect_clean(t, f.device)
}
