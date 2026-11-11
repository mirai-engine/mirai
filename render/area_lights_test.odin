package mirai_render

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import stbi "vendor:stb/image"
import "core:testing"
import "mirai:rhi"

@(private)
Area_Fixture :: struct {
	using base: Fixture,
	cube:       Mesh_Handle,
	camera:     Camera,
}

@(private)
area_init :: proc(t: ^testing.T, f: ^Area_Fixture, loc := #caller_location) -> bool {
	settings := DEFAULT_SETTINGS
	settings.gi_enabled, settings.taa = false, false
	if !fixture_init(t, f, 96, 96, settings, programs = true, loc = loc) {return false}
	vertices: [24]Mesh_Vertex
	indices: [36]u32
	normals := [6]Vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
	for n, face in normals {
		u := Vec3{n.y, n.z, n.x}
		v := linalg.cross(n, u)
		corners := [4]Vec3{n - u - v, n + u - v, n + u + v, n - u + v}
		for c, i in corners {vertices[face * 4 + i] = {position = c * 0.5, normal = n, color = {1, 1, 1}}}
		base := u32(face * 4)
		for q, i in ([6]u32{base, base + 1, base + 2, base, base + 2, base + 3}) {indices[face * 6 + i] = q}
	}
	added: bool
	f.cube, added = mesh_add(f.renderer, vertices[:], indices[:])
	f.camera = {position = {0, 4, 0.001}, forward = {0, -4, -0.001}, up = {0, 0, -1}, fov_y = 70, near = 0.05, far = 100, exposure = TUNED_EXPOSURE}
	return testing.expect(t, added)
}

// A white matte floor whose top is at y = 0, with the lights given.
@(private)
area_scene :: proc(f: ^Area_Fixture, lights: []Light_Desc, extra: []Instance_Desc = nil) {
	floor := Mat4(1)
	floor[0, 0], floor[1, 1], floor[2, 2], floor[1, 3] = 10, 0.1, 10, -0.05
	instances := make([dynamic]Instance_Desc, context.temp_allocator)
	append(&instances, Instance_Desc{object_id = 1, mesh = f.cube, transform = floor, tint = {1, 1, 1}})
	append(&instances, ..extra)
	scene_given(f.renderer, instances[:], lights, {}, {sky = {0, 0, 0}})
}

// The direct light of every pixel, as a mean over `frames` frames, of the
// pipeline or of the reference of the lights.
@(private)
area_direct :: proc(t: ^testing.T, f: ^Area_Fixture, frames: int, reference: bool, pipeline: Render_Pipeline_Handle = 0) -> []Vec3 {
	r := f.renderer
	size := int(r.main.targets.width * r.main.targets.height)
	sum := make([]Vec3, size, context.temp_allocator)
	texels := make([]f16, size * 4, context.temp_allocator)
	for _ in 0 ..< frames {
		r.main_pipeline = reference_pipeline(r, {.Lights}, nil) if reference else pipeline
		testing.expect(t, renderer_frame(r, {camera = f.camera}), r.error)
		if !testing.expect(t, rhi.texture_read(f.device, r.main.targets.direct, ([^]u8)(raw_data(texels))[:len(texels) * 2])) {return sum}
		for &value, i in sum {value += {f32(texels[i * 4]), f32(texels[i * 4 + 1]), f32(texels[i * 4 + 2])} / f32(frames)}
	}
	return sum
}

@(private)
area_luminance :: proc(c: Vec3) -> f32 {return 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z}

// With MIRAI_AREA_DUMP=<folder>, the light of a case as an image to look at.
@(private)
area_dump :: proc(f: ^Area_Fixture, values: []Vec3, name: string) {
	folder, found := os.lookup_env("MIRAI_AREA_DUMP", context.temp_allocator)
	if !found {return}
	width, height := int(f.renderer.main.targets.width), int(f.renderer.main.targets.height)
	pixels := make([]u8, width * height * 3, context.temp_allocator)
	for value, i in values {
		for channel in 0 ..< 3 {pixels[i * 3 + channel] = u8(clamp(math.pow(value[channel] / (1 + value[channel]), 1 / 2.2) * 255, 0, 255))}
	}
	path := strings.clone_to_cstring(fmt.tprintf("%s/%s.png", folder, name), context.temp_allocator)
	stbi.write_png(path, i32(width), i32(height), 3, raw_data(pixels), i32(width * 3))
}

// The pixels of a grid over the view where the reference is lit, and how
// far the light of each is from it at most, as a share of the reference.
@(private)
area_compare :: proc(f: ^Area_Fixture, approximate, reference: []Vec3) -> (worst: f32, lit: int, mean: f32, at: [2]int) {
	width, height := int(f.renderer.main.targets.width), int(f.renderer.main.targets.height)
	// Over 5x5 pixels: the reference is a mean of random points.
	around :: proc(values: []Vec3, width, x, y: int) -> f32 {
		sum: f32
		for dy in -2 ..= 2 {for dx in -2 ..= 2 {sum += area_luminance(values[(y + dy) * width + x + dx])}}
		return sum / 25
	}
	brightest: f32
	for value in reference {brightest = max(brightest, area_luminance(value))}
	for y := 4; y < height - 4; y += 8 {
		for x := 4; x < width - 4; x += 8 {
			want := around(reference, width, x, y)
			if want < 0.05 * brightest {continue}
			lit += 1
			error := abs(around(approximate, width, x, y) - want) / want
			mean += error
			if error > worst {worst, at = error, {x, y}}
		}
	}
	if lit > 0 {mean /= f32(lit)}
	return
}

// A rectangle, a capsule and a rectangle that goes into the floor, which
// its points see in part beyond their horizon, give what their reference gives: sixteen points of them
// every frame, each with its own falloff, cosines and ray, averaged over
// frames.
@(test)
area_lights_give_what_their_points_give :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_init(t, &f) {return}
	defer fixture_destroy(&f)
	cases := [?]struct {name: string, light: Light_Desc, worst, mean: f32}{
		{"rectangle above", {position = {0.3, 1.2, 0}, color = {1, 1, 1}, intensity = 3 * math.PI / 2, range = 20, direction = {0, -1, 0}, axis = {1, 0, 0}, size = {2, 1}}, 0.06, 0.03},
		{"tilted rectangle", {position = {0, 0.5, 0}, color = {1, 0.8, 0.6}, intensity = 3 * math.PI / 2.1, range = 20, direction = {0.8, -0.6, 0}, axis = {0, 0, 1}, size = {1.5, 1.4}}, 0.1, 0.03},
		{"capsule", {position = {0, 0.8, 0.2}, color = {0.7, 0.9, 1}, intensity = 3 * math.PI, range = 20, axis = {1, 0, 0.3}, length = 2.5, radius = 0.05}, 0.06, 0.03},
	}
	for c in cases {
		area_scene(&f, []Light_Desc{c.light})
		approximate := area_direct(t, &f, 4, false)
		reference := area_direct(t, &f, 64, true)
		area_dump(&f, approximate, fmt.tprintf("%s approximation", c.name))
		area_dump(&f, reference, fmt.tprintf("%s reference", c.name))
		worst, lit, mean, at := area_compare(&f, approximate, reference)
		testing.expectf(t, lit > 10, "%s: %d pixels of the grid are lit", c.name, lit)
		testing.expectf(t, worst < c.worst && mean < c.mean, "%s: the light is up to %.1f%% (at %v) and %.1f%% on average from its reference", c.name, worst * 100, at, mean * 100)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(f.device), rhi.device_validation_message(f.device))
}

// A rectangle lights the side it faces alone; small and far it gives what a
// point light of its intensity gives.
@(test)
rectangles_light_one_side_and_far_away_are_points :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_init(t, &f) {return}
	defer fixture_destroy(&f)
	area_scene(&f, []Light_Desc{{position = {0, 1.5, 0}, color = {1, 1, 1}, intensity = 5 * math.PI / 4, range = 20, direction = {0, 1, 0}, axis = {1, 0, 0}, size = {2, 2}}})
	brightest: f32
	for value in area_direct(t, &f, 2, false) {brightest = max(brightest, area_luminance(value))}
	testing.expectf(t, brightest == 0, "a rectangle facing up lights the floor under it: %v", brightest)

	area_scene(&f, []Light_Desc{{position = {0, 3, 0}, color = {1, 1, 1}, intensity = 5 * math.PI / 0.0016, range = 20, direction = {0, -1, 0}, axis = {1, 0, 0}, size = {0.04, 0.04}}})
	rectangle := area_direct(t, &f, 2, false)
	area_scene(&f, []Light_Desc{{position = {0, 3, 0}, color = {1, 1, 1}, intensity = 5 * math.PI, range = 20, radius = 0.01}})
	sphere := area_direct(t, &f, 2, false)
	worst, lit, _, _ := area_compare(&f, rectangle, sphere)
	testing.expect(t, lit > 20)
	// The rectangle also leans away from the points off its axis: its cosine.
	width := int(f.renderer.main.targets.width)
	middle := (width / 2) * width + width / 2
	testing.expectf(t, abs(area_luminance(rectangle[middle]) / area_luminance(sphere[middle]) - 1) < 0.015, "under its center a small rectangle gives %v and a point %v", rectangle[middle], sphere[middle])
	testing.expectf(t, worst < 0.45, "off its axis it should fall with the cosine and no faster: %.1f%%", worst * 100)
}

// The emission of a material across a rectangle colors the light it gives
// where that part of it is: red on one side of it, blue on the other.
@(test)
rectangles_show_the_emission_of_their_material :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_init(t, &f) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	SIZE :: 32
	pixels: [SIZE * SIZE * 4]u8
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			at := (y * SIZE + x) * 4
			if x < SIZE / 2 {pixels[at] = 255} else {pixels[at + 2] = 255}
			pixels[at + 3] = 255
		}
	}
	texture, added := texture_add(r, {pixels = pixels[:], width = SIZE, height = SIZE, srgb = true, name = "halves"})
	if !testing.expect(t, added, r.error) {return}
	screen := DEFAULT_MATERIAL
	screen.emission = {1, 1, 1}
	screen.textures[.Emission] = texture
	materials_set(r, {screen})
	light := Light_Desc{position = {0, 0.6, 0}, color = {1, 1, 1}, intensity = 3 * math.PI / 2.4, range = 20, direction = {0, -1, 0}, axis = {1, 0, 0}, size = {2.4, 1}, material = 1}
	area_scene(&f, []Light_Desc{light})
	direct := area_direct(t, &f, 2, false)
	reference := area_direct(t, &f, 48, true)
	area_dump(&f, direct, "textured approximation")
	area_dump(&f, reference, "textured reference")
	width := int(r.main.targets.width)
	column :: proc(f: ^Area_Fixture, x: f32) -> int {
		view, proj, _ := camera_matrices(f.camera, 1)
		clip := proj * view * Vec4{x, 0, 0, 1}
		return int((clip.x / clip.w * 0.5 + 0.5) * f32(f.renderer.main.targets.width))
	}
	row := width / 2
	for values, kind in ([2][]Vec3{direct, reference}) {
		left, right := values[row * width + column(&f, -0.7)], values[row * width + column(&f, 0.7)]
		label := "approximation" if kind == 0 else "reference"
		testing.expectf(t, left.x > 2 * left.z && right.z > 2 * right.x, "%s: red on the left and blue on the right, not %v and %v", label, left, right)
	}
	worst, lit, mean, at := area_compare(&f, direct, reference)
	testing.expect(t, lit > 20)
	// One color for the diffuse light of each point: off the edge of a texture of two colors it errs most.
	testing.expectf(t, worst < 0.35 && mean < 0.12, "the textured rectangle is up to %.1f%% (at %v) and %.1f%% on average from its reference", worst * 100, at, mean * 100)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(f.device), rhi.device_validation_message(f.device))
}
