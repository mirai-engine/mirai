package mirai_render

import "core:fmt"
import "core:strings"
import "mirai:asset"
import "mirai:rhi"

// The raster stages of Surface programs (`//! per surface program`): a stage
// of the engine compiled for one program, <stem>__<program>[_<variant>],
// draws the materials of that program, and the stage itself those without
// one. The pipeline of a program is that of the stage with the fragment stage
// of the program, asked for ahead of time when the program first gets rows in
// the scene (programs_ask), or when a draw first needs it (pipeline_thread.odin);
// until it is made, the stage itself draws those materials as their rows. A
// draw of the clusters the cull listed takes those of one program
// (gbuffer_programs_draw); one of the clusters of an instance, the clusters
// of the materials of one program (instance_programs_draw).

PROGRAM_GRAPHICS_CAPACITY :: 4096 // pipelines of raster stages of programs at once, a power of two: past them a program draws as its rows

@(private)
Program_Graphics :: struct {
	target:   ^rhi.Pipeline, // where the renderer keeps the pipeline of the stage itself; nil: a free entry
	program:  u32,
	pipeline: rhi.Pipeline, // 0: not made yet, or the shaders in use have no stage of the program
	code:     ^rhi.Shader_Code, // the fragment stage of the program it is made with
}

// The entry of a stage and a program in the open table, or the free one
// where it goes; nil when the table is full.
@(private = "file")
program_graphics_entry :: proc(r: ^Renderer, target: ^rhi.Pipeline, program: u32) -> (entry: ^Program_Graphics, found: bool) {
	at := (u64(uintptr(target)) >> 3 ~ u64(program) * 0x9E3779B97F4A7C15) * 0xFF51AFD7ED558CCD >> 32
	for _ in 0 ..< PROGRAM_GRAPHICS_CAPACITY {
		entry = &r.program_graphics[at & (PROGRAM_GRAPHICS_CAPACITY - 1)]
		if entry.target == target && entry.program == program {return entry, true}
		if entry.target == nil {return entry, false}
		at += 1
	}
	return nil, false
}

// The pipeline that draws the materials of a Surface program for the stage
// whose pipeline is target^; target^ until it is made, or while the shaders
// in use have no stage of that program. now: a draw that is read back at once
// (a thumbnail) waits for it. early: asked ahead of time, before a draw needs
// it, which raises it.
@(private)
program_graphics :: proc(r: ^Renderer, target: ^rhi.Pipeline, program: u32, now := false, early := false) -> rhi.Pipeline {
	if program == 0 || program == GPU_NONE {return target^}
	entry, found := program_graphics_entry(r, target, program)
	if entry == nil {return target^}
	if !found {
		entry^ = {target = target, program = program}
		if desc, ok := pipeline_desc_of(r, target); ok && desc.fragment != nil {
			if entry.code = program_stage(r, desc.fragment, program); entry.code != nil {
				desc.fragment, desc.name = entry.code, entry.code.name
				if !pipeline_make(r, &entry.pipeline, graphics = desc, now = now, early = early) {entry^ = {}}
			}
		}
	} else if entry.pipeline == 0 && entry.code != nil && !early {
		pipeline_urgent(r, &entry.pipeline)
		if now {renderer_pipelines_wait(r, &entry.pipeline)}
	}
	return entry.pipeline if entry.pipeline != 0 else target^
}

// When a program first gets rows in the scene, with pipelines_async: the
// pipelines its rows are drawn with on the camera and evaluated with on the
// rays, asked for ahead of time, behind what frames ask for.
@(private)
programs_ask :: proc(r: ^Renderer) {
	s := &r.scene
	s.programs_arrived = false
	if !r.pipelines_async {return}
	for row in s.materials {
		if row.program_id == 0 || row.program_id == GPU_NONE {continue}
		glass := row.alpha_mode == u32(asset.Alpha_Mode.Blend)
		for id in ([]Pipeline_Id{.Glass_Layer, .Glass_Filter} if glass else []Pipeline_Id{.Gbuffer, .Gbuffer_Plain, .Gbuffer_Layers}) {
			program_graphics(r, &r.pipelines[id], row.program_id, early = true)
		}
		for program in renderer_programs(r) {
			if program.id == row.program_id && program.domain == .Surface {points_pipeline(r, program, early = true)}
		}
	}
}

// With the GPU idle: when the shaders they were made from, or the pipelines
// of the stages themselves, go.
@(private)
program_graphics_destroy :: proc(r: ^Renderer) {
	for entry in r.program_graphics {if entry.pipeline != 0 {rhi.pipeline_destroy(r.device, entry.pipeline)}}
	r.program_graphics = {}
}

// With the GPU idle and the jobs of the pipeline thread dropped, before the
// renderer takes the stages of programs of another generation, next, with
// the stages of the engine as they are: the pipelines of programs whose
// stages changed go, and those whose stages are the same stay, with the code
// of next. Those asked for and not made are asked for again. A program edited
// in the editor makes again only the pipelines of its own stages.
@(private)
program_stages_publish :: proc(r: ^Renderer, next: []rhi.Shader_Code) {
	same :: program_code_same
	kept := make([dynamic]Program_Graphics, context.temp_allocator)
	for entry in r.program_graphics {
		if entry.target == nil {continue}
		if code := same(next, entry.code); code != nil && entry.pipeline != 0 {
			append(&kept, Program_Graphics{entry.target, entry.program, entry.pipeline, code})
		} else if entry.pipeline != 0 {rhi.pipeline_destroy(r.device, entry.pipeline)}
	}
	r.program_graphics = {}
	for entry in kept {
		if slot, _ := program_graphics_entry(r, entry.target, entry.program); slot != nil {slot^ = entry}
	}
	program_computes_publish(r, &r.points.stages, next)
	program_computes_publish(r, &r.vertex_stages, next)
	for &entry in r.stage_pipelines {
		if !entry.asked || entry.program == 0 {continue}
		if code := same(next, entry.code); code != nil && entry.pipeline != 0 {
			entry.code = code
			continue
		}
		if entry.pipeline != 0 {rhi.pipeline_destroy(r.device, entry.pipeline)}
		entry = {}
	}
}

// The code of next with the name of code, when it is the same code; nil otherwise.
@(private)
program_code_same :: proc(codes: []rhi.Shader_Code, code: ^rhi.Shader_Code) -> ^rhi.Shader_Code {
	if code == nil {return nil}
	for &other in codes {if other.name == code.name {return &other if shader_code_matches(other, code^) else nil}}
	return nil
}

// The description of a graphics pipeline of the renderer, by where it keeps it.
@(private = "file")
pipeline_desc_of :: proc(r: ^Renderer, target: ^rhi.Pipeline) -> (rhi.Graphics_Pipeline_Desc, bool) {
	list := new(Pipeline_List, context.temp_allocator)
	pipelines_list(r, list)
	for item in list.items[:list.count] {
		if item.target == target && item.graphics {return item.desc, true}
	}
	return {}, false
}

// The code of a stage of the engine or of an extension compiled for a Surface
// program, from that of the stage itself: <stem>__<program>[_<variant>]<suffix>,
// for the split of its name into a stem and a variant the shaders in use
// have. nil without a program or without such a stage.
@(private)
program_stage :: proc(r: ^Renderer, stage: ^rhi.Shader_Code, program: u32) -> ^rhi.Shader_Code {
	if program == 0 || program == GPU_NONE || stage == nil {return nil}
	program_name := ""
	for candidate in renderer_programs(r) {if candidate.id == program && candidate.domain == .Surface {program_name = candidate.name}}
	dot := strings.index_byte(stage.name, '.')
	if dot < 0 || program_name == "" {return nil}
	name, suffix := stage.name[:dot], stage.name[dot:]
	buffer: [256]u8
	for cut := len(name); cut > 0; cut -= 1 {
		if cut < len(name) && name[cut] != '_' {continue}
		wanted := fmt.bprintf(buffer[:], "%s__%s%s%s", name[:cut], program_name, name[cut:], suffix)
		if code := program_shader(r, wanted); code != nil {return code}
		if code := extension_shader(r, wanted); code != nil {return code}
	}
	return nil
}

// The Surface program of a material of the table; 0 for none.
pass_material_program :: proc(s: ^Stage_Pass, material: Material_Handle) -> u32 {
	materials := s.pass.r.scene.materials[:]
	return materials[material].program_id if int(material) < len(materials) else 0
}

// The Surface programs of what the clusters of a mesh show with a material
// (0: those of the mesh), each once and 0 for those without one, into
// `programs`: how many there are, past its length too. A stage draws them
// with the pipeline of each (pass_gbuffer_pipeline, Stage_Pipeline_Desc).
pass_mesh_programs :: proc(s: ^Stage_Pass, mesh: Mesh_Handle, material: Material_Handle, programs: []u32) -> (count: int) {
	add :: proc(programs: []u32, count: ^int, program: u32) {
		for held in programs[:min(count^, len(programs))] {if held == program {return}}
		if count^ < len(programs) {programs[count^] = program}
		count^ += 1
	}
	if material != 0 {
		add(programs, &count, pass_material_program(s, material))
		return
	}
	sc := &s.pass.r.scene
	if int(mesh) >= len(sc.meshes) {return}
	m := &sc.meshes[mesh]
	palette: [32]u32
	for packed in sc.indices[m.slot_word:][:m.slot_count] {
		add(programs, &count, pass_material_program(s, Material_Handle(instance_row(packed, GPU_NONE, &palette))))
	}
	if m.slot_count == 0 {add(programs, &count, 0)}
	return
}

// Draws `vertices` of a table of materials (thumbnail.vert) for a stage whose
// pipeline is in target: once for its materials without a program, and once
// for each Surface program among them with the stage of the program. Each
// draw names its program to the vertex stage as its first instance, which
// a list outside a frame takes as well as one inside; the vertex stage
// collapses the triangles of the others. now: as program_graphics.
@(private)
rows_programs_draw :: proc(r: ^Renderer, cmd: ^rhi.Command_List, target: ^rhi.Pipeline, rows: []Gpu_Material_Row, vertices: u32, now := false) {
	draw :: proc(cmd: ^rhi.Command_List, program, vertices: u32) {rhi.cmd_draw(cmd, vertices, 1, 0, program)}
	plain := len(rows) == 0
	for row in rows {plain ||= row.program_id == 0}
	if plain {
		rhi.cmd_bind_pipeline(cmd, target^)
		draw(cmd, 0, vertices)
	}
	// The programs of the rows, in order of id, each once.
	last := u32(0)
	for {
		next := max(u32)
		for row in rows {if row.program_id > last && row.program_id < next {next = row.program_id}}
		if next == max(u32) {return}
		rhi.cmd_bind_pipeline(cmd, program_graphics(r, target, next, now))
		draw(cmd, next, vertices)
		last = next
	}
}

// Draws `count` vertices of the UI (ui.frag) from `first` of `vertices`,
// which went to the buffer from `base`, for a stage whose pipeline is in
// target: in runs of triangles in their order, each with the stage of the
// Surface program of the material its studio previews show
// (UI_MATERIAL_PREVIEW_BIT), so that what is drawn keeps its order. bound:
// the pipeline bound, which it leaves as the last it binds.
@(private)
ui_programs_draw :: proc(r: ^Renderer, cmd: ^rhi.Command_List, target: ^rhi.Pipeline, vertices: []Ui_Vertex, base, first, count: int, bound: ^rhi.Pipeline) {
	s := &r.scene
	program_of :: proc(s: ^Scene_State, vertex: Ui_Vertex) -> u32 {
		if vertex.material & UI_MATERIAL_PREVIEW_BIT == 0 {return 0}
		row := vertex.material &~ UI_MATERIAL_PREVIEW_BIT
		return s.materials[row].program_id if int(row) < len(s.materials) else 0
	}
	end := first + count
	run_first, run_program := first, u32(0)
	for at := first; at <= end; at += 3 {
		program := u32(0)
		if at < end && s.programmed_rows > 0 {program = program_of(s, vertices[at])}
		if at < end && (at == run_first || program == run_program) {
			run_program = program
			continue
		}
		if at > run_first {
			pipeline := program_graphics(r, target, run_program)
			if pipeline != bound^ {rhi.cmd_bind_pipeline(cmd, pipeline); bound^ = pipeline}
			rhi.cmd_draw(cmd, u32(at - run_first), 1, u32(base + run_first))
		}
		run_first, run_program = at, program
	}
}

// Draws the clusters of an instance for a pass whose stage has its pipeline
// in target: those of its materials without a program with that pipeline,
// and those of each Surface program of its materials with the stage of the
// program. Each draw names its program to gbuffer.vert, which collapses the
// clusters of the others.
@(private)
instance_programs_draw :: proc(r: ^Renderer, cmd: ^rhi.Command_List, target: ^rhi.Pipeline, instance: u32, level0: bool) {
	s := &r.scene
	inst := &s.instances[instance]
	mesh := inst.meta.x & INSTANCE_MESH_MASK
	if int(mesh) >= len(s.meshes) {return}
	m := &s.meshes[mesh]
	program_of :: proc(s: ^Scene_State, inst: ^Gpu_Instance, packed: u32) -> u32 {
		row := instance_row(packed, inst.meta.y, &inst.slot_materials)
		return s.materials[row].program_id if int(row) < len(s.materials) else 0
	}
	slots := s.indices[m.slot_word:][:m.slot_count]
	plain := len(slots) == 0
	for packed in slots {plain ||= program_of(s, inst, packed) == 0}
	if plain {
		rhi.cmd_bind_pipeline(cmd, target^)
		instance_clusters_draw(r, cmd, instance, level0, 0)
	}
	// The programs of its materials, in order of id, each once.
	last := u32(0)
	for {
		next := max(u32)
		for packed in slots {
			if program := program_of(s, inst, packed); program > last && program < next {next = program}
		}
		if next == max(u32) {return}
		rhi.cmd_bind_pipeline(cmd, program_graphics(r, target, next))
		instance_clusters_draw(r, cmd, instance, level0, next)
		last = next
	}
}
