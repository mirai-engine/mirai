package mirai_render

import "core:math"
import mm "mirai:std/math"

// The viewmodel of a local body: its instances (INSTANCE_FLAG_VIEWMODEL of
// that owner) are drawn by the view of that body alone, by the passes that
// draw every instance, with each place moved from the eye of the view by
// Gpu_Frame.viewmodel in the vertex stage: VIEWMODEL_SCALE nearer the eye and
// as wide as their own field of view shows them in the field of view of the
// camera. They are lit there as any surface, cast no shadow and are in no ray
// structure; other views (mirrors, other players) do not draw them.

// How much nearer the eye a viewmodel is drawn than it is: its parts within a
// metre of the eye stay within the 0.3 m a character keeps between its eye
// and a wall (its capsule), and those beyond 10 cm stay beyond the near plane
// of a camera that draws one (viewmodel_near).
VIEWMODEL_SCALE :: f32(0.3)

// The near plane of a camera that draws a viewmodel, metres: the parts of it
// 10 cm or more from the eye, drawn VIEWMODEL_SCALE nearer, are in front of it.
VIEWMODEL_NEAR :: f32(0.1) * VIEWMODEL_SCALE

// The vertical field of view, radians, the viewmodel of each local slot is
// drawn with by the view of that slot; one at 0 or from PI draws it as it is.
scene_set_viewmodels :: proc(r: ^Renderer, fovs: [OWNER_SLOTS]f32) {
	r.scene.viewmodels = fovs
}

// The vertical field of view, radians, a camera draws the viewmodel of its
// body with; 0 for one that draws none.
@(private)
viewmodel_fov :: proc(r: ^Renderer, camera: Camera) -> f32 {
	fov := r.scene.viewmodels[camera.own - 1] if camera.own > 0 && int(camera.own) <= OWNER_SLOTS else 0
	return fov if camera.projection == .Perspective && fov > 0 && fov < math.PI else 0
}

// The rows of Gpu_Frame.viewmodel of a camera that looks along forward: the
// scale toward its eye by VIEWMODEL_SCALE, and across its forward by how much
// wider its field of view shows what that of the viewmodel shows. The
// identity for a camera without a viewmodel.
@(private)
viewmodel_rows :: proc(r: ^Renderer, camera: Camera, forward: Vec3) -> (rows: [3]Vec4) {
	rows = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}}
	fov := viewmodel_fov(r, camera)
	if fov == 0 {return}
	across := math.tan(camera.fov_y * math.PI / 360) / math.tan(fov * 0.5)
	s := VIEWMODEL_SCALE
	for i in 0 ..< 3 {
		for j in 0 ..< 3 {rows[i][j] = s * (1 - across) * forward[i] * forward[j] + (s * across if i == j else 0)}
	}
	rows[0].w = across - 1
	return
}

// The box a view draws an instance in: that of the viewmodel of its body
// around where it draws it.
@(private)
drawn_box :: proc "contextless" (f: ^Gpu_Frame, inst: ^Gpu_Instance) -> mm.Aabb {
	low, high, flags := inst.bounds_min.xyz, inst.bounds_max.xyz, inst.meta.w
	if flags & INSTANCE_FLAG_VIEWMODEL == 0 || f.own & 0xff != (flags >> INSTANCE_OWNER_SHIFT & 3) + 1 {return {low, high}}
	eye := f.camera_position.xyz
	center, half := (low + high) * 0.5 - eye, (high - low) * 0.5
	drawn, reach: Vec3
	for row in 0 ..< 3 {
		m := f.viewmodel[row].xyz
		drawn[row] = m.x * center.x + m.y * center.y + m.z * center.z
		reach[row] = abs(m.x) * half.x + abs(m.y) * half.y + abs(m.z) * half.z
	}
	return {eye + drawn - reach, eye + drawn + reach}
}
