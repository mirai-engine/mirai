package mirai_render

import "core:fmt"
import "mirai:rhi"
import "mirai:render/abi"

// Material points (shaders/include/points.slang): where a pass needs a
// Surface program evaluated. A pass starts a batch (points_begin); its
// threads append the points they need and a head for what they resume;
// points_resolve counts and lists the points by program and runs the stage
// of each program in use over its own (surface_points__<program>.comp); the
// pass then resumes over the heads (points_resume), which may append points
// for another round. No other stage of the engine runs a program. The points
// of a program whose stage has no pipeline yet (pipeline_thread.odin) are
// read as the rows of their materials.

POINTS_START :: 1 << 16 // points the buffer holds at first; it grows to what a frame asked for
POINTS_MAX :: 1 << 21 // the most points it holds: past them a pass does without the programs
POINTS_PROGRAM_CAPACITY :: 1024 // bins the groups of points.comp and cull_programs.comp aggregate (BINS_MAX of bins.slang)
@(private) POINTS_HEADER :: abi.POINTS_HEADER
@(private) POINT_WORDS :: abi.POINT_WORDS
@(private) RECORD_WORDS :: abi.RECORD_WORDS
@(private) HEAD_WORDS :: abi.HEAD_WORDS
// Words of the header.
@(private) POINTS_WANTED :: abi.POINTS_WANTED
@(private) POINTS_ARGS :: abi.POINTS_ARGS
@(private) POINTS_HEAD_ARGS :: abi.POINTS_HEAD_ARGS

Material_Points :: struct {
	buffer:    rhi.Buffer,
	capacity:  u32, // points a batch holds at once
	programs:  u32, // bins: the largest Surface program id of the catalog, plus one
	wanted:    u32, // the most points a batch asked for, read back: the buffer grows to it
	readback:  [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	using stages: Program_Computes, // of surface_points__<program>.comp
	started:   bool, // a batch started this frame: the next one keeps what it asked for
}

// The pipelines of a compute stage of the engine compiled for each Surface
// program (<stem>__<program>.comp), by id, asked for when first needed.
Program_Computes :: struct {
	pipelines: [POINTS_PROGRAM_CAPACITY]rhi.Pipeline, // 0 until made, or when the shaders have no such stage
	codes:     [POINTS_PROGRAM_CAPACITY]^rhi.Shader_Code, // and the code it was made with
	asked:     [POINTS_PROGRAM_CAPACITY]bool,
}

// The buffer of the frame, as large as the frames before asked for. Without a
// Surface program in the catalog it is a header that takes no point.
@(private)
points_prepare :: proc(r: ^Renderer) -> bool {
	m := &r.points
	programs: u32
	for program in renderer_programs(r) {
		if program.domain == .Surface && program.id < POINTS_PROGRAM_CAPACITY {programs = max(programs, program.id + 1)}
	}
	capacity: u32
	if programs > 0 {
		wanted := min(max(u32(POINTS_START), m.wanted), POINTS_MAX)
		capacity = m.capacity if wanted <= m.capacity else min(wanted + wanted / 2, POINTS_MAX)
	}
	if m.buffer != 0 && capacity == m.capacity && programs == m.programs {return true}
	if m.buffer != 0 {rhi.buffer_destroy(r.device, m.buffer)}
	words := u64(POINTS_HEADER) + 6 * u64(programs) + u64(capacity) * (POINT_WORDS + RECORD_WORDS + 1 + HEAD_WORDS)
	m.buffer = rhi.buffer_create(r.device, {size = words * size_of(u32), usage = {.Storage, .Indirect}, name = "material points"})
	for &b in m.readback {
		if b == 0 {b = rhi.buffer_create(r.device, {size = size_of(u32), memory = .Readback, name = "material points readback"})}
	}
	m.capacity, m.programs = capacity, programs
	made := m.buffer != 0
	for b in m.readback {made &&= b != 0}
	if !made {
		set_error(r, "material points: %s", rhi.device_error(r.device))
		return false
	}
	// The header of a buffer no batch has started takes no point.
	header: [POINTS_HEADER]u32
	if !rhi.buffer_upload_slice(r.device, m.buffer, 0, header[:]) {
		set_error(r, "material points: %s", rhi.device_error(r.device))
		return false
	}
	return true
}

@(private)
points_destroy :: proc(r: ^Renderer) {
	m := &r.points
	points_pipelines_destroy(r)
	if m.buffer != 0 {rhi.buffer_destroy(r.device, m.buffer)}
	for b in m.readback {if b != 0 {rhi.buffer_destroy(r.device, b)}}
	m^ = {}
}

// With the GPU idle: when the shaders they were made from go.
@(private)
points_pipelines_destroy :: proc(r: ^Renderer) {
	program_computes_destroy(r, &r.points.stages)
	program_computes_destroy(r, &r.vertex_stages)
}

@(private)
program_computes_destroy :: proc(r: ^Renderer, table: ^Program_Computes) {
	for &pipeline, id in table.pipelines {
		if pipeline != 0 {rhi.pipeline_destroy(r.device, pipeline)}
		pipeline, table.asked[id], table.codes[id] = 0, false, nil
	}
}

// With the GPU idle, before the renderer takes the stages of programs of
// another generation, next: the pipelines whose code is the same stay.
@(private)
program_computes_publish :: proc(r: ^Renderer, table: ^Program_Computes, next: []rhi.Shader_Code) {
	for &pipeline, id in table.pipelines {
		if code := program_code_same(next, table.codes[id]); code != nil && pipeline != 0 {
			table.codes[id] = code
			continue
		}
		if pipeline != 0 {rhi.pipeline_destroy(r.device, pipeline)}
		pipeline, table.asked[id], table.codes[id] = 0, false, nil
	}
}

// The stage <stem>__<program>.comp of a Surface program; 0 until it is made
// (pipeline_thread.odin), or when the shaders have none.
@(private)
program_compute :: proc(r: ^Renderer, table: ^Program_Computes, program: Program, stem, label: string) -> rhi.Pipeline {
	if program.id >= POINTS_PROGRAM_CAPACITY {return 0}
	if !table.asked[program.id] {
		table.asked[program.id] = true
		name: [192]u8
		if code := program_shader(r, fmt.bprintf(name[:], "%s__%s.comp", stem, program.name)); code != nil {
			table.codes[program.id] = code
			table.asked[program.id] = pipeline_make(r, &table.pipelines[program.id], compute = {shader = code, name = label})
		}
	}
	return table.pipelines[program.id]
}

// The stage of a Surface program over its points.
@(private)
points_pipeline :: proc(r: ^Renderer, program: Program) -> rhi.Pipeline {
	return program_compute(r, &r.points.stages, program, "surface_points", "surface points")
}

// Whether the passes of the frame need batches: a material of the scene has a program.
@(private)
points_needed :: proc(r: ^Renderer) -> bool {
	return r.points.capacity > 0 && r.scene.programmed_rows > 0
}

// Binds the buffer where the passes find it.
@(private)
points_bind :: proc(p: ^Pass) {
	rhi.cmd_bind_buffer(p.cmd, SLOT_POINTS, p.r.points.buffer if p.r.points.buffer != 0 else p.r.dummy_buffer)
}

@(private)
points_dispatch :: proc(p: ^Pass, mode: u32, x: u32 = 1, indirect: bool = false) {
	r, cmd := p.r, p.cmd
	m := &r.points
	Params :: struct {mode, capacity, programs, frame_start: u32}
	params := Params{mode = mode, capacity = m.capacity, programs = m.programs}
	if mode == 0 && !m.started {params.frame_start = 1}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Points])
	set_params(cmd, &params)
	points_bind(p)
	if indirect {
		rhi.cmd_dispatch_indirect(cmd, m.buffer, POINTS_ARGS * size_of(u32))
	} else {
		rhi.cmd_dispatch(cmd, x, 1)
	}
	rhi.cmd_barrier_buffer(cmd, m.buffer, .Shader_Write)
}

// Starts the batch of a pass: its threads after it append their points and
// heads. False when the frame needs none, or for a pass whose only points are
// the filters of glass (`filters`) when no glass has a program: the pass runs
// without rounds.
@(private)
points_begin :: proc(p: ^Pass, filters := false) -> bool {
	m := &p.r.points
	if !points_needed(p.r) || (filters && p.r.scene.programmed_glass == 0) {return false}
	rhi.cmd_barrier_buffer(p.cmd, m.buffer, .Shader_Write)
	points_dispatch(p, 0)
	m.started = true
	return true
}

// Evaluates the points appended since the last resolve, and readies the
// dispatch of a resume over the heads appended since. With one program in
// the scene its stage goes over the whole window, without binning it.
@(private)
points_resolve :: proc(p: ^Pass) {
	r, cmd := p.r, p.cmd
	m := &r.points
	whole := r.scene.programs_used == 1
	points_dispatch(p, 1, groups(max(m.programs, 1), 64))
	rhi.cmd_barrier_buffer(cmd, m.buffer, .Indirect_Read)
	if !whole {
		points_dispatch(p, 2, indirect = true)
		points_dispatch(p, 3)
		rhi.cmd_barrier_buffer(cmd, m.buffer, .Indirect_Read)
		points_dispatch(p, 4, indirect = true)
		rhi.cmd_barrier_buffer(cmd, m.buffer, .Indirect_Read)
	}
	// The stages of the programs write the records of disjoint points: no barrier between them.
	Params :: struct {program, whole, pad0, pad1: u32}
	for program in renderer_programs(r) {
		if program.domain != .Surface || program.id >= m.programs || r.scene.program_rows[program.id] == 0 {continue}
		pipeline := points_pipeline(r, program)
		if pipeline == 0 {continue}
		rhi.cmd_bind_pipeline(cmd, pipeline)
		params := Params{program = program.id, whole = u32(whole)}
		set_params(cmd, &params)
		points_bind(p)
		args := POINTS_ARGS if whole else POINTS_HEADER + 3 * m.programs + 3 * program.id
		rhi.cmd_dispatch_indirect(cmd, m.buffer, u64(args) * size_of(u32))
	}
	rhi.cmd_barrier_buffer(cmd, m.buffer, .Indirect_Read)
}

// A dispatch of the pipeline bound over the heads of the round, a group of
// 32 threads or more (POINTS_HEAD_GROUP) for each 32 of them along x.
@(private)
points_resume :: proc(p: ^Pass) {
	points_bind(p)
	rhi.cmd_dispatch_indirect(p.cmd, p.r.points.buffer, POINTS_HEAD_ARGS * size_of(u32))
	rhi.cmd_barrier_buffer(p.cmd, p.r.points.buffer, .Shader_Write)
}

// The rounds of a pass that started a batch (batch, from points_begin) and
// ran once: each evaluates what its threads appended and runs the pipeline
// again over the heads they left, with params.resume set.
@(private)
points_rounds :: proc(p: ^Pass, batch: bool, pipeline: rhi.Pipeline, params: ^$T, rounds: int) {
	if !batch {return}
	params.resume = 1
	for _ in 0 ..< rounds {
		points_resolve(p)
		rhi.cmd_bind_pipeline(p.cmd, pipeline)
		set_params(p.cmd, params)
		points_resume(p)
	}
	params.resume = 0
}

// At the end of the frame: what its batches asked for, to grow the buffer.
@(private)
points_end :: proc(r: ^Renderer, cmd: ^rhi.Command_List, slot: int) {
	m := &r.points
	if m.buffer == 0 || !m.started {return}
	m.started = false
	rhi.cmd_barrier_buffer(cmd, m.buffer, .Transfer_Read)
	rhi.cmd_copy_buffer(cmd, m.buffer, POINTS_WANTED * size_of(u32), m.readback[slot], 0, size_of(u32))
	rhi.cmd_barrier_buffer(cmd, m.readback[slot], .Host_Read)
}

@(private)
points_read :: proc(r: ^Renderer, slot: int) {
	m := &r.points
	if m.readback[slot] == 0 {return}
	if ptr := rhi.buffer_mapped(r.device, m.readback[slot]); ptr != nil {
		wanted := (cast(^u32)ptr)^
		if wanted > m.capacity {m.wanted = max(m.wanted, wanted)}
	}
}
