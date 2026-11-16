package mirai_render

import "core:math/linalg"
import "core:testing"
import mm "mirai:std/math"

// Far from the centre of the world, the places the helpers take relative to
// the origin are those of the world minus the origin, as f64 finds them: a
// point, a cell of a grid, a transform into the world and one out of it, a
// plane and a rigid transform of the world, which keep what they do.
@(test)
places_relative_to_the_origin_lose_nothing_the_origin_takes :: proc(t: ^testing.T) {
	origin := Vec3{-20480, 1024, 15360}
	testing.expect_value(t, origin_point({-20000.25, 1030.5, 15000.125}, origin), Vec3{479.75, 6.5, -359.875})
	testing.expect_value(t, origin_cell({-160003, 4, 120001}, 0.125, origin), Vec3{479.625, -1023.5, -359.875})
	testing.expect_value(t, origin_cell({3, 0, -2}, 0.5, {}), Vec3{1.5, 0, -1})
	place := mm.transform_matrix(mm.Transform{position = {-20000.5, 1100, 15000.25}, rotation = mm.quat_axis_angle(linalg.normalize(Vec3{1, 2, -1}), 0.7), scale = 1})
	into := origin_to_world(rows_3x4(place), origin)
	testing.expect(t, into[0].w == 479.5 && into[1].w == 76 && into[2].w == -359.75)
	testing.expect_value(t, origin_matrix(place, origin)[0, 3], into[0].w)
	// A point of the world: its place in the transform out of the world is the same from the origin.
	inverse := linalg.inverse(linalg.matrix_cast(place, f64))
	out_of: [3]Vec4
	for row in 0 ..< 3 {out_of[row] = {f32(inverse[row, 0]), f32(inverse[row, 1]), f32(inverse[row, 2]), f32(inverse[row, 3])}}
	relative := origin_from_world(out_of, origin)
	point := Vec3{-19998.5, 1101, 15001.25}
	for row in 0 ..< 3 {
		at := origin_point(point, origin)
		got := relative[row].x * at.x + relative[row].y * at.y + relative[row].z * at.z + relative[row].w
		want := f32(inverse[row, 0] * f64(point.x) + inverse[row, 1] * f64(point.y) + inverse[row, 2] * f64(point.z) + inverse[row, 3])
		testing.expectf(t, abs(got - want) < 1e-3, "row %d: %v from the origin, %v in the world", row, got, want)
	}
	plane := Vec4{0, 1, 0, -1100}
	testing.expect_value(t, origin_plane(plane, origin), Vec4{0, 1, 0, -76})
	testing.expect_value(t, origin_plane({}, origin), Vec4{})
	// A rigid transform of the world takes a point relative to the origin where it takes it in the world.
	carried := linalg.matrix4_translate_f32({3, 0, -2}) * linalg.matrix4_rotate_f32(0.5, {0, 1, 0})
	moved := origin_transform(carried, origin)
	at := origin_point(point, origin)
	world := (linalg.matrix_cast(carried, f64) * [4]f64{f64(point.x), f64(point.y), f64(point.z), 1}).xyz
	there := (moved * Vec4{at.x, at.y, at.z, 1}).xyz
	for axis in 0 ..< 3 {testing.expect(t, abs(f64(there[axis]) - (world[axis] - f64(origin[axis]))) < 1e-3)}
	testing.expect_value(t, origin_transform({}, origin), Mat4{})
	// The origin snaps to whole steps, which the shaders take.
	testing.expect_value(t, origin_cells({15003, -600, -12001}), [4]i32{15, -1, -12, 0})
	testing.expect_value(t, origin_snap({15003, -600, -12001}), Vec3{15360, -1024, -12288})
}

// A world drawn between frames near the centre while the window looked from
// far away (a preview): the origin follows its eye, and the cascades of the
// light of each world, kept relative to the origin, stay where they are in the
// world, as the instances do. Within reach, nothing moves.
@(test)
the_origin_follows_the_eye_of_a_preview_and_the_cascades_stay_in_the_world :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	renderer_origin_follow(r, {16000, 0, -9000})
	far := renderer_origin(r)
	testing.expect_value(t, far, Vec3{16384, 0, -9216})
	r.ddgi.cascades, r.ddgi.corners[0] = 1, {-10, -4, -10, 1}
	r.kept_count = 1
	r.kept[0].ddgi.cascades, r.kept[0].ddgi.corners[0] = 1, {-20, -4, -20, 2}
	renderer_origin_follow(r, {0.5, 1, -0.25})
	testing.expect_value(t, renderer_origin(r), Vec3{})
	testing.expect_value(t, r.ddgi.corners[0], Vec4{-10 + far.x, -4, -10 + far.z, 1})
	testing.expect_value(t, r.kept[0].ddgi.corners[0], Vec4{-20 + far.x, -4, -20 + far.z, 2})
	renderer_origin_follow(r, {900, -1000, 1020})
	testing.expect_value(t, renderer_origin(r), Vec3{})
}
