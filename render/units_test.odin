package mirai_render

import "core:math"
import "core:mem"
import "core:testing"
import "mirai:rhi"

@(private = "file")
Units_Fixture :: struct {
	using base: Fixture,
	floor:      Instance_Desc,
}

// A white Lambert floor wider than the view, without reflections, TAA and, unless asked, GI.
@(private = "file")
units_fixture :: proc(t: ^testing.T, f: ^Units_Fixture, gi := false, loc := #caller_location) -> bool {
	settings := DEFAULT_SETTINGS
	settings.gi_enabled, settings.taa = gi, false
	if !fixture_init(t, f, 64, 64, settings, hardware_rt = false, loc = loc) {return false}
	lambert := DEFAULT_MATERIAL
	lambert.specular_factor = 0
	materials_set(f.renderer, {lambert})
	scale := Mat4(1)
	scale[0, 0], scale[2, 2] = 40, 40
	f.floor = {object_id = 1, mesh = unit_square(f.renderer), transform = scale, material = 1, tint = {1, 1, 1}}
	return true
}

@(private = "file")
unit_square :: proc(r: ^Renderer) -> Mesh_Handle {
	vertices := [4]Mesh_Vertex{{position = {-0.5, 0, -0.5}, normal = {0, 1, 0}, color = {1, 1, 1}}, {position = {0.5, 0, -0.5}, normal = {0, 1, 0}, color = {1, 1, 1}}, {position = {0.5, 0, 0.5}, normal = {0, 1, 0}, color = {1, 1, 1}}, {position = {-0.5, 0, 0.5}, normal = {0, 1, 0}, color = {1, 1, 1}}}
	indices := [6]u32{0, 2, 1, 0, 3, 2}
	mesh, _ := mesh_add(r, vertices[:], indices[:])
	return mesh
}

@(private = "file")
DOWN :: Camera{position = {0, 3, 0}, forward = {0, -3, 0}, up = {0, 0, -1}, fov_y = 40, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}

// The luminance, in nits, a target holds at the middle of the view.
@(private = "file")
nits_at_center :: proc(t: ^testing.T, f: ^Units_Fixture, target: rhi.Texture) -> f32 {
	r := f.renderer
	rhi.device_wait_idle(f.device)
	pixels := make([]f16, int(r.targets.width * r.targets.height) * 4, context.temp_allocator)
	testing.expect(t, golden_read_texture(f.device, target, mem.slice_data_cast([]u8, pixels)), rhi.device_error(f.device))
	at := (int(r.targets.height / 2) * int(r.targets.width) + int(r.targets.width / 2)) * 4
	return f32(pixels[at + 1]) / r.scene.light_scale
}

@(private = "file")
near :: proc(value, expected, share: f32) -> bool {return abs(value - expected) <= abs(expected) * share}

@(test)
lights_reach_a_white_surface_with_the_luminance_their_units_give :: proc(t: ^testing.T) {
	f: Units_Fixture
	if !units_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	scene_set(r, {f.floor}, nil, {direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = 100000, enabled = true}, {})
	testing.expect(t, renderer_frame(r, {camera = DOWN}), r.error)
	testing.expectf(t, r.scene.light_scale == math.pow(f32(2), -15), "a sunlit scene takes a light scale near its sun: %v", r.scene.light_scale)
	sunlit := nits_at_center(t, &f, r.targets.direct)
	testing.expectf(t, near(sunlit, 100000 / math.PI, 0.01), "100000 lux give a white Lambert surface %v nits, not 100000 / pi", sunlit)
	// 1000 cd two metres above: 250 lux.
	scene_set(r, {f.floor}, {{position = {0, 2, 0}, color = {1, 1, 1}, intensity = 1000, range = 100}}, {}, {})
	testing.expect(t, renderer_frame(r, {camera = DOWN}), r.error)
	lamp := nits_at_center(t, &f, r.targets.direct)
	testing.expectf(t, near(lamp, 250 / math.PI, 0.02), "1000 candela at 2 m give %v nits, not 250 / pi", lamp)
	// A square of 10 cm glowing at 20000 nits two metres above: 200 cd towards the floor.
	scene_set(r, {f.floor}, {{position = {0, 2, 0}, color = {1, 1, 1}, intensity = 20000, range = 100, direction = {0, -1, 0}, axis = {1, 0, 0}, size = {0.1, 0.1}}}, {}, {})
	testing.expect(t, renderer_frame(r, {camera = DOWN}), r.error)
	panel := nits_at_center(t, &f, r.targets.direct)
	testing.expectf(t, near(panel, 50 / math.PI, 0.02), "20000 nits over 0.01 m^2 at 2 m give %v nits, not 50 / pi", panel)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
without_gi_the_sky_lights_a_surface_and_nothing_else_does :: proc(t: ^testing.T) {
	f: Units_Fixture
	if !units_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	scene_set(r, {f.floor}, nil, {}, {sky = {2000, 2000, 2000}})
	testing.expect(t, renderer_frame(r, {camera = DOWN}), r.error)
	// Facing the zenith it sees the gradient at its top: the luminance of the sky.
	lit := nits_at_center(t, &f, r.targets.display)
	testing.expectf(t, near(lit, 2000, 0.02), "a white floor under a sky of 2000 nits shows %v nits", lit)
	scene_set(r, {f.floor}, nil, {}, {})
	testing.expect(t, renderer_frame(r, {camera = DOWN}), r.error)
	dark := nits_at_center(t, &f, r.targets.display)
	testing.expectf(t, dark == 0, "without sky or lights nothing lights it: %v nits", dark)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(private = "file")
exposure_state :: proc(t: ^testing.T, f: ^Units_Fixture) -> Gpu_Exposure {
	rhi.device_wait_idle(f.device)
	state: [1]Gpu_Exposure
	testing.expect(t, rhi.buffer_read_slice(f.device, f.renderer.main.exposure, 0, state[:]), rhi.device_error(f.device))
	return state[0]
}

// The EV100 of a frame 1/60 s on that cuts to `camera`.
@(private = "file")
exposure_cut :: proc(t: ^testing.T, f: ^Units_Fixture, camera: Camera, time: ^f32) -> f32 {
	time^ += 1.0 / 60
	testing.expect(t, renderer_frame(f.renderer, {camera = camera, camera_cut = true, time = time^}), f.renderer.error)
	return exposure_state(t, f).ev100
}

// Seconds, in frames of 1/60 s, until the exposure comes within 5 % of the
// way from EV100 `from` to `to`; 10 if it does not.
@(private = "file")
exposure_settles :: proc(t: ^testing.T, f: ^Units_Fixture, camera: Camera, time: ^f32, from, to: f32) -> f32 {
	for frame in 1 ..= 600 {
		time^ += 1.0 / 60
		testing.expect(t, renderer_frame(f.renderer, {camera = camera, time = time^}), f.renderer.error)
		if abs(exposure_state(t, f).ev100 - to) <= 0.05 * abs(to - from) {return f32(frame) / 60}
	}
	return 10
}

@(test)
the_exposure_meters_the_image_or_follows_the_camera :: proc(t: ^testing.T) {
	f: Units_Fixture
	if !units_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	renderer_set_display_transform(r, .ACES_2)
	scene_set(r, {f.floor}, nil, {direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = 100000, enabled = true}, {})
	metered := DOWN
	metered.exposure = {}
	testing.expect(t, renderer_frame(r, {camera = metered, time = 0}), r.error)
	// The whole view is a white floor in the sun. The meter reads the light, not the floor: a
	// middle gray card there would be made middle gray, and the white floor shows 1, to a bin of
	// the histogram, before EXPOSURE_BIAS.
	floor := f32(100000 / math.PI)
	state := exposure_state(t, &f)
	testing.expectf(t, abs(state.ev100 - math.log2(MIDDLE_GRAY * floor * 100 / LIGHT_METER_K)) < 0.2, "the meter takes EV100 %v for a card of %v nits", state.ev100, MIDDLE_GRAY * floor)
	shown := floor * r.scene.light_scale * state.exposure
	testing.expectf(t, near(shown, math.pow(2, EXPOSURE_BIAS), 0.15), "the white floor shows %v: %v", math.pow(2, EXPOSURE_BIAS), shown)
	brighter := metered
	brighter.exposure.compensation, brighter.exposure.own = 1, true
	testing.expect(t, renderer_frame(r, {camera = brighter, time = 0}), r.error)
	compensated := exposure_state(t, &f)
	testing.expectf(t, near(compensated.exposure, 2 * state.exposure, 0.01), "a compensation of +1 EV doubles the exposure: %v from %v", compensated.exposure, state.exposure)
	// A light four stops stronger and back, in frames of 1/60 s. A cut takes
	// the exposure of its light at once, whatever the adaptation; without one
	// the view comes within 5 % of the change (0.2 EV) in half the adaptation
	// when the light grows, and in the adaptation when it falls.
	adapting := metered
	adapting.exposure.range = {-6, 24}
	adapting.exposure.adaptation, adapting.exposure.own = 1, true
	time := f32(0)
	strong := Sun_Desc{direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = 1600000, enabled = true}
	weak := strong
	weak.illuminance = 100000
	scene_set(r, {f.floor}, nil, strong, {})
	high := exposure_cut(t, &f, adapting, &time)
	scene_set(r, {f.floor}, nil, weak, {})
	low := exposure_cut(t, &f, adapting, &time)
	testing.expectf(t, abs(low - state.ev100) < 0.2, "a cut exposes for its light at once: EV100 %v, not %v", low, state.ev100)
	testing.expectf(t, abs(high - low - 4) < 0.35, "sixteen times the light is 4 EV more: %v", high - low)
	scene_set(r, {f.floor}, nil, strong, {})
	brightens := exposure_settles(t, &f, adapting, &time, low, high)
	testing.expectf(t, brightens > 0.45 && brightens <= 0.501, "with 4 EV more light it comes within 5 %% in %v s, not 0.5", brightens)
	exposure_cut(t, &f, adapting, &time)
	scene_set(r, {f.floor}, nil, weak, {})
	darkens := exposure_settles(t, &f, adapting, &time, high, low)
	testing.expectf(t, darkens > 0.95 && darkens <= 1.001, "with 4 EV less light it comes within 5 %% in %v s, not 1", darkens)
	// At speed, a second for each EV the light falls and three EV a second
	// when it grows, then exponentially within 1.5 EV at the rate it had: 4 EV
	// take 1.8 s up and 5.5 s down.
	steady := adapting
	steady.exposure.adaptation_mode = .Speed
	apart := high - low
	exposure_cut(t, &f, steady, &time)
	scene_set(r, {f.floor}, nil, strong, {})
	brightens = exposure_settles(t, &f, steady, &time, low, high)
	expected := ((apart - 1.5) + 1.5 * math.ln(1.5 / (0.05 * apart))) / 3
	testing.expectf(t, abs(brightens - expected) < 0.05, "at speed, with 4 EV more light it comes within 5 %% in %v s, not %v", brightens, expected)
	exposure_cut(t, &f, steady, &time)
	scene_set(r, {f.floor}, nil, weak, {})
	darkens = exposure_settles(t, &f, steady, &time, high, low)
	expected *= 3
	testing.expectf(t, abs(darkens - expected) < 0.05, "at speed, with 4 EV less light it comes within 5 %% in %v s, not %v", darkens, expected)
	manual := DOWN
	manual.exposure = {mode = .Manual, ev100 = ev100_of(16, 1.0 / 125, 100), own = true}
	testing.expect(t, renderer_frame(r, {camera = manual, time = time + 0.1}), r.error)
	sunny := exposure_state(t, &f)
	testing.expectf(t, sunny.ev100 == manual.exposure.ev100 && abs(sunny.ev100 - 14.966) < 0.01, "f/16, 1/125 s and ISO 100 are EV100 15: %v", sunny.ev100)
	testing.expectf(t, near(sunny.exposure, exposure_of_ev100(sunny.ev100) / r.scene.light_scale, 1e-4), "manual exposure: %v", sunny.exposure)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// Every pixel of the sky of a parallel projection shows the same direction,
// and how many there are follows the framing: the meter leaves them out and
// exposes for the surfaces. A perspective view counts its sky as the light of
// the open sky and sun: high above the floor it exposes as the floor in the sun.
@(test)
a_parallel_view_meters_its_surfaces_and_not_its_sky :: proc(t: ^testing.T) {
	f: Units_Fixture
	if !units_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	scene_set(r, {f.floor}, nil, {direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = 100000, enabled = true}, {sky = {20, 20, 20}})
	time := f32(0)
	close := DOWN
	close.exposure = {}
	floor := exposure_cut(t, &f, close, &time)
	// The 40 m floor is a sixteenth of the view, in the middle of a sky far darker than it shows.
	parallel := close
	parallel.projection, parallel.height = .Orthographic, 160
	framed := exposure_cut(t, &f, parallel, &time)
	testing.expectf(t, abs(framed - floor) < 0.1, "a parallel view exposes for its floor: EV100 %v, not %v", framed, floor)
	perspective := close
	perspective.position, perspective.far = {0, 400, 0}, 1000
	seen := exposure_cut(t, &f, perspective, &time)
	testing.expectf(t, abs(seen - floor) < 0.2, "a perspective view counts its sky as the light it gives with the sun: EV100 %v, the floor alone %v", seen, floor)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// Render units at a point of the view, as a share of its width and height from the top left.
@(private = "file")
render_units_at :: proc(t: ^testing.T, f: ^Units_Fixture, target: rhi.Texture, x, y: f32) -> Vec3 {
	r := f.renderer
	rhi.device_wait_idle(f.device)
	pixels := make([]f16, int(r.targets.width * r.targets.height) * 4, context.temp_allocator)
	testing.expect(t, golden_read_texture(f.device, target, mem.slice_data_cast([]u8, pixels)), rhi.device_error(f.device))
	at := (int(y * f32(r.targets.height)) * int(r.targets.width) + int(x * f32(r.targets.width))) * 4
	return {f32(pixels[at]), f32(pixels[at + 1]), f32(pixels[at + 2])}
}

// An unlit square of relative emission over the left half of the view, a hand above the floor.
@(private = "file")
glow_over_the_left :: proc(f: ^Units_Fixture) -> Instance_Desc {
	transform := Mat4(1)
	transform[0, 0], transform[2, 2] = 1.2, 3
	transform[0, 3], transform[1, 3] = -0.6, 0.5
	return {object_id = 2, mesh = f.floor.mesh, transform = transform, material = 2, tint = {1, 1, 1}}
}

// A relative emission is the value the exposed image shows, whatever the
// exposure, and the meter does not count it: the exposure is the floor's.
@(test)
a_relative_emission_shows_its_value_at_any_exposure_and_is_not_metered :: proc(t: ^testing.T) {
	f: Units_Fixture
	if !units_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	lambert, glow := DEFAULT_MATERIAL, DEFAULT_MATERIAL
	lambert.specular_factor = 0
	glow.unlit, glow.emission, glow.emission_mode = true, {0.5, 0.25, 0.1}, .Relative
	materials_set(r, {lambert, glow})
	// A sun a meter does not clamp: the floor shows 1000 / pi nits.
	sun := Sun_Desc{direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = 1000, enabled = true}
	scene_set(r, {f.floor, glow_over_the_left(&f)}, nil, sun, {})
	for ev in ([2]f32{11, 3}) {
		camera := DOWN
		camera.exposure = {mode = .Manual, ev100 = ev, own = true}
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
		shown := render_units_at(t, &f, r.targets.display, 0.25, 0.5) * exposure_state(t, &f).exposure
		testing.expectf(t, near(shown.x, 0.5, 0.02) && near(shown.y, 0.25, 0.02) && near(shown.z, 0.1, 0.03), "at EV100 %v the exposed image shows %v", ev, shown)
	}
	metered :: proc(t: ^testing.T, f: ^Units_Fixture, instances: []Instance_Desc, sun: Sun_Desc) -> f32 {
		r := f.renderer
		scene_set(r, instances, nil, sun, {})
		camera := DOWN
		camera.exposure = {}
		for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera, time = 0}), r.error)}
		return exposure_state(t, f).ev100
	}
	floor := metered(t, &f, {f.floor}, sun)
	covered := metered(t, &f, {f.floor, glow_over_the_left(&f)}, sun)
	testing.expectf(t, abs(covered - floor) < 0.2, "half the view glowing leaves the exposure of the floor: EV100 %v and %v", covered, floor)
	// The same square glowing in nits, ten times the floor, is light the meter counts.
	glow.emission, glow.emission_mode = 10 * 1000 / math.PI, .Physical
	materials_set(r, {lambert, glow})
	physical := metered(t, &f, {f.floor, glow_over_the_left(&f)}, sun)
	testing.expectf(t, physical > floor + 1, "a physical glow raises it: EV100 %v from %v", physical, floor)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// While the exposure adapts to 4 EV less light and back, a relative emission
// shows its value but for what the exposure moved in that frame: its passes
// take the exposure the GPU left for the view in the frame before.
@(test)
a_relative_emission_follows_an_adapting_exposure_a_frame_behind :: proc(t: ^testing.T) {
	f: Units_Fixture
	if !units_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	lambert, glow := DEFAULT_MATERIAL, DEFAULT_MATERIAL
	lambert.specular_factor = 0
	glow.unlit, glow.emission, glow.emission_mode = true, {0.5, 0.25, 0.1}, .Relative
	materials_set(r, {lambert, glow})
	camera := DOWN
	camera.exposure = {range = {-6, 24}, adaptation = 1, own = true}
	strong := Sun_Desc{direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = 1600000, enabled = true}
	weak := strong
	weak.illuminance = 100000
	scene_set(r, {f.floor, glow_over_the_left(&f)}, nil, strong, {})
	time := f32(0)
	exposure_cut(t, &f, camera, &time)
	// And a frame on, for the CPU to read back the exposure of the cut.
	time += 1.0 / 60
	testing.expect(t, renderer_frame(r, {camera = camera, time = time}), r.error)
	for sun in ([2]Sun_Desc{weak, strong}) {
		scene_set(r, {f.floor, glow_over_the_left(&f)}, nil, sun, {})
		before := exposure_state(t, &f).ev100
		previous, moved := before, f32(0)
		for _ in 0 ..< 60 {
			time += 1.0 / 60
			testing.expect(t, renderer_frame(r, {camera = camera, time = time}), r.error)
			state := exposure_state(t, &f)
			shown := render_units_at(t, &f, r.targets.display, 0.25, 0.5).y * state.exposure
			apart, step := abs(math.log2(shown / 0.25)), abs(state.ev100 - previous)
			testing.expectf(t, apart <= step + 0.01, "the glow is %v EV off while the exposure moved %v EV in the frame", apart, step)
			previous, moved = state.ev100, max(moved, step)
		}
		testing.expectf(t, abs(previous - before) > 3.5 && moved > 0.15, "the exposure adapts to 4 EV: %v EV in a second, at most %v EV a frame", previous - before, moved)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A relative emitter lights nothing: the rays that gather light, of the
// probes and of the screen, find none of it, where the same wall in nits
// lights the floor beside it.
@(test)
a_relative_emission_lights_nothing :: proc(t: ^testing.T) {
	f: Units_Fixture
	if !units_fixture(t, &f, gi = true) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	lambert, relative, physical := DEFAULT_MATERIAL, DEFAULT_MATERIAL, DEFAULT_MATERIAL
	lambert.specular_factor = 0
	relative.unlit, relative.emission, relative.emission_mode = true, {4, 4, 4}, .Relative
	physical.unlit, physical.emission = true, {1000, 1000, 1000}
	materials_set(r, {lambert, relative, physical})
	// A wall just left of the view, facing +X.
	wall := Mat4(1)
	wall[0, 0], wall[1, 0], wall[0, 1], wall[2, 2] = 0, -1.2, 1, 3
	wall[0, 3], wall[1, 3] = -1.3, 0.6
	lit :: proc(t: ^testing.T, f: ^Units_Fixture, wall: Mat4, material: Material_Handle) -> f32 {
		r := f.renderer
		scene_set(r, {f.floor, {object_id = 2, mesh = f.floor.mesh, transform = wall, material = material, tint = {1, 1, 1}}}, nil, {}, {})
		for frame in 0 ..< 60 {testing.expect(t, renderer_frame(r, {camera = DOWN, time = f32(frame) / 60}), r.error)}
		return render_units_at(t, f, r.targets.display, 0.1, 0.5).y
	}
	// The relative wall first: the probes keep what they gathered for a while.
	shown := lit(t, &f, wall, 2)
	glowing := lit(t, &f, wall, 3)
	testing.expectf(t, glowing > 0 && shown <= glowing * 0.01, "a wall in nits lights the floor (%v), the relative one does not (%v)", glowing, shown)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// With nothing to meter, as when all the view glows relative to the exposure
// in front of a backdrop, the exposure begins at a middle gray card under the
// strongest light, and the glow shows its value.
@(test)
with_nothing_to_meter_the_exposure_begins_at_the_strongest_light :: proc(t: ^testing.T) {
	f: Units_Fixture
	if !units_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	glow := DEFAULT_MATERIAL
	glow.unlit, glow.emission, glow.emission_mode = true, {0.5, 0.25, 0.1}, .Relative
	materials_set(r, {glow})
	covering := f.floor
	covering.material = 1
	scene_set(r, {covering}, nil, {direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = 100000, enabled = true}, {background = {0, 0, 0}, use_background = true})
	camera := DOWN
	camera.exposure = {}
	for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera, time = 0}), r.error)}
	state := exposure_state(t, &f)
	testing.expectf(t, abs(state.ev100 - math.log2(MIDDLE_GRAY / r.scene.light_scale * 100 / LIGHT_METER_K)) < 0.01, "EV100 %v under a light scale of %v", state.ev100, r.scene.light_scale)
	shown := render_units_at(t, &f, r.targets.display, 0.5, 0.5) * state.exposure
	testing.expectf(t, near(shown.x, 0.5, 0.02) && near(shown.y, 0.25, 0.02) && near(shown.z, 0.1, 0.03), "the glow shows %v", shown)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
the_scene_exposes_the_views_whose_camera_has_no_exposure :: proc(t: ^testing.T) {
	f: Units_Fixture
	if !units_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	renderer_set_display_transform(r, .ACES_2)
	scene_set(r, {f.floor}, nil, {direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = 100000, enabled = true}, {})
	metered := DOWN
	metered.exposure = {}
	testing.expect(t, renderer_frame(r, {camera = metered, time = 0}), r.error)
	plain := exposure_state(t, &f)
	scene_set_exposure(r, {compensation = 1})
	testing.expect(t, renderer_frame(r, {camera = metered, time = 0}), r.error)
	brighter := exposure_state(t, &f)
	testing.expectf(t, near(brighter.exposure, 2 * plain.exposure, 0.01), "+1 EV of the scene doubles the exposure of a camera without its own: %v from %v", brighter.exposure, plain.exposure)
	scene_set_exposure(r, {mode = .Manual, ev100 = 10})
	testing.expect(t, renderer_frame(r, {camera = metered, time = 0}), r.error)
	manual := exposure_state(t, &f)
	testing.expectf(t, manual.ev100 == 10, "a Manual scene exposes a camera without its own at its EV100: %v", manual.ev100)
	own := metered
	own.exposure = {own = true}
	testing.expect(t, renderer_frame(r, {camera = own, time = 0}), r.error)
	replaced := exposure_state(t, &f)
	testing.expectf(t, near(replaced.exposure, plain.exposure, 0.01), "the exposure of a camera replaces that of the scene: %v, not %v", replaced.exposure, manual.exposure)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}
