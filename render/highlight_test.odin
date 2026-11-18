package mirai_render

import "core:testing"

@(test)
highlight_filter_bounds_cover_silhouette_glow_and_eye_plane :: proc(t: ^testing.T) {
	instances := [3]Gpu_Instance{
		{bounds_min = {-0.5, -0.5, -0.5, 0}, bounds_max = {0.5, 0.5, 0.5, 0}, meta = {0, 0, 0, 1 << INSTANCE_HIGHLIGHT_SHIFT}},
		{bounds_min = {-100, -100, -100, 0}, bounds_max = {100, 100, 100, 0}},
		{bounds_min = {-100, -100, -100, 0}, bounds_max = {100, 100, 100, 0}, meta = {0, 0, 0, (1 << INSTANCE_HIGHLIGHT_SHIFT) | INSTANCE_FLAG_HIDDEN}},
	}
	camera := Camera{position = {0, 0, 5}, forward = {0, 0, -5}, up = {0, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	view, proj, _ := camera_matrices(camera, 1.6)
	bounds := highlight_screen_bounds(instances[:], proj * view, {}, {800, 500}, {400, 250}, 3)
	testing.expect(t, bounds.x > 0.3 && bounds.y > 0.3 && bounds.z < 0.7 && bounds.w < 0.7, "Only highlighted visible instances expand the filtering region")
	for corner in 0 ..< 8 {
		p := Vec4{-0.5 if corner & 1 == 0 else 0.5, -0.5 if corner & 2 == 0 else 0.5, -0.5 if corner & 4 == 0 else 0.5, 1}
		clip := (proj * view) * p
		uv := Vec2{clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5}
		testing.expect(t, bounds.x < uv.x - 3.0 / 800 && bounds.y < uv.y - 3.0 / 500 && bounds.z > uv.x + 3.0 / 800 && bounds.w > uv.y + 3.0 / 500, "The bound includes every silhouette corner, glow, jitter and reduced-resolution mask texels")
	}
	instances[0].bounds_min.x += 100; instances[0].bounds_max.x += 100
	offscreen := highlight_screen_bounds(instances[:], proj * view, {}, {800, 500}, {400, 250}, 3)
	testing.expect(t, offscreen.x > offscreen.z || offscreen.y > offscreen.w, "Offscreen selections perform no outline filtering on drawable pixels")
	instances[0].bounds_min = {-0.5, -0.5, 4.5, 0}; instances[0].bounds_max = {0.5, 0.5, 5.5, 0}
	testing.expect_value(t, highlight_screen_bounds(instances[:], proj * view, {}, {800, 500}, {400, 250}, 3), Vec4{0, 0, 1, 1})
	// What is drawn only as its outline is outlined although it is hidden.
	ghost := [1]Gpu_Instance{{bounds_min = {-0.5, -0.5, -0.5, 0}, bounds_max = {0.5, 0.5, 0.5, 0}, meta = {0, 0, 0, (1 << INSTANCE_HIGHLIGHT_SHIFT) | INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_OUTLINE_ONLY}}}
	outlined := highlight_screen_bounds(ghost[:], proj * view, {}, {800, 500}, {400, 250}, 3)
	testing.expect(t, outlined.x < 0.5 && outlined.z > 0.5 && outlined.y < 0.5 && outlined.w > 0.5, "An outline-only instance has the region of its silhouette")
}

// The game's styles rank below every level of the editor, and show through
// what is in front of them as much as their style says.
@(test)
outline_levels_of_the_game_rank_below_the_editor :: proc(t: ^testing.T) {
	testing.expect_value(t, outline_level(1), u8(HIGHLIGHT_LEVELS + 1))
	testing.expect_value(t, outline_level(0), u8(0))
	testing.expect_value(t, outline_level(OUTLINE_STYLES + 1), u8(0))
	for level in 1 ..= u32(HIGHLIGHT_LEVELS) {testing.expect(t, highlight_rank(level) > highlight_rank(u32(outline_level(1))))}
	testing.expect(t, highlight_rank(u32(outline_level(1))) > highlight_rank(u32(outline_level(2))))
	testing.expect_value(t, highlight_rank(u32(outline_level(OUTLINE_STYLES))), u32(1))
}
