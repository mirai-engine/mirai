package mirai_render

import "core:math"
import "core:mem"
import "core:testing"
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
	s.reflections = false
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
@(private = "file")
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
SUN :: Sun_Desc{direction = {1, 1, 0}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true}

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
	scene_set(r, {floor}, nil, SUN, {})
	open := shown(t, &f, above, {0, 1, 0})
	testing.expect_value(t, r.targets.glass_scene, rhi.Texture(0))
	scene_set(r, {floor, {object_id = 2, mesh = sheet, transform = placed({0, 1, 0}, {2, 1, 2}), material = 1, tint = {1, 1, 1}}}, nil, SUN, {})
	covered := shown(t, &f, above, {0, 1, 0})
	// 60% of the sheet is a red surface lit by the sun and 40% of the floor shows.
	testing.expectf(t, abs(covered.g - 0.4 * open.g) < 0.03 && covered.r > open.r * 0.9, "a coat covers the floor with its own color: %v over %v", covered, open)

	for layers in ([]u32{1, 2}) {
		settings := r.settings
		settings.glass_layers = layers
		testing.expect(t, renderer_apply_settings(r, settings))
		scene_set(r, {floor, {object_id = 2, mesh = sheet, transform = placed({0, 1, 0}, {2, 1, 2}), material = 2, tint = {1, 1, 1}}}, nil, SUN, {})
		through := shown(t, &f, above, {0, 1, 0})
		// Glass diffuses nothing: the floor comes through its filter, which
		// takes 60% of what is not red and the little the surface reflects.
		testing.expectf(t, abs(through.r - 0.96 * open.r) < 0.04 && abs(through.g - 0.4 * 0.96 * open.g) < 0.03 && abs(through.g - through.b) < 0.01,
			"%d layers: glass filters the floor behind it: %v over %v", layers, through, open)
		testing.expect(t, r.scene.instances[1].meta.w & INSTANCE_FLAG_BLENDED != 0 && r.scene.instances[0].meta.w & INSTANCE_FLAG_BLENDED == 0, "only the glass is its own class of ray")
	}
	scene_set(r, {floor, {object_id = 2, mesh = sheet, transform = placed({0, 1, 0}, {2, 1, 2}), material = 3, tint = {1, 1, 1}}}, nil, SUN, {})
	red := shown(t, &f, above, {0, 1, 0})
	testing.expectf(t, len(r.scene.translucent) == 1 && abs(red.r - 0.96 * open.r) < 0.04 && red.g < 0.02, "a transmissive material is glass of its base color whatever its alpha mode: %v", red)
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
		scene_set(f.renderer, {{object_id = 1, mesh = sheet, transform = placed({}, {4, 1, 4}), material = Material_Handle(material + 1), tint = {1, 1, 1}}}, nil, SUN, {})
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
		scene_set(f.renderer, {floor, {object_id = 2, mesh = sheet, transform = placed({0, 1, 0}, {2, 1, 2}), material = Material_Handle(material + 1), tint = {1, 1, 1}}}, nil, SUN, {})
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
glass_solid_filters_once_absorbs_and_shades_colored_shadows :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, glass_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	green := glass_material({0.2, 1, 0.2}, 1, 0.05)
	green.thickness = 0.5
	smoky := glass_material({1, 1, 1}, 0, 0.05)
	smoky.thickness = 0.5
	smoky.attenuation_color = {1, 1, 0.25}
	smoky.attenuation_distance = 0.5
	materials_set(r, {green, smoky})
	sheet, box := sheet_mesh(r), box_mesh(r)
	floor := Instance_Desc{object_id = 1, mesh = sheet, transform = placed({}, {20, 1, 20}), tint = {1, 1, 1}}
	block := Instance_Desc{object_id = 2, mesh = box, transform = placed({0, 1, 0}, {2, 0.5, 2}), material = 1, tint = {1, 1, 1}}
	above := Camera{position = {0, 5, 0}, forward = {0, -5, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	scene_set(r, {floor}, nil, SUN, {})
	open := shown(t, &f, above, {0, 1, 0})
	scene_set(r, {floor, block}, nil, SUN, {})
	through := shown(t, &f, above, {0, 1, 0})
	testing.expectf(t, abs(through.g - 0.96 * open.g) < 0.04 && abs(through.r - 0.2 * 0.96 * open.r) < 0.03, "the two faces of a solid are one filter: %v over %v", through, open)
	rhi.device_wait_idle(f.device)
	depths := make([]f32, int(r.targets.width * r.targets.height), context.temp_allocator)
	testing.expect(t, golden_read_texture(f.device, r.targets.glass[0].depth, mem.slice_data_cast([]u8, depths)), rhi.device_error(f.device))
	center := glass_pixel(r, above, {0, 1, 0})
	depth := depths[center.y * int(r.targets.width) + center.x]
	testing.expectf(t, abs(depth - 3.75) < 0.02, "the layer is the face where the view enters the solid: depth %v", depth)
	block.material = 2
	scene_set(r, {floor, block}, nil, SUN, {})
	absorbed := shown(t, &f, above, {0, 1, 0})
	testing.expectf(t, abs(absorbed.r - 0.96 * open.r) < 0.04 && abs(absorbed.b - 0.25 * 0.96 * open.b) < 0.03, "half a unit of the solid leaves a quarter of the blue: %v over %v", absorbed, open)

	// The light under the block: untouched without colored shadows, and with
	// them filtered once by the solid, which reflects at each of its two faces.
	side := Camera{position = {0, 3, 6}, forward = {0, -3, -6}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	sun := Sun_Desc{direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true}
	under := glass_pixel(r, side, {0, 0, 0.5})
	for provider in ([]Trace_Mode{.Software, .Hardware}) {
		if provider == .Hardware && !r.hardware_rt_verified || provider == .Software && !SOFTWARE_TRACER {continue}
		settings := r.settings
		settings.trace_mode = provider
		settings.colored_shadows = false
		testing.expect(t, renderer_apply_settings(r, settings))
		// What the floor receives with nothing above it: the surface keeps for
		// its own reflection a part of the light, so the reference is measured.
		scene_set(r, {floor}, nil, sun, {})
		for _ in 0 ..< 2 {testing.expect(t, fixture_frame(&f, {camera = side}), r.error)}
		lit := read_halves(t, &f, r.targets.direct, under)
		block.material = 1
		scene_set(r, {floor, block}, nil, sun, {})
		for _ in 0 ..< 2 {testing.expect(t, fixture_frame(&f, {camera = side}), r.error)}
		plain := read_halves(t, &f, r.targets.direct, under)
		testing.expectf(t, lit.r > 0.9 && abs(plain.r - lit.r) < 0.02 && abs(plain.g - lit.g) < 0.02, "%v: glass casts no shadow: %v of %v", provider, plain, lit)
		settings.colored_shadows = true
		testing.expect(t, renderer_apply_settings(r, settings))
		for _ in 0 ..< 2 {testing.expect(t, fixture_frame(&f, {camera = side}), r.error)}
		colored := read_halves(t, &f, r.targets.direct, under)
		testing.expectf(t, abs(colored.g - 0.92 * lit.g) < 0.03 && abs(colored.r - 0.2 * 0.92 * lit.r) < 0.03, "%v: the shadow of a solid has its color once: %v of %v", provider, colored, lit)
		block.material = 2
		scene_set(r, {floor, block}, nil, sun, {})
		for _ in 0 ..< 2 {testing.expect(t, fixture_frame(&f, {camera = side}), r.error)}
		smoked := read_halves(t, &f, r.targets.direct, under)
		testing.expectf(t, abs(smoked.r - 0.92 * lit.r) < 0.03 && abs(smoked.b - 0.25 * 0.92 * lit.b) < 0.03, "%v: the shadow of a solid has what it absorbs: %v of %v", provider, smoked, lit)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
glass_tints_the_indirect_light_with_its_mean :: proc(t: ^testing.T) {
	settings := glass_settings()
	settings.gi_enabled = true
	f: Fixture
	if !fixture_init(t, &f, 96, 64, settings, programs = true, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	grid := program_find(r, "Grid", .Surface)
	if !testing.expect(t, grid != nil, "the tests have the Grid program") {return}
	plain, painted := glass_material({1, 0.2, 0.2}, 1, 0.05), glass_material({0.2, 0.2, 1}, 1, 0.05)
	painted.program_id = grid.id
	painted.custom_params = program_defaults(grid)
	for name in ([]string{"color", "line_color"}) {testing.expect(t, program_parameter_set(&painted.custom_params, program_parameter(grid, name), {1, 0.2, 0.2, 0}))}
	testing.expect(t, program_parameter_set(&painted.custom_params, program_parameter(grid, "roughness"), {0.05, 0, 0, 0}))
	materials_set(r, {plain})
	sheet, box := sheet_mesh(r), box_mesh(r)
	// A closed white room under a sheet of red glass, lit by the sky alone:
	// all the light of its floor comes through the glass.
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
		if provider == .Hardware && !r.hardware_rt_verified || provider == .Software && !SOFTWARE_TRACER {continue}
		for colored in ([]bool{false, true}) {
			settings := r.settings
			settings.trace_mode = provider
			settings.colored_shadows = colored
			testing.expect(t, renderer_apply_settings(r, settings))
			scene_set(r, room, nil, {}, {sky = {1, 1, 1}})
			for _ in 0 ..< 48 {testing.expect(t, fixture_frame(&f, {camera = camera, inspection = {mode = .Indirect}}), r.error)}
			light := read_halves(t, &f, r.targets.display, floor)
			if !colored {
				testing.expectf(t, light.r > 0.05 && abs(light.g - light.r) < 0.1 * light.r, "%v: without colored shadows the glass leaves the light of the sky white: %v", provider, light)
				continue
			}
			// The mean of a sheet is its color less what each face reflects.
			testing.expectf(t, light.r > 0.05 && abs(light.g / light.r - 0.2) < 0.05 && abs(light.b - light.g) < 0.05 * light.r, "%v: the light through the glass has its color: %v", provider, light)
		}
		// The same color given by a program over a blue row: the mean is what the program gives.
		materials_set(r, {painted})
		scene_set(r, room, nil, {}, {sky = {1, 1, 1}})
		for _ in 0 ..< 48 {testing.expect(t, fixture_frame(&f, {camera = camera, inspection = {mode = .Indirect}}), r.error)}
		light := read_halves(t, &f, r.targets.display, floor)
		testing.expectf(t, light.r > 0.05 && abs(light.g / light.r - 0.2) < 0.05 && abs(light.b - light.g) < 0.05 * light.r, "%v: the light through glass with a program has the color it gives: %v", provider, light)
		materials_set(r, {plain})
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
glass_ball_turns_the_scene_behind_it_upside_down :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 128, 96, glass_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	clear := glass_material({1, 1, 1}, 0, 0.05)
	clear.thickness = 1
	materials_set(r, {clear})
	sheet, ball := sheet_mesh(r), ball_mesh(r)
	// A wall that glows red on the left and blue on the right.
	red := Instance_Desc{object_id = 1, mesh = sheet, transform = standing({-4, 1, -4}, 8, 12), tint = {0, 0, 0}, emission = {1, 0, 0}}
	blue := Instance_Desc{object_id = 2, mesh = sheet, transform = standing({4, 1, -4}, 8, 12), tint = {0, 0, 0}, emission = {0, 0, 1}}
	lens := Instance_Desc{object_id = 3, mesh = ball, transform = placed({0, 1, 0}, {2, 2, 2}), material = 1, tint = {1, 1, 1}}
	camera := Camera{position = {0, 1, 6}, forward = {0, 0, -6}, up = {0, 1, 0}, fov_y = 40, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for provider in ([]Trace_Mode{.Software, .Hardware}) {
		if provider == .Hardware && !r.hardware_rt_verified || provider == .Software && !SOFTWARE_TRACER {continue}
		settings := r.settings
		settings.trace_mode = provider
		testing.expect(t, renderer_apply_settings(r, settings))
		scene_set(r, {red, blue}, nil, {}, {})
		left := shown(t, &f, camera, {-0.4, 1, 0})
		testing.expectf(t, left.r > 0.9 && left.b < 0.05, "%v: the left of the wall is red: %v", provider, left)
		scene_set(r, {red, blue, lens}, nil, {}, {})
		through_left := shown(t, &f, camera, {-0.4, 1, 0})
		through_right := shown(t, &f, camera, {0.4, 1, 0})
		testing.expectf(t, through_left.b > 0.7 && through_left.r < 0.1 && through_right.r > 0.7 && through_right.b < 0.1,
			"%v: a ball of glass shows the wall behind it mirrored: %v on its left, %v on its right", provider, through_left, through_right)
		beside := shown(t, &f, camera, {-1.6, 1, 0})
		testing.expectf(t, beside.r > 0.9 && beside.b < 0.05, "%v: beside the ball the wall is where it was: %v", provider, beside)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
glass_pane_shows_what_a_ray_through_it_finds :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 256, 192, glass_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	clear := glass_material({1, 1, 1}, 0, 0.05)
	clear.thickness = 0.4
	materials_set(r, {clear})
	// The same box twice: the loose vertex of the second lies between its top
	// and its bottom, so only the first is a pane.
	sheet, slab, solid := sheet_mesh(r), box_mesh(r), box_mesh(r, Vec3{0.5, 0.1, 0.2})
	// A floor that glows red where x < 0 and blue where x > 0.
	red := Instance_Desc{object_id = 1, mesh = sheet, transform = placed({-5, 0, 0}, {10, 1, 10}), tint = {0, 0, 0}, emission = {1, 0, 0}}
	blue := Instance_Desc{object_id = 2, mesh = sheet, transform = placed({5, 0, 0}, {10, 1, 10}), tint = {0, 0, 0}, emission = {0, 0, 1}}
	pane := Instance_Desc{object_id = 3, mesh = slab, transform = placed({0, 0.6, 0}, {3, 0.4, 3}), material = 1, tint = {1, 1, 1}}
	camera := Camera{position = {2.5, 3, 0}, forward = {-2.5, -3, 0}, up = {0, 1, 0}, fov_y = 40, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	// About 40 degrees from straight down, the view leaves the pane 15 cm
	// nearer the camera than it would go without it.
	at := [4]f32{-0.3, -0.2, -0.05, 0.05}
	scene_set(r, {red, blue, pane}, nil, {}, {})
	seen: [4]Vec3
	for &c, i in seen {c = shown(t, &f, camera, {at[i], 0, 0})}
	testing.expectf(t, seen[1].r > 0.7 && seen[1].b < 0.1 && seen[2].b > 0.7 && seen[2].r < 0.1, "the edge of the floor shows moved aside: %v at -20 cm, %v at -5 cm", seen[1], seen[2])
	pane.mesh = solid
	scene_set(r, {red, blue, pane}, nil, {}, {})
	for c, i in seen {
		traced := shown(t, &f, camera, {at[i], 0, 0})
		testing.expectf(t, abs(c.r - traced.r) < 0.05 && abs(c.b - traced.b) < 0.05, "at %v m the pane shows %v and the ray inside the solid %v", at[i], c, traced)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
glass_reflects_what_stands_before_it :: proc(t: ^testing.T) {
	f: Fixture
	settings := glass_settings()
	settings.reflections = true
	if !fixture_init(t, &f, 128, 96, settings, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	materials_set(r, {glass_material({1, 1, 1}, 0, 0.05)})
	sheet, box := sheet_mesh(r), box_mesh(r)
	pane := Instance_Desc{object_id = 1, mesh = sheet, transform = standing({0, 1, 0}, 6, 4), material = 1, tint = {1, 1, 1}}
	lamp := Instance_Desc{object_id = 2, mesh = box, transform = placed({1.5, 1, 2}, {0.8, 0.8, 0.8}), tint = {0, 0, 0}, emission = {40, 40, 40}}
	camera := Camera{position = {-1.5, 1, 4}, forward = {2, 0, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	// The image of the lamp in the pane lies on the line from the eye to the lamp mirrored behind it.
	image := Vec3{0.5, 1, 0}
	for provider in ([]Trace_Mode{.Software, .Hardware}) {
		if provider == .Hardware && !r.hardware_rt_verified || provider == .Software && !SOFTWARE_TRACER {continue}
		applied := r.settings
		applied.trace_mode = provider
		applied.reflections = true
		testing.expect(t, renderer_apply_settings(r, applied))
		scene_set(r, {pane, lamp}, nil, {}, {})
		reflected := shown(t, &f, camera, image, 10)
		away := shown(t, &f, camera, {-2, 1, 0}, 1)
		testing.expectf(t, reflected.g > 0.5 && reflected.g < 4 && away.g < 0.05, "%v: the pane reflects a few percent of the lamp, and nothing where it is not: %v and %v", provider, reflected, away)
		applied.reflections = false
		testing.expect(t, renderer_apply_settings(r, applied))
		dark := shown(t, &f, camera, image)
		testing.expectf(t, dark.g < 0.05, "%v: without traced reflections and without probes the pane reflects nothing: %v", provider, dark)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
glass_rough_scatters_what_shows_through :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 128, 96, glass_settings(), reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	materials_set(r, {glass_material({1, 1, 1}, 0, 0.05), glass_material({1, 1, 1}, 0, 0.7)})
	sheet := sheet_mesh(r)
	red := Instance_Desc{object_id = 1, mesh = sheet, transform = standing({-4, 1, -4}, 8, 12), tint = {0, 0, 0}, emission = {1, 0, 0}}
	blue := Instance_Desc{object_id = 2, mesh = sheet, transform = standing({4, 1, -4}, 8, 12), tint = {0, 0, 0}, emission = {0, 0, 1}}
	pane := Instance_Desc{object_id = 3, mesh = sheet, transform = standing({0, 1, 0}, 6, 4), material = 1, tint = {1, 1, 1}}
	camera := Camera{position = {0, 1, 5}, forward = {0, 0, -5}, up = {0, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	// A point of the wall a hand's width into its red half.
	point := Vec3{-0.12, 1, 0}
	scene_set(r, {red, blue, pane}, nil, {}, {})
	sharp := shown(t, &f, camera, point)
	testing.expectf(t, sharp.r > 0.85 && sharp.b < 0.05, "smooth glass shows the wall as it is: %v", sharp)
	pane.material = 2
	scene_set(r, {red, blue, pane}, nil, {}, {})
	frosted := shown(t, &f, camera, point)
	testing.expectf(t, frosted.r > 0.3 && frosted.b > 0.1, "frosted glass mixes in the blue beside it: %v", frosted)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A reflection sharp enough for it to show has the glass its ray crosses, as
// a filter, and what the ray finds as the glossy surface it is.
@(test)
glass_and_gloss_show_in_sharp_reflections :: proc(t: ^testing.T) {
	f: Fixture
	settings := glass_settings()
	settings.reflections = true
	if !fixture_init(t, &f, 128, 96, settings, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	mirror, plate := DEFAULT_MATERIAL, DEFAULT_MATERIAL
	mirror.metallic, mirror.roughness = 1, 0.05
	plate.metallic, plate.roughness = 1, 0.2
	materials_set(r, {mirror, glass_material({1, 0, 0}, 0.9, 0.05), plate})
	sheet := sheet_mesh(r)
	floor := Instance_Desc{object_id = 1, mesh = sheet, transform = placed({}, {30, 1, 30}), material = 1, tint = {1, 1, 1}}
	pane := Instance_Desc{object_id = 2, mesh = sheet, transform = placed({0, 3, 0}, {30, 1, 30}), material = 2, tint = {1, 1, 1}}
	lamp := Instance_Desc{object_id = 3, mesh = sheet, transform = placed({0, 4, 0}, {30, 1, 30}), tint = {0, 0, 0}, emission = {2, 2, 2}}
	ceiling := Instance_Desc{object_id = 3, mesh = sheet, transform = placed({0, 4, 0}, {30, 1, 30}), material = 3, tint = {1, 1, 1}}
	light := Light_Desc{position = {4, 2, -8}, color = {1, 1, 1}, intensity = 40 * math.PI, range = 12}
	camera := Camera{position = {0, 2, 5}, forward = {0, -2, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for provider in ([]Trace_Mode{.Software, .Hardware}) {
		if provider == .Hardware && !r.hardware_rt_verified || provider == .Software && !SOFTWARE_TRACER {continue}
		applied := r.settings
		applied.trace_mode = provider
		applied.reflection_detail_roughness = REFLECTION_SHARED_ROUGHNESS
		testing.expect(t, renderer_apply_settings(r, applied))
		scene_set(r, {floor, pane, lamp}, nil, {}, {})
		filtered := shown(t, &f, camera, {})
		testing.expectf(t, filtered.r > 1.2 && filtered.g < 0.5, "%v: the mirror shows the lamp through the red glass above it: %v", provider, filtered)
		scene_set(r, {floor, ceiling}, []Light_Desc{light}, {}, {})
		// The light is strong enough for the scene to take another light scale: in nits.
		glossy := shown(t, &f, camera, {}) / r.scene.light_scale
		testing.expectf(t, glossy.g < 0.05, "%v: a metal plate away from its highlight is dark in the mirror: %v", provider, glossy)
		applied.reflection_detail_roughness = 0
		testing.expect(t, renderer_apply_settings(r, applied))
		matte := shown(t, &f, camera, {}) / r.scene.light_scale
		testing.expectf(t, matte.g > 0.3, "%v: without the detail the plate is a matte surface: %v", provider, matte)
		scene_set(r, {floor, pane, lamp}, nil, {}, {})
		plain := shown(t, &f, camera, {})
		testing.expectf(t, plain.g > 1.2 && abs(plain.r - plain.g) < 0.1, "%v: and the glass is not in the reflection: %v", provider, plain)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The filter of a reflection finds last frame's result where the reflected
// point was. On a ball that is nearly where the surface was, not where a flat
// mirror would have shown it: the reflection of a camera on the move is the
// one it settles into.
@(test)
reflection_on_a_ball_keeps_its_place_on_the_move :: proc(t: ^testing.T) {
	f: Fixture
	settings := glass_settings()
	settings.reflections = true
	if !fixture_init(t, &f, 128, 96, settings, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	polished := DEFAULT_MATERIAL
	polished.metallic, polished.roughness = 1, 0.15
	materials_set(r, {polished})
	sheet, ball := sheet_mesh(r), ball_mesh(r)
	scene_set(r, {
		{object_id = 1, mesh = ball, transform = placed({0, 1, 0}, {2, 2, 2}), material = 1, tint = {1, 1, 1}},
		{object_id = 2, mesh = sheet, transform = standing({-6, 1, 12}, 12, 12), tint = {0, 0, 0}, emission = {1, 0, 0}},
		{object_id = 3, mesh = sheet, transform = standing({6, 1, 12}, 12, 12), tint = {0, 0, 0}, emission = {0, 0, 1}},
	}, nil, {}, {})
	camera := Camera{position = {-0.6, 1, 6}, forward = {0, 0, -6}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 20 {testing.expect(t, fixture_frame(&f, {camera = camera}), r.error)}
	for _ in 0 ..< 40 {
		camera.position.x += 0.03
		camera.forward.x += 0.03
		testing.expect(t, fixture_frame(&f, {camera = camera}), r.error)
	}
	read :: proc(t: ^testing.T, f: ^Fixture) -> []f16 {
		r := f.renderer
		rhi.device_wait_idle(f.device)
		pixels := make([]f16, int(r.targets.width * r.targets.height) * 4, context.temp_allocator)
		testing.expect(t, golden_read_texture(f.device, r.targets.display, mem.slice_data_cast([]u8, pixels)), rhi.device_error(f.device))
		return pixels
	}
	moving := read(t, &f)
	for _ in 0 ..< 30 {testing.expect(t, fixture_frame(&f, {camera = camera}), r.error)}
	settled := read(t, &f)
	center := glass_pixel(r, camera, {0, 1, 0})
	difference: f32
	for y in center.y - 9 ..= center.y + 9 {
		for x in center.x - 9 ..= center.x + 9 {
			i := (y * int(r.targets.width) + x) * 4
			for channel in 0 ..< 3 {difference += abs(f32(moving[i + channel]) - f32(settled[i + channel]))}
		}
	}
	difference /= 19 * 19 * 3
	testing.expectf(t, difference < 0.009, "the ball shows on the move what it shows at rest: mean difference %v", difference)
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
	scene_set(r, {floor, pane, wall}, nil, SUN, {})
	hidden := shown(t, &f, above, {0, 1, 0}, 4)
	testing.expectf(t, abs(hidden.r - hidden.g) < 0.01 && hidden.r > 0.5, "the wall hides the glass: %v", hidden)
	scene_set(r, {floor, pane}, nil, SUN, {})
	first := shown(t, &f, above, {0, 1, 0}, 1)
	settled := shown(t, &f, above, {0, 1, 0}, 3)
	testing.expectf(t, first.g < 0.6 * first.r && abs(first.r - settled.r) < 0.02 && abs(first.g - settled.g) < 0.02, "the glass is there in the first frame without the wall: %v, then %v", first, settled)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
glass_frames_stay_allocation_free :: proc(t: ^testing.T) {
	f: Fixture
	settings := glass_settings()
	settings.gi_enabled = true
	settings.reflections = true
	settings.glass_layers = 2
	if !fixture_init(t, &f, 96, 64, settings, reference = {.Lights}) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	solid := glass_material({0.8, 0.9, 1}, 0.2, 0.05)
	solid.thickness = 0.5
	materials_set(r, {solid, glass_material({1, 0.6, 0.6}, 0.5)})
	sheet, box := sheet_mesh(r), box_mesh(r)
	instances := []Instance_Desc{
		{object_id = 1, mesh = sheet, transform = placed({}, {20, 1, 20}), tint = {1, 1, 1}},
		{object_id = 2, mesh = box, transform = placed({0, 1, 0}, {2, 0.5, 2}), material = 1, tint = {1, 1, 1}},
		{object_id = 3, mesh = sheet, transform = placed({0, 2, 0}, {2, 1, 2}), material = 2, tint = {1, 1, 1}},
		{object_id = 4, mesh = sheet, transform = placed({0, 0.5, 0}, {2, 1, 2}), material = 2, tint = {1, 1, 1}},
	}
	scene_set(r, instances, []Light_Desc{{position = {1, 3, 1}, color = {1, 1, 1}, intensity = 8 * math.PI, range = 10}}, SUN, {})
	camera := Camera{position = {0, 5, 0.5}, forward = {0, -5, -0.5}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 4 {testing.expect(t, fixture_frame(&f, {camera = camera}), r.error)}
	targets := [3]rhi.Texture{r.targets.glass_scene, r.targets.glass[1].depth, r.targets.glass_history[0]}
	testing.expect(t, targets[0] != 0 && targets[1] != 0 && targets[2] != 0, "both layers have their targets")
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	{
		context.allocator = mem.tracking_allocator(&tracking)
		for _ in 0 ..< 8 {testing.expect(t, fixture_frame(&f, {camera = camera}), r.error)}
	}
	testing.expect_value(t, tracking.total_allocation_count, 0)
	testing.expect_value(t, [3]rhi.Texture{r.targets.glass_scene, r.targets.glass[1].depth, r.targets.glass_history[0]}, targets)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// From inside a block of water: straight up the view leaves it into the sky,
// past the critical angle the top reflects the floor inside, and the water
// absorbs what the view crosses of it from the camera.
@(test)
glass_seen_from_inside_bends_out_reflects_past_the_critical_angle_absorbs_and_scatters :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 96, 64, glass_settings(), reference = {.Lights}) {return}
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
		if provider == .Hardware && !r.hardware_rt_verified || provider == .Software && !SOFTWARE_TRACER {continue}
		settings := r.settings
		settings.trace_mode = provider
		testing.expect(t, renderer_apply_settings(r, settings))
		scene_set(r, {block, floor}, nil, SUN, sky)
		inside := Vec3{0, 0, 0}
		window := look(inside, critical - 0.25)
		up := shown(t, &f, window, window.position + window.forward)
		testing.expectf(t, up.b > 2 * up.g && up.b > 0.05, "%v: within the window the view leaves into the sky: %v", provider, up)
		mirror := look(inside, critical + 0.1)
		reflected := shown(t, &f, mirror, mirror.position + mirror.forward)
		testing.expectf(t, reflected.g > 2 * reflected.b && reflected.g > 0.05, "%v: past the critical angle the top reflects the floor inside: %v", provider, reflected)
		// Looking down at the floor a metre away, with nothing of the glass between.
		down := Camera{position = {0, -0.9, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 30, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
		clear := shown(t, &f, down, {0, -1.9, 0})
		block.material = 2
		scene_set(r, {block, floor}, nil, SUN, sky)
		absorbed := shown(t, &f, down, {0, -1.9, 0})
		testing.expectf(t, clear.g > 0.05 && abs(absorbed.g - clear.g) < 0.02 * clear.g + 1e-3 && abs(absorbed.b - 0.25 * clear.b) < 0.05 * clear.b + 1e-3,
			"%v: a metre of the water leaves a quarter of the blue: %v of %v", provider, absorbed, clear)
		// What it stops of the blue it scatters back towards the eye, lit by the sky and the sun that reach it.
		block.material = 3
		scene_set(r, {block, floor}, nil, SUN, sky)
		scattered := shown(t, &f, down, {0, -1.9, 0})
		testing.expectf(t, scattered.b > absorbed.b * 1.05 && abs(scattered.g - absorbed.g) < 0.02 * absorbed.g + 1e-3,
			"%v: a solid that scatters adds its color to what it lets through: %v over %v", provider, scattered, absorbed)
		block.material = 1
		// From outside nothing of this applies: the camera over the block sees its top as glass.
		outside := Camera{position = {0, 6, 0.01}, forward = {0, -7.9, -0.01}, up = {0, 0, -1}, fov_y = 30, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
		scene_set(r, {block, floor}, nil, SUN, sky)
		seen := shown(t, &f, outside, {0, -1.9, 0})
		testing.expectf(t, seen.g > 2 * seen.b, "%v: from outside the floor shows through the top: %v", provider, seen)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}
