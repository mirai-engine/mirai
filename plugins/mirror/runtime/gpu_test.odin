package mirror

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import mm "mirai:std/math"

// The nested view of a mirror on the GPU, with the shaders of the engine and
// those of the plugin: a generation into .mirai/tmp of the engine, which the
// tests after the first find up to date.

@(private = "file")
ROOT :: #directory + "/../../.."

@(private = "file")
WIDTH :: 96
@(private = "file")
HEIGHT :: 64

@(private = "file")
Gpu_Fixture :: struct {
	device:   ^rhi.Device,
	renderer: gpu.Renderer,
	assets:   host.Assets,
	app:      host.App,
	cube:     gpu.Mesh_Handle,
	folder:   string,
}

@(private = "file")
gpu_fixture_init :: proc(t: ^testing.T, f: ^Gpu_Fixture) -> bool {
	root, _ := filepath.clean(ROOT, context.temp_allocator)
	// mirai test generates them: cook is not shipped, and the game compiles its test files.
	output := fmt.tprintf("%s/.mirai/tmp/mirror-test-shaders", root)
	loaded, problem := gpu.shader_assets_load(output)
	if !testing.expect(t, problem == "", problem) {return false}
	device := shared_device.take_or_skip(t)
	if device == nil {
		gpu.shader_assets_destroy(&loaded)
		return false
	}
	f.device = device
	settings := gpu.DEFAULT_SETTINGS
	settings.taa, settings.gi_enabled = false, false
	if !testing.expect(t, gpu.renderer_init(&f.renderer, {device = device, width = WIDTH, height = HEIGHT, settings = settings, shaders = &loaded}), f.renderer.error) {return false}
	directory, _ := os.temp_directory(context.temp_allocator)
	f.folder = fmt.aprintf("%s/mirai-mirror-gpu-%d-%p", directory, os.get_pid(), f)
	os.make_directory_all(f.folder)
	if !testing.expect(t, host.assets_init(&f.assets, {root = f.folder, renderer = &f.renderer})) {return false}
	f.app = host.App{allocator = context.allocator, renderer = &f.renderer, assets = &f.assets, device = device}
	cube := host.assets_shape(&f.assets, .Cube)
	if !testing.expect(t, cube != nil) {return false}
	f.cube = cube.handle
	gpu.scene_world(&f.renderer, 1)
	return true
}

@(private = "file")
gpu_fixture_destroy :: proc(f: ^Gpu_Fixture) {
	if f.device == nil {return}
	host.assets_destroy(&f.assets)
	gpu.renderer_destroy(&f.renderer)
	os.remove_all(f.folder)
	delete(f.folder)
}

@(private = "file")
trs :: proc(position, scale: [3]f32) -> matrix[4, 4]f32 {
	m: matrix[4, 4]f32 = 1
	m[0, 0], m[1, 1], m[2, 2] = scale.x, scale.y, scale.z
	m[0, 3], m[1, 3], m[2, 3] = position.x, position.y, position.z
	return m
}

// A face of a mirror as mirrors_render makes it, without its body.
@(private = "file")
face_of :: proc(shown: mm.Transform) -> Face {
	to_local, _ := mm.transform_inverse_matrix({shown.position, shown.rotation, {shown.scale.x, shown.scale.y, 1}})
	normal := mm.quat_rotate(shown.rotation, [3]f32{0, 0, 1})
	face := Face{to_local = mm.mat4_rows(to_local), place = shown.position}
	face.plane = {normal.x, normal.y, normal.z, -(normal.x * shown.position.x + normal.y * shown.position.y + normal.z * shown.position.z)}
	face.reflect = reflection(face.plane)
	face.previous = face.reflect
	for &corner, i in face.corners {
		corner = shown.position + mm.quat_rotate(shown.rotation, [3]f32{(i & 1 != 0 ? 0.5 : -0.5) * shown.scale.x, (i & 2 != 0 ? 0.5 : -0.5) * shown.scale.y, 0})
	}
	return face
}

// The texel of a target at the middle of the view.
@(private = "file")
middle_texel :: proc(t: ^testing.T, f: ^Gpu_Fixture, target: rhi.Texture, x, y: int) -> []u8 {
	desc := rhi.texture_desc(f.device, target)
	size := rhi.format_size(desc.format)
	bytes := make([]u8, int(desc.width) * int(desc.height) * size, context.temp_allocator)
	testing.expect(t, rhi.texture_read(f.device, target, bytes), rhi.device_error(f.device))
	at := (y * int(desc.width) + x) * size
	return bytes[at:][:size]
}

@(private = "file")
srgb_linear :: proc(b: u8) -> f32 {
	v := f32(b) / 255
	return v / 12.92 if v <= 0.04045 else math.pow((v + 0.055) / 1.055, 2.4)
}

// A surface with its own F0 and a coat, behind the camera, seen only in a
// mirror in front of it: the G-buffer of the view keeps what it reflects and
// its layers, which the frustum of the view alone does not see the need for,
// and the pixels of the view itself reflect as they do without the target.
@(test)
a_surface_seen_only_in_a_mirror_keeps_its_reflectance_and_layers :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	values := host.assets_material_values(&f.assets, 0)
	values.ior, values.specular_color = 0, {0.2, 0.8, 0.4}
	values.coat.weight = 1
	material, derived := host.assets_material_derive(&f.assets, values)
	if !testing.expect(t, derived) {return}
	host.assets_commit(&f.assets)
	gpu.scene_set(r, {
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, -4}, {20, 0.2, 20}), tint = {0.5, 0.5, 0.5}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 1, 3}, {6, 6, 0.2}), material = gpu.Material_Handle(material), tint = {1, 1, 1}},
	}, nil, {direction = {0.2, 1, 0.3}, color = {1, 1, 1}, illuminance = math.PI, enabled = true}, {sky = {0.3, 0.4, 0.6}})
	camera := gpu.Camera{position = {0, 1, 0}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 100, exposure = gpu.UNIT_EXPOSURE}
	state := new(Mirrors_Gpu)
	defer free(state)
	state.faces[0] = face_of({position = {0, 1, -3}, rotation = 1, scale = {2, 2, 1}})
	state.count = 1
	for _ in 0 ..< 3 {
		state.pipeline = gpu.stage_pipeline(r, {stage = .Mask, shader = "mirror_mask", name = "mirror masks"})
		if !testing.expect(t, state.pipeline != 0, "the shaders of the plugin have the mask of mirrors") {return}
		testing.expect(t, gpu.frame_pass(r, .Mask, mirrors_record, state))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	}
	rhi.device_wait_idle(f.device)
	targets := &r.targets
	if !testing.expect(t, targets.surface != 0 && targets.layers != 0, "the view takes the reflectance and the layers targets of what its mirror shows") {return}
	x, y := int(targets.width) / 2, int(targets.height) / 2
	f0 := middle_texel(t, f, targets.surface, x, y)
	seen := [3]f32{srgb_linear(f0[0]), srgb_linear(f0[1]), srgb_linear(f0[2])}
	testing.expectf(t, abs(seen.x - 0.2) < 0.01 && abs(seen.y - 0.8) < 0.01 && abs(seen.z - 0.4) < 0.01, "the mirror shows the F0 of the surface: %v", seen)
	layers := middle_texel(t, f, targets.layers, x, y)
	coated := false
	for b in layers {coated ||= b != 0}
	testing.expect(t, coated, "the mirror shows the coat of the surface")
	// The ground in front of the mirror, in the view itself: the default dielectric of its albedo.
	ground := middle_texel(t, f, targets.surface, x, int(targets.height) - 2)
	testing.expectf(t, abs(srgb_linear(ground[0]) - 0.04) < 0.005 && ground[3] == 254, "the view itself reflects what its albedo gives: %v", ground)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(f.device), rhi.device_validation_message(f.device))
}
