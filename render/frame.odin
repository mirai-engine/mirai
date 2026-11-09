package mirai_render

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:time"
import "mirai:rhi"

// Binding slots, mirrored from shaders/include/common.slang.
SLOT_FRAME          :: 0
SLOT_PARAMS         :: 1
SLOT_LINEAR_SAMPLER :: 2
SLOT_POINT_SAMPLER  :: 3
SLOT_INSTANCES      :: 4
SLOT_MESHES         :: 5
SLOT_VERTICES       :: 6
SLOT_INDICES        :: 7
SLOT_MATERIALS      :: 8
SLOT_LIGHTS         :: 9
SLOT_LIGHT_TREE     :: 10
SLOT_BLAS_NODES     :: 11
SLOT_BLAS_TRIANGLES :: 12
SLOT_TLAS_NODES     :: 13
SLOT_TLAS_REFS      :: 14
SLOT_MATERIAL_SAMPLER :: 15
SLOT_PROBES         :: 16
SLOT_IRRADIANCE     :: 17
SLOT_POINTS         :: 18 // the material points (points.odin)
SLOT_PASS0          :: 19
SLOT_PASS1          :: 20
SLOT_PASS2          :: 21
SLOT_PASS3          :: 22
SLOT_PASS4          :: 23
SLOT_PASS5          :: 24
SLOT_PASS6          :: 25
SLOT_PASS7          :: 26
SLOT_PASS8          :: 27
SLOT_PASS9          :: 28
SLOT_TLAS           :: 29
SLOT_SURFACE        :: 30
SLOT_VIEWS          :: 31
SLOT_LAYERS         :: 32
SLOT_DISTANCE       :: 33
// Of a draw of the clusters of an instance (gbuffer.vert): the Surface program
// whose clusters it draws, 0 those without one, GPU_NONE all of them.
SLOT_DRAW           :: SLOT_PASS9

// What the passes of a view record with: the frame, the view with its
// targets, and what several of them decide by.
Pass :: struct {
	r:         ^Renderer,
	cmd:       ^rhi.Command_List,
	view:      ^View_State,
	t:         ^Targets,
	camera:    Camera,
	constants: rhi.Transient, // the Gpu_Frame of the view, with what the extensions add to it
	frame:     Gpu_Frame,
	slot:      int,  // of the frame in flight
	current, previous: int, // of each pair of history targets, the one this frame writes and the one it reads
	first:     bool, // the first view the frame records: what runs once a frame goes with it
	index:     int,  // of the views of the window, in the order of Frame_Desc.views
	plan:      ^Render_Plan, // of the pipeline the view is drawn with
	texture:   bool, // drawn into a texture: nothing of the window goes over it
	offscreen: bool, // a frame no window shows: it leaves what lights the world to those that are
	inspection: View_Inspection,
	wide:      View_Wide, // of a view into a texture: its image is kept wide too
	view_matrix, unjittered: Mat4,
	jitter:    Vec2,
	jitter_phases: u32, // of the sequence the jitter of the view follows; 0: none
	use_gi, use_probes, use_reflections: bool,
	reflectance:    bool, // the G-buffer keeps what each pixel reflects
	layered:        bool, // and the layers of its material (gbuffer.slang)
	instance_count: u32,
	batch_slots:    u32, // instance slots of the batches drawn, a cull thread each after the instances

	draw, draw_translucent, draw_overlays: bool,
	blend:   bool,       // the view runs the Blend stage of extensions
	blended: bool,       // a pass of it began: TAA reads the coverage it drew
	glass:   Glass_Side, // of the Lit or Blend stage being recorded
	glass_layered: bool, // the layers of glass were drawn before the Lit stage, which runs on each side of them
	glass_medium: u32, // instance plus one of the solid of glass the camera may be in (glass_layers), 0 none
	reflections: rhi.Texture, // the filtered traced reflections, when the view traced any
	gi:    rhi.Texture, // the contact occlusion of the probe volume, or the reference of the indirect light
	shown: rhi.Texture, // the image so far: the Display or the Taa a pass last wrote, which the Output stage finishes
	nested:       [NESTED_VIEW_CAPACITY]Nested_View,
	nested_count: int,
}

@(private)
or_dummy :: proc(r: ^Renderer, b: rhi.Buffer) -> rhi.Buffer {return b if b != 0 else r.dummy_buffer}

@(private)
texture_or_dummy :: proc(r: ^Renderer, t: rhi.Texture) -> rhi.Texture {return t if t != 0 else r.dummy_texture}

// Binds the tables of the scene and the constants of the view. Public for
// the pass of an extension that bound other constants.
bind_scene_table :: proc(p: ^Pass) {
	r, cmd := p.r, p.cmd
	s := &r.scene
	rhi.cmd_bind_transient(cmd, SLOT_FRAME, p.constants)
	rhi.cmd_bind_sampler(cmd, SLOT_LINEAR_SAMPLER, r.linear_sampler)
	rhi.cmd_bind_sampler(cmd, SLOT_POINT_SAMPLER, r.point_sampler)
	rhi.cmd_bind_sampler(cmd, SLOT_MATERIAL_SAMPLER, r.material_sampler)
	rhi.cmd_bind_buffer(cmd, SLOT_INSTANCES, or_dummy(r, s.instance_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_MESHES, or_dummy(r, s.mesh_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_VERTICES, or_dummy(r, s.vertex_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_INDICES, or_dummy(r, s.index_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_MATERIALS, or_dummy(r, s.material_buffer))
	rhi.cmd_bind_texture(cmd, SLOT_SURFACE, texture_or_dummy(r, p.t.surface))
	rhi.cmd_bind_texture(cmd, SLOT_VIEWS, p.t.motion)
	rhi.cmd_bind_texture(cmd, SLOT_LAYERS, p.t.layers if p.t.layers != 0 else r.dummy_layers)
	rhi.cmd_bind_buffer(cmd, SLOT_LIGHTS, or_dummy(r, s.light_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_LIGHT_TREE, or_dummy(r, s.light_tree_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_BLAS_NODES, or_dummy(r, s.blas_node_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_BLAS_TRIANGLES, or_dummy(r, s.blas_triangle_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_TLAS_NODES, or_dummy(r, s.tlas_node_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_TLAS_REFS, or_dummy(r, s.tlas_ref_buffer))
	if r.hardware_rt && s.tlas != 0 {rhi.cmd_bind_accel(cmd, SLOT_TLAS, s.tlas)}
	g := &r.ddgi
	rhi.cmd_bind_buffer(cmd, SLOT_PROBES, g.probes if g.valid else r.dummy_buffer)
	rhi.cmd_bind_texture(cmd, SLOT_IRRADIANCE, g.irradiance if g.valid else r.dummy_texture)
	rhi.cmd_bind_texture(cmd, SLOT_DISTANCE, g.distance if g.valid else r.dummy_texture)
}

@(private)
shadow_pipeline :: proc(r:^Renderer,software,hardware,colored_software,colored_hardware:Pipeline_Id)->rhi.Pipeline {
    return shadow_target(r,software,hardware,colored_software,colored_hardware)^
}

// The same, as where the renderer keeps it.
@(private)
shadow_target :: proc(r:^Renderer,software,hardware,colored_software,colored_hardware:Pipeline_Id)->^rhi.Pipeline {
    id:=colored_hardware if r.hardware_rt else colored_software
    if !shadows_colored(r) {id=hardware if r.hardware_rt else software}
    return &r.pipelines[id]
}

// Whether shadow rays take the color of the glass they cross.
@(private)
shadows_colored :: proc(r: ^Renderer) -> bool {
	return r.settings.colored_shadows && len(r.scene.translucent) > 0
}

@(private)
set_params :: proc(cmd: ^rhi.Command_List, params: ^$T) {
	rhi.cmd_set_constants(cmd, SLOT_PARAMS, params, size_of(T))
}

@(private)
groups :: proc "contextless" (size, group: u32) -> u32 {return (size + group - 1) / group}

@(private)
read_stats :: proc(r: ^Renderer, slot: int) {
	if ptr := rhi.buffer_mapped(r.device, r.stats_readback[slot]); ptr != nil {
		stats := (cast(^Gpu_Cull_Stats)ptr)^
		r.stats.visible_instances = stats.visible_instances
		r.stats.visible_triangles = stats.visible_triangles
		r.stats.visible_clusters = stats.visible_clusters
		for kind, k in stats.kinds {r.stats.visible_kinds[Visible_Kind_Id(k)] = kind}
		r.stats.visible_late = stats.late
		r.stats.cull_dropped = stats.dropped
		// A list that dropped grows for the frames after, by what it lacked.
		for dropped, list in stats.dropped {
			if dropped > 0 {r.scene.cull_wanted[list] = max(r.scene.cull_wanted[list], r.scene.cull_capacity[list] + dropped)}
		}
		r.stats.culled_instances = stats.culled_instances
		r.stats.occluded_instances = stats.occluded_instances
		r.stats.probes_traced = stats.probes_traced
	}
	r.stats.timings = rhi.frame_timings(r.device)
	total: f32
	for t in r.stats.timings {total += t.ms}
	r.stats.gpu_ms = total
}

// The targets of the G-buffer a view draws to: the reflectance and the
// layers only while a surface in sight needs them, then the instance ids
// while the shaders ask for them.
@(private)
gbuffer_targets :: proc(p: ^Pass) -> (targets: [8]rhi.Texture, count: int) {
	t := p.t
	targets = {t.albedo, t.normal, t.emission, t.motion, t.linear_depth, t.surface, t.layers, 0}
	count = 7 if p.layered else 6 if p.reflectance else 5
	if p.r.frame_layout.instance_ids {targets[count] = t.instance; count += 1}
	return
}

@(private)
gbuffer_pass :: proc(p: ^Pass, phase: u32, clear, keep_depth: bool) {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	if p.draw {
		rhi.cmd_barrier_buffer(cmd, s.cull_state_buffer, .Indirect_Read)
		if program_clusters(r) {rhi.cmd_barrier_buffer(cmd, s.program_bins, .Indirect_Read)}
		for b in ([]rhi.Buffer{s.instance_buffer, s.vertex_buffer, s.index_buffer, s.material_buffer, s.visible_buffer, s.program_visible}) {rhi.cmd_barrier_buffer(cmd, b, .Shader_Read)}
	}
	load: rhi.Load_Op = .Clear if clear else .Load
	targets, count := gbuffer_targets(p)
	pass := rhi.Render_Pass_Desc{color_count = count, name = "gbuffer" if clear else "gbuffer late"}
	for target, i in targets[:count] {pass.colors[i] = {texture = target, load = load, store = .Store}}
	pass.depth = {texture = t.depth, load = load, store = .Store if keep_depth else .Dont_Care, clear = 0}
	rhi.cmd_begin_render_pass(cmd, &pass)
	if p.draw {
		target := &r.pipelines[.Gbuffer_Layers if p.layered else .Gbuffer if p.reflectance else .Gbuffer_Plain]
		if clipped := &r.pipelines[.Gbuffer_Layers_Clip if p.layered else .Gbuffer_Clip if p.reflectance else .Gbuffer_Plain_Clip]; p.camera.clip_plane != {} && clipped^ != 0 {target = clipped}
		rhi.cmd_bind_pipeline(cmd, target^)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.visible_buffer)
		rhi.cmd_draw_indirect(cmd, s.cull_state_buffer, u64(offset_of(Gpu_Cull_State, draws)) + u64(phase) * size_of(Gpu_Draw), 1, size_of(Gpu_Draw))
		gbuffer_programs_draw(p, target, phase)
	}
	rhi.cmd_end_render_pass(cmd)
}

// Draws the clusters of an instance whose mesh is in the pools, for a pass of
// its own (gbuffer.vert without the visible list): those of level 0, or all
// of them, the vertices of those out of the cut of the view collapsed, and
// those of materials of another program than `program` (SLOT_DRAW).
@(private)
instance_clusters_draw :: proc(r: ^Renderer, cmd: ^rhi.Command_List, instance: u32, level0: bool, program: u32) {
	s := &r.scene
	inst := &s.instances[instance]
	mesh := inst.meta.x & INSTANCE_MESH_MASK
	if int(mesh) >= len(s.meshes) || s.meshes[mesh].vertex_count == 0 || mesh_pending(s, mesh) {return}
	m := &s.meshes[mesh]
	clusters := m.cluster_count
	// A streamed mesh draws the finest its pools hold, which may be coarser than level 0.
	if level0 && m.stream == nil {_, clusters = record_level(s, m^, 0)}
	drawn := [4]u32{program, 0, 0, 0}
	rhi.cmd_set_constants(cmd, SLOT_DRAW, &drawn, size_of(drawn))
	rhi.cmd_draw(cmd, clusters * CLUSTER_DRAW_VERTICES, 1, 0, instance)
}

// Editor selection mask: the highlighted instances alone, in full detail
// (level 0) and without the scene's occlusion, so the outline follows their
// complete silhouette. Its unjittered window-point mask is independent of TAA.
@(private)
highlight_pass :: proc(p: ^Pass) {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	for b in ([]rhi.Buffer{s.instance_buffer, s.vertex_buffer, s.index_buffer, s.material_buffer}) {rhi.cmd_barrier_buffer(cmd, b, .Shader_Read)}
	pass := rhi.Render_Pass_Desc{color_count = 1, name = "highlight mask"}
	pass.colors[0] = {texture = t.highlight, load = .Clear, store = .Store}
	pass.depth = {texture = t.highlight_depth, load = .Clear, store = .Dont_Care, clear = 0}
	rhi.cmd_begin_render_pass(cmd, &pass)
	for inst, index in s.instances {
		if !highlight_drawn(inst.meta.w) {continue}
		instance_programs_draw(r, cmd, &r.pipelines[.Highlight], u32(index), true)
	}
	rhi.cmd_end_render_pass(cmd)
}

// Outlines only sample within a few pixels of highlighted silhouettes. Use
// conservative projected world bounds to avoid running the neighborhood
// filter over the rest of the drawable. Camera motion changes only this
// small calculation, never the scene or its acceleration structures.
// view_projection takes a point from eye.
highlight_screen_bounds :: proc(instances: []Gpu_Instance, view_projection: Mat4, eye: Vec3, points, render_size: Vec2, glow: f32) -> Vec4 {
	lo, hi := Vec2{1e30, 1e30}, Vec2{-1e30, -1e30}
	found := false
	for inst in instances {
		if !highlight_drawn(inst.meta.w) {continue}
		for corner in 0 ..< 8 {
			p := Vec3{inst.bounds_min.x if corner & 1 == 0 else inst.bounds_max.x, inst.bounds_min.y if corner & 2 == 0 else inst.bounds_max.y, inst.bounds_min.z if corner & 4 == 0 else inst.bounds_max.z}
			clip := view_projection * Vec4{p.x - eye.x, p.y - eye.y, p.z - eye.z, 1}
			// Bounds crossing the eye plane can cover any part of the screen.
			if !(clip.w > 0.001) {return {0, 0, 1, 1}}
			uv := Vec2{clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5}
			lo = linalg.min(lo, uv); hi = linalg.max(hi, uv); found = true
		}
	}
	if !found {return {1, 1, 0, 0}}
	// Include contour/glow, mask texel rounding and TAA jitter even when the
	// scene renders below drawable resolution or at a different UI density.
	padding := Vec2{max(glow, 1) / max(points.x, 1) + 2 / max(render_size.x, 1), max(glow, 1) / max(points.y, 1) + 2 / max(render_size.y, 1)}
	lo = linalg.max(lo - padding, Vec2{}); hi = linalg.min(hi + padding, Vec2{1, 1})
	return {lo.x, lo.y, hi.x, hi.y}
}

// Traces one ray of the specular lobe of the surfaces of a G-buffer that are
// smooth enough and filters the result over space and time. lit receives the
// direct light plus those reflections, and the current history their radiance.
// shared_from is the roughness from which a block of 2x2 pixels shares a ray;
// a pixel that reflects less than cached_below of what its ray finds lights
// the hit from the probe volume. For a layer of glass the pass runs with the
// dispatch sizes of the cull pass and keeps the history alone.
@(private)
reflect_pass :: proc(p: ^Pass, normal, depth, albedo, history_previous, history_current: rhi.Texture, history_valid, stored_reflectance: bool, shared_from: f32, cached_below: f32 = 0, glass := false) {
	run :: proc(p: ^Pass, glass, half: bool, x, y: u32) {
		if glass {
			rhi.cmd_dispatch_indirect(p.cmd, p.view.glass_dispatch, u64(offset_of(Gpu_Glass_Dispatch, half)) if half else 0)
		} else {
			rhi.cmd_dispatch(p.cmd, x, y)
		}
	}
	Params :: struct {light_budget: u32, max_distance, firefly_clamp, pixel_spread: f32, block: u32, roughness_from, roughness_to, cached_below, detail_below: f32, stored_reflectance, material_roughness: u32, faint_below: f32, resume, pad0, pad1, pad2: u32}
	// The rays of a size of block, then what waits for the programs of what they hit.
	trace :: proc(p: ^Pass, pipeline: rhi.Pipeline, params: ^Params, glass, half: bool, x, y: u32) {
		batch := points_begin(p)
		rhi.cmd_bind_pipeline(p.cmd, pipeline)
		set_params(p.cmd, params)
		points_bind(p)
		run(p, glass, half, x, y)
		points_rounds(p, batch, pipeline, params, 1)
	}
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	settings := &r.settings
	// pixel_spread: what the width of a pixel grows by per unit of distance.
	params := Params{light_budget = settings.reflection_light_budget, max_distance = settings.gi_max_distance, firefly_clamp = settings.firefly_clamp, pixel_spread = p.frame.footprint.y, cached_below = cached_below, detail_below = settings.reflection_detail_roughness}
	// Sharp reflections trace every pixel; the wider lobes one pixel per
	// block of 2x2, in a dispatch of a quarter of the threads.
	split := shared_from if settings.reflection_half_resolution else max(f32)
	// Its rays shade what they hit with the layers of its material, and a
	// layer of glass traces the lobe its own layers shape.
	pipeline: rhi.Pipeline
	if scene_layered(s) || (glass && glass_layered(s)) {
		pipeline = shadow_pipeline(r,.Reflect,.Reflect_Hw,.Reflect_Color,.Reflect_Color_Hw)
	} else {
		pipeline = shadow_pipeline(r,.Reflect_Unlayered,.Reflect_Unlayered_Hw,.Reflect_Unlayered_Color,.Reflect_Unlayered_Color_Hw)
	}
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, albedo)
	rhi.cmd_bind_texture(cmd, SLOT_PASS4, r.dummy_texture if glass else t.motion)
	params.material_roughness = 0 if glass else 1
	// Until the filter has a past to keep, every turn traces.
	params.faint_below = GLASS_FAINT_REFLECTANCE if glass && history_valid else 0
	// A layer of glass always keeps what it reflects.
	params.stored_reflectance = 1 if stored_reflectance else 0
	if s.smoothest < split {
		params.block, params.roughness_from, params.roughness_to = 1, 0, split
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.reflect_raw)
		trace(p, pipeline, &params, glass, false, groups(t.width, 8), groups(t.height, 8))
	}
	if settings.reflection_half_resolution {
		params.block, params.roughness_from, params.roughness_to = 2, split, max(f32)
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.reflect_shared)
		trace(p, pipeline, &params, glass, true, groups(t.half_width, 8), groups(t.half_height, 8))
	}

	Resolve :: struct {history_valid, max_radius, blend, shared_from: f32}
	// The disc keeps its size on screen at any resolution, down to the few
	// pixels a filter needs to have neighbours at all.
	resolve := Resolve{history_valid = 1 if history_valid else 0, max_radius = max(7 * f32(t.height) / 900, 3), blend = 0.08, shared_from = split}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Reflect_Resolve_Glass if glass else .Reflect_Resolve])
	set_params(cmd, &resolve)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.reflect_raw)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, depth)
	if glass {rhi.cmd_bind_buffer(cmd, SLOT_PASS4, p.view.glass_seen)}
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, history_previous)
	rhi.cmd_bind_texture(cmd, SLOT_PASS6, t.motion)
	rhi.cmd_bind_texture(cmd, SLOT_PASS8, history_current)
	rhi.cmd_bind_texture(cmd, SLOT_PASS9, t.reflect_shared)
	run(p, glass, false, groups(t.width, 8), groups(t.height, 8))
}

// Farthest-depth mip chain of the linear depth target.
@(private)
build_depth_pyramid :: proc(p: ^Pass, pyramid: rhi.Texture) {
	r, cmd, t := p.r, p.cmd, p.t
	Params :: struct {source_size: [2]i32, from_depth, pad: u32}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Hiz])
	width, height := t.width, t.height
	for level in 0 ..< t.hiz_levels {
		params := Params{source_size = {i32(width), i32(height)}, from_depth = 1 if level == 0 else 0}
		set_params(cmd, &params)
		if level == 0 {rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.linear_depth)} else {rhi.cmd_bind_texture(cmd, SLOT_PASS0, pyramid, i32(level - 1))}
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, pyramid, i32(level))
		width = max(t.hiz_width >> level, 1)
		height = max(t.hiz_height >> level, 1)
		rhi.cmd_dispatch(cmd, groups(width, 8), groups(height, 8))
	}
}

// A finished image of the window into a target the size of the frame.
@(private)
present_blit :: proc(r: ^Renderer, cmd: ^rhi.Command_List, target: rhi.Texture, format: rhi.Format, source: rhi.Texture) {
	if !ensure_blit_pipeline(r, format) {return}
	rhi.cmd_barrier_texture(cmd, source, .Shader_Read)
	present := rhi.Render_Pass_Desc{color_count = 1, name = "present"}
	present.colors[0] = {texture = target, load = .Dont_Care, store = .Store}
	rhi.cmd_begin_render_pass(cmd, &present)
	Blit_Params :: struct {decode_srgb, pad0, pad1, pad2: u32}
	blit := Blit_Params{decode_srgb = 1 if format == .BGRA8_Srgb || format == .RGBA8_Srgb else 0}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Blit])
	set_params(cmd, &blit)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, source)
	rhi.cmd_draw(cmd, 3)
	rhi.cmd_end_render_pass(cmd)
}

// Records and submits one frame. Must be called outside any immediate
// transaction. Returns false when the frame was skipped (minimized window,
// swapchain recreation) or failed; r.error says which.
renderer_frame :: proc(r:^Renderer,frame:Frame_Desc) -> bool {
    d:=r.device
    r.error=""
    started:=time.tick_now()
    texture_uploads_install(r)
    geometry_uploads_install(r)
    pipelines_install(r)
    // What the extensions asked of this frame lasts for it alone.
    defer {
        r.pass_count=0;r.main_pipeline=0;r.gbuffer_asked={}
        r.antialiasing_offered,r.antialiasing_offered_count=r.antialiasing,r.antialiasing_count
        r.antialiasing_count=0
    }
    r.previous_time,r.time=r.time,frame.time
    // After another world the time may jump by what loading it took: the
    // frame keeps the pace of the one before.
    if !r.world_switched {r.delta_time=max(r.time-r.previous_time,0)}
    r.world_switched,r.world_kept=false,false
    r.frame_changes={}
    // The origin follows the eye of the first view of the window; what the
    // frame places comes relative to it. Every view projects from its own eye.
    if !frame.offscreen && !frame.ui_only {
        eye:=frame.camera.position
        for view in frame.views {if view.texture==0 && !view.disabled {eye=view.camera.position;break}}
        renderer_origin_follow(r,eye)
    }
    textures_views_record(r,frame)
    frame,framed:=origin_frame(r,frame)
    if !framed {return false}
    displaced_prepare(r)
    skins_bounds(r)
    // What changed for the shadows reaches the views of a frame that draws the scene.
    if !frame.ui_only {r.frame_occluders,r.scene.occluders=r.scene.occluders,{}}
    batches_build(r)
    // The room for the lights of the GPU sizes the light buffers: it is taken before they are made.
    scene_light_region(r)
    if !ensure_scene_capacity(r) {return false}
    if !frame.offscreen && !frame.ui_only {
        // The cuts rays trace follow the eye of the first view of the window, as the probes.
        eye:=frame.camera.position
        for view in frame.views {if view.texture==0 && !view.disabled {eye=view.camera.position;break}}
        if frame.detail.on {eye=frame.detail.camera.position}
        ray_cuts_update(r,eye)
    }
    if r.settings.gi_enabled && !frame.offscreen && !frame.ui_only {
        // The probes follow the focus of the first view of the window.
        focus:=camera_focus(frame.camera)
        for view in frame.views {if view.texture==0 && !view.disabled {focus=camera_focus(view.camera);break}}
        if ddgi_ensure(r) {ddgi_place(r,focus)}
    } else if !r.settings.gi_enabled && r.ddgi.valid {ddgi_release(r)}
    if r.main.targets.ldr==0 && !create_targets(r,&r.main,r.window_width,r.window_height,window_render_scale(r,f32(r.window_height)),true) {return false}
    // A frame no window shows that draws only into textures leaves the views
    // of the window as they are: it records those alone.
    alone:=frame.offscreen && len(frame.views)>0
    for view in frame.views {if view.texture==0 {alone=false}}
    if !prepare_views(r,frame.views,alone) {return false}
    if r.view_count==0 && !ensure_glass_targets(r,&r.main.targets) {return false}
    if !frame.ui_only && (!air_tables_ensure(r) || !points_prepare(r)) {return false}
    // A window whose pipeline generates frames shows them through the presenter of the device.
    if !frame.offscreen {
        _,main_plan:=view_plan(r,0,true)
        rhi.swapchain_set_paced(d,main_plan.generates)
    }
    prepared:=time.tick_now()
    cmd,began:=rhi.frame_begin(d,!frame.offscreen)
    if !began {
        set_error(r,"the device gave no frame to draw: %s",rhi.device_error(d)!=""?rhi.device_error(d):"the window is being resized or its image is not ready")
        return false
    }
    begun:=time.tick_now()
    slot:=int(rhi.frame_number(d)%rhi.MAX_FRAMES_IN_FLIGHT)
    read_stats(r,slot)
    points_read(r,slot)
    pages_update(r,slot)
    extension_counters_begin(r,cmd,slot)
    depth_probes_begin(r,cmd,slot,frame.probes)
    extension_readbacks_take(r,slot)
    r.stats.counters=r.counters.counters[:r.counters.count]
    r.stats.ui_vertices_dropped,r.stats.debug_vertices_dropped=0,0
    r.stats.ui_shapes_dropped,r.stats.ui_layers_dropped=0,0
    r.ui_shape_written,r.ui_shape_cache_count,r.ui_vertex_cache_count=0,0,0
    ui_written:=0
    s:=&r.scene
    if s.instances_dirty || len(s.touched)>0 || s.materials_dirty || len(s.material_ranges)>0 {r.textures.residency.stale=true}
    r.scene_uploads_change=s.instances_dirty || len(s.touched)>0 || s.materials_dirty || len(s.material_ranges)>0 || s.lights_dirty || s.lights_changed
    s.lights_changed=false
    texture_uploads_record(r,cmd)
    recorded_ok:=renderer_commit_geometry(r,cmd,slot) && font_record(r,cmd,slot) && upload_scene(r,cmd) && (frame.ui_only || air_frame(r,cmd))
    if recorded_ok {pages_record_begin(r,cmd)}
    // The BLASes built frames ago become their compacted copies; the TLAS of this frame names those.
    if recorded_ok && r.hardware_rt {
        if replaced,freed:=rhi.cmd_compact_blases(cmd);replaced>0 {s.tlas_dirty=true;geometry_released(s,freed)}
    }
    histories_rescale(r,cmd)
    if recorded_ok {ui_textures_record(r,cmd,slot,&ui_written,frame.ui_textures)}
    if recorded_ok && !frame.ui_only {
        geometry:=Pass{r=r,cmd=cmd,slot=slot}
        stage_run(&geometry,.Geometry)
        recorded_ok=deformables_record(r,cmd)
    }
    // The views drawn into a texture come first: those of the window may show
    // them. What runs once a frame goes with the first view of the window, or
    // with the first one of a frame alone.
    first:=alone
    for view in frame.views {
        if view.texture==0 || view.disabled || !recorded_ok || frame.ui_only {continue}
        state:=texture_view_find(r,view.texture)
        if state==nil {continue}
        recorded_ok=record_view(r,cmd,state,view,{offscreen=frame.offscreen},slot,&ui_written,first)
        first=false
        if recorded_ok {texture_view_show(r,cmd,state,slot,view.readback)}
    }
    first=true
    generated:=false
    r.main.generated=false
    for &view in r.views {view.generated=false}
    if recorded_ok && !alone && frame.ui_only {
        // What covers the scene may show images of previews: they are drawn without it.
        if r.preview_count>0 {
            rhi.cmd_timestamp(cmd,"previews")
            previews_pass(r,cmd,slot)
        }
        compose_views(r,cmd,{ui=frame.ui},slot,&ui_written)
    } else if recorded_ok && !alone && r.view_count==0 {
        single:=Frame_View{camera=frame.camera,camera_cut=frame.camera_cut,carried=frame.carried,inspection=frame.inspection}
        for view in frame.views {
            if view.texture==0 {single.camera,single.camera_cut,single.carried,single.pipeline,single.inspection=view.camera,view.camera_cut,view.carried,view.pipeline,view.inspection;break}
        }
        recorded_ok=record_view(r,cmd,&r.main,single,frame,slot,&ui_written,first)
        generated=recorded_ok && r.main.generated
    } else if recorded_ok && !alone {
        index:=0
        for view in frame.views {
            if view.texture!=0 {continue}
            state:=&r.views[index]
            index+=1
            if view.disabled {state.has_previous=false;continue}
            ok:=record_view(r,cmd,state,view,{panels=frame.panels,debug=frame.debug,effect_views=frame.effect_views,offscreen=frame.offscreen},slot,&ui_written,first,index-1)
            first=false
            recorded_ok &&=ok
            if !ok {break}
        }
        if recorded_ok {compose_views(r,cmd,frame,slot,&ui_written)}
        for &view in r.views[:r.view_count] {generated||=view.generated}
        if recorded_ok && generated {
            recorded_ok=ensure_generated_target(r,&r.main.targets)
            if recorded_ok {compose_views(r,cmd,frame,slot,&ui_written,true)}
        }
    }
	// ---------------------------------------------------------- present
	if swap := rhi.swapchain_texture(d); recorded_ok && swap != 0 {present_blit(r, cmd, swap, rhi.swapchain_format(d), r.main.targets.ldr)}
	shown_generated := false
	if before := rhi.swapchain_generated_texture(d); recorded_ok && generated && before != 0 {
		present_blit(r, cmd, before, rhi.swapchain_format(d), r.main.targets.generated)
		shown_generated = true
	}
	r.stats.generated = shown_generated
	// The image another process shows, left ready for it to sample.
	if recorded_ok && frame.output != 0 {
		present_blit(r, cmd, frame.output, rhi.texture_desc(d, frame.output).format, r.main.targets.ldr)
		rhi.cmd_barrier_texture(cmd, frame.output, .Shader_Read)
	}
    if recorded_ok {
        if r.settings.gi_enabled {
            if r.ddgi.valid {rhi.cmd_copy_buffer(cmd,r.ddgi.chosen,0,r.stats_buffer,u64(offset_of(Gpu_Cull_Stats,probes_traced)),4)}
        }
        rhi.cmd_copy_buffer(cmd,r.stats_buffer,0,r.stats_readback[slot],0,size_of(Gpu_Cull_Stats))
        rhi.cmd_barrier_buffer(cmd,r.stats_readback[slot],.Host_Read)
        pages_record_end(r,cmd,slot)
        points_end(r,cmd,slot)
        extension_counters_end(r,cmd,slot)
        depth_probes_end(r,cmd,slot)
    }
	rhi.cmd_timestamp(cmd, "end")
	recorded := time.tick_now()
	ok := rhi.frame_end(d, cmd, shown_generated)
	ended := time.tick_now()
	r.stats.cpu_prepare_ms = f32(time.duration_milliseconds(time.tick_diff(started, prepared)))
	r.stats.cpu_begin_ms = f32(time.duration_milliseconds(time.tick_diff(prepared, begun)))
	r.stats.cpu_record_ms = f32(time.duration_milliseconds(time.tick_diff(begun, recorded)))
	r.stats.cpu_end_ms = f32(time.duration_milliseconds(time.tick_diff(recorded, ended)))

	r.frame += 1
	update_stats(r)
	if !ok {set_error(r, "the frame was not submitted: %s", rhi.device_error(d))}
	return ok && recorded_ok
}

// What the histories of the views and the probe volume hold of light, in the
// units of a new light scale (Renderer.light_rescale): a change of units, not
// of light, keeps every history.
@(private)
histories_rescale :: proc(r: ^Renderer, cmd: ^rhi.Command_List) {
	if r.light_rescale <= 0 {return}
	Params :: struct {scale: f32, encoded: u32, pad: [2]u32} // encoded: 1 for the irradiance atlases of the probe volume
	params := Params{scale = r.light_rescale, encoded = 1}
	r.light_rescale = 0
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.History_Scale])
	scale :: proc(r: ^Renderer, cmd: ^rhi.Command_List, texture: rhi.Texture) {
		if texture == 0 {return}
		desc := rhi.texture_desc(r.device, texture)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, texture)
		rhi.cmd_dispatch(cmd, groups(desc.width, 8), groups(desc.height, 8))
	}
	if r.ddgi.valid {
		set_params(cmd, &params)
		scale(r, cmd, r.ddgi.irradiance);scale(r, cmd, r.ddgi.kept)
	}
	params.encoded = 0
	set_params(cmd, &params)
	for view in views_all(r) {
		t := &view.targets
		for i in 0 ..< 2 {
			for texture in ([?]rhi.Texture{t.taa[i], t.hdr[i], t.reflect_history[i], t.glass_history[i]}) {scale(r, cmd, texture)}
		}
	}
}

// One view of the frame, from its G-buffer to its image in t.ldr. frame: what
// is drawn over the image of a view of the window.
@(private)
record_view :: proc(r:^Renderer,cmd:^rhi.Command_List,state:^View_State,view:Frame_View,frame:Frame_Desc,slot:int,ui_written:^int,first:bool,index:=0) -> bool {
    if view.camera_cut || !state.has_previous {view_camera_cut(state)}
    // A camera carried with what it sees keeps its histories: its last frame
    // is taken as seen from where the camera would have been.
    if view.carried!={} && state.has_previous {
        back:=linalg.inverse(view.carried)
        state.prev_view_proj=state.prev_view_proj*matrix_from_eye(back)
        state.prev_eye=point_carried(view.carried,state.prev_eye)
        state.prev_depth_plane=plane_carried(state.prev_depth_plane,back)
    }
    handle,plan:=view_plan(r,view.pipeline,view.texture==0)
    if !view_pipeline_prepare(r,state,handle,plan) {return false}
    // The passes after the Output stage generate the image shown before this
    // one, for a view of a window; with a history, it is shown.
    generate:=plan.generates && view.texture==0 && !frame.offscreen
    shown:=generate && state.has_previous && !state.resources_made
    if generate && !ensure_generated_target(r,&state.targets) {return false}
    extension_textures_release(r,state)
    p:=Pass{r=r,cmd=cmd,view=state,t=&state.targets,camera=view.camera,slot=slot,first=first,index=index,plan=plan,texture=view.texture!=0,offscreen=frame.offscreen,inspection=view.inspection,wide=view.texture!=0?view.wide:.None}
    p.current=int(state.frames%2)
    p.previous=1-p.current
    if !view_begin(&p) {return false}
    output:=false
    for index in plan.order[:plan.order_count] {
        pass:=&plan.passes[index]
        ok:=true
        switch pass.stage {
        case .Custom:      if !output || generate {custom_pass_record(&p,pass)}
        case .Geometry:    ok=pass_gbuffer(&p)
        case .Nested:      ok=pass_nested(&p)
        case .Surface:     if r.pass_count>0 {stage_run(&p,.Surface)}
        case .Direct:      ok=pass_direct(&p,pass.direct)
        case .Reflections: ok=pass_reflections(&p)
        case .World:       ok=pass_world_lighting(&p)
        case .Indirect:    ok=pass_indirect(&p)
        case .Composite:   pass_composite(&p)
        case .Lit:         if r.pass_count>0 && !view_inspected(p.inspection) {lit_run(&p)}
        case .Transparency:pass_transparent(&p)
        case .Resolve:     pass_taa(&p)
        case .Output:      ok=pass_output(&p,frame,ui_written,!generate);output=true
        }
        if !ok {return false}
    }
    if generate {overlays_pass(&p,frame,ui_written,shown)}
    state.generated=shown
    state.prev_view_proj=p.unjittered
    state.prev_eye=p.camera.position
    state.prev_jitter=p.jitter
    state.prev_depth_plane=p.frame.depth_plane
    state.has_previous=true
    state.resources_frames+=1
    state.frames+=1
    state.last_frame=r.frame
    return true
}

// The sun, the sky and the background of a frame in render units: scale per
// nit. disc: the angular radius of the disc of a sun that shows one. Under
// the air of an atmosphere, the sun is as bright above it as it has to be to
// give its illuminance on the ground when it stands overhead.
@(private)
frame_sun_sky :: proc(f: ^Gpu_Frame, sun: Sun_Desc, environment: Environment, scale, disc: f32, air, shadows: bool) {
	if sun.enabled {
		light := sun.color * (sun.illuminance / math.PI * scale)
		if air && environment.sky_atmosphere {light *= air_overhead(environment.air)}
		f.sun_direction = {sun.direction.x, sun.direction.y, sun.direction.z, 1 if shadows else SUN_UNSHADOWED}
		f.sun_color = {light.x, light.y, light.z, disc if sun.disc else 0}
	}
	sky := environment.sky * scale
	f.sky_color = {sky.x, sky.y, sky.z, scale}
	background := environment.background * scale
	f.background = {background.x, background.y, background.z, 1 if environment.use_background else 0}
}

// A look of the sky as the frame names it: an atmosphere (y 1) once its
// tables are built, or an image, its slot in the texture table, its last
// level and 1, or zero for a gradient.
@(private)
sky_map :: proc(r: ^Renderer, texture: Texture_Handle, atmosphere: bool) -> Vec4 {
	if atmosphere && r.air.built {return {0, 1, 0, 0}}
	index := int(texture) - 1
	if index < 0 || index >= r.textures.count || r.textures.textures[index] == 0 {return {}}
	size := r.textures.sizes[index]
	return {f32(texture_entry(index)), 0, math.floor(math.log2(f32(max(size[0], size[1], 1)))), 1}
}

// The constants of the view and what it decides for all its passes.
@(private)
view_begin :: proc(p: ^Pass) -> bool {
	r, cmd, t, camera := p.r, p.cmd, p.t, p.camera
	d := r.device
	s := &r.scene
	g := &r.ddgi
	settings := &r.settings
	p.use_gi = settings.gi_enabled
	p.use_probes = p.use_gi && g.valid
	// Skipped while no material is smooth enough to have a pixel traced.
	p.use_reflections = settings.reflections && len(s.materials) > 0 && s.smoothest < settings.reflection_roughness && .Reflections in p.plan.stages

	// The matrices of the view take a point from its eye (frame.camera_position,
	// view_clip of scene.slang): far from the origin a point near the eye keeps
	// what f32 holds of it, and the image does not shake.
	low, high := scene_box(r)
	reach := camera_reach(camera, low, high)
	view, proj, forward := camera_matrices(camera, f32(t.width) / f32(t.height), reach)
	view = matrix_from_eye(view)
	unjittered := proj * view
	phases := u32(0)
	switch p.plan.jitter {
	case .Resolve: if settings.taa && .Resolve in p.plan.stages {phases = TAA_JITTER_PHASES}
	case .None:
	case .Upscale: phases = upscale_jitter_phases(t.width, t.output_width)
	}
	jitter := taa_jitter(p.view.frames, phases) if phases > 0 else Vec2{}
	p.jitter_phases = phases
	// Sub-pixel offset applied in NDC (pixel y grows downwards, NDC y upwards).
	shift := Mat4(1)
	shift[0, 3] = 2 * jitter.x / f32(t.width)
	shift[1, 3] = -2 * jitter.y / f32(t.height)
	view_proj := shift * unjittered
	p.view_matrix, p.unjittered, p.jitter = view, unjittered, jitter
	f := Gpu_Frame{
		view = view, proj = proj, view_proj = view_proj, inv_view_proj = linalg.inverse(view_proj),
		view_proj_unjittered = unjittered,
		jitter = {jitter.x, jitter.y, p.view.prev_jitter.x, p.view.prev_jitter.y},
		camera_position = {camera.position.x, camera.position.y, camera.position.z, max(camera.near, 0.001)},
		camera_forward = {forward.x, forward.y, forward.z, reach},
		frustum = frustum_from_eye(unjittered, camera.position),
		resolution = {f32(t.width), f32(t.height)},
		inv_resolution = {1 / f32(t.width), 1 / f32(t.height)},
		time={r.time,r.previous_time,r.delta_time,0},
		frame_index = u32(p.view.frames),
		light_nodes = u32(len(s.light_tree)),
		shadowless_lights = light_region_frame(s.light_region),
		instance_count = u32(len(s.instances)),
		cut = {settings.lod_error_pixels, settings.batch_min_pixels if settings.lod_error_pixels > 0 else 0, 0, 0},
		batches = {s.batch.slots, s.batch.groups.first, u32(len(s.batch.drawn)), u32(len(s.batch.traced))},
		debug_view = DEBUG_VIEW_EXTENSION if p.inspection.mode == .None && p.inspection.record != nil else u32(p.inspection.mode),
		gi_strength = settings.gi_strength,
		exposure = view_exposure(p),
		// Rendering below the output resolution samples the mips the output would use.
		texturing = {clamp(math.log2(f32(t.width) / f32(t.output_width)), -2, 0), settings.reflection_roughness if p.use_reflections else 0, f32(s.tlas_node_count), f32(s.glass_node_count)},
	}
	frame_view_constants(&f, camera, view, shift * proj, proj, forward, f32(t.height))
	// The detail is that of the views of the window, also those of a frame that captures it.
	if detail := r.frame_detail; detail.on && (!p.texture || p.offscreen) {
		_, chosen, _ := camera_matrices(detail.camera, f32(t.width) / f32(t.height), camera_reach(detail.camera, low, high))
		pixel := 2 / (abs(chosen[1, 1]) * f32(t.height))
		eye := detail.camera.position
		f.detail_eye = {eye.x, eye.y, eye.z, max(detail.camera.near, 0.001)}
		f.detail_footprint = {pixel * chosen[3, 3], -pixel * chosen[3, 2], 0, 0}
	}
	f.origin = origin_cells(r.origin)
	f.scene_box = {{low.x, low.y, low.z, 0}, {high.x, high.y, high.z, 0}}
	if !p.view.has_previous {p.view.prev_view_proj, p.view.prev_depth_plane, p.view.prev_eye = unjittered, f.depth_plane, camera.position}
	f.prev_view_proj, f.prev_depth_plane = p.view.prev_view_proj, p.view.prev_depth_plane
	f.prev_eye = {p.view.prev_eye.x, p.view.prev_eye.y, p.view.prev_eye.z, 0}
	// The clip plane of the view in place of the near one: what is all behind it is not drawn.
	if camera.clip_plane != {} {
		length := linalg.length(camera.clip_plane.xyz)
		if length > 1e-8 {f.frustum[5] = camera.clip_plane / length}
	}
	scale := s.light_scale if s.light_scale > 0 else 1
	frame_sun_sky(&f, s.sun, s.environment, scale, max(settings.sun_radius, SUN_RADIUS), r.air.built, settings.sun_shadows)
	f.sky_map = sky_map(r, s.environment.sky_texture, s.environment.sky_atmosphere)
	f.sky_from_map = sky_map(r, s.environment.sky_from_texture, s.environment.sky_from_atmosphere)
	air_view(p, &f)
	tint := exposure_of_camera(r, camera).tint
	f.tint = {1, 1, 1, 0} if tint == {} else {tint.x, tint.y, tint.z, 0}
	orientation := s.environment.sky_orientation
	if orientation == {} {orientation = 1}
	f.sky_orientation = {imag(orientation), jmag(orientation), kmag(orientation), real(orientation)}
	if weight := clamp(s.environment.sky_from_weight, 0, 1); weight > 0 {
		from := s.environment.sky_from * scale
		f.sky_from = {from.x, from.y, from.z, weight}
	}
	if r.has_backdrop && !p.texture {
		backdrop := r.backdrop * scale
		f.background = {backdrop.x, backdrop.y, backdrop.z, 1}
	}
	if p.use_gi {f.flags |= FRAME_FLAG_GI}
	if p.use_gi && settings.reference_gi {f.flags |= FRAME_FLAG_GI_REFERENCE}
	if r.hardware_rt {f.flags |= FRAME_FLAG_HW_RT}
	if s.environment.ground_grid && !p.texture {f.flags |= FRAME_FLAG_GRID}
	if len(s.translucent) > 0 {f.flags |= FRAME_FLAG_GLASS}
	p.reflectance, p.layered = reflectance_in_frustum(r, f.frustum)
	// What the surfaces of the Gbuffer stage of extensions need, wherever they are.
	if stage_asked(r, .Gbuffer) {
		p.layered ||= .Layers in r.gbuffer_asked
		p.reflectance ||= p.layered || .Reflectance in r.gbuffer_asked
	}
	if p.reflectance && !ensure_surface_target(r, t) {return false}
	if p.layered && !ensure_layers_target(r, t) {return false}
	if r.frame_layout.instance_ids && !ensure_instance_target(r, t) {return false}
	if p.reflectance {f.flags |= FRAME_FLAG_REFLECTANCE}
	if p.use_probes {ddgi_frame_constants(r, &f)}
	frame_occluders(&f, &r.frame_occluders)
	p.constants = rhi.frame_alloc(d, u64(r.frame_layout.size), 256)
	if p.constants.ptr == nil {
		set_error(r, "frame constants: %s", rhi.device_error(d))
		return false
	}
	p.frame = f
	frame_constants_write(p)

	rhi.cmd_timestamp(cmd, "upload")
	frame_exposure_copy(p, p.constants)
	if t.needs_clear {
		clear_textures(cmd, t.hdr[0], t.hdr[1], t.taa[0], t.taa[1], t.taa_frames[0], t.taa_frames[1], t.reactive, r.dummy_texture, r.dummy_layers)
		t.needs_clear = false
	}
	if t.glass_needs_clear {
		clear_textures(cmd, t.glass_history[0], t.glass_history[1])
		t.glass_needs_clear = false
	}
	bind_scene_table(p)
	if !air_aerial(p) {return false}
	if !glass_means_record(p) {return false}

	// What the stages a pipeline may leave out give the ones after them.
	p.reflections, p.gi = 0, r.dummy_texture
	p.instance_count = u32(len(s.instances))
	p.batch_slots = s.batch.slots
	p.draw = p.instance_count + p.batch_slots > 0 && s.index_buffer != 0
	// Modes of inspection show the opaque scene alone.
	transparency := .Transparency in p.plan.stages && !view_inspected(p.inspection)
	p.draw_translucent = p.draw && transparency && glass_in_frustum(r, f.frustum)
	p.draw_overlays = p.draw && transparency && s.overlay_count>0
	p.blend = transparency && stage_asked(r, .Blend)
	return true
}

// The constants of the view into the memory the frame gave them.
@(private)
frame_constants_write :: proc(p: ^Pass) {
	frame_constants_fill(p.r, p.constants.ptr, &p.frame)
}

// Constants of a frame into memory of the size the shaders in use ask for:
// what an extension keeps after them starts empty, and no nested view sees
// anything.
@(private)
frame_constants_fill :: proc(r: ^Renderer, to: rawptr, frame: ^Gpu_Frame) {
	layout := &r.frame_layout
	mem.copy(to, frame, size_of(Gpu_Frame))
	if layout.size > size_of(Gpu_Frame) {mem.zero(rawptr(uintptr(to) + size_of(Gpu_Frame)), layout.size - size_of(Gpu_Frame))}
	if layout.nested {
		blocks := ([^]Gpu_Nested)(rawptr(uintptr(to) + size_of(Gpu_Frame)))[:NESTED_VIEW_CAPACITY]
		for &block in blocks {block.eye = {1e30, 1e30, 1e30, 1}}
	}
}

// Constants for the passes of a frame that belong to no view.
@(private)
frame_constants :: proc(r: ^Renderer, frame: Gpu_Frame) -> rhi.Transient {
	frame := frame
	constants := rhi.frame_alloc(r.device, u64(r.frame_layout.size), 256)
	if constants.ptr != nil {frame_constants_fill(r, constants.ptr, &frame)}
	return constants
}

// The parameters of the cull passes (Params_Block of cull_common.slang).
@(private)
Cull_Params :: struct {
	phase, occlusion, hiz_levels, programs: u32,
	glass_groups: [4]u32,
	chunk_capacity, visible_capacity, candidate_capacity, program_capacity: u32,
	pages: [4]u32, // pages_cull_params
}

// The state of the cull of a view as each starts: the draws of its phases
// with the vertices of a cluster and no instances, nothing counted.
@(private)
cull_reset :: proc(r: ^Renderer, cmd: ^rhi.Command_List) -> bool {
	start := [1]Gpu_Cull_State{{
		draws = {{vertex_count = CLUSTER_DRAW_VERTICES}, {vertex_count = CLUSTER_DRAW_VERTICES}},
		chunk_dispatch = {0, 0, 1}, candidate_dispatch = {0, 1, 1},
	}}
	if program_clusters(r) {cull_programs_dispatch(r, cmd, 0, 0)}
	return upload_transient(r, cmd, start[:], r.scene.cull_state_buffer)
}

// Whether the cull lists the clusters of Surface programs apart: a material
// of the scene has a program.
@(private)
program_clusters :: proc(r: ^Renderer) -> bool {
	return r.points.programs > 0 && r.scene.programmed_rows > 0 && r.scene.program_bins != 0
}

// A pass of cull_programs.comp over the clusters of Surface programs of a phase.
@(private)
cull_programs_dispatch :: proc(r: ^Renderer, cmd: ^rhi.Command_List, mode, phase: u32) {
	s := &r.scene
	Params :: struct {mode, phase, programs, capacity: u32}
	params := Params{mode = mode, phase = phase, programs = r.points.programs, capacity = s.cull_capacity[.Programs]}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Cull_Programs])
	set_params(cmd, &params)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.program_bins)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, s.program_visible)
	switch mode {
	case 0:
		rhi.cmd_barrier_buffer(cmd, s.program_bins, .Shader_Write)
		rhi.cmd_dispatch(cmd, groups(r.points.programs, 64))
	case 2:
		rhi.cmd_dispatch(cmd, 1)
	case:
		rhi.cmd_barrier_buffer(cmd, s.program_bins, .Indirect_Read)
		rhi.cmd_dispatch_indirect(cmd, s.program_bins, u64(PROGRAMS_DISPATCH + 3 * phase) * size_of(u32))
	}
	rhi.cmd_barrier_buffer(cmd, s.program_bins, .Shader_Write)
}

// The clusters of Surface programs the cull of a phase listed, by program:
// the draws of each program read them (gbuffer_programs_draw).
@(private)
cull_programs_bin :: proc(p: ^Pass, phase: u32) {
	if !program_clusters(p.r) {return}
	for mode in u32(1) ..= 3 {cull_programs_dispatch(p.r, p.cmd, mode, phase)}
}

// The layout of Scene_State.program_bins (cull_programs.slang), for the most bins.
@(private) PROGRAMS_DISPATCH :: 2
@(private) PROGRAMS_HEADER :: 8
@(private)
program_entry_word :: proc "contextless" (entry: u32) -> u32 {return PROGRAMS_HEADER + 14 * POINTS_PROGRAM_CAPACITY + 3 * entry}
@(private)
program_draw_offset :: proc "contextless" (phase, program, programs: u32) -> u64 {
	return u64(PROGRAMS_HEADER + 6 * programs + (phase * programs + program) * 4) * size_of(u32)
}

// The clusters of each Surface program of the scene that the cull of the view
// listed in a phase, each with the stage of its program, or with the one of
// `target` while the shaders in use have none.
@(private)
gbuffer_programs_draw :: proc(p: ^Pass, target: ^rhi.Pipeline, phase: u32) {
	r, cmd := p.r, p.cmd
	s := &r.scene
	if !program_clusters(r) {return}
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.program_visible)
	for program in renderer_programs(r) {
		if program.domain != .Surface || program.id >= r.points.programs || s.program_rows[program.id] == 0 {continue}
		rhi.cmd_bind_pipeline(cmd, program_graphics(r, target, program.id))
		rhi.cmd_draw_indirect(cmd, s.program_bins, program_draw_offset(phase, program.id, r.points.programs), 1, size_of(Gpu_Draw))
	}
}

@(private)
cull_bind :: proc(p: ^Pass, params: Cull_Params, hiz: rhi.Texture, stats, glass: rhi.Buffer) {
	r, cmd := p.r, p.cmd
	s := &r.scene
	params := params
	params.chunk_capacity, params.visible_capacity, params.candidate_capacity = s.cull_capacity[.Chunks], s.cull_capacity[.Visible], s.cull_capacity[.Candidates]
	if program_clusters(r) {params.programs, params.program_capacity = r.points.programs, s.cull_capacity[.Programs]}
	params.pages = pages_cull_params(r)
	set_params(cmd, &params)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.cull_state_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, stats)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, hiz)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS5, s.chunk_buffer)
	// The cluster pass asks for pages and stamps their slots.
	rhi.cmd_bind_buffer(cmd, SLOT_PASS7, or_dummy(r, s.pages.request_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_PASS8, or_dummy(r, s.pages.stamp_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_PASS9, or_dummy(r, s.program_bins))
}

// The lists a pass of the cull reads and writes, after what the passes and
// copies before it wrote or read of them: the cluster pass reads the chunks
// the instance pass just wrote at the same places phase 0 wrote its own, and
// phase 1 counts in the state the frame reset.
@(private)
cull_lists_ready :: proc(p: ^Pass, stats, glass: rhi.Buffer) {
	s := &p.r.scene
	for b in ([]rhi.Buffer{s.cull_state_buffer, s.chunk_buffer, s.candidate_buffer, s.cluster_candidate_buffer, s.visible_buffer, s.program_bins, stats, glass, s.pages.request_buffer, s.pages.stamp_buffer}) {
		if b != 0 {rhi.cmd_barrier_buffer(p.cmd, b, .Shader_Write)}
	}
}

// The two passes of a phase of the cull: by instance, which hands the
// clusters of their cuts over in chunks, and by cluster over the chunks.
@(private)
cull_record :: proc(p: ^Pass, params: Cull_Params, hiz: rhi.Texture, stats, glass: rhi.Buffer) {
	r, cmd := p.r, p.cmd
	s := &r.scene
	cull_lists_ready(p, stats, glass)
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Cull])
	cull_bind(p, params, hiz, stats, glass)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS3, s.candidate_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, glass)
	rhi.cmd_dispatch(cmd, groups(p.instance_count + p.batch_slots, 64))
	rhi.cmd_barrier_buffer(cmd, s.cull_state_buffer, .Indirect_Read)
	cull_lists_ready(p, stats, glass)
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Cull_Clusters])
	cull_bind(p, params, hiz, stats, glass)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS3, s.cluster_candidate_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS6, s.visible_buffer)
	rhi.cmd_dispatch_indirect(cmd, s.cull_state_buffer, u64(offset_of(Gpu_Cull_State, chunk_dispatch)))
}

// Culling and the G-buffer. Phase 0 draws what last frame's depth pyramid
// says is visible; the pyramid of this frame then rescues occlusion-rejected
// instances and clusters that are visible after all (phase 1), so the result
// is exact with no popping. The pyramid is built before any nested view is
// drawn: it holds the depths of the view alone.
@(private)
pass_gbuffer :: proc(p: ^Pass) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	settings := &r.settings
	threads := p.instance_count + p.batch_slots
	occlusion := settings.occlusion_culling && threads > 0
	keep_depth := p.draw_translucent || p.draw_overlays || p.blend || stage_asked(r, .Gbuffer) || r.pass_count > 0 && .Nested in p.plan.stages
	glass_groups := [4]u32{groups(t.width, 8), groups(t.height, 8), groups(t.half_width, 8), groups(t.half_height, 8)}
	rhi.cmd_timestamp(cmd, "cull")
	rhi.cmd_fill_buffer(cmd, r.stats_buffer, 0, size_of(Gpu_Cull_Stats), 0)
	rhi.cmd_copy_buffer(cmd, p.view.glass_dispatch, u64(offset_of(Gpu_Glass_Dispatch, seen)), p.view.glass_seen, 0, size_of(u32))
	rhi.cmd_fill_buffer(cmd, p.view.glass_dispatch, 0, size_of(Gpu_Glass_Dispatch), 0)
	if !cull_reset(r, cmd) {return false}
	if threads > 0 {
		cull_record(p, {phase = 0, occlusion = 1 if occlusion && t.hiz_valid else 0, hiz_levels = t.hiz_levels, glass_groups = glass_groups}, t.hiz[p.previous], r.stats_buffer, p.view.glass_dispatch)
	}
	cull_programs_bin(p, 0)
	rhi.cmd_timestamp(cmd, "gbuffer")
	gbuffer_pass(p, 0, true, occlusion || keep_depth)
	if occlusion && p.draw {
		rhi.cmd_timestamp(cmd, "occlusion")
		build_depth_pyramid(p, t.hiz[p.current])
		// Phase 1 hands its own chunks over, from none: a dispatch of x 0, y 0
		// and z 1 (a fill writes bytes, so z is uploaded as a word); its draw
		// lists after those of phase 0.
		restart := [4]u32{0, 0, 1, 0}
		if !upload_transient(r, cmd, restart[:], s.cull_state_buffer, u64(offset_of(Gpu_Cull_State, chunk_dispatch))) {return false}
		params := Cull_Params{phase = 1, occlusion = 1, hiz_levels = t.hiz_levels, glass_groups = glass_groups}
		cull_record(p, params, t.hiz[p.current], r.stats_buffer, p.view.glass_dispatch)
		rhi.cmd_barrier_buffer(cmd, s.cull_state_buffer, .Indirect_Read)
		cull_lists_ready(p, r.stats_buffer, p.view.glass_dispatch)
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Cull_Clusters_Candidates])
		cull_bind(p, params, t.hiz[p.current], r.stats_buffer, p.view.glass_dispatch)
		rhi.cmd_dispatch_indirect(cmd, s.cull_state_buffer, u64(offset_of(Gpu_Cull_State, candidate_dispatch)))
		cull_programs_bin(p, 1)
		rhi.cmd_timestamp(cmd, "gbuffer late")
		draw1 := u64(offset_of(Gpu_Cull_State, draws)) + size_of(Gpu_Draw)
		rhi.cmd_copy_buffer(cmd, s.cull_state_buffer, u64(offset_of(Gpu_Cull_State, draws)) + u64(offset_of(Gpu_Draw, instance_count)), s.cull_state_buffer, draw1 + u64(offset_of(Gpu_Draw, first_instance)), size_of(u32))
		gbuffer_pass(p, 1, false, keep_depth)
		// The pyramid the next frame tests against holds what both phases drew:
		// what phase 1 rescued hides what is behind it from the next phase 0.
		rhi.cmd_timestamp(cmd, "depth pyramid")
		build_depth_pyramid(p, t.hiz[p.current])
		t.hiz_valid = true
	} else {
		t.hiz_valid = false
	}
	if p.first && stage_asked(r, .Simulate) {simulate_run(p)}
	if stage_asked(r, .Gbuffer) {stage_run(p, .Gbuffer)}

	if !p.texture && s.highlighted > 0 && ensure_highlight_targets(r, t) {
		rhi.cmd_timestamp(cmd, "highlight")
		highlight_pass(p)
	}
	return true
}

// The masks extensions draw in the Mask stage and the G-buffers of the nested
// views they add.
@(private)
pass_nested :: proc(p: ^Pass) -> bool {
	if p.r.pass_count == 0 {return true}
	stage_run(p, .Mask)
	return nested_targets(p) && nested_views_record(p)
}

// What the view sees of the world through a nested view: its frustum carried
// by the transform of the nested view, behind its clip plane.
@(private)
nested_frustum :: proc(frustum: [6]Vec4, nested: ^Nested_View) -> (carried: [6]Vec4) {
	inverse := linalg.inverse(nested.to_world)
	for plane, i in frustum {carried[i] = plane_carried(plane, inverse)}
	if length := linalg.length(nested.clip_plane.xyz); length > 1e-8 {carried[5] = nested.clip_plane / length}
	return
}

// The reflectance and the layers targets the nested views need besides
// those of the view, known once the Mask stage added them. A view whose
// G-buffer was drawn without its reflectance target gets it, with what its
// own pixels reflect, and its constants say from then on that the G-buffer
// keeps it: every pass that reads it comes after.
@(private)
nested_targets :: proc(p: ^Pass) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	if p.nested_count == 0 || p.layered {return true}
	reflectance, layered := p.reflectance, false
	for &nested in p.nested[:p.nested_count] {
		seen, seen_layered := reflectance_in_frustum(r, nested_frustum(p.frame.frustum, &nested))
		reflectance ||= seen
		layered ||= seen_layered
		if layered {break}
	}
	if layered {
		if !ensure_layers_target(r, t) {return false}
		p.layered = true
	}
	if !reflectance || p.reflectance {return true}
	if !ensure_surface_target(r, t) {return false}
	rhi.cmd_timestamp(cmd, "nested view reflectance")
	rhi.cmd_barrier_texture(cmd, t.albedo, .Shader_Read)
	fill := rhi.Render_Pass_Desc{color_count = 1, name = "reflectance of the view"}
	fill.colors[0] = {texture = t.surface, load = .Dont_Care, store = .Store}
	rhi.cmd_begin_render_pass(cmd, &fill)
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Nested_Reflectance])
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.albedo)
	rhi.cmd_draw(cmd, 3)
	rhi.cmd_end_render_pass(cmd)
	p.reflectance = true
	p.frame.flags |= FRAME_FLAG_REFLECTANCE
	(^Gpu_Frame)(p.constants.ptr).flags = p.frame.flags
	return true
}

// The G-buffers of the nested views an extension added in the Mask stage.
// Each one is drawn from its own camera into the targets of the view, with a
// depth buffer that lets through the pixels its mask gave it and no other.
@(private)
nested_views_record :: proc(p: ^Pass) -> bool {
	if p.nested_count == 0 {return true}
	r, cmd, t := p.r, p.cmd, p.t
	d := r.device
	s := &r.scene
	if !target(r, nil, &t.nested_depth, t.width, t.height, .D32_Float, {.Depth_Target}, "nested view depth") {return false}
	rhi.cmd_timestamp(cmd, "nested views")
	for &nested, at in p.nested[:p.nested_count] {
		index := u32(at + 1)
		inverse := linalg.inverse(nested.to_world)
		inverse_previous := linalg.inverse(nested.previous)
		f := p.frame
		// The matrices take a point from the eye, which the transform carries with the camera.
		turn, turn_previous := matrix_from_eye(inverse), matrix_from_eye(inverse_previous)
		f.view = f.view * turn
		f.view_proj = f.view_proj * turn
		f.view_proj_unjittered = f.view_proj_unjittered * turn
		f.inv_view_proj = matrix_from_eye(nested.to_world) * f.inv_view_proj
		f.prev_view_proj = f.prev_view_proj * turn_previous
		prev_eye := point_carried(nested.previous, f.prev_eye.xyz)
		f.prev_eye = {prev_eye.x, prev_eye.y, prev_eye.z, 0}
		position := point_carried(nested.to_world, f.camera_position.xyz)
		forward := vector_carried(nested.to_world, f.camera_forward.xyz)
		f.camera_position = {position.x, position.y, position.z, f.camera_position.w}
		f.camera_forward = {forward.x, forward.y, forward.z, f.camera_forward.w}
		f.frustum = nested_frustum(p.frame.frustum, &nested)
		for row in ([]^Vec4{&f.eye_du, &f.eye_dv, &f.ray_origin, &f.ray_du, &f.ray_dv}) {
			v := vector_carried(nested.to_world, row.xyz)
			row^ = {v.x, v.y, v.z, 0}
		}
		origin := point_carried(nested.to_world, f.eye_origin.xyz)
		f.eye_origin = {origin.x, origin.y, origin.z, 0}
		eye := point_carried(nested.to_world, f.eye.xyz) if f.eye.w > 0.5 else vector_carried(nested.to_world, f.eye.xyz)
		f.eye = {eye.x, eye.y, eye.z, f.eye.w}
		f.depth_plane = plane_carried(f.depth_plane, inverse)
		f.prev_depth_plane = plane_carried(f.prev_depth_plane, inverse_previous)
		f.clip_plane = nested.clip_plane
		f.layers = nested.layers & LAYERS_ALL if nested.layers & LAYERS_ALL != 0 else LAYERS_ALL
		// A mirror or a portal shows the body its view hides.
		f.own = 0
		f.view_index = index
		constants := rhi.frame_alloc(d, u64(r.frame_layout.size), 256)
		if constants.ptr == nil {set_error(r, "nested view constants: %s", rhi.device_error(d)); return false}
		mem.copy(constants.ptr, p.constants.ptr, r.frame_layout.size)
		mem.copy(constants.ptr, &f, size_of(Gpu_Frame))
		frame_exposure_copy(p, constants)
		rhi.cmd_bind_transient(cmd, SLOT_FRAME, constants)

		// What the nested camera sees, without the pyramid of the view: its depths are of another camera.
		if !cull_reset(r, cmd) {return false}
		cull_record(p, {phase = 0, hiz_levels = t.hiz_levels}, t.hiz[p.previous], r.scratch_buffer, r.scratch_buffer)
		cull_programs_bin(p, 0)

		// Its pixels alone pass the depth test of its draws: the farthest depth where the mask named it, the nearest elsewhere.
		rhi.cmd_barrier_texture(cmd, t.motion, .Shader_Read)
		prime := rhi.Render_Pass_Desc{name = "nested view pixels"}
		prime.depth = {texture = t.nested_depth, load = .Clear, store = .Store, clear = 1}
		rhi.cmd_begin_render_pass(cmd, &prime)
		Prime_Params :: struct {index, pad0, pad1, pad2: u32}
		prime_params := Prime_Params{index = index}
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Nested_Prime])
		set_params(cmd, &prime_params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.motion)
		if nested.rect.z > 0 && nested.rect.w > 0 {
			x, y := clamp(nested.rect.x, 0, i32(t.width)), clamp(nested.rect.y, 0, i32(t.height))
			rhi.cmd_set_scissor(cmd, x, y, u32(clamp(nested.rect.z, 0, i32(t.width) - x)), u32(clamp(nested.rect.w, 0, i32(t.height) - y)))
		}
		rhi.cmd_draw(cmd, 3)
		rhi.cmd_end_render_pass(cmd)

		rhi.cmd_barrier_buffer(cmd, s.cull_state_buffer, .Indirect_Read)
		if program_clusters(r) {rhi.cmd_barrier_buffer(cmd, s.program_bins, .Indirect_Read)}
		for b in ([]rhi.Buffer{s.instance_buffer, s.vertex_buffer, s.index_buffer, s.material_buffer, s.visible_buffer, s.program_visible}) {rhi.cmd_barrier_buffer(cmd, b, .Shader_Read)}
		targets, count := gbuffer_targets(p)
		pass := rhi.Render_Pass_Desc{color_count = count, name = "nested view gbuffer"}
		for texture, i in targets[:count] {pass.colors[i] = {texture = texture, load = .Load, store = .Store}}
		pass.depth = {texture = t.nested_depth, load = .Load, store = .Dont_Care}
		rhi.cmd_begin_render_pass(cmd, &pass)
		if p.draw {
			target := &r.pipelines[.Gbuffer_Nested_Layers if p.layered else .Gbuffer_Nested if p.reflectance else .Gbuffer_Nested_Plain]
			rhi.cmd_bind_pipeline(cmd, target^)
			rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.visible_buffer)
			rhi.cmd_draw_indirect(cmd, s.cull_state_buffer, u64(offset_of(Gpu_Cull_State, draws)), 1, size_of(Gpu_Draw))
			gbuffer_programs_draw(p, target, 0)
		}
		rhi.cmd_end_render_pass(cmd)
	}
	bind_scene_table(p)
	return true
}

// Shadow rays at a hit of a ray of the probe volume: what it gathers is
// blurred over many rays and probes.
PROBE_LIGHT_BUDGET :: u32(4)

// The list of the pixels whose direct light traces rays of its own
// (DIRECT_TRACED_* in lighting.slang), room for every pixel of the view, and
// the dispatch over them, which starts each frame as a copy of dispatch_start.
DIRECT_TRACED_FIRST :: u32(1)
DIRECT_TRACED_GROUP :: u32(64)
@(private)
ensure_direct_list :: proc(r: ^Renderer, t: ^Targets) -> bool {
	if t.direct_traced != 0 {return true}
	t.direct_traced = rhi.buffer_create(r.device, {size = u64(DIRECT_TRACED_FIRST + t.width * t.height) * 4, usage = {.Storage}, name = "direct traced pixels"})
	t.direct_dispatch = rhi.buffer_create(r.device, {size = 16, usage = {.Storage, .Indirect}, name = "direct traced dispatch"})
	if t.direct_traced == 0 || t.direct_dispatch == 0 {set_error(r, "direct traced pixels: %s", rhi.device_error(r.device)); return false}
	return true
}

// A set of soft shadows: the rays of its blocks, their history and the filter
// of their penumbras, which leaves the share of light of each block in set.raw.
@(private)
pass_shadow_set :: proc(p: ^Pass, set: ^Shadow_Set) {
	r, cmd, t := p.r, p.cmd, p.t
	settings := &r.settings
	current, previous := p.current, p.previous
	rhi.cmd_timestamp(cmd, "shadow trace")
	{
		Params :: struct {light_budget: u32, sun_radius: f32, block, resume: u32}
		params := Params{light_budget = settings.light_budget, sun_radius = settings.sun_radius, block = set.block}
		// The filters of glass with a program wait for it.
		batch := shadows_colored(r) && points_begin(p, filters = true)
		pipeline := shadow_pipeline(r, .Shadow_Trace, .Shadow_Trace_Hw, .Shadow_Trace_Color, .Shadow_Trace_Color_Hw)
		rhi.cmd_bind_pipeline(cmd, pipeline)
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, set.raw)
		rhi.cmd_bind_texture(cmd, SLOT_PASS3, set.geometry[current])
		rhi.cmd_bind_texture(cmd, SLOT_PASS4, set.light)
		points_bind(p)
		rhi.cmd_dispatch(cmd, groups(set.width, 8), groups(set.height, 8))
		points_rounds(p, batch, pipeline, &params, 1)
	}
	rhi.cmd_timestamp(cmd, "shadow filter")
	{
		Params :: struct {max_history, history_valid, still_history: f32, block: u32}
		params := Params{max_history = SHADOW_HISTORY_FRAMES, history_valid = 1 if set.valid else 0, still_history = SHADOW_HISTORY_STILL_FRAMES, block = set.block}
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Shadow_Temporal])
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, set.raw)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, set.geometry[current])
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, set.geometry[previous])
		rhi.cmd_bind_texture(cmd, SLOT_PASS3, set.history[previous])
		rhi.cmd_bind_texture(cmd, SLOT_PASS4, set.widths[previous])
		rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.motion)
		rhi.cmd_bind_texture(cmd, SLOT_PASS6, t.normal)
		rhi.cmd_bind_texture(cmd, SLOT_PASS7, t.linear_depth)
		rhi.cmd_bind_texture(cmd, SLOT_PASS8, set.history[current])
		rhi.cmd_bind_texture(cmd, SLOT_PASS9, set.widths[current])
		rhi.cmd_dispatch(cmd, groups(set.width, 8), groups(set.height, 8))
	}
	// The widths along x, then y; the share along x, then y, into the texture the rays of the frame no longer need.
	sources := [4]rhi.Texture{set.widths[current], set.filter[0], set.history[current], set.filter[0]}
	targets := [4]rhi.Texture{set.filter[0], set.filter[1], set.filter[0], set.raw}
	for step in 0 ..< 4 {
		Params :: struct {step, block, pad0, pad1: u32}
		params := Params{step = u32(step), block = set.block}
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Shadow_Penumbra])
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, sources[step])
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, set.geometry[current])
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, set.filter[1] if step >= 2 else r.dummy_texture)
		rhi.cmd_bind_texture(cmd, SLOT_PASS3, targets[step])
		rhi.cmd_bind_texture(cmd, SLOT_PASS4, set.light if step == 0 else r.dummy_texture)
		rhi.cmd_dispatch(cmd, groups(set.width, 8), groups(set.height, 8))
	}
	set.valid = true
}

// The direct light of each pixel: the sun and the local lights, with their shadows.
@(private)
pass_direct :: proc(p: ^Pass, mode: Direct_Mode) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	settings := &r.settings
	current := p.current
	// The share of light of each 2x2 block, with the penumbra its casters ask for.
	shadow_share := r.dummy_texture
	blocks := mode == .Blocks && !settings.reference_lights
	if blocks {
		if !ensure_shadow_targets(r, cmd, t, &t.shadow, 2) {return false}
		pass_shadow_set(p, &t.shadow)
		shadow_share = t.shadow.raw
	} else {
		t.shadow.valid = false
	}
	rhi.cmd_timestamp(cmd, "direct")
	if blocks {
		if !ensure_direct_list(r, t) {return false}
		rhi.cmd_fill_buffer(cmd, t.direct_traced, 0, 4, 0)
		rhi.cmd_copy_buffer(cmd, r.dispatch_start, 0, t.direct_dispatch, 0, 16)
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Lighting if p.layered else .Lighting_Unlayered])
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.direct)
		rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.albedo)
		rhi.cmd_bind_texture(cmd, SLOT_PASS4, shadow_share)
		rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.shadow.geometry[current])
		rhi.cmd_bind_texture(cmd, SLOT_PASS6, t.shadow.filter[1])
		rhi.cmd_bind_buffer(cmd, SLOT_PASS7, t.direct_traced)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS8, t.direct_dispatch)
		rhi.cmd_dispatch(cmd, groups(t.width, 8), groups(t.height, 8))
	}
	// The pixels that trace their own rays: those of the list, or without
	// blocks every pixel.
	rhi.cmd_timestamp(cmd, "direct rays")
	{
		Params :: struct {light_budget, listed, reference: u32, sun_radius: f32, resume, pad0, pad1, pad2: u32}
		params := Params{light_budget = settings.light_budget, listed = u32(blocks), reference = u32(settings.reference_lights), sun_radius = settings.sun_radius}
		batch := shadows_colored(r) && points_begin(p, filters = true)
		pipeline := shadow_pipeline(r, .Lighting_Traced, .Lighting_Traced_Hw, .Lighting_Traced_Color, .Lighting_Traced_Color_Hw)
		rhi.cmd_bind_pipeline(cmd, pipeline)
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.direct)
		rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.albedo)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS4, t.direct_traced if blocks else r.dummy_buffer)
		points_bind(p)
		if blocks {
			rhi.cmd_dispatch_indirect(cmd, t.direct_dispatch, 0)
		} else {
			rhi.cmd_dispatch(cmd, groups(t.width * t.height, DIRECT_TRACED_GROUP))
		}
		points_rounds(p, batch, pipeline, &params, 1)
	}
	return true
}

@(private)
pass_reflections :: proc(p: ^Pass) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	if !p.use_reflections {
		t.reflect_valid = false
		return true
	}
	if !ensure_reflect_targets(r, cmd, t) {return false}
	rhi.cmd_timestamp(cmd, "reflect")
	reflect_pass(p, t.normal, t.linear_depth, t.albedo, t.reflect_history[p.previous], t.reflect_history[p.current], t.reflect_valid, p.reflectance, REFLECTION_SHARED_ROUGHNESS)
	p.reflections = t.reflect_history[p.current]
	t.reflect_valid = true
	return true
}

// Updates of the probe volume in the frame that shows a world anew
// (Renderer.gi_warm), each a bounce more: the light it shows from its first
// frame instead of over seconds.
GI_WARM_UPDATES :: 64

// What lights the world whatever the view: the probe volume. Once a frame,
// with its first view; several times in the frame of a world shown anew, and
// over GI_BLACKOUT_FRAMES after a blackout.
@(private)
pass_world_lighting :: proc(p: ^Pass) -> bool {
	r, cmd := p.r, p.cmd
	g := &r.ddgi
	changes := &r.scene.changes
	if p.first && !p.offscreen && p.use_gi {
		if changes.count > 0 && !changes.all && !upload_transient(r, cmd, changes.spheres[:changes.count], r.light_changes) {return false}
		updates := 1
		if r.gi_warm {updates = GI_WARM_UPDATES}
		r.gi_warm = false
		// A blackout spreads the warm updates over its frames; only the last
		// update of the last frame keeps its history.
		spread := r.gi_warm_spread
		if spread > 0 && updates == 1 {
			updates = int((GI_BLACKOUT_UPDATES + GI_BLACKOUT_FRAMES - 1) / GI_BLACKOUT_FRAMES)
			r.gi_warm_spread -= 1
		}
		for update in 0 ..< updates {
			warm := update < updates - 1 || (spread > 1 && updates > 1)
			if p.use_probes && g.valid {
				rhi.cmd_timestamp(cmd, "ddgi")
				if !ddgi_update(p, warm) {return false}
			}
			r.light_frame += 1
		}
	}
	if p.use_probes && p.first && !p.offscreen {
		// Later passes sample the updated atlases through the scene table.
		rhi.cmd_bind_texture(cmd, SLOT_IRRADIANCE, g.irradiance)
		rhi.cmd_bind_texture(cmd, SLOT_DISTANCE, g.distance)
	}
	if p.first && !p.offscreen {
		r.frame_changes = changes^
		changes^ = {}
	}
	return true
}

// The light around each pixel beside the probe volume, which the composition
// reads at each pixel: its contact occlusion, or with Settings.reference_gi the
// reference in place of the volume.
@(private)
pass_indirect :: proc(p: ^Pass) -> bool {
	if !p.use_gi {
		p.gi = p.r.dummy_texture
		return true
	}
	if p.r.settings.reference_gi {return pass_gi_reference(p)}
	return pass_contact(p)
}

// The contact occlusion of the probe volume (contact.comp): the composition
// takes it in p.gi.
// Rays of each pixel. Must match CONTACT_SAMPLES of contact.comp.
CONTACT_RAYS :: u64(8)
@(private)
pass_contact :: proc(p: ^Pass) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	ok := target(r, cmd, &t.contact[0], t.width, t.height, .R16_Float, HISTORY_USAGE, "contact", true)
	ok &&= target(r, cmd, &t.contact[1], t.width, t.height, .R16_Float, HISTORY_USAGE, "contact blurred", true)
	if !ok {return false}
	rhi.cmd_timestamp(cmd, "contact")
	Params :: struct {mode, pad0, pad1, pad2: u32}
	for mode in u32(0) ..< 2 {
		params := Params{mode = mode}
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Contact_Hw] if mode == 0 && r.hardware_rt else r.pipelines[.Contact])
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.contact[0] if mode == 1 else texture_or_dummy(r, 0))
		rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.contact[mode])
		rhi.cmd_dispatch(cmd, groups(t.width, 8), groups(t.height, 8))
	}
	p.gi = t.contact[1]
	return true
}

// Paths of each pixel in a frame of Settings.reference_gi, and the most
// surfaces each meets.
GI_REFERENCE_PATHS :: u32(4)
GI_REFERENCE_BOUNCES :: u32(32)

// Settings.reference_gi in place of the probe volume: paths from every pixel,
// averaged over the frames since the scene or the camera last changed.
@(private)
pass_gi_reference :: proc(p: ^Pass) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	if !ensure_pipelines(r, {.Gi_Reference, .Gi_Reference_Hw}) {return false}
	if !target(r, cmd, &t.gi_reference, t.width, t.height, .RGBA32_Float, HISTORY_USAGE, "gi reference", true) {return false}
	restart := !t.gi_reference_valid || r.scene_uploads_change || t.gi_reference_view != p.frame.view_proj_unjittered || t.gi_reference_eye != p.camera.position
	t.gi_reference_view, t.gi_reference_eye = p.frame.view_proj_unjittered, p.camera.position
	rhi.cmd_timestamp(cmd, "gi reference")
	Params :: struct {paths, bounces, reset: u32, sun_radius: f32, resume, pad0, pad1, pad2: u32}
	params := Params{paths = GI_REFERENCE_PATHS, bounces = GI_REFERENCE_BOUNCES, reset = u32(restart), sun_radius = r.settings.sun_radius}
	batch := points_begin(p)
	pipeline := r.pipelines[.Gi_Reference_Hw] if r.hardware_rt else r.pipelines[.Gi_Reference]
	rhi.cmd_bind_pipeline(cmd, pipeline)
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.gi_reference)
	points_bind(p)
	rhi.cmd_dispatch(cmd, groups(t.width, 8), groups(t.height, 8))
	// A pixel goes on from each surface with a program its paths meet: a round for each, at most.
	points_rounds(p, batch, pipeline, &params, int(GI_REFERENCE_PATHS * GI_REFERENCE_BOUNCES))
	p.gi = t.gi_reference
	t.gi_reference_valid = true
	return true
}

// The lit image of the opaque scene, in t.hdr and t.display, where the mode
// of inspection of the view replaces it.
@(private)
pass_composite :: proc(p: ^Pass) {
	r, cmd, t := p.r, p.cmd, p.t
	rhi.cmd_timestamp(cmd, "composite")
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Composite if p.layered else .Composite_Unlayered])
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.albedo)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.emission)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS4, t.direct)
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, p.gi)
	// Without an atmosphere the composite reads no aerial perspective: any volume stands for it.
	rhi.cmd_bind_texture(cmd, SLOT_PASS6, t.aerial if t.aerial != 0 else r.display_lut)
	rhi.cmd_bind_texture(cmd, SLOT_PASS7, texture_or_dummy(r, p.reflections))
	rhi.cmd_bind_texture(cmd, SLOT_PASS8, t.hdr[p.current])
	rhi.cmd_bind_texture(cmd, SLOT_PASS9, t.display)
	rhi.cmd_dispatch(cmd, groups(t.width, 8), groups(t.height, 8))
	p.shown = t.display
	debug_views_pass(p)
	if p.inspection.record != nil {stage_inspect(p)}
}

// The Lit stage of extensions over the lit opaque scene. With glass in view
// the layers of glass are drawn first, and the stage runs on each side of the
// nearest one as Blend does: behind it here, before the glass reads what it
// has behind, and in front of it over the lit glass (pass_transparent).
@(private)
lit_run :: proc(p: ^Pass) {
	if !p.draw_translucent || !stage_asked(p.r, .Lit) {
		stage_run(p, .Lit)
		return
	}
	glass_layers(p)
	p.glass_layered = true
	side_run(p, .Lit, .Behind)
}

// What is drawn over the lit opaque scene: overlays, glass and the Blend
// stage of extensions. What is blended behind the nearest glass layer is
// there before the glass reads the scene; the rest goes over it, after the
// Lit stage in front of the glass and what the solid the camera is in takes.
@(private)
pass_transparent :: proc(p: ^Pass) {
	if p.draw_overlays {overlay_pass(p)}
	if p.draw_translucent {
		if !p.glass_layered {glass_layers(p)}
		if p.blend {side_run(p, .Blend, .Behind)}
		glass_shade(p, p.use_reflections)
		if p.glass_layered {side_run(p, .Lit, .Front)}
		glass_inside(p)
		if p.blend {side_run(p, .Blend, .Front)}
	} else {
		p.t.glass_valid = false
		if p.blend {side_run(p, .Blend, .All)}
	}
	// Without a Blend pass the mask of the frame is zero, as a pass that replaces the Resolve stage reads it.
	if p.blended {p.t.reactive_drawn = true} else if p.t.reactive_drawn {
		clear_textures(p.cmd, p.t.reactive)
		p.t.reactive_drawn = false
	}
}

@(private)
side_run :: proc(p: ^Pass, stage: Frame_Stage, side: Glass_Side) {
	p.glass = side
	stage_run(p, stage)
	p.glass = .All
}

// The Simulate stage of extensions, with the first view of the window: what
// it traces and reads of the scene went up in this frame.
@(private)
simulate_run :: proc(p: ^Pass) {
	r, cmd := p.r, p.cmd
	s, g := &r.scene, &r.ddgi
	for b in ([]rhi.Buffer{s.instance_buffer, s.mesh_buffer, s.vertex_buffer, s.index_buffer, s.material_buffer, s.light_buffer, s.light_tree_buffer, s.blas_node_buffer, s.blas_triangle_buffer, s.tlas_node_buffer, s.tlas_ref_buffer, g.probes if g.valid else r.dummy_buffer}) {if b != 0 {rhi.cmd_barrier_buffer(cmd, b, .Shader_Read)}}
	if r.hardware_rt && s.tlas != 0 {rhi.cmd_barrier_accel(cmd, s.tlas)}
	rhi.cmd_barrier_texture(cmd, p.t.linear_depth, .Shader_Read)
	rhi.cmd_barrier_texture(cmd, p.t.normal, .Shader_Read)
	stage_run(p, .Simulate)
	if s.light_region.lights > 0 {
		rhi.cmd_barrier_buffer(cmd, s.light_buffer, .Shader_Read)
		rhi.cmd_barrier_buffer(cmd, s.light_tree_buffer, .Shader_Read)
	}
}

// Temporal anti-aliasing and upscaling to the size the view is shown at.
@(private)
pass_taa :: proc(p: ^Pass) {
	r, cmd, t := p.r, p.cmd, p.t
	if !r.settings.taa {
		t.taa_valid = false
		return
	}
	rhi.cmd_timestamp(cmd, "taa")
	Params :: struct {history_valid, feedback, clip_gamma, reactive, shadows: f32, pad: [3]f32}
	params := Params{history_valid = 1 if t.taa_valid else 0, feedback = 0.1, clip_gamma = 1.25, reactive = 1 if p.blended else 0, shadows = 1 if t.shadow.valid else 0}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Taa])
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, p.shown)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.motion)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.taa[p.previous])
	rhi.cmd_bind_texture(cmd, SLOT_PASS4, t.taa[p.current])
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.reactive)
	rhi.cmd_bind_texture(cmd, SLOT_PASS6, t.taa_frames[p.previous])
	rhi.cmd_bind_texture(cmd, SLOT_PASS7, t.taa_frames[p.current])
	rhi.cmd_bind_texture(cmd, SLOT_PASS8, t.shadow.widths[p.current] if t.shadow.valid else r.dummy_texture)
	rhi.cmd_dispatch(cmd, groups(t.output_width, 8), groups(t.output_height, 8))
	p.shown = t.taa[p.current]
	t.taa_valid = true
}

// The image of the view in t.ldr: the effects of the stack over the last image
// a pass wrote (Pass.shown), the tonemap, the outline of the highlighted
// instances and what is drawn over the finished image (the panels of the
// scene, the debug lines and the layers of the screen, in that order).
@(private)
// overlays: false leaves t.ldr without what is drawn over it, for the passes
// that generate a frame; overlays_pass draws it after them.
pass_output :: proc(p: ^Pass, frame: Frame_Desc, ui_written: ^int, overlays := true) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	depth_probes_record(p)
	if p.first && !p.texture {effect_views_record(p, frame.effect_views)}
	if !pass_exposure(p) {return false}
	if r.pass_count > 0 && !view_inspected(p.inspection) {stage_run(p, .Post)}
	p.shown = postprocess_passes(p, p.shown, false)
	points := Vec2{f32(t.output_width), f32(t.output_height)} / ui_scale(r)
	highlight_bounds := Vec4{1, 1, 0, 0}
	outline := highlight_drawn_in(p) && highlight_outlined(r)
	glow := max(r.highlight.width, r.outlines.width)
	if s.highlighted > 0 && !p.texture {highlight_bounds = highlight_screen_bounds(s.instances[:], p.unjittered, p.camera.position, points, {f32(t.highlight_width), f32(t.highlight_height)}, glow)}
	if outline {
		rhi.cmd_timestamp(cmd, "highlight filter")
		highlight_filter_pass(p, points, highlight_bounds)
	}
	if p.first && r.preview_count > 0 && !p.texture {
		rhi.cmd_timestamp(cmd, "previews")
		previews_pass(r, cmd, p.slot)
		bind_scene_table(p)
	}
	rhi.cmd_timestamp(cmd, "tonemap ui")
	coat := texture_or_dummy(r, t.highlight_filtered)
	rhi.cmd_barrier_texture(cmd, p.shown, .Shader_Read)
	rhi.cmd_barrier_texture(cmd, coat, .Shader_Read)
	rhi.cmd_barrier_texture(cmd, r.font, .Shader_Read)
	thumbnails := r.thumbnails if r.thumbnails != 0 else r.dummy_texture
	rhi.cmd_barrier_texture(cmd, thumbnails, .Shader_Read)
	rhi.cmd_barrier_buffer(cmd, p.view.exposure, .Shader_Read)
	if len(frame.panels) > 0 || len(frame.debug) > 0 {
		rhi.cmd_barrier_texture(cmd, t.linear_depth, .Shader_Read)
		rhi.cmd_barrier_texture(cmd, t.motion, .Shader_Read)
	}
	ldr_pass := rhi.Render_Pass_Desc{color_count = 1, name = "tonemap"}
	ldr_pass.colors[0] = {texture = t.ldr, load = .Dont_Care, store = .Store}
	rhi.cmd_begin_render_pass(cmd, &ldr_pass)
	// One premultiplied editor coat sample per drawable pixel after TAA.
	tonemap := Tonemap_Params{outline = {1 if outline else 0, glow, points.x, points.y}, bounds = highlight_bounds}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Tonemap])
	set_params(cmd, &tonemap)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, p.shown)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, coat)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.linear_depth)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS3, p.view.exposure)
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, r.display_lut)
	rhi.cmd_draw(cmd, 3)
	// The UI goes in the pass of the tonemap, unless effects of the stack come between them.
	open := true
	if postprocess_active(p, true) && postprocess_limit(p.inspection, true) > 0 {
		rhi.cmd_end_render_pass(cmd)
		processed := postprocess_passes(p, t.ldr, true)
		if processed != t.ldr {
			rhi.cmd_timestamp(cmd, "postprocess copy")
			rhi.cmd_barrier_texture(cmd, processed, .Shader_Read)
			pass := rhi.Render_Pass_Desc{color_count = 1, name = "postprocess copy"}
			pass.colors[0] = {texture = t.ldr, load = .Dont_Care, store = .Store}
			rhi.cmd_begin_render_pass(cmd, &pass)
			rhi.cmd_bind_pipeline(cmd, r.pipelines[.Postprocess_Copy])
			params := [4]u32{}
			set_params(cmd, &params)
			rhi.cmd_bind_texture(cmd, SLOT_PASS0, processed)
			rhi.cmd_draw(cmd, 3)
			rhi.cmd_end_render_pass(cmd)
		}
		open = overlays && !p.texture
		if open {
			rhi.cmd_timestamp(cmd, "ui")
			ldr_pass.colors[0].load = .Load
			ldr_pass.name = "editor UI"
			rhi.cmd_begin_render_pass(cmd, &ldr_pass)
		}
	}
	if !p.texture && overlays {overlays_draw(p, frame, ui_written, points, thumbnails)}
	if open {rhi.cmd_end_render_pass(cmd)}
	if p.wide != .None && p.view.wide != 0 {
		// The same tonemap again into the wide image, as the view asked for it.
		rhi.cmd_timestamp(cmd, "tonemap wide")
		wide_pass := rhi.Render_Pass_Desc{color_count = 1, name = "tonemap wide"}
		wide_pass.colors[0] = {texture = p.view.wide, load = .Dont_Care, store = .Store}
		rhi.cmd_begin_render_pass(cmd, &wide_pass)
		wide := Tonemap_Params{bounds = {1, 1, 0, 0}, wide = {f32(p.wide), 0, 0, 0}}
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Tonemap_Wide])
		set_params(cmd, &wide)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, p.shown)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, coat)
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.linear_depth)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS3, p.view.exposure)
		rhi.cmd_bind_texture(cmd, SLOT_PASS5, r.display_lut)
		rhi.cmd_draw(cmd, 3)
		rhi.cmd_end_render_pass(cmd)
	}
	return true
}

// What is drawn over the finished image of a view: the panels of the scene,
// the debug lines and the layers of the screen, in that order. In the open
// pass of the target.
@(private)
overlays_draw :: proc(p: ^Pass, frame: Frame_Desc, ui_written: ^int, points: Vec2, thumbnails: rhi.Texture) {
	world_panels_pass(p.r, p.cmd, p.t, p.slot, ui_written, frame.panels, p.view_matrix, thumbnails, p.index)
	debug_lines_pass(p.r, p.cmd, p.t, p.slot, frame.debug)
	ui_layers_pass(p.r, p.cmd, ui_surface_of(p.t), p.slot, ui_written, frame.ui, points, ui_scale(p.r), thumbnails)
}

// The overlays of a view that generated a frame, over its image and, while
// the generated one is shown, over that too: the same in both.
@(private)
overlays_pass :: proc(p: ^Pass, frame: Frame_Desc, ui_written: ^int, generated: bool) {
	r, cmd, t := p.r, p.cmd, p.t
	thumbnails := r.thumbnails if r.thumbnails != 0 else r.dummy_texture
	points := Vec2{f32(t.output_width), f32(t.output_height)} / ui_scale(r)
	for image in 0 ..< (2 if generated else 1) {
		rhi.cmd_barrier_texture(cmd, r.font, .Shader_Read)
		rhi.cmd_barrier_texture(cmd, thumbnails, .Shader_Read)
		if len(frame.panels) > 0 || len(frame.debug) > 0 {
			rhi.cmd_barrier_texture(cmd, t.linear_depth, .Shader_Read)
			rhi.cmd_barrier_texture(cmd, t.motion, .Shader_Read)
		}
		// The passes of the UI draw into t.ldr: over the generated image, it takes its place.
		if image == 1 {t.ldr, t.generated = t.generated, t.ldr}
		rhi.cmd_timestamp(cmd, "ui" if image == 0 else "generated ui")
		pass := rhi.Render_Pass_Desc{color_count = 1, name = "editor UI" if image == 0 else "generated UI"}
		pass.colors[0] = {texture = t.ldr, load = .Load, store = .Store}
		rhi.cmd_begin_render_pass(cmd, &pass)
		overlays_draw(p, frame, ui_written, points, thumbnails)
		rhi.cmd_end_render_pass(cmd)
		if image == 1 {t.ldr, t.generated = t.generated, t.ldr}
	}
}

@(private)
update_stats :: proc(r: ^Renderer) {
	info := rhi.device_info(r.device)
	s := &r.stats
	t := &r.main.targets
	s.frame = r.frame
	s.backend = info.backend
	s.device_name = info.name
	s.device_type = info.type
	s.hardware_rt = r.hardware_rt
	s.render_width = t.width
	s.render_height = t.height
	s.instances = u32(len(r.scene.instances))
	s.tlas_instances = u32(len(r.scene.hw_instances) + r.scene.batch.hw_count) if r.hardware_rt else u32(len(r.scene.tlas_refs))
	s.meshes = u32(len(r.scene.meshes))
	s.triangles = r.scene.triangle_total
	s.materials = u32(len(r.scene.materials))
	s.textures = u32(r.textures.count)
	s.texture_bytes = r.textures.bytes
	s.geometry_bytes = geometry_pool_bytes(r)
	s.geometry_free, s.geometry_free_largest = geometry_pool_free(&r.scene)
	s.ray_bytes, _ = rhi.accel_memory(r.device)
	s.textures_reduced = u32(r.textures.reduced + r.textures.residency.reduced)
	s.textures_pending = u32(r.textures.residency.pending)
	s.lights = u32(len(r.scene.lights))
	pages_stats(r, s)
	geometry := geometry_refused_problem(r, r.problem_buffer[:])
	s.problem = geometry
	for other in ([]string{r.tlas_problem, pages_problem(r)}) {
		if other == "" {continue}
		if s.problem == "" {s.problem = other; continue}
		// The problems before are at the start of problem_buffer: this one follows them.
		if raw_data(s.problem) != raw_data(r.problem_buffer[:]) {s.problem = string(r.problem_buffer[:copy(r.problem_buffer[:], s.problem)])}
		tail := fmt.bprintf(r.problem_buffer[len(s.problem):], "; %s", other)
		s.problem = string(r.problem_buffer[:len(s.problem) + len(tail)])
	}
	s.probes = r.ddgi.total if r.ddgi.valid else 0
	s.probes_per_frame = r.ddgi.budget if r.ddgi.valid else 0
	pixels := u64(t.width) * u64(t.height)
	// A block of 2x2 pixels traces a ray to the sun and one to each light or
	// group of its cut; the reference, every pixel to sixteen points of each light.
	rays := u64(t.half_width) * u64(t.half_height) * u64(1 + min(s.lights, r.settings.light_budget))
	if r.settings.reference_lights {rays = pixels * (1 + 16 * u64(s.lights))}
	if r.settings.gi_enabled {
		// A probe ray traces the sun and the lights of its cut where it hits.
		rays += u64(s.probes_traced) * u64(r.ddgi.rays_per_probe) * u64(2 + min(s.lights, PROBE_LIGHT_BUDGET))
		// The contact occlusion: CONTACT_RAYS short rays of each pixel.
		rays += pixels * CONTACT_RAYS
	}
	if r.settings.reflections && r.scene.smoothest < r.settings.reflection_roughness {
		// A pixel traces its own ray or takes its turn for its block, never both.
		blocks_only := r.settings.reflection_half_resolution && r.scene.smoothest >= REFLECTION_SHARED_ROUGHNESS
		rays += u64(t.half_width) * u64(t.half_height) if blocks_only else pixels
	}
	s.rays_per_frame = rays
}

renderer_stats :: proc(r: ^Renderer) -> ^Stats {return &r.stats}

// Stats with the counters of the last frame, which it reads back by the time
// a later frame needs its slot: for whoever has just read an image of that
// frame (renderer_capture, view_texture_capture), so the GPU is idle.
renderer_stats_of_last_frame :: proc(r: ^Renderer) -> ^Stats {
	if r.frame > 0 {read_stats(r, int((rhi.frame_number(r.device) + rhi.MAX_FRAMES_IN_FLIGHT - 1) % rhi.MAX_FRAMES_IN_FLIGHT))}
	return &r.stats
}

// Reads back the last presented LDR image (RGBA8, window resolution). Blocks
// until the GPU is idle; call between frames. The caller owns the pixels.
renderer_capture :: proc(r: ^Renderer, allocator := context.allocator) -> (pixels: []u8, width, height: int, ok: bool) {
	if r.frame == 0 {
		set_error(r, "capture: no frame has been drawn")
		return nil, 0, 0, false
	}
	return targets_capture(r, &r.main.targets, allocator)
}

// Reads back the image the window showed before the last presented one, which
// frame generation drew (Stats.generated); false when the last frame drew none.
renderer_capture_generated :: proc(r: ^Renderer, allocator := context.allocator) -> (pixels: []u8, width, height: int, ok: bool) {
	if !r.stats.generated {
		set_error(r, "capture: the last frame generated no image")
		return nil, 0, 0, false
	}
	t := r.main.targets
	t.ldr = t.generated
	return targets_capture(r, &t, allocator)
}

@(private)
targets_capture :: proc(r: ^Renderer, t: ^Targets, allocator: mem.Allocator) -> (pixels: []u8, width, height: int, ok: bool) {
	if t.ldr == 0 {
		set_error(r, "capture: the view has no image yet")
		return nil, 0, 0, false
	}
	width, height = int(t.output_width), int(t.output_height)
	memory: mem.Allocator_Error
	pixels, memory = make([]u8, width * height * 4, allocator)
	if memory != nil {
		set_error(r, "capture: no memory for %dx%d pixels", width, height)
		return nil, 0, 0, false
	}
	if !rhi.texture_read(r.device, t.ldr, pixels) {
		delete(pixels, allocator)
		set_error(r, "capture: %s", rhi.device_error(r.device))
		return nil, 0, 0, false
	}
	return pixels, width, height, true
}
