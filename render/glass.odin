package mirai_render

import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:asset"
import "mirai:render/abi"
import "mirai:rhi"
import mm "mirai:std/math"

GLASS_LAYERS_MAX :: 2

Glass_Layer :: struct {
	albedo:   rhi.Texture, // rgb base color, a metallic
	normal:   rhi.Texture, // xyz shading normal, a roughness
	emission: rhi.Texture, // rgb emission, a alpha
	ids:      rhi.Texture, // material row, instance
	depth:    rhi.Texture, // linear view depth; 0 where the layer is empty
	surface:  rhi.Texture, // evaluated F0 RGB and F90
	layers:   rhi.Texture, // the layers of the material (gbuffer_layers_pack), while a blended instance has them
}

@(private)
glass_layer_count :: proc "contextless" (r: ^Renderer) -> int {return int(clamp(r.settings.glass_layers, 1, GLASS_LAYERS_MAX))}

@(private)
ensure_glass_targets :: proc(r: ^Renderer, t: ^Targets) -> bool {
	present, layered := false, false
	for entry in r.scene.translucent {
		present ||= entry.glass
		layered ||= entry.layered
	}
	if !present {return true}
	attachment := rhi.Texture_Usage{.Color_Target, .Sampled}
	for &layer in t.glass[:glass_layer_count(r)] {
		if !target(r, nil, &layer.albedo, t.width, t.height, .RGBA8_Srgb, attachment, "glass albedo") ||
		   !target(r, nil, &layer.normal, t.width, t.height, .RGBA16_Float, attachment, "glass normal") ||
		   !target(r, nil, &layer.emission, t.width, t.height, .RGBA16_Float, attachment, "glass emission") ||
		   !target(r, nil, &layer.ids, t.width, t.height, .RG32_Uint, attachment, "glass ids") ||
		   !target(r, nil, &layer.depth, t.width, t.height, .R32_Float, attachment, "glass depth") ||
		   !target(r, nil, &layer.surface, t.width, t.height, .RGBA8_Srgb, attachment, "glass surface") ||
		   layered && !target(r, nil, &layer.layers, t.width, t.height, .RGBA32_Uint, attachment, "glass material layers") {
			return false
		}
	}
	if t.glass_scene == 0 {
		t.glass_scene = rhi.texture_create(r.device, {
			width = t.width, height = t.height, format = .RGBA16_Float, usage = HISTORY_USAGE,
			mip_levels = glass_scene_levels(t), name = "glass scene",
		})
		if t.glass_scene == 0 {set_error(r, "glass scene: %s", rhi.device_error(r.device)); return false}
	}
	return target(r, nil, &t.glass_zbuffer, t.width, t.height, .D32_Float, {.Depth_Target}, "glass z")
}

// Every texture of the glass of a view, made or not.
@(private)
glass_textures :: proc(t: ^Targets) -> (all: [GLASS_LAYERS_MAX * 7 + 2]rhi.Texture) {
	for layer, i in t.glass {
		each := [7]rhi.Texture{layer.albedo, layer.normal, layer.emission, layer.ids, layer.depth, layer.surface, layer.layers}
		copy(all[i * 7:], each[:])
	}
	rest := [2]rhi.Texture{t.glass_zbuffer, t.glass_scene}
	copy(all[GLASS_LAYERS_MAX * 7:], rest[:])
	return
}

@(private)
destroy_glass_targets :: proc(r: ^Renderer, t: ^Targets) {
	for tex in glass_textures(t) {if tex != 0 {rhi.texture_destroy(r.device, tex)}}
	t.glass, t.glass_zbuffer, t.glass_scene = {}, 0, 0
}

// m over the top of a solid within which the pixels of a view near it decide whether they start in it
// (glass_pass.slang Params_Block.near_top).
GLASS_MEDIUM_NEAR :: f32(0.25)

// The solid blended instance under the top of whose box the camera is, within its sides, plus one: the smallest
// of them, the one further in, by its box down to the camera when the camera is below it. Under, not only
// inside: under a sheet open below, as the surface of water, is inside it. The glass passes find whether
// the camera is in its solid; 0 when it is under none. row: that of the material of its medium.
@(private)
glass_medium :: proc(r: ^Renderer, camera: Vec3) -> (medium, row: u32) {
	smallest := max(f32)
	for entry in r.scene.translucent {
		if entry.medium == 0 {continue}
		inst := &r.scene.instances[entry.instance]
		lo, hi := inst.bounds_min.xyz, inst.bounds_max.xyz
		if camera.x < lo.x || camera.z < lo.z || camera.x > hi.x || camera.y > hi.y + GLASS_MEDIUM_NEAR || camera.z > hi.z {continue}
		size := hi - lo
		if volume := size.x * size.z * (hi.y - min(lo.y, camera.y)); volume < smallest {smallest, medium, row = volume, entry.instance + 1, entry.medium - 1}
	}
	return
}

// Partitions the scene list in place. Only the visible prefix is sorted and drawn.
@(private)
glass_visible :: proc(s: ^Scene_State, frame: ^Gpu_Frame) -> []Translucent {
	frustum := transmute(mm.Frustum)frame.frustum
	count := 0
	for &entry, i in s.translucent {
		inst := &s.instances[entry.instance]
		flags := inst.meta.w
		layers := flags >> INSTANCE_LAYERS_SHIFT
		owner := frame.own & 0xff
		own := owner != 0 && flags & INSTANCE_FLAG_OWNED != 0 &&
		       (flags >> INSTANCE_OWNER_SHIFT) & 3 == owner - 1
		if layers & frame.layers & LAYERS_ALL == 0 ||
		   own && (layers & (frame.layers >> 16) != 0 || frame.own >> 16 == 65535) ||
		   instance_values_fade(s, inst.material_values) >= 1 {continue}
		if !mm.frustum_overlaps_aabb(frustum, {inst.bounds_min.xyz, inst.bounds_max.xyz}) {continue}
		offset := (inst.bounds_min.xyz + inst.bounds_max.xyz) * 0.5 - frame.camera_position.xyz
		entry.distance = linalg.dot(offset, offset)
		s.translucent[count], s.translucent[i] = s.translucent[i], s.translucent[count]
		count += 1
	}
	visible := s.translucent[:count]
	slice.sort_by(visible, proc(a, b: Translucent) -> bool {
		return a.distance > b.distance || a.distance == b.distance && a.instance < b.instance
	})
	return visible
}

@(private)
translucency_in_frustum :: proc(p: ^Pass, f: ^Gpu_Frame) {
	p.translucent = glass_visible(&p.r.scene, f)
	for entry in p.translucent {
		p.draw_forward ||= entry.forward
		p.draw_glass ||= entry.glass
		p.glass_material_layers ||= entry.layered
		p.glass_rough ||= entry.glass && !entry.glass_smooth
	}
	translucent_before_glass(p, f)
}

// Tiles per side of the screen over which a view keeps the nearest glass.
GLASS_TILES :: 32

// Marks the blended instances of the view nearer than every glass in the tiles
// they cover: no layer is in front of them, so only the raster in front of the
// nearest layer has fragments of them to draw.
@(private = "file")
translucent_before_glass :: proc(p: ^Pass, f: ^Gpu_Frame) {
	if !p.draw_glass || !p.draw_forward {return}
	s := &p.r.scene
	eye, forward := f.camera_position.xyz, f.camera_forward.xyz
	margin := 2 / linalg.max(f.resolution, Vec2{1, 1})
	// The nearest and farthest view depth (fragment_depth) of a box and the tiles it covers.
	span :: proc(inst: ^Gpu_Instance, f: ^Gpu_Frame, eye, forward: Vec3, margin: Vec2) -> (near, far: f32, lo, hi: [2]int) {
		box := mm.Aabb{inst.bounds_min.xyz, inst.bounds_max.xyz}
		along := linalg.dot((box.min + box.max) * 0.5 - eye, forward)
		reach := linalg.dot((box.max - box.min) * 0.5, linalg.abs(forward))
		rect := projected_box(box, f.view_proj, eye)
		if !(rect.x <= rect.z && rect.y <= rect.w) {rect = {0, 0, 1, 1}}
		for axis in 0 ..< 2 {
			lo[axis] = clamp(int(math.floor((rect[axis] - margin[axis]) * GLASS_TILES)), 0, GLASS_TILES - 1)
			hi[axis] = clamp(int(math.floor((rect[axis + 2] + margin[axis]) * GLASS_TILES)), lo[axis], GLASS_TILES - 1)
		}
		return along - reach, along + reach, lo, hi
	}
	nearest: [GLASS_TILES * GLASS_TILES]f32
	if p.draw_glass && p.draw_forward {
		slice.fill(nearest[:], max(f32))
		for entry in p.translucent {
			if !entry.glass {continue}
			near, _, lo, hi := span(&s.instances[entry.instance], f, eye, forward, margin)
			for y in lo.y ..= hi.y {
				for &tile in nearest[y * GLASS_TILES:][lo.x:hi.x + 1] {tile = min(tile, near)}
			}
		}
	}
	for &entry in p.translucent {
		entry.before = false
		if !p.draw_glass || !entry.forward {continue}
		_, far, lo, hi := span(&s.instances[entry.instance], f, eye, forward, margin)
		entry.before = true
		rows: for y in lo.y ..= hi.y {
			for tile in nearest[y * GLASS_TILES:][lo.x:hi.x + 1] {
				if !(far < tile) {entry.before = false; break rows}
			}
		}
	}
}

// The indirect draw of each entry of p.translucent (translucent_draws.comp),
// once a frame of the view and outside a render pass: the levels of its mesh
// its cut can take, or none where the depth pyramid of this frame hides it.
@(private)
translucent_draws_record :: proc(p: ^Pass) -> bool {
	if p.translucent_drawn {return true}
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	count := len(p.translucent)
	if count == 0 || count > s.translucent_draws_capacity {return false}
	instances := rhi.frame_alloc(r.device, u64(count) * size_of(u32), 16)
	if instances.ptr == nil {return false}
	for entry, k in p.translucent {([^]u32)(instances.ptr)[k] = entry.instance}
	// The cells of those split for shadowless lights, a thread each, in a pass after; skipped without shadowless lights.
	shadowless := p.frame.shadowless_lights != 0
	cells := pipeline_of(r, .Translucent_Draws, {TRANSLUCENT_DRAWS_COMP_CELLS})^ if shadowless else 0
	Params :: struct {count, hiz_levels, occlusion, cells, split, pad0, pad1, pad2: u32}
	params := Params{
		count = u32(count), hiz_levels = t.hiz_levels, occlusion = 1 if p.pyramid else 0,
		cells = u32(s.translucent_draws_capacity), split = 1 if cells != 0 else 0,
	}
	if cells != 0 {rhi.cmd_fill_buffer(cmd, s.translucent_cell_jobs, 0, size_of([2]u32), 0)}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Translucent_Draws])
	set_params(cmd, &params)
	rhi.cmd_bind_transient(cmd, SLOT_PASS0, instances)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.hiz[p.current] if p.pyramid else r.dummy_texture)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS2, s.translucent_draws)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, s.translucent_lists)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, s.translucent_entries)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS5, s.translucent_cell_jobs)
	rhi.cmd_dispatch(cmd, groups(u32(count), 64))
	if cells != 0 {
		rhi.cmd_bind_pipeline(cmd, cells)
		rhi.cmd_dispatch(cmd, groups(abi.TRANSLUCENT_CELLS, 64))
	}
	p.translucent_drawn = true
	return true
}

// Consecutive entries of p.translucent drawn with one pipeline and program,
// as one indirect draw of all of them.
@(private = "file")
Translucent_Run :: struct {
	pipeline: rhi.Pipeline,
	program, first, count: u32,
}

@(private = "file")
translucent_run_end :: proc(p: ^Pass, run: ^Translucent_Run, plain: rhi.Transient) {
	if run.count == 0 {return}
	cmd := p.cmd
	rhi.cmd_bind_pipeline(cmd, run.pipeline)
	if run.program == 0 {rhi.cmd_bind_transient(cmd, SLOT_DRAW, plain)} else {
		drawn := [4]u32{run.program, 0, 0, 0}
		rhi.cmd_set_constants(cmd, SLOT_DRAW, &drawn, size_of(drawn))
	}
	rhi.cmd_draw_indexed_indirect(cmd, p.r.scene.translucent_draws, u64(run.first) * size_of(rhi.Draw_Indexed_Indirect), run.count)
	run.count = 0
}

// The draws of the blended programs of entry k with the stage of target.
@(private = "file")
translucent_entry_draw :: proc(p: ^Pass, run: ^Translucent_Run, target: ^rhi.Pipeline, k: int, plain: rhi.Transient) {
	entry := p.translucent[k]
	if !entry.multi_program {
		program := entry.program
		pipeline := program_graphics(p.r, target, program)
		if run.count > 0 && (run.pipeline != pipeline || run.program != program || run.first + run.count != u32(k)) {
			translucent_run_end(p, run, plain)
		}
		if run.count == 0 {run^ = {pipeline = pipeline, program = program, first = u32(k)}}
		run.count += 1
		return
	}
	programs, count := instance_blended_programs(&p.r.scene, entry.instance)
	for program in programs[:count] {
		pipeline := program_graphics(p.r, target, program)
		if run.count > 0 && (run.pipeline != pipeline || run.program != program || run.first + run.count != u32(k)) {
			translucent_run_end(p, run, plain)
		}
		if run.count == 0 {run^ = {pipeline = pipeline, program = program, first = u32(k)}}
		run.count += 1
	}
}

// Split between complete instances so the command count stays within the pass bound.
@(private = "file")
glass_raster :: proc(p: ^Pass, pass: ^rhi.Render_Pass_Desc, target: ^rhi.Pipeline) {
	r, cmd := p.r, p.cmd
	s := &r.scene
	#assert(3 * asset.MESH_MAX_SLOTS <= rhi.MAX_RENDER_PASS_COMMANDS)
	plain := rhi.frame_alloc(r.device, 4 * size_of(u32))
	if plain.ptr == nil {return}
	(^[4]u32)(plain.ptr)^ = {}
	rhi.cmd_bind_index_buffer(cmd, s.mesh_draws)
	rhi.cmd_begin_render_pass(cmd, pass)
	commands := 0
	run: Translucent_Run
	for entry, k in p.translucent {
		if !entry.glass {continue}
		needed := 3 * (int(entry.slots) if entry.multi_program else 1)
		if commands + needed > rhi.MAX_RENDER_PASS_COMMANDS {
			translucent_run_end(p, &run, plain)
			rhi.cmd_end_render_pass(cmd)
			for &color in pass.colors[:pass.color_count] {color.load = .Load}
			pass.depth.load = .Load
			rhi.cmd_begin_render_pass(cmd, pass)
			commands = 0
		}
		translucent_entry_draw(p, &run, target, k, plain)
		commands += needed
	}
	translucent_run_end(p, &run, plain)
	rhi.cmd_end_render_pass(cmd)
}

@(private)
glass_layers :: proc(p: ^Pass) {
	r, cmd, t := p.r, p.cmd, p.t
	p.glass_medium, p.glass_medium_row = glass_medium(r, p.camera.position)
	rhi.cmd_timestamp(cmd, "glass layers")
	if !translucent_draws_record(p) {return}
	for k in 0 ..< glass_layer_count(r) {
		layer := t.glass[k]
		nearer := t.glass[k - 1].depth if k > 0 else r.dummy_texture
		layered := p.glass_material_layers
		pass := rhi.Render_Pass_Desc{color_count = 7 if layered else 6, name = "glass layer"}
		for target, i in ([7]rhi.Texture{layer.albedo, layer.normal, layer.emission, layer.ids, layer.depth, layer.surface, layer.layers}) {
			if i < int(pass.color_count) {pass.colors[i] = {texture = target, load = .Clear, store = .Store}}
		}
		// From the depth of the opaque scene: what it hides fails the test before its fragment runs.
		rhi.cmd_copy_texture(cmd, t.depth, t.glass_zbuffer)
		pass.depth = {texture = t.glass_zbuffer, load = .Load, store = .Store}
		Params :: struct {peeled, medium, pad1, pad2: u32}
		params := Params{peeled = u32(k), medium = p.glass_medium}
		target := &r.pipelines[.Glass_Layer_Layers if layered else .Glass_Layer]
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.linear_depth)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, nearer)
		textures_feedback_bind(r, cmd)
		glass_raster(p, &pass, target)
	}
}

// The blended surfaces between two glass layers (0: none), back to front,
// tested against the depth of the opaque scene; overflow: also the glass
// beyond the layers. Those before the glass are drawn only in front of it.
@(private)
translucent_forward :: proc(p: ^Pass, near_layer, far_layer: rhi.Texture, overflow := false) {
	if !p.draw_forward && !overflow {return}
	r, cmd, t := p.r, p.cmd, p.t
	rhi.cmd_timestamp(cmd, "translucent")
	if !translucent_draws_record(p) {return}
	s := &r.scene
	#assert((3 * asset.MESH_MAX_SLOTS + 1) * 3 <= rhi.MAX_RENDER_PASS_COMMANDS)
	plain := rhi.frame_alloc(r.device, 4 * size_of(u32))
	if plain.ptr == nil {return}
	(^[4]u32)(plain.ptr)^ = {}
	pass := rhi.Render_Pass_Desc{color_count = 1, name = "translucent forward"}
	pass.colors[0] = {texture = t.display, load = .Load, store = .Store}
	pass.depth = {texture = t.depth, load = .Load, store = .Store}
	if s.light_grid_dirty {
		light_grid_record(r, cmd)
		s.light_grid_dirty = false
	}
	cells := s.light_grid.size.x * s.light_grid.size.y * s.light_grid.size.z
	Params :: struct {
		light_budget, near_layer, far_layer, overflow: u32,
		grid_origin: Vec3, grid_cell: f32,
		grid_size: [3]u32, cells: u32,
	}
	params := Params{
		light_budget = r.settings.light_budget,
		near_layer = 1 if near_layer != 0 else 0, far_layer = 1 if far_layer != 0 else 0,
		grid_origin = s.light_grid.origin, grid_cell = s.light_grid.cell,
		grid_size = s.light_grid.size, cells = cells if s.light_grid_buffer != 0 else 0,
	}
	bind_light_maps(p, p.frame.sun_maps.z != 0)
	textures_feedback_bind(r, cmd)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, texture_or_dummy(r, near_layer))
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, texture_or_dummy(r, far_layer))
	rhi.cmd_bind_buffer(cmd, SLOT_PASS3, or_dummy(r, s.light_grid_buffer))
	rhi.cmd_bind_buffer(cmd, SLOT_PASS4, s.translucent_entries)
	rhi.cmd_bind_texture(cmd, SLOT_LIGHT_LISTS, s.translucent_lists)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS6, t.shadow_raster.pages if p.frame.sun_maps.z != 0 else r.scratch_buffer)
	set_params(cmd, &params)
	targets := translucent_forward_pipelines(p, overflow)
	behind := near_layer != 0
	rhi.cmd_bind_index_buffer(cmd, s.mesh_draws)
	rhi.cmd_begin_render_pass(cmd, &pass)
	commands := 0
	run: Translucent_Run
	for entry, k in p.translucent {
		forward := entry.forward && !(behind && entry.before)
		draws := 0
		for target, i in targets {
			if target != nil && (i < 2 ? entry.glass : forward) {draws += 1}
		}
		if draws == 0 {continue}
		needed := (3 * (int(entry.slots) if entry.multi_program else 1) + 1) * draws
		if commands + needed > rhi.MAX_RENDER_PASS_COMMANDS {
			translucent_run_end(p, &run, plain)
			rhi.cmd_end_render_pass(cmd)
			rhi.cmd_begin_render_pass(cmd, &pass)
			commands = 0
		}
		for target, i in targets {
			if target == nil || (i < 2 ? !entry.glass : !forward) {continue}
			if filter := u32(1 if i < 2 else 0); filter != params.overflow {
				translucent_run_end(p, &run, plain)
				params.overflow = filter
				set_params(cmd, &params)
			}
			translucent_entry_draw(p, &run, target, k, plain)
		}
		commands += needed
	}
	translucent_run_end(p, &run, plain)
	rhi.cmd_end_render_pass(cmd)
}

@(private)
glass_shade :: proc(p: ^Pass) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	layers := glass_layer_count(r)
	translucent_forward(p, t.glass[layers - 1].depth, 0, true)

	rhi.cmd_timestamp(cmd, "glass")
	params := glass_params(p)
	pipeline := pipeline_of(r, .Glass)^
	light := pipeline_of(r, .Glass_Light)^
	maps := p.frame.sun_maps.z != 0
	for k := layers - 1; k >= 0; k -= 1 {
		if k < layers - 1 {translucent_forward(p, t.glass[k].depth, t.glass[k + 1].depth)}
		rhi.cmd_bind_pipeline(cmd, pipeline)
		glass_layer_bind(p, k)
		// The layer reads the scene from a copy and writes over its own pixels: its own light
		// (glass_light.comp, with the maps of the view), then what it lets through.
		params.snapshot = 1
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.display)
		rhi.cmd_bind_texture(cmd, SLOT_PASS7, t.glass_scene, 0)
		rhi.cmd_dispatch_indirect(cmd, p.view.glass_dispatch, 0)
		if p.glass_rough {glass_scene_levels_record(p)}
		glass_layer_bind(p, k)
		params.snapshot = 0
		rhi.cmd_bind_pipeline(cmd, light)
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.shadow_raster.atlas if maps else r.dummy_texture)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS8, r.shadow_buffers.table if maps else r.dummy_buffer)
		rhi.cmd_bind_texture(cmd, SLOT_PASS7, t.display)
		rhi.cmd_dispatch_indirect(cmd, p.view.glass_dispatch, 0)
		rhi.cmd_bind_pipeline(cmd, pipeline)
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.glass_scene)
		rhi.cmd_bind_texture(cmd, SLOT_PASS8, t.linear_depth)
		rhi.cmd_dispatch_indirect(cmd, p.view.glass_dispatch, 0)
	}
	rhi.cmd_bind_texture(cmd, SLOT_LAYERS, t.layers if t.layers != 0 else r.dummy_layers)
	return true
}

// The levels of the copy of the scene behind a layer: down to the one the
// widest blur of glass_pass.slang takes (scene_blurred, 8 % of the height).
@(private)
glass_scene_levels :: proc(t: ^Targets) -> u32 {
	widest := u32(math.ceil(math.log2(max(0.08 * f32(t.height), 1)) - 0.5)) + 1
	full := u32(1)
	for (max(t.width, t.height) >> full) > 0 {full += 1}
	return clamp(widest, 1, min(full, rhi.MAX_TEXTURE_MIPS))
}

// Each level of the scene the layer reads from the one before (glass_levels.comp).
@(private)
glass_scene_levels_record :: proc(p: ^Pass) {
	r, cmd, t := p.r, p.cmd, p.t
	Params :: struct {source_size: [2]i32, first, pad: u32}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Glass_Levels])
	levels := glass_scene_levels(t)
	for level in 1 ..< levels {
		params := Params{source_size = {i32(max(t.width >> (level - 1), 1)), i32(max(t.height >> (level - 1), 1))}, first = 1 if level == 1 else 0}
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.glass_scene, i32(level - 1))
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.glass_scene, i32(level))
		rhi.cmd_dispatch(cmd, groups(max(t.width >> level, 1), 8), groups(max(t.height >> level, 1), 8))
	}
}

// glass_pass.slang Params_Block.
@(private)
Glass_Params :: struct {light_budget, pad: u32, max_distance: f32, snapshot, medium: u32, near_top: f32, medium_row, pad1: u32}

@(private)
glass_params :: proc(p: ^Pass) -> Glass_Params {
	settings := &p.r.settings
	return {light_budget = settings.light_budget, max_distance = settings.gi_max_distance, medium = p.glass_medium, near_top = GLASS_MEDIUM_NEAR, medium_row = p.glass_medium_row}
}

@(private = "file")
glass_bind_layers :: proc(p: ^Pass, layer: Glass_Layer) {
	rhi.cmd_bind_texture(p.cmd, SLOT_LAYERS, layer.layers if p.glass_material_layers else p.r.dummy_layers)
}

// What the glass passes read of layer k.
@(private)
glass_layer_bind :: proc(p: ^Pass, k: int) {
	cmd, t := p.cmd, p.t
	layer := t.glass[k]
	rhi.cmd_bind_texture(cmd, SLOT_PASS9, layer.surface)
	glass_bind_layers(p, layer)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, layer.albedo)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, layer.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, layer.emission)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, layer.ids)
	rhi.cmd_bind_texture(cmd, SLOT_PASS4, layer.depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS8, t.linear_depth)
}

// The camera under some instance of glass may be inside it: what the solid
// absorbs and scatters from the camera to the nearest layer, over the lit
// glass and the Lit stage in front of it.
@(private)
glass_inside :: proc(p: ^Pass) {
	if p.glass_medium == 0 {return}
	r, cmd, t := p.r, p.cmd, p.t
	rhi.cmd_timestamp(cmd, "glass inside")
	params := glass_params(p)
	glass_layer_bind(p, 0)
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.glass_scene)
	rhi.cmd_bind_texture(cmd, SLOT_PASS7, t.display)
	rhi.cmd_bind_pipeline(cmd, pipeline_of(r, .Glass_Inside)^)
	set_params(cmd, &params)
	rhi.cmd_dispatch_indirect(cmd, p.view.glass_dispatch, 0)
	rhi.cmd_bind_texture(cmd, SLOT_LAYERS, t.layers if t.layers != 0 else r.dummy_layers)
}
