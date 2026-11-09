package mirai_render

import "core:fmt"
import "mirai:rhi"

// Startup validation of the hardware ray tracing path. Native acceleration
// structures and ray queries depend on driver quality, so before the
// renderer trusts them it traces rays with known answers against a tiny
// two-instance scene. Any error or mismatch keeps the software BVH walker,
// which produces identical results on every GPU.
hardware_rt_self_test :: proc(r: ^Renderer) -> (ok: bool, reason: string) {
	d := r.device
	// The RHI makes native the instances the renderer writes, as this test does.
	if !rhi.tlas_translator_set(d, &r.shader_codes[.Tlas_Instances_Comp]) {return false, fmt.tprintf("translation of TLAS instances: %s", rhi.device_error(d))}
	pipeline := rhi.pipeline_create_compute(d, {shader = &r.shader_codes[.Rt_Selftest_Comp], name = "rt self test"})
	if pipeline == 0 {return false, "self-test pipeline failed"}
	defer rhi.pipeline_destroy(d, pipeline)

	// Unit quad in the XY plane: triangle 0 = (0,0) (1,0) (1,1), triangle 1 = (0,0) (1,1) (0,1).
	positions := [4][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}
	indices := [6]u32{0, 1, 2, 0, 2, 3}
	vb := rhi.buffer_create(d, {size = size_of(positions), usage = {.Storage, .Accel_Input}, name = "selftest vertices"})
	ib := rhi.buffer_create(d, {size = size_of(indices), usage = {.Storage, .Index, .Accel_Input}, name = "selftest indices"})
	rays_buffer := rhi.buffer_create(d, {size = 16 * size_of(Vec4), usage = {.Storage}, name = "selftest rays"})
	instances_buffer := rhi.buffer_create(d, {size = 2 * size_of(rhi.Tlas_Instance), usage = {.Storage}, name = "selftest instances"})
	defer if instances_buffer != 0 {rhi.buffer_destroy(d, instances_buffer)}
	hits_buffer := rhi.buffer_create(d, {size = 8 * size_of(Vec4), usage = {.Storage}, name = "selftest hits"})
	defer for b in ([]rhi.Buffer{vb, ib, rays_buffer, hits_buffer}) {if b != 0 {rhi.buffer_destroy(d, b)}}
	if vb == 0 || ib == 0 || rays_buffer == 0 || hits_buffer == 0 {return false, "self-test buffers failed"}
	if !rhi.buffer_upload_slice(d, vb, 0, positions[:]) || !rhi.buffer_upload_slice(d, ib, 0, indices[:]) {return false, "self-test upload failed"}
	blas := rhi.blas_create(d, {vertex_buffer = vb, vertex_stride = 12, vertex_count = 4, index_buffer = ib, triangle_count = 2, name = "selftest blas"})
	tlas := rhi.tlas_create(d, 2, "selftest tlas")
	defer if blas != 0 {rhi.accel_destroy(d, blas)}
	defer if tlas != 0 {rhi.accel_destroy(d, tlas)}
	if blas == 0 || tlas == 0 {return false, fmt.tprintf("acceleration structures: %s", rhi.device_error(d))}
	// Instance 7 at z = -5; instance 9 translated to x = 10 and scaled by 2.
	id := rhi.accel_id(d, blas)
	instances := [2]rhi.Tlas_Instance{
		{transform = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, -5}}, custom_index = 7, mask_flags = 0xFF, blas = id},
		{transform = {{2, 0, 0, 10}, {0, 2, 0, 0}, {0, 0, 2, -5}}, custom_index = 9, mask_flags = 0xFF, blas = id},
	}
	if instances_buffer == 0 || !rhi.buffer_upload_slice(d, instances_buffer, 0, instances[:]) {return false, "self-test instances failed"}
	Expect :: struct {t: f32, instance, primitive: i32}
	rays := [16]Vec4{
		{0.75, 0.25, 0, 100}, {0, 0, -1, 0}, // instance 7, triangle 0
		{0.25, 0.75, 0, 100}, {0, 0, -1, 0}, // instance 7, triangle 1
		{5, 5, 0, 100}, {0, 0, -1, 0},       // miss
		{11.5, 0.5, 0, 100}, {0, 0, -1, 0},  // instance 9, triangle 0 (scaled)
		{10.5, 1.5, 0, 100}, {0, 0, -1, 0},  // instance 9, triangle 1
		{0.75, 0.25, 0, 4}, {0, 0, -1, 0},   // too short: miss
		{0.75, 0.25, -10, 100}, {0, 0, 1, 0},// from behind, double sided: t = 5
		{0.5, 0.25, 0, 100}, {0, 1, 0, 0},   // parallel to the plane: miss
	}
	expected := [8]Expect{{5, 7, 0}, {5, 7, 1}, {-1, -1, -1}, {5, 9, 0}, {5, 9, 1}, {-1, -1, -1}, {5, 7, 0}, {-1, -1, -1}}
	if !rhi.buffer_upload_slice(d, rays_buffer, 0, rays[:]) {return false, "self-test upload failed"}
	cmd := rhi.immediate_begin(d)
	if cmd == nil {return false, fmt.tprintf("self-test submission: %s", rhi.device_error(d))}
	rhi.cmd_build_blas(cmd, blas)
	if !rhi.cmd_build_tlas(cmd, tlas, instances_buffer, 0, len(instances)) {rhi.immediate_end(d, cmd); return false, fmt.tprintf("self-test TLAS: %s", rhi.device_error(d))}
	rhi.cmd_bind_pipeline(cmd, pipeline)
	rhi.cmd_bind_accel(cmd, SLOT_TLAS, tlas)
	rhi.cmd_bind_buffer(cmd, 19, rays_buffer)
	rhi.cmd_bind_buffer(cmd, 20, hits_buffer)
	rhi.cmd_dispatch(cmd, 1)
	if !rhi.immediate_end(d, cmd) {return false, fmt.tprintf("self-test submission: %s", rhi.device_error(d))}
	hits: [8]Vec4
	if !rhi.buffer_read_slice(d, hits_buffer, 0, hits[:]) {return false, "self-test readback failed"}
	for e, i in expected {
		h := hits[i]
		if e.instance < 0 {
			if h.y >= 0 {return false, fmt.tprintf("ray %d should miss but hit instance %v", i, h.y)}
			continue
		}
		if i32(h.y) != e.instance || i32(h.z) != e.primitive || abs(h.x - e.t) > 1e-3 {
			return false, fmt.tprintf("ray %d: got t=%v instance=%v primitive=%v, expected %v", i, h.x, h.y, h.z, e)
		}
	}
	return true, ""
}
