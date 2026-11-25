package mirai_render

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:rhi"
import "mirai:render/abi"

// The viewmodel of the body of a view (Scene_State.foreground: the instances
// of INSTANCE_FLAG_FOREGROUND of the slot the view owns). The world of the
// view is drawn into the depth below FOREGROUND_DEPTH; after its G-buffer
// the viewmodel is culled, rasterized and resolved over it from the same eye
// with its own field of view, into the depth above, where nothing of the
// world reaches. Its pixels keep their true depth and are tagged in the
// views target (VIEWS_FOREGROUND) with the share of the way from the eye
// their light is taken at (foreground_tag.frag): in front of the world drawn
// under them, so a wall nearer than the weapon neither darkens it nor lets
// the light behind the wall reach it. A view without a viewmodel sets no
// depth range, makes no target and draws nothing more.

// The vertical field of view, radians, the view draws the viewmodel of its
// body with; 0 for a view that draws none.
@(private)
view_foreground :: proc(r: ^Renderer, camera: Camera) -> f32 {
	slot := int(camera.own) - 1
	if slot < 0 || slot >= OWNER_SLOTS || camera.projection != .Perspective {return 0}
	foreground := r.scene.foreground[slot]
	return foreground.fov if foreground.instances > 0 && foreground.fov > 0 && foreground.fov < math.PI else 0
}

// What takes the depth z of a clip point to where the view stores it: below
// FOREGROUND_DEPTH for the world, above it for the viewmodel, as the depth
// range of the passes (rhi.cmd_set_depth_range) places them.
@(private)
foreground_depth_range :: proc "contextless" (viewmodel: bool) -> (m: Mat4) {
	m = Mat4(1)
	if viewmodel {
		m[2, 2], m[2, 3] = 1 - FOREGROUND_DEPTH, FOREGROUND_DEPTH
	} else {
		m[2, 2] = FOREGROUND_DEPTH
	}
	return
}

// The camera of the viewmodel: that of the view, with its field of view.
@(private)
foreground_camera :: proc(camera: Camera, fov: f32) -> Camera {
	c := camera
	c.fov_y = math.to_degrees(fov)
	c.clip_plane = {}
	return c
}

// What the constants of a view with a viewmodel say of it: the flag, the
// rays of its pixels and, as the depth target holds the world, inv_view_proj.
@(private)
foreground_view_constants :: proc(p: ^Pass, f: ^Gpu_Frame, reach: f32) {
	t := p.t
	camera := foreground_camera(p.camera, p.foreground)
	view, proj, forward := camera_matrices(camera, f32(t.width) / f32(t.height), reach)
	shift := Mat4(1)
	shift[0, 3] = 2 * p.jitter.x / f32(t.width)
	shift[1, 3] = -2 * p.jitter.y / f32(t.height)
	own := f^
	frame_view_constants(&own, camera, matrix_from_eye(view), shift * proj, proj, forward, f32(t.height))
	f.foreground_ray = {own.ray_origin, own.ray_du, own.ray_dv}
	f.inv_view_proj = linalg.inverse(foreground_depth_range(false) * f.view_proj)
	f.flags |= FRAME_FLAG_VIEWMODEL
}

// The constants of the pass that draws the viewmodel: those of the view
// with its projection, its previous one, its frustum and the footprint of
// its pixels, for the instances of the body of the view alone and none
// faded out.
@(private)
foreground_constants :: proc(p: ^Pass, reach: f32) -> (f: Gpu_Frame, unjittered: Mat4) {
	t := p.t
	camera := foreground_camera(p.camera, p.foreground)
	view, proj, forward := camera_matrices(camera, f32(t.width) / f32(t.height), reach)
	view = matrix_from_eye(view)
	unjittered = proj * view
	shift := Mat4(1)
	shift[0, 3] = 2 * p.jitter.x / f32(t.width)
	shift[1, 3] = -2 * p.jitter.y / f32(t.height)
	f = p.frame
	f.view, f.proj, f.view_proj, f.view_proj_unjittered = view, shift * proj, shift * unjittered, unjittered
	f.inv_view_proj = linalg.inverse(foreground_depth_range(true) * f.view_proj)
	f.prev_view_proj = p.view.prev_foreground if p.view.foreground_previous else unjittered
	f.frustum = frustum_from_eye(unjittered, camera.position)
	frame_view_constants(&f, camera, view, shift * proj, proj, forward, f32(t.height))
	f.own &= 0xff
	f.flags |= FRAME_FLAG_FOREGROUND
	return
}

// The viewmodel over the G-buffer of the view, after its world: its cull of
// one phase, its visibility into the depth above FOREGROUND_DEPTH, the tags
// of its pixels and their resolve over those of the world.
@(private)
foreground_record :: proc(p: ^Pass) -> bool {
	if p.foreground == 0 || !p.draw {return true}
	r, cmd, t := p.r, p.cmd, p.t
	d := r.device
	if !target(r, nil, &t.views, t.width, t.height, .R8_Uint, {.Color_Target, .Sampled}, "nested views", shared = true) {return false}
	f, unjittered := foreground_constants(p, p.frame.camera_forward.w)
	p.foreground_unjittered = unjittered
	constants := rhi.frame_alloc(d, u64(r.frame_layout.size), 256)
	if constants.ptr == nil {set_error(r, "viewmodel constants: %s", rhi.device_error(d)); return false}
	mem.copy(constants.ptr, p.constants.ptr, r.frame_layout.size)
	mem.copy(constants.ptr, &f, size_of(Gpu_Frame))
	frame_exposure_copy(p, constants)
	rhi.cmd_timestamp(cmd, "viewmodel")
	rhi.cmd_bind_transient(cmd, SLOT_FRAME, constants)
	if !cull_reset(r, cmd, p.instance_count) {return false}
	cull_record(p, {phase = 0, hiz_levels = t.hiz_levels}, t.hiz[p.previous], r.scratch_buffer, r.scratch_buffer)
	cull_bins_dispatch(r, cmd, 0)
	raster_round_record(r, cmd, 0, false, r.scratch_buffer)
	rhi.cmd_set_depth_range(cmd, FOREGROUND_DEPTH, 1)
	visibility_pass(p, 0, .Clear, .Load, t.depth, true, false)
	for round in u32(1) ..< abi.RASTER_ROUNDS - 1 {
		raster_round_record(r, cmd, round, round == abi.RASTER_ROUNDS - 2, r.scratch_buffer)
		visibility_pass(p, round, .Load, .Load, t.depth, true, false)
	}
	rhi.cmd_set_depth_range(cmd, 0, FOREGROUND_DEPTH)

	// The tags, from the depth of the viewmodel and the linear depth of the world before it is resolved.
	Params :: struct {along, by: Vec4, size, pad: Vec2}
	m, forward := f.inv_view_proj, f.camera_forward.xyz
	params := Params{by = {m[3, 0], m[3, 1], m[3, 2], m[3, 3]}, size = {f32(t.width), f32(t.height)}}
	for i in 0 ..< 3 {params.along += forward[i] * Vec4{m[i, 0], m[i, 1], m[i, 2], m[i, 3]}}
	tags := rhi.Render_Pass_Desc{color_count = 1, name = "viewmodel tags"}
	tags.colors[0] = {texture = t.views, load = .Clear, store = .Store}
	rhi.cmd_begin_render_pass(cmd, &tags)
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Foreground_Tag])
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_draw(cmd, 3)
	rhi.cmd_end_render_pass(cmd)
	resolve_pass(p, .Foreground)
	bind_scene_table(p)
	return true
}
