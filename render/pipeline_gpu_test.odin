package mirai_render

import "core:math"
import "core:mem"
import "core:testing"
import "mirai:rhi"

@(private = "file", rodata)
PASS_BINDINGS := [?]rhi.Binding_Info{
	{slot = SLOT_PARAMS, kind = .Uniform_Buffer, stages = {.Compute}},
	{slot = SLOT_PASS0, kind = .Sampled_Texture, stages = {.Compute}},
	{slot = SLOT_PASS1, kind = .Storage_Texture, stages = {.Compute}},
}

// The test stage of pass.comp in shaders/tests: target = source * scale + offset.
@(private = "file")
pass_shader :: proc() -> rhi.Shader_Code {
	bindings := PASS_BINDINGS[:]
	when ODIN_OS == .Darwin {
		return {binary = {msl = #load("../shaders/build/tests/pass.comp.metal", string), msl_entry = "main0"}, name = "pass.comp", stage = .Compute, threadgroup = {8, 8, 1}, bindings = bindings}
	} else {
		return {binary = {spirv = #load("../shaders/build/tests/pass.comp.spv")}, name = "pass.comp", stage = .Compute, threadgroup = {8, 8, 1}, bindings = bindings}
	}
}

@(private = "file")
Scale_Pass :: struct {
	pipeline:        rhi.Pipeline,
	source, target:  Render_Resource,
	source_previous: bool,
	scale, offset:   f32,
	runs:            int,
	unbound:         bool,
}

@(private = "file")
scale_record :: proc(s: ^Stage_Pass, user: rawptr) {
	data := cast(^Scale_Pass)user
	data.runs += 1
	if !pass_resource(s, 0, data.source, data.source_previous) || !pass_resource(s, 1, data.target) {data.unbound = true; return}
	params := struct {scale, offset: f32, pad: [2]u32}{data.scale, data.offset, {}}
	pass_pipeline(s, data.pipeline)
	pass_params(s, &params, size_of(params))
	pass_dispatch(s, (s.width + 7) / 8, (s.height + 7) / 8)
}

@(private = "file")
half_to_f32 :: proc(h: u16) -> f32 {
	return f32(transmute(f16)h)
}

// Two views of the same camera side by side: one with the standard pipeline,
// the other with passes of its own between Composite and Transparency. Their
// images differ by what those passes multiply, a resource with history counts
// the frames, and two resources used one after the other share a texture.
@(test)
pipeline_passes_run_between_stages_over_the_resources_they_declare :: proc(t: ^testing.T) {
	settings := DEFAULT_SETTINGS
	settings.gi_enabled, settings.taa = false, false
	f: Fixture
	if !fixture_init(t, &f, 128, 64, settings) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	vertices: [24]Mesh_Vertex
	indices: [36]u32
	normals := [6]Vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
	for n, face in normals {
		u := Vec3{n.y, n.z, n.x}
		v := Vec3{n.y * u.z - n.z * u.y, n.z * u.x - n.x * u.z, n.x * u.y - n.y * u.x}
		corners := [4]Vec3{n - u - v, n + u - v, n + u + v, n - u + v}
		for c, i in corners {vertices[face * 4 + i] = {position = c * 0.5, normal = n, color = {1, 1, 1}}}
		base := u32(face * 4)
		for q, i in ([6]u32{base, base + 1, base + 2, base, base + 2, base + 3}) {indices[face * 6 + i] = q}
	}
	cube, added := mesh_add(r, vertices[:], indices[:])
	testing.expect(t, added)
	floor := Mat4(1)
	floor[0, 0], floor[1, 1], floor[2, 2], floor[1, 3] = 8, 0.1, 8, -0.55
	instances := []Instance_Desc{{object_id = 1, mesh = cube, transform = 1, tint = {0.7, 0.4, 0.2}}, {object_id = 2, mesh = cube, transform = floor, tint = {0.6, 0.6, 0.6}}}
	lights := []Light_Desc{{position = {1.2, 1.5, 1}, color = {1, 0.8, 0.6}, intensity = 4 * math.PI, range = 8, radius = 0.1}}
	scene_set(r, instances, lights, {direction = {0.4, 1, 0.3}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true}, {sky = {0.2, 0.3, 0.5}})

	shader := pass_shader()
	pipeline := rhi.pipeline_create_compute(device, {shader = &shader, name = "test pass"})
	if !testing.expect(t, pipeline != 0, rhi.device_error(device)) {return}
	defer rhi.pipeline_destroy(device, pipeline)
	double := Scale_Pass{pipeline = pipeline, source = .Display, target = .Custom0, scale = 2}
	count := Scale_Pass{pipeline = pipeline, source = .Custom1, source_previous = true, target = .Custom1, scale = 1, offset = 1}
	back := Scale_Pass{pipeline = pipeline, source = .Custom0, target = .Display, scale = 2}
	again := Scale_Pass{pipeline = pipeline, source = .Display, target = .Custom2, scale = 2}
	back_again := Scale_Pass{pipeline = pipeline, source = .Custom2, target = .Display, scale = 2}
	passes := []Render_Pass_Desc{
		{stage = .Geometry}, {stage = .Nested}, {stage = .Surface}, {stage = .Direct}, {stage = .Composite},
		{stage = .Custom, name = "double", uses = []Render_Use{{.Display, .Read, false}, {.Custom0, .Write, false}}, record = scale_record, user = &double},
		{stage = .Custom, name = "count", uses = []Render_Use{{.Custom1, .Read, true}, {.Custom1, .Write, false}}, record = scale_record, user = &count},
		{stage = .Custom, name = "back", uses = []Render_Use{{.Custom0, .Read, false}, {.Custom1, .Read, false}, {.Display, .Write, false}}, record = scale_record, user = &back},
		{stage = .Custom, name = "again", uses = []Render_Use{{.Display, .Read, false}, {.Custom2, .Write, false}}, record = scale_record, user = &again},
		{stage = .Custom, name = "back again", uses = []Render_Use{{.Custom2, .Read, false}, {.Display, .Write, false}}, record = scale_record, user = &back_again},
		{stage = .Transparency}, {stage = .Resolve}, {stage = .Output},
	}
	resources := []Render_Resource_Desc{
		{id = .Custom0, format = .RGBA16_Float, size = .Full},
		{id = .Custom1, format = .RGBA16_Float, size = .Fixed, width = 8, height = 8, history = true},
		{id = .Custom2, format = .RGBA16_Float, size = .Full},
	}
	desc := Render_Pipeline_Desc{passes = passes, resources = resources}
	// A pass in place of the Resolve stage, as an upscaler is, writes Taa: the
	// Output stage finishes that image.
	upscale := Scale_Pass{pipeline = pipeline, source = .Display, target = .Taa, scale = 2}
	upscaled := Render_Pipeline_Desc{passes = []Render_Pass_Desc{
		{stage = .Geometry}, {stage = .Nested}, {stage = .Surface}, {stage = .Direct}, {stage = .Composite}, {stage = .Transparency},
		{stage = .Custom, name = "upscale", uses = []Render_Use{{.Display, .Read, false}, {.Taa, .Write, false}}, record = scale_record, user = &upscale},
		{stage = .Output},
	}, jitter = .None}
	camera := Camera{position = {0, 1.5, 3}, forward = {0, -1.5, -3}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	frames :: 5
	for _ in 0 ..< frames {
		own, error := renderer_pipeline(r, desc)
		if !testing.expect(t, own != 0, error) {return}
		resolved, resolved_error := renderer_pipeline(r, upscaled)
		if !testing.expect(t, resolved != 0, resolved_error) {return}
		views := []Frame_View{{camera = camera, rect = {0, 0, 64, 64}}, {camera = camera, rect = {64, 0, 64, 64}, pipeline = own}, {camera = camera, rect = {0, 0, 64, 64}, pipeline = resolved}}
		testing.expect(t, renderer_frame(r, {camera = camera, views = views}), r.error)
	}
	rhi.device_wait_idle(device)
	{
		shown := make([]u8, int(r.views[0].targets.output_width * r.views[0].targets.output_height * 4), context.temp_allocator)
		finished := make([]u8, len(shown), context.temp_allocator)
		if !testing.expect(t, golden_read_texture(device, r.views[0].targets.ldr, shown), rhi.device_error(device)) {return}
		if !testing.expect(t, golden_read_texture(device, r.views[2].targets.ldr, finished), rhi.device_error(device)) {return}
		plain, doubled := 0, 0
		for i in 0 ..< len(shown) {if i % 4 != 3 {plain += int(shown[i]); doubled += int(finished[i])}}
		testing.expect_value(t, upscale.runs, frames)
		testing.expectf(t, plain > 0 && f32(doubled) > 1.2 * f32(plain), "the Output stage finishes the image the pass wrote in Taa: %d against %d", doubled, plain)
	}
	for pass in ([]^Scale_Pass{&double, &count, &back, &again, &back_again}) {
		testing.expect_value(t, pass.runs, frames)
		testing.expect(t, !pass.unbound)
	}
	standard, own := &r.views[0], &r.views[1]
	testing.expect_value(t, own.resources[2].textures[0], own.resources[0].textures[0])
	testing.expect(t, own.resources[0].owned && !own.resources[2].owned && own.resources[1].owned)

	read :: proc(t: ^testing.T, device: ^rhi.Device, texture: rhi.Texture, pixels: []u16) -> bool {
		return testing.expect(t, golden_read_texture(device, texture, mem.slice_to_bytes(pixels)), rhi.device_error(device))
	}
	size := int(standard.targets.width * standard.targets.height * 4)
	plain := make([]u16, size, context.temp_allocator)
	scaled := make([]u16, size, context.temp_allocator)
	if !read(t, device, standard.targets.display, plain) || !read(t, device, own.targets.display, scaled) {return}
	wrong, lit := 0, 0
	for value, i in plain {
		if i % 4 == 3 {continue}
		expected := half_to_f32(value) * 16
		if half_to_f32(value) > 0.01 {lit += 1}
		if abs(half_to_f32(scaled[i]) - expected) > expected * 1e-3 {wrong += 1}
	}
	testing.expect(t, lit > size / 8, "the scene should light the view")
	testing.expectf(t, wrong == 0, "%d channels of the view with passes are not 16 times those of the standard one", wrong)

	counted := make([]u16, 8 * 8 * 4, context.temp_allocator)
	current := int((own.frames - 1) % 2)
	if !read(t, device, own.resources[1].textures[current], counted) {return}
	testing.expect_value(t, half_to_f32(counted[0]), f32(frames))

	// Steady frames ask for the same pipeline and allocate nothing.
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	{
		context.allocator = mem.tracking_allocator(&tracker)
		for _ in 0 ..< 3 {
			own_pipeline, _ := renderer_pipeline(r, desc)
			views := []Frame_View{{camera = camera, rect = {0, 0, 64, 64}}, {camera = camera, rect = {64, 0, 64, 64}, pipeline = own_pipeline}}
			renderer_frame(r, {camera = camera, views = views})
		}
	}
	testing.expect_value(t, tracker.total_allocation_count, i64(0))

	// A view drawn with another pipeline starts again: the Light one, then Full.
	light := renderer_standard_pipeline(r, .Light)
	for pipeline in ([]Render_Pipeline_Handle{light, light, 0}) {
		views := []Frame_View{{camera = camera, rect = {0, 0, 64, 64}}, {camera = camera, rect = {64, 0, 64, 64}, pipeline = pipeline}}
		testing.expect(t, renderer_frame(r, {camera = camera, views = views}), r.error)
	}
	testing.expect_value(t, own.resources[0].textures[0], rhi.Texture(0))
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(device), rhi.device_validation_message(device))
}
