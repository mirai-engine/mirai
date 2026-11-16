package mirai_render

import "core:math"
import "mirai:rhi"
import "mirai:render/abi"

// The display transform (display.slang) the tonemap and the UI encode with.
// PBR Neutral is computed in the pass; ACES 2.0 is baked when the renderer
// starts into a LUT of DISPLAY_LUT_SIZE³ that they read.

// DISPLAY_LUT_SIZE of display.slang.
DISPLAY_LUT_SIZE :: abi.DISPLAY_LUT_SIZE
// ACES_HUES of aces.slang.
DISPLAY_HUES :: 360

// How the exposed image goes to the display.
Display_Transform :: enum u32 {
	Neutral, // Khronos PBR Neutral: colors come out as authored up to their highlights
	ACES_2,  // the ACES 2.0 Output Transform: a filmic image with smooth highlights
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
display_exposure_bias :: proc "contextless" (transform: Display_Transform) -> f32 {
	switch transform {
	case .ACES_2:  return EXPOSURE_BIAS
	case .Neutral: return math.log2((DISPLAY_ACES_GRAY + DISPLAY_NEUTRAL_OFFSET) / MIDDLE_GRAY)
	}
	return EXPOSURE_BIAS
}

// The transform the frames after this one encode with.
renderer_set_display_transform :: proc(r: ^Renderer, transform: Display_Transform) {
	r.display_transform = transform
}

// What tells the passes of a frame how to encode (display_encode).
@(private)
display_frame_flags :: proc(r: ^Renderer) -> u32 {
	return FRAME_FLAG_NEUTRAL if r.display_transform == .Neutral else 0
}

// The LUT of ACES 2.0 for the display, from its tables of hue.
@(private)
display_build :: proc(r: ^Renderer, display: Display_Desc) -> bool {
	d := r.device
	tables_pipeline := rhi.pipeline_create_compute(d, {shader = &r.shader_codes[.Display_Tables_Comp], name = "display tables"})
	defer if tables_pipeline != 0 {rhi.pipeline_destroy(d, tables_pipeline)}
	lut_pipeline := rhi.pipeline_create_compute(d, {shader = &r.shader_codes[.Display_Lut_Comp], name = "display lut"})
	defer if lut_pipeline != 0 {rhi.pipeline_destroy(d, lut_pipeline)}
	tables := rhi.buffer_create(d, {size = DISPLAY_HUES * size_of(Vec4), usage = {.Storage}, name = "display tables"})
	defer if tables != 0 {rhi.buffer_destroy(d, tables)}
	Params :: struct {red_green, blue_white: Vec4, peak: f32, pad: [3]u32}
	params_buffer := rhi.buffer_create(d, {size = size_of(Params), usage = {.Uniform}, memory = .Upload, name = "display params"})
	defer if params_buffer != 0 {rhi.buffer_destroy(d, params_buffer)}
	r.display_lut = rhi.texture_create(d, {width = DISPLAY_LUT_SIZE, height = DISPLAY_LUT_SIZE, depth = DISPLAY_LUT_SIZE, format = .RGBA16_Float, usage = {.Sampled, .Storage}, name = "display lut"})
	if tables_pipeline == 0 || lut_pipeline == 0 || tables == 0 || params_buffer == 0 || r.display_lut == 0 {
		set_error(r, "display lut: %s", rhi.device_error(d))
		return false
	}
	params := Params{red_green = {display.red.x, display.red.y, display.green.x, display.green.y}, blue_white = {display.blue.x, display.blue.y, display.white.x, display.white.y}, peak = display.peak}
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
	rhi.cmd_dispatch(cmd, groups(DISPLAY_LUT_SIZE, 4), groups(DISPLAY_LUT_SIZE, 4), groups(DISPLAY_LUT_SIZE, 4))
	if !rhi.immediate_end(d, cmd) {
		set_error(r, "display lut: %s", rhi.device_error(d))
		return false
	}
	return true
}
