package portals

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:testing"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"
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
}

@(private = "file")
gpu_fixture_init :: proc(t: ^testing.T, f: ^Gpu_Fixture) -> bool {
	root, _ := filepath.clean(ROOT, context.temp_allocator)
	// mirai test generates them: cook is not shipped, and the game compiles its test files.
	output := fmt.tprintf("%s/.mirai/test-shaders/portals", root)
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
	folder := base.test_folder(t, "portals-gpu")
	if folder == "" || !testing.expect(t, host.assets_init(&f.assets, {root = folder, renderer = &f.renderer})) {return false}
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
}

@(private = "file")
trs :: proc(position, scale: [3]f32) -> matrix[4, 4]f32 {
	m: matrix[4, 4]f32 = 1
	m[0, 0], m[1, 1], m[2, 2] = scale.x, scale.y, scale.z
	m[0, 3], m[1, 3], m[2, 3] = position.x, position.y, position.z
	return m
}

// The gate of a mirror as portals_render makes it, without its body.
@(private = "file")
mirror_gate :: proc(shown: mm.Transform) -> Gate {
	normal := mm.quat_rotate(shown.rotation, [3]f32{0, 0, 1})
	plane := [4]f32{normal.x, normal.y, normal.z, -(normal.x * shown.position.x + normal.y * shown.position.y + normal.z * shown.position.z)}
	gate := Gate{entrance = {shown.position, shown.rotation, {shown.scale.x, shown.scale.y, 1}}, exit = shown, mirror = true, plane = plane, exit_plane = plane}
	gate.through = gate_through(shown, shown, true)
	gate.previous = gate.through
	for &corner, i in gate.corners {
		corner = shown.position + mm.quat_rotate(shown.rotation, [3]f32{(i & 1 != 0 ? 0.5 : -0.5) * shown.scale.x, (i & 2 != 0 ? 0.5 : -0.5) * shown.scale.y, 0})
	}
	return gate
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
	// Under the coat the base meets an IOR of 1.5 instead of the air: its F0 is that of a relative IOR of 2.
	values.ior, values.specular_color = 3, {0.2, 0.8, 0.4}
	values.coat.weight, values.coat.ior = 1, 1.5
	material, derived := host.assets_material_derive(&f.assets, values)
	if !testing.expect(t, derived) {return}
	host.assets_commit(&f.assets)
	gpu.scene_set_environment(r,{direction = {0.2, 1, 0.3}, color = {1, 1, 1}, illuminance = math.PI, enabled = true, indirect = 1, scattering = 1},{sky = {0.3, 0.4, 0.6}})
	gpu.scene_update(r,0,{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, -4}, {20, 0.2, 20}), tint = {0.5, 0.5, 0.5}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 1, 3}, {6, 6, 0.2}), material = gpu.Material_Handle(material), tint = {1, 1, 1}},
	},true)
	camera := gpu.Camera{position = {0, 1, 0}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 100, exposure = gpu.UNIT_EXPOSURE}
	state := new(Portals_Gpu)
	defer free(state)
	state.gates[0] = mirror_gate({position = {0, 1, -3}, rotation = 1, scale = {2, 2, 1}})
	state.count = 1
	state.constants.count = 1
	for _ in 0 ..< 3 {
		state.pipeline = gpu.stage_pipeline(r, {stage = .Mask, shader = "portal_mask", name = "portal masks"})
		if !testing.expect(t, state.pipeline != 0, "the shaders of the plugin have the mask of portals") {return}
		testing.expect(t, gpu.frame_pass(r, .Mask, portals_record, state))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	}
	rhi.device_wait_idle(f.device)
	targets := &r.targets
	if !testing.expect(t, targets.surface != 0 && targets.layers != 0, "the view takes the reflectance and the layers targets of what its mirror shows") {return}
	x, y := int(targets.width) / 2, int(targets.height) / 2
	f0 := middle_texel(t, f, targets.surface, x, y)
	seen := [3]f32{srgb_linear(f0[0]), srgb_linear(f0[1]), srgb_linear(f0[2])}
	testing.expectf(t, abs(seen.x - 0.2 / 9) < 0.004 && abs(seen.y - 0.8 / 9) < 0.004 && abs(seen.z - 0.4 / 9) < 0.004, "the mirror shows the F0 of the surface: %v", seen)
	layers := middle_texel(t, f, targets.layers, x, y)
	coated := false
	for b in layers {coated ||= b != 0}
	testing.expect(t, coated, "the mirror shows the coat of the surface")
	// The ground in front of the mirror, in the view itself: the default dielectric of its albedo.
	ground := middle_texel(t, f, targets.surface, x, int(targets.height) - 2)
	testing.expectf(t, abs(srgb_linear(ground[0]) - 0.04) < 0.005 && ground[3] == 255, "the view itself reflects what its albedo gives: %v", ground)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(f.device), rhi.device_validation_message(f.device))
}

// A mirror in front of a player in first person shows its body and never its
// viewmodel: the view draws the weapon, the nested view of the mirror the body
// alone.
@(test)
a_mirror_shows_the_body_of_the_player_and_never_its_viewmodel :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r, {direction = {0.2, 1, 0.3}, color = {1, 1, 1}, illuminance = math.PI, enabled = true}, {sky = {0.3, 0.4, 0.6}})
	eye := [3]f32{0, 1.6, 0}
	gpu.scene_update(r, 0, {
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, -4}, {20, 0.2, 20}), tint = {0.5, 0.5, 0.5}},
		// The body around the eye, blue, and the weapon under it, red.
		{object_id = 2, mesh = f.cube, transform = trs({0, 0.85, 0.05}, {0.5, 1.7, 0.3}), tint = {0, 0, 1}, owner = 1},
		{object_id = 3, mesh = f.cube, transform = trs(eye + {0.12, -0.12, -0.45}, {0.05, 0.05, 0.4}), tint = {1, 0, 0}, owner = 1, viewmodel = true},
	}, true)
	gpu.scene_set_viewmodels(r, {55 * math.RAD_PER_DEG, 0, 0, 0})
	camera := gpu.Camera{position = eye, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 90, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE, own = 1}
	state := new(Portals_Gpu)
	defer free(state)
	state.gates[0] = mirror_gate({position = {0, 1.2, -2}, rotation = 1, scale = {3, 2.4, 1}})
	state.count = 1
	state.constants.count = 1
	for _ in 0 ..< 3 {
		state.pipeline = gpu.stage_pipeline(r, {stage = .Mask, shader = "portal_mask", name = "portal masks"})
		if !testing.expect(t, state.pipeline != 0, "the shaders of the plugin have the mask of portals") {return}
		testing.expect(t, gpu.frame_pass(r, .Mask, portals_record, state))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	}
	rhi.device_wait_idle(f.device)
	targets := &r.targets
	count := int(targets.width * targets.height)
	albedo := make([]u8, count * 4, context.temp_allocator)
	depths := make([]f32, count, context.temp_allocator)
	testing.expect(t, rhi.texture_read(f.device, targets.albedo, albedo) && rhi.texture_read(f.device, targets.linear_depth, ([^]u8)(raw_data(depths))[:count * 4]), rhi.device_error(f.device))
	body, weapon, nested, drawn := 0, 0, 0, 0
	for i in 0 ..< count {
		red, blue := albedo[i * 4] > 150 && albedo[i * 4 + 2] < 60, albedo[i * 4 + 2] > 150 && albedo[i * 4] < 60
		if depths[i] < 0 {
			nested += 1
			if blue {body += 1}
			if red {weapon += 1}
		} else if red {drawn += 1}
	}
	testing.expectf(t, nested > 0 && body > 0, "the mirror shows the body: %d of its %d pixels", body, nested)
	testing.expectf(t, weapon == 0, "the mirror never shows the viewmodel: %d pixels", weapon)
	testing.expectf(t, drawn > 0, "the view draws its viewmodel: %d pixels", drawn)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(f.device), rhi.device_validation_message(f.device))
}

// A floor in the sun seen in a mirror is lit as the same floor seen directly:
// the nested view, whose reflection turns the winding of what it draws around,
// draws the top of the floor and not its underside, which the floor shades.
@(test)
a_lit_floor_seen_in_a_mirror_is_lit_as_seen_directly :: proc(t: ^testing.T) {
	f := new(Gpu_Fixture)
	defer free(f)
	if !gpu_fixture_init(t, f) {return}
	defer gpu_fixture_destroy(f)
	r := &f.renderer
	gpu.scene_set_environment(r, {direction = {0.2, 1, 0.3}, color = {1, 1, 1}, illuminance = math.PI, enabled = true}, {sky = {0.3, 0.4, 0.6}})
	gpu.scene_update(r, 0, {{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, -4}, {20, 0.2, 20}), tint = {0.5, 0.5, 0.5}}}, true)
	camera := gpu.Camera{position = {0, 1.6, 1}, forward = {0, -0.35, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = gpu.UNIT_EXPOSURE}
	state := new(Portals_Gpu)
	defer free(state)
	state.gates[0] = mirror_gate({position = {0, 1, -2}, rotation = 1, scale = {4, 2, 1}})
	state.count = 1
	state.constants.count = 1
	for _ in 0 ..< 4 {
		state.pipeline = gpu.stage_pipeline(r, {stage = .Mask, shader = "portal_mask", name = "portal masks"})
		if !testing.expect(t, state.pipeline != 0, "the shaders of the plugin have the mask of portals") {return}
		testing.expect(t, gpu.frame_pass(r, .Mask, portals_record, state))
		testing.expect(t, gpu.renderer_frame(r, {camera = camera}), r.error)
	}
	rhi.device_wait_idle(f.device)
	targets := &r.targets
	count := int(targets.width * targets.height)
	display := make([]f16, count * 4, context.temp_allocator)
	depths := make([]f32, count, context.temp_allocator)
	testing.expect(t, rhi.texture_read(f.device, targets.display, ([^]u8)(raw_data(display))[:count * 8]) && rhi.texture_read(f.device, targets.linear_depth, ([^]u8)(raw_data(depths))[:count * 4]), rhi.device_error(f.device))
	mirrored, direct: [dynamic]f32
	mirrored.allocator, direct.allocator = context.temp_allocator, context.temp_allocator
	for i in 0 ..< count {
		l := 0.2126 * f32(display[i * 4]) + 0.7152 * f32(display[i * 4 + 1]) + 0.0722 * f32(display[i * 4 + 2])
		// The floor of each: below the middle of the mirror, below the horizon of the view.
		y := i / int(targets.width)
		if depths[i] < 0 && y > int(targets.height) / 2 {append(&mirrored, l)}
		if depths[i] > 0 && y > int(targets.height) * 3 / 4 {append(&direct, l)}
	}
	mean :: proc(values: []f32) -> (m: f32) {
		for v in values {m += v}
		return m / max(f32(len(values)), 1)
	}
	if !testing.expectf(t, len(mirrored) > 50 && len(direct) > 50, "the floor is seen in the mirror (%d pixels) and directly (%d)", len(mirrored), len(direct)) {return}
	testing.expectf(t, abs(mean(mirrored[:]) - mean(direct[:])) <= 0.05 * mean(direct[:]), "the floor in the mirror is lit as the floor seen directly: %.4f, %.4f", mean(mirrored[:]), mean(direct[:]))
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(f.device), rhi.device_validation_message(f.device))
}
