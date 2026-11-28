package mirai_render

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:time"
import "mirai:rhi"
import mm "mirai:std/math"
import "mirai:render/abi"
import "mirai:std/base"

// Binding slots.
SLOT_FRAME          :: abi.SLOT_FRAME
SLOT_PARAMS         :: abi.SLOT_PARAMS
SLOT_LINEAR_SAMPLER :: abi.SLOT_LINEAR_SAMPLER
SLOT_POINT_SAMPLER  :: abi.SLOT_POINT_SAMPLER
SLOT_INSTANCES      :: abi.SLOT_INSTANCES
SLOT_MESHES         :: abi.SLOT_MESHES
SLOT_VERTICES       :: abi.SLOT_VERTICES
SLOT_INDICES        :: abi.SLOT_INDICES
SLOT_MATERIALS      :: abi.SLOT_MATERIALS
SLOT_LIGHTS         :: abi.SLOT_LIGHTS
SLOT_LIGHT_TREE     :: abi.SLOT_LIGHT_TREE
SLOT_BLAS_NODES     :: abi.SLOT_BLAS_NODES
SLOT_BLAS_TRIANGLES :: abi.SLOT_BLAS_TRIANGLES
SLOT_TLAS_NODES     :: abi.SLOT_TLAS_NODES
SLOT_TLAS_REFS      :: abi.SLOT_TLAS_REFS
SLOT_MATERIAL_SAMPLER :: abi.SLOT_MATERIAL_SAMPLER
SLOT_PROBES         :: abi.SLOT_PROBES
SLOT_IRRADIANCE     :: abi.SLOT_IRRADIANCE
SLOT_POINTS         :: abi.SLOT_POINTS // the material points (points.odin)
SLOT_PASS0          :: abi.SLOT_PASS0
SLOT_PASS1          :: abi.SLOT_PASS1
SLOT_PASS2          :: abi.SLOT_PASS2
SLOT_PASS3          :: abi.SLOT_PASS3
SLOT_PASS4          :: abi.SLOT_PASS4
SLOT_PASS5          :: abi.SLOT_PASS5
SLOT_PASS6          :: abi.SLOT_PASS6
SLOT_PASS7          :: abi.SLOT_PASS7
SLOT_PASS8          :: abi.SLOT_PASS8
SLOT_PASS9          :: abi.SLOT_PASS9
SLOT_TLAS           :: abi.SLOT_TLAS
SLOT_SURFACE        :: abi.SLOT_SURFACE
SLOT_VIEWS          :: abi.SLOT_VIEWS
SLOT_LAYERS         :: abi.SLOT_LAYERS
SLOT_DISTANCE       :: abi.SLOT_DISTANCE
SLOT_SHADOW_TABLE   :: abi.SLOT_SHADOW_TABLE
SLOT_LIGHT_LISTS    :: abi.SLOT_LIGHT_LISTS
SLOT_REST           :: abi.SLOT_REST
SLOT_AERIAL         :: abi.SLOT_AERIAL
SLOT_DIRECT_BLOCKERS :: abi.SLOT_DIRECT_BLOCKERS
// Of a draw of the clusters of an instance (gbuffer.vert): the Surface program
// whose clusters it draws, 0 those without one, GPU_NONE all of them.
SLOT_DRAW           :: abi.SLOT_DRAW

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
	settle_gi: bool, // with offscreen: updates the probe volume of the world shown without presenting
	inspection: View_Inspection,
	wide:      View_Wide, // of a view into a texture: its image is kept wide too
	view_matrix, unjittered: Mat4,
	jitter:    Vec2,
	jitter_phases: u32, // of the sequence the jitter of the view follows; 0: none
	use_gi, use_probes: bool,
	pyramid_previous: bool, // the depth pyramid of the frame before holds what the view drew then (pass_depth_pyramid)
	pyramid:          bool, // that of this frame holds what the view drew of the opaque scene
	reflectance:    bool, // the G-buffer keeps what each pixel reflects
	layered:        bool, // and the layers of its material (gbuffer.slang)
	subsurface:     bool, // an instance with a subsurface is in sight and the view shows the image lit: the subsurface passes run (subsurface.odin)
	decals:         bool, // the scene has decals or an extension asks for the Decal stage: the view draws them and its resolve applies them (decals.odin)
	decal_emission: bool, // and one of them emits: the view has the emission target
	scattered:      bool, // the direct light of the view left the light of its subsurfaces in t.subsurface[0]
	instance_count: u32,
	batch_slots:    u32, // instance slots of the batches drawn, after the instances

	draw, draw_forward, draw_glass, draw_overlays: bool,
	translucent: []Translucent, // visible prefix of the scene list for this view, sorted back to front
	translucent_drawn: bool,    // their indirect draws are written (translucent_draws_record)
	glass_material_layers: bool,
	forward_material_layers: bool, // a forward blend in sight has material layers
	forward_additive: bool,        // a forward blend in sight is additive and writes the reactive target
	glass_rough: bool,          // some visible glass layer may sample blurred mips of scene_copy
	blend:   bool,       // the view runs the Blend stage of extensions
	blended: bool,       // a pass of it drew in reactive (Blend stage, additive forward blends): TAA reads the coverage drawn
	glass:   Glass_Side, // of the Lit or Blend stage being recorded
	distorted: bool,        // the Blend stage of this side drew into the distortion target (pass_distortion_begin)
	distortion_drawn: bool, // and that of some side of this frame
	glass_layered: bool, // the layers of glass were drawn before the Lit stage, which runs on each side of them
	glass_medium: u32, // instance plus one of the solid of glass the camera may be in (glass_layers), 0 none
	glass_medium_row: u32, // the row of the material of its medium
	gi:    rhi.Texture, // the light of the probe volume at each pixel, or what a custom pass writes as Gi
	gathered: bool, // gi holds the light of the probe volume (contact_pixels.comp)
	shown: rhi.Texture, // the image so far: the Display or the Taa a pass last wrote, which the Output stage finishes
	nested:       [NESTED_VIEW_CAPACITY]Nested_View,
	nested_count: int,
	cost:         rhi.Buffer, // the count of a request the view adds to (cost.odin); 0: none
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
	rhi.cmd_bind_texture(cmd, SLOT_VIEWS, p.t.views if p.t.views != 0 else r.dummy_views)
	rhi.cmd_bind_texture(cmd, SLOT_LAYERS, p.t.layers if p.t.layers != 0 else r.dummy_layers)
	rhi.cmd_bind_texture(cmd, SLOT_REST, p.t.rest if p.t.rest != 0 else r.dummy_rest)
	// Without an atmosphere no pass reads the aerial perspective: any volume stands for it.
	rhi.cmd_bind_texture(cmd, SLOT_AERIAL, p.t.aerial if p.t.aerial != 0 else r.display_lut)
	rhi.cmd_bind_texture(cmd, SLOT_SHADOW_TABLE, p.t.shadow_raster.table if p.t.shadow_raster.table != 0 else r.dummy_uint)
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
set_params :: proc(cmd: ^rhi.Command_List, params: ^$T) {
	rhi.cmd_set_constants(cmd, SLOT_PARAMS, params, size_of(T))
}

@(private)
groups :: proc "contextless" (size, group: u32) -> u32 {return (size + group - 1) / group}

// Keeps of what the last view counted what the lists of the cull grow from,
// as the most any view of the frame needed (cull_stats_fold.comp).
@(private)
cull_stats_fold :: proc(r: ^Renderer, cmd: ^rhi.Command_List) {
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Cull_Stats_Fold])
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, r.stats_buffer)
	rhi.cmd_dispatch(cmd, 1)
}

@(private)
read_stats :: proc(r: ^Renderer, slot: int) {
	if ptr := rhi.buffer_mapped(r.device, r.stats_readback[slot]); ptr != nil {
		stats := (cast(^Gpu_Cull_Stats)ptr)^
		r.stats.visible_instances = stats.visible_instances
		r.stats.visible_triangles = stats.visible_triangles
		r.stats.visible_clusters = stats.visible_clusters
		for kind, k in stats.kinds {r.stats.visible_kinds[Visible_Kind_Id(k)] = kind}
		r.stats.visible_late = stats.late
		r.stats.cull_dropped = stats.most_dropped
		r.stats.raster_vertices, r.stats.raster_triangles, r.stats.raster_deferred = stats.raster[0], stats.raster[1], stats.raster[2]
		// A list that dropped grows for the frames after, by what it lacked.
		for dropped, list in stats.most_dropped {
			if dropped > 0 && list < .Raster_Vertices {r.scene.cull_wanted[list] = max(r.scene.cull_wanted[list], r.scene.cull_capacity[list] + dropped)}
		}
		most := CULL_MOST
		for &wanted, list in r.scene.cull_wanted {wanted = min(wanted, most[list])}
		// Those of the raster, which a view writes again in each of its rounds,
		// ask for a third of what the view that needs most would hold: it is
		// drawn in up to RASTER_ROUNDS of them.
		// A round of the maps is the only one of its cull: they hold what it needs
		// whole, of which a round of a view takes its share alone (raster_share).
		for list, k in ([2]Cull_List{.Raster_Vertices, .Raster_Triangles}) {
			r.scene.cull_wanted[list] = max(r.scene.cull_wanted[list], min((stats.most_raster_need[k] + RASTER_LIST_SHARE - 1) / RASTER_LIST_SHARE, CULL_MARK_MAX))
			r.scene.raster_shadow_wanted[k] = max(r.scene.raster_shadow_wanted[k], min(stats.shadow_need[k], CULL_MARK_MAX))
		}
		r.stats.culled_instances = stats.culled_instances
		r.stats.occluded_instances = stats.occluded_instances
		r.stats.probes_traced = stats.probes_traced
		r.stats.probe_rays_traced, r.stats.probe_hits_lit = stats.probe_rays[0], stats.probe_rays[1]
		r.stats.resolved_pixels, r.stats.resolve_helpers, r.stats.resolve_quads_again = stats.resolved[0], stats.resolved[1], stats.resolved[2]
		r.stats.light_lists = stats.lists
		r.stats.shadow = stats.views_shadow
		r.probe.found = stats.probe
	}
	r.stats.timings, _, _ = rhi.frame_timings(r.device)
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

// The raster of the visibility target of a round into depth, a draw of each
// raster bin, indexed by the triangles the round listed of its clusters
// (raster_round_record); a view with a clip plane draws nothing behind it.
// ids, depth: what the pass does first with the visibility target and depth.
@(private)
visibility_pass :: proc(p: ^Pass, round: u32, ids, depth: rhi.Load_Op, depth_target: rhi.Texture, keep_depth, clip: bool) {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	names := [abi.RASTER_ROUNDS]string{0 = "visibility", 1 = "visibility late"}
	pass := rhi.Render_Pass_Desc{color_count = 1, name = names[round] if names[round] != "" else "visibility of what found no room"}
	pass.colors[0] = {texture = t.visibility, load = ids, store = .Store}
	pass.depth = {texture = depth_target, load = depth, store = .Store if keep_depth else .Dont_Care, clear = 0}
	rhi.cmd_begin_render_pass(cmd, &pass)
	if p.draw {
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.visible_buffer)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS1, s.raster_vertices)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS2, s.raster_ids)
		rhi.cmd_bind_index_buffer(cmd, s.raster_indices)
		first := Pipeline_Id.Visibility_Clip if clip && r.pipelines[.Visibility_Clip] != 0 else .Visibility
		for bin in 0 ..< RASTER_BINS {
			rhi.cmd_bind_pipeline(cmd, r.pipelines[Pipeline_Id(int(first) + bin)])
			rhi.cmd_draw_indexed_indirect(cmd, s.cull_state_buffer, u64(offset_of(Gpu_Cull_State, draws)) + u64(int(round) * RASTER_BINS + bin) * size_of(rhi.Draw_Indexed_Indirect), 1)
		}
	}
	rhi.cmd_end_render_pass(cmd)
}

// The G-buffer from the visibility target: the depth of the Surface program
// of each pixel, then the resolve of each program the cull saw a cluster of,
// which runs where that depth is its own. A nested view resolves its own
// pixels over those of its view.
#assert(POINTS_PROGRAM_CAPACITY < 65534, "the 16-bit program depth holds a step for each program and one for none")
@(private)
resolve_pass :: proc(p: ^Pass, nested: bool) {
	r, cmd, t := p.r, p.cmd, p.t
	render_zone(r, "material resolve")
	s := &r.scene
	classify := rhi.Render_Pass_Desc{name = "program depth"}
	classify.depth = {texture = t.program_depth, load = .Clear, store = .Store, clear = 0}
	rhi.cmd_begin_render_pass(cmd, &classify)
	if p.draw {
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Program_Depth])
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.visible_buffer)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.visibility)
		rhi.cmd_draw(cmd, 3)
	}
	rhi.cmd_end_render_pass(cmd)
	targets, count := gbuffer_targets(p)
	pass := rhi.Render_Pass_Desc{color_count = count, name = "nested view resolve" if nested else "resolve"}
	for target, i in targets[:count] {
		pass.colors[i] = {texture = target, load = .Load if nested else .Clear, store = .Store}
	}
	pass.depth = {texture = t.program_depth, load = .Load, store = .Dont_Care}
	rhi.cmd_begin_render_pass(cmd, &pass)
	if p.draw {
		variant := 2 if p.layered else 1 if p.reflectance else 0
		ids := [2][3]Pipeline_Id{{.Resolve_Plain, .Resolve, .Resolve_Layers}, {.Resolve_Nested_Plain, .Resolve_Nested, .Resolve_Nested_Layers}}
		id := ids[1 if nested else 0][variant]
		rhi.cmd_bind_pipeline(cmd, r.pipelines[id])
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.visible_buffer)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.visibility)
		// A nested view counts with its cull, apart.
		rhi.cmd_bind_buffer(cmd, SLOT_PASS2, r.scratch_buffer if nested else r.stats_buffer)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS3, s.program_draws)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS4, s.visible_moved)
		// The decals of the view, which a nested view does not show.
		decals := p.decals && !nested
		textures, _ := decal_textures(p)
		for texture, target in textures {
			rhi.cmd_bind_texture(cmd, SLOT_PASS5 + u32(target), texture if decals && texture != 0 else r.dummy_texture)
		}
		textures_feedback_bind(r, cmd)
		resolve_programs_draw(r, cmd, id, decals)
	}
	rhi.cmd_end_render_pass(cmd)
}

// Where the vertex hook moved each pixel from where it rests (rest.comp),
// after the resolve of the view, while a batch gives the hook values.
@(private)
rest_pass :: proc(p: ^Pass) {
	r, cmd, t := p.r, p.cmd, p.t
	if !p.draw || t.rest == 0 || p.frame.flags & FRAME_FLAG_SWAY == 0 {return}
	rhi.cmd_timestamp(cmd, "rest")
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Rest])
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, r.scene.visible_buffer)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.visibility)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.rest)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, r.scene.visible_moved)
	rhi.cmd_dispatch(cmd, groups(t.width, 8), groups(t.height, 8))
}

// The resolve of the materials without a program, then that of each Surface
// program of the scene, with the stage of the program, or with that of
// `target` while the shaders in use have none. The draw of a program has an
// instance only when the cull of the view saw a cluster of it (cull_bins.comp).
// Off its feedback turn a program takes the pipeline without the recording,
// once it is made (textures_feedback_turn). decals: it applies what the
// decals of the view left (decal_buffer.slang), once its pipelines are made.
@(private)
resolve_programs_draw :: proc(r: ^Renderer, cmd: ^rhi.Command_List, id: Pipeline_Id, decals: bool) {
	s := &r.scene
	applied := rhi.Shader_Constants{VIS_RESOLVE_FRAG_DECALS} if decals else {}
	target := pipeline_of(r, id, applied, optional = applied)
	quiet := pipeline_of(r, id, applied + {VIS_RESOLVE_FRAG_QUIET}, optional = applied + {VIS_RESOLVE_FRAG_QUIET})
	pipeline :: proc(r: ^Renderer, target, quiet: ^rhi.Pipeline, program: u32) -> rhi.Pipeline {
		return program_spared(r, target, target if textures_feedback_turn(r, program) else quiet, program)
	}
	rhi.cmd_bind_pipeline(cmd, pipeline(r, target, quiet, 0))
	rhi.cmd_draw_indirect(cmd, s.program_draws, 0, 1, size_of(Gpu_Program_Draw))
	if s.programmed_rows == 0 {return}
	for program in renderer_programs(r) {
		// A program only blended rows show has no pixel there.
		if program.domain != .Surface || program.id == 0 || program.id >= r.points.programs || s.program_opaque_rows[program.id] == 0 && !s.program_shown_opaque[program.id] {continue}
		rhi.cmd_bind_pipeline(cmd, pipeline(r, target, quiet, program.id))
		rhi.cmd_draw_indirect(cmd, s.program_draws, u64(program.id) * size_of(Gpu_Program_Draw), 1, size_of(Gpu_Program_Draw))
	}
}

// Draws the clusters of an instance whose mesh is in the pools, for a pass of
// its own (gbuffer.vert without the visible list), indexed by where the
// frame listed its mesh (mesh_draws.odin): those of level 0, or all of them,
// the vertices of those out of the cut of the view collapsed, and those of
// materials of another program than `program` (SLOT_DRAW).
@(private)
instance_clusters_draw :: proc(r: ^Renderer, cmd: ^rhi.Command_List, instance: u32, level0: bool,
	program: u32, plain: rhi.Transient = {}) {
	s := &r.scene
	mesh := s.instances[instance].meta.x & INSTANCE_MESH_MASK
	// A streamed mesh draws the finest its pools hold, which may be coarser than level 0.
	streamed := int(mesh) < len(s.meshes) && s.meshes[mesh].stream != nil
	first, count, ok := mesh_draws_range(s, mesh, level0 && !streamed)
	if !ok {return}
	if program == 0 && plain.buffer != 0 {
		rhi.cmd_bind_transient(cmd, SLOT_DRAW, plain)
	} else {
		drawn := [4]u32{program, 0, 0, 0}
		rhi.cmd_set_constants(cmd, SLOT_DRAW, &drawn, size_of(drawn))
	}
	rhi.cmd_draw_indexed(cmd, count, 1, first, instance)
}

// Editor selection mask: the highlighted instances alone, in full detail
// (level 0) and without the scene's occlusion, so the outline follows their
// complete silhouette. Its unjittered window-point mask is independent of TAA.
@(private)
highlight_pass :: proc(p: ^Pass) {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	pass := rhi.Render_Pass_Desc{color_count = 1, name = "highlight mask"}
	pass.colors[0] = {texture = t.highlight, load = .Clear, store = .Store}
	pass.depth = {texture = t.highlight_depth, load = .Clear, store = .Dont_Care, clear = 0}
	rhi.cmd_bind_index_buffer(cmd, s.mesh_draws)
	rhi.cmd_begin_render_pass(cmd, &pass)
	for &inst, index in s.instances {
		if !highlight_drawn(inst.meta.w) || viewmodel_elsewhere(&p.frame, &inst) {continue}
		instance_programs_draw(r, cmd, &r.pipelines[.Highlight], u32(index), true, blended = true)
	}
	rhi.cmd_end_render_pass(cmd)
}

// Outlines only sample within a few pixels of highlighted silhouettes. Use
// conservative projected world bounds to avoid running the neighborhood
// filter over the rest of the drawable. Camera motion changes only this
// small calculation, never the scene or its acceleration structures. The
// boxes are where the view of f draws them (drawn_box).
highlight_screen_bounds :: proc(s: ^Scene_State, f: ^Gpu_Frame, points, render_size: Vec2, glow: f32) -> Vec4 {
	lo, hi := Vec2{1e30, 1e30}, Vec2{-1e30, -1e30}
	found := false
	for &inst, index in s.instances {
		if !highlight_drawn(inst.meta.w) || viewmodel_elsewhere(f, &inst) {continue}
		rect := projected_box(drawn_box(s, f, u32(index)), f.view_proj_unjittered, f.camera_position.xyz)
		lo, hi, found = linalg.min(lo, rect.xy), linalg.max(hi, rect.zw), true
	}
	if !found {return {1, 1, 0, 0}}
	// Include contour/glow, mask texel rounding and TAA jitter even when the
	// scene renders below drawable resolution or at a different UI density.
	padding := Vec2{max(glow, 1) / max(points.x, 1) + 2 / max(render_size.x, 1), max(glow, 1) / max(points.y, 1) + 2 / max(render_size.y, 1)}
	lo = linalg.max(lo - padding, Vec2{}); hi = linalg.min(hi + padding, Vec2{1, 1})
	return {lo.x, lo.y, hi.x, hi.y}
}

@(private)
projected_box :: proc(box: mm.Aabb, projection: Mat4, eye: Vec3) -> Vec4 {
	lo, hi := Vec2{1e30, 1e30}, Vec2{-1e30, -1e30}
	for corner in 0 ..< 8 {
		p := Vec3{
			box.min.x if corner & 1 == 0 else box.max.x,
			box.min.y if corner & 2 == 0 else box.max.y,
			box.min.z if corner & 4 == 0 else box.max.z,
		}
		clip := projection * Vec4{p.x - eye.x, p.y - eye.y, p.z - eye.z, 1}
		if !(clip.w > 0.001) {return {0, 0, 1, 1}}
		uv := Vec2{clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5}
		lo, hi = linalg.min(lo, uv), linalg.max(hi, uv)
	}
	return {lo.x, lo.y, hi.x, hi.y}
}

// The maps of the view for a pass that lights hits with MIRAI_LIGHT_MAPS of
// lighting.slang (SUN_SHADOW_SLOT, SHADOW_DATA_SLOT); the
// dummies when the view drew none.
@(private)
bind_light_maps :: proc(p: ^Pass, maps: bool) {
	r, cmd, t := p.r, p.cmd, p.t
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.shadow_raster.atlas if maps else r.dummy_texture)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS8, r.shadow_buffers.table if maps else r.dummy_buffer)
}

// Farthest-depth mip chain of the depth target, as it holds it (reverse Z),
// up to DEPTH_PYRAMID_BATCH levels a dispatch (hiz.comp), each from the last
// level of the one before.
@(private)
build_depth_pyramid :: proc(p: ^Pass, pyramid: rhi.Texture) {
	r, cmd, t := p.r, p.cmd, p.t
	Params :: struct {source_size: [2]i32, levels, pad: u32, inv_extent, pad1: [2]f32}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Hiz])
	source := [2]u32{t.width, t.height}
	side := rhi.texture_desc(r.device, pyramid)
	for first: u32 = 0; first < t.hiz_levels; first += DEPTH_PYRAMID_BATCH {
		count := min(DEPTH_PYRAMID_BATCH, t.hiz_levels - first)
		extent := source if first == 0 else [2]u32{max(side.width >> (first - 1), 1), max(side.height >> (first - 1), 1)}
		params := Params{source_size = {i32(source.x), i32(source.y)}, levels = count, inv_extent = 1 / [2]f32{f32(extent.x), f32(extent.y)}}
		set_params(cmd, &params)
		if first == 0 {rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.depth)} else {rhi.cmd_bind_texture(cmd, SLOT_PASS0, pyramid, i32(first - 1))}
		// The targets past the last level are bound to it, and not written.
		for k in 0 ..< u32(DEPTH_PYRAMID_BATCH) {rhi.cmd_bind_texture(cmd, SLOT_PASS1 + k, pyramid, i32(first + min(k, count - 1)))}
		top := [2]u32{(source.x + 1) / 2, (source.y + 1) / 2}
		rhi.cmd_dispatch(cmd, groups(top.x, 8), groups(top.y, 8))
		for &extent in source {extent = (extent + (1 << count) - 1) >> count}
	}
}

// A finished image of the window into a target the size of the frame.
@(private)
present_blit :: proc(r: ^Renderer, cmd: ^rhi.Command_List, target: rhi.Texture, format: rhi.Format, source: rhi.Texture) {
	if !ensure_blit_pipeline(r, format) {return}
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
    r.pipeline_waiting=""
    started:=time.tick_now()
    zone:=render_zone_begin(r,"uploads arrived")
    texture_uploads_install(r)
    geometry_uploads_install(r)
    base.profile_end(zone)
    zone=render_zone_begin(r,"programs")
    pipelines_install(r)
    if r.variants_wanted {pipeline_variants_ask(r)}
    if r.scene.programs_arrived {programs_ask(r)}
    base.profile_end(zone)
    // What the extensions asked of this frame lasts for it alone.
    defer {
        r.pass_count=0;r.main_pipeline=0;r.gbuffer_asked={};r.decal_emission_asked=false;r.eye_taken={};r.dynamic_lights.asked=0
        r.antialiasing_offered=r.antialiasing
        r.antialiasing_offered_count=r.antialiasing_count
        r.antialiasing_count=0
    }
    r.previous_time,r.time=r.time,frame.time
    // After another world the time may jump by what loading it took: the
    // frame keeps the pace of the one before.
    if !r.world_switched {r.delta_time=max(r.time-r.previous_time,0)}
    // A world shown again (scene_world) has the light of the scene it was given since.
    if r.world_kept {r.scene.changes={}}
    r.world_switched,r.world_kept=false,false
    r.frame_changes={}
    r.frame_eye=frame.camera.position
    // The origin follows the eye of the first view of the window; what the
    // frame places comes relative to it. Every view projects from its own eye.
    if !frame.offscreen && !frame.ui_only {
        eye:=frame.camera.position
        for view in frame.views {if view.texture==0 && !view.disabled {eye=view.camera.position;break}}
        renderer_origin_follow(r,eye)
    }
    zone=render_zone_begin(r,"poses")
    frame,framed:=origin_frame(r,frame)
    if framed {
        displaced_prepare(r)
        skins_bounds(r)
    }
    base.profile_end(zone)
    if !framed {return false}
    // What changed for the shadows reaches the views of a frame that draws the scene.
    if !frame.ui_only {
        r.frame_occluders=r.scene.occluders
        r.scene.occluders={}
    }
    zone=render_zone_begin(r,"batches")
    batches_build(r)
    base.profile_end(zone)
    zone=render_zone_begin(r,"light tree")
    settled:=scene_lights_settle(r)
    base.profile_end(zone)
    zone=render_zone_begin(r,"scene capacity")
    settled=settled && ensure_scene_capacity(r)
    base.profile_end(zone)
    if !settled {return false}
    if !frame.offscreen && !frame.ui_only {
        // The cuts rays trace follow the eye of the first view of the window, as the probes.
        eye:=frame.camera.position
        for view in frame.views {if view.texture==0 && !view.disabled {eye=view.camera.position;break}}
        if frame.detail.on {eye=frame.detail.camera.position}
        zone=render_zone_begin(r,"ray cuts")
        ray_cuts_update(r,eye)
        base.profile_end(zone)
    }
    if r.settings.gi_enabled && (!frame.offscreen || frame.settle_gi) && !frame.ui_only {
        // The probes follow the focus of the first view of the window.
        focus:=camera_focus(frame.camera)
        for view in frame.views {if view.texture==0 && !view.disabled {focus=camera_focus(view.camera);break}}
        zone=render_zone_begin(r,"probes placed")
        if ddgi_ensure(r) {ddgi_place(r,focus)}
        base.profile_end(zone)
    } else if !r.settings.gi_enabled && r.ddgi.valid {
        ddgi_release(r)
        probe_hits_release(r)
    }
    zone=render_zone_begin(r,"views prepared")
    // A frame no window shows that draws only into textures leaves the views
    // of the window as they are: it records those alone.
    alone:=frame.offscreen && len(frame.views)>0
    for view in frame.views {if view.texture==0 {alone=false}}
    prepared_ok:=(r.main.targets.ldr!=0 || create_targets(r,&r.main,r.window_width,r.window_height,window_render_scale(r,f32(r.window_height)),true)) &&
                 prepare_views(r,frame.views,alone) && (r.view_count>0 || (alone || frame.ui_only || scene_targets(r,&r.main)) && ensure_glass_targets(r,&r.main.targets)) &&
                 (frame.ui_only || air_tables_ensure(r) && points_prepare(r))
    if prepared_ok {ground_prepare(r)}
    if prepared_ok && !frame.ui_only {sky_bakes_ensure(r)}
    if prepared_ok && r.view_count>0 {main_scene_release(r)}
    // A window whose pipeline generates frames shows them through the presenter of the device.
    if prepared_ok && !frame.offscreen {
        _,main_plan:=view_plan(r,0,true)
        rhi.swapchain_set_paced(d,main_plan.generates)
    }
    base.profile_end(zone)
    if !prepared_ok {return false}
    prepared:=time.tick_now()
    zone=render_zone_begin(r,"gpu slot")
    cmd,began:=rhi.frame_begin(d,!frame.offscreen)
    base.profile_end(zone)
    gpu_submission_keep(r)
    if !began {
        set_error(r,"the device gave no frame to draw: %s",rhi.device_error(d)!=""?rhi.device_error(d):"the window is being resized or its image is not ready")
        return false
    }
    begun:=time.tick_now()
    slot:=int(rhi.frame_number(d)%rhi.MAX_FRAMES_IN_FLIGHT)
    zone=render_zone_begin(r,"readbacks")
    read_stats(r,slot)
    points_read(r,slot)
    pages_update(r,slot)
    base.profile_end(zone)
    zone=render_zone_begin(r,"shadow movers")
    if !frame.ui_only {shadow_movers_update(r)}
    shadow_bound_update(r,slot,frame.refresh_hz)
    base.profile_end(zone)
    zone=render_zone_begin(r,"readbacks")
    textures_feedback_read(r,slot)
    extension_counters_begin(r,cmd,slot)
    // A frame none of whose views culls reports no counts, not those of the last one that did.
    rhi.cmd_fill_buffer(cmd,r.stats_buffer,0,size_of(Gpu_Cull_Stats),0)
    cost_begin(r,cmd)
    depth_probes_begin(r,cmd,slot,frame.probes)
    extension_readbacks_take(r,slot)
    r.stats.counters=r.counters.counters[:r.counters.count]
    r.stats.ui_vertices_dropped,r.stats.debug_vertices_dropped=0,0
    r.stats.shadow_movers=0
    r.stats.shadow_marked=0
    r.stats.shadow_stale,r.scene.shadow_stale_by=r.scene.shadow_stale_by,{}
    r.stats.ui_shapes_dropped,r.stats.ui_layers_dropped=0,0
    r.ui_shape_written,r.ui_shape_cache_count,r.ui_vertex_cache_count=0,0,0
    ui_written:=0
    s:=&r.scene
    s.lights_changed=false
    base.profile_end(zone)
    zone=render_zone_begin(r,"uploads")
    texture_uploads_record(r,cmd)
    texture_writes_record(r,cmd,frame.texture_writes)
    recorded_ok:=renderer_commit_geometry(r,cmd,slot) && font_record(r,cmd,slot) && ground_table_record(r,cmd)
    base.profile_end(zone)
    zone=render_zone_begin(r,"scene tables")
    recorded_ok=recorded_ok && upload_scene(r,cmd) && viewmodels_place(r,cmd,frame)
    base.profile_end(zone)
    zone=render_zone_begin(r,"mesh draws")
    recorded_ok=recorded_ok && decals_order(r,cmd) && mesh_draws_record(r,cmd) && (frame.ui_only || air_frame(r,cmd) && sky_bakes_record(r,cmd))
    if recorded_ok {pages_record_begin(r,cmd)}
    recorded_ok=recorded_ok && textures_feedback_begin(r,cmd,frame)
    base.profile_end(zone)
    // The BLASes built frames ago become their compacted copies; the TLAS of this frame names those.
    if recorded_ok && r.hardware_rt {
        zone=render_zone_begin(r,"ray structures")
        if replaced,freed:=rhi.cmd_compact_blases(cmd);replaced>0 {s.tlas_dirty=true;geometry_released(s,freed)}
        base.profile_end(zone)
    }
    histories_rescale(r,cmd)
    if recorded_ok {
        zone=render_zone_begin(r,"ui textures")
        ui_textures_record(r,cmd,slot,&ui_written,frame.ui_textures)
        base.profile_end(zone)
    }
    if recorded_ok && !frame.ui_only {
        zone=render_zone_begin(r,"extensions")
        geometry:=Pass{r=r,cmd=cmd,slot=slot}
        stage_run(&geometry,.Geometry)
        base.profile_end(zone)
        zone=render_zone_begin(r,"ray structures")
        eyes:[VIEW_CAPACITY+TEXTURE_VIEW_CAPACITY+2]Vec3
        recorded_ok=deformables_record(r,cmd,frame_eyes(frame,&eyes))
        base.profile_end(zone)
    }
    // The views drawn into a texture come first: those of the window may show
    // them. What runs once a frame goes with the first view of the window, or
    // with the first one of a frame alone.
    first:=alone
    for view in frame.views {
        if view.texture==0 || view.disabled || !recorded_ok || frame.ui_only {continue}
        state:=texture_view_find(r,view.texture)
        if state==nil {continue}
        recorded_ok=record_view(r,cmd,state,view,{debug=frame.debug if first else nil,offscreen=frame.offscreen,settle_gi=frame.settle_gi},slot,&ui_written,first)
        first=false
        if recorded_ok {texture_view_show(r,cmd,state,slot,view.readback)}
    }
    first=true
    generated:=false
    r.main.generated=false
    for &view in r.views {view.generated=false}
    if recorded_ok && !alone && frame.ui_only {
        zone=render_zone_begin(r,"compose")
        // What covers the scene may show images of previews: they are drawn without it.
        if r.preview_count>0 {
            rhi.cmd_timestamp(cmd,"previews")
            previews_pass(r,cmd,slot)
        }
        compose_views(r,cmd,{ui=frame.ui},slot,&ui_written)
        base.profile_end(zone)
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
            ok:=record_view(r,cmd,state,view,{panels=frame.panels,debug=frame.debug,effect_views=frame.effect_views,offscreen=frame.offscreen,settle_gi=frame.settle_gi},slot,&ui_written,first,index-1)
            first=false
            recorded_ok &&=ok
            if !ok {break}
        }
        zone=render_zone_begin(r,"compose")
        if recorded_ok {compose_views(r,cmd,frame,slot,&ui_written)}
        for &view in r.views[:r.view_count] {generated||=view.generated}
        if recorded_ok && generated {
            recorded_ok=ensure_generated_target(r,&r.main.targets)
            if recorded_ok {compose_views(r,cmd,frame,slot,&ui_written,true)}
        }
        base.profile_end(zone)
    }
	// ---------------------------------------------------------- present
	zone = render_zone_begin(r, "present")
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
            if r.ddgi.valid {
                rhi.cmd_copy_buffer(cmd,r.ddgi.chosen,0,r.stats_buffer,u64(offset_of(Gpu_Cull_Stats,probes_traced)),4)
                rhi.cmd_copy_buffer(cmd,r.ddgi.chosen,ddgi_counts_offset(&r.ddgi),r.stats_buffer,u64(offset_of(Gpu_Cull_Stats,probe_rays)),8)
            }
        }
        cull_stats_fold(r,cmd)
        rhi.cmd_copy_buffer(cmd,r.stats_buffer,0,r.stats_readback[slot],0,size_of(Gpu_Cull_Stats))
        rhi.cmd_barrier_buffer(cmd,r.stats_readback[slot],.Host_Read)
        pages_record_end(r,cmd,slot)
        textures_feedback_end(r,cmd,slot)
        points_end(r,cmd,slot)
        extension_counters_end(r,cmd,slot)
        depth_probes_end(r,cmd,slot)
        cost_end(r,cmd)
    }
    r.cost.counting,r.cost.taken=false,false
	base.profile_end(zone)
	rhi.cmd_timestamp(cmd, "end")
	recorded := time.tick_now()
	zone = render_zone_begin(r, "submit")
	ok := rhi.frame_end(d, cmd, shown_generated)
	base.profile_end(zone)
	ended := time.tick_now()
	r.stats.cpu_prepare_ms = f32(time.duration_milliseconds(time.tick_diff(started, prepared)))
	r.stats.cpu_begin_ms = f32(time.duration_milliseconds(time.tick_diff(prepared, begun)))
	r.stats.cpu_record_ms = f32(time.duration_milliseconds(time.tick_diff(begun, recorded)))
	r.stats.cpu_end_ms = f32(time.duration_milliseconds(time.tick_diff(recorded, ended)))

	r.frame += 1
	texture_views_count(r)
	update_stats(r)
	if !ok {set_error(r, "the frame was not submitted: %s", rhi.device_error(d))}
	if ok && recorded_ok && renderer_pipelines_pending(r) > 0 {r.pipeline_thread.late_frames += 1}
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
		// What the probes keep of the light of their hits is in the units before: they take it again.
		r.ddgi.lit_everywhere = u32(r.light_frame) + 1
	}
	params.encoded = 0
	set_params(cmd, &params)
	for view in views_all(r) {
		t := &view.targets
		for i in 0 ..< 2 {scale(r, cmd, t.taa[i])}
	}
}

// One view of the frame, from its G-buffer to its image in t.ldr. frame: what
// is drawn over the image of a view of the window.
@(private)
record_view :: proc(r:^Renderer,cmd:^rhi.Command_List,state:^View_State,view:Frame_View,frame:Frame_Desc,slot:int,ui_written:^int,first:bool,index:=0) -> bool {
    render_zone(r,"view")
    if view.camera_cut || !state.has_previous {view_camera_cut(state)}
    // A camera carried with what it sees keeps its histories: its last frame
    // is taken as seen from where the camera would have been.
    if view.carried!={} && state.has_previous {
        back:=linalg.inverse(view.carried)
        state.prev_view_proj=state.prev_view_proj*matrix_from_eye(back)
        state.prev_eye=point_carried(view.carried,state.prev_eye)
        state.prev_depth_plane=plane_carried(state.prev_depth_plane,back)
    }
    zone:=render_zone_begin(r,"view plan")
    handle,plan:=view_plan(r,view.pipeline,view.texture==0)
    planned:=view_pipeline_prepare(r,state,handle,plan)
    base.profile_end(zone)
    if !planned {return false}
    // The passes after the Output stage generate the image shown before this
    // one, for a view of a window whose device presents it; with a history, it
    // is shown. Without a window nobody would see it: they do not run.
    generate:=plan.generates && view.texture==0 && !frame.offscreen && rhi.swapchain_generated_texture(r.device)!=0
    shown:=generate && state.has_previous && !state.resources_made
    if generate && !ensure_generated_target(r,&state.targets) {return false}
    extension_textures_release(r,state)
    p:=Pass{r=r,cmd=cmd,view=state,t=&state.targets,camera=view.camera,slot=slot,first=first,index=index,plan=plan,texture=view.texture!=0,offscreen=frame.offscreen,settle_gi=frame.settle_gi,inspection=view.inspection,wide=view.texture!=0?view.wide:.None}
    p.cost=cost_take(r,first,view.texture!=0,state.targets.hiz_valid)
    p.current=int(state.frames%2)
    p.previous=1-p.current
    zone=render_zone_begin(r,"view constants")
    begun:=view_begin(&p)
    base.profile_end(zone)
    if !begun {return false}
    output:=false
    stages:=STAGE_ZONES
    for index in plan.order[:plan.order_count] {
        pass:=&plan.passes[index]
        ok:=true
        render_zone(r,stages[pass.stage])
        switch pass.stage {
        case .Custom:      if !output || generate {custom_pass_record(&p,pass)}
        case .Geometry:    ok=pass_gbuffer(&p)
        case .Nested:      ok=pass_nested(&p)
        case .Direct:      ok=pass_direct(&p)
        case .World:       ok=pass_world_lighting(&p)
        case .Indirect:    ok=pass_indirect(&p)
        case .Composite:   pass_composite(&p)
        case .Lit:         if r.pass_count>0 && !view_inspected(p.inspection) {lit_run(&p)}
        case .Transparency: ok=pass_transparent(&p)
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
    state.turn+=1
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
		f.sun_shares = {sun.indirect, sun.scattering, 0, 0}
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
	// A camera that draws a viewmodel sees as near as its parts are drawn.
	if viewmodel_fov(p.r, p.camera) > 0 {p.camera.near = min(p.camera.near, VIEWMODEL_NEAR)}
	r, cmd, t, camera := p.r, p.cmd, p.t, p.camera
	d := r.device
	s := &r.scene
	g := &r.ddgi
	settings := &r.settings
	p.use_gi = settings.gi_enabled
	p.use_probes = p.use_gi && g.valid

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
	jitter := taa_jitter(p.view.turn, phases) if phases > 0 else Vec2{}
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
		frame_index = u32(p.view.turn),
		light_nodes = u32(len(s.light_tree)),
		shadowless_lights = light_tree_shadowless(s.light_tree[:]),
		dynamic_lights = dynamic_lights_of(r),
		instance_count = u32(len(s.instances)),
		cut = {settings.lod_error_pixels, settings.batch_min_pixels if settings.lod_error_pixels > 0 else 0, 0, 0},
		batches = {s.batch.slots, s.batch.groups.first, u32(len(s.batch.drawn)), u32(len(s.batch.traced))},
		debug_view = DEBUG_VIEW_EXTENSION if p.inspection.mode == .None && p.inspection.record != nil else u32(p.inspection.mode),
		indirect = s.indirect,
		exposure = view_exposure(p),
		// Rendering below the output resolution samples the mips the output would use.
		texturing = {clamp(math.log2(f32(t.width) / f32(t.output_width)), -2, 0), 0, 0, 0},
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
	f.ground, f.ground_table = ground_frame(r)
	f.scene_box = {{low.x, low.y, low.z, 0}, {high.x, high.y, high.z, 0}}
	if !p.view.has_previous {p.view.prev_view_proj, p.view.prev_depth_plane, p.view.prev_eye = unjittered, f.depth_plane, camera.position}
	f.prev_view_proj, f.prev_depth_plane = p.view.prev_view_proj, p.view.prev_depth_plane
	f.prev_eye = {p.view.prev_eye.x, p.view.prev_eye.y, p.view.prev_eye.z, 0}
	// The clip plane of the view in place of the near one: what is all behind it is not drawn.
	if camera.clip_plane != {} {
		length := linalg.length(camera.clip_plane.xyz)
		if length > 1e-8 {f.frustum[5] = camera.clip_plane / length}
	}
	p.instance_count, p.batch_slots = u32(len(s.instances)), s.batch.slots
	p.draw = p.instance_count + p.batch_slots > 0 && s.index_buffer != 0
	// Modes of inspection show the opaque scene alone.
	transparency := .Transparency in p.plan.stages && !view_inspected(p.inspection)
	if p.draw && transparency {
		translucency_in_frustum(p, &f)
	}
	p.draw_overlays = p.draw && transparency && s.overlay_count > 0
	p.blend = transparency && stage_asked(r, .Blend)
	scale := s.light_scale if s.light_scale > 0 else 1
	frame_sun_sky(&f, s.sun, s.environment, scale, max(settings.sun_radius, SUN_RADIUS), r.air.built, settings.sun_shadows && !s.sun.shadowless)
	f.sky_map = sky_map(r, sky_image_of(r, 0, s.environment.sky_texture, s.environment.sky_program), s.environment.sky_atmosphere)
	f.sky_from_map = sky_map(r, sky_image_of(r, 1, s.environment.sky_from_texture, s.environment.sky_from_program), s.environment.sky_from_atmosphere)
	if s.environment.use_background {
		f.background_map = sky_map(r, s.environment.background_texture, false)
		f.background_map.y = 0 if s.environment.background_behind else 1
	}
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
		f.background_map = {}
	}
	if p.use_gi {f.flags |= FRAME_FLAG_GI}
	if p.use_gi && p.plan.gi_given {f.flags |= FRAME_FLAG_GI_GIVEN}
	if r.hardware_rt {f.flags |= FRAME_FLAG_HW_RT}
	if s.environment.ground_grid && !p.texture {f.flags |= FRAME_FLAG_GRID}
	if r.resolve_counted {f.flags |= FRAME_FLAG_RESOLVE_COUNTED}
	p.reflectance, p.layered, p.subsurface = reflectance_in_frustum(r, f.frustum)
	// A mode of inspection shows each pixel as the G-buffer and the lights give it.
	p.subsurface &&= p.inspection.mode == .None
	p.scattered = false
	// What the surfaces of the Gbuffer stage of extensions need, wherever they are.
	if stage_asked(r, .Gbuffer) {
		p.layered ||= .Layers in r.gbuffer_asked
		p.reflectance ||= p.layered || .Reflectance in r.gbuffer_asked
	}
	if p.reflectance && !ensure_surface_target(r, t) {return false}
	if p.layered && !ensure_layers_target(r, t) {return false}
	if p.subsurface && !subsurface_targets(r, t) {return false}
	p.decals = (p.draw && len(s.decals) > 0 || stage_asked(r, .Decal)) && renderer_feature(r, .Decals)
	p.decal_emission = p.decals && (s.decal_emission || r.decal_emission_asked)
	if !decal_targets(r, t, p.decals, p.decal_emission) {return false}
	if r.frame_layout.instance_ids && !ensure_instance_target(r, t) {return false}
	if s.batch.hooked && !ensure_rest_target(r, t) {return false}
	if p.reflectance {f.flags |= FRAME_FLAG_REFLECTANCE}
	if s.batch.hooked {f.flags |= FRAME_FLAG_SWAY}
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
		clear_textures(cmd, t.taa[0], t.taa[1], t.taa_frames[0], t.taa_frames[1], t.reactive, r.dummy_texture, r.dummy_layers, r.dummy_uint, r.dummy_views)
		t.needs_clear = false
	}
	bind_scene_table(p)
	if !air_aerial(p) {return false}
	// The volume the view may have made just now.
	rhi.cmd_bind_texture(cmd, SLOT_AERIAL, t.aerial if t.aerial != 0 else r.display_lut)

	// What the stages a pipeline may leave out give the ones after them.
	p.gi, p.gathered = r.dummy_texture, false
	if p.plan.gi_given {
		if !target(r, cmd, &t.gi_given, t.width, t.height, .RGBA32_Float, HISTORY_USAGE, "given gi", true) {return false}
		p.gi = t.gi_given
	}
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
	frame.flags |= display_frame_flags(r)
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
	chunk_capacity, visible_capacity, candidate_capacity: u32,
	probe: u32, // the instance whose cull the stats keep, plus one (Instance_Probe); 0: none
	pages: [4]u32, // pages_cull_params
}

// The state of the cull of a view as each starts: the draws of its phases
// and bins with no triangles, and nothing counted. Phase 0 of the instance
// pass starts the rest (cull.comp).
@(private)
cull_reset :: proc(r: ^Renderer, cmd: ^rhi.Command_List, instances: u32) -> bool {
	start := [1]Gpu_Cull_State{{chunk_dispatch = {0, 0, 1}, candidate_dispatch = {0, 1, 1}, bins_dispatch = {{0, 1, 1}, {0, 1, 1}}, raster_dispatch = {0, 0, 1}, raster_pending = {GPU_NONE, 0}, instance_dispatch = {groups(instances, 64), 1, 1}}}
	return upload_transient(r, cmd, start[:], r.scene.cull_state_buffer)
}

// Of each phase and tested raster bin, a word per depth bucket for its
// clusters and one for the cursor they take their places with; then, of
// each tested bin, a word per bucket for the triangles a round of the raster
// lists of it and one for where they start (raster_lists.slang).
DEPTH_BUCKET_WORDS :: 2 * 2 * 2 * RASTER_DEPTH_BUCKETS + 2 * 2 * RASTER_DEPTH_BUCKETS

// The pass of cull_bins.comp after the cull of a phase: it places the
// clusters it listed in their raster bins, the list the draws of the phase
// read.
@(private)
cull_bins_dispatch :: proc(r: ^Renderer, cmd: ^rhi.Command_List, phase: u32) {
	s := &r.scene
	Params :: struct {phase, capacity, pad0, pad1: u32}
	params := Params{phase = phase, capacity = s.cull_capacity[.Visible]}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Cull_Bins])
	set_params(cmd, &params)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.cull_state_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, s.listed_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS2, s.visible_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS3, s.visible_moved)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, s.depth_buckets)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS5, s.raster_entries)
	rhi.cmd_dispatch_indirect(cmd, s.cull_state_buffer, u64(offset_of(Gpu_Cull_State, bins_dispatch)) + u64(phase) * size_of([3]u32))
}

// How far a device may move a corner of a triangle as it places it on the
// grid of its raster, in pixels: a step of that grid, and what the float
// that holds a pixel of a view loses (raster_triangle_shows).
@(private)
raster_margin :: proc "contextless" (subpixel_bits: u32) -> f32 {
	return 1 / f32(u32(1) << clamp(subpixel_bits, 4, 16)) + 1.0 / 512
}

// What a round of the passes of raster_lists.slang reads and writes: the
// state of its cull, the list of its clusters and what each keeps between
// the passes. shadow: of a round of the maps of the shadows, its parameters,
// which raster_vertices.comp places the vertices with for the pages of the
// pool (shadow_cull.slang); nil for the view.
@(private)
Raster_Round_Lists :: struct {
	state, visible, entries: rhi.Buffer,
	shadow:                  ^Shadow_Params,
	pages, maps:             rhi.Buffer, // of the maps: the buffer of the pages of the view and the words of the maps
}

// A round of the passes of raster_lists.slang: it takes the clusters of the
// list no round listed yet, those cull_bins.comp placed since the round
// before (or the cull of the maps listed) and those that found no room in
// it, and writes their vertices, which of their triangles show, where the
// triangles of each raster bin and depth bucket go, and the triangles
// themselves, which the draws of the round read. last: no round follows, so
// what finds no room is left out and counted. stats: what counts the
// vertices and the triangles written, the clusters left to the next round
// and what was left out. lists: those of the view where nil.
@(private)
raster_round_record :: proc(r: ^Renderer, cmd: ^rhi.Command_List, round: u32, last: bool, stats: rhi.Buffer, lists: ^Raster_Round_Lists = nil, cost: rhi.Buffer = 0) {
	render_zone(r, "raster round")
	s := &r.scene
	view := Raster_Round_Lists{state = s.cull_state_buffer, visible = s.visible_buffer, entries = s.raster_entries}
	l := lists if lists != nil else &view
	groups := u64(offset_of(Gpu_Cull_State, raster_dispatch))
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Raster_Round])
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, l.state)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, s.depth_buckets)
	rhi.cmd_dispatch(cmd, 1)
	margin := raster_margin(rhi.device_info(r.device).subpixel_bits)
	if l.shadow != nil {
		params := l.shadow^
		params.round, params.last, params.margin = round, u32(last), margin
		params.vertex_capacity, params.triangle_capacity = s.cull_capacity[.Raster_Vertices], s.cull_capacity[.Raster_Triangles]
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Raster_Vertices_Shadow_Cost if cost != 0 else .Raster_Vertices_Shadow])
		set_params(cmd, &params)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS6, l.pages)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS7, l.maps)
	} else {
		Vertices_Params :: struct {round, last, vertex_capacity, triangle_capacity: u32, margin: f32, pad: [3]u32}
		// A round of a view takes its share of the lists, whatever a round of the
		// maps grew them to: what finds no room is drawn by the round after, over
		// the depth of those before.
		vertices := Vertices_Params{round = round, last = u32(last), margin = margin}
		vertices.vertex_capacity = min(s.raster_share[0], s.cull_capacity[.Raster_Vertices])
		vertices.triangle_capacity = min(s.raster_share[1], s.cull_capacity[.Raster_Triangles])
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Raster_Vertices_Cost if cost != 0 else .Raster_Vertices])
		set_params(cmd, &vertices)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS6, s.visible_moved)
	}
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, l.state)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, stats)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS2, l.visible)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS3, s.raster_vertices)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, s.depth_buckets)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS5, l.entries)
	if cost != 0 {rhi.cmd_bind_buffer(cmd, SLOT_PASS8, cost)}
	rhi.cmd_dispatch_indirect(cmd, l.state, groups)
	Params :: struct {round, ids, pad0, pad1: u32}
	params := Params{round = round, ids = 0 if l.shadow != nil else 1}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Raster_Starts])
	set_params(cmd, &params)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, l.state)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, s.depth_buckets)
	rhi.cmd_dispatch(cmd, 1)
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Raster_Triangles])
	set_params(cmd, &params)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, l.state)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS2, l.visible)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS3, s.raster_indices)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, s.depth_buckets)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS5, l.entries)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS6, s.raster_ids)
	rhi.cmd_dispatch_indirect(cmd, l.state, groups)
}

@(private)
cull_bind :: proc(p: ^Pass, params: Cull_Params, hiz: rhi.Texture, stats: rhi.Buffer) {
	r, cmd := p.r, p.cmd
	s := &r.scene
	params := params
	params.chunk_capacity, params.visible_capacity, params.candidate_capacity = s.cull_capacity[.Chunks], s.cull_capacity[.Visible], s.cull_capacity[.Candidates]
	params.programs = r.points.programs
	params.pages = pages_cull_params(r)
	params.probe = r.probe.instance
	set_params(cmd, &params)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.cull_state_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, stats)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, hiz)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS5, s.chunk_buffer)
	// The cluster pass asks for pages and stamps their slots.
	rhi.cmd_bind_buffer(cmd, SLOT_PASS7, or_dummy(r, s.pages.request_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_PASS8, or_dummy(r, s.pages.stamp_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_PASS9, s.program_draws)
}

// The passes of a phase of the cull: before phase 0, by batch, which lists
// the slots of the batches the view draws; by instance, which hands the
// clusters of their cuts over in chunks; and by cluster over the chunks.
@(private)
cull_record :: proc(p: ^Pass, params: Cull_Params, hiz: rhi.Texture, stats, glass: rhi.Buffer, cost: rhi.Buffer = 0, viewmodel := false) {
	r, cmd := p.r, p.cmd
	render_zone(r, "cull")
	s := &r.scene
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Cull_Cost if cost != 0 else .Cull])
	cull_bind(p, params, hiz, stats)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS3, s.candidate_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, glass)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS6, s.depth_buckets)
	if params.phase == 0 {
		batches := params
		batches.phase = abi.CULL_PHASE_BATCHES
		cull_bind(p, batches, hiz, stats)
		rhi.cmd_dispatch(cmd, groups(max(u32(len(s.batch.drawn)), 1), 64))
		cull_bind(p, params, hiz, stats)
	}
	// After cull_bind, which binds the stamps of the pages in its place.
	if cost != 0 {rhi.cmd_bind_buffer(cmd, SLOT_PASS8, cost)}
	rhi.cmd_dispatch_indirect(cmd, s.cull_state_buffer, u64(offset_of(Gpu_Cull_State, instance_dispatch)))
	// The viewmodel of the view, from its list, in front of all that could hide it (viewmodel.odin).
	if viewmodel {
		// Without room in the transient ring (set_error says so) the view draws none.
		count, listed := viewmodel_list(p)
		if pipeline := pipeline_of(r, .Cull, {CULL_COMP_VIEWMODEL})^; listed && count > 0 && pipeline != 0 {
			rhi.cmd_bind_pipeline(cmd, pipeline)
			viewmodel := params
			viewmodel.occlusion = 0
			cull_bind(p, viewmodel, hiz, stats)
			rhi.cmd_bind_buffer(cmd, SLOT_PASS3, s.viewmodel_list)
			rhi.cmd_bind_buffer(cmd, SLOT_PASS4, glass)
			rhi.cmd_bind_buffer(cmd, SLOT_PASS6, s.depth_buckets)
			rhi.cmd_dispatch(cmd, groups(count, 64))
		}
	}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Cull_Clusters])
	cull_bind(p, params, hiz, stats)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS3, s.cluster_candidate_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS6, s.listed_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, s.depth_buckets)
	rhi.cmd_dispatch_indirect(cmd, s.cull_state_buffer, u64(offset_of(Gpu_Cull_State, chunk_dispatch)))
}

// Culling and the G-buffer. Phase 0 rasters into the visibility target what
// last frame's depth pyramid says is visible; the pyramid of this frame then
// rescues occlusion-rejected instances and clusters that are visible after
// all (phase 1), so the result is exact with no popping. The material of each
// pixel then runs once (resolve_pass). The pyramid is built before any nested
// view is drawn: it holds the depths of the view alone.
@(private)
pass_gbuffer :: proc(p: ^Pass) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	threads := p.instance_count + p.batch_slots
	occlusion := threads > 0
	keep_depth := occlusion || p.decals || p.draw_glass || p.draw_overlays || p.blend ||
	              stage_asked(r, .Gbuffer) || r.pass_count > 0 && .Nested in p.plan.stages
	clip := p.camera.clip_plane != {}
	glass_groups := [4]u32{groups(t.width, 8), groups(t.height, 8), 0, 0} if p.draw_glass else {}
	p.pyramid_previous = t.hiz_valid
	if r.probe.instance > 0 {r.probe.eye = p.camera.position}
	// The batches the GPU fills draw what the Instances stage of this view writes alone.
	if len(s.batch.counts) > 0 && s.index_buffer != 0 {
		for word in s.batch.counts {rhi.cmd_fill_buffer(cmd, s.index_buffer, u64(word) * 4, 4, 0)}
		if stage_asked(r, .Instances) {stage_run(p, .Instances)}
	}
	rhi.cmd_timestamp(cmd, "cull")
	// What the view before counted, before this one counts its own.
	cull_stats_fold(r, cmd)
	rhi.cmd_fill_buffer(cmd, r.stats_buffer, 0, u64(offset_of(Gpu_Cull_Stats, most_dropped)), 0)
	rhi.cmd_fill_buffer(cmd, p.view.glass_dispatch, 0, 16, 0)
	if !cull_reset(r, cmd, p.instance_count) {return false}
	if threads > 0 {
		cull_record(p, {phase = 0, occlusion = 1 if occlusion && t.hiz_valid else 0, hiz_levels = t.hiz_levels, glass_groups = glass_groups}, t.hiz[p.previous], r.stats_buffer, p.view.glass_dispatch, p.cost, viewmodel = true)
	}
	cull_bins_dispatch(r, cmd, 0)
	rhi.cmd_timestamp(cmd, "visible triangles")
	if p.draw {raster_round_record(r, cmd, 0, false, r.stats_buffer, cost = p.cost)}
	rhi.cmd_timestamp(cmd, "visibility")
	visibility_pass(p, 0, .Clear, .Clear, t.depth, keep_depth, clip)
	if occlusion && p.draw {
		rhi.cmd_timestamp(cmd, "occlusion")
		build_depth_pyramid(p, t.hiz[p.current])
		// Phase 1 hands its own chunks over, from none: a dispatch of x 0, y 0
		// and z 1 (a fill writes bytes, so z is uploaded as a word); its
		// clusters go to the visible list after those of phase 0.
		restart := [4]u32{0, 0, 1, 0}
		if !upload_transient(r, cmd, restart[:], s.cull_state_buffer, u64(offset_of(Gpu_Cull_State, chunk_dispatch))) {return false}
		params := Cull_Params{phase = 1, occlusion = 1, hiz_levels = t.hiz_levels, glass_groups = glass_groups}
		cull_record(p, params, t.hiz[p.current], r.stats_buffer, p.view.glass_dispatch, p.cost)
		if candidates := pipeline_of(r, .Cull_Clusters, {CULL_CLUSTERS_COMP_CANDIDATES})^; candidates != 0 {
			rhi.cmd_bind_pipeline(cmd, candidates)
			cull_bind(p, params, t.hiz[p.current], r.stats_buffer)
			rhi.cmd_dispatch_indirect(cmd, s.cull_state_buffer, u64(offset_of(Gpu_Cull_State, candidate_dispatch)))
		}
		cull_bins_dispatch(r, cmd, 1)
		rhi.cmd_timestamp(cmd, "visible triangles late")
		raster_round_record(r, cmd, 1, false, r.stats_buffer, cost = p.cost)
		rhi.cmd_timestamp(cmd, "visibility late")
		visibility_pass(p, 1, .Load, .Load, t.depth, keep_depth, clip)
		// What found no room in the lists of the rounds of both phases.
		rhi.cmd_timestamp(cmd, "visibility rest")
		for round in u32(2) ..< abi.RASTER_ROUNDS {
			raster_round_record(r, cmd, round, round == abi.RASTER_ROUNDS - 1, r.stats_buffer, cost = p.cost)
			visibility_pass(p, round, .Load, .Load, t.depth, keep_depth, clip)
		}
		// The pyramid the next frame tests against holds what both phases drew:
		// what phase 1 rescued hides what is behind it from the next phase 0.
		rhi.cmd_timestamp(cmd, "depth pyramid")
		build_depth_pyramid(p, t.hiz[p.current])
		t.hiz_valid, p.pyramid = true, true
	} else {
		t.hiz_valid = false
	}
	if p.cost != 0 && p.draw {cost_pixels(p)}
	if p.decals {pass_decals(p)}
	rhi.cmd_timestamp(cmd, "resolve")
	resolve_pass(p, false)
	rest_pass(p)
	if p.first && stage_asked(r, .Simulate) {stage_run(p, .Simulate)}
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
		seen, seen_layered, _ := reflectance_in_frustum(r, nested_frustum(p.frame.frustum, &nested))
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
	if !target(r, nil, &t.nested_depth, t.width, t.height, .D32_Float, {.Depth_Target}, "nested view depth", shared = true) {return false}
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
		constants := rhi.frame_alloc(d, u64(r.frame_layout.size), 256)
		if constants.ptr == nil {set_error(r, "nested view constants: %s", rhi.device_error(d)); return false}
		mem.copy(constants.ptr, p.constants.ptr, r.frame_layout.size)
		mem.copy(constants.ptr, &f, size_of(Gpu_Frame))
		frame_exposure_copy(p, constants)
		rhi.cmd_bind_transient(cmd, SLOT_FRAME, constants)

		// What the nested camera sees, without the pyramid of the view: its depths are of another camera.
		if !cull_reset(r, cmd, p.instance_count) {return false}
		cull_record(p, {phase = 0, hiz_levels = t.hiz_levels}, t.hiz[p.previous], r.scratch_buffer, r.scratch_buffer)
		cull_bins_dispatch(r, cmd, 0)
		if p.draw {raster_round_record(r, cmd, 0, false, r.scratch_buffer)}

		// Its pixels alone pass the depth test of its draws: the farthest depth where the mask named it, the nearest elsewhere.
		prime := rhi.Render_Pass_Desc{name = "nested view pixels"}
		prime.depth = {texture = t.nested_depth, load = .Clear, store = .Store, clear = 1}
		rhi.cmd_begin_render_pass(cmd, &prime)
		Prime_Params :: struct {index, pad0, pad1, pad2: u32}
		prime_params := Prime_Params{index = index}
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Nested_Prime])
		set_params(cmd, &prime_params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.views)
		if nested.rect.z > 0 && nested.rect.w > 0 {
			x, y := clamp(nested.rect.x, 0, i32(t.width)), clamp(nested.rect.y, 0, i32(t.height))
			rhi.cmd_set_scissor(cmd, x, y, u32(clamp(nested.rect.z, 0, i32(t.width) - x)), u32(clamp(nested.rect.w, 0, i32(t.height) - y)))
		}
		rhi.cmd_draw(cmd, 3)
		rhi.cmd_end_render_pass(cmd)

		// Its visibility target holds its own pixels alone, which it resolves over those of the view.
		visibility_pass(p, 0, .Clear, .Load, t.nested_depth, false, true)
		// It has one phase: the rounds after it take what found no room in its lists.
		if p.draw {
			for round in u32(1) ..< abi.RASTER_ROUNDS - 1 {
				raster_round_record(r, cmd, round, round == abi.RASTER_ROUNDS - 2, r.scratch_buffer)
				visibility_pass(p, round, .Load, .Load, t.nested_depth, false, true)
			}
		}
		resolve_pass(p, true)
	}
	bind_scene_table(p)
	return true
}

// The tiles of the direct light a view that draws maps takes after
// direct_maps.comp (abi.DIRECT_TILES_REGIONS).
DIRECT_TILE           :: abi.DIRECT_TILE
DIRECT_SPREAD_RUN     :: abi.DIRECT_SPREAD_RUN
DIRECT_TILES_SAMPLES  :: abi.DIRECT_TILES_SAMPLES
DIRECT_TILES_RAYS     :: abi.DIRECT_TILES_RAYS
DIRECT_TILES_SPREAD   :: abi.DIRECT_TILES_SPREAD
DIRECT_TILES_HEADER   :: abi.DIRECT_TILES_HEADER
DIRECT_TILES_REGIONS  :: abi.DIRECT_TILES_REGIONS

// Shadow rays at a hit of a ray of the probe volume: what it gathers is
// blurred over many rays and probes.
PROBE_LIGHT_BUDGET :: u32(4)

// The direct light of each pixel, the sun and the local lights with their
// shadows (direct_samples.slang): the grid of the lights in the frame one
// changed, the maps of the shadows and the light of what they hold at each
// point, the ray of one point of each square of 2x2 and the samples of each
// point of the lights no map holds, the window and the spread that filter
// them, and the pass that takes them to the pixels, where the sun gives its
// light.
@(private)
pass_direct :: proc(p: ^Pass) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	settings := &r.settings
	scale := u32(2) if settings.direct_half_resolution else 1
	if !ensure_direct_targets(r, cmd, t, scale) {return false}
	if s.light_grid_dirty {
		rhi.cmd_timestamp(cmd, "light grid")
		render_zone(r, "light grid")
		light_grid_record(r, cmd)
		s.light_grid_dirty = false
	}
	Params :: struct {every, samples: u32, sun_radius: f32, scale, hard, pad1, pad2, pad3: u32, grid_origin: Vec3, grid_cell: f32, grid_size: [3]u32, cells: u32, shadow: Shadow_Maps}
	cells := s.light_grid.size.x * s.light_grid.size.y * s.light_grid.size.z
	params := Params{
		every       = 1 if r.direct_every else 0,
		scale       = scale,
		samples     = clamp(settings.direct_samples, 1, DIRECT_SAMPLES_MAX),
		sun_radius  = settings.sun_radius,
		hard        = clamp(settings.light_budget, 1, LIGHT_CUT_MAX),
		grid_origin = s.light_grid.origin,
		grid_cell   = s.light_grid.cell,
		grid_size   = s.light_grid.size,
		cells       = cells if s.light_grid_buffer != 0 else 0,
	}
	points := [2]u32{(t.width + scale - 1) / scale, (t.height + scale - 1) / scale}
	grid := or_dummy(r, s.light_grid_buffer)
	zone := render_zone_begin(r, "shadow maps")
	params.shadow = shadow_maps_pass(p, &params, scale, grid)
	base.profile_end(zone)
	atlas := t.shadow_raster.atlas if params.shadow.on != 0 else r.dummy_texture
	table := r.shadow_buffers.table if params.shadow.on != 0 else r.dummy_buffer
	unlayered := rhi.Shader_Constants{} if p.layered else {DIRECT_MAPS_COMP_UNLAYERED}
	#assert(DIRECT_MAPS_COMP_UNLAYERED == DIRECT_SAMPLES_COMP_UNLAYERED && DIRECT_MAPS_COMP_UNLAYERED == DIRECT_FILTER_COMP_UNLAYERED)
	// The light of what the maps hold, while the view drew them: the samples
	// add the rest where it marks a point (Frame.sun_maps.z, direct_maps.comp),
	// and the passes after take only the tiles it lists; else all of them.
	maps := p.frame.sun_maps.z != 0
	tiles := t.direct_tiles
	tiles_across := [2]u32{groups(points.x, DIRECT_TILE), groups(points.y, DIRECT_TILE)}
	// What the samples leave at each point and what the window of the pattern
	// gives it: while the view draws maps, direct_maps.comp writes the points,
	// and the window takes only the tiles that take samples, into the other
	// two, and gives them back.
	samples, sun := t.direct_samples, t.direct_sun
	windowed, sun_windowed := t.direct_points, t.direct_sun_points
	if maps {samples, sun, windowed, sun_windowed = windowed, sun_windowed, samples, sun}
	if maps {
		rhi.cmd_timestamp(cmd, "direct tiles")
		header := [DIRECT_TILES_HEADER]u32{DIRECT_TILES_SAMPLES + 1 = 1, DIRECT_TILES_SAMPLES + 2 = 1, DIRECT_TILES_RAYS + 1 = 1, DIRECT_TILES_RAYS + 2 = 1, DIRECT_TILES_SPREAD + 1 = DIRECT_SPREAD_RUN, DIRECT_TILES_SPREAD + 2 = 1}
		if !upload_transient(r, cmd, header[:], tiles) {return false}
		// Whether each tile of rays and each block is listed: the first words
		// of their regions.
		region := u64(tiles_across.x * tiles_across.y) * size_of(u32)
		rays := u64(groups(tiles_across.x, 2) * groups(tiles_across.y, 2)) * size_of(u32)
		run := u32(DIRECT_SPREAD_RUN / DIRECT_TILE)
		rhi.cmd_fill_buffer(cmd, tiles, DIRECT_TILES_HEADER * size_of(u32), rays, 0)
		rhi.cmd_fill_buffer(cmd, tiles, DIRECT_TILES_HEADER * size_of(u32) + region, u64(groups(tiles_across.x, run) * groups(tiles_across.y, run)) * size_of(u32), 0)
		rhi.cmd_timestamp(cmd, "direct maps")
		rhi.cmd_bind_pipeline(cmd, pipeline_of(r, .Direct_Maps, unlayered, unlayered)^)
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, samples)
		rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.albedo)
		rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.direct_depth)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS6, grid)
		rhi.cmd_bind_texture(cmd, SLOT_PASS7, sun)
		rhi.cmd_bind_texture(cmd, SLOT_PASS8, atlas)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS9, table)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS4, tiles)
		rhi.cmd_dispatch(cmd, tiles_across.x, tiles_across.y)
	}
	rhi.cmd_timestamp(cmd, "direct rays")
	rhi.cmd_bind_pipeline(cmd, pipeline_of(r, .Direct_Rays)^)
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.direct_blockers)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS6, grid)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS9, table)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, tiles)
	// A thread for each square of 2x2 points, and a group of the samples for
	// each 4x4 of them (direct_group_pixel), a tile.
	squares := (points.x + 1) / 2
	if maps {
		rhi.cmd_dispatch_indirect(cmd, tiles, DIRECT_TILES_RAYS * size_of(u32))
	} else {
		rhi.cmd_dispatch(cmd, groups(squares, 8), groups((points.y + 1) / 2, 8))
	}
	rhi.cmd_timestamp(cmd, "direct samples")
	rhi.cmd_bind_pipeline(cmd, pipeline_of(r, .Direct_Samples, unlayered, {DIRECT_SAMPLES_COMP_UNLAYERED})^)
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, samples)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.albedo)
	rhi.cmd_bind_texture(cmd, SLOT_DIRECT_BLOCKERS, t.direct_blockers)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, tiles)
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.direct_depth)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS6, grid)
	rhi.cmd_bind_texture(cmd, SLOT_PASS7, sun)
	rhi.cmd_bind_texture(cmd, SLOT_PASS8, atlas)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS9, table)
	if maps {
		rhi.cmd_dispatch_indirect(cmd, tiles, DIRECT_TILES_SAMPLES * size_of(u32))
	} else {
		rhi.cmd_dispatch(cmd, groups(squares, 4), groups(points.y, 8))
	}
	// What the window of the pattern gives each point.
	rhi.cmd_timestamp(cmd, "direct points")
	Window :: struct {scale, samples, back, pad1: u32}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Direct_Points])
	for back in u32(0) ..= (1 if maps else 0) {
		window := Window{scale = scale, samples = params.samples, back = back}
		set_params(cmd, &window)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS2, tiles)
		rhi.cmd_bind_texture(cmd, SLOT_PASS4, windowed if back != 0 else samples)
		rhi.cmd_bind_texture(cmd, SLOT_PASS5, sun_windowed if back != 0 else sun)
		rhi.cmd_bind_texture(cmd, SLOT_PASS6, samples if back != 0 else windowed)
		rhi.cmd_bind_texture(cmd, SLOT_PASS7, sun if back != 0 else sun_windowed)
		if maps {
			rhi.cmd_dispatch_indirect(cmd, tiles, DIRECT_TILES_SAMPLES * size_of(u32))
		} else {
			rhi.cmd_dispatch(cmd, groups(points.x, 8), groups(points.y, 8))
		}
	}
	rhi.cmd_timestamp(cmd, "direct spread")
	Spread :: struct {axis, scale, samples, even: u32}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Direct_Spread])
	for axis in u32(0) ..< 2 {
		spread := Spread{axis = axis, scale = scale, samples = params.samples, even = 1 if params.shadow.on != 0 else 0}
		set_params(cmd, &spread)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.direct_spread)
		rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.direct_points)
		rhi.cmd_bind_texture(cmd, SLOT_PASS4, t.direct_sun_points)
		rhi.cmd_bind_texture(cmd, SLOT_PASS6, t.direct_depth)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS5, tiles)
		// A group for each run along the axis of each block of
		// DIRECT_SPREAD_RUN points a side.
		if maps {
			rhi.cmd_dispatch_indirect(cmd, tiles, DIRECT_TILES_SPREAD * size_of(u32))
		} else {
			rhi.cmd_dispatch(cmd, groups(points.x, DIRECT_SPREAD_RUN), DIRECT_SPREAD_RUN, groups(points.y, DIRECT_SPREAD_RUN))
		}
	}
	zone = render_zone_begin(r, "light lists")
	lists, listed := light_lists_record(p)
	base.profile_end(zone)
	if !listed {return false}
	rhi.cmd_timestamp(cmd, "direct pixels")
	filter := unlayered + ({} if lights_listed(p.frame) else {DIRECT_FILTER_COMP_UNLISTED}) + ({} if p.subsurface else {DIRECT_FILTER_COMP_UNSCATTERED})
	rhi.cmd_bind_pipeline(cmd, pipeline_of(r, .Direct_Filter, filter, {DIRECT_FILTER_COMP_UNLAYERED, DIRECT_FILTER_COMP_UNLISTED, DIRECT_FILTER_COMP_UNSCATTERED})^)
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.direct)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.albedo)
	rhi.cmd_bind_texture(cmd, SLOT_PASS4, t.direct_sun_points)
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.direct_marks)
	rhi.cmd_bind_texture(cmd, SLOT_PASS6, t.subsurface[0] if p.subsurface else r.dummy_texture)
	rhi.cmd_bind_texture(cmd, SLOT_PASS7, t.direct_points)
	rhi.cmd_bind_texture(cmd, SLOT_PASS8, atlas)
	rhi.cmd_bind_texture(cmd, SLOT_LIGHT_LISTS, lists)
	rhi.cmd_dispatch(cmd, groups(t.width, 8), groups(t.height, 8))
	p.scattered = p.subsurface
	return true
}

// Updates over PROBE_WARM_BUDGET probes that gather the light of a world shown
// anew (Renderer.gi_warm), each a bounce more, taken over the frames after
// within the budget of each (ddgi_warm_frames).
GI_WARM_UPDATES :: 64

// What lights the world whatever the view: the probe volume, updated once a
// frame with its first view, within the budget of a frame: no frame, the
// first of a world either, traces more than another may, whatever else the
// GPU runs. A world shown anew and a blackout gather their light over the
// frames after, each update taking every probe in turn (whole).
@(private)
pass_world_lighting :: proc(p: ^Pass) -> bool {
	r, cmd := p.r, p.cmd
	g := &r.ddgi
	changes := &r.scene.changes
	update_gi := p.first && (!p.offscreen || p.settle_gi)
	if p.first {ground_bake(p)}
	if update_gi && p.use_gi {
		if changes.count > 0 && !changes.all && !upload_transient(r, cmd, changes.spheres[:changes.count], r.light_changes) {return false}
		if r.gi_warm {r.gi_warm_spread = max(r.gi_warm_spread, ddgi_warm_frames(g, GI_WARM_UPDATES))}
		r.gi_warm = false
		warm := r.gi_warm_spread > 0
		if warm {r.gi_warm_spread -= 1}
		if p.use_probes && g.valid {
			rhi.cmd_timestamp(cmd, "ddgi")
			if !ddgi_update(p, warm) {return false}
		}
		r.light_frame += 1
	}
	if p.use_probes && update_gi {
		// Later passes sample the updated atlases through the scene table.
		rhi.cmd_bind_texture(cmd, SLOT_IRRADIANCE, g.irradiance)
		rhi.cmd_bind_texture(cmd, SLOT_DISTANCE, g.distance)
	}
	if update_gi {
		r.frame_changes = changes^
		changes^ = {}
	}
	return true
}

// The light around each pixel beside the probe volume, which the composition
// reads at each pixel: its contact occlusion.
@(private)
pass_indirect :: proc(p: ^Pass) -> bool {
	if !p.use_gi {
		p.gi = p.r.dummy_texture
		return true
	}
	return pass_contact(p)
}

// The contact occlusion of each point (contact.comp) and the light of the
// probe volume there (contact_light.comp), which contact_pixels.comp takes to
// the pixels: the composition takes it in p.gi.
// Rays of each point.
CONTACT_RAYS :: abi.CONTACT_RAYS
@(private)
pass_contact :: proc(p: ^Pass) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	// A point for each 2x2 pixels with the direct light at half resolution.
	scale := u32(2) if r.settings.direct_half_resolution else 1
	if t.contact != 0 && t.contact_scale != scale {
		rhi.device_wait_idle(r.device)
		destroy_gi_targets(r, t)
	}
	t.contact_scale = scale
	points := [2]u32{(t.width + scale - 1) / scale, (t.height + scale - 1) / scale}
	ok := target(r, cmd, &t.contact_rays, points.x, points.y, .RGBA16_Float, {.Sampled, .Storage}, "contact rays", shared = true)
	ok &&= target(r, cmd, &t.contact_points[0], points.x, points.y, .RGBA16_Float, {.Sampled, .Storage}, "contact light", shared = true)
	ok &&= target(r, cmd, &t.contact_points[1], points.x, points.y, .RGBA16_Float, {.Sampled, .Storage}, "contact specular", shared = true)
	ok &&= target(r, cmd, &t.contact, t.width, t.height, .RG32_Float, {.Sampled, .Storage}, "contact", shared = true)
	if !ok {return false}
	Params :: struct {scale, pad0, pad1, pad2: u32}
	params := Params{scale = scale}
	rhi.cmd_timestamp(cmd, "contact")
	rhi.cmd_bind_pipeline(cmd, pipeline_of(r, .Contact)^)
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.contact_rays)
	rhi.cmd_dispatch(cmd, groups(points.x, 8), groups(points.y, 8))
	rhi.cmd_timestamp(cmd, "contact light")
	rhi.cmd_bind_pipeline(cmd, pipeline_of(r, .Contact_Light, {} if p.layered else {CONTACT_LIGHT_COMP_UNLAYERED}, {CONTACT_LIGHT_COMP_UNLAYERED})^)
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.contact_points[0])
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.contact_points[1])
	rhi.cmd_dispatch(cmd, groups(points.x, 8), groups(points.y, 8))
	rhi.cmd_timestamp(cmd, "contact pixels")
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Contact_Pixels])
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.contact_rays)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.contact)
	rhi.cmd_bind_texture(cmd, SLOT_PASS4, t.contact_points[0])
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.contact_points[1])
	rhi.cmd_dispatch(cmd, groups(t.width, 8), groups(t.height, 8))
	p.gi, p.gathered = t.contact, true
	return true
}

// The lit image of the opaque scene, in t.display, where the mode
// of inspection of the view replaces it.
@(private)
pass_composite :: proc(p: ^Pass) {
	r, cmd, t := p.r, p.cmd, p.t
	rhi.cmd_timestamp(cmd, "composite")
	constants := ({} if p.layered else rhi.Shader_Constants{COMPOSITE_COMP_UNLAYERED}) + ({} if p.subsurface else {COMPOSITE_COMP_UNSCATTERED})
	rhi.cmd_bind_pipeline(cmd, pipeline_of(r, .Composite, constants, {COMPOSITE_COMP_UNLAYERED, COMPOSITE_COMP_UNSCATTERED})^)
	Params :: struct {gathered, scattered, pad1, pad2: u32}
	params := Params{gathered = u32(p.gathered), scattered = u32(p.scattered)}
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.albedo)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.emission)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS4, t.direct)
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, p.gi)
	rhi.cmd_bind_texture(cmd, SLOT_PASS6, t.subsurface[0] if p.subsurface else r.dummy_texture)
	rhi.cmd_bind_texture(cmd, SLOT_PASS7, t.motion)
	rhi.cmd_bind_texture(cmd, SLOT_PASS8, t.display)
	rhi.cmd_dispatch(cmd, groups(t.width, 8), groups(t.height, 8))
	if p.subsurface {pass_subsurface(p)}
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
	if !p.draw_glass || !stage_asked(p.r, .Lit) {
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
pass_transparent :: proc(p: ^Pass) -> bool {
	if p.draw_overlays {overlay_pass(p)}
	distortion_targets_settle(p.r, p.t)
	if p.draw_glass {
		if !p.glass_layered {glass_layers(p)}
		if p.blend {side_run(p, .Blend, .Behind)}
		if !glass_shade(p) {return false}
		if p.glass_layered {side_run(p, .Lit, .Front)}
		glass_inside(p)
		translucent_forward(p, 0, p.t.glass[0].depth)
		if p.blend {side_run(p, .Blend, .Front)}
	} else {
		translucent_forward(p, 0, 0)
		if p.blend {side_run(p, .Blend, .All)}
	}
	p.t.distorted = p.distortion_drawn
	// Without a Blend pass the mask of the frame is zero, as a pass that replaces the Resolve stage reads it.
	if p.blended {p.t.reactive_drawn = true} else if p.t.reactive_drawn {
		clear_textures(p.cmd, p.t.reactive)
		p.t.reactive_drawn = false
	}
	return true
}

@(private)
side_run :: proc(p: ^Pass, stage: Frame_Stage, side: Glass_Side) {
	p.glass = side
	stage_run(p, stage)
	if stage == .Blend {distortion_apply(p)}
	p.glass = .All
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
	// Of the Direct stage of this frame: a custom pass in its place leaves none.
	marks := .Direct in p.plan.stages && t.direct_marks != 0
	params := Params{history_valid = 1 if t.taa_valid else 0, feedback = 0.1, clip_gamma = 1.25, reactive = 1 if p.blended else 0, shadows = 1 if marks else 0}
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
	rhi.cmd_bind_texture(cmd, SLOT_PASS8, t.direct_marks if marks else r.dummy_texture)
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
	if s.highlighted > 0 && !p.texture {highlight_bounds = highlight_screen_bounds(s, &p.frame, points, {f32(t.highlight_width), f32(t.highlight_height)}, glow)}
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
	thumbnails := r.thumbnails if r.thumbnails != 0 else r.dummy_texture
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
		open = overlays && (!p.texture || len(frame.debug) > 0)
		if open {
			rhi.cmd_timestamp(cmd, "ui")
			ldr_pass.colors[0].load = .Load
			ldr_pass.name = "editor UI"
			rhi.cmd_begin_render_pass(cmd, &ldr_pass)
		}
	}
	if !p.texture && overlays {overlays_draw(p, frame, ui_written, points, thumbnails)}
	if p.texture && overlays {debug_lines_pass(r, cmd, t, p.slot, frame.debug)}
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
	s.view_target_bytes = r.texture_view_bytes
	s.geometry_bytes = geometry_pool_bytes(r)
	s.geometry_free, s.geometry_free_largest = geometry_pool_free(&r.scene)
	s.ray_bytes, _ = rhi.accel_memory(r.device)
	s.textures_reduced = u32(r.textures.reduced + r.textures.residency.reduced)
	s.textures_pending = u32(r.textures.residency.pending)
	s.lights = u32(len(r.scene.lights))
	s.light_sets = r.scene.light_revision
	pages_stats(r, s)
	geometry := geometry_refused_problem(r, r.problem_buffer[:])
	s.problem = geometry
	memory := ""
	if host := rhi.device_stats(r.device).host_memory; host > 0 {
		memory = fmt.tprintf("%d resources of GPU memory went to system memory because the device memory was full, which slows the frames: a lower resolution or texture quality frees device memory", host)
	}
	waiting := fmt.tprintf("the pass of the stage %s is skipped while its pipeline is made", r.pipeline_waiting) if r.pipeline_waiting != "" else ""
	for other in ([]string{r.tlas_problem, pages_problem(r), memory, r.pipeline_problem, r.program_problem, waiting}) {
		if other == "" {continue}
		if s.problem == "" {s.problem = string(r.problem_buffer[:copy(r.problem_buffer[:], other)]); continue}
		// The problems before are at the start of problem_buffer: this one follows them.
		if raw_data(s.problem) != raw_data(r.problem_buffer[:]) {s.problem = string(r.problem_buffer[:copy(r.problem_buffer[:], s.problem)])}
		tail := fmt.bprintf(r.problem_buffer[len(s.problem):], "; %s", other)
		s.problem = string(r.problem_buffer[:len(s.problem) + len(tail)])
	}
	s.probes = r.ddgi.total if r.ddgi.valid else 0
	s.probes_per_frame = r.ddgi.budget if r.ddgi.valid else 0
	pixels := u64(t.width) * u64(t.height)
	points :: proc(t: ^Targets, scale: u32) -> u64 {
		scale := max(scale, 1)
		return u64((t.width + scale - 1) / scale) * u64((t.height + scale - 1) / scale)
	}
	// A point traces its samples, and a square of 2x2 points a ray.
	samples := u64(clamp(r.settings.direct_samples, 1, DIRECT_SAMPLES_MAX))
	rays := points(t, t.direct_scale) * (4 * samples + 1) / 4
	if r.settings.gi_enabled {
		// The rays the probes traced, and the sun and the lights of its cut at each hit they lit.
		rays += u64(s.probe_rays_traced) + u64(s.probe_hits_lit) * u64(1 + min(s.lights, PROBE_LIGHT_BUDGET))
		// The contact occlusion: CONTACT_RAYS short rays of each point.
		rays += points(t, t.contact_scale) * CONTACT_RAYS
	}
	s.rays_per_frame = rays
}

renderer_stats :: proc(r: ^Renderer) -> ^Stats {return &r.stats}

RENDER_GPU_SUBMISSIONS :: 8   // whose timings wait between two renderer_gpu_clear
RENDER_GPU_TIMINGS :: 1024

// The GPU timings of one submission of the device, copied out of it, which
// reuses its own at the next frame.
Gpu_Submission :: struct {
	frame:   u64, // the rhi.frame_number it was
	timings: []rhi.Gpu_Timing,
}

Gpu_Submissions :: struct {
	list:         [RENDER_GPU_SUBMISSIONS]Gpu_Submission,
	count:        int,
	timings:      [RENDER_GPU_TIMINGS]rhi.Gpu_Timing,
	names:        [RENDER_GPU_TIMINGS][rhi.MAX_TIMESTAMP_NAME_BYTES]u8,
	timing_count: int,
	kept_end:     u64, // one past the rhi frame of the last submission seen
}

// The submissions whose GPU timings came back since renderer_gpu_clear, in
// the order they were submitted. A host frame may submit several (captures,
// thumbnails); whoever accounts for each one takes them every frame and
// clears them. A submission that does not fit is left out.
renderer_gpu_submissions :: proc(r: ^Renderer) -> []Gpu_Submission {return r.submissions.list[:r.submissions.count]}

renderer_gpu_clear :: proc(r: ^Renderer) {r.submissions.count, r.submissions.timing_count = 0, 0}

@(private)
gpu_submission_keep :: proc(r: ^Renderer) {
	timings, frame, measured := rhi.frame_timings(r.device)
	g := &r.submissions
	// A frame_begin that fails before the device collects leaves the timings of the one before.
	if !measured || frame < g.kept_end {return}
	g.kept_end = frame + 1
	if g.count >= len(g.list) || g.timing_count + len(timings) > len(g.timings) {return}
	first := g.timing_count
	for timing, i in timings {
		k := first + i
		g.timings[k] = timing
		g.timings[k].name = string(g.names[k][:copy(g.names[k][:], timing.name)])
	}
	g.timing_count += len(timings)
	g.list[g.count] = {frame, g.timings[first:g.timing_count]}
	g.count += 1
}

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
