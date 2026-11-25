package mirai_render

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:rhi"
import mm "mirai:std/math"
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

// The world of the view below FOREGROUND_DEPTH, in its depth and in the
// copy of it the glass is drawn against.
@(private)
foreground_world_depth :: proc(p: ^Pass) {
	rhi.cmd_set_depth_range(p.cmd, 0, FOREGROUND_DEPTH, p.t.depth, p.t.glass_zbuffer)
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
	rhi.cmd_set_depth_range(cmd, FOREGROUND_DEPTH, 1, t.depth)
	visibility_pass(p, 0, .Clear, .Load, t.depth, true, false)
	for round in u32(1) ..< abi.RASTER_ROUNDS - 1 {
		raster_round_record(r, cmd, round, round == abi.RASTER_ROUNDS - 2, r.scratch_buffer)
		visibility_pass(p, round, .Load, .Load, t.depth, true, false)
	}
	foreground_world_depth(p)

	// Its share of the way, from the depth of the viewmodel and the linear
	// depth of the world before it is resolved, then the tags.
	Params :: struct {along, by: Vec4, size, pad: Vec2}
	m, forward := f.inv_view_proj, f.camera_forward.xyz
	params := Params{by = {m[3, 0], m[3, 1], m[3, 2], m[3, 3]}, size = {f32(t.width), f32(t.height)}}
	for i in 0 ..< 3 {params.along += forward[i] * Vec4{m[i, 0], m[i, 1], m[i, 2], m[i, 3]}}
	if made, _ := ensure_buffer(r, &r.foreground_kept, 16, {.Storage, .Transfer_Dst}, "viewmodel share"); !made {return false}
	rhi.cmd_fill_buffer(cmd, r.foreground_kept, 0, 4, 0xff)
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Foreground_Kept])
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS2, r.foreground_kept)
	rhi.cmd_dispatch(cmd, groups(t.width, 8), groups(t.height, 8))
	tags := rhi.Render_Pass_Desc{color_count = 1, name = "viewmodel tags"}
	tags.colors[0] = {texture = t.views, load = .Clear, store = .Store}
	rhi.cmd_begin_render_pass(cmd, &tags)
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Foreground_Tag])
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.depth)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, r.foreground_kept)
	rhi.cmd_draw(cmd, 3)
	rhi.cmd_end_render_pass(cmd)
	resolve_pass(p, .Foreground)
	bind_scene_table(p)
	return true
}

// The boxes the maps of a viewmodel are fitted around: of the slot's weapon
// (its instances of INSTANCE_FLAG_FOREGROUND) and of its body (the others of
// INSTANCE_FLAG_OWNED), from the instances of the body and what hangs from
// it, and the turn of its Viewmodel, which the maps of the weapon turn with.
scene_foreground_bodies :: proc(r: ^Renderer, slot: int, instances: []u32, turn: quaternion128) {
	s := &r.scene
	if slot < 0 || slot >= OWNER_SLOTS {return}
	f := &s.foreground[slot]
	f.weapon, f.body, f.turn = {Vec3(max(f32)), Vec3(-max(f32))}, {Vec3(max(f32)), Vec3(-max(f32))}, turn
	for index in instances {
		if int(index) >= len(s.instances) {continue}
		inst := s.instances[index]
		if inst.meta.w & INSTANCE_FLAG_HIDDEN != 0 || inst.meta.w & INSTANCE_FLAG_OWNED == 0 {continue}
		box := &f.weapon if inst.meta.w & INSTANCE_FLAG_FOREGROUND != 0 else &f.body
		box[0], box[1] = linalg.min(box[0], inst.bounds_min.xyz), linalg.max(box[1], inst.bounds_max.xyz)
	}
}

// The maps of a viewmodel (Gpu_Frame.foreground_maps), each a square of
// FOREGROUND_MAP_SIDE texels below the pool in the atlas of the view: the
// layers of the weapon and of the body for the sun, then for the local light
// that lights the weapon most. The weapon reads its own layer at its true
// place, the world the layer of the body, as the maps of the world leave
// both out.
FOREGROUND_MAP_SIDE :: abi.FOREGROUND_MAP_SIDE
FOREGROUND_MAPS :: abi.FOREGROUND_MAPS
// How far past the body its shadow falls on what its map holds, metres.
@(private)
FOREGROUND_BODY_REACH :: 60

// The local light with a shadow that lights the box most at its middle; -1: none.
@(private)
foreground_light :: proc(s: ^Scene_State, box: [2]Vec3) -> int {
	middle := 0.5 * (box[0] + box[1])
	best, chosen := f32(0), -1
	for light, i in s.lights {
		if i < len(s.light_shadowless) && s.light_shadowless[i] {continue}
		to := light.position_range.xyz - middle
		distance := linalg.length(to)
		if distance >= light.position_range.w {continue}
		strength := light.color_intensity.w * (light.color_intensity.x + light.color_intensity.y + light.color_intensity.z) / max(distance * distance, 0.01)
		if strength > best {best, chosen = strength, i}
	}
	return chosen
}

// The camera a map of a viewmodel draws its layer from, fitted around box,
// and the map the shaders read it as; false where the box holds nothing or
// the light is inside it. sun: along `toward`, else from the light at `from`
// of radius `radius`. reach: how far past the box what it shades lies.
@(private)
foreground_map :: proc(box: [2]Vec3, turn: quaternion128, sun: bool, toward, from: Vec3, radius, reach: f32, corner: [2]u32) -> (camera: Camera, m: Gpu_Shadow_Map, ok: bool) {
	if !(box[0].x <= box[1].x && box[0].y <= box[1].y && box[0].z <= box[1].z) {return}
	middle, half := 0.5 * (box[0] + box[1]), 0.5 * linalg.length(box[1] - box[0]) + 0.01
	forward := -toward if sun else middle - from
	distance := linalg.length(forward)
	if distance < 1e-6 || !sun && distance <= half + radius {return}
	forward /= distance
	// Its texels turn with the weapon, which keeps them where they are on it.
	up := mm.quat_rotate(turn, Vec3{0, 0, -1})
	if abs(linalg.dot(up, forward)) > 0.99 {up = mm.quat_rotate(turn, Vec3{0, 1, 0})}
	camera = {forward = forward, up = up, projection = .Perspective}
	if sun {
		camera.projection, camera.height = .Orthographic, 2 * half
		camera.position = middle - forward * (half + 0.05)
		camera.near, camera.far = 0.01, 2 * half + 0.1 + reach
	} else {
		camera.position = from
		camera.fov_y = math.to_degrees(2 * math.asin(min(half / distance, 0.99)))
		camera.near, camera.far = max(distance - half, radius, 0.01), distance + half + reach
	}
	// As camera_matrices takes it.
	camera.far = max(camera.far, camera.near + 1)
	_, right, along := mm.look_basis(camera.forward, camera.up)
	extent := half if sun else math.tan(math.to_radians(camera.fov_y) * 0.5)
	m = {
		origin = camera.position, near = camera.near, far = camera.far,
		right = right, up = linalg.cross(right, along), forward = along,
		kind = abi.SHADOW_MAP_ORTHOGRAPHIC if sun else 0, skip = camera.near,
		span = {-extent, -extent, extent, extent},
		rect = {abi.FOREGROUND_MAP_SLOT, corner.x / SHADOW_PAGE | corner.y / SHADOW_PAGE << 8, FOREGROUND_MAP_SIDE, max(u32)},
	}
	return camera, m, true
}

// The maps of the viewmodel of the view, after those of its world, into the
// atlas below its pool, and the constants that say where they are.
@(private)
foreground_maps_record :: proc(p: ^Pass) -> bool {
	if p.foreground == 0 || p.frame.sun_maps.z == 0 {return true}
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	b := &t.shadow_raster
	if b.atlas == 0 || b.body == 0 {return true}
	fg := s.foreground[p.camera.own - 1]
	light := foreground_light(s, fg.weapon)
	top := b.rows * SHADOW_PAGE
	maps: [FOREGROUND_MAPS]Gpu_Shadow_Map
	rhi.cmd_timestamp(cmd, "viewmodel maps")
	for k in 0 ..< FOREGROUND_MAPS {
		sun := k < 2
		if sun && (s.sun.shadowless || !s.sun.enabled || !r.settings.sun_shadows) {continue}
		if !sun && light < 0 {continue}
		weapon := k % 2 == 0
		at, radius := Vec3{}, f32(0)
		if light >= 0 {at, radius = s.lights[light].position_range.xyz, s.lights[light].size.x}
		camera, m, fitted := foreground_map(fg.weapon if weapon else fg.body, fg.turn, sun, s.sun.direction, at, radius, 0 if weapon else FOREGROUND_BODY_REACH, {u32(k) * FOREGROUND_MAP_SIDE, top})
		if !fitted {continue}
		if !foreground_map_draw(p, camera, FRAME_FLAG_FOREGROUND if weapon else FRAME_FLAG_BODY, m.rect.y) {return false}
		maps[k] = m
	}
	bind_scene_table(p)
	p.frame.foreground_maps = maps
	p.frame.foreground_light = u32(light) if light >= 0 && maps[2].rect.z != 0 else max(u32)
	constants := (^Gpu_Frame)(p.constants.ptr)
	constants.foreground_maps, constants.foreground_light = p.frame.foreground_maps, p.frame.foreground_light
	return true
}

// A layer of a map of the viewmodel: the instances of the view's weapon
// (FRAME_FLAG_FOREGROUND) or of its body (FRAME_FLAG_BODY) culled and drawn
// from camera into the square of the atlas at the pages of corner.
@(private)
foreground_map_draw :: proc(p: ^Pass, camera: Camera, layer: u32, corner: u32) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	d := r.device
	s := &r.scene
	view, proj, forward := camera_matrices(camera, 1, camera.far)
	view = matrix_from_eye(view)
	f := p.frame
	vp := proj * view
	f.view, f.proj, f.view_proj, f.view_proj_unjittered, f.prev_view_proj = view, proj, vp, vp, vp
	f.inv_view_proj = linalg.inverse(vp)
	f.camera_position = {camera.position.x, camera.position.y, camera.position.z, camera.near}
	f.camera_forward = {forward.x, forward.y, forward.z, camera.far}
	f.prev_eye = {camera.position.x, camera.position.y, camera.position.z, 0}
	f.frustum = frustum_from_eye(vp, camera.position)
	side := f32(FOREGROUND_MAP_SIDE)
	f.resolution, f.inv_resolution = {side, side}, {1 / side, 1 / side}
	f.jitter = {}
	layers := f.layers & LAYERS_ALL
	frame_view_constants(&f, camera, view, proj, proj, forward, side)
	// Of the body, the head the view leaves out casts its shadow too.
	f.own, f.layers = u32(p.camera.own), layers
	f.flags |= layer
	constants := rhi.frame_alloc(d, u64(r.frame_layout.size), 256)
	if constants.ptr == nil {set_error(r, "viewmodel map constants: %s", rhi.device_error(d)); return false}
	mem.copy(constants.ptr, p.constants.ptr, r.frame_layout.size)
	mem.copy(constants.ptr, &f, size_of(Gpu_Frame))
	rhi.cmd_bind_transient(cmd, SLOT_FRAME, constants)
	if !cull_reset(r, cmd, p.instance_count) {return false}
	cull_record(p, {phase = 0, hiz_levels = t.hiz_levels}, t.hiz[p.previous], r.scratch_buffer, r.scratch_buffer)
	cull_bins_dispatch(r, cmd, 0)
	x, y := f32((corner & 0xff) * SHADOW_PAGE), f32((corner >> 8 & 0xff) * SHADOW_PAGE)
	for round in u32(0) ..< abi.RASTER_ROUNDS - 1 {
		raster_round_record(r, cmd, round, round == abi.RASTER_ROUNDS - 2, r.scratch_buffer)
		pass := rhi.Render_Pass_Desc{name = "viewmodel map"}
		pass.depth = {texture = t.shadow_raster.atlas, load = .Load, store = .Store}
		rhi.cmd_begin_render_pass(cmd, &pass)
		rhi.cmd_set_viewport(cmd, x, y, side, side)
		rhi.cmd_set_scissor(cmd, i32(x), i32(y), FOREGROUND_MAP_SIDE, FOREGROUND_MAP_SIDE)
		if round == 0 {
			rhi.cmd_bind_pipeline(cmd, r.pipelines[.Foreground_Map_Clear])
			rhi.cmd_draw(cmd, 3)
		}
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.visible_buffer)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS1, s.raster_vertices)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS2, s.raster_ids)
		rhi.cmd_bind_index_buffer(cmd, s.raster_indices)
		for bin in 0 ..< RASTER_BINS {
			rhi.cmd_bind_pipeline(cmd, r.pipelines[Pipeline_Id(int(Pipeline_Id.Foreground_Map) + bin)])
			rhi.cmd_draw_indexed_indirect(cmd, s.cull_state_buffer, u64(offset_of(Gpu_Cull_State, draws)) + u64(int(round) * RASTER_BINS + bin) * size_of(rhi.Draw_Indexed_Indirect), 1)
		}
		rhi.cmd_end_render_pass(cmd)
	}
	return true
}
