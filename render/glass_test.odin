package mirai_render

import "core:math"
import "core:mem"
import "core:testing"
import "mirai:render/abi"
import "mirai:rhi"

// No jitter and no probes: a pixel shows one surface point, lit by the sun
// alone. Shadows are checked ray by ray, at single pixels of small images:
// the fixtures draw with the reference of the lights, whose every pixel
// traces its own rays.
@(private = "file")
glass_settings :: proc() -> Settings {
	s := DEFAULT_SETTINGS
	s.gi_enabled = false
	s.taa = false
	return s
}

// A unit square facing +Y, its tangent along +X; both sides are drawn.
@(private = "file")
sheet_mesh :: proc(r: ^Renderer) -> Mesh_Handle {
	corners := [4]Vec3{{-0.5, 0, -0.5}, {0.5, 0, -0.5}, {0.5, 0, 0.5}, {-0.5, 0, 0.5}}
	vertices: [4]Mesh_Vertex
	for c, i in corners {vertices[i] = {position = c, normal = {0, 1, 0}, tangent = {1, 0, 0, 1}, uv = {c.x + 0.5, c.z + 0.5}, color = {1, 1, 1}}}
	mesh, _ := mesh_add(r, vertices[:], []u32{0, 2, 1, 0, 3, 2})
	return mesh
}

// A unit cube, counter-clockwise seen from outside, and a vertex at `loose`
// that no triangle uses.
@(private = "file")
box_mesh :: proc(r: ^Renderer, loose: Maybe(Vec3) = nil) -> Mesh_Handle {
	vertices: [25]Mesh_Vertex
	indices: [36]u32
	for n, face in ([6]Vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) {
		u := Vec3{n.y, n.z, n.x}
		v := Vec3{n.y * u.z - n.z * u.y, n.z * u.x - n.x * u.z, n.x * u.y - n.y * u.x}
		for c, i in ([4]Vec3{n - u - v, n + u - v, n + u + v, n - u + v}) {vertices[face * 4 + i] = {position = c * 0.5, normal = n, color = {1, 1, 1}}}
		base := u32(face * 4)
		for q, i in ([6]u32{base, base + 1, base + 2, base, base + 2, base + 3}) {indices[face * 6 + i] = q}
	}
	count := 24
	if p, ok := loose.?; ok {
		vertices[24] = {position = p, normal = {1, 0, 0}, color = {1, 1, 1}}
		count = 25
	}
	mesh, _ := mesh_add(r, vertices[:count], indices[:])
	return mesh
}

// A sphere of diameter 1.
ball_mesh :: proc(r: ^Renderer) -> Mesh_Handle {
	RINGS :: 24
	SEGMENTS :: 48
	vertices := make([dynamic]Mesh_Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	for ring in 0 ..= RINGS {
		theta := math.PI * f32(ring) / RINGS
		for segment in 0 ..= SEGMENTS {
			phi := 2 * math.PI * f32(segment) / SEGMENTS
			n := Vec3{math.sin(theta) * math.cos(phi), math.cos(theta), math.sin(theta) * math.sin(phi)}
			append(&vertices, Mesh_Vertex{position = n * 0.5, normal = n, color = {1, 1, 1}})
		}
	}
	row := u32(SEGMENTS + 1)
	for ring in 0 ..< u32(RINGS) {
		for segment in 0 ..< u32(SEGMENTS) {
			a := ring * row + segment
			b := a + row
			if ring != 0 {append(&indices, a, a + 1, b + 1)}
			if ring != RINGS - 1 {append(&indices, a, b + 1, b)}
		}
	}
	mesh, _ := mesh_add(r, vertices[:], indices[:])
	return mesh
}

@(private = "file")
placed :: proc(position, scale: Vec3) -> Mat4 {
	m := Mat4(1)
	m[0, 0], m[1, 1], m[2, 2] = scale.x, scale.y, scale.z
	m[0, 3], m[1, 3], m[2, 3] = position.x, position.y, position.z
	return m
}

// A sheet standing in the XY plane, facing +Z.
@(private = "file")
standing :: proc(position: Vec3, width, height: f32) -> Mat4 {
	m := Mat4{}
	m[0, 0] = width
	m[1, 2] = -height
	m[2, 1] = 1
	m[0, 3], m[1, 3], m[2, 3], m[3, 3] = position.x, position.y, position.z, 1
	return m
}

@(private = "file")
glass_pixel :: proc(r: ^Renderer, camera: Camera, world: Vec3) -> [2]int {
	view, proj, _ := camera_matrices(camera, f32(r.targets.width) / f32(r.targets.height))
	clip := (proj * view) * Vec4{world.x, world.y, world.z, 1}
	ndc := clip.xy / clip.w
	return {int((ndc.x * 0.5 + 0.5) * f32(r.targets.width)), int((0.5 - ndc.y * 0.5) * f32(r.targets.height))}
}

@(private = "file")
read_halves :: proc(t: ^testing.T, f: ^Fixture, target: rhi.Texture, p: [2]int) -> Vec3 {
	r := f.renderer
	rhi.device_wait_idle(f.device)
	pixels := make([]f16, int(r.targets.width * r.targets.height) * 4, context.temp_allocator)
	testing.expect(t, golden_read_texture(f.device, target, mem.slice_data_cast([]u8, pixels)), rhi.device_error(f.device))
	i := (p.y * int(r.targets.width) + p.x) * 4
	return {f32(pixels[i]), f32(pixels[i + 1]), f32(pixels[i + 2])}
}

// The lit scene with its blended surfaces, in linear light, where a world
// position shows after `count` frames.
@(private = "file")
shown :: proc(t: ^testing.T, f: ^Fixture, camera: Camera, world: Vec3, count := 3) -> Vec3 {
	r := f.renderer
	for _ in 0 ..< count {testing.expect(t, fixture_frame(f, {camera = camera}), r.error)}
	return read_halves(t, f, r.targets.display, glass_pixel(r, camera, world))
}

@(private = "file")
glass_material :: proc(color: Vec3, opacity: f32, roughness: f32 = 0.3) -> Material_Desc {
	m := DEFAULT_MATERIAL
	m.base_color = color
	m.opacity = opacity
	m.alpha_mode = .Blend
	m.roughness = roughness
	m.transmission = 1
	return m
}

@(private = "file")
SUN :: Sun_Desc{direction = {1, 1, 0}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true, indirect = 1, scattering = 1}

@(test)
glass_filters_the_scene_where_a_coat_covers_it :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, glass_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	coat := glass_material({1, 0, 0}, 0.6)
	coat.transmission = 0
	// The opacity of an opaque material is not part of its glass.
	whole := glass_material({1, 0, 0}, 0.6)
	whole.alpha_mode = .Opaque
	materials_set(r, {coat, glass_material({1, 0, 0}, 0.6), whole})
	sheet := sheet_mesh(r)
	floor := Instance_Desc{object_id = 1, mesh = sheet, transform = placed({}, {20, 1, 20}), tint = {1, 1, 1}}
	above := Camera{position = {0, 5, 0}, forward = {0, -5, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	scene_given(r, {floor}, nil, SUN, {})
	open := shown(t, &f, above, {0, 1, 0})
	testing.expect_value(t, r.targets.glass_scene, rhi.Texture(0))
	scene_given(r, {floor, {object_id = 2, mesh = sheet, transform = placed({0, 1, 0}, {2, 1, 2}), material = 1, tint = {1, 1, 1}}}, nil, SUN, {})
	covered := shown(t, &f, above, {0, 1, 0})
	// 60% of the sheet is a red surface lit by the sun and 40% of the floor shows.
	testing.expectf(t, abs(covered.g - 0.4 * open.g) < 0.03 && covered.r > open.r * 0.9, "a coat covers the floor with its own color: %v over %v", covered, open)

	for layers in ([]u32{1, 2}) {
		settings := r.settings
		settings.glass_layers = layers
		testing.expect(t, renderer_apply_settings(r, settings))
		scene_given(r, {floor, {object_id = 2, mesh = sheet, transform = placed({0, 1, 0}, {2, 1, 2}), material = 2, tint = {1, 1, 1}}}, nil, SUN, {})
		through := shown(t, &f, above, {0, 1, 0})
		// Glass diffuses nothing: the floor comes whole through the 40% the
		// sheet does not cover, and through the rest by its filter, which
		// takes what is not red and the little the surface reflects.
		testing.expectf(t, abs(through.r - (0.4 + 0.6 * 0.96) * open.r) < 0.03 && abs(through.g - 0.4 * open.g) < 0.02 && abs(through.g - through.b) < 0.01,
			"%d layers: glass filters the floor behind it: %v over %v", layers, through, open)
		testing.expect(t, r.scene.instances[1].meta.w & INSTANCE_FLAG_BLENDED != 0 && r.scene.instances[0].meta.w & INSTANCE_FLAG_BLENDED == 0, "only the glass is its own class of ray")
	}
	scene_given(r, {floor, {object_id = 2, mesh = sheet, transform = placed({0, 1, 0}, {2, 1, 2}), material = 3, tint = {1, 1, 1}}}, nil, SUN, {})
	red := shown(t, &f, above, {0, 1, 0})
	testing.expectf(t, len(r.scene.translucent) == 1 && abs(red.r - 0.96 * open.r) < 0.04 && red.g < 0.02, "a transmissive material is glass of its base color whatever its alpha mode: %v", red)

	// Where a blended surface covers nothing there is no surface, nor its
	// highlight; at half its coverage it mirrors half of the sun. Glass covers
	// whole and mirrors it as a black coat does, over what it lets through.
	card :: proc(opacity, transmission: f32) -> Material_Desc {
		m := glass_material({0, 0, 0}, opacity, 0.5)
		m.transmission = transmission
		return m
	}
	clear := card(1, 1)
	clear.base_color = {1, 1, 1}
	materials_set(r, {card(0, 0), card(0.5, 0), card(1, 0), clear})
	mirror := Camera{position = {-3, 3, 0}, forward = {3, -3, 0}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	scene_given(r, {}, nil, SUN, {})
	empty := shown(t, &f, mirror, {})
	gleams: [4]Vec3
	for &gleam, i in gleams {
		scene_given(r, {{object_id = 1, mesh = sheet, transform = placed({}, {4, 1, 4}), material = Material_Handle(i + 1), tint = {1, 1, 1}}}, nil, SUN, {})
		gleam = shown(t, &f, mirror, {})
	}
	full := gleams[2]
	near :: proc(a, b, full: Vec3) -> bool {return abs(a.x - b.x) <= 0.05 * full.x + 2e-3 && abs(a.z - b.z) <= 0.05 * full.z + 2e-3}
	testing.expectf(t, full.x > empty.x + 0.05, "a black coat mirrors the sun: %v over %v", full, empty)
	testing.expectf(t, near(gleams[0], empty, full), "a card that covers nothing shows nothing: %v, without it %v", gleams[0], empty)
	testing.expectf(t, near(gleams[1], 0.5 * (full + empty), full), "a card that covers half mirrors half: %v, whole %v, without it %v", gleams[1], full, empty)
	testing.expectf(t, near(gleams[3], full + 0.96 * empty, full), "glass mirrors the sun whole: %v, a black coat %v", gleams[3], full)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The layers of a glass material lie over it as over an opaque base. Seen
// where it mirrors the sun, a coated, fuzzy or anisotropic pane over nothing
// sends what a black opaque surface with the same layers does, since glass
// diffuses nothing, and not what a pane without them does. A tinted coat
// filters what shows through, crossed once.
@(test)
glass_wears_the_layers_of_its_material :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, glass_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	pane := glass_material({1, 1, 1}, 1, 0.5)
	black := DEFAULT_MATERIAL
	black.base_color = {0, 0, 0}
	black.roughness = 0.5
	layered :: proc(base: Material_Desc, which: int) -> Material_Desc {
		m := base
		switch which {
		case 1: m.coat.weight, m.coat.roughness = 1, 0.15
		case 2: m.fuzz = {weight = 1, color = {1, 1, 1}, roughness = 0.5}
		case 3: m.anisotropy.amount = 0.8
		}
		return m
	}
	NAMES :: [4]string{"plain", "coat", "fuzz", "anisotropy"}
	// Smooth enough for the sun not to shine in them seen from above.
	clear := glass_material({1, 1, 1}, 1, 0.2)
	tinted := layered(clear, 1)
	tinted.coat.color = {1, 0.25, 0.25}
	materials: [10]Material_Desc
	for i in 0 ..< 4 {materials[i], materials[4 + i] = layered(pane, i), layered(black, i)}
	materials[8], materials[9] = clear, tinted
	materials_set(r, materials[:])
	sheet := sheet_mesh(r)
	mirror := Camera{position = {-3, 3, 0}, forward = {3, -3, 0}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	seen :: proc(t: ^testing.T, f: ^Fixture, sheet: Mesh_Handle, material: int, camera: Camera) -> Vec3 {
		scene_given(f.renderer, {{object_id = 1, mesh = sheet, transform = placed({}, {4, 1, 4}), material = Material_Handle(material + 1), tint = {1, 1, 1}}}, nil, SUN, {})
		return shown(t, f, camera, {})
	}
	plain := seen(t, &f, sheet, 0, mirror)
	for name, i in NAMES {
		glass := seen(t, &f, sheet, i, mirror)
		testing.expectf(t, len(r.scene.translucent) == 1 && r.scene.translucent[0].layered == (i > 0), "%s: the pane is glass, with layers or without", name)
		opaque := seen(t, &f, sheet, 4 + i, mirror)
		testing.expectf(t, abs(glass.x - opaque.x) <= 0.05 * opaque.x + 2e-3 && abs(glass.z - opaque.z) <= 0.05 * opaque.z + 2e-3, "%s: glass %v, black opaque surface %v", name, glass, opaque)
		// The fuzz changes least there: it takes a few percent of the lobe and adds its sheen.
		if i > 0 {testing.expectf(t, abs(glass.x - plain.x) > 0.05 * plain.x, "%s: the layer shows on glass: %v, without it %v", name, glass, plain)}
	}

	floor := Instance_Desc{object_id = 1, mesh = sheet, transform = placed({}, {20, 1, 20}), tint = {1, 1, 1}}
	above := Camera{position = {0, 5, 0}, forward = {0, -5, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	over := proc(t: ^testing.T, f: ^Fixture, floor: Instance_Desc, sheet: Mesh_Handle, material: int, camera: Camera) -> Vec3 {
		scene_given(f.renderer, {floor, {object_id = 2, mesh = sheet, transform = placed({0, 1, 0}, {2, 1, 2}), material = Material_Handle(material + 1), tint = {1, 1, 1}}}, nil, SUN, {})
		return shown(t, f, camera, {0, 1, 0})
	}
	through := over(t, &f, floor, sheet, 8, above)
	filtered := over(t, &f, floor, sheet, 9, above)
	// The coat leaves the square root of its color crossed once face on, and
	// reflects about as much as the glass under it would without it.
	testing.expectf(t, abs(filtered.x - through.x) < 0.03 * through.x && abs(filtered.y - 0.5 * filtered.x) < 0.02 * filtered.x && abs(filtered.y - filtered.z) < 0.01 * filtered.x,
		"a tinted coat filters the floor through glass: %v, without it %v", filtered, through)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
glass_solid_filters_once_and_absorbs :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, glass_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	green := glass_material({0.2, 1, 0.2}, 1, 0.05)
	green.thickness = 0.5
	smoky := glass_material({1, 1, 1}, 1, 0.05)
	smoky.thickness = 0.5
	smoky.attenuation_color = {1, 1, 0.25}
	smoky.attenuation_distance = 0.5
	materials_set(r, {green, smoky, glass_material({1, 1, 1}, 1, 0.05)})
	sheet, box := sheet_mesh(r), box_mesh(r)
	floor := Instance_Desc{object_id = 1, mesh = sheet, transform = placed({}, {20, 1, 20}), tint = {1, 1, 1}}
	block := Instance_Desc{object_id = 2, mesh = box, transform = placed({0, 1, 0}, {2, 0.5, 2}), material = 1, tint = {1, 1, 1}}
	pane := Instance_Desc{object_id = 3, mesh = sheet, transform = placed({0, 2, 0}, {3, 1, 3}), material = 3, tint = {1, 1, 1}}
	above := Camera{position = {0, 5, 0}, forward = {0, -5, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	scene_given(r, {floor}, nil, SUN, {})
	open := shown(t, &f, above, {0, 1, 0})
	scene_given(r, {floor, pane}, nil, SUN, {})
	paned := shown(t, &f, above, {})
	// An instance that mirrors its mesh shows the faces its twin shows. Behind
	// a pane, the forward pass draws the solid: here one sunk in the floor,
	// which hides its back face, so only the face the view enters filters it.
	for mirrored in ([2]bool{false, true}) {
		scale := Vec3{-2 if mirrored else 2, 0.5, 2}
		block.transform = placed({0, 1, 0}, scale)
		scene_given(r, {floor, block}, nil, SUN, {})
		through := shown(t, &f, above, {0, 1, 0})
		testing.expectf(t, abs(through.g - 0.96 * open.g) < 0.04 && abs(through.r - 0.2 * 0.96 * open.r) < 0.03, "mirrored %v: the two faces of a solid are one filter: %v over %v", mirrored, through, open)
		rhi.device_wait_idle(f.device)
		depths := make([]f32, int(r.targets.width * r.targets.height), context.temp_allocator)
		testing.expect(t, golden_read_texture(f.device, r.targets.glass[0].depth, mem.slice_data_cast([]u8, depths)), rhi.device_error(f.device))
		center := glass_pixel(r, above, {0, 1, 0})
		depth := depths[center.y * int(r.targets.width) + center.x]
		testing.expectf(t, abs(depth - 3.75) < 0.02, "mirrored %v: the layer is the face where the view enters the solid: depth %v", mirrored, depth)
		sunk := block
		sunk.transform = placed({}, scale)
		scene_given(r, {floor, sunk, pane}, nil, SUN, {})
		behind := shown(t, &f, above, {})
		testing.expectf(t, abs(behind.g - 0.96 * paned.g) < 0.04 && abs(behind.r - 0.2 * 0.96 * paned.r) < 0.03, "mirrored %v: behind a pane the face the view enters filters the floor: %v over %v", mirrored, behind, paned)
	}
	block.transform = placed({0, 1, 0}, {2, 0.5, 2})
	block.material = 2
	scene_given(r, {floor, block}, nil, SUN, {})
	absorbed := shown(t, &f, above, {0, 1, 0})
	testing.expectf(t, abs(absorbed.r - 0.96 * open.r) < 0.04 && abs(absorbed.b - 0.25 * 0.96 * open.b) < 0.03, "half a unit of the solid leaves a quarter of the blue: %v over %v", absorbed, open)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The rays of the indirect light go through glass: a room lit by the sky
// through a sheet of red glass takes the light of the sky white.
@(test)
glass_lets_the_indirect_light_through_uncolored :: proc(t: ^testing.T) {
	settings := glass_settings()
	settings.gi_enabled = true
	f: Fixture
	if !fixture_init(t, &f, 96, 64, settings, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	materials_set(r, {glass_material({1, 0.2, 0.2}, 1, 0.05)})
	sheet, box := sheet_mesh(r), box_mesh(r)
	// A closed white room under the glass, lit by the sky alone.
	white := Vec3{0.9, 0.9, 0.9}
	room := []Instance_Desc{
		{object_id = 1, mesh = box, transform = placed({0, -0.1, 0}, {6, 0.2, 6}), tint = white},
		{object_id = 2, mesh = box, transform = placed({-3.1, 1.6, 0}, {0.2, 3.4, 6.4}), tint = white},
		{object_id = 3, mesh = box, transform = placed({3.1, 1.6, 0}, {0.2, 3.4, 6.4}), tint = white},
		{object_id = 4, mesh = box, transform = placed({0, 1.6, -3.1}, {6.4, 3.4, 0.2}), tint = white},
		{object_id = 5, mesh = box, transform = placed({0, 1.6, 3.1}, {6.4, 3.4, 0.2}), tint = white},
		{object_id = 6, mesh = sheet, transform = placed({0, 3.2, 0}, {6.4, 1, 6.4}), material = 1, tint = {1, 1, 1}},
	}
	camera := Camera{position = {0, 2.5, 2.5}, forward = {0, -2.5, -2.5}, up = {0, 1, 0}, fov_y = 70, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	floor := glass_pixel(r, camera, {0, 0.001, 0})
	for provider in ([]Trace_Mode{.Software, .Hardware}) {
		if !fixture_traces(r, provider) {continue}
		settings := r.settings
		settings.trace_mode = provider
		testing.expect(t, renderer_apply_settings(r, settings))
		scene_given(r, room, nil, {}, {sky = {1, 1, 1}})
		for _ in 0 ..< 48 {testing.expect(t, fixture_frame(&f, {camera = camera, inspection = {mode = .Indirect}}), r.error)}
		light := read_halves(t, &f, r.targets.display, floor)
		testing.expectf(t, light.r > 0.05 && abs(light.g - light.r) < 0.1 * light.r, "%v: the glass leaves the light of the sky white: %v", provider, light)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A solid that is not a pane is crossed as a slab as thick as its material:
// a ball of glass moves the wall behind it aside, without turning it over.
@(test)
glass_ball_shows_the_scene_behind_it_across_a_slab :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 128, 96, glass_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	clear := glass_material({1, 1, 1}, 1, 0.05)
	clear.thickness = 1
	materials_set(r, {clear})
	sheet, ball := sheet_mesh(r), ball_mesh(r)
	// A wall that glows red on the left and blue on the right.
	red := Instance_Desc{object_id = 1, mesh = sheet, transform = standing({-4, 1, -4}, 8, 12), tint = {0, 0, 0}, emission = {1, 0, 0}}
	blue := Instance_Desc{object_id = 2, mesh = sheet, transform = standing({4, 1, -4}, 8, 12), tint = {0, 0, 0}, emission = {0, 0, 1}}
	lens := Instance_Desc{object_id = 3, mesh = ball, transform = placed({0, 1, 0}, {2, 2, 2}), material = 1, tint = {1, 1, 1}}
	camera := Camera{position = {0, 1, 6}, forward = {0, 0, -6}, up = {0, 1, 0}, fov_y = 40, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	scene_given(r, {red, blue, lens}, nil, {}, {})
	through_left := shown(t, &f, camera, {-0.4, 1, 0})
	through_right := shown(t, &f, camera, {0.4, 1, 0})
	testing.expectf(t, through_left.r > 0.7 && through_left.b < 0.1 && through_right.b > 0.7 && through_right.r < 0.1,
		"a ball of glass shows the wall behind it as it stands: %v on its left, %v on its right", through_left, through_right)
	beside := shown(t, &f, camera, {-1.6, 1, 0})
	testing.expectf(t, beside.r > 0.9 && beside.b < 0.05, "beside the ball the wall is where it was: %v", beside)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
glass_pane_shows_what_a_ray_through_it_finds :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 256, 192, glass_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	clear := glass_material({1, 1, 1}, 1, 0.05)
	clear.thickness = 0.4
	materials_set(r, {clear})
	// The same box twice: the loose vertex of the second lies between its top
	// and its bottom, so only the first is a pane; the second is crossed as a
	// slab as thick as its material, as thick as the box.
	sheet, slab, solid := sheet_mesh(r), box_mesh(r), box_mesh(r, Vec3{0.5, 0.1, 0.2})
	// A floor that glows red where x < 0 and blue where x > 0.
	red := Instance_Desc{object_id = 1, mesh = sheet, transform = placed({-5, 0, 0}, {10, 1, 10}), tint = {0, 0, 0}, emission = {1, 0, 0}}
	blue := Instance_Desc{object_id = 2, mesh = sheet, transform = placed({5, 0, 0}, {10, 1, 10}), tint = {0, 0, 0}, emission = {0, 0, 1}}
	pane := Instance_Desc{object_id = 3, mesh = slab, transform = placed({0, 0.6, 0}, {3, 0.4, 3}), material = 1, tint = {1, 1, 1}}
	camera := Camera{position = {2.5, 3, 0}, forward = {-2.5, -3, 0}, up = {0, 1, 0}, fov_y = 40, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	// About 40 degrees from straight down, the view leaves the pane 15 cm
	// nearer the camera than it would go without it.
	at := [4]f32{-0.3, -0.2, -0.05, 0.05}
	scene_given(r, {red, blue, pane}, nil, {}, {})
	seen: [4]Vec3
	for &c, i in seen {c = shown(t, &f, camera, {at[i], 0, 0})}
	testing.expectf(t, seen[1].r > 0.7 && seen[1].b < 0.1 && seen[2].b > 0.7 && seen[2].r < 0.1, "the edge of the floor shows moved aside: %v at -20 cm, %v at -5 cm", seen[1], seen[2])
	pane.mesh = solid
	scene_given(r, {red, blue, pane}, nil, {}, {})
	for c, i in seen {
		solid := shown(t, &f, camera, {at[i], 0, 0})
		testing.expectf(t, abs(c.r - solid.r) < 0.05 && abs(c.b - solid.b) < 0.05, "at %v m the pane shows %v and the solid %v", at[i], c, solid)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
glass_rough_scatters_what_shows_through :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 128, 96, glass_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	materials_set(r, {glass_material({1, 1, 1}, 1, 0.05), glass_material({1, 1, 1}, 1, 0.7)})
	sheet := sheet_mesh(r)
	red := Instance_Desc{object_id = 1, mesh = sheet, transform = standing({-4, 1, -4}, 8, 12), tint = {0, 0, 0}, emission = {1, 0, 0}}
	blue := Instance_Desc{object_id = 2, mesh = sheet, transform = standing({4, 1, -4}, 8, 12), tint = {0, 0, 0}, emission = {0, 0, 1}}
	pane := Instance_Desc{object_id = 3, mesh = sheet, transform = standing({0, 1, 0}, 6, 4), material = 1, tint = {1, 1, 1}}
	camera := Camera{position = {0, 1, 5}, forward = {0, 0, -5}, up = {0, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	// A point of the wall a hand's width into its red half.
	point := Vec3{-0.12, 1, 0}
	scene_given(r, {red, blue, pane}, nil, {}, {})
	sharp := shown(t, &f, camera, point)
	testing.expectf(t, sharp.r > 0.85 && sharp.b < 0.05, "smooth glass shows the wall as it is: %v", sharp)
	pane.material = 2
	scene_given(r, {red, blue, pane}, nil, {}, {})
	frosted := shown(t, &f, camera, point)
	testing.expectf(t, frosted.r > 0.3 && frosted.b > 0.1, "frosted glass mixes in the blue beside it: %v", frosted)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The cull pass turns the glass passes off while every blended instance is
// hidden, with the same two-phase test as the opaque draws.
@(test)
glass_behind_a_wall_shows_the_frame_the_wall_goes :: proc(t: ^testing.T) {
	f: Fixture
	settings := glass_settings()
	if !fixture_init(t, &f, 96, 64, settings, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	materials_set(r, {glass_material({1, 0, 0}, 0.6)})
	sheet := sheet_mesh(r)
	floor := Instance_Desc{object_id = 1, mesh = sheet, transform = placed({}, {20, 1, 20}), tint = {1, 1, 1}}
	pane := Instance_Desc{object_id = 2, mesh = sheet, transform = placed({0, 1, 0}, {2, 1, 2}), material = 1, tint = {1, 1, 1}}
	wall := Instance_Desc{object_id = 3, mesh = sheet, transform = placed({0, 2, 0}, {8, 1, 8}), tint = {1, 1, 1}}
	above := Camera{position = {0, 5, 0}, forward = {0, -5, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	scene_given(r, {floor, pane, wall}, nil, SUN, {})
	hidden := shown(t, &f, above, {0, 1, 0}, 4)
	testing.expectf(t, abs(hidden.r - hidden.g) < 0.01 && hidden.r > 0.5, "the wall hides the glass: %v", hidden)
	// The draw of the pane, the one blended instance of the view (translucent_draws.comp).
	pane_indices :: proc(f: ^Fixture) -> u32 {
		draw: [1]rhi.Draw_Indexed_Indirect
		if !rhi.buffer_read_slice(f.device, f.renderer.scene.translucent_draws, 0, draw[:]) {return max(u32)}
		return draw[0].index_count
	}
	testing.expect_value(t, pane_indices(&f), 0)
	scene_given(r, {floor, pane}, nil, SUN, {})
	first := shown(t, &f, above, {0, 1, 0}, 1)
	settled := shown(t, &f, above, {0, 1, 0}, 3)
	testing.expectf(t, first.g < 0.6 * first.r && abs(first.r - settled.r) < 0.02 && abs(first.g - settled.g) < 0.02, "the glass is there in the first frame without the wall: %v, then %v", first, settled)
	testing.expectf(t, pane_indices(&f) > 0, "without the wall the pane is drawn")
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
glass_passes_preserve_the_image_past_the_command_budget :: proc(t: ^testing.T) {
	f: Fixture
	settings := glass_settings()
	settings.glass_layers = 2
	if !fixture_init(t, &f, 32, 24, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	if !testing.expect(t, materials_set(r, {
		glass_material({1, 0.8, 0.8}, 0.2),
		glass_material({0.4, 1, 0.8}, 0.5),
		glass_material({0.8, 0.4, 1}, 0.7),
	}), r.error) {return}
	sheet := sheet_mesh(r)
	camera := Camera{position = {0, 0, 6}, forward = {0, 0, -1}, up = {0, 1, 0},
		fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	FILLERS :: 6000
	instances := make([]Instance_Desc, FILLERS + 5, context.temp_allocator)
	for z, i in ([4]f32{3, 2, 1, -1}) {
		instances[i] = {object_id = u64(i + 1), mesh = sheet, material = Material_Handle(i % 3 + 1),
			transform = standing({0, 0, z}, 2, 2), tint = 1}
	}
	for &inst, i in instances[4:] {
		inst = {object_id = u64(i + 5), mesh = sheet, material = 1,
			transform = standing({2, 0, 0}, 0.01, 0.01), tint = 1}
	}
	instances[len(instances) - 1].transform = standing({100, 0, 0}, 1, 1)
	env := Environment{background = {0.4, 0.4, 0.4}, use_background = true}
	if !testing.expect(t, scene_given(r, instances[:4], nil, SUN, env), r.error) {return}
	expected := shown(t, &f, camera, {}, count = 1)
	if !testing.expect(t, scene_given(r, instances, nil, SUN, env), r.error) {return}
	actual := shown(t, &f, camera, {}, count = 1)
	delta := actual - expected
	testing.expectf(t, max(abs(delta.x), abs(delta.y), abs(delta.z)) < 0.002,
		"split glass passes changed the center pixel: %v, expected %v", actual, expected)
	testing.expect_value(t, rhi.device_error(f.device), "")
	view, projection, _ := camera_matrices(camera, 32.0 / 24.0)
	frame := Gpu_Frame{frustum = frustum_from_eye(projection * matrix_from_eye(view), camera.position),
		camera_position = {0, 0, 6, camera.near}, layers = LAYERS_ALL}
	testing.expect_value(t, len(glass_visible(&r.scene, &frame)), FILLERS + 4)
}

@(test)
glass_cost_counts_only_forward_fragments_by_mesh_and_material :: proc(t: ^testing.T) {
	f: Fixture
	settings := glass_settings()
	settings.glass_layers = 2
	if !fixture_init(t, &f, 32, 24, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	glass := glass_material({0.8, 0.6, 0.4}, 0.5)
	if !testing.expect(t, materials_set(r, {glass, glass, glass, glass}), r.error) {return}
	sheet := sheet_mesh(r)
	camera := Camera{position = {0, 0, 6}, forward = {0, 0, -1}, up = {0, 1, 0},
		fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	instances: [5]Instance_Desc
	for z, i in ([5]f32{3, 2, 1, 0, 0}) {
		x := f32(100) if i == 4 else 0
		instances[i] = {object_id = u64(i + 1), mesh = sheet, material = Material_Handle(min(i, 3) + 1),
			transform = standing({x, 0, z}, 20, 20), tint = 1}
	}
	if !testing.expect(t, scene_given(r, instances[:], nil, SUN, {}), r.error) {return}
	if !testing.expect(t, renderer_frame(r, {camera = camera}), r.error) {return}
	if !testing.expect_value(t, renderer_cost_ask(r), "") {return}
	cost: Cost
	ready := false
	for _ in 0 ..< 8 {
		if !testing.expect(t, renderer_frame(r, {camera = camera}), r.error) {return}
		if cost, ready = renderer_cost(r); ready {break}
	}
	if !testing.expect(t, ready, "the forward fragment count never came") {return}
	pixels := r.targets.width * r.targets.height
	for row, i in cost.materials[1:5] {
		testing.expect_value(t, row.pixels, 0)
		testing.expect_value(t, row.translucent_fragments, pixels if i >= 2 else 0)
	}
	testing.expect_value(t, cost.meshes[sheet].translucent_fragments, 2 * pixels)
}

@(test)
glass_frames_stay_allocation_free :: proc(t: ^testing.T) {
	f: Fixture
	settings := glass_settings()
	settings.gi_enabled = true
	settings.glass_layers = 2
	if !fixture_init(t, &f, 96, 64, settings, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	solid := glass_material({0.96, 0.98, 1}, 1, 0.05)
	solid.thickness = 0.5
	materials_set(r, {solid, glass_material({1, 0.8, 0.8}, 1)})
	sheet, box := sheet_mesh(r), box_mesh(r)
	instances := []Instance_Desc{
		{object_id = 1, mesh = sheet, transform = placed({}, {20, 1, 20}), tint = {1, 1, 1}},
		{object_id = 2, mesh = box, transform = placed({0, 1, 0}, {2, 0.5, 2}), material = 1, tint = {1, 1, 1}},
		{object_id = 3, mesh = sheet, transform = placed({0, 2, 0}, {2, 1, 2}), material = 2, tint = {1, 1, 1}},
		{object_id = 4, mesh = sheet, transform = placed({0, 0.5, 0}, {2, 1, 2}), material = 2, tint = {1, 1, 1}},
	}
	scene_given(r, instances, []Light_Desc{{position = {1, 3, 1}, color = {1, 1, 1}, intensity = 8 * math.PI, range = 10, indirect = 1, scattering = 1}}, SUN, {})
	camera := Camera{position = {0, 5, 0.5}, forward = {0, -5, -0.5}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 4 {testing.expect(t, fixture_frame(&f, {camera = camera}), r.error)}
	targets := [2]rhi.Texture{r.targets.glass_scene, r.targets.glass[1].depth}
	testing.expect(t, targets[0] != 0 && targets[1] != 0, "both layers have their targets")
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	{
		context.allocator = mem.tracking_allocator(&tracking)
		for _ in 0 ..< 8 {testing.expect(t, fixture_frame(&f, {camera = camera}), r.error)}
	}
	testing.expect_value(t, tracking.total_allocation_count, 0)
	testing.expect_value(t, [2]rhi.Texture{r.targets.glass_scene, r.targets.glass[1].depth}, targets)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// From inside a block of water: straight up the view leaves it into the sky,
// past the critical angle the top reflects the floor inside, and the water
// absorbs what the view crosses of it from the camera.
@(test)
glass_seen_from_inside_bends_out_reflects_past_the_critical_angle_absorbs_and_scatters :: proc(t: ^testing.T) {
	f: Fixture
	// What a back face reflects inside comes from the probe volume.
	inside_settings := glass_settings()
	inside_settings.gi_enabled = true
	if !fixture_init(t, &f, 96, 64, inside_settings, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	water := glass_material({1, 1, 1}, 1, 0.02)
	water.thickness = 1
	water.ior = 1.33
	murky := water
	murky.attenuation_color = {1, 1, 0.25}
	murky.attenuation_distance = 1
	milky := murky
	milky.scatter_color = {0, 0, 1}
	materials_set(r, {water, murky, milky})
	sheet, box := sheet_mesh(r), box_mesh(r)
	block := Instance_Desc{object_id = 1, mesh = box, transform = placed({}, {40, 4, 40}), material = 1, tint = {1, 1, 1}}
	floor := Instance_Desc{object_id = 2, mesh = sheet, transform = placed({0, -1.9, 0}, {39, 1, 39}), tint = {0.1, 1, 0.1}}
	sky := Environment{sky = {0.1, 0.1, 1}}
	critical := math.asin(f32(1) / 1.33)
	look :: proc(from: Vec3, angle: f32) -> Camera {
		return {position = from, forward = {math.sin(angle), math.cos(angle), 0}, up = {0, 0, 1}, fov_y = 20, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	}
	for provider in ([]Trace_Mode{.Software, .Hardware}) {
		if !fixture_traces(r, provider) {continue}
		settings := r.settings
		settings.trace_mode = provider
		testing.expect(t, renderer_apply_settings(r, settings))
		scene_given(r, {block, floor}, nil, SUN, sky)
		inside := Vec3{0, 0, 0}
		window := look(inside, critical - 0.25)
		up := shown(t, &f, window, window.position + window.forward)
		testing.expectf(t, up.b > 2 * up.g && up.b > 0.05, "%v: within the window the view leaves into the sky: %v", provider, up)
		mirror := look(inside, critical + 0.1)
		reflected := shown(t, &f, mirror, mirror.position + mirror.forward, 16)
		testing.expectf(t, reflected.g > 2 * reflected.b && reflected.g > 0.05, "%v: past the critical angle the top reflects the floor inside: %v", provider, reflected)
		// Looking down at the floor a metre away, with nothing of the glass between.
		down := Camera{position = {0, -0.9, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 30, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
		clear := shown(t, &f, down, {0, -1.9, 0})
		block.material = 2
		scene_given(r, {block, floor}, nil, SUN, sky)
		absorbed := shown(t, &f, down, {0, -1.9, 0})
		testing.expectf(t, clear.g > 0.05 && abs(absorbed.g - clear.g) < 0.02 * clear.g + 1e-3 && abs(absorbed.b - 0.25 * clear.b) < 0.05 * clear.b + 1e-3,
			"%v: a metre of the water leaves a quarter of the blue: %v of %v", provider, absorbed, clear)
		// What it stops of the blue it scatters back towards the eye, lit by the sky and the sun that reach it.
		block.material = 3
		scene_given(r, {block, floor}, nil, SUN, sky)
		scattered := shown(t, &f, down, {0, -1.9, 0})
		testing.expectf(t, scattered.b > absorbed.b * 1.05 && abs(scattered.g - absorbed.g) < 0.02 * absorbed.g + 1e-3,
			"%v: a solid that scatters adds its color to what it lets through: %v over %v", provider, scattered, absorbed)
		block.material = 1
		// From outside nothing of this applies: the camera over the block sees its top as glass.
		outside := Camera{position = {0, 6, 0.01}, forward = {0, -7.9, -0.01}, up = {0, 0, -1}, fov_y = 30, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
		scene_given(r, {block, floor}, nil, SUN, sky)
		seen := shown(t, &f, outside, {0, -1.9, 0})
		testing.expectf(t, seen.g > 2 * seen.b, "%v: from outside the floor shows through the top: %v", provider, seen)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A blended sheet among many lights, with and without shadows, takes the
// light of every one that reaches each of its points: the same whether the
// lists of its instance hold them (translucent_draws.comp) or, a wide sheet
// whose box reaches more than a list holds, those of the cells it is split into.
@(test)
blended_light_is_the_same_from_the_lists_of_its_instance_as_from_those_of_its_cells :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, glass_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	decal := DEFAULT_MATERIAL
	decal.base_color = {0.8, 0.8, 0.8}
	decal.opacity = 0.5
	decal.alpha_mode = .Blend
	materials_set(r, {decal})
	sheet := sheet_mesh(r)
	lights := make([dynamic]Light_Desc, context.temp_allocator)
	for x in 0 ..< 20 {
		for z in 0 ..< 20 {
			append(&lights, Light_Desc{position = {-11.4 + 1.2 * f32(x), 1, -11.4 + 1.2 * f32(z)}, color = {1, 0.8, 0.6},
				intensity = 2, range = 1.8, shadowless = (x + z) % 3 != 0})
		}
	}
	camera := Camera{position = {0, 4, 0.01}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 40, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	at := Vec3{0.3, 0.5, 0.2}
	seen: [2]Vec3
	lists, sides: [2]u32
	for side, i in ([2]f32{2, 40}) {
		floor := Instance_Desc{object_id = 1, mesh = sheet, transform = placed({}, {30, 1, 30}), tint = {1, 1, 1}}
		blended := Instance_Desc{object_id = 2, mesh = sheet, transform = placed(at, {side, 1, side}), material = 1, tint = {1, 1, 1}}
		testing.expect(t, scene_given(r, {floor, blended}, lights[:], {}, {}), r.error)
		seen[i] = shown(t, &f, camera, at, 4)
		words := make([]u32, (abi.TRANSLUCENT_LIST_COLUMNS * LIGHT_LIST_TILE) * (u32(r.scene.translucent_draws_capacity + abi.TRANSLUCENT_CELLS) / abi.TRANSLUCENT_LIST_COLUMNS) * LIGHT_LIST_ROWS, context.temp_allocator)
		testing.expect(t, golden_read_texture(f.device, r.scene.translucent_lists, mem.slice_data_cast([]u8, words)))
		lists[i] = words[0]
		cells: [2][2]u32
		testing.expect(t, rhi.buffer_read_slice(f.device, r.scene.translucent_entries, 0, cells[:]))
		sides[i] = cells[1].y
	}
	WALK :: 0xFFFFFFFF
	testing.expectf(t, lists[0] != WALK && lists[0] > 0, "the list of the sheet alone holds its shadowless lights: %v", lists[0])
	testing.expectf(t, lists[1] == WALK && sides[0] == 0x010101 && sides[1] != 0x010101,
		"the box of the wide sheet reaches more than a list holds (%v) and is split (%x), the other not (%x)", lists[1], sides[1], sides[0])
	delta := seen[0] - seen[1]
	testing.expectf(t, seen[0].x > 0 && max(abs(delta.x), abs(delta.y), abs(delta.z)) <= 1e-3 * seen[0].x, "the same light from the lists of the sheet and of a cell: %v and %v", seen[0], seen[1])
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A decal blended 1 cm over the whole floor of a closed room is as dark as
// the floor under the roof the sun lights, frame after frame of a still view:
// a forward blend traces no ray, so the maps of the view hide the sun from it
// at the level of its pixel, which the floor beside it reads, in the page of
// its texel or the nearest coarser one drawn, near the eye as far from it.
@(test)
blended_decal_indoors_takes_the_shadow_of_the_roof :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 320, 180, glass_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	decal := DEFAULT_MATERIAL
	decal.base_color = {0.8, 0.8, 0.8}
	decal.opacity = 0.9
	decal.alpha_mode = .Blend
	materials_set(r, {decal})
	box := box_mesh(r)
	sheet := sheet_mesh(r)
	instances := []Instance_Desc{
		{object_id = 1, mesh = box, transform = placed({0, -0.1, 0}, {24, 0.2, 24}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = box, transform = placed({0, 3.1, 0}, {24, 0.2, 24}), tint = {0.8, 0.8, 0.8}},
		{object_id = 3, mesh = box, transform = placed({12, 1.5, 0}, {0.2, 3.2, 24}), tint = {0.8, 0.8, 0.8}},
		{object_id = 4, mesh = box, transform = placed({-12, 1.5, 0}, {0.2, 3.2, 24}), tint = {0.8, 0.8, 0.8}},
		{object_id = 5, mesh = box, transform = placed({0, 1.5, 12}, {24, 3.2, 0.2}), tint = {0.8, 0.8, 0.8}},
		{object_id = 6, mesh = box, transform = placed({0, 1.5, -12}, {24, 3.2, 0.2}), tint = {0.8, 0.8, 0.8}},
		{object_id = 7, mesh = sheet, transform = placed({0, 0.01, 0}, {23.6, 1, 23.6}), material = 1, tint = {1, 1, 1}},
	}
	sun := Sun_Desc{direction = {1, 1, 0.3}, color = {1, 1, 1}, illuminance = 10 * math.PI, enabled = true, indirect = 1, scattering = 1}
	testing.expect(t, scene_given(r, instances, nil, sun, {}), r.error)
	camera := Camera{position = {-10, 2.5, 0.01}, forward = {10, -2.5, 0}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 30 {testing.expect(t, fixture_frame(&f, {camera = camera}), r.error)}
	rhi.device_wait_idle(f.device)
	w, h := int(r.targets.width), int(r.targets.height)
	pixels := make([]f16, w * h * 4, context.temp_allocator)
	testing.expect(t, golden_read_texture(f.device, r.targets.display, mem.slice_data_cast([]u8, pixels)), rhi.device_error(f.device))
	// The lower half of the image is the decal over the floor, near and far.
	lit, brightest := 0, f32(0)
	for y in h / 2 ..< h {
		for x in 0 ..< w {
			v := f32(pixels[(y * w + x) * 4])
			if v > 0.02 {lit += 1}
			brightest = max(brightest, v)
		}
	}
	testing.expectf(t, lit == 0, "%d of %d pixels of the decal under the roof are lit, up to %f", lit, w * (h - h / 2), brightest)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}
