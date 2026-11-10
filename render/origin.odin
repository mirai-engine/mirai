package mirai_render

import "core:math"
import "mirai:render/abi"

// The renderer draws relative to an origin of the world: every place it keeps
// (instances, batches, lights, the boxes and trees of its rays, the views and
// their histories) and every place its shaders see is the place of the world
// minus the origin, so that far from the centre of the world vertices and
// views do not shake. Places come in as the world has them, through the
// procedures that take them (scene_set, scene_update, scene_move, batch_set,
// scene_set_lights, the cameras of a frame, its panels and debug lines), and
// are kept relative. The origin follows in steps the eye of the window, and
// that of a world drawn between frames while it is drawn (a preview): while
// the eye stays within ORIGIN_REACH of it nothing moves on the GPU; past it,
// it jumps to the multiple of ORIGIN_STEP nearest the eye and what the
// renderer keeps moves once (renderer_origin_set), without motion and without
// a change of the light. One origin for every world: what is kept of each
// stays valid. Each view projects from its own eye (view_begin), so a view far
// from the origin keeps the precision of the places it is given. A pass that
// needs a place of the world (a noise, a texture projected on the world) takes
// what the origin adds from origin.slang, which has it in whole steps.

ORIGIN_STEP :: abi.ORIGIN_STEP  // metres: a whole number the floats hold exactly
ORIGIN_REACH :: f32(1024) // metres from the origin the eye goes before it jumps

// The origin of the world the renderer draws relative to.
renderer_origin :: proc "contextless" (r: ^Renderer) -> Vec3 {return r.origin}

// The origin in steps of ORIGIN_STEP, as the shaders take it (Frame_Data.origin).
origin_cells :: proc "contextless" (origin: Vec3) -> [4]i32 {
	cells: [4]i32
	for axis in 0 ..< 3 {cells[axis] = i32(clamp(math.round(origin[axis] / ORIGIN_STEP), -ORIGIN_CELLS_MAX, ORIGIN_CELLS_MAX))}
	return cells
}

// Steps of the origin from the centre of the world at most, along an axis:
// far beyond any world of f32 places.
ORIGIN_CELLS_MAX :: 1 << 20

// The multiple of ORIGIN_STEP nearest a place.
@(private)
origin_snap :: proc "contextless" (place: Vec3) -> Vec3 {
	cells := origin_cells(place)
	return Vec3{f32(cells.x), f32(cells.y), f32(cells.z)} * ORIGIN_STEP
}

// Places of the world for whoever keeps them relative to an origin (that of
// the renderer, Stage_Pass.origin), in f64: far from the centre of the world
// a place loses nothing of what the origin takes away. A point:
origin_point :: proc "contextless" (point, origin: Vec3) -> Vec3 {
	return {f32(f64(point.x) - f64(origin.x)), f32(f64(point.y) - f64(origin.y)), f32(f64(point.z) - f64(origin.z))}
}

// A function of the place that is a plane (normal, distance), or a row of a
// transform out of the world: what the origin adds to it.
origin_plane :: proc "contextless" (plane: Vec4, origin: Vec3) -> Vec4 {
	w := f64(plane.w) + f64(plane.x) * f64(origin.x) + f64(plane.y) * f64(origin.y) + f64(plane.z) * f64(origin.z)
	return {plane.x, plane.y, plane.z, f32(w)}
}

// The rows of a transform out of the world (world to local).
origin_from_world :: proc "contextless" (rows: [3]Vec4, origin: Vec3) -> [3]Vec4 {
	return {origin_plane(rows[0], origin), origin_plane(rows[1], origin), origin_plane(rows[2], origin)}
}

// The rows of a transform into the world (local to world): its translation.
origin_to_world :: proc "contextless" (rows: [3]Vec4, origin: Vec3) -> [3]Vec4 {
	rows := rows
	place := origin_point({rows[0].w, rows[1].w, rows[2].w}, origin)
	for &row, i in rows {row.w = place[i]}
	return rows
}

// A transform into the world, as a matrix.
origin_matrix :: proc "contextless" (m: Mat4, origin: Vec3) -> Mat4 {
	m := m
	place := origin_point({m[0, 3], m[1, 3], m[2, 3]}, origin)
	m[0, 3], m[1, 3], m[2, 3] = place.x, place.y, place.z
	return m
}

// A rigid transform of the world into itself (Frame_View.carried,
// Nested_View.to_world): both sides. Zero, none, stays zero.
origin_transform :: proc "contextless" (m: Mat4, origin: Vec3) -> Mat4 {
	if m == {} {return m}
	m := m
	for row in 0 ..< 3 {
		moved := f64(m[row, 3]) - f64(origin[row])
		for col in 0 ..< 3 {moved += f64(m[row, col]) * f64(origin[col])}
		m[row, 3] = f32(moved)
	}
	return m
}

// The lowest corner of a cell of a grid of the world, whose cells are size metres.
origin_cell :: proc "contextless" (cell: [3]i32, size: f64, origin: Vec3) -> Vec3 {
	return {f32(f64(cell.x) * size - f64(origin.x)), f32(f64(cell.y) * size - f64(origin.y)), f32(f64(cell.z) * size - f64(origin.z))}
}

@(private)
origin_camera :: proc "contextless" (c: Camera, origin: Vec3) -> Camera {
	c := c
	c.position = origin_point(c.position, origin)
	c.clip_plane = origin_plane(c.clip_plane, origin)
	return c
}

// The origin jumps when the eye left its reach: that of the window in each
// frame, and that of a world drawn between frames before it gives the
// renderer its places (host.app_world_draw).
renderer_origin_follow :: proc(r: ^Renderer, eye: Vec3) {
	away := eye - r.origin
	if abs(away.x) <= ORIGIN_REACH && abs(away.y) <= ORIGIN_REACH && abs(away.z) <= ORIGIN_REACH {return}
	if !(abs(eye.x) < max(f32) && abs(eye.y) < max(f32) && abs(eye.z) < max(f32)) {return}
	renderer_origin_set(r, eye)
}

// Moves the origin to the multiple of ORIGIN_STEP nearest `origin`, and what
// the renderer keeps with it, as a transaction: the instances (and where they
// were in the frame before), the lights, the boxes and trees of the rays and
// the histories of the views stay where they are in the world. Nothing moves
// to the eye and the light does not change. What it costs grows with the
// instances of the scene, not with those of batches: a batch keeps its
// instances relative to an anchor of its own and moves by its row alone.
renderer_origin_set :: proc(r: ^Renderer, origin: Vec3) {
	origin := origin_snap(origin)
	d := origin - r.origin
	if d == {} {return}
	r.origin = origin
	s := &r.scene
	for &inst in s.instances {
		for row in 0 ..< 3 {
			inst.world[row].w -= d[row]
			inst.prev_world[row].w -= d[row]
		}
		// From the rotation and the place, not from the inverse before: jumps do not add up.
		for row in 0 ..< 3 {
			inv := inst.world_inv[row]
			inst.world_inv[row].w = f32(-(f64(inv.x) * f64(inst.world[0].w) + f64(inv.y) * f64(inst.world[1].w) + f64(inv.z) * f64(inst.world[2].w)))
		}
		inst.bounds_min.xyz -= d
		inst.bounds_max.xyz -= d
	}
	for &hw, i in s.hw_instances {
		if hw.transform == {} {continue}
		for row in 0 ..< 3 {hw.transform[row].w = s.instances[i].world[row].w}
	}
	for &item in s.tlas_items {item.min -= d; item.max -= d}
	for &node in s.tlas_nodes {node.bounds_min -= d; node.bounds_max -= d}
	if s.has_bounds {s.bounds_min -= d; s.bounds_max -= d}
	for &light in s.lights {light.position_range.xyz -= d}
	for &node in s.light_tree {node.center_radius.xyz -= d}
	// A frame no window shows does not place the cascades again (ddgi_place).
	for &corner in r.ddgi.corners[:r.ddgi.cascades] {corner.xyz -= d}
	for &w in r.kept[:r.kept_count] {
		for &corner in w.ddgi.corners[:w.ddgi.cascades] {corner.xyz -= d}
	}
	for &sphere in s.changes.spheres[:s.changes.count] {sphere.xyz -= d}
	for &sphere in r.frame_changes.spheres[:r.frame_changes.count] {sphere.xyz -= d}
	for &box in s.occluders.boxes[:s.occluders.count] {box.low -= d; box.high -= d}
	for &box in r.frame_occluders.boxes[:r.frame_occluders.count] {box.low -= d; box.high -= d}
	s.batch.built = false
	// Each view takes its last frame as seen from the new origin: its eye moves by -d.
	for view in views_all(r) {
		if !view.has_previous {continue}
		view.prev_eye -= d
		view.prev_depth_plane = origin_plane(view.prev_depth_plane, d)
	}
	clear(&s.light_ranges)
	clear(&s.light_node_ranges)
	s.instances_dirty = true
	s.tlas_nodes_dirty = true
	s.tlas_dirty = true
	s.lights_dirty = true
}

// The cameras of a frame, and what carried them, relative to the origin: its
// views go to those the renderer keeps for a frame. False with more views
// than those.
@(private)
origin_frame :: proc(r: ^Renderer, frame: Frame_Desc) -> (Frame_Desc, bool) {
	f := frame
	f.camera = origin_camera(f.camera, r.origin)
	if f.detail.on {f.detail.camera = origin_camera(f.detail.camera, r.origin)}
	r.frame_detail = f.detail
	f.carried = origin_transform(f.carried, r.origin)
	if len(f.views) > len(r.frame_views) {
		set_error(r, "too many views: %d, at most %d", len(f.views), len(r.frame_views))
		return f, false
	}
	for view, i in f.views {
		r.frame_views[i] = view
		r.frame_views[i].camera = origin_camera(view.camera, r.origin)
		r.frame_views[i].carried = origin_transform(view.carried, r.origin)
	}
	f.views = r.frame_views[:len(f.views)]
	return f, true
}
