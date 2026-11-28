package mirai_render

import "core:math/linalg"
import "mirai:render/abi"
import "mirai:rhi"

// The sky a Sky program draws (Environment.sky_program, `//! mirai sky`): the
// renderer draws the image it gives, laid out as an image of the sky is
// (sky_image of scene.slang) with its whole mip chain, by the stage of the
// program (sky_bake.comp), and the frame reads it where it reads
// Environment.sky_texture: the camera, what reflects the sky, the probes,
// exposure, media and glass take it as they take an image, times the
// luminance of the sky. The program colors directions of the sky, which turns
// with its entity, so turning it draws nothing again; another program, other
// parameters or a sun that moves draw it again at the start of the frame, and
// the world is lit again. A look of the sky whose program was never drawn
// shows the gradient of its luminance until its stage is made; one drawn
// before keeps its image until it is drawn again (an edit of the program in
// the editor). Nothing is made until a sky names a program.

SKY_BAKE_WIDTH :: abi.SKY_BAKE_WIDTH
SKY_BAKE_HEIGHT :: SKY_BAKE_WIDTH / 2
SKY_BAKE_LEVELS :: 12 // from SKY_BAKE_WIDTH across to one texel
#assert(1 << (SKY_BAKE_LEVELS - 1) == SKY_BAKE_WIDTH)
@(private) SKY_BAKE_TEXELS :: SKY_BAKE_WIDTH * SKY_BAKE_HEIGHT * 4 / 3 + SKY_BAKE_LEVELS // of every level, rounded up

// A sky a Sky program draws: the program and its parameters, as it reflects
// them. program 0: none.
Sky_Program :: struct {
	program: u32,
	params:  [16]Vec4,
}

// What the image of a bake holds: the sky drawn and the sun it saw, towards
// it in the space of the sky, w 1 while a Sun is on.
@(private)
Sky_Bake_Key :: struct {
	sky: Sky_Program,
	sun: Vec4,
}

@(private)
Sky_Bake :: struct {
	key:     Sky_Bake_Key, // what texture holds, once held
	held:    bool,
	stale:   bool, // the stage of its program changed: it is drawn again once that is made
	texture: rhi.Texture,
	handle:  Texture_Handle,
}

@(private)
Sky_Bakes :: struct {
	bakes:   [2]Sky_Bake, // of the sky on, and of the one a change comes from
	staging: rhi.Buffer,  // the texels of every level of a bake, half floats, before they are copied in
	stages:  Program_Computes, // of sky_bake__<program>.comp
}

// The skies the frame draws by their programs: the one on, and the one a
// change comes from while it still shows.
@(private)
sky_programs_wanted :: proc "contextless" (r: ^Renderer) -> [2]Sky_Program {
	e := &r.scene.environment
	return {e.sky_program, e.sky_from_program if e.sky_from_weight > 0 else {}}
}

// The image of each look of the sky drawn by a program, and the texels of a
// bake, made the first time a frame wants them and kept; before the frame
// begins, as the texture table changes only between frames. Without memory
// for them, the error says so and the sky shows its gradient.
@(private)
sky_bakes_ensure :: proc(r: ^Renderer) {
	b := &r.sky_bakes
	wanted := sky_programs_wanted(r)
	for sky, i in wanted {
		if sky.program == 0 || b.bakes[i].texture != 0 {continue}
		b.bakes[i].texture, b.bakes[i].handle = written_texture(r, SKY_BAKE_WIDTH, SKY_BAKE_HEIGHT, SKY_BAKE_LEVELS, .RGBA16_Float, "sky program")
		if b.bakes[i].texture == 0 {return}
	}
	if b.staging != 0 || wanted[0].program == 0 && wanted[1].program == 0 {return}
	b.staging = rhi.buffer_create(r.device, {size = SKY_BAKE_TEXELS * 8, usage = {.Storage, .Transfer_Src}, name = "sky program bake"})
	if b.staging == 0 {set_error(r, "sky program: %s", rhi.device_error(r.device))}
}

@(private)
sky_bakes_destroy :: proc(r: ^Renderer) {
	b := &r.sky_bakes
	for bake in b.bakes {if bake.texture != 0 {texture_remove(r, bake.handle)}}
	if b.staging != 0 {rhi.buffer_destroy(r.device, b.staging)}
	program_computes_destroy(r, &b.stages)
	b^ = {}
}

// With the GPU idle, when the shaders they were made from go: the pipelines,
// and what each image holds, which a program of another id may name next.
@(private)
sky_bakes_drop :: proc(r: ^Renderer) {
	program_computes_destroy(r, &r.sky_bakes.stages)
	for &bake in r.sky_bakes.bakes {bake.held = false}
}

// With the GPU idle, before the renderer takes the stages of programs of
// another generation: the pipelines of the stages that changed go, and every
// image is drawn again, under the id its program has there (moved), once its
// stage is made.
@(private)
sky_bakes_publish :: proc(r: ^Renderer, next: []rhi.Shader_Code, moved: []u32) {
	b := &r.sky_bakes
	program_computes_publish(r, &b.stages, next, moved)
	for &bake in b.bakes {
		bake.key.sky.program = program_id_moved(moved, bake.key.sky.program)
		bake.stale = true
	}
}

// The image the frame reads for a look of the sky (slot 0 the one on, 1 the
// one it changes from): that of its program once drawn, or its own image.
@(private)
sky_image_of :: proc "contextless" (r: ^Renderer, slot: int, texture: Texture_Handle, sky: Sky_Program) -> Texture_Handle {
	if sky.program == 0 {return texture}
	bake := &r.sky_bakes.bakes[slot]
	return bake.handle if bake.held && bake.key.sky.program == sky.program else 0
}

// Draws the image of each look of the sky whose program, parameters or sun
// changed since it was drawn, whose stage is made, and lights the world again
// with it: before the views, which read it.
@(private)
sky_bakes_record :: proc(r: ^Renderer, cmd: ^rhi.Command_List) -> bool {
	b := &r.sky_bakes
	if b.staging == 0 {return true}
	sun: Vec4
	if s := &r.scene; s.sun.enabled {
		turn := s.environment.sky_orientation
		if turn == {} {turn = 1}
		toward := linalg.quaternion_mul_vector3(conj(turn), s.sun.direction)
		sun = {toward.x, toward.y, toward.z, 1}
	}
	for sky, i in sky_programs_wanted(r) {
		bake := &b.bakes[i]
		key := Sky_Bake_Key{sky, sun}
		if sky.program == 0 || bake.texture == 0 || bake.held && !bake.stale && bake.key == key {continue}
		program := program_of_id(r, sky.program)
		if program == nil || program.domain != .Sky || program.id >= POINTS_PROGRAM_CAPACITY {continue}
		pipeline := program_compute(r, &b.stages, program^, "sky_bake")
		if pipeline == 0 {continue}
		rhi.cmd_timestamp(cmd, "sky program")
		Params :: struct {packed: [16]Vec4, sun: Vec4, level: u32, pad: [3]u32}
		params := Params{packed = sky.params, sun = sun}
		rhi.cmd_bind_pipeline(cmd, pipeline)
		rhi.cmd_bind_sampler(cmd, SLOT_MATERIAL_SAMPLER, r.material_sampler)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, b.staging)
		offset: u64
		for level in u32(0) ..< SKY_BAKE_LEVELS {
			params.level = level
			set_params(cmd, &params)
			width, height := max(u32(SKY_BAKE_WIDTH) >> level, 1), max(u32(SKY_BAKE_HEIGHT) >> level, 1)
			rhi.cmd_dispatch(cmd, groups(width * height, 64))
		}
		for level in u32(0) ..< SKY_BAKE_LEVELS {
			rhi.cmd_copy_buffer_to_texture(cmd, b.staging, offset * 8, bake.texture, level)
			offset += u64(max(u32(SKY_BAKE_WIDTH) >> level, 1)) * u64(max(u32(SKY_BAKE_HEIGHT) >> level, 1))
		}
		rhi.cmd_barrier_texture(cmd, bake.texture, .Shader_Read)
		bake.key, bake.held, bake.stale = key, true, false
		scene_relit(&r.scene)
	}
	return true
}
