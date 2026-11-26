package mirai_render

import "core:testing"
import "mirai:rhi"

// A batch the GPU fills, with the stage of testdata/batch_fill.comp: what the
// Instances stage of a view writes is what the view draws, at most the room
// of the batch, and nothing when nothing writes it.

@(private = "file")
Fill_Test :: struct {
	handle:  Batch_Handle,
	written: u32, // instances the stage writes; 0: no pass
	target:  Batch_Target,
	bound:   bool, // pass_batch_target bound it in the Instances stage
	refused: bool, // and refused it in the Gbuffer stage
}

@(private = "file")
Fill_Params :: struct {
	target: [4]u32,
	anchor: [4]f32,
}

@(private = "file")
fill_record :: proc(s: ^Stage_Pass, user: rawptr) {
	f := cast(^Fill_Test)user
	if s.stage == .Gbuffer {
		_, wrong := pass_batch_target(s, 0, f.handle)
		f.refused = !wrong
		return
	}
	pipeline := stage_pipeline(s.pass.r, {stage = .Instances, shader = "batch_fill", name = "test batch fill"})
	target, ok := pass_batch_target(s, 0, f.handle)
	f.bound, f.target = ok, target
	if !ok || pipeline == 0 {return}
	params := Fill_Params{{target.first, target.count, target.capacity, f.written}, {target.anchor.x, target.anchor.y, target.anchor.z, 0}}
	pass_pipeline(s, pipeline)
	pass_batch_target(s, 0, f.handle)
	if pass_params(s, &params, size_of(params)) {pass_dispatch(s, (f.written + 63) / 64)}
}

@(private = "file")
fill_box :: proc(r: ^Renderer) -> Mesh_Handle {
	vertices: [24]Mesh_Vertex
	indices: [36]u32
	for n, face in ([6]Vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) {
		u := Vec3{n.y, n.z, n.x}
		v := Vec3{n.y * u.z - n.z * u.y, n.z * u.x - n.x * u.z, n.x * u.y - n.y * u.x}
		for c, i in ([4]Vec3{n - u - v, n + u - v, n + u + v, n - u + v}) {vertices[face * 4 + i] = {position = c * 0.5, normal = n, color = {1, 1, 1}}}
		base := u32(face * 4)
		quad := [6]u32{base, base + 1, base + 2, base, base + 2, base + 3}
		copy(indices[face * 6:], quad[:])
	}
	mesh, _ := mesh_add(r, vertices[:], indices[:])
	return mesh
}

// Boxes along x over a floor: the view draws as many as the stage writes up
// to the room of the batch (visible instances besides the floor), none
// without a pass, and reserving the same room again takes no memory.
@(test)
a_batch_the_gpu_fills_draws_what_the_instances_stage_of_the_view_writes :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 128, 64, DEFAULT_SETTINGS, programs = true) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	box := fill_box(r)
	floor := Instance_Desc{object_id = 1, mesh = box, transform = Mat4{40, 0, 0, 8, 0, 0.2, 0, -0.1, 0, 0, 40, 0, 0, 0, 0, 1}, tint = {0.2, 0.2, 0.2}}
	scene_given(r, {floor}, nil, {direction = {0.1, 1, 0.05}, color = {1, 1, 1}, illuminance = 3, enabled = true}, {sky = {0.3, 0.4, 0.6}})
	camera := Camera{position = {8, 30, 0.01}, forward = {0, -1, -0.0003}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	desc := Batch_Desc{mesh = box, tint = {0.9, 0.2, 0.1}}
	fill := Fill_Test{}
	handle, error := batch_reserve(r, 0, r.world_key, desc, 8, {-1, 0, -1}, {17, 1, 1})
	if !testing.expect_value(t, error, "") {return}
	fill.handle = handle
	held := len(r.scene.indices)
	again, kept := batch_reserve(r, handle, r.world_key, desc, 8, {-2, 0, -2}, {18, 1, 2})
	testing.expect(t, kept == "" && again == handle && len(r.scene.indices) == held, "the same room takes no memory")
	Case :: struct {written: u32, pass: bool, drawn: u32}
	cases := [?]Case{{0, false, 0}, {4, true, 4}, {64, true, 8}, {0, true, 0}}
	for c in cases {
		fill.written = c.written
		for _ in 0 ..< 4 {
			if c.pass {
				testing.expect(t, frame_pass(r, .Instances, fill_record, &fill))
				testing.expect(t, frame_pass(r, .Gbuffer, fill_record, &fill))
			}
			testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
		}
		rhi.device_wait_idle(f.device)
		testing.expectf(t, r.stats.visible_instances == 1 + c.drawn, "%v: %d instances seen besides the floor", c, r.stats.visible_instances - 1)
		if c.pass {
			testing.expect(t, fill.bound && fill.refused, "the target is bound in the Instances stage alone")
			testing.expect(t, fill.target.capacity == 8 && fill.target.count + 1 == fill.target.first)
		}
	}
	_, refused := batch_reserve(r, handle, r.world_key, {mesh = box, flags = {.Casts_Shadow}}, 8, 0, 1)
	testing.expect(t, refused != "", "no ray meets what the GPU fills")
	testing.expect(t, batch_remove(r, handle))
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}
