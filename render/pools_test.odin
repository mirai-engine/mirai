package mirai_render

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:rhi"

// A grid of quads of side cells, flat on y = 0.
@(private = "file")
pools_grid :: proc(r: ^Renderer, cells: int) -> (Mesh_Handle, bool) {
	vertices := make([]Mesh_Vertex, (cells + 1) * (cells + 1))
	defer delete(vertices)
	indices := make([dynamic]u32)
	defer delete(indices)
	for z in 0 ..= cells {
		for x in 0 ..= cells {vertices[z * (cells + 1) + x] = {position = {f32(x), 0, f32(z)}, normal = {0, 1, 0}, color = {1, 1, 1}}}
	}
	for z in 0 ..< cells {
		for x in 0 ..< cells {
			a := u32(z * (cells + 1) + x)
			b, c, d := a + 1, a + u32(cells + 1), a + u32(cells + 2)
			append(&indices, a, c, b, b, c, d)
		}
	}
	return mesh_add(r, vertices, indices[:])
}

@(test)
a_small_pool_growth_keeps_its_data_with_aligned_copies :: proc(t: ^testing.T) {
	settings:=DEFAULT_SETTINGS;settings.gi_enabled,settings.taa=false,false
	f: Fixture
	if !fixture_init(t, &f, 64, 64, settings) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	if !testing.expect(t,pool_room(r,.Vertex,13),r.error) {return}
	first:=r.scene.vertex_buffer
	testing.expectf(t,rhi.buffer_size(device,first)%4==0,"pool capacity must permit an aligned copy")
	values:[13]u32
	for &value,i in values {value=u32(i+123)}
	if !testing.expect(t,rhi.buffer_upload(device,first,0,mem.slice_to_bytes(values[:])),rhi.device_error(device)) {return}
	if !testing.expect(t,pool_room(r,.Vertex,21),r.error) {return}
	cmd:=rhi.immediate_begin(device)
	pool_moves_record(r,cmd)
	if !testing.expect(t,rhi.immediate_end(device,cmd),rhi.device_error(device)) {return}
	actual:[13]u32
	if !testing.expect(t,rhi.buffer_read(device,r.scene.vertex_buffer,0,mem.slice_to_bytes(actual[:])),rhi.device_error(device)) {return}
	testing.expect_value(t,actual,values)
}

// A pool the GPU has no memory for leaves out what asked for it and draws the
// rest; it says so, does not ask for the same size again until something goes,
// and grows again after. A pool that grows keeps what its old buffer held.
@(test)
a_pool_without_memory_leaves_out_what_asked_and_draws_the_rest :: proc(t: ^testing.T) {
	settings := DEFAULT_SETTINGS
	settings.gi_enabled, settings.taa = false, false
	f: Fixture
	if !fixture_init(t, &f, 64, 64, settings) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	s := &r.scene
	camera := Camera{position = {8, 10, -6}, forward = {0, -10, 14}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 100, exposure = UNIT_EXPOSURE}

	small, added := pools_grid(r, 8)
	if !testing.expect(t, added, r.error) {return}
	scene_given(r, {Instance_Desc{object_id = 1, mesh = small, transform = Mat4(1)}}, nil, {}, {})
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	held := rhi.buffer_size(device, s.vertex_buffer)

	// No more room than the vertex pool holds now.
	s.pool_bytes_max = held
	_, taken := pools_grid(r, 96)
	testing.expect(t, !taken, "a mesh past the memory of the GPU is not taken")
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	testing.expect(t, strings.contains(r.stats.problem, "no memory for more geometry"), r.stats.problem)
	refusal := s.pool_refused[.Vertex]
	_, taken = pools_grid(r, 96)
	testing.expect(t, !taken && s.pool_refused[.Vertex] == refusal && s.refused.meshes == 2, "the same size is not asked for again")
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	testing.expect_value(t, r.stats.instances, 1)

	// Something goes, and the GPU has the room again.
	s.pool_bytes_max = 0
	geometry_released(s, 1 << 30)
	large: Mesh_Handle
	large, taken = pools_grid(r, 96)
	testing.expect(t, taken, r.error)
	testing.expect(t, s.vertex_buffer != 0 && rhi.buffer_size(device, s.vertex_buffer) > held, "the pool grew")
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	testing.expect_value(t, r.stats.problem, "")
	rhi.device_wait_idle(device)
	// The words of the old buffer were copied, and the new ones uploaded.
	gpu := make([]u8, len(s.vertices) * size_of(u32))
	defer delete(gpu)
	if testing.expect(t, rhi.buffer_read(device, s.vertex_buffer, 0, gpu), rhi.device_error(device)) {
		testing.expect(t, mem.compare(gpu, mem.slice_to_bytes(s.vertices[:])) == 0, "the GPU holds the vertex pool as the CPU does")
	}
	// The mesh that goes from before the large one leaves its room free between them, as the stats say.
	before := r.stats.geometry_free
	scene_given(r, {Instance_Desc{object_id = 2, mesh = large, transform = Mat4(1)}}, nil, {}, {})
	testing.expect(t, mesh_remove(r, small))
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	vertices := u64((8 + 1) * (8 + 1)) * size_of(u32)
	testing.expectf(t, r.stats.geometry_free >= before + vertices && r.stats.geometry_free_largest >= vertices && r.stats.geometry_free_largest <= r.stats.geometry_free, "free %d, largest %d", r.stats.geometry_free, r.stats.geometry_free_largest)
	// What instances give over their rows lives in the index pool: without room for it they show their rows as they are, and the renderer says so.
	s.pool_bytes_max = 1
	given: Instance_Material_Values
	given.count = INSTANCE_VALUES_MAX
	for &entry in given.entries {entry = {row = 0, word = 1 << INSTANCE_VALUE_COUNT_SHIFT}}
	many := make([]Instance_Desc, 4096)
	defer delete(many)
	for &desc, i in many {desc = {object_id = u64(i + 1), mesh = large, transform = Mat4(1), material_values = given}}
	scene_given(r, many, nil, {}, {})
	said: [1024]u8
	problem := geometry_refused_problem(r, said[:])
	testing.expect(t, strings.contains(problem, "what their entities give"), problem)
}

// A mesh at rest traced by hardware has its BLAS made smaller frames after
// its build, and the TLAS of that frame names the smaller one.
@(test)
blas_of_a_mesh_at_rest_is_compacted :: proc(t: ^testing.T) {
	settings := DEFAULT_SETTINGS
	settings.taa = false
	f: Fixture
	if !fixture_init(t, &f, 64, 64, settings) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	if !rhi.device_info(device).features.ray_query {fmt.eprintln("compaction test skipped: no hardware ray tracing");return}
	if !r.hardware_rt {fmt.eprintln("compaction test skipped: rays are traced by software");return}
	mesh, added := pools_grid(r, 64)
	if !testing.expect(t, added, r.error) {return}
	scene_given(r, {Instance_Desc{object_id = 1, mesh = mesh, transform = Mat4(1)}}, nil, {}, {})
	camera := Camera{position = {32, 20, -10}, forward = {0, -20, 40}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 200, exposure = UNIT_EXPOSURE}
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	_, built := rhi.accel_memory(device)
	for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	rhi.device_wait_idle(device)
	_, compacted := rhi.accel_memory(device)
	testing.expectf(t, compacted < built, "the structures took %d bytes after the build and %d after the compaction", built, compacted)
	testing.expect(t, !r.scene.tlas_dirty && r.tlas_problem == "", "the TLAS was built again over the compacted BLAS")
	testing.expect_value(t, rhi.device_validation_errors(device), 0)
}
