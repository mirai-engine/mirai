package mirai_render

import "core:math/linalg"
import "mirai:rhi"
import mm "mirai:std/math"

// Blended surfaces. The nearest ones of each pixel are layers: a small
// G-buffer each, lit by a compute pass once per pixel with what glass needs
// (traced reflection, refraction, shadowed lights). The surfaces behind the
// layers are drawn forward and back to front: each one filters the scene
// behind it and adds its own light, with the probe volume for its reflection.

GLASS_LAYERS_MAX :: 2
// Below this reflectance a reflection of glass lights what it shows from the
// probe volume instead of tracing shadow rays there.
GLASS_CACHED_REFLECTANCE :: f32(0.25)
// Below this reflectance (glass seen within about 50 degrees of face on) a
// reflection of glass traces one turn of its block in four.
GLASS_FAINT_REFLECTANCE :: f32(0.06)

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

// Whether some blended instance of the scene has a material with layers.
@(private)
glass_layered :: proc(s: ^Scene_State) -> bool {
	for entry in s.translucent {if entry.layered {return true}}
	return false
}

// The targets of the layers exist from the first frame that draws a blended
// surface: a scene without any never pays for them. Their layers targets,
// from the first frame whose scene has a blended material with layers.
@(private)
ensure_glass_targets :: proc(r: ^Renderer, t: ^Targets) -> bool {
	layers := glass_layer_count(r)
	if len(r.scene.translucent) == 0 {return true}
	d := r.device
	full :: proc(d: ^rhi.Device, t: ^Targets, format: rhi.Format, usage: rhi.Texture_Usage, name: string) -> rhi.Texture {
		return rhi.texture_create(d, {width = t.width, height = t.height, format = format, usage = usage, name = name})
	}
	attachment := rhi.Texture_Usage{.Color_Target, .Sampled}
	layered := glass_layered(&r.scene)
	if t.glass_scene != 0 {
		if t.glass[0].layers != 0 || !layered {return true}
		ok := true
		for &layer in t.glass[:layers] {
			layer.layers = full(d, t, .RGBA32_Uint, attachment, "glass material layers")
			ok &&= layer.layers != 0
		}
		if !ok {set_error(r, "glass layers targets: %s", rhi.device_error(d))}
		return ok
	}
	ok := true
	for &layer in t.glass[:layers] {
		layer.albedo = full(d, t, .RGBA8_Srgb, attachment, "glass albedo")
		layer.normal = full(d, t, .RGBA16_Float, attachment, "glass normal")
		layer.emission = full(d, t, .RGBA16_Float, attachment, "glass emission")
		layer.ids = full(d, t, .RG32_Uint, attachment, "glass ids")
		layer.depth = full(d, t, .R32_Float, attachment, "glass depth")
		layer.surface = full(d, t, .RGBA8_Srgb, attachment, "glass surface")
		if layered {layer.layers = full(d, t, .RGBA32_Uint, attachment, "glass material layers")}
		ok &&= layer.albedo != 0 && layer.normal != 0 && layer.emission != 0 && layer.ids != 0 && layer.depth != 0 && layer.surface != 0 && (layer.layers != 0 || !layered)
	}
	t.glass_zbuffer = full(d, t, .D32_Float, {.Depth_Target}, "glass z")
	t.glass_scene = full(d, t, .RGBA16_Float, {.Sampled, .Storage, .Color_Target}, "glass scene")
	for &history in t.glass_history {history = full(d, t, .RGBA16_Float, {.Sampled, .Storage, .Color_Target}, "glass reflection history")}
	t.glass_valid = false
	t.glass_needs_clear = true
	ok &&= t.glass_zbuffer != 0 && t.glass_scene != 0 && t.glass_history[0] != 0 && t.glass_history[1] != 0
	if !ok {set_error(r, "glass targets: %s", rhi.device_error(d))}
	return ok
}

// The mean filter of each instance with blended surfaces (glass_mean.comp,
// Gpu_Instance.glass), which the rays that average glass take. It runs in the
// first view of a frame that uploaded the table of instances, one with blended
// surfaces, materials or geometry, before any pass traces: an upload of an
// instance brings the value the CPU holds.
// Without colored shadows no ray reads it.
@(private)
glass_means_record :: proc(p: ^Pass) -> bool {
	r, cmd := p.r, p.cmd
	s := &r.scene
	if !r.glass_stale || !r.settings.colored_shadows || len(s.translucent) == 0 {return true}
	list, t := rhi.frame_alloc_typed(r.device, u32, len(s.translucent))
	if list == nil {set_error(r, "transient ring exhausted listing %d instances with glass", len(s.translucent)); return false}
	for entry, i in s.translucent {list[i] = entry.instance}
	rhi.cmd_timestamp(cmd, "glass mean")
	// The faces with a program wait for it.
	batch := points_begin(p, filters = true)
	Params :: struct {resume, batch, pad0, pad1: u32}
	params := Params{batch = u32(batch)}
	pipeline := r.pipelines[.Glass_Mean]
	rhi.cmd_bind_pipeline(cmd, pipeline)
	set_params(cmd, &params)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, t.buffer, t.offset, u64(len(list) * size_of(u32)))
	points_bind(p)
	for b in ([]rhi.Buffer{s.mesh_buffer, s.vertex_buffer, s.index_buffer, s.material_buffer}) {rhi.cmd_barrier_buffer(cmd, b, .Shader_Read)}
	rhi.cmd_barrier_buffer(cmd, s.instance_buffer, .Shader_Write)
	rhi.cmd_dispatch(cmd, u32(len(list)), 1)
	// The resume adds to what the dispatch wrote.
	if batch {rhi.cmd_barrier_buffer(cmd, s.instance_buffer, .Shader_Write)}
	points_rounds(p, batch, pipeline, &params, 1)
	rhi.cmd_barrier_buffer(cmd, s.instance_buffer, .Shader_Read)
	r.glass_stale = false
	return true
}

// Every texture of the glass of a view, made or not.
@(private)
glass_textures :: proc(t: ^Targets) -> (all: [GLASS_LAYERS_MAX * 7 + 4]rhi.Texture) {
	for layer, i in t.glass {
		each := [7]rhi.Texture{layer.albedo, layer.normal, layer.emission, layer.ids, layer.depth, layer.surface, layer.layers}
		copy(all[i * 7:], each[:])
	}
	rest := [4]rhi.Texture{t.glass_zbuffer, t.glass_scene, t.glass_history[0], t.glass_history[1]}
	copy(all[GLASS_LAYERS_MAX * 7:], rest[:])
	return
}

@(private)
destroy_glass_targets :: proc(r: ^Renderer, t: ^Targets) {
	for tex in glass_textures(t) {if tex != 0 {rhi.texture_destroy(r.device, tex)}}
	t.glass, t.glass_zbuffer, t.glass_scene, t.glass_history = {}, 0, 0, {}
	t.glass_valid = false
}

// Of the stage whose pipeline is target^, by the programs of its materials.
@(private = "file")
draw_translucent :: proc(r: ^Renderer, cmd: ^rhi.Command_List, target: ^rhi.Pipeline, entry: Translucent) {
	// The clusters of the cut the view takes, as the G-buffer: glass gets coarser with distance too.
	instance_programs_draw(r, cmd, target, entry.instance, false)
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

// Whether a blended instance can be on screen at all. The cull pass tests
// occlusion too and sizes the compute passes; this spares the rest.
@(private)
glass_in_frustum :: proc(r: ^Renderer, planes: [6]Vec4) -> bool {
	frustum := transmute(mm.Frustum)planes
	for entry in r.scene.translucent {
		inst := &r.scene.instances[entry.instance]
		if mm.frustum_overlaps_aabb(frustum, {inst.bounds_min.xyz, inst.bounds_max.xyz}) {return true}
	}
	return false
}

// The blended instances over the composited scene in t.display, in two
// steps: glass_layers rasterizes the nearest surfaces of each pixel, and
// glass_shade draws the ones behind them and lights the layers. Their
// fragments and the glass pass trace shadow rays and read the probe volume,
// so everything the deferred passes read is declared here. Drawn from the CPU
// in full detail: the order matters and there are few of them. The compute
// passes run with the dispatch sizes the cull pass wrote: none while every
// blended instance is hidden.
@(private)
glass_layers :: proc(p: ^Pass) {
	r, cmd, t, camera := p.r, p.cmd, p.t, p.camera
	s := &r.scene
	g := &r.ddgi
	layers := glass_layer_count(r)
	for &entry in s.translucent {
		inst := s.instances[entry.instance]
		center := (inst.bounds_min.xyz + inst.bounds_max.xyz) * 0.5
		entry.distance = linalg.length(center - camera.position)
	}
	for i in 1 ..< len(s.translucent) {
		entry := s.translucent[i]
		j := i
		for j > 0 && s.translucent[j - 1].distance < entry.distance {
			s.translucent[j] = s.translucent[j - 1]
			j -= 1
		}
		s.translucent[j] = entry
	}
	p.glass_medium = glass_medium(r, camera.position)
	rhi.cmd_timestamp(cmd, "translucent")
	buffers := []rhi.Buffer{
		s.instance_buffer, s.mesh_buffer, s.vertex_buffer, s.index_buffer, s.material_buffer, s.light_buffer, s.light_tree_buffer,
		s.blas_node_buffer, s.blas_triangle_buffer, s.tlas_node_buffer, s.tlas_ref_buffer, g.probes if g.valid else r.dummy_buffer,
	}
	for b in buffers {if b != 0 {rhi.cmd_barrier_buffer(cmd, b, .Shader_Read)}}
	if g.valid {
		rhi.cmd_barrier_texture(cmd, g.irradiance, .Shader_Read)
		rhi.cmd_barrier_texture(cmd, g.distance, .Shader_Read)
	}
	if r.hardware_rt && s.tlas != 0 {rhi.cmd_barrier_accel(cmd, s.tlas)}
	rhi.cmd_barrier_texture(cmd, t.linear_depth, .Shader_Read)
	rhi.cmd_barrier_texture(cmd, r.dummy_texture, .Shader_Read)

	for k in 0 ..< layers {
		layer := t.glass[k]
		nearer := t.glass[k - 1].depth if k > 0 else r.dummy_texture
		rhi.cmd_barrier_texture(cmd, nearer, .Shader_Read)
		layered := glass_layers_held(r, layer)
		pass := rhi.Render_Pass_Desc{color_count = 7 if layered else 6, name = "glass layer"}
		for target, i in ([7]rhi.Texture{layer.albedo, layer.normal, layer.emission, layer.ids, layer.depth, layer.surface, layer.layers}) {
			if i < int(pass.color_count) {pass.colors[i] = {texture = target, load = .Clear, store = .Store}}
		}
		pass.depth = {texture = t.glass_zbuffer, load = .Clear, store = .Store, clear = 0}
		rhi.cmd_begin_render_pass(cmd, &pass)
		Params :: struct {peeled, medium, pad1, pad2: u32}
		params := Params{peeled = u32(k), medium = p.glass_medium}
		target := &r.pipelines[.Glass_Layer_Layers if layered else .Glass_Layer]
		rhi.cmd_bind_pipeline(cmd, target^)
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.linear_depth)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, nearer)
		for entry in s.translucent {draw_translucent(r, cmd, target, entry)}
		rhi.cmd_end_render_pass(cmd)
	}
}

@(private)
glass_shade :: proc(p: ^Pass, trace_reflections: bool) {
	r, cmd, t, camera := p.r, p.cmd, p.t, p.camera
	previous, current := p.previous, p.current
	s := &r.scene
	settings := &r.settings
	layers := glass_layer_count(r)
	{
		// The depth buffer of the last layer rejects that layer and what is in
		// front of it before a fragment runs: only the surfaces behind are shaded.
		last := t.glass[layers - 1].depth
		rhi.cmd_barrier_texture(cmd, last, .Shader_Read)
		pass := rhi.Render_Pass_Desc{color_count = 1, name = "translucent"}
		pass.colors[0] = {texture = t.display, load = .Load, store = .Store}
		pass.depth = {texture = t.glass_zbuffer, load = .Load, store = .Dont_Care}
		rhi.cmd_begin_render_pass(cmd, &pass)
		Params :: struct {light_budget, pad0, pad1, pad2: u32}
		params := Params{light_budget = settings.light_budget}
		targets := [2]^rhi.Pipeline{&r.pipelines[.Glass_Filter], pipeline_of(r, .Translucent, {TRANSLUCENT_FRAG_COLOR} if shadows_colored(r) else {})}
		for entry in s.translucent {
			for target in targets {
				rhi.cmd_bind_pipeline(cmd, target^)
				set_params(cmd, &params)
				rhi.cmd_bind_texture(cmd, SLOT_PASS0, last)
				rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
				draw_translucent(r, cmd, target, entry)
			}
		}
		rhi.cmd_end_render_pass(cmd)
	}

	traced := trace_reflections
	if traced {
		rhi.cmd_timestamp(cmd, "glass reflect")
		first := t.glass[0]
		rhi.cmd_barrier_texture(cmd, first.surface, .Shader_Read)
		rhi.cmd_bind_texture(cmd, SLOT_SURFACE, first.surface)
		glass_bind_layers(p, first)
		// Glass reflects a few percent of what its ray finds: a ray per block
		// of 2x2 pixels is enough at any roughness.
		reflect_pass(p, first.normal, first.depth, first.albedo, t.glass_history[previous], t.glass_history[current], t.glass_valid, true, 0, GLASS_CACHED_REFLECTANCE, true)
		rhi.cmd_bind_texture(cmd, SLOT_SURFACE, t.surface if t.surface != 0 else r.dummy_texture)
	}
	t.glass_valid = traced

	rhi.cmd_timestamp(cmd, "glass")
	params := glass_params(p)
	pipeline := pipeline_of(r, .Glass, {GLASS_COMP_COLOR} if shadows_colored(r) else {})^
	for k := layers - 1; k >= 0; k -= 1 {
		rhi.cmd_bind_pipeline(cmd, pipeline)
		glass_layer_bind(p, k)
		// The layer reads the scene from a copy and writes over its own pixels.
		params.snapshot, params.traced = 1, 0
		set_params(cmd, &params)
		rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.display)
		rhi.cmd_bind_texture(cmd, SLOT_PASS7, t.glass_scene)
		points_bind(p)
		rhi.cmd_dispatch_indirect(cmd, p.view.glass_dispatch, 0)
		params.snapshot, params.traced = 0, 1 if traced && k == 0 else 0
		rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.glass_scene)
		rhi.cmd_bind_texture(cmd, SLOT_PASS7, t.display)
		glass_walk(p, pipeline, &params, false)
	}
	rhi.cmd_bind_texture(cmd, SLOT_LAYERS, t.layers if t.layers != 0 else r.dummy_layers)
}

// glass_pass.slang Params_Block.
@(private)
Glass_Params :: struct {light_budget, traced: u32, max_distance, firefly_clamp, pixel_spread: f32, snapshot, medium: u32, near_top: f32, resume, pad0, pad1, pad2: u32}

// The most rounds the ways of the view through a solid wait for programs
// (glass_pass.slang): a face at each turn inside, and what they show, for the
// way out and the way reflected back in.
@(private)
GLASS_WALK_ROUNDS :: 5

// A dispatch of a glass pass over the pixels of glass, then the rounds of its
// ways that wait for programs.
@(private)
glass_walk :: proc(p: ^Pass, pipeline: rhi.Pipeline, params: ^Glass_Params, inside: bool) {
	cmd := p.cmd
	batch := points_begin(p)
	rhi.cmd_bind_pipeline(cmd, pipeline)
	set_params(cmd, params)
	points_bind(p)
	rhi.cmd_dispatch_indirect(cmd, p.view.glass_dispatch, 0)
	points_rounds(p, batch, pipeline, params, GLASS_WALK_ROUNDS if inside else GLASS_WALK_ROUNDS - 1)
}

@(private)
glass_params :: proc(p: ^Pass) -> Glass_Params {
	settings := &p.r.settings
	return {
		light_budget = settings.light_budget,
		max_distance = settings.gi_max_distance, firefly_clamp = settings.firefly_clamp,
		pixel_spread = p.frame.footprint.y, medium = p.glass_medium, near_top = GLASS_MEDIUM_NEAR,
	}
}

// Whether a layer of glass keeps the layers of its materials in its target:
// while some blended instance of the scene has them.
@(private)
glass_layers_held :: proc(r: ^Renderer, layer: Glass_Layer) -> bool {return layer.layers != 0 && glass_layered(&r.scene)}

// The layers target of a layer of glass in place of the G-buffer's, from
// which the passes that read the layer read its layers (gbuffer_layers).
@(private = "file")
glass_bind_layers :: proc(p: ^Pass, layer: Glass_Layer) {
	r, cmd := p.r, p.cmd
	if !glass_layers_held(r, layer) {
		rhi.cmd_bind_texture(cmd, SLOT_LAYERS, r.dummy_layers)
		return
	}
	rhi.cmd_barrier_texture(cmd, layer.layers, .Shader_Read)
	rhi.cmd_bind_texture(cmd, SLOT_LAYERS, layer.layers)
}

// What the glass passes read of layer k.
@(private)
glass_layer_bind :: proc(p: ^Pass, k: int) {
	cmd, t := p.cmd, p.t
	layer := t.glass[k]
	rhi.cmd_barrier_texture(cmd, layer.surface, .Shader_Read)
	rhi.cmd_bind_texture(cmd, SLOT_PASS9, layer.surface)
	glass_bind_layers(p, layer)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, layer.albedo)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, layer.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, layer.emission)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, layer.ids)
	rhi.cmd_bind_texture(cmd, SLOT_PASS4, layer.depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS6, t.glass_history[p.current])
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
	rhi.cmd_barrier_texture(cmd, t.display, .Shader_Write)
	params := glass_params(p)
	glass_layer_bind(p, 0)
	rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.glass_scene)
	rhi.cmd_bind_texture(cmd, SLOT_PASS7, t.display)
	glass_walk(p, pipeline_of(r, .Glass_Inside, {GLASS_INSIDE_COMP_COLOR} if shadows_colored(r) else {})^, &params, true)
	rhi.cmd_bind_texture(cmd, SLOT_LAYERS, t.layers if t.layers != 0 else r.dummy_layers)
}
