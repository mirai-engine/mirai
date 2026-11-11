package mirai_render

import "core:math"
import "mirai:rhi"
import "mirai:render/abi"

// The exposure of each view (Camera.exposure). Before the tonemap of a view,
// exposure_histogram.comp counts the light of its image and
// exposure_adapt.comp turns the counts into the exposure value the tonemap
// reads, on the GPU, in the same frame. The passes of the next frame take it
// from there (Gpu_Frame.exposure, frame_exposure_copy); a copy for the CPU
// gives them one when they cannot.

// EXPOSURE_BINS of exposure.slang; the histogram has one more count, of the pixels of sky.
EXPOSURE_BINS :: abi.EXPOSURE_BINS

// About how many pixels the meter reads, on a grid over the image whatever its size.
EXPOSURE_SAMPLES :: 65536

// Exposure_State of exposure.slang.
Gpu_Exposure :: struct {
	ev100:      f32,
	exposure:   f32, // the scene-linear value of one render unit
	valid:      u32,
	generation: u32, // View_State.exposure_generation it was adapted in
}
#assert(size_of(Gpu_Exposure) == 16)

// What the last exposure pass of a view was recorded with: the exposure it
// leaves in view.exposure is that of the next frame while these hold.
Exposure_Adapted :: struct {
	generation:   u32,
	compensation: f32,
	light_scale:  f32,
	bias:         f32, // display_exposure_bias of the transform it was adapted under
	recorded:     bool,
}

@(private)
view_exposure_buffers :: proc(r: ^Renderer, cmd: ^rhi.Command_List, view: ^View_State) -> bool {
	if view.exposure != 0 {return true}
	d := r.device
	view.exposure = rhi.buffer_create(d, {size = size_of(Gpu_Exposure), usage = {.Storage, .Transfer_Src}, name = "exposure"})
	view.exposure_histogram = rhi.buffer_create(d, {size = (EXPOSURE_BINS + 1) * 4, usage = {.Storage}, name = "exposure histogram"})
	for &b in view.exposure_readback {b = rhi.buffer_create(d, {size = size_of(Gpu_Exposure), memory = .Readback, name = "exposure readback"})}
	if view.exposure == 0 || view.exposure_histogram == 0 {
		set_error(r, "exposure: %s", rhi.device_error(d))
		return false
	}
	for b in view.exposure_readback {if b == 0 {set_error(r, "exposure: %s", rhi.device_error(d)); return false}}
	rhi.cmd_fill_buffer(cmd, view.exposure, 0, size_of(Gpu_Exposure), 0)
	rhi.cmd_fill_buffer(cmd, view.exposure_histogram, 0, (EXPOSURE_BINS + 1) * 4, 0)
	for b in view.exposure_readback {
		if mapped := rhi.buffer_mapped(d, b); mapped != nil {(cast(^Gpu_Exposure)mapped)^ = {}}
	}
	view.ev100_known, view.exposure_adapted = false, {}
	return true
}

// The EV100 a view with nothing to meter yet begins at (exposure_first of
// exposure.slang): a middle gray card under the strongest light, which the
// light scale brings near one.
exposure_first :: proc "contextless" (light_scale: f32, range: [2]f32) -> f32 {
	return clamp(math.log2(MIDDLE_GRAY / light_scale * 100 / LIGHT_METER_K), range[0], range[1])
}

// The exposure the CPU writes in Gpu_Frame.exposure for the passes of the
// view: that of the camera when it is manual, else the one a frame before read
// back. Until one of its present generation comes back (after a cut the GPU
// takes the metered one at once), the last one it knew, or with none where the
// view begins.
@(private)
view_exposure :: proc(p: ^Pass) -> f32 {
	view := p.view
	if b := view.exposure_readback[p.slot]; b != 0 {
		if mapped := rhi.buffer_mapped(p.r.device, b); mapped != nil {
			state := (cast(^Gpu_Exposure)mapped)^
			if state.valid != 0 && state.generation == view.exposure_generation {view.ev100, view.ev100_known = state.ev100, true}
		}
	}
	e := exposure_of_camera(p.r, p.camera)
	scale := p.r.scene.light_scale if p.r.scene.light_scale > 0 else 1
	ev100 := e.ev100
	if e.mode == .Auto {ev100 = view.ev100 if view.ev100_known else exposure_first(scale, e.range if e.range != {} else AUTO_EXPOSURE_RANGE)}
	if view == &p.r.main || (p.r.view_count > 0 && view == &p.r.views[0]) {p.r.stats.ev100 = ev100}
	return exposure_of_ev100(ev100 - e.compensation, display_exposure_bias(p.r.display_transform)) / scale
}

// How a view exposes: as its camera, when the camera has an exposure of its
// own, or else as the scene.
@(private)
exposure_of_camera :: proc(r: ^Renderer, camera: Camera) -> Exposure {return camera.exposure if camera.exposure.own else r.scene.exposure}

// Over the exposure the CPU wrote in the constants of a view, the one the GPU
// left for it in its last frame, when that frame adapted it with the
// generation, compensation, light scale and bias of this one: the passes follow an
// auto exposure a frame behind the tonemap. A manual one, and the first frame
// after a discontinuity, keep the CPU's.
@(private)
frame_exposure_copy :: proc(p: ^Pass, constants: rhi.Transient) {
	view := p.view
	e := exposure_of_camera(p.r, p.camera)
	if e.mode != .Auto || view.exposure == 0 || constants.ptr == nil {return}
	scale := p.r.scene.light_scale if p.r.scene.light_scale > 0 else 1
	if view.exposure_adapted != (Exposure_Adapted{generation = view.exposure_generation, compensation = e.compensation, light_scale = scale, bias = display_exposure_bias(p.r.display_transform), recorded = true}) {return}
	rhi.cmd_copy_buffer(p.cmd, view.exposure, u64(offset_of(Gpu_Exposure, exposure)), constants.buffer, constants.offset + u64(offset_of(Gpu_Frame, exposure)), size_of(f32))
	rhi.cmd_barrier_buffer(p.cmd, constants.buffer, .Shader_Read)
}

// The exposure of the views whose camera has none of its own; zero: Auto at once.
scene_set_exposure :: proc(r: ^Renderer, e: Exposure) {r.scene.exposure = e}

// Meters the light of the image before its temporal resolve (auto) and leaves the exposure
// of this frame in view.exposure, with a copy for the CPU.
@(private)
pass_exposure :: proc(p: ^Pass) -> bool {
	r, cmd, view := p.r, p.cmd, p.view
	if !view_exposure_buffers(r, cmd, view) {return false}
	e := exposure_of_camera(r, p.camera)
	scale := r.scene.light_scale if r.scene.light_scale > 0 else 1
	rhi.cmd_timestamp(cmd, "exposure")
	if e.mode == .Auto {
		t := p.t
		Meter :: struct {light_scale, step: f32, grid: [2]u32}
		step := max(math.sqrt(f32(t.width) * f32(t.height) / EXPOSURE_SAMPLES), 1)
		meter := Meter{light_scale = scale, step = step, grid = {u32(math.ceil(f32(t.width) / step)), u32(math.ceil(f32(t.height) / step))}}
		rhi.cmd_bind_pipeline(cmd, r.pipelines[.Exposure_Histogram])
		set_params(cmd, &meter)
		rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.display)
		rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.linear_depth)
		rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.albedo)
		rhi.cmd_bind_texture(cmd, SLOT_PASS4, t.emission)
		rhi.cmd_bind_texture(cmd, SLOT_PASS5, t.normal)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS1, view.exposure_histogram)
		rhi.cmd_dispatch(cmd, groups(meter.grid.x, 16), groups(meter.grid.y, 16))
	}
	bias := display_exposure_bias(r.display_transform)
	Adapt :: struct {manual: u32, ev100, compensation, adaptation: f32, range: [2]f32, dt, light_scale: f32, generation, speed: u32, bias: f32, pad: u32}
	adapt := Adapt{manual = 1 if e.mode == .Manual else 0, ev100 = e.ev100, compensation = e.compensation, adaptation = max(e.adaptation, 0), range = e.range if e.range != {} else AUTO_EXPOSURE_RANGE, dt = r.delta_time, light_scale = scale, generation = view.exposure_generation, speed = 1 if e.adaptation_mode == .Speed else 0, bias = bias}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Exposure_Adapt])
	set_params(cmd, &adapt)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, view.exposure_histogram)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, view.exposure)
	rhi.cmd_dispatch(cmd, 1)
	view.exposure_adapted = {generation = view.exposure_generation, compensation = e.compensation, light_scale = scale, bias = bias, recorded = true}
	rhi.cmd_copy_buffer(cmd, view.exposure, 0, view.exposure_readback[p.slot], 0, size_of(Gpu_Exposure))
	rhi.cmd_barrier_buffer(cmd, view.exposure_readback[p.slot], .Host_Read)
	return true
}
