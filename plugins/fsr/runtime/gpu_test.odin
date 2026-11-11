package fsr

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:testing"
import render "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"

// The passes of FSR 3.1 on the GPU, with the shaders of the engine and the
// stages of the plugin that mirai test generates into .mirai/tmp: what they
// make of a scene against what the renderer makes without them.

@(private = "file")
ROOT :: #directory + "/../../.."

@(private = "file")
WIDTH :: 256
@(private = "file")
HEIGHT :: 160

@(private = "file")
Gpu_Fixture :: struct {
	device:   ^rhi.Device,
	renderer: gpu.Renderer,
	assets:   host.Assets,
	app:      host.App,
	cube:     gpu.Mesh_Handle,
	fsr:      Fsr_Runtime,
}

@(private = "file")
gpu_fixture_init :: proc(t: ^testing.T, f: ^Gpu_Fixture) -> bool {
	root, _ := filepath.clean(ROOT, context.temp_allocator)
	loaded, problem := gpu.shader_assets_load(fmt.tprintf("%s/.mirai/tmp/fsr-test-shaders", root))
	if !testing.expect(t, problem == "", problem) {return false}
	device := shared_device.take_or_skip(t)
	if device == nil {
		gpu.shader_assets_destroy(&loaded)
		return false
	}
	f.device = device
	// Without the probes and their rays the image is the same from one frame
	// to the next; without the shadows of the sun no lit pixel is black.
	settings := gpu.DEFAULT_SETTINGS
	settings.gi_enabled, settings.sun_shadows = false, false
	if !testing.expect(t, gpu.renderer_init(&f.renderer, {device = device, width = WIDTH, height = HEIGHT, settings = settings, shaders = &loaded}), f.renderer.error) {return false}
	folder := base.test_folder(t, "fsr-gpu")
	if folder == "" || !testing.expect(t, host.assets_init(&f.assets, {root = folder, renderer = &f.renderer})) {return false}
	f.app = host.App{allocator = context.allocator, renderer = &f.renderer, assets = &f.assets, device = device}
	cube := host.assets_shape(&f.assets, .Cube)
	if !testing.expect(t, cube != nil) {return false}
	f.cube = cube.handle
	gpu.scene_world(&f.renderer, 1)
	gpu.scene_set_environment(&f.renderer, {direction = {0.2, 0.3, 1}, color = {1, 1, 1}, illuminance = math.PI, enabled = true}, {sky = {0.05, 0.05, 0.05}})
	return true
}

@(private = "file")
gpu_fixture_destroy :: proc(f: ^Gpu_Fixture) {
	if f.device == nil {return}
	host.assets_destroy(&f.assets)
	gpu.renderer_destroy(&f.renderer)
}

// A box of size at position, turned by angle radians about the view axis.
@(private = "file")
box :: proc(position, size: [3]f32, angle: f32 = 0) -> matrix[4, 4]f32 {
	c, s := math.cos(angle), math.sin(angle)
	m: matrix[4, 4]f32 = 1
	m[0, 0], m[0, 1] = c * size.x, -s * size.y
	m[1, 0], m[1, 1] = s * size.x, c * size.y
	m[2, 2] = size.z
	m[0, 3], m[1, 3], m[2, 3] = position.x, position.y, position.z
	return m
}

@(private = "file")
CAMERA :: gpu.Camera{position = {0, 0, 0}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 100, exposure = gpu.UNIT_EXPOSURE}

// The views draw the scene at lines of the HEIGHT of the window: fewer upscale it.
@(private = "file")
draw_at :: proc(t: ^testing.T, f: ^Gpu_Fixture, lines: u32, taa: bool) {
	settings := f.renderer.settings
	settings.resolution, settings.taa = lines, taa
	testing.expect(t, gpu.renderer_apply_settings(&f.renderer, settings), f.renderer.error)
}

// One frame, drawn by FSR 3.1 when fsr: it offers itself, the settings name
// it and generate asks it for frames.
@(private = "file")
frame :: proc(t: ^testing.T, f: ^Gpu_Fixture, index: int, fsr, generate: bool) {
	if fsr {
		graphics := render.GRAPHICS_SETTINGS_DEFAULT
		base.text_set(graphics.antialiasing[:], FSR3_NAME)
		graphics.frame_generation = generate
		fsr_render(&f.fsr, graphics, FSR_SETTINGS_DEFAULT, &f.app)
		testing.expect(t, f.fsr.pipelines[.Accumulate_Sharpen] != 0 && (!generate || f.fsr.framegen[.Fi_Interpolation] != 0), "the shaders of the plugin have the stages of FSR 3.1")
	}
	testing.expect(t, gpu.renderer_frame(&f.renderer, {camera = CAMERA, time = f32(index) / 60, camera_cut = index == 0}), f.renderer.error)
}

@(private = "file")
Image :: struct {
	pixels:        []u8,
	width, height: int,
}

@(private = "file")
capture :: proc(t: ^testing.T, f: ^Gpu_Fixture) -> Image {
	rhi.device_wait_idle(f.device)
	pixels, w, h, ok := gpu.renderer_capture(&f.renderer, context.temp_allocator)
	testing.expect(t, ok, f.renderer.error)
	return {pixels, w, h}
}

// The image the frame generated, shown before its own: the presenter of a
// window takes it, which a test without one reads from the target.
@(private = "file")
capture_generated :: proc(t: ^testing.T, f: ^Gpu_Fixture) -> Image {
	rhi.device_wait_idle(f.device)
	targets := &f.renderer.main.targets
	if !testing.expect(t, f.renderer.main.generated && targets.generated != 0, "the last frame generated an image") {return {}}
	pixels := make([]u8, int(targets.output_width) * int(targets.output_height) * 4, context.temp_allocator)
	testing.expect(t, rhi.texture_read(f.device, targets.generated, pixels), rhi.device_error(f.device))
	return {pixels, int(targets.output_width), int(targets.output_height)}
}

@(private = "file")
luma :: proc(image: Image, i: int) -> f32 {
	p := image.pixels[i * 4:]
	return 0.2126 * f32(p[0]) + 0.7152 * f32(p[1]) + 0.0722 * f32(p[2])
}

// The mean absolute difference of the luma of two images of the same size, 0 to 255.
@(private = "file")
difference :: proc(a, b: Image) -> f32 {
	total: f32
	for i in 0 ..< a.width * a.height {total += abs(luma(a, i) - luma(b, i))}
	return total / f32(a.width * a.height)
}

@(private = "file")
expect_clean :: proc(t: ^testing.T, d: ^rhi.Device) {
	testing.expectf(t, rhi.device_validation_errors(d) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(d), rhi.device_validation_message(d))
}

// Thin bright bars at an angle, thinner than a pixel of the image drawn at
// half the lines, over a dark wall: FSR 3.1 accumulates the jittered frames
// at half the lines into an image of the size of the window closer to the
// scene drawn at its whole size (with the TAA, converged) than the bilinear
// upscale of one frame at half the lines is, without black or NaN pixels.
@(test)
fsr_upscales_fine_detail_closer_to_the_whole_resolution_than_bilinear :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	// At 4 m a pixel of the window is 2.9 cm: the bars are 3.5 cm wide, 17 cm apart.
	BARS :: 44
	instances: [BARS + 1]gpu.Instance_Desc
	instances[0] = {object_id = 1, mesh = f.cube, transform = box({0, 0, -5}, {20, 20, 0.2}), tint = {0.05, 0.05, 0.05}}
	for i in 0 ..< BARS {
		x := (f32(i) - BARS / 2) * 0.17
		instances[i + 1] = {object_id = u64(i + 2), mesh = f.cube, transform = box({x, 0, -4}, {0.035, 6, 0.035}, 0.44), tint = {0.9, 0.9, 0.9}}
	}
	gpu.scene_update(&f.renderer, 0, instances[:], true)
	FRAMES :: 64

	draw_at(t, f, HEIGHT, true)
	for i in 0 ..< FRAMES {frame(t, f, i, false, false)}
	whole := capture(t, f)

	draw_at(t, f, HEIGHT / 2, false)
	frame(t, f, 0, false, false)
	bilinear := capture(t, f)
	testing.expectf(t, f.renderer.main.targets.width == WIDTH / 2, "the scene is drawn at half the width: %d", f.renderer.main.targets.width)

	draw_at(t, f, HEIGHT / 2, true)
	for i in 0 ..< FRAMES {frame(t, f, i, true, false)}
	upscaled := capture(t, f)
	if !testing.expectf(t, upscaled.width == WIDTH && upscaled.height == HEIGHT && f.renderer.main.targets.width == WIDTH / 2, "FSR shows %dx%d drawn at %d wide", upscaled.width, upscaled.height, f.renderer.main.targets.width) {return}

	black, mean_whole, mean_upscaled := 0, f32(0), f32(0)
	for i in 0 ..< WIDTH * HEIGHT {
		if luma(upscaled, i) < 2 {black += 1}
		mean_whole += luma(whole, i) / (WIDTH * HEIGHT)
		mean_upscaled += luma(upscaled, i) / (WIDTH * HEIGHT)
	}
	testing.expectf(t, black == 0, "%d pixels of the image FSR upscales are black or NaN; the wall is lit", black)
	testing.expectf(t, abs(mean_upscaled - mean_whole) < 0.1 * mean_whole, "the mean luma of FSR %.1f, of the whole resolution %.1f", mean_upscaled, mean_whole)
	from_fsr, from_bilinear := difference(upscaled, whole), difference(bilinear, whole)
	testing.expectf(t, from_fsr < 0.7 * from_bilinear, "against the whole resolution FSR differs by %.2f, the bilinear upscale by %.2f", from_fsr, from_bilinear)
	expect_clean(t, f.device)
}

// The centroid of the bright pixels of an image.
@(private = "file")
centroid :: proc(image: Image) -> (at: [2]f32, count: int) {
	for y in 0 ..< image.height {
		for x in 0 ..< image.width {
			if luma(image, y * image.width + x) > 128 {at += {f32(x), f32(y)}; count += 1}
		}
	}
	if count > 0 {at /= f32(count)}
	return
}

// A bright box that crosses a dark wall at a steady speed: the image FSR 3.1
// generates between the last two frames shows it between where each of them
// does, about halfway, and is neither of them.
@(test)
fsr_generates_the_frame_between_two_frames :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	draw_at(t, f, HEIGHT, true)
	FRAMES :: 16
	// 30 cm a frame at 4 m: about 10 pixels.
	STEP :: f32(0.3)
	before: Image
	for i in 0 ..< FRAMES {
		x := (f32(i) - FRAMES / 2) * STEP
		gpu.scene_update(&f.renderer, 0, {
			{object_id = 1, mesh = f.cube, transform = box({0, 0, -5}, {20, 20, 0.2}), tint = {0.05, 0.05, 0.05}},
			{object_id = 2, mesh = f.cube, transform = box({x, 0, -4}, {0.5, 0.5, 0.5}), tint = {0.9, 0.9, 0.9}},
		}, true)
		frame(t, f, i, true, true)
		if i == FRAMES - 2 {before = capture(t, f)}
	}
	after := capture(t, f)
	generated := capture_generated(t, f)
	if generated.pixels == nil {return}
	a, a_count := centroid(before)
	b, b_count := centroid(after)
	g, g_count := centroid(generated)
	if !testing.expectf(t, a_count > 0 && b_count > 0 && g_count > 0, "the box shows in each image: %d, %d, %d pixels", a_count, b_count, g_count) {return}
	moved := b.x - a.x
	if !testing.expectf(t, moved > 5, "the box moves to the right between the frames: %.1f pixels", moved) {return}
	middle := (a + b) / 2
	testing.expectf(t, abs(g.x - middle.x) < 0.25 * moved && abs(g.y - middle.y) < 2, "the generated box is at %v, halfway between %v and %v", g, a, b)
	testing.expectf(t, difference(generated, before) > 0.5 && difference(generated, after) > 0.5, "the generated image is neither frame: it differs from them by %.2f and %.2f", difference(generated, before), difference(generated, after))
	expect_clean(t, f.device)
}
