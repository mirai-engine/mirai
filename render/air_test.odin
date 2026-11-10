package mirai_render

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:rhi"

@(private = "file")
Air_Fixture :: struct {
	using base: Fixture,
	square:     Mesh_Handle,
}

// A renderer without GI, reflections and TAA, and a white Lambert material.
@(private = "file")
air_fixture :: proc(t: ^testing.T, f: ^Air_Fixture, loc := #caller_location) -> bool {
	settings := DEFAULT_SETTINGS
	settings.gi_enabled, settings.taa = false, false
	if !fixture_init(t, f, 64, 64, settings, hardware_rt = false, loc = loc) {return false}
	lambert := DEFAULT_MATERIAL
	lambert.specular_factor = 0
	materials_set(f.renderer, {lambert})
	vertices := [4]Mesh_Vertex{{position = {-0.5, -0.5, 0}, normal = {0, 0, 1}, color = {1, 1, 1}}, {position = {0.5, -0.5, 0}, normal = {0, 0, 1}, color = {1, 1, 1}}, {position = {0.5, 0.5, 0}, normal = {0, 0, 1}, color = {1, 1, 1}}, {position = {-0.5, 0.5, 0}, normal = {0, 0, 1}, color = {1, 1, 1}}}
	indices := [6]u32{0, 1, 2, 0, 2, 3}
	f.square, _ = mesh_add(f.renderer, vertices[:], indices[:])
	return true
}

// A sun at an elevation, degrees, toward -z.
@(private = "file")
sun_at :: proc(degrees: f32) -> Sun_Desc {
	e := degrees * math.RAD_PER_DEG
	return {direction = {0, math.sin(e), -math.cos(e)}, color = {1, 1, 1}, illuminance = 100000, enabled = true}
}

@(private = "file")
AIR_SKY :: Environment{sky_atmosphere = true, air = AIR_EARTH}

// Looking toward -z, the horizon across the middle of the view.
@(private = "file")
LEVEL :: Camera{position = {0, 1, 0}, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 90, near = 0.05, far = 100000, exposure = UNIT_EXPOSURE}

// Looking up at the zenith.
@(private = "file")
UP :: Camera{position = {0, 1, 0}, forward = {0, 1, 0}, up = {0, 0, -1}, fov_y = 30, near = 0.05, far = 100000, exposure = UNIT_EXPOSURE}

// The light, in nits, a target holds at a place of the view, from 0 to 1 across and down.
@(private = "file")
nits_at :: proc(t: ^testing.T, f: ^Air_Fixture, target: rhi.Texture, x, y: f32) -> Vec3 {
	r := f.renderer
	rhi.device_wait_idle(f.device)
	pixels := make([]f16, int(r.targets.width * r.targets.height) * 4, context.temp_allocator)
	testing.expect(t, golden_read_texture(f.device, target, mem.slice_data_cast([]u8, pixels)), rhi.device_error(f.device))
	px := clamp(int(x * f32(r.targets.width)), 0, int(r.targets.width) - 1)
	py := clamp(int(y * f32(r.targets.height)), 0, int(r.targets.height) - 1)
	at := (py * int(r.targets.width) + px) * 4
	return Vec3{f32(pixels[at]), f32(pixels[at + 1]), f32(pixels[at + 2])} / r.scene.light_scale
}

@(private = "file")
sky_frame :: proc(t: ^testing.T, f: ^Air_Fixture, sun: Sun_Desc, camera: Camera, x, y: f32, environment := AIR_SKY) -> Vec3 {
	r := f.renderer
	scene_set(r, nil, nil, sun, environment)
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	return nits_at(t, f, r.targets.display, x, y)
}

@(test)
the_air_is_blue_by_day_red_at_sunset_and_still_lit_at_dusk :: proc(t: ^testing.T) {
	f: Air_Fixture
	if !air_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	noon := sun_at(70)
	high := sky_frame(t, &f, noon, LEVEL, 0.5, 0.05)
	horizon := sky_frame(t, &f, noon, LEVEL, 0.5, 0.49)
	testing.expectf(t, high.b > high.r * 1.5, "by day the sky above is blue: %v", high)
	testing.expectf(t, luminance_of(horizon) > luminance_of(high), "and lighter toward the horizon: %v against %v", horizon, high)
	zenith := sky_frame(t, &f, noon, UP, 0.5, 0.5)
	testing.expectf(t, luminance_of(zenith) > 1000 && luminance_of(zenith) < 20000, "the zenith of a clear day is some thousands of nits: %v", zenith)

	sunset := sky_frame(t, &f, sun_at(2), LEVEL, 0.5, 0.49)
	testing.expectf(t, sunset.r > sunset.b, "toward a setting sun the horizon is red: %v", sunset)
	zenith_sunset := sky_frame(t, &f, sun_at(2), UP, 0.5, 0.5)
	testing.expectf(t, zenith_sunset.b > zenith_sunset.r, "the zenith at sunset stays blue: %v", zenith_sunset)

	dusk := sky_frame(t, &f, sun_at(-4), LEVEL, 0.5, 0.49)
	zenith_dusk := sky_frame(t, &f, sun_at(-4), UP, 0.5, 0.5)
	testing.expectf(t, luminance_of(dusk) > 0.5 && luminance_of(dusk) < luminance_of(sunset) * 0.5, "after the sun sets the sky still glows, dimmer: %v against %v", dusk, sunset)
	testing.expectf(t, zenith_dusk.b > zenith_dusk.r, "the ozone keeps the zenith of dusk blue: %v", zenith_dusk)
	night := sky_frame(t, &f, sun_at(-25), LEVEL, 0.5, 0.49)
	testing.expectf(t, luminance_of(night) < luminance_of(dusk) * 0.01, "with the sun far under the horizon it is night: %v", night)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
the_sky_from_high_above_is_darker_and_shows_the_ground_below_the_horizon :: proc(t: ^testing.T) {
	f: Air_Fixture
	if !air_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	noon := sun_at(60)
	ground := sky_frame(t, &f, noon, UP, 0.5, 0.5)
	high := AIR_SKY
	high.air.altitude = 20000
	above := sky_frame(t, &f, noon, UP, 0.5, 0.5, high)
	testing.expectf(t, luminance_of(above) < luminance_of(ground) * 0.3, "from 20 km the air above is thin: %v against %v", above, ground)
	space := AIR_SKY
	space.air.altitude = 400000
	black := sky_frame(t, &f, noon, UP, 0.5, 0.5, space)
	planet := sky_frame(t, &f, noon, {position = {0, 1, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 30, near = 0.05, far = 100000, exposure = UNIT_EXPOSURE}, 0.5, 0.5, space)
	testing.expectf(t, luminance_of(black) < 1, "from space the sky above is black: %v", black)
	testing.expectf(t, luminance_of(planet) > 1000, "and the planet below is lit: %v", planet)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
the_sun_through_the_air_gives_its_illuminance_overhead_and_reddens_low :: proc(t: ^testing.T) {
	f: Air_Fixture
	if !air_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// A white floor, the camera above it looking down.
	floor := Instance_Desc{object_id = 1, mesh = f.square, transform = linalg.matrix4_rotate_f32(-math.PI / 2, {1, 0, 0}) * linalg.matrix4_scale_f32({40, 40, 1}), material = 1, tint = {1, 1, 1}}
	down := Camera{position = {0, 3, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 40, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	overhead := Sun_Desc{direction = {0, 1, 0}, color = {1, 1, 1}, illuminance = 100000, enabled = true}
	scene_set(r, {floor}, nil, overhead, {})
	testing.expect(t, renderer_frame(r, {camera = down}), r.error)
	bare := nits_at(t, &f, r.targets.direct, 0.5, 0.5)
	scene_set(r, {floor}, nil, overhead, AIR_SKY)
	testing.expect(t, renderer_frame(r, {camera = down}), r.error)
	through := nits_at(t, &f, r.targets.direct, 0.5, 0.5)
	for c in 0 ..< 3 {testing.expectf(t, abs(through[c] - bare[c]) <= bare[c] * 0.02, "the sun overhead lights the ground as its illuminance says: %v against %v", through, bare)}
	scene_set(r, {floor}, nil, sun_at(3), AIR_SKY)
	testing.expect(t, renderer_frame(r, {camera = down}), r.error)
	low := nits_at(t, &f, r.targets.direct, 0.5, 0.5)
	testing.expectf(t, low.r > low.b * 2, "a low sun is red: %v", low)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

@(test)
the_air_hazes_what_is_far_and_not_what_is_near :: proc(t: ^testing.T) {
	f: Air_Fixture
	if !air_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	sun := sun_at(40)
	sun.direction.z = 0.5
	// A wall across the view at a distance, as wide as the view sees there.
	wall :: proc(f: ^Air_Fixture, distance: f32) -> Instance_Desc {
		return {object_id = 1, mesh = f.square, transform = linalg.matrix4_translate_f32({0, 1, -distance}) * linalg.matrix4_scale_f32({distance, distance, 1}), material = 1, tint = {1, 1, 1}}
	}
	look := LEVEL
	look.fov_y = 20
	scene_set(r, {wall(&f, 20)}, nil, sun, AIR_SKY)
	testing.expect(t, renderer_frame(r, {camera = look}), r.error)
	near_seen, near_lit := nits_at(t, &f, r.targets.display, 0.5, 0.5), nits_at(t, &f, r.targets.direct, 0.5, 0.5)
	scene_set(r, {wall(&f, 15000)}, nil, sun, AIR_SKY)
	testing.expect(t, renderer_frame(r, {camera = look}), r.error)
	far_seen, far_lit := nits_at(t, &f, r.targets.display, 0.5, 0.5), nits_at(t, &f, r.targets.direct, 0.5, 0.5)
	testing.expectf(t, abs(far_lit.g - near_lit.g) <= near_lit.g * 0.02, "both walls take the same light: %v against %v", far_lit, near_lit)
	near_tint, far_tint := near_seen.b / near_seen.r, far_seen.b / far_seen.r
	testing.expectf(t, far_tint > near_tint * 1.1, "the far wall is bluer: %v against %v", far_seen, near_seen)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The light of the whole view, as half floats.
@(private = "file")
hdr_view :: proc(t: ^testing.T, f: ^Air_Fixture) -> []f16 {
	r := f.renderer
	rhi.device_wait_idle(f.device)
	pixels := make([]f16, int(r.targets.width * r.targets.height) * 4, context.temp_allocator)
	testing.expect(t, golden_read_texture(f.device, r.targets.display, mem.slice_data_cast([]u8, pixels)), rhi.device_error(f.device))
	return pixels
}

@(test)
the_air_draws_the_same_while_nothing_changes_and_follows_the_sun :: proc(t: ^testing.T) {
	f: Air_Fixture
	if !air_fixture(t, &f) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	scene_set(r, nil, nil, sun_at(10), AIR_SKY)
	testing.expect(t, renderer_frame(r, {camera = LEVEL}), r.error)
	first := hdr_view(t, &f)
	row, key := r.air.rows[0], r.targets.aerial_key
	testing.expect(t, renderer_frame(r, {camera = LEVEL}), r.error)
	second := hdr_view(t, &f)
	testing.expect(t, mem.compare(mem.slice_to_bytes(first), mem.slice_to_bytes(second)) == 0, "a frame where nothing changed is the same")
	testing.expect(t, r.air.rows[0] == row && r.targets.aerial_key == key, "and computes no table again")
	near, far := LEVEL, LEVEL
	near.position.y += AIR_SKY_ALTITUDE_TOLERANCE * 0.5
	far.position.y += AIR_SKY_ALTITUDE_TOLERANCE * 2
	testing.expect(t, renderer_frame(r, {camera = near}), r.error)
	testing.expectf(t, r.air.rows[0] == row, "an eye that rises within the tolerance keeps its sky: %v", r.air.rows[0])
	testing.expect(t, renderer_frame(r, {camera = far}), r.error)
	testing.expectf(t, r.air.rows[0].altitude != row.altitude, "and one that rises past it draws its sky again: %v", r.air.rows[0])
	scene_set_environment(r, sun_at(30), AIR_SKY)
	testing.expect(t, renderer_frame(r, {camera = LEVEL}), r.error)
	testing.expectf(t, r.air.rows[0].sun != row.sun, "a sun that moves draws its sky again: %v", r.air.rows[0])
	moved := hdr_view(t, &f)
	testing.expect(t, mem.compare(mem.slice_to_bytes(first), mem.slice_to_bytes(moved)) != 0, "and the sky changes with it")
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}
