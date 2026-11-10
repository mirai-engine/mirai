package mirai_render

import "core:math"
import "core:testing"
import "mirai:rhi"

// The scene-linear value at the index of an axis of the display LUT (display_unshaper).
@(private = "file")
lut_value :: proc(index: f32) -> f32 {return 0.18 * math.pow(2, index / (DISPLAY_LUT_SIZE - 1) * 26.5 - 12)}

@(private = "file")
srgb_decode :: proc(v: f32) -> f32 {return v / 12.92 if v <= 0.04045 else math.pow((v + 0.055) / 1.055, 2.4)}

@(private = "file")
N :: DISPLAY_LUT_SIZE

@(private = "file")
at :: proc(lut: []f16, x, y, z: int) -> Vec3 {
	i := ((z * N + y) * N + x) * 4
	return {f32(lut[i]), f32(lut[i + 1]), f32(lut[i + 2])}
}

// What the display shows, in linear light, of a scene-linear color: the LUT as the tonemap reads it.
@(private = "file")
shown :: proc(lut: []f16, scene: Vec3) -> Vec3 {
	place: [3]f32
	for c in 0 ..< 3 {place[c] = clamp((math.log2(scene[c] / 0.18) + 12) / 26.5, 0, 1) * (N - 1)}
	low := [3]int{min(int(place[0]), N - 2), min(int(place[1]), N - 2), min(int(place[2]), N - 2)}
	share := Vec3{place[0] - f32(low[0]), place[1] - f32(low[1]), place[2] - f32(low[2])}
	sum: Vec3
	for corner in 0 ..< 8 {
		x, y, z := corner & 1, (corner >> 1) & 1, corner >> 2
		weight := (share.x if x == 1 else 1 - share.x) * (share.y if y == 1 else 1 - share.y) * (share.z if z == 1 else 1 - share.z)
		sum += at(lut, low[0] + x, low[1] + y, low[2] + z) * weight
	}
	return {srgb_decode(sum.x), srgb_decode(sum.y), srgb_decode(sum.z)}
}

// Choosing a transform changes the color of a scene and not how bright it is:
// each shows the card a view exposes for it as the same light, in the image
// a frame draws. Neutral shows a midtone as authored, less its offset.
@(test)
every_display_transform_shows_the_card_it_is_exposed_for_alike :: proc(t: ^testing.T) {
	settings := DEFAULT_SETTINGS
	settings.gi_enabled, settings.reflections, settings.taa = false, false, false
	f: Fixture
	if !fixture_init(t, &f, 96, 64, settings, hardware_rt = false) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	scene_given(r, nil, nil, {}, {})
	// What the display shows, in linear light, of a backdrop the view exposes to scene.
	seen :: proc(t: ^testing.T, r: ^Renderer, scene: Vec3) -> (shown: Vec3, ok: bool) {
		camera := Camera{position = {0, 1, 4}, forward = {0, 0, -4}, up = {0, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
		renderer_set_backdrop(r, scene / exposure_of_ev100(UNIT_EXPOSURE.ev100, display_exposure_bias(r.display_transform)))
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error) or_return
		pixels, _, _, captured := golden_capture(r)
		testing.expect(t, captured, r.error) or_return
		defer delete(pixels)
		center := (32 * 96 + 48) * 4
		return {srgb_decode(f32(pixels[center]) / 255), srgb_decode(f32(pixels[center + 1]) / 255), srgb_decode(f32(pixels[center + 2]) / 255)}, true
	}
	for transform in Display_Transform {
		renderer_set_display_transform(r, transform)
		card := MIDDLE_GRAY * math.pow(f32(2), display_exposure_bias(transform))
		gray, drawn := seen(t, r, {card, card, card})
		if !drawn {return}
		testing.expectf(t, abs(gray.x - gray.y) < 0.008 && abs(gray.y - gray.z) < 0.008, "%v shows the card neutral: %v", transform, gray)
		testing.expectf(t, abs(gray.y - DISPLAY_ACES_GRAY) < 0.008, "%v shows the card as %v, not %v", transform, gray.y, DISPLAY_ACES_GRAY)
	}
	renderer_set_display_transform(r, .Neutral)
	color := Vec3{0.5, 0.3, 0.2}
	out, drawn := seen(t, r, color)
	if !drawn {return}
	for c in 0 ..< 3 {testing.expectf(t, abs(out[c] - (color[c] - DISPLAY_NEUTRAL_OFFSET)) < 0.008, "Neutral shows %v as %v", color, out)}
	// Its highlights roll off along its curve, with no step of a LUT.
	start := 0.8 - DISPLAY_NEUTRAL_OFFSET
	for step in 0 ..< 24 {
		white := math.pow(f32(2), f32(step) / 8)
		expected := 1 - (1 - start) * (1 - start) / (white - DISPLAY_NEUTRAL_OFFSET + 1 - 2 * start)
		bright, lit := seen(t, r, {white, white, white})
		if !lit {return}
		testing.expectf(t, abs(bright.y - expected) < 0.012 && abs(bright.x - bright.z) < 0.008, "Neutral shows a white of %v as %v, not %v", white, bright, expected)
	}
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}

@(test)
the_display_lut_holds_the_aces_2_output_transform :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 8, 8, hardware_rt = false) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	lut := make([]f16, N * N * N * 4, context.temp_allocator)
	if !testing.expect(t, rhi.texture_read(device, r.display_lut, ([^]u8)(raw_data(lut))[:len(lut) * 2]), rhi.device_error(device)) {return}
	finite, inside := true, true
	for v in lut {
		if math.is_nan(f32(v)) || math.is_inf(f32(v)) {finite = false}
		if f32(v) < 0 || f32(v) > 1.0001 {inside = false}
	}
	testing.expect(t, finite && inside, "every texel is an encoded color, from 0 to 1")
	// Gray stays gray and grows with the light.
	previous := f32(-1)
	for i in 0 ..< N {
		gray := at(lut, i, i, i)
		testing.expectf(t, abs(gray.x - gray.y) < 2e-3 && abs(gray.y - gray.z) < 2e-3, "gray %v stays neutral: %v", lut_value(f32(i)), gray)
		testing.expectf(t, gray.y >= previous - 1e-4, "gray grows with the light at %v: %v after %v", lut_value(f32(i)), gray.y, previous)
		previous = gray.y
	}
	testing.expectf(t, at(lut, 0, 0, 0).y < 0.01, "black stays black: %v", at(lut, 0, 0, 0))
	testing.expectf(t, at(lut, N - 1, N - 1, N - 1).y > 0.999, "the brightest gray is the white of the display: %v", at(lut, N - 1, N - 1, N - 1))
	// Middle gray, 0.18, is 10.013 nits of a display of 100.
	index := (math.log2(f32(1)) + 12) / 26.5 * (N - 1)
	low := int(index)
	share := index - f32(low)
	mid := at(lut, low, low, low) * (1 - share) + at(lut, low + 1, low + 1, low + 1) * share
	testing.expectf(t, abs(srgb_decode(mid.y) - 0.10013) < 0.003, "middle gray shows %v of the white of the display, not 0.1", srgb_decode(mid.y))
	// A saturated primary stays in the gamut of the display, with its hue.
	one := int(math.round(f32((math.log2(f32(1) / 0.18) + 12) / 26.5 * (N - 1))))
	red, green, blue := at(lut, one, 0, 0), at(lut, 0, one, 0), at(lut, 0, 0, one)
	testing.expectf(t, red.x > red.y + 0.3 && red.x > red.z + 0.3, "red stays red: %v", red)
	testing.expectf(t, green.y > green.x + 0.3 && green.y > green.z + 0.3, "green stays green: %v", green)
	testing.expectf(t, blue.z > blue.x + 0.3 && blue.z > blue.y + 0.3, "blue stays blue: %v", blue)
	// A color keeps its hue as it gets brighter, unlike a curve per channel.
	hue :: proc(c: Vec3) -> f32 {return math.to_degrees(math.atan2(math.sqrt(f32(3)) * (c.y - c.z), 2 * c.x - c.y - c.z))}
	for color in ([]Vec3{{1, 0.5, 0.1}, {0.2, 0.6, 1}, {0.3, 1, 0.3}}) {
		dim := hue(shown(lut, color * 0.05))
		for brightness in ([]f32{0.2, 0.6}) {
			bright := hue(shown(lut, color * brightness))
			turn := abs(bright - dim)
			testing.expectf(t, min(turn, 360 - turn) < 6, "%v keeps its hue from 0.05 to %v times: %v° then %v°", color, brightness, dim, bright)
		}
	}
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}
