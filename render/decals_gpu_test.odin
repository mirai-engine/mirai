package mirai_render

import "core:math"
import "core:mem"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:rhi"

@(private = "file")
decal_settings :: proc() -> Settings {
	s := DEFAULT_SETTINGS
	s.gi_enabled = false
	s.taa = false
	return s
}

// A unit square facing +Y, u along +X and v along +Z, tangent along +X.
@(private = "file")
decal_quad :: proc(r: ^Renderer) -> Mesh_Handle {
	corners := [4]Vec3{{-0.5, 0, -0.5}, {0.5, 0, -0.5}, {0.5, 0, 0.5}, {-0.5, 0, 0.5}}
	vertices: [4]Mesh_Vertex
	for c, i in corners {vertices[i] = {position = c, normal = {0, 1, 0}, tangent = {1, 0, 0, 1}, uv = {c.x + 0.5, c.z + 0.5}, color = {1, 1, 1}}}
	mesh, _ := mesh_add(r, vertices[:], []u32{0, 2, 1, 0, 3, 2})
	return mesh
}

@(private = "file")
decal_placed :: proc(position, scale: Vec3) -> Mat4 {
	m := Mat4(1)
	m[0, 0], m[1, 1], m[2, 2] = scale.x, scale.y, scale.z
	m[0, 3], m[1, 3], m[2, 3] = position.x, position.y, position.z
	return m
}

@(private = "file")
decal_material :: proc(color: Vec3, opacity: f32, writes: asset.Decal_Writes, order: i32 = 0) -> Material_Desc {
	m := DEFAULT_MATERIAL
	m.alpha_mode, m.base_color, m.opacity, m.decal = .Decal, color, opacity, {writes = writes, order = order}
	return m
}

@(private = "file")
decal_pixel :: proc(r: ^Renderer, camera: Camera, world: Vec3) -> [2]int {
	view, proj, _ := camera_matrices(camera, f32(r.targets.width) / f32(r.targets.height))
	clip := (proj * view) * Vec4{world.x, world.y, world.z, 1}
	ndc := clip.xy / clip.w
	return {int((ndc.x * 0.5 + 0.5) * f32(r.targets.width)), int((0.5 - ndc.y * 0.5) * f32(r.targets.height))}
}

// The G-buffer where a point of the world shows after two frames: its base
// color (sRGB bytes) with metallic, and its shading normal with roughness.
@(private = "file")
Decal_Seen :: struct {
	albedo: [4]int,
	normal: Vec4,
}

@(private = "file")
decal_seen :: proc(t: ^testing.T, f: ^Fixture, camera: Camera, world: Vec3) -> (seen: Decal_Seen) {
	r := f.renderer
	for _ in 0 ..< 2 {testing.expect(t, fixture_frame(f, {camera = camera}), r.error)}
	rhi.device_wait_idle(f.device)
	p := decal_pixel(r, camera, world)
	at := p.y * int(r.targets.width) + p.x
	bytes := make([]u8, int(r.targets.width * r.targets.height) * 4, context.temp_allocator)
	halves := make([]f16, int(r.targets.width * r.targets.height) * 4, context.temp_allocator)
	testing.expect(t, golden_read_texture(f.device, r.targets.albedo, bytes) && golden_read_texture(f.device, r.targets.normal, mem.slice_data_cast([]u8, halves)), rhi.device_error(f.device))
	for i in 0 ..< 4 {seen.albedo[i] = int(bytes[at * 4 + i])}
	normal, roughness, _ := gbuffer_normal_decode({f32(halves[at * 4]), f32(halves[at * 4 + 1]), f32(halves[at * 4 + 2]), f32(halves[at * 4 + 3])})
	seen.normal = {normal.x, normal.y, normal.z, roughness}
	return
}

// The lit image in linear light where a point of the world shows.
@(private = "file")
decal_lit :: proc(t: ^testing.T, f: ^Fixture, camera: Camera, world: Vec3) -> Vec3 {
	r := f.renderer
	for _ in 0 ..< 3 {testing.expect(t, fixture_frame(f, {camera = camera}), r.error)}
	rhi.device_wait_idle(f.device)
	pixels := make([]f16, int(r.targets.width * r.targets.height) * 4, context.temp_allocator)
	testing.expect(t, golden_read_texture(f.device, r.targets.display, mem.slice_data_cast([]u8, pixels)), rhi.device_error(f.device))
	p := decal_pixel(r, camera, world)
	i := (p.y * int(r.targets.width) + p.x) * 4
	return {f32(pixels[i]), f32(pixels[i + 1]), f32(pixels[i + 2])}
}

@(private = "file")
DECAL_ABOVE :: Camera{position = {0, 3, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}

@(private = "file")
srgb_byte :: proc(linear: f32) -> int {
	c := clamp(linear, 0, 1)
	s := c * 12.92 if c <= 0.0031308 else 1.055 * math.pow(c, 1 / 2.4) - 0.055
	return int(math.round(s * 255))
}

// A decal changes the surface under it before it is lit, exactly where it
// lies on it: only what its material writes, by its coverage. It is in no
// target of the G-buffer of its own, and the view has the decal targets only
// while the scene has a decal.
@(test)
a_decal_changes_only_what_it_writes_of_the_surface_under_it :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, decal_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// 30 degrees towards +X of the image.
	tilt := [4]u8{191, 128, 238, 255}
	tilted, made := texture_add(r, {pixels = tilt[:], width = 1, height = 1, normal_map = true, name = "decal tilt"})
	testing.expect(t, made, r.error)
	floor := DEFAULT_MATERIAL
	floor.base_color, floor.roughness = {0.5, 0.5, 0.5}, 0.8
	paint := decal_material({1, 0, 0}, 1, {.Color})
	rebar := decal_material({0, 0, 1}, 1, {.Normal})
	rebar.textures[.Normal] = tilted
	wet := decal_material({0, 1, 0}, 1, {.Surface})
	wet.roughness, wet.metallic = 0.2, 1
	half := decal_material({1, 0, 0}, 0.5, {.Color})
	materials_set(r, {floor, paint, rebar, wet, half})
	quad := decal_quad(r)
	ground := Instance_Desc{object_id = 1, mesh = quad, transform = decal_placed({}, {20, 1, 20}), material = 1, tint = 1}
	under, beside := Vec3{0.1, 0, 0.1}, Vec3{1.2, 0, 0}
	scene_given(r, {ground}, nil, {}, {})
	bare := decal_seen(t, &f, DECAL_ABOVE, under)
	testing.expect(t, r.targets.decal_color == 0 && len(r.scene.decals) == 0, "without a decal the view has no decal targets")

	for decal, i in ([4]Material_Handle{2, 3, 4, 5}) {
		top := Instance_Desc{object_id = 2, mesh = quad, transform = decal_placed({}, {1, 1, 1}), material = decal, tint = 1}
		testing.expect(t, scene_given(r, {ground, top}, nil, {}, {}), r.error)
		seen := decal_seen(t, &f, DECAL_ABOVE, under)
		outside := decal_seen(t, &f, DECAL_ABOVE, beside)
		testing.expectf(t, outside == bare, "decal %d: beside it the surface is as it was: %v, %v", i, outside, bare)
		testing.expect(t, len(r.scene.decals) == 1 && r.targets.decal_color != 0 && r.targets.decal_emission == 0, "a decal that emits nothing takes no emission target")
		switch i {
		case 0:
			testing.expectf(t, seen.albedo.rgb == {255, 0, 0} && seen.normal == bare.normal, "a color decal changes the color alone: %v", seen)
		case 1:
			n := seen.normal
			testing.expectf(t, seen.albedo == bare.albedo && abs(n.x - 0.5) < 0.03 && abs(n.y - 0.866) < 0.03 && abs(n.z) < 0.03 && abs(n.w - bare.normal.w) < 0.01,
				"a normal decal turns the normal alone, as its map turns it: %v", seen)
		case 2:
			testing.expectf(t, seen.albedo.rgb == bare.albedo.rgb && seen.albedo.a == 255 && abs(seen.normal.w - 0.2) < 0.02 && seen.normal.xyz == bare.normal.xyz,
				"a surface decal gives its roughness and metallic alone: %v", seen)
		case 3:
			testing.expectf(t, abs(seen.albedo.r - srgb_byte(0.75)) <= 2 && abs(seen.albedo.g - srgb_byte(0.25)) <= 2,
				"half a red decal over gray: %v", seen)
		}
	}
	// Decals placed as one batch are drawn as the same decals of the scene are, each of its instances.
	batch, problem := batch_set(r, 0, r.world_key, {mesh = quad, material = 2, tint = 1}, {batch_instance({}, 1, 1), batch_instance(beside, 1, 1)})
	testing.expect(t, batch != 0, problem)
	testing.expect(t, scene_given(r, {ground}, nil, {}, {}), r.error)
	for at in ([2]Vec3{under, beside}) {
		seen := decal_seen(t, &f, DECAL_ABOVE, at)
		testing.expectf(t, seen.albedo.rgb == {255, 0, 0} && seen.normal == bare.normal, "a decal of a batch at %v changes the color alone: %v", at, seen)
	}
	testing.expect_value(t, len(r.scene.decals), 2)
	batch_remove(r, batch)
	// The decals go: so do the targets, and the surface is as it was.
	testing.expect(t, scene_given(r, {ground}, nil, {}, {}), r.error)
	testing.expect(t, decal_seen(t, &f, DECAL_ABOVE, under) == bare && r.targets.decal_color == 0 && len(r.scene.decals) == 0)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A decal over a floor a wall shadows from a light that casts shadows is lit
// as the floor beside it: its surface is that of the floor, lit with it, so
// no light goes through the wall onto it.
@(test)
a_decal_in_the_shadow_of_a_wall_takes_the_light_of_the_floor :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 128, 96, decal_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	white := DEFAULT_MATERIAL
	white.base_color, white.roughness = {0.8, 0.8, 0.8}, 1
	mud := decal_material({0.8, 0.8, 0.8}, 1, {.Color, .Normal, .Surface})
	mud.roughness = 1
	materials_set(r, {white, mud})
	quad := decal_quad(r)
	ground := Instance_Desc{object_id = 1, mesh = quad, transform = decal_placed({}, {20, 1, 20}), material = 1, tint = 1}
	// A wall at x = 0 from the floor to 3 m, between the light and the floor past it.
	wall := Instance_Desc{object_id = 2, mesh = quad, transform = {0, -1, 0, 0, 3, 0, 0, 1.5, 0, 0, 6, 0, 0, 0, 0, 1}, material = 1, tint = 1}
	decal := Instance_Desc{object_id = 3, mesh = quad, transform = decal_placed({1.5, 0, 0}, {1, 1, 1}), material = 2, tint = 1}
	lamp := Light_Desc{position = {-1, 2, 0}, color = {1, 1, 1}, intensity = 20, range = 12}
	// Over the top of the wall, in its plane: both sides of it show.
	camera := Camera{position = {0, 8, 5}, forward = {0, -8, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	shadowed, open := Vec3{1.5, 0, 0.1}, Vec3{-1.5, 0, 0.1}
	testing.expect(t, scene_given(r, {ground, wall}, {lamp}, {}, {}), r.error)
	floor_dark, floor_lit := decal_lit(t, &f, camera, shadowed), decal_lit(t, &f, camera, open)
	testing.expectf(t, floor_lit.x > 10 * max(floor_dark.x, 1e-6), "the wall shadows the floor past it: %v, %v", floor_dark, floor_lit)
	testing.expect(t, scene_given(r, {ground, wall, decal}, {lamp}, {}, {}), r.error)
	under := decal_lit(t, &f, camera, shadowed)
	testing.expectf(t, abs(under.x - floor_dark.x) <= 1e-3 * floor_lit.x, "the decal is as dark as the floor under it: %v, %v", under, floor_dark)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// Four decals over one place compose by their order, whatever the order of
// their instances, and give the same surface from every side of an orbit.
@(test)
decal_layers_compose_in_their_order_from_every_side :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, decal_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	gray := DEFAULT_MATERIAL
	gray.base_color = {0.2, 0.2, 0.2}
	colors := [4]Vec3{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 1, 1}}
	layers := [5]Material_Desc{gray, {}, {}, {}, {}}
	for color, order in colors {layers[order + 1] = decal_material(color, 0.5, {.Color}, i32(order))}
	materials_set(r, layers[:])
	quad := decal_quad(r)
	ground := Instance_Desc{object_id = 1, mesh = quad, transform = decal_placed({}, {20, 1, 20}), material = 1, tint = 1}
	expected := Vec3{0.2, 0.2, 0.2}
	for color in colors {expected = expected * 0.5 + color * 0.5}
	given := [2][4]int{{3, 1, 0, 2}, {0, 1, 2, 3}}
	first: [4]int
	for order, k in given {
		instances := [5]Instance_Desc{ground, {}, {}, {}, {}}
		for layer, i in order {
			instances[i + 1] = {object_id = u64(i + 2), mesh = quad, transform = decal_placed({}, {2, 1, 2}), material = Material_Handle(layer + 2), tint = 1}
		}
		testing.expect(t, scene_given(r, instances[:], nil, {}, {}), r.error)
		for angle in 0 ..< 4 {
			a := f32(angle) * math.PI / 2 + 0.3
			eye := Vec3{3 * math.cos(a), 2.5, 3 * math.sin(a)}
			camera := Camera{position = eye, forward = -eye, up = {0, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
			seen := decal_seen(t, &f, camera, {0.1, 0, -0.1}).albedo
			if k == 0 && angle == 0 {
				first = seen
				testing.expectf(t, abs(seen.r - srgb_byte(expected.x)) <= 3 && abs(seen.g - srgb_byte(expected.y)) <= 3 && abs(seen.b - srgb_byte(expected.z)) <= 3,
					"red, green, blue then white, each at half over gray: %v, expected %v", seen, expected)
			}
			testing.expectf(t, seen == first, "given in order %v, from the side %d: %v, first %v", order, angle, seen, first)
		}
	}
	orders := make([]i16, len(r.scene.decals), context.temp_allocator)
	for entry, i in r.scene.decals {orders[i] = entry.order}
	testing.expect(t, slice.is_sorted(orders) && len(r.scene.decal_runs) == 1, "one run of the four, in their order")
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A scene that has had decals and has none again draws the same image, byte
// for byte, as before it had them, with no decal target and no decal pass.
@(test)
a_scene_without_decals_draws_no_decal_pass_and_the_same_image :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, decal_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	gray := DEFAULT_MATERIAL
	gray.base_color = {0.6, 0.5, 0.4}
	materials_set(r, {gray, decal_material({1, 0, 0}, 1, {.Color, .Emission})})
	quad := decal_quad(r)
	ground := Instance_Desc{object_id = 1, mesh = quad, transform = decal_placed({}, {20, 1, 20}), material = 1, tint = 1}
	sun := Sun_Desc{direction = {0.3, 1, 0.2}, color = {1, 1, 1}, illuminance = math.PI, enabled = true, indirect = 1, scattering = 1}
	rhi.timestamps_want(f.device, true)
	defer rhi.timestamps_want(f.device, false)
	image :: proc(t: ^testing.T, f: ^Fixture) -> (pixels: []u8, decal_pass: bool) {
		for _ in 0 ..< 3 {testing.expect(t, fixture_frame(f, {camera = DECAL_ABOVE}), f.renderer.error)}
		rhi.device_wait_idle(f.device)
		for timing in renderer_stats(f.renderer).timings {decal_pass ||= timing.name == "decals"}
		ok: bool
		pixels, _, _, ok = renderer_capture(f.renderer, context.temp_allocator)
		testing.expect(t, ok)
		return
	}
	testing.expect(t, scene_given(r, {ground}, nil, sun, {}), r.error)
	before, drawn := image(t, &f)
	testing.expect(t, !drawn && r.targets.decal_color == 0 && r.targets.decal_emission == 0, "no decal pass, no decal target")
	decal := Instance_Desc{object_id = 2, mesh = quad, transform = decal_placed({0.3, 0, 0}, {1, 1, 1}), material = 2, tint = 1}
	testing.expect(t, scene_given(r, {ground, decal}, nil, sun, {}), r.error)
	with, drawn_with := image(t, &f)
	testing.expect(t, drawn_with && r.targets.decal_emission != 0 && !slice.equal(with, before), "a decal that emits has its pass and the emission target")
	testing.expect(t, scene_given(r, {ground}, nil, sun, {}), r.error)
	after, drawn_after := image(t, &f)
	testing.expect(t, !drawn_after && r.targets.decal_color == 0 && r.targets.decal_emission == 0 && slice.equal(after, before), "without decals again: the image of before, byte for byte")
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}
