package mirai_render

import "core:slice"
import "mirai:asset"
import "mirai:render/abi"
import "mirai:rhi"

// Decals: surfaces of materials of asset.Alpha_Mode.Decal change the surface
// under them before it is lit, and are never lit themselves. Each view draws
// them, after its depth pyramid and before its resolve, against its final
// depth without writing it, into decal targets of its own that blend
// premultiplied (decal.vert, decal.frag); the Decal stage of extensions draws
// into the same targets after them. The resolve applies what they hold to
// the surface of each pixel before it packs the G-buffer (decal_buffer.slang).
// A view has the targets, the pass and the constant of the resolve only while
// the scene has a decal or an extension asks for the stage; the emission
// target only while one of them emits.
//
// The decals of the scene are a list of its instances and the slots of their
// meshes that are decals, ordered once, when it changes, by the order of
// their materials (asset.Material_Decal.order), their program, their
// instance and their slot: the same in every view. A frame looks at no entry
// of it: decal_draws.comp culls each, and the entries of one program in a
// row are one draw of many.

// An entry of the decals of the scene, in the order they are drawn.
@(private)
Decal_Entry :: struct {
	order:    i16,
	program:  u32,
	instance: u32,
	slot:     u32,
}

// Entries in a row of one Surface program: one draw of many.
@(private)
Decal_Run :: struct {
	program, first, count: u32,
}

// The decal targets of a view and the formats they have (decal.frag).
@(private)
DECAL_FORMATS :: [Decal_Target]rhi.Format{.Color = .RGBA8_Srgb, .Normal = .RGBA16_Float, .Surface = .RGBA8_Unorm, .Emission = .RGBA16_Float}

// The decals of the scene in their order and their runs, and what the GPU
// reads of them, again once they changed.
@(private)
decals_order :: proc(r: ^Renderer, cmd: ^rhi.Command_List) -> bool {
	s := &r.scene
	if !s.decals_stale {return true}
	clear(&s.decals)
	clear(&s.decal_runs)
	s.decal_emission = false
	for &inst, index in s.instances {
		if inst.meta.x & INSTANCE_FLAG_DECAL == 0 || int(inst.meta.x & INSTANCE_MESH_MASK) >= len(s.meshes) {continue}
		mesh := s.meshes[inst.meta.x & INSTANCE_MESH_MASK]
		for packed, k in s.indices[mesh.slot_word:][:mesh.slot_count] {
			row := instance_row(packed, inst.meta.y, &inst.slot_materials)
			if int(row) >= len(s.materials) {continue}
			values := instance_material(s, inst.material_values, row)
			if values.alpha_mode != u32(asset.Alpha_Mode.Decal) {continue}
			flags := s.materials[row].volume.flags
			writes := transmute(asset.Decal_Writes)u8(flags >> abi.MATERIAL_DECAL_SHIFT & u32(transmute(u8)asset.DECAL_WRITES_ALL))
			if writes == {} {writes = asset.MATERIAL_DEFAULTS.decal.writes}
			s.decal_emission ||= .Emission in writes
			entry := Decal_Entry{order = i16(u16(flags >> abi.MATERIAL_DECAL_ORDER_SHIFT)), program = values.program_id, instance = u32(index), slot = u32(k)}
			if _, error := append(&s.decals, entry); error != nil {
				set_error(r, "decals of the scene: out of memory")
				return false
			}
		}
	}
	slice.sort_by(s.decals[:], proc(a, b: Decal_Entry) -> bool {
		if a.order != b.order {return a.order < b.order}
		if a.program != b.program {return a.program < b.program}
		if a.instance != b.instance {return a.instance < b.instance}
		return a.slot < b.slot
	})
	for entry, k in s.decals {
		if n := len(s.decal_runs); n > 0 && s.decal_runs[n - 1].program == entry.program {
			s.decal_runs[n - 1].count += 1
			continue
		}
		if _, error := append(&s.decal_runs, Decal_Run{entry.program, u32(k), 1}); error != nil {
			set_error(r, "decals of the scene: out of memory")
			return false
		}
	}
	count := len(s.decals)
	if count > s.decal_capacity {
		capacity := max(count + count / 2, 64)
		for b in ([]rhi.Buffer{s.decal_entries, s.decal_draws}) {if b != 0 {rhi.buffer_destroy(r.device, b)}}
		s.decal_entries = rhi.buffer_create(r.device, {size = u64(capacity) * size_of([2]u32), usage = {.Storage}, name = "decals of the scene"})
		s.decal_draws = rhi.buffer_create(r.device, {size = u64(capacity) * size_of(rhi.Draw_Indexed_Indirect), usage = {.Storage, .Indirect}, name = "draws of the decals"})
		s.decal_capacity = capacity if s.decal_entries != 0 && s.decal_draws != 0 else 0
		if s.decal_capacity == 0 {
			set_error(r, "decals of the scene: %s", rhi.device_error(r.device))
			return false
		}
	}
	if count > 0 {
		words := rhi.frame_alloc(r.device, u64(count) * size_of([2]u32), 16)
		if words.ptr == nil {return false}
		placed := ([^][2]u32)(words.ptr)[:count]
		for entry, k in s.decals {placed[k] = {entry.instance, entry.slot}}
		rhi.cmd_copy_buffer(cmd, words.buffer, words.offset, s.decal_entries, 0, u64(count) * size_of([2]u32))
	}
	s.decals_stale = false
	return true
}

// The meshes of the decals are drawn whole (mesh_draws.odin).
@(private)
decals_meshes_ask :: proc(s: ^Scene_State, asked: u64) {
	for entry in s.decals {
		mesh := s.instances[entry.instance].meta.x & INSTANCE_MESH_MASK
		if int(mesh) < len(s.meshes) {s.meshes[mesh].draw_asked = asked}
	}
}

// The decal targets of a view while it draws decals, and none while it does
// not: they are shared with the views of its size.
@(private)
decal_targets :: proc(r: ^Renderer, t: ^Targets, decals, emission: bool) -> bool {
	if !decals {
		shared_targets_release(r, targets_frame(&t.decal_targets))
		return true
	}
	if !emission && t.decal_emission != 0 {
		shared_target_release(r, t.decal_emission)
		t.decal_emission = 0
	}
	formats := DECAL_FORMATS
	usage := rhi.Texture_Usage{.Color_Target, .Sampled}
	ok := target(r, nil, &t.decal_color, t.width, t.height, formats[.Color], usage, "decal color", shared = true)
	ok &&= target(r, nil, &t.decal_normal, t.width, t.height, formats[.Normal], usage, "decal normal", shared = true)
	ok &&= target(r, nil, &t.decal_surface, t.width, t.height, formats[.Surface], usage, "decal surface", shared = true)
	ok &&= !emission || target(r, nil, &t.decal_emission, t.width, t.height, formats[.Emission], usage, "decal emission", shared = true)
	return ok
}

// The decal targets of the view: those it has, in the order of Decal_Target.
@(private)
decal_textures :: proc(p: ^Pass) -> (textures: [Decal_Target]rhi.Texture, targets: Decal_Targets) {
	t := p.t
	textures = {.Color = t.decal_color, .Normal = t.decal_normal, .Surface = t.decal_surface, .Emission = t.decal_emission}
	targets = {.Color, .Normal, .Surface}
	if p.decal_emission {targets += {.Emission}}
	return
}

// The pass of the decals of a view, against the depth its raster left: the
// draws of the decals of the scene, culled, a draw of many for each run of
// one program, then the Decal stage of extensions over them.
@(private)
pass_decals :: proc(p: ^Pass) {
	r, cmd, t := p.r, p.cmd, p.t
	s := &r.scene
	render_zone(r, "decals")
	rhi.cmd_timestamp(cmd, "decals")
	textures, targets := decal_textures(p)
	pass := rhi.Render_Pass_Desc{name = "decals"}
	for texture, target in textures {
		if target not_in targets {continue}
		pass.colors[pass.color_count] = {texture = texture, load = .Clear, store = .Store}
		pass.color_count += 1
	}
	count := len(s.decals)
	if count == 0 || !p.draw || s.decal_capacity < count {
		rhi.cmd_begin_render_pass(cmd, &pass)
		rhi.cmd_end_render_pass(cmd)
	} else {
		Params :: struct {count, hiz_levels, occlusion, pad: u32}
		params := Params{count = u32(count), hiz_levels = t.hiz_levels, occlusion = 1 if p.pyramid else 0}
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Decal_Draws])
		set_params(cmd, &params)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.decal_entries)
		rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.hiz[p.current] if p.pyramid else r.dummy_texture)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS2, s.decal_draws)
		rhi.cmd_dispatch(cmd, groups(u32(count), 64))
		pass.depth = {texture = t.depth, load = .Load, store = .Store}
		id := Pipeline_Id.Decal_Emissive if p.decal_emission else .Decal
		target := &r.pipelines[id]
		quiet := pipeline_of(r, id, {DECAL_FRAG_QUIET}, optional = {DECAL_FRAG_QUIET})
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.decal_entries)
		textures_feedback_bind(r, cmd)
		rhi.cmd_bind_index_buffer(cmd, s.mesh_draws)
		rhi.cmd_begin_render_pass(cmd, &pass)
		for run in s.decal_runs {
			spared := target if textures_feedback_turn(r, run.program) else quiet
			rhi.cmd_bind_pipeline(cmd, program_spared(r, target, spared, run.program))
			rhi.cmd_draw_indexed_indirect(cmd, s.decal_draws, u64(run.first) * size_of(rhi.Draw_Indexed_Indirect), run.count)
		}
		rhi.cmd_end_render_pass(cmd)
	}
	if stage_asked(r, .Decal) {stage_run(p, .Decal)}
}
