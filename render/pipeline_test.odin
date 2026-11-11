package mirai_render

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
expect_error :: proc(t: ^testing.T, desc: Render_Pipeline_Desc, words: string, loc := #caller_location) {
	plan: Render_Plan
	buffer: [512]u8
	ok, error := plan_compile(&plan, desc, buffer[:])
	testing.expectf(t, !ok, "the pipeline compiled, and should say %q", words, loc = loc)
	testing.expectf(t, strings.contains(error, words), "the error %q does not say %q", error, words, loc = loc)
}

@(private)
nothing :: proc(s: ^Stage_Pass, user: rawptr) {}

@(test)
pipelines_keep_their_order_leave_out_what_nothing_reads_and_say_what_is_wrong :: proc(t: ^testing.T) {
	buffer: [512]u8
	for kind in Standard_Pipeline {
		plan: Render_Plan
		ok, error := plan_compile(&plan, {passes = standard_pipeline_passes(kind)}, buffer[:])
		testing.expect(t, ok, error)
		testing.expect_value(t, plan.order_count, len(standard_pipeline_passes(kind)))
		for at in 0 ..< plan.order_count {testing.expect_value(t, int(plan.order[at]), at)}
	}
	light: Render_Plan
	plan_compile(&light, {passes = standard_pipeline_passes(.Light)}, buffer[:])
	testing.expect(t, .Reflections not_in light.stages && .Indirect not_in light.stages)

	// A pass whose resource nothing reads is left out; the passes it would have read from stay.
	{
		unread := []Render_Use{{.Display, .Read, false}, {.Custom0, .Write, false}}
		passes := []Render_Pass_Desc{
			{stage = .Geometry}, {stage = .Direct}, {stage = .Composite},
			{stage = .Custom, name = "unread", uses = unread, record = nothing},
			{stage = .Output},
		}
		resources := []Render_Resource_Desc{{id = .Custom0, format = .RGBA16_Float}}
		plan: Render_Plan
		ok, error := plan_compile(&plan, {passes = passes, resources = resources}, buffer[:])
		testing.expect(t, ok, error)
		testing.expect_value(t, plan.order_count, 4)
		testing.expect(t, .Custom not_in plan.stages)
		testing.expect_value(t, plan.first_use[0], i8(-1))
	}
	// Optional reads: a pipeline without reflections, screen GI or temporal resolve.
	{
		passes := []Render_Pass_Desc{{stage = .Geometry}, {stage = .Direct}, {stage = .Composite}, {stage = .Output}}
		plan: Render_Plan
		ok, error := plan_compile(&plan, {passes = passes}, buffer[:])
		testing.expect(t, ok, error)
	}

	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Geometry}, {stage = .Composite}, {stage = .Output}}}, "reads Direct, which no pass before it writes")
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Geometry}, {stage = .Composite}, {stage = .Direct}, {stage = .Output}}}, "reads Direct, which no pass before it writes")
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Geometry}, {stage = .Direct}, {stage = .Composite}}}, "no Output stage")
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Geometry}, {stage = .Geometry}, {stage = .Output}}}, "second Geometry stage")
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Geometry, uses = []Render_Use{{.Display, .Read, false}}}, {stage = .Output}}}, "declares its own resources")
	writes_albedo := []Render_Use{{.Albedo, .Write, false}}
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Custom, name = "paint", uses = writes_albedo, record = nothing}}}, "writes Albedo, which a custom pass can only read")
	undeclared := []Render_Use{{.Custom3, .Write, false}}
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Custom, name = "own", uses = undeclared, record = nothing}}}, "does not declare in resources")
	previous := []Render_Use{{.Display, .Read, true}}
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Custom, name = "past", uses = previous, record = nothing}}}, "previous Display")
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Custom, name = "silent", uses = previous}}}, "has no record procedure")
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Output}}, resources = []Render_Resource_Desc{{id = .Hdr, format = .RGBA16_Float}}}, "declares Hdr")
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Output}}, resources = []Render_Resource_Desc{{id = .Custom0, format = .RGBA8_Srgb}}}, "format RGBA8_Srgb")
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Output}}, resources = []Render_Resource_Desc{{id = .Custom0, bytes = 6}}}, "multiple of 4")
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Output}}, resources = []Render_Resource_Desc{{id = .Custom0, format = .R8_Unorm, history = true, kept = true}}}, "history and kept")
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Output}}, resources = []Render_Resource_Desc{{id = .Custom0, size = .Fixed, width = 1, height = 1, pixel_bytes = 4}}}, "pixel_bytes and a Fixed size")
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Output}}, resources = []Render_Resource_Desc{{id = .Custom0, size = .Fixed, width = 4, height = 4, shift = 1, format = .R8_Unorm}}}, "Fixed with a shift")
	writes_depth := []Render_Use{{.Depth, .Write, false}}
	expect_error(t, {passes = []Render_Pass_Desc{{stage = .Custom, name = "depth", uses = writes_depth, record = nothing}}}, "writes Depth")
	// A pass in place of the Resolve stage asks for the jitter of an upscaler.
	{
		resolves := []Render_Use{{.Display, .Read, false}, {.Depth, .Read, false}, {.Exposure, .Read, false}, {.Custom0, .Read, false}, {.Custom1, .Write, false}, {.Taa, .Write, false}}
		resources := []Render_Resource_Desc{{id = .Custom0, format = .R8_Unorm, kept = true}, {id = .Custom1, format = .RG16_Float, shift = 1, align = 32, mips = RENDER_MIPS_ALL}}
		passes := []Render_Pass_Desc{{stage = .Geometry}, {stage = .Direct}, {stage = .Composite}, {stage = .Custom, name = "upscale", uses = resolves, record = nothing}, {stage = .Output}}
		expect_error(t, {passes = passes, resources = resources}, "jitter Upscale")
		plan: Render_Plan
		ok, error := plan_compile(&plan, {passes = passes, resources = resources, jitter = .Upscale}, buffer[:])
		testing.expect(t, ok, error)
		testing.expect_value(t, plan.jitter, Render_Jitter.Upscale)
		testing.expect(t, .Custom in plan.stages)
	}
	// Passes after the Output stage generate a frame: nothing reads Generated, and they stay.
	{
		flow := []Render_Use{{.Ldr, .Read, false}, {.Custom0, .Read, true}, {.Custom0, .Write, false}}
		interpolate := []Render_Use{{.Ldr, .Read, false}, {.Custom0, .Read, false}, {.Generated, .Write, false}}
		resources := []Render_Resource_Desc{{id = .Custom0, format = .R8_Uint, size = .Output, history = true}}
		passes := []Render_Pass_Desc{
			{stage = .Geometry}, {stage = .Direct}, {stage = .Composite}, {stage = .Output},
			{stage = .Custom, name = "flow", uses = flow, record = nothing},
			{stage = .Custom, name = "interpolate", uses = interpolate, record = nothing},
		}
		plan: Render_Plan
		ok, error := plan_compile(&plan, {passes = passes, resources = resources}, buffer[:])
		testing.expect(t, ok, error)
		testing.expect(t, plan.generates)
		testing.expect_value(t, plan.order_count, 6)
		standard: Render_Plan
		plan_compile(&standard, {passes = standard_pipeline_passes(.Full)}, buffer[:])
		testing.expect(t, !standard.generates)
		paints := []Render_Use{{.Ldr, .Read, false}, {.Display, .Write, false}}
		expect_error(t, {passes = []Render_Pass_Desc{{stage = .Geometry}, {stage = .Direct}, {stage = .Composite}, {stage = .Output}, {stage = .Custom, name = "late", uses = paints, record = nothing}}}, "comes after the Output stage and writes Display")
		early := []Render_Use{{.Display, .Read, false}, {.Generated, .Write, false}}
		expect_error(t, {passes = []Render_Pass_Desc{{stage = .Geometry}, {stage = .Direct}, {stage = .Composite}, {stage = .Custom, name = "early", uses = early, record = nothing}, {stage = .Output}}}, "writes Generated before the Output stage")
	}
}

@(test)
pipeline_resources_follow_the_view_by_shift_align_and_pixels :: proc(t: ^testing.T) {
	targets := Targets{width = 1001, height = 563, output_width = 1920, output_height = 1080}
	w, h := resource_size(&targets, {size = .Full, shift = 1, align = 32})
	testing.expect_value(t, w, u32(512))
	testing.expect_value(t, h, u32(288))
	w, h = resource_size(&targets, {size = .Full, align = 8})
	testing.expect_value(t, w, u32(1008))
	testing.expect_value(t, h, u32(568))
	w, h = resource_size(&targets, {size = .Output, shift = 3})
	testing.expect_value(t, w, u32(240))
	testing.expect_value(t, h, u32(135))
	w, h = resource_size(&targets, {size = .Fixed, width = 1, height = 1})
	testing.expect_value(t, w, u32(1))
	testing.expect_value(t, mip_count(512, 288), u32(10))
	testing.expect_value(t, upscale_jitter_phases(1280, 1920), u32(18))
	testing.expect_value(t, upscale_jitter_phases(1920, 1920), u32(8))
	// The slots of a custom pass, as custom_slots.slang declares them for shaders.
	bindings := CUSTOM_PASS_BINDINGS
	testing.expect_value(t, bindings[0], u32(SLOT_PASS0))
	testing.expect_value(t, bindings[9], u32(SLOT_PASS9))
	testing.expect_value(t, bindings[10], u32(SLOT_INSTANCES))
	testing.expect_value(t, bindings[CUSTOM_PASS_SLOTS - 1], u32(SLOT_POINTS))
	for binding in bindings {testing.expect(t, binding != SLOT_MATERIAL_SAMPLER && binding != SLOT_PARAMS)}
}

// Pipelines no frame asks for make room for others; the standard ones stay.
@(test)
pipelines_a_frame_does_not_ask_for_make_room :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.frame = 1
	for kind in Standard_Pipeline {
		handle, error := renderer_pipeline(r, {passes = standard_pipeline_passes(kind)})
		testing.expect(t, handle != 0, error)
		plan_find(r, handle).standard = true
		r.standard_pipelines[kind] = handle
	}
	names: [RENDER_PIPELINE_CAPACITY + 4][8]u8
	made: [RENDER_PIPELINE_CAPACITY + 4]Render_Pipeline_Handle
	reads := []Render_Use{{.Display, .Read, false}, {.Display, .Write, false}}
	for i in 0 ..< len(made) {
		// Each one differs by the name of the pass it brings.
		name := fmt.bprintf(names[i][:], "p%d", i)
		passes := [5]Render_Pass_Desc{{stage = .Geometry}, {stage = .Direct}, {stage = .Composite}, {stage = .Custom, name = name, uses = reads, record = nothing}, {stage = .Output}}
		desc := Render_Pipeline_Desc{passes = passes[:]}
		r.frame = u64(2 + i)
		handle, error := renderer_pipeline(r, desc)
		testing.expect(t, handle != 0, error)
		made[i] = handle
		again, _ := renderer_pipeline(r, desc)
		testing.expect_value(t, again, handle)
	}
	// The latest ones are there, the first ones went, the standard ones stayed.
	testing.expect(t, plan_find(r, made[len(made) - 1]) != nil)
	testing.expect(t, plan_find(r, made[0]) == nil)
	for kind in Standard_Pipeline {testing.expect(t, plan_find(r, r.standard_pipelines[kind]) != nil)}
	// A frame that asked for every place has none for another.
	for i in 0 ..< RENDER_PIPELINE_CAPACITY {r.plans[i].asked = r.frame}
	_, error := renderer_pipeline(r, {passes = standard_pipeline_passes(.Light)[:4]})
	testing.expect(t, strings.contains(error, "places are in use"), error)
}
