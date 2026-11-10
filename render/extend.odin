package mirai_render

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:render/abi"

// What an extension of the renderer records with. A plugin reaches all of it
// through engine/render: it imports neither this package nor the RHI.

// Where in a frame an extension records passes of its own.
Frame_Stage :: enum u8 {
	Geometry, // once a frame, before its views: the vertices an extension deforms
	Simulate, // once a frame, with the first view of the window after its G-buffer: what moves on the GPU against the depth of that view, the traced scene, its lights and probes
	Gbuffer,  // each view, after Simulate: surfaces an extension draws into the G-buffer, lit like the scene (pass_gbuffer_begin)
	Mask,     // each view, after its G-buffer: the pixels of the nested views an extension adds to it
	Surface,  // each view, after the G-buffers of its nested views: what changes its surfaces before they are lit
	Lit,      // each view, after composite and before what is blended: dispatches over the lit image of the opaque scene (pass_image_bind), on each side of glass
	Blend,    // each view, where blended surfaces go: over the lit image before the temporal resolve, on each side of glass (pass_blend_begin)
	Post,     // each view, as Output begins, after the exposure and before the PostProcess stack: dispatches over the resolved image, each writing the next one (pass_image_write)
	Effect,   // each effect view of the frame (Effect_View) after Simulate: what goes into a texture an interface shows, over nothing (pass_blend_begin); Stage_Pass.texture names it
	Custom,   // a pass of a render pipeline, where the pipeline puts it: dispatches over the resources it declares (pass_resource)
	Inspect,  // the view whose View_Inspection names it, after composite: dispatches over its image (pass_image_bind)
}

// Which side of the nearest layer of glass a pass of the Lit or Blend stage
// draws. With glass in view each runs twice: behind it, after the layers are
// drawn and before the glass reads what is behind; and in front, over the lit
// glass. Without, once. A pass draws what is on its side
// (pass_surface_read .Glass_Depth): a medium in Lit, what lies between the
// nearest layer and the opaque scene behind it and what lies between the eye
// and that layer in front.
Glass_Side :: enum u8 {
	All,    // no glass in view
	Behind, // behind the nearest layer
	Front,  // in front of it
}

// What an extension records the passes of a stage with: the view they are
// for, and the pass of the renderer its procedures draw through. Geometry has
// no view: its size and its matrix are zero.
Stage_Pass :: struct {
	stage:           Frame_Stage,
	width, height:   u32,  // of the targets of the view, in pixels
	eye:             Vec4, // where the view looks from; with w 0, the direction an orthographic one looks along
	view_projection: Mat4, // of the view, without its jitter, from its eye: it takes a place minus camera.position
	world:           u64,  // the world the frame draws (scene_world): an extension records what is of it alone
	origin:          Vec3, // what the places of the frame are relative to (origin.odin): eye and view_projection are, and what a pass writes for the GPU must be (origin_point and the others)
	frame:           u64,  // the frame being recorded: what an extension uploads once a frame (pass_rows_upload) it uploads again when this changes
	time:            f32,  // seconds of the world shown
	glass:           Glass_Side, // Lit and Blend
	texture:         Texture_Handle, // Effect: the texture of the effect view
	pass:            ^Pass,
	uses:            []Render_Use, // Custom: what the pass declared
	output_width, output_height: u32, // the size the view is shown at: that of the image of Post
	delta_time:      f32,  // seconds of the world since the frame before, over which the motion of the view went
	// Custom: what a pass in place of the Resolve stage resolves with.
	jitter, previous_jitter:     Vec2, // the offset of the projection in pixels, x right and y down, of this frame and of the frame before
	jitter_phases:   u32,  // of the sequence the jitter follows (Render_Jitter); 0: none
	camera:          Camera, // of the view, relative to origin as eye
	history:         bool, // the resources with history or kept hold what the frame before of the view left: false after a cut, a resize or another pipeline
	history_frames:  u32,  // the frames the view was drawn with them; 0 while !history
}

// The slots a custom pass binds (pass_resource, pass_constants): the first
// ten are SLOT_PASS0 to SLOT_PASS9, the rest the bindings of the tables of
// the scene, which the renderer binds again after the pass. A pass that binds
// those reads nothing of the scene. A shader declares a slot by its binding.
CUSTOM_PASS_SLOTS :: 24
@(rodata)
CUSTOM_PASS_BINDINGS := [CUSTOM_PASS_SLOTS]u32{
	SLOT_PASS0, SLOT_PASS1, SLOT_PASS2, SLOT_PASS3, SLOT_PASS4, SLOT_PASS5, SLOT_PASS6, SLOT_PASS7, SLOT_PASS8, SLOT_PASS9,
	SLOT_INSTANCES, SLOT_MESHES, SLOT_VERTICES, SLOT_INDICES, SLOT_MATERIALS, SLOT_LIGHTS, SLOT_LIGHT_TREE,
	SLOT_BLAS_NODES, SLOT_BLAS_TRIANGLES, SLOT_TLAS_NODES, SLOT_TLAS_REFS, SLOT_PROBES, SLOT_IRRADIANCE, SLOT_POINTS,
}

// The binding of a slot of a pass; false past those of its stage.
@(private)
pass_slot :: proc "contextless" (s: ^Stage_Pass, slot: u32) -> (u32, bool) {
	limit := u32(CUSTOM_PASS_SLOTS) if s.stage == .Custom else SLOT_PASS9 - SLOT_PASS0 + 1
	if slot >= limit {return 0, false}
	return CUSTOM_PASS_BINDINGS[slot], true
}

// Records the passes of an extension at a stage.
Stage_Proc :: #type proc(s: ^Stage_Pass, user: rawptr)

Frame_Pass :: struct {
	stage:  Frame_Stage,
	record: Stage_Proc,
	user:   rawptr,
}

FRAME_PASS_CAPACITY :: 32
NESTED_VIEW_CAPACITY :: abi.NESTED_VIEW_CAPACITY

// A view drawn inside some pixels of another, with its projection and its
// jitter: what the camera of that view would see carried by a transform that
// keeps distances, rigid or a mirror. An extension adds it in the Mask stage
// of the view and draws its mask.
Nested_View :: struct {
	to_world:   Mat4,   // carries the camera of the view to the nested one; places of the world, as every one an extension gives
	previous:   Mat4,   // the same in the previous frame
	clip_plane: Vec4,   // of the world the nested view shows: nothing behind it is drawn
	layers:     u32,    // the instances it draws; 0: every one
	rect:       [4]i32, // the pixels of the view its mask may cover: x, y, width, height. Zero: any
	opening:    Vec4,   // the plane its mask is on, in the world of the view: what is drawn over the view (lines, panels) is in front of its pixels only in front of this. Zero: not known
}

// Asks the next frame to call `record` at a stage: every view for Gbuffer,
// Mask, Surface, Lit, Blend and Post, every effect view for Effect, once for
// Geometry and Simulate. Passes run in
// the order they were asked for; asking again for one the frame has is
// asking once. False without room for another one. A Custom pass goes in a
// render pipeline, and an Inspect one in the View_Inspection of a view.
frame_pass :: proc(r: ^Renderer, stage: Frame_Stage, record: Stage_Proc, user: rawptr = nil) -> bool {
	if record == nil || stage == .Custom || stage == .Inspect {return false}
	for pass in r.passes[:r.pass_count] {
		if pass.stage == stage && pass.record == record && pass.user == user {return true}
	}
	if r.pass_count >= len(r.passes) {return false}
	r.passes[r.pass_count] = {stage, record, user}
	r.pass_count += 1
	return true
}

// The targets of the G-buffer a view has only while a surface needs them:
// what it reflects other than the default dielectric, and the layers of its
// material.
@(private)
Gbuffer_Target :: enum u8 {Reflectance, Layers}

// Tells the next frame that its Gbuffer stage draws surfaces of a mesh of the
// scene with a material (0: those of the mesh), wherever they are: every view
// draws its G-buffer with the targets they need. Ask in each frame that draws
// them.
frame_gbuffer_mesh :: proc(r: ^Renderer, mesh: Mesh_Handle, material: Material_Handle) {
	s := &r.scene
	if int(mesh) >= len(s.meshes) || r.gbuffer_asked == {.Reflectance, .Layers} {return}
	row := u32(material) if material != 0 && int(material) < len(s.materials) else GPU_NONE
	_, _, _, reflectance, layered, _, _ := instance_alpha(s, s.meshes[mesh], row, {})
	if reflectance {r.gbuffer_asked += {.Reflectance}}
	if layered {r.gbuffer_asked += {.Layers}}
}

// Tells the frame that an extension draws every cluster of level 0 of a mesh
// of the scene, where the cull of the scene does not see it (the meshes of
// particles): a mesh whose pages stream loads them all, and keeps them while
// it asks. Ask in each frame that draws it.
frame_mesh_whole :: proc(r: ^Renderer, mesh: Mesh_Handle) {
	if int(mesh) < len(r.scene.meshes) {r.scene.meshes[mesh].whole = r.frame + 1}
}

// A technique of anti-aliasing an extension resolves, by a pipeline whose
// pass stands in place of the Resolve stage: a choice of the graphics settings.
Antialiasing_Desc :: struct {
	name:  [ANTIALIASING_NAME_BYTES]u8, // what the graphics settings keep
	label: [ANTIALIASING_NAME_BYTES]u8, // what a menu shows
}
ANTIALIASING_CAPACITY :: 8
ANTIALIASING_NAME_BYTES :: 24
// The names of the techniques of the renderer, which no extension offers.
ANTIALIASING_OFF :: "off"
ANTIALIASING_TAA :: "taa"

// Offers a technique for the next frame; an extension offers it in every
// frame it can resolve it. False without room, with a name or a label of
// ANTIALIASING_NAME_BYTES or more, one of the renderer or one offered already.
antialiasing_offer :: proc(r: ^Renderer, name, label: string) -> bool {
	if r.antialiasing_count >= len(r.antialiasing) || name == "" || len(name) >= ANTIALIASING_NAME_BYTES || len(label) >= ANTIALIASING_NAME_BYTES {return false}
	if name == ANTIALIASING_OFF || name == ANTIALIASING_TAA {return false}
	for &offered in r.antialiasing[:r.antialiasing_count] {
		if base.text_get(offered.name[:]) == name {return false}
	}
	d := &r.antialiasing[r.antialiasing_count]
	d^ = {}
	base.text_set(d.name[:], name)
	base.text_set(d.label[:], label if label != "" else name)
	r.antialiasing_count += 1
	return true
}

// The techniques extensions offered for the last frame, besides Off and TAA.
renderer_antialiasing :: proc(r: ^Renderer) -> []Antialiasing_Desc {
	return r.antialiasing_offered[:r.antialiasing_offered_count]
}

@(private)
stage_pass :: proc(p: ^Pass, stage: Frame_Stage) -> (s: Stage_Pass) {
	s = {stage = stage, pass = p, world = p.r.world_key, origin = p.r.origin, frame = p.r.frame, time = p.r.time, glass = p.glass}
	if p.view != nil {
		s.width, s.height, s.eye, s.view_projection, s.camera = p.t.width, p.t.height, p.frame.eye, p.unjittered, p.camera
		s.output_width, s.output_height, s.delta_time = p.t.output_width, p.t.output_height, p.r.delta_time
	}
	return
}

// Whether an extension asked for a pass of the stage in this frame.
@(private)
stage_asked :: proc(r: ^Renderer, stage: Frame_Stage) -> bool {
	for pass in r.passes[:r.pass_count] {if pass.stage == stage {return true}}
	return false
}

@(private)
stage_run :: proc(p: ^Pass, stage: Frame_Stage) {
	s := stage_pass(p, stage)
	ran := false
	for pass in p.r.passes[:p.r.pass_count] {
		if pass.stage != stage {continue}
		pass.record(&s, pass.user)
		ran = true
	}
	// The passes of an extension bind what they need over the tables of the scene.
	if ran && p.view != nil {bind_scene_table(p)}
}

// The pass of the mode of inspection an extension shows in this view.
@(private)
stage_inspect :: proc(p: ^Pass) {
	rhi.cmd_timestamp(p.cmd, "inspection")
	s := stage_pass(p, .Inspect)
	p.inspection.record(&s, p.inspection.user)
	bind_scene_table(p)
}

// Binds the image of the view at SLOT_PASS0 + slot for the dispatches of the
// Lit and Inspect stages, to read and write (rgba16f): what composite left.
// In Lit, the lit image of the opaque scene in render units, before exposure,
// which glass, the Blend stage and the temporal resolve take next; in front of
// glass (Glass_Side), that image with the lit glass over it. In Inspect, that
// image or the one of View_Inspection.mode, in linear values shown clamped to
// [0, 1], without exposure or display transform. In Post, to read alone: the
// image so far (pass_image_write). False in another stage.
pass_image_bind :: proc(s: ^Stage_Pass, slot: u32) -> bool {
	if s.stage != .Lit && s.stage != .Inspect && s.stage != .Post || slot > SLOT_PASS9 - SLOT_PASS0 {return false}
	rhi.cmd_bind_texture(s.pass.cmd, SLOT_PASS0 + slot, s.pass.shown if s.stage == .Post else s.pass.t.display)
	return true
}

// In Post, binds the image so far at SLOT_PASS0 + read, to read, and the next
// one at SLOT_PASS0 + write, to write (rgba16f, output_width by
// output_height), which is the image from then on: the passes after it, the
// PostProcess stack and the tonemap read it. At first it is the resolved
// image, in render units before exposure, which the temporal resolve keeps as
// its history: a pass never writes the image it reads. The dispatches that
// write the next image write every pixel of it. False in another stage or
// without room for the image.
pass_image_write :: proc(s: ^Stage_Pass, read, write: u32) -> bool {
	p := s.pass
	if s.stage != .Post || read > SLOT_PASS9 - SLOT_PASS0 || write > SLOT_PASS9 - SLOT_PASS0 || read == write {return false}
	next := postprocess_next(p.r, p.t, p.shown, false)
	if next == 0 {return false}
	rhi.cmd_bind_texture(p.cmd, SLOT_PASS0 + read, p.shown)
	rhi.cmd_bind_texture(p.cmd, SLOT_PASS0 + write, next)
	p.shown = next
	return true
}

// A pipeline of an extension for the passes of a stage, from the stages
// <shader>.vert and <shader>.frag of the shaders in use, or <shader>.comp for
// Geometry, Simulate, Lit, Post, Custom and Inspect, and for Surface with compute:
// a dispatch outside pass_surface_begin that reads the surfaces
// (pass_surface_read). Without a <shader>.vert its vertices are those of one
// triangle over the view, drawn with three vertices. One of Mask draws in
// pass_mask_begin; one of Surface blends into the targets it names, in their
// order, in a pass_surface_begin with them; one of Blend into the lit image
// with blend and into the coverage TAA reads, adding, in pass_blend_begin.
// Gbuffer takes pass_gbuffer_pipeline instead. A compute stage that traces
// rays declares the variant hw (//! variant) and the constant color
// (//! constant), and its pipeline is that of the rays the renderer traces,
// as for the stages of the engine: by hardware, and through the filters of
// glass with colored shadows.
// A graphics stage whose source marks it `//! per surface program` draws the
// materials of a Surface program with the fragment stage of that program:
// program names it (pass_material_program), 0 for those without one.
Stage_Pipeline_Desc :: struct {
	stage:   Frame_Stage,
	shader:  string,
	targets: Surface_Targets,
	blend:   rhi.Blend_Mode,
	compute: bool, // Surface: <shader>.comp
	name:    string,
	fragment:string, // of a graphics stage: <fragment>.frag instead of <shader>.frag
	program: u32, // of a graphics stage: the Surface program of the materials its draws show
}

STAGE_PIPELINE_CAPACITY :: 1024 // a stage of each Vfx program is a pipeline of its own

@(private)
Stage_Pipeline :: struct {
	key:      u64,
	pipeline: rhi.Pipeline, // 0: the shaders in use have no such stages, or that of a program is not made yet
	asked:    bool,
	program:  u32, // the Surface program whose fragment stage it draws with (pipeline_thread.odin)
	code:     ^rhi.Shader_Code, // and that stage
}

// The pipeline of a description. The renderer makes it the first time it is
// asked for and keeps it until the shaders change, so an extension asks for it
// in every frame it draws and owns nothing. 0 while the shaders in use do not
// have its stages, or without room for another one. With a program, that of
// the description without it until the one of the program is made
// (pipeline_thread.odin): the materials of the program are drawn as their rows.
stage_pipeline :: proc(r: ^Renderer, desc: Stage_Pipeline_Desc) -> rhi.Pipeline {
	if desc.stage == .Gbuffer {set_error(r, "the pipeline of the Gbuffer stage %s depends on the view: ask pass_gbuffer_pipeline in the pass", desc.shader); return 0}
	compute := desc.stage != .Mask && desc.stage != .Blend && desc.stage != .Effect && (desc.stage != .Surface || desc.compute)
	hardware := compute && r.hardware_rt
	colored := compute && r.settings.colored_shadows && len(r.scene.translucent) > 0
	program := desc.program if !compute && desc.program != GPU_NONE else 0
	plain: rhi.Pipeline
	if program != 0 {
		without := desc
		without.program = 0
		if plain = stage_pipeline(r, without); plain == 0 {return 0}
	}
	key := base.name_hash(desc.shader) ~ base.name_hash(desc.fragment) * 31 ~ (u64(desc.stage) + 1) << 56 ~ u64(transmute(u8)desc.targets) << 48 ~ u64(desc.blend) << 40 ~ u64(hardware) << 39 ~ u64(colored) << 38 ~ u64(compute) << 37 ~ u64(program) * 0x9E3779B97F4A7C15
	free: ^Stage_Pipeline
	for &entry in r.stage_pipelines {
		if entry.asked && entry.key == key {return entry.pipeline if entry.pipeline != 0 else plain}
		if !entry.asked && free == nil {free = &entry}
	}
	if free == nil {set_error(r, "no room for the pipeline of the stage %s", desc.shader); return plain}
	free.key, free.asked = key, true
	names: [2][192]u8
	switch {
	case compute:
		variants := [2]string{"_hw", ""}
		for variant in variants {
			if variant == "_hw" && !hardware {continue}
			if code := extension_shader(r, fmt.bprintf(names[0][:], "%s%s.comp", desc.shader, variant)); code != nil {
				constants: rhi.Shader_Constants
				if colored {constants, _ = rhi.shader_constant(code, "color")}
				free.pipeline = rhi.pipeline_create_compute(r.device, {shader = code, constants = constants, name = desc.name})
				break
			}
		}
	case:
		vertex := extension_shader(r, fmt.bprintf(names[0][:], "%s.vert", desc.shader))
		fragment := extension_shader(r, fmt.bprintf(names[1][:], "%s.frag", desc.fragment if desc.fragment != "" else desc.shader))
		if vertex == nil {vertex = &r.shader_codes[.Fullscreen_Vert]}
		if fragment == nil {break}
		made := rhi.Graphics_Pipeline_Desc{vertex = vertex, fragment = fragment, cull = .None, name = desc.name}
		if desc.stage == .Mask {
			made.color_formats, made.color_count = {0 = .RGBA16_Float, 1 = .R32_Float}, 2
			made.depth_format, made.depth_test, made.depth_write, made.depth_compare = .D32_Float, true, true, .Greater
		} else if desc.stage == .Blend || desc.stage == .Effect {
			made.color_formats, made.color_count, made.blend = {0 = .RGBA16_Float, 1 = .R8_Unorm}, 2, {0 = desc.blend, 1 = .Additive}
			made.depth_format, made.depth_test, made.depth_compare = .D32_Float, true, .Greater
		} else {
			formats := [Surface_Target]rhi.Format{.Albedo = .RGBA8_Srgb, .Normal = .RGBA16_Float, .Emission = .RGBA16_Float}
			for format, target in formats {
				if target not_in desc.targets {continue}
				made.color_formats[made.color_count], made.blend[made.color_count] = format, desc.blend
				made.color_count += 1
			}
		}
		if program == 0 {
			free.pipeline = rhi.pipeline_create_graphics(r.device, made)
			break
		}
		free.program, free.code = program, program_stage(r, fragment, program)
		if free.code == nil {break}
		made.fragment = free.code
		if !pipeline_make(r, &free.pipeline, graphics = made) {free^ = {}}
	}
	return free.pipeline if free.pipeline != 0 else plain
}

// The same, in a pass.
pass_stage_pipeline :: proc(s: ^Stage_Pass, desc: Stage_Pipeline_Desc) -> rhi.Pipeline {
	return stage_pipeline(s.pass.r, desc)
}

// With the GPU idle: when the shaders they were made from go, and with the renderer.
@(private)
stage_pipelines_destroy :: proc(r: ^Renderer) {
	for entry in r.stage_pipelines {if entry.pipeline != 0 {rhi.pipeline_destroy(r.device, entry.pipeline)}}
	r.stage_pipelines = {}
}

// Adds a nested view to the view being recorded, in its Mask stage. Returns
// the index its mask writes for its pixels, in the alpha of the motion target
// as 1 + index; 0 when the view has no room for another, or the shaders in use
// do not know nested views.
pass_nested_add :: proc(s: ^Stage_Pass, nested: Nested_View) -> u32 {
	p := s.pass
	if p.view == nil || !p.r.frame_layout.nested || p.nested_count >= NESTED_VIEW_CAPACITY || p.r.pipelines[.Gbuffer_Nested] == 0 {return 0}
	nested := nested
	nested.to_world = origin_transform(nested.to_world, p.r.origin)
	nested.previous = origin_transform(nested.previous, p.r.origin)
	nested.clip_plane = origin_plane(nested.clip_plane, p.r.origin)
	nested.opening = origin_plane(nested.opening, p.r.origin)
	p.nested[p.nested_count] = nested
	p.nested_count += 1
	index := u32(p.nested_count)
	if p.constants.ptr != nil {
		block := cast(^Gpu_Nested)rawptr(uintptr(p.constants.ptr) + uintptr(size_of(Gpu_Frame) + (p.nested_count - 1) * size_of(Gpu_Nested)))
		block.to_world = rows_3x4(nested.to_world)
		block.from_world_previous = rows_3x4(linalg.inverse(nested.previous))
		eye := point_carried(nested.to_world, p.frame.eye.xyz) if p.frame.eye.w > 0.5 else vector_carried(nested.to_world, p.frame.eye.xyz)
		block.eye = {eye.x, eye.y, eye.z, p.frame.eye.w}
		block.opening = nested.opening
	}
	return index
}

// What an extension keeps in the constants of the view being recorded: the
// bytes of the struct it declared for them, zero until it writes them. Empty
// when the shaders in use do not have it.
pass_extension_data :: proc(s: ^Stage_Pass, name: string) -> []u8 {
	p := s.pass
	if p.constants.ptr == nil {return nil}
	for extension in p.r.frame_layout.extensions[:p.r.frame_layout.extension_count] {
		if extension.name == name {return ([^]u8)(p.constants.ptr)[extension.offset:][:extension.size]}
	}
	return nil
}

// Begins the pass in which an extension draws the mask of its nested views:
// over the motion target (rg 0, b 0, a 1 + the index of the nested view) and
// the linear depth (0: nothing drawn there yet), with the depth buffer of the
// view, which the mask also writes: what is in front of it stays, and what is
// behind it is not of this view any longer. Ends with pass_end.
pass_mask_begin :: proc(s: ^Stage_Pass, name := "nested view mask") {
	p := s.pass
	t := p.t
	rhi.cmd_timestamp(p.cmd, name)
	pass := rhi.Render_Pass_Desc{color_count = 2, name = name}
	pass.colors[0] = {texture = t.motion, load = .Load, store = .Store}
	pass.colors[1] = {texture = t.linear_depth, load = .Load, store = .Store}
	pass.depth = {texture = t.depth, load = .Load, store = .Store}
	rhi.cmd_begin_render_pass(p.cmd, &pass)
}

// The targets of the G-buffer that say what a surface is: base color with
// metallic in alpha, normal with roughness, emission with occlusion.
Surface_Target :: enum u8 {Albedo, Normal, Emission}
Surface_Targets :: bit_set[Surface_Target;u8]

// What a pass over the surfaces of a view, or one of its Simulate, Blend,
// Post or Inspect stages, may read of it: its linear depth, its motion, the surfaces
// the pass does not draw and, while the shaders in use ask for it (`//! mirai
// needs instance_ids`), the instance that drew each pixel + 1 (R32 uint; 0:
// none, or a surface of the Gbuffer stage). Glass_Depth: in Lit and Blend,
// the linear depth of the nearest layer of glass (0 where there is none),
// which a pass behind it draws only behind and one in front only in front;
// nothing without glass. Direct: in
// Lit, the direct light the surfaces reflect, in the lit image already. Post
// reads what the Output stage does (stage_contract): Linear_Depth, Motion,
// Albedo, Normal and Emission, at the size of the targets of the view.
Surface_Source :: enum u8 {Linear_Depth, Motion, Albedo, Normal, Emission, Instance, Glass_Depth, Direct}

// Begins the pass in which an extension draws surfaces into the G-buffer of
// the view, in the Gbuffer stage, with the depth buffer of the view: the
// pipelines of pass_gbuffer_pipeline, the index buffer of pass_indices and
// draws of pass_draw_indexed_indirect. Ends with pass_end.
pass_gbuffer_begin :: proc(s: ^Stage_Pass, name := "extension surfaces") {
	p := s.pass
	sc := &p.r.scene
	rhi.cmd_timestamp(p.cmd, name)
	for b in ([]rhi.Buffer{sc.vertex_buffer, sc.material_buffer}) {if b != 0 {rhi.cmd_barrier_buffer(p.cmd, b, .Shader_Read)}}
	if sc.index_buffer != 0 {rhi.cmd_barrier_buffer(p.cmd, sc.index_buffer, .Shader_Read)}
	targets, count := gbuffer_targets(p)
	pass := rhi.Render_Pass_Desc{color_count = count, name = name}
	for target, i in targets[:count] {pass.colors[i] = {texture = target, load = .Load, store = .Store}}
	pass.depth = {texture = p.t.depth, load = .Load, store = .Store}
	rhi.cmd_begin_render_pass(p.cmd, &pass)
}

// The pipeline of the Gbuffer stage that draws with <shader>.vert of the
// shaders in use, which fills a Gbuffer_Vertex (include/gbuffer_vertex.slang),
// into the targets of the G-buffer this view has, with the fragment of the
// engine: what the scene is drawn with. With fragment, <fragment>.frag of the
// shaders in use writes those targets instead, as gbuffer.frag does (the
// packing of gbuffer.slang), and declares its variants plain
// (MIRAI_GBUFFER_PLAIN) and layers (MIRAI_GBUFFER_LAYERS): the one of the
// view is taken. program: the Surface program of the materials its draws
// show (pass_mesh_programs), whose fragment stage it takes; 0 for those
// without one. 0 while the shaders in use do not have it, or without room for
// another one.
pass_gbuffer_pipeline :: proc(s: ^Stage_Pass, shader: string, name := "", fragment := "", program := u32(0)) -> rhi.Pipeline {
	p := s.pass
	r := p.r
	Variant :: enum u8 {Plain, Reflectance, Layers}
	variant := Variant.Layers if p.layered else .Reflectance if p.reflectance else .Plain
	ids := r.frame_layout.instance_ids
	program := program if program != GPU_NONE else 0
	// Until the pipeline of the program is made, that of the stage without it.
	plain: rhi.Pipeline
	if program != 0 {
		if plain = pass_gbuffer_pipeline(s, shader, name, fragment); plain == 0 {return 0}
	}
	key := base.name_hash(shader) ~ base.name_hash(fragment) * 31 ~ (u64(Frame_Stage.Gbuffer) + 1) << 56 ~ u64(variant) << 48 ~ u64(ids) << 47 ~ u64(program) * 0x9E3779B97F4A7C15
	free: ^Stage_Pipeline
	for &entry in r.stage_pipelines {
		if entry.asked && entry.key == key {return entry.pipeline if entry.pipeline != 0 else plain}
		if !entry.asked && free == nil {free = &entry}
	}
	if free == nil {set_error(r, "no room for the pipeline of the stage %s", shader); return plain}
	free.key, free.asked = key, true
	names: [2][192]u8
	vertex := extension_shader(r, fmt.bprintf(names[0][:], "%s.vert", shader))
	if vertex == nil {return 0}
	desc := rhi.Graphics_Pipeline_Desc{
		vertex = vertex, fragment = &r.shader_codes[.Gbuffer_Frag],
		color_formats = {0 = .RGBA8_Srgb, 1 = .RGBA16_Float, 2 = .RGBA16_Float, 3 = .RGBA16_Float, 4 = .R32_Float, 5 = .RGBA8_Srgb}, color_count = 6,
		depth_format = .D32_Float, depth_test = true, depth_write = true, depth_compare = .Greater, cull = .None,
		name = name if name != "" else shader,
	}
	switch variant {
	case .Reflectance:
	case .Plain:  desc.fragment, desc.color_count = &r.shader_codes[.Gbuffer_Plain_Frag], 5
	case .Layers: desc.fragment, desc.color_formats[6], desc.color_count = &r.shader_codes[.Gbuffer_Layers_Frag], .RGBA32_Uint, 7
	}
	if fragment != "" {
		suffixes := [Variant]string{.Plain = "_plain", .Reflectance = "", .Layers = "_layers"}
		desc.fragment = extension_shader(r, fmt.bprintf(names[1][:], "%s%s.frag", fragment, suffixes[variant]))
		if desc.fragment == nil {return 0}
	}
	if program == 0 {
		free.pipeline = rhi.pipeline_create_graphics(r.device, gbuffer_ids(desc, ids))
		return free.pipeline
	}
	free.program, free.code = program, program_stage(r, desc.fragment, program)
	if free.code != nil {
		desc.fragment = free.code
		if !pipeline_make(r, &free.pipeline, graphics = gbuffer_ids(desc, ids)) {free^ = {}}
	}
	return free.pipeline if free.pipeline != 0 else plain
}

// Begins the pass in which an extension blends into the lit image of the
// view, in the Blend stage: in render units before exposure, with the
// coverage TAA reads (the share of each pixel drawn over, which keeps less of
// its history) and the depth buffer of the view to test against. What the
// pass reads of the view (pass_surface_read) and of its buffers
// (pass_buffer_ready) is made readable before it. Ends with pass_end.
pass_blend_begin :: proc(s: ^Stage_Pass, name := "blended") {
	p := s.pass
	t := p.t
	rhi.cmd_timestamp(p.cmd, name)
	rhi.cmd_barrier_texture(p.cmd, t.linear_depth, .Shader_Read)
	if s.glass != .All && t.glass[0].depth != 0 {rhi.cmd_barrier_texture(p.cmd, t.glass[0].depth, .Shader_Read)}
	if p.r.scene.material_buffer != 0 {rhi.cmd_barrier_buffer(p.cmd, p.r.scene.material_buffer, .Shader_Read)}
	target := rhi.Render_Pass_Desc{color_count = 2, name = name}
	target.colors[0] = {texture = t.display, load = .Load, store = .Store}
	target.colors[1] = {texture = t.reactive, load = .Load if p.blended else .Clear, store = .Store}
	target.depth = {texture = t.depth, load = .Load, store = .Store}
	rhi.cmd_begin_render_pass(p.cmd, &target)
	p.blended = true
}

// Begins a pass over the surfaces of the G-buffer of the view, which its
// fragments blend into: the targets asked for, in the order of Surface_Target.
// The others, the linear depth and the motion target are not attached, so a
// shader of the pass may read them (pass_surface_read). Ends with pass_end.
pass_surface_begin :: proc(s: ^Stage_Pass, targets: Surface_Targets, name := "surfaces") {
	p := s.pass
	t := p.t
	textures := [Surface_Target]rhi.Texture{.Albedo = t.albedo, .Normal = t.normal, .Emission = t.emission}
	rhi.cmd_timestamp(p.cmd, name)
	rhi.cmd_barrier_texture(p.cmd, t.linear_depth, .Shader_Read)
	rhi.cmd_barrier_texture(p.cmd, t.motion, .Shader_Read)
	if t.instance != 0 {rhi.cmd_barrier_texture(p.cmd, t.instance, .Shader_Read)}
	pass := rhi.Render_Pass_Desc{name = name}
	for texture, target in textures {
		if target not_in targets {rhi.cmd_barrier_texture(p.cmd, texture, .Shader_Read); continue}
		pass.colors[pass.color_count] = {texture = texture, load = .Load, store = .Store}
		pass.color_count += 1
	}
	rhi.cmd_begin_render_pass(p.cmd, &pass)
}

// Binds what a pass of pass_surface_begin, a dispatch of the Surface stage
// or a pass of the Inspect stage reads of its view at SLOT_PASS0 + slot.
// Without instance ids, Instance reads 0 everywhere.
pass_surface_read :: proc(s: ^Stage_Pass, slot: u32, source: Surface_Source) {
	t := s.pass.t
	instance := t.instance if t.instance != 0 && s.pass.r.frame_layout.instance_ids else s.pass.r.dummy_layers
	glass := t.glass[0].depth if s.glass != .All && t.glass[0].depth != 0 else s.pass.r.dummy_texture
	textures := [Surface_Source]rhi.Texture{.Linear_Depth = t.linear_depth, .Motion = t.motion, .Albedo = t.albedo, .Normal = t.normal, .Emission = t.emission, .Instance = instance, .Glass_Depth = glass, .Direct = t.direct}
	if slot <= SLOT_PASS9 - SLOT_PASS0 {rhi.cmd_bind_texture(s.pass.cmd, SLOT_PASS0 + slot, textures[source])}
}

pass_end :: proc(s: ^Stage_Pass) {rhi.cmd_end_render_pass(s.pass.cmd)}

// Begins the dispatches with which an extension writes the vertices of its
// deformables, in the Geometry stage: every pipeline bound after it has the
// vertex pool of the scene (words, gpu_types.odin) at SLOT_VERTICES, and the
// index pool and the mesh table at SLOT_INDICES and SLOT_MESHES, which
// geometry.slang reads. False while the scene has no vertices.
pass_vertices_begin :: proc(s: ^Stage_Pass, name := "vertices") -> bool {
	scene := &s.pass.r.scene
	if s.stage != .Geometry || scene.vertex_buffer == 0 || scene.index_buffer == 0 || scene.mesh_buffer == 0 {return false}
	rhi.cmd_timestamp(s.pass.cmd, name)
	rhi.cmd_barrier_buffer(s.pass.cmd, scene.vertex_buffer, .Shader_Write)
	rhi.cmd_barrier_buffer(s.pass.cmd, scene.index_buffer, .Shader_Read)
	rhi.cmd_barrier_buffer(s.pass.cmd, scene.mesh_buffer, .Shader_Read)
	return true
}

// Where the vertices of a deformable are in the vertex pool of the scene, in
// words (deformable_vertices): Gpu_Posed_Vertex each, read and written with
// posed.slang, and its row of the mesh table, through which geometry.slang
// reads the rest of each vertex (mesh_vertex_color).
pass_deformable :: proc(s: ^Stage_Pass, handle: Mesh_Handle) -> (written, rest, count, mesh: u32, ok: bool) {
	return deformable_vertices(s.pass.r, handle)
}

// Binds a pipeline of stage_pipeline for what the pass draws or dispatches next.
pass_pipeline :: proc(s: ^Stage_Pass, pipeline: rhi.Pipeline) {
	rhi.cmd_bind_pipeline(s.pass.cmd, pipeline)
	if s.stage == .Geometry {
		scene := &s.pass.r.scene
		rhi.cmd_bind_buffer(s.pass.cmd, SLOT_VERTICES, scene.vertex_buffer)
		rhi.cmd_bind_buffer(s.pass.cmd, SLOT_INDICES, scene.index_buffer)
		rhi.cmd_bind_buffer(s.pass.cmd, SLOT_MESHES, scene.mesh_buffer)
	}
}

// The parameters of the next draw or dispatch, at SLOT_PARAMS. False when the
// memory of the frame has no room for them: nothing is to be drawn with them.
pass_params :: proc(s: ^Stage_Pass, params: rawptr, size: int) -> bool {
	return rhi.cmd_set_constants(s.pass.cmd, SLOT_PARAMS, params, size)
}

// Copies the rows a pass reads into the memory of the frame and binds them at
// a slot of the pass (CUSTOM_PASS_SLOTS): the extension keeps no buffer for
// them. False when they do not fit.
pass_upload :: proc(s: ^Stage_Pass, slot: u32, data: rawptr, size: int) -> bool {
	binding, ok := pass_slot(s, slot)
	if !ok || data == nil || size <= 0 {return false}
	rows := rhi.frame_alloc(s.pass.r.device, u64(size), 16)
	if rows.ptr == nil {return false}
	mem.copy(rows.ptr, data, size)
	rhi.cmd_bind_transient(s.pass.cmd, binding, rows)
	return true
}

// A block of constants (a cbuffer) the next draws or dispatches read at a
// slot of the pass, in the memory of the frame. False when it does not fit.
pass_constants :: proc(s: ^Stage_Pass, slot: u32, data: rawptr, size: int) -> bool {
	binding, ok := pass_slot(s, slot)
	return ok && data != nil && size > 0 && rhi.cmd_set_constants(s.pass.cmd, binding, data, size)
}

// The pixels the next draws of the pass reach: x, y, width, height. Without
// size, those of the whole view.
pass_scissor :: proc(s: ^Stage_Pass, rect: [4]i32) {
	if rect.z > 0 && rect.w > 0 {
		rhi.cmd_set_scissor(s.pass.cmd, rect.x, rect.y, u32(rect.z), u32(rect.w))
	} else {
		rhi.cmd_set_scissor(s.pass.cmd, 0, 0, s.width, s.height)
	}
}

pass_draw :: proc(s: ^Stage_Pass, vertices: u32, instances: u32 = 1) {rhi.cmd_draw(s.pass.cmd, vertices, instances)}

pass_dispatch :: proc(s: ^Stage_Pass, x: u32, y: u32 = 1, z: u32 = 1) {rhi.cmd_dispatch(s.pass.cmd, x, y, z)}

// The GPU time of what the pass records from here on counts under this name
// in the timings of the frame, up to the next pass that names its own.
pass_timestamp :: proc(s: ^Stage_Pass, name: string) {rhi.cmd_timestamp(s.pass.cmd, name)}

// A texture of a view that an extension keeps between frames: 2D, or 3D with
// a depth above 1, in a format a compute shader writes. The name tells the
// textures of a view apart; asking for one under that name with another
// format, size or mips makes it again.
Pass_Texture_Desc :: struct {
	name:                 string,
	format:               rhi.Format, // RGBA8_Unorm, or of 16 or 32 bit floats or uints
	width, height, depth: u32,        // depth 0 or 1: a 2D texture
	history:              bool,       // two copies that take turns: the one of this frame and the one of the frame before
	mips:                 u8,         // of a 2D texture; 0 or 1: one, RENDER_MIPS_ALL: down to one texel
}

EXTENSION_TEXTURE_CAPACITY :: 8

@(private)
Extension_Texture :: struct {
	key:      u64, // of its name; 0: a free place
	desc:     rhi.Texture_Desc,
	history:  bool,
	textures: [2]rhi.Texture,
	asked:    u64,  // the frame of the view (View_State.frames) that last asked for it
	kept:     bool, // in that frame, its previous copy holds what the frame before wrote
}

// Binds a texture of the view being recorded at SLOT_PASS0 + slot, for the
// dispatches of a stage with a view: one with history, its copy of this frame
// or, with previous, that of the frame before; of one with mips, one of them
// to write, or all of them to read (-1). The renderer makes it the first
// time a pass asks for it, keeps it while the passes of the view ask for it in
// each frame and frees it after a frame of the view without them. kept: the
// previous copy holds what the passes of the view wrote in its frame before;
// false the first time, after a cut and after a frame without them. What a
// texture holds before something writes it is not known. False for a
// description no compute shader writes, for a mip it does not have, or
// without room for another texture in the view.
pass_texture :: proc(s: ^Stage_Pass, slot: u32, desc: Pass_Texture_Desc, previous := false, mip: i32 = -1) -> (ok: bool, kept: bool) {
	p := s.pass
	view := p.view
	if view == nil || slot > SLOT_PASS9 - SLOT_PASS0 || previous && !desc.history || !custom_format_valid(desc.format) {return}
	if desc.width == 0 || desc.height == 0 || desc.width > 16384 || desc.height > 16384 || desc.depth > 2048 || desc.depth > 1 && desc.mips > 1 {return}
	mips := mip_count(desc.width, desc.height) if desc.mips == RENDER_MIPS_ALL else min(u32(max(desc.mips, 1)), mip_count(desc.width, desc.height))
	if mip >= i32(mips) {return}
	key := base.name_hash(desc.name) | 1
	want := rhi.Texture_Desc{width = desc.width, height = desc.height, depth = desc.depth if desc.depth > 1 else 0, mip_levels = mips, format = desc.format, usage = {.Sampled, .Storage}, name = "extension texture"}
	entry, free: ^Extension_Texture
	for &place in view.extension_textures {
		if place.key == key {entry = &place; break}
		if place.key == 0 && free == nil {free = &place}
	}
	if entry != nil {
		made := entry.desc
		if made.width != want.width || made.height != want.height || made.depth != want.depth || made.mip_levels != want.mip_levels || made.format != want.format || entry.history != desc.history {
			extension_texture_free(p.r, entry)
			free = entry
			entry = nil
		}
	}
	if entry == nil {
		if free == nil {set_error(p.r, "extension texture %s: the view has no room for more than %d", desc.name, EXTENSION_TEXTURE_CAPACITY); return}
		entry = free
		entry^ = {key = key, desc = want, history = desc.history, asked = view.frames}
		for at in 0 ..< (2 if desc.history else 1) {
			entry.textures[at] = rhi.texture_create(p.r.device, want)
			if entry.textures[at] == 0 {
				set_error(p.r, "extension texture %s: %s", desc.name, rhi.device_error(p.r.device))
				extension_texture_free(p.r, entry)
				return
			}
		}
	} else if entry.asked != view.frames {
		entry.kept = entry.history && view.has_previous && entry.asked + 1 == view.frames
		entry.asked = view.frames
	}
	at := (p.previous if previous else p.current) if desc.history else 0
	rhi.cmd_bind_texture(p.cmd, SLOT_PASS0 + slot, entry.textures[at], mip)
	return true, entry.kept
}

// Binds a texture the passes of the view already asked for this frame at
// SLOT_PASS0 + slot, for the draws of the next pass of the stage to sample
// what the dispatches before wrote: its copy of this frame, or that of the
// frame before with previous. Outside a pass of pass_surface_begin or
// pass_mask_begin, before it begins. False for a texture the view does not have.
pass_texture_sample :: proc(s: ^Stage_Pass, slot: u32, desc: Pass_Texture_Desc, previous := false) -> bool {
	p := s.pass
	view := p.view
	if view == nil || slot > SLOT_PASS9 - SLOT_PASS0 || previous && !desc.history {return false}
	key := base.name_hash(desc.name) | 1
	for &entry in view.extension_textures {
		if entry.key != key || entry.asked != view.frames {continue}
		texture := entry.textures[(p.previous if previous else p.current) if entry.history else 0]
		rhi.cmd_barrier_texture(p.cmd, texture, .Shader_Read)
		rhi.cmd_bind_texture(p.cmd, SLOT_PASS0 + slot, texture)
		return true
	}
	return false
}

// Binds at SLOT_PASS0 + slot, before a pass begins, the volume the passes of
// the view asked for this frame by that name, as pass_texture_sample does;
// in a view without it, a volume of the renderer that stands for it and holds
// nothing meant to be read. False then.
pass_volume_sample :: proc(s: ^Stage_Pass, slot: u32, name: string) -> bool {
	if slot > SLOT_PASS9 - SLOT_PASS0 {return false}
	if pass_texture_sample(s, slot, {name = name}) {return true}
	rhi.cmd_bind_texture(s.pass.cmd, SLOT_PASS0 + slot, s.pass.r.display_lut)
	return false
}

@(private)
extension_texture_free :: proc(r: ^Renderer, entry: ^Extension_Texture) {
	for texture in entry.textures {if texture != 0 {rhi.texture_destroy(r.device, texture)}}
	entry^ = {}
}

// Frees the textures of extensions that the frame of the view before did not
// ask for, or every one.
@(private)
extension_textures_release :: proc(r: ^Renderer, view: ^View_State, all := false) {
	for &entry in view.extension_textures {
		if entry.key != 0 && (all || entry.asked + 1 < view.frames) {extension_texture_free(r, &entry)}
	}
}
