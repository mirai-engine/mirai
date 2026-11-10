package mirai_render

import "mirai:rhi"
import "mirai:render/abi"

// The modes of inspection of a view: a buffer or a part of the light shown
// instead of the lit image, without exposure or display transform. Composite
// shows those it has at hand; debug_views.comp, after it, the buffers of other
// passes. An extension shows one of its own in the Inspect stage of the view.

// What the shaders of the engine show instead of the lit image, with the
// values of composite.comp (up to Lighting) and debug_views.comp.
Debug_View :: abi.Debug_View

// What a view shows instead of its lit image: a mode of the engine, and over
// the image of that mode the passes an extension records in the Inspect stage
// of this view alone. Zero: the lit image. A view inspected leaves out what is
// blended over the opaque scene.
View_Inspection :: struct {
	mode:   Debug_View,
	record: Stage_Proc,
	user:   rawptr,
	postprocess: Postprocess_Inspect,
}

// What the most lights a pixel counts in the Lights mode: the top of its scale.
DEBUG_LIGHTS_SCALE :: 32

// Gpu_Frame.debug_view of a view an extension inspects over its lit image:
// past every Debug_View, so that the tonemap shows it as it is.
@(private)
DEBUG_VIEW_EXTENSION :: u32(len(Debug_View))

@(private)
view_inspected :: proc "contextless" (inspection: View_Inspection) -> bool {
	return inspection.mode != .None || inspection.record != nil
}

// Whether the views of the window can show a mode with the pipeline they were
// last drawn with, the settings and the scene; when not, why.
renderer_debug_view_status :: proc(r: ^Renderer, mode: Debug_View) -> (available: bool, reason: string) {
	plan := plan_find(r, r.main.pipeline)
	if plan == nil {_, plan = view_plan(r, 0, true)}
	return debug_view_status(r, plan, mode)
}

@(private)
debug_view_status :: proc(r: ^Renderer, plan: ^Render_Plan, mode: Debug_View) -> (available: bool, reason: string) {
	s := &r.settings
	#partial switch mode {
	case .Shadows:
		if plan.direct != .Blocks || s.reference_lights {return false, "The direct light of this pipeline has no blocks of shadows to show"}
	case .Reflections, .Reflections_Raw:
		if .Reflections not_in plan.stages {return false, "This pipeline has no traced reflections"}
		if s.reflections == .Off {return false, "Traced reflections are off in the settings"}
		if r.scene.smoothest >= s.reflection_roughness {return false, "No material is smooth enough to trace a reflection"}
	case .Indirect:
		if !s.gi_enabled {return false, "Indirect light is off in the settings"}
	case .Probes:
		if !s.gi_enabled || !r.ddgi.valid {return false, "The probe volume is off or empty"}
	case .Lights:
		if len(r.scene.lights) == 0 {return false, "The scene has no local lights"}
	}
	return true, ""
}

// The modes debug_views.comp shows, after composite.
@(private)
debug_view_pass_needed :: proc "contextless" (mode: Debug_View) -> bool {
	#partial switch mode {
	case .Shadows, .Reflections, .Reflections_Raw, .Lights: return true
	}
	return false
}

@(private)
debug_views_pass :: proc(p: ^Pass) {
	r, cmd, t := p.r, p.cmd, p.t
	mode := p.inspection.mode
	if !debug_view_pass_needed(mode) || !ensure_pipelines(r, {.Debug_Views}) {return}
	available, _ := debug_view_status(r, p.plan, mode)
	source := r.dummy_texture
	#partial switch mode {
	case .Shadows:             if t.shadow.valid {source = texture_or_dummy(r, t.shadow.raw)}
	case .Reflections:         if p.use_reflections {source = texture_or_dummy(r, t.reflect_history[p.current])}
	case .Reflections_Raw:     if p.use_reflections {source = texture_or_dummy(r, t.reflect_raw)}
	}
	rhi.cmd_timestamp(cmd, "debug view")
	Params :: struct {mode, available, lights_scale: u32}
	params := Params{mode = u32(mode), available = u32(available), lights_scale = DEBUG_LIGHTS_SCALE}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Debug_Views])
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, source)
	rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.normal)
	rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.linear_depth)
	rhi.cmd_bind_texture(cmd, SLOT_PASS3, t.display)
	rhi.cmd_dispatch(cmd, groups(t.width, 8), groups(t.height, 8))
}
