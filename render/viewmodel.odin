package mirai_render

import "core:math"
import "core:math/linalg"
import mm "mirai:std/math"
import "mirai:rhi"

// The viewmodel of a local body: its instances (Instance_Desc.viewmodel,
// INSTANCE_VIEWMODEL) are in no layer and cast no shadow, so no view, map or
// ray of the world meets them, by the tests every instance already takes; the
// ray structures leave them out (ray_class, tlas_build). The view of that body
// alone draws them: its cull takes them from a list of their own (cull.comp,
// MIRAI_CULL_VIEWMODEL), and the GPU holds them where it draws them, nearer
// its eye by VIEWMODEL_SCALE and as wide as their own field of view shows them
// in the field of view of its camera (viewmodels_place); the scene keeps
// their own place. The rest of the frame draws and lights them there as any
// instance, with the motion of where they were drawn the frame before.

// How much nearer the eye a viewmodel is drawn than it is: its parts within a
// metre of the eye stay within the 0.3 m a character keeps between its eye
// and a wall (its capsule), and those beyond 10 cm stay beyond the near plane
// of a camera that draws one (VIEWMODEL_NEAR).
VIEWMODEL_SCALE :: f32(0.3)

// The near plane of a camera that draws a viewmodel, metres: the parts of it
// 10 cm or more from the eye, drawn VIEWMODEL_SCALE nearer, are in front of it.
VIEWMODEL_NEAR :: f32(0.1) * VIEWMODEL_SCALE

// An instance of a viewmodel (Scene_State.viewmodel_instances).
Viewmodel_Instance :: struct {
	index: u32,
	drawn: Mat4,    // where the view of its body drew it last; zero: nowhere it moved from (new, hidden, cut)
	box:   mm.Aabb, // where that view draws it in this frame
	shown: bool,    // that view draws it in this frame
}

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

// What takes a place of the world to where a camera draws its viewmodel:
// toward its eye by VIEWMODEL_SCALE, and across its forward by how much wider
// its field of view shows what that of the viewmodel shows.
@(private)
viewmodel_matrix :: proc(r: ^Renderer, camera: Camera) -> (m: Mat4) {
	m = 1
	fov := viewmodel_fov(r, camera)
	if fov == 0 {return}
	_, _, forward := mm.look_basis(camera.forward, camera.up)
	across := math.tan(camera.fov_y * math.PI / 360) / math.tan(fov * 0.5)
	s, eye := VIEWMODEL_SCALE, camera.position
	for i in 0 ..< 3 {
		for j in 0 ..< 3 {m[i, j] = s * (1 - across) * forward[i] * forward[j] + (s * across if i == j else 0)}
	}
	for i in 0 ..< 3 {m[i, 3] = eye[i] - (m[i, 0] * eye.x + m[i, 1] * eye.y + m[i, 2] * eye.z)}
	return
}

// 1 + the local slot of the body of an instance of a viewmodel.
@(private = "file")
viewmodel_own :: proc "contextless" (inst: Gpu_Instance) -> u8 {
	return u8(inst.meta.w >> INSTANCE_OWNER_SHIFT & 3) + 1
}

// Whether an instance is of a viewmodel the view of f does not draw: that of
// another body than its own.
@(private)
viewmodel_elsewhere :: proc "contextless" (f: ^Gpu_Frame, inst: ^Gpu_Instance) -> bool {
	return inst.meta.x & INSTANCE_VIEWMODEL != 0 && f.own & 0xff != u32(viewmodel_own(inst^))
}

// The box the view of f draws an instance in, and whether it is of the
// viewmodel that view draws: where it draws it.
@(private)
viewmodel_drawn :: proc(s: ^Scene_State, f: ^Gpu_Frame, index: u32) -> (box: mm.Aabb, listed: bool) {
	inst := &s.instances[index]
	if inst.meta.x & INSTANCE_VIEWMODEL != 0 && !viewmodel_elsewhere(f, inst) {
		placed := s.viewmodel_cameras[viewmodel_own(inst^) - 1]
		for v in s.viewmodel_instances {
			if v.index == index && v.shown && placed.position == f.camera_position.xyz {return v.box, true}
		}
	}
	return {inst.bounds_min.xyz, inst.bounds_max.xyz}, false
}
@(private)
drawn_box :: proc(s: ^Scene_State, f: ^Gpu_Frame, index: u32) -> mm.Aabb {
	box, _ := viewmodel_drawn(s, f, index)
	return box
}

// The instance at index is of a viewmodel, or no longer. False without memory.
@(private)
viewmodel_keep :: proc(s: ^Scene_State, index: u32, kept: bool) -> bool {
	for v, i in s.viewmodel_instances {
		if v.index != index {continue}
		if !kept {unordered_remove(&s.viewmodel_instances, i)}
		return true
	}
	if !kept {return true}
	if _, error := append(&s.viewmodel_instances, Viewmodel_Instance{index = index}); error != nil {return false}
	return reserve(&s.viewmodel_list_words, len(s.viewmodel_instances) + 1) == nil
}

// The camera of the first view of the window of a local body in a frame,
// whether it cut and what carried it.
@(private = "file")
viewmodel_camera :: proc(frame: Frame_Desc, own: u8) -> (camera: Camera, cut: bool, carried: Mat4, found: bool) {
	if len(frame.views) == 0 {return frame.camera, frame.camera_cut, frame.carried, frame.camera.own == own}
	for view in frame.views {
		if !view.disabled && view.texture == 0 && view.camera.own == own {return view.camera, view.camera_cut, view.carried, true}
	}
	return
}

// Where the views of a frame draw the instances of the viewmodels, into the
// table of the GPU over what upload_scene gave it, and the room of their
// lists. False when the frame could not record it.
@(private)
viewmodels_place :: proc(r: ^Renderer, cmd: ^rhi.Command_List, frame: Frame_Desc) -> bool {
	s := &r.scene
	s.viewmodel_cameras = {}
	if len(s.viewmodel_instances) == 0 {return true}
	words := u64(len(s.viewmodel_instances) + 1) * size_of(u32)
	if s.viewmodel_list == 0 || rhi.buffer_size(r.device, s.viewmodel_list) < words {
		if s.viewmodel_list != 0 {rhi.buffer_destroy(r.device, s.viewmodel_list)}
		s.viewmodel_list = rhi.buffer_create(r.device, {size = max(words, 256), usage = {.Storage}, name = "viewmodel list"})
		if s.viewmodel_list == 0 {set_error(r, "viewmodel list: %s", rhi.device_error(r.device)); return false}
	}
	for &v in s.viewmodel_instances {
		v.shown = false
		inst := s.instances[v.index]
		own := viewmodel_own(inst)
		camera, cut, carried, found := viewmodel_camera(frame, own)
		if inst.meta.w & INSTANCE_FLAG_HIDDEN != 0 || !found {
			v.drawn = {}
			continue
		}
		if cut {v.drawn = {}} else if carried != {} && v.drawn != {} {v.drawn = carried * v.drawn}
		m := viewmodel_matrix(r, camera)
		w := inst.world
		world := m * Mat4{w[0].x, w[0].y, w[0].z, w[0].w, w[1].x, w[1].y, w[1].z, w[1].w, w[2].x, w[2].y, w[2].z, w[2].w, 0, 0, 0, 1}
		low, high := transform_bounds(m, inst.bounds_min.xyz, inst.bounds_max.xyz)
		drawn := [1]Gpu_Instance{inst}
		drawn[0].world, drawn[0].world_inv = rows_3x4(world), rows_3x4(linalg.inverse(world))
		drawn[0].prev_world = rows_3x4(v.drawn if v.drawn != {} else world)
		drawn[0].bounds_min.xyz, drawn[0].bounds_max.xyz = low, high
		v.drawn, v.box, v.shown = world, {low, high}, true
		s.viewmodel_cameras[own - 1] = camera
		if !upload_transient(r, cmd, drawn[:], s.instance_buffer, u64(v.index) * size_of(Gpu_Instance)) {return false}
	}
	return true
}

// The instances of the viewmodel the view of p draws, into the list its cull
// takes after their count (cull.comp, MIRAI_CULL_VIEWMODEL): those of its body,
// placed for its camera. 0 for a view that draws none.
@(private)
viewmodel_list :: proc(p: ^Pass) -> (count: u32, ok: bool) {
	s := &p.r.scene
	own := p.camera.own
	if own == 0 || int(own) > OWNER_SLOTS || p.texture || len(s.viewmodel_instances) == 0 {return 0, true}
	placed := s.viewmodel_cameras[own - 1]
	if placed.own != own || placed.position != p.camera.position || placed.forward != p.camera.forward || placed.fov_y != p.camera.fov_y {return 0, true}
	clear(&s.viewmodel_list_words)
	append(&s.viewmodel_list_words, 0)
	for v in s.viewmodel_instances {
		if v.shown && viewmodel_own(s.instances[v.index]) == own {append(&s.viewmodel_list_words, v.index)}
	}
	count = u32(len(s.viewmodel_list_words) - 1)
	s.viewmodel_list_words[0] = count
	return count, count == 0 || upload_transient(p.r, p.cmd, s.viewmodel_list_words[:], s.viewmodel_list)
}
