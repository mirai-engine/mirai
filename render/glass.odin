package mirai_render

import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:asset"
import "mirai:rhi"
import mm "mirai:std/math"

GLASS_LAYERS_MAX :: 2
GLASS_CACHED_REFLECTANCE :: f32(0.25)

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
glass_textures :: proc(t: ^Targets) -> (all: [GLASS_LAYERS_MAX * 7 + 3]rhi.Texture) {
	for layer, i in t.glass {
		each := [7]rhi.Texture{layer.albedo, layer.normal, layer.emission, layer.ids, layer.depth, layer.surface, layer.layers}
		copy(all[i * 7:], each[:])
	}
	rest := [3]rhi.Texture{t.glass_zbuffer, t.glass_scene, t.glass_reflections}
	copy(all[GLASS_LAYERS_MAX * 7:], rest[:])
	return
}

@(private)
destroy_glass_targets :: proc(r: ^Renderer, t: ^Targets) {
	for tex in glass_textures(t) {if tex != 0 {rhi.texture_destroy(r.device, tex)}}
	t.glass, t.glass_zbuffer, t.glass_scene, t.glass_reflections = {}, 0, 0, 0
	t.glass_valid = false
}

// m over the top of a solid within which the pixels of a view near it decide whether they start in it
// (glass_pass.slang Params_Block.near_top).
GLASS_MEDIUM_NEAR :: f32(0.25)

// The solid blended instance under the top of whose box the camera is, within its sides, plus one: the smallest
// of them, the one further in, by its box down to the camera when the camera is below it. Under, not only
// inside: under a sheet open below, as the surface of water, is inside it. The glass passes find whether
// the camera is in its solid; 0 when it is under none.
@(private)
glass_medium :: proc(r: ^Renderer, camera: Vec3) -> (medium: u32) {
	smallest := max(f32)
	for entry in r.scene.translucent {
		if !entry.solid {continue}
		inst := &r.scene.instances[entry.instance]
		lo, hi := inst.bounds_min.xyz, inst.bounds_max.xyz
		if camera.x < lo.x || camera.z < lo.z || camera.x > hi.x || camera.y > hi.y + GLASS_MEDIUM_NEAR || camera.z > hi.z {continue}
		size := hi - lo
		if volume := size.x * size.z * (hi.y - min(lo.y, camera.y)); volume < smallest {smallest, medium = volume, entry.instance + 1}
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
	settings := &p.r.settings
	size := f.resolution
	lo, hi := Vec2{1, 1}, Vec2{}
	p.translucent = glass_visible(&p.r.scene, f)
	for entry in p.translucent {
		inst := &p.r.scene.instances[entry.instance]
		bounds := mm.Aabb{inst.bounds_min.xyz, inst.bounds_max.xyz}
		p.draw_forward ||= entry.forward
		p.draw_glass ||= entry.glass
		p.glass_material_layers ||= entry.layered
		if settings.reflections != .Off && entry.glass_roughness < settings.reflection_roughness {
			rect := projected_box(bounds, f.view_proj, f.camera_position.xyz)
			lo, hi = linalg.min(lo, rect.xy), linalg.max(hi, rect.zw)
		}
	}
	if lo.x < hi.x && lo.y < hi.y {
		p.glass_reflect_bounds = {
			u32(max(math.floor(lo.x * size.x) - 1, 0)), u32(max(math.floor(lo.y * size.y) - 1, 0)),
			u32(min(math.ceil(hi.x * size.x) + 1, size.x)), u32(min(math.ceil(hi.y * size.y) + 1, size.y)),
		}
	}
}

// A draw of one program binds its pipeline and draw constants, then draws.
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
	for entry in p.translucent {
		if !entry.glass {continue}
		mesh := s.instances[entry.instance].meta.x & INSTANCE_MESH_MASK
		needed := 3 * int(max(s.meshes[mesh].slot_count, 1))
		if commands + needed > rhi.MAX_RENDER_PASS_COMMANDS {
			rhi.cmd_end_render_pass(cmd)
			for &color in pass.colors[:pass.color_count] {color.load = .Load}
			pass.depth.load = .Load
			rhi.cmd_begin_render_pass(cmd, pass)
			commands = 0
		}
		instance_programs_draw(r, cmd, target, entry.instance, false, plain_constants = plain)
		commands += needed
	}
	rhi.cmd_end_render_pass(cmd)
}

@(private)
glass_layers :: proc(p: ^Pass) {
	r, cmd, t := p.r, p.cmd, p.t
	p.glass_medium = glass_medium(r, p.camera.position)
	rhi.cmd_timestamp(cmd, "translucent")
	for k in 0 ..< glass_layer_count(r) {
		layer := t.glass[k]
		nearer := t.glass[k - 1].depth if k > 0 else r.dummy_texture
		layered := p.glass_material_layers
		pass := rhi.Render_Pass_Desc{color_count = 7 if layered else 6, name = "glass layer"}
		for target, i in ([7]rhi.Texture{layer.albedo, layer.normal, layer.emission, layer.ids, layer.depth, layer.surface, layer.layers}) {
			if i < int(pass.color_count) {pass.colors[i] = {texture = target, load = .Clear, store = .Store}}
		}
		pass.depth = {texture = t.glass_zbuffer, load = .Clear, store = .Store, clear = 0}
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

@(private)
translucent_forward :: proc(p: ^Pass, near_layer, far_layer: rhi.Texture, overflow := false) {
	if !p.draw_forward && !overflow {return}
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	#assert((3 * asset.MESH_MAX_SLOTS + 1) * 3 <= rhi.MAX_RENDER_PASS_COMMANDS)
	plain := rhi.frame_alloc(r.device, 4 * size_of(u32))
	if plain.ptr == nil {return}
	(^[4]u32)(plain.ptr)^ = {}
	pass := rhi.Render_Pass_Desc{color_count = 1, name = "translucent forward"}
	pass.colors[0] = {texture = t.display, load = .Load, store = .Store}
	Params :: struct {light_budget, near_layer, far_layer, overflow: u32}
	params := Params{
		light_budget = r.settings.light_budget,
		near_layer = 1 if near_layer != 0 else 0, far_layer = 1 if far_layer != 0 else 0,
	}
	bind_light_maps(p, p.frame.sun_maps.z != 0)
	textures_feedback_bind(r, cmd)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, texture_or_dummy(r, near_layer))
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, texture_or_dummy(r, far_layer))
	targets := translucent_forward_pipelines(p, overflow)
	rhi.cmd_bind_index_buffer(cmd, s.mesh_draws)
	rhi.cmd_begin_render_pass(cmd, &pass)
	commands := 0
	for entry in p.translucent {
		draws := 0
		for target, i in targets {
			if target != nil && (i < 2 ? entry.glass : entry.forward) {draws += 1}
		}
		if draws == 0 {continue}
		mesh := s.instances[entry.instance].meta.x & INSTANCE_MESH_MASK
		needed := (3 * int(max(s.meshes[mesh].slot_count, 1)) + 1) * draws
		if commands + needed > rhi.MAX_RENDER_PASS_COMMANDS {
			rhi.cmd_end_render_pass(cmd)
			rhi.cmd_begin_render_pass(cmd, &pass)
			commands = 0
		}
		for target, i in targets {
			if target == nil || (i < 2 ? !entry.glass : !entry.forward) {continue}
			params.overflow = 1 if i < 2 else 0
			set_params(cmd, &params)
			instance_programs_draw(r, cmd, target, entry.instance, false, plain_constants = plain)
		}
		commands += needed
	}
	rhi.cmd_end_render_pass(cmd)
}

@(private)
glass_shade :: proc(p: ^Pass) -> bool {
	r, cmd, t := p.r, p.cmd, p.t
	layers := glass_layer_count(r)
	translucent_forward(p, t.glass[layers - 1].depth, 0, true)
	traced := p.glass_reflect_bounds != {}
	if traced {
		if !ensure_reflect_targets(r, cmd, t) ||
		   !target(r, cmd, &t.glass_reflections, t.width, t.height, .RGBA16_Float, HISTORY_USAGE,
		           "glass reflections", clear = true) {
			return false
		}
		rhi.cmd_timestamp(cmd, "glass reflect")
		rhi.cmd_bind_texture(cmd, SLOT_SURFACE, t.glass[0].surface)
		glass_bind_layers(p, t.glass[0])
		traced = reflect_pass(p, glass = true)
		rhi.cmd_bind_texture(cmd, SLOT_SURFACE, texture_or_dummy(r, t.surface))
	}
	t.glass_valid = traced

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
		params.snapshot, params.traced = 1, 0
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.display)
		rhi.cmd_bind_texture(cmd, SLOT_PASS7, t.glass_scene, 0)
		rhi.cmd_dispatch_indirect(cmd, p.view.glass_dispatch, 0)
		glass_scene_levels_record(p)
		glass_layer_bind(p, k)
		params.snapshot, params.traced = 0, 1 if traced && k == 0 else 0
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
Glass_Params :: struct {light_budget, traced: u32, max_distance: f32, snapshot, medium: u32, near_top: f32, pad0, pad1: u32}

@(private)
glass_params :: proc(p: ^Pass) -> Glass_Params {
	settings := &p.r.settings
	return {light_budget = settings.light_budget, max_distance = settings.gi_max_distance, medium = p.glass_medium, near_top = GLASS_MEDIUM_NEAR}
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
	rhi.cmd_bind_texture(cmd, SLOT_PASS6, texture_or_dummy(p.r, t.glass_reflections))
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
	params.traced = 1 if t.glass_valid else 0
	glass_layer_bind(p, 0)
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.glass_scene)
	rhi.cmd_bind_texture(cmd, SLOT_PASS7, t.display)
	rhi.cmd_bind_pipeline(cmd, pipeline_of(r, .Glass_Inside)^)
	set_params(cmd, &params)
	rhi.cmd_dispatch_indirect(cmd, p.view.glass_dispatch, 0)
	rhi.cmd_bind_texture(cmd, SLOT_LAYERS, t.layers if t.layers != 0 else r.dummy_layers)
}
