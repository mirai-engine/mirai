package mirai_render

import "core:math/linalg"
import "core:testing"

// The grid unfolds the upper hemisphere: folding a direction gives back its
// place, the border looks along the horizon and the centre straight down
// from above, and the axes of a frame are a right-handed basis around it.
@(test)
impostor_frames_cover_the_upper_hemisphere_and_fold_back :: proc(t: ^testing.T) {
	n := u32(8)
	for y in 0 ..< n {
		for x in 0 ..< n {
			d := impostor_direction(n, x, y)
			testing.expect(t, abs(linalg.length(d) - 1) < 1e-5 && d.y >= -1e-6)
			e := impostor_fold(d)
			want := Vec2{f32(x) / f32(n - 1) * 2 - 1, f32(y) / f32(n - 1) * 2 - 1}
			testing.expectf(t, linalg.length(e - want) < 1e-4, "frame %d %d folds back to %v, not %v", x, y, e, want)
			on_border := x == 0 || y == 0 || x == n - 1 || y == n - 1
			if on_border {testing.expectf(t, abs(d.y) < 1e-5, "a frame of the border looks along the horizon: %v", d)}
			right, up := impostor_axes(d)
			testing.expect(t, abs(linalg.dot(right, d)) < 1e-5 && abs(linalg.dot(up, d)) < 1e-5 && abs(linalg.dot(right, up)) < 1e-5)
			testing.expect(t, linalg.length(linalg.cross(right, up) - d) < 1e-4)
		}
	}
	top := impostor_unfold({0, 0})
	testing.expect(t, linalg.length(top - Vec3{0, 1, 0}) < 1e-5)
	right, up := impostor_axes(top)
	testing.expect(t, abs(linalg.dot(right, up)) < 1e-5 && linalg.length(linalg.cross(right, up) - top) < 1e-4)
	// Below the horizon a view folds onto it.
	testing.expect(t, abs(impostor_unfold(impostor_fold({0.6, -0.3, 0.2})).y) < 1e-5)
}

// The texels a frame does not cover take those of the nearest one it does,
// and the frames do not bleed into each other.
@(test)
impostor_frames_spread_their_color_into_what_they_do_not_cover :: proc(t: ^testing.T) {
	images := Impostor_Images{grid = 2, frame = 4}
	images.color = make([]u8, 8 * 8 * 4)
	images.normal = make([]u8, 8 * 8 * 4)
	images.surface = make([]u8, 8 * 8 * 4)
	defer impostor_images_destroy(&images)
	put :: proc(images: ^Impostor_Images, x, y: int, color, normal, surface: [4]u8) {
		at := (y * 8 + x) * 4
		for c in 0 ..< 4 {images.color[at + c], images.normal[at + c], images.surface[at + c] = color[c], normal[c], surface[c]}
	}
	put(&images, 1, 1, {200, 10, 10, 255}, {128, 255, 128, 100}, {200, 0, 255, 90})
	put(&images, 6, 1, {10, 200, 10, 255}, {128, 128, 255, 50}, {60, 0, 255, 0})
	impostor_dilate(&images)
	texel :: proc(images: ^Impostor_Images, x, y: int) -> (color, normal, surface: [4]u8) {
		at := (y * 8 + x) * 4
		for c in 0 ..< 4 {color[c], normal[c], surface[c] = images.color[at + c], images.normal[at + c], images.surface[at + c]}
		return
	}
	color, normal, surface := texel(&images, 3, 3)
	testing.expect_value(t, color, [4]u8{200, 10, 10, 0})
	testing.expect_value(t, normal, [4]u8{128, 255, 128, 100})
	testing.expect_value(t, surface, [4]u8{200, 0, 255, 90})
	color, _, _ = texel(&images, 4, 0)
	testing.expect_value(t, color, [4]u8{10, 200, 10, 0})
	color, _, _ = texel(&images, 1, 1)
	testing.expect_value(t, color.a, 255)
	// The lower frames cover nothing: they stay cleared.
	color, _, _ = texel(&images, 2, 6)
	testing.expect_value(t, color, [4]u8{})
	// The light the frames let through is that of the texels that let it through.
	transmitted := make([]u8, 8 * 8 * 4)
	defer delete(transmitted)
	for i := 0; i < len(transmitted); i += 4 {transmitted[i], transmitted[i + 1], transmitted[i + 2] = 51, 255, 0}
	testing.expect(t, linalg.length(impostor_transmission(images.surface, transmitted) - Vec3{0.2, 1, 0}) < 1e-3)
	testing.expect_value(t, impostor_transmission(make([]u8, 16, context.temp_allocator), transmitted), Vec3{1, 1, 1})
}
