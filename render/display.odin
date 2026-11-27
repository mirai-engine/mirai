package mirai_render

import "core:math"
import "mirai:rhi"
import "mirai:render/abi"

// The display transform (display.slang) the tonemap and the UI encode with.
// PBR Neutral is computed in the pass; ACES 2.0 is baked when the renderer
// starts into a LUT of DISPLAY_LUT_SIZE³ that they read; a LUT of the project
// is copied into one of its own when it arrives or changes.

// DISPLAY_LUT_SIZE of display.slang.
DISPLAY_LUT_SIZE :: abi.DISPLAY_LUT_SIZE
// Slices a row of the texture of a LUT of the project: within the largest
// texture of the pool.
DISPLAY_LUT_COLUMNS :: abi.DISPLAY_LUT_COLUMNS

// The exposed scene-linear value at an index along an axis of a display LUT
// (display_unshaper of display.slang).
display_lut_value :: proc "contextless" (index: int) -> f32 {
	return MIDDLE_GRAY * math.pow(2, f32(index) / (DISPLAY_LUT_SIZE - 1) * (abi.DISPLAY_STOPS_BELOW + abi.DISPLAY_STOPS_ABOVE) - abi.DISPLAY_STOPS_BELOW)
}

// The width and height of the texture of a LUT of the project.
display_lut_texture_size :: proc "contextless" () -> [2]int {
	rows := (DISPLAY_LUT_SIZE + DISPLAY_LUT_COLUMNS - 1) / DISPLAY_LUT_COLUMNS
	return {DISPLAY_LUT_COLUMNS * DISPLAY_LUT_SIZE, rows * DISPLAY_LUT_SIZE}
}
// ACES_HUES of aces.slang.
DISPLAY_HUES :: 360

// How the exposed image goes to the display.
Display_Transform :: enum u32 {
	Neutral, // Khronos PBR Neutral: colors come out as authored up to their highlights
	ACES_2,  // the ACES 2.0 Output Transform: a filmic image with smooth highlights
	LUT,     // a LUT the project gives (renderer_set_display_lut): the look of another engine or tool
}

// A display: the luminance of its white, nits, and the chromaticities of its
// primaries and white. It shows sRGB.
Display_Desc :: struct {
	peak:            f32,
	red, green, blue, white: Vec2,
}

// An SDR display of Rec.709 primaries, as the sRGB of a monitor.
DISPLAY_SDR :: Display_Desc{peak = 100, red = {0.64, 0.33}, green = {0.3, 0.6}, blue = {0.15, 0.06}, white = {0.3127, 0.329}}

// The linear light ACES 2.0 shows on DISPLAY_SDR for a card its meter takes as
// average, exposed with EXPOSURE_BIAS: what the other transforms calibrate to,
// so that choosing one changes the color of a scene and not how bright it is.
DISPLAY_ACES_GRAY :: f32(0.20894)
// What PBR Neutral takes from a midtone (pbr_neutral of display.slang).
DISPLAY_NEUTRAL_OFFSET :: f32(0.04)

// The EV a view is exposed above what its meter or its camera gives under a
// transform. Neutral shows a midtone less its offset, so the card has to be
// exposed to the light ACES 2.0 shows plus that offset.
// A LUT of the project shows the light that is its mid gray as ACES 2.0
// shows the card.
display_exposure_bias :: proc "contextless" (transform: Display_Transform, lut_gray: f32 = 0) -> f32 {
	switch transform {
	case .ACES_2:  return EXPOSURE_BIAS
	case .LUT:     if lut_gray > 0 {return math.log2(lut_gray / MIDDLE_GRAY)}
	case .Neutral:
	}
	return math.log2((DISPLAY_ACES_GRAY + DISPLAY_NEUTRAL_OFFSET) / MIDDLE_GRAY)
}

// The bias of the transform the frames encode with: Neutral's while a LUT of
// the project has not arrived, as they show Neutral then.
@(private)
display_bias :: proc(r: ^Renderer) -> f32 {
	return display_exposure_bias(r.display_transform, r.display_custom.gray if r.display_custom.ready else 0)
}

// The transform the frames after this one encode with.
renderer_set_display_transform :: proc(r: ^Renderer, transform: Display_Transform) {
	r.display_transform = transform
	r.display_lut = r.display_custom.lut if transform == .LUT && r.display_custom.ready else r.display_aces
}

// A LUT of the project for Display_Transform.LUT, in a texture of the pool of
// display_lut_texture_size: DISPLAY_LUT_SIZE slices of DISPLAY_LUT_SIZE², blue
// from one to the next, DISPLAY_LUT_COLUMNS a row from the top left, red across
// and green down a slice, read texel by texel; each texel the encoded color
// the display shows for the exposed scene-linear Rec.709 one at its place
// along the axes (display_unshaper of display.slang). gray: the exposed light
// it shows as ACES 2.0 shows the card (DISPLAY_ACES_GRAY). It is copied when
// the texture is whole in the pool; until then the frames show Neutral. false:
// the texture is not of that size, or the copy failed (renderer_error).
renderer_set_display_lut :: proc(r: ^Renderer, texture: Texture_Handle, gray: f32) -> bool {
	c := &r.display_custom
	if texture == c.from && gray == c.gray && (c.ready || texture == 0) {return true}
	c.from, c.gray, c.ready = texture, gray, false
	defer renderer_set_display_transform(r, r.display_transform)
	index := int(texture) - 1
	if index < 0 || index >= r.textures.count || r.textures.textures[index] == 0 {return true}
	if size := display_lut_texture_size(); r.textures.sizes[index] != size {
		set_error(r, "display lut: the texture is %dx%d, not %dx%d", r.textures.sizes[index][0], r.textures.sizes[index][1], size.x, size.y)
		return false
	}
	if bytes, reduced := texture_stored(r, texture); bytes == 0 || reduced {return true}
	if !display_copy(r, r.textures.textures[index]) {return false}
	c.ready = true
	return true
}

// What tells the passes of a frame how to encode (display_encode).
@(private)
display_frame_flags :: proc(r: ^Renderer) -> u32 {
	neutral := r.display_transform == .Neutral || r.display_transform == .LUT && !r.display_custom.ready
	return FRAME_FLAG_NEUTRAL if neutral else 0
}

// The LUT of the project (renderer_set_display_lut).
@(private)
Display_Custom :: struct {
	lut:   rhi.Texture,     // its copy, made at the first one
	from:  Texture_Handle,  // the texture of the pool it is copied from
	gray:  f32,
	ready: bool,            // lut holds from
}

// Copies the slices of a texture of the pool into the LUT of the project.
@(private)
display_copy :: proc(r: ^Renderer, source: rhi.Texture) -> bool {
	d := r.device
	c := &r.display_custom
	if c.lut == 0 {c.lut = rhi.texture_create(d, {width = DISPLAY_LUT_SIZE, height = DISPLAY_LUT_SIZE, depth = DISPLAY_LUT_SIZE, format = .RGBA16_Float, usage = {.Sampled, .Storage}, name = "display lut of the project"})}
	pipeline := rhi.pipeline_create_compute(d, {shader = &r.shader_codes[.Display_Lut_Comp], name = "display lut copy"})
	defer if pipeline != 0 {rhi.pipeline_destroy(d, pipeline)}
	params := Display_Lut_Params{copy = 1}
	params_buffer := rhi.buffer_create(d, {size = size_of(params), usage = {.Uniform}, memory = .Upload, name = "display params"})
	defer if params_buffer != 0 {rhi.buffer_destroy(d, params_buffer)}
	if c.lut == 0 || pipeline == 0 || params_buffer == 0 {
		set_error(r, "display lut: %s", rhi.device_error(d))
		return false
	}
	rhi.buffer_upload(d, params_buffer, 0, ([^]u8)(&params)[:size_of(params)])
	cmd := rhi.immediate_begin(d)
	if cmd == nil {
		set_error(r, "display lut: %s", rhi.device_error(d))
		return false
	}
	rhi.cmd_bind_pipeline(cmd, pipeline)
	rhi.cmd_bind_buffer(cmd, SLOT_PARAMS, params_buffer)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, c.lut)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, r.display_tables)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, source)
	rhi.cmd_dispatch(cmd, groups(DISPLAY_LUT_SIZE, 4), groups(DISPLAY_LUT_SIZE, 4), groups(DISPLAY_LUT_SIZE, 4))
	if !rhi.immediate_end(d, cmd) {
		set_error(r, "display lut: %s", rhi.device_error(d))
		return false
	}
	return true
}

// The constants of display_lut.comp.
@(private)
Display_Lut_Params :: struct {red_green, blue_white: Vec4, peak: f32, copy: u32, pad: [2]u32}

// The LUT of ACES 2.0 for the display, from its tables of hue.
@(private)
display_build :: proc(r: ^Renderer, display: Display_Desc) -> bool {
	d := r.device
	tables_pipeline := rhi.pipeline_create_compute(d, {shader = &r.shader_codes[.Display_Tables_Comp], name = "display tables"})
	defer if tables_pipeline != 0 {rhi.pipeline_destroy(d, tables_pipeline)}
	lut_pipeline := rhi.pipeline_create_compute(d, {shader = &r.shader_codes[.Display_Lut_Comp], name = "display lut"})
	defer if lut_pipeline != 0 {rhi.pipeline_destroy(d, lut_pipeline)}
	r.display_tables = rhi.buffer_create(d, {size = DISPLAY_HUES * size_of(Vec4), usage = {.Storage}, name = "display tables"})
	tables := r.display_tables
	params_buffer := rhi.buffer_create(d, {size = size_of(Display_Lut_Params), usage = {.Uniform}, memory = .Upload, name = "display params"})
	defer if params_buffer != 0 {rhi.buffer_destroy(d, params_buffer)}
	r.display_aces = rhi.texture_create(d, {width = DISPLAY_LUT_SIZE, height = DISPLAY_LUT_SIZE, depth = DISPLAY_LUT_SIZE, format = .RGBA16_Float, usage = {.Sampled, .Storage}, name = "display lut"})
	r.display_lut = r.display_aces
	if tables_pipeline == 0 || lut_pipeline == 0 || tables == 0 || params_buffer == 0 || r.display_lut == 0 {
		set_error(r, "display lut: %s", rhi.device_error(d))
		return false
	}
	params := Display_Lut_Params{red_green = {display.red.x, display.red.y, display.green.x, display.green.y}, blue_white = {display.blue.x, display.blue.y, display.white.x, display.white.y}, peak = display.peak}
	rhi.buffer_upload(d, params_buffer, 0, ([^]u8)(&params)[:size_of(params)])
	cmd := rhi.immediate_begin(d)
	if cmd == nil {
		set_error(r, "display lut: %s", rhi.device_error(d))
		return false
	}
	rhi.cmd_bind_pipeline(cmd, tables_pipeline)
	rhi.cmd_bind_buffer(cmd, SLOT_PARAMS, params_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, tables)
	rhi.cmd_dispatch(cmd, groups(DISPLAY_HUES, 64))
	rhi.cmd_bind_pipeline(cmd, lut_pipeline)
	rhi.cmd_bind_buffer(cmd, SLOT_PARAMS, params_buffer)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, r.display_lut)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, tables)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, r.dummy_texture)
	rhi.cmd_dispatch(cmd, groups(DISPLAY_LUT_SIZE, 4), groups(DISPLAY_LUT_SIZE, 4), groups(DISPLAY_LUT_SIZE, 4))
	if !rhi.immediate_end(d, cmd) {
		set_error(r, "display lut: %s", rhi.device_error(d))
		return false
	}
	return true
}
