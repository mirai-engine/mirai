package mirai_render

import "core:testing"
import "mirai:rhi"

// A scene that fills the list of the chunks of the cull past where it starts
// drops in its first frames and asks for more; a renderer that starts from
// what it asked for (its marks, which the host keeps by scene) holds the same
// scene from its first frame, dropping nothing.
@(test)
a_scene_seen_again_starts_its_lists_at_its_marks_and_drops_nothing :: proc(t: ^testing.T) {
	SIDE :: 330 // instances a side: one chunk each, past the list the chunks start with
	#assert(SIDE * SIDE > CULL_START[.Chunks] * 3 / 2)
	settings := DEFAULT_SETTINGS
	settings.gi_enabled, settings.taa = false, false
	camera := Camera{position = {0, 50, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 90, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	marks: Capacity_Marks
	for run in 0 ..< 2 {
		f: Fixture
		if !fixture_init(t, &f, 128, 128, settings) {return}
		defer fixture_destroy(&f)
		r := f.renderer
		corners := [4]Vec3{{-0.1, 0, -0.1}, {0.1, 0, -0.1}, {0.1, 0, 0.1}, {-0.1, 0, 0.1}}
		vertices: [4]Mesh_Vertex
		for c, i in corners {vertices[i] = {position = c, normal = {0, 1, 0}, tangent = {1, 0, 0, 1}, color = {1, 1, 1}}}
		indices := [6]u32{0, 2, 1, 0, 3, 2}
		quad, added := mesh_add(r, vertices[:], indices[:])
		if !testing.expect(t, added, r.error) {return}
		instances := make([]Instance_Desc, SIDE * SIDE, context.temp_allocator)
		for &instance, i in instances {
			x, z := f32(i % SIDE) - SIDE / 2, f32(i / SIDE) - SIDE / 2
			instance = {object_id = u64(i + 1), mesh = quad, transform = {0.25, 0, 0, x * 0.25, 0, 1, 0, 0, 0, 0, 0.25, z * 0.25, 0, 0, 0, 1}, tint = {1, 1, 1}}
		}
		if !testing.expect(t, scene_given(r, instances, nil, {}, {}), r.error) {return}
		if run == 1 {renderer_capacity_marks_set(r, marks)}
		dropped: [Cull_List]u32
		for _ in 0 ..< 6 {
			if !testing.expect(t, renderer_frame(r, {camera = camera}), r.error) {return}
			for count, list in renderer_stats(r).cull_dropped {dropped[list] += count}
		}
		if run == 0 {
			marks = renderer_capacity_marks(r)
			testing.expectf(t, dropped[.Chunks] > 0 && marks.cull[.Chunks] > CULL_START[.Chunks], "the first time, the chunks pass their list (%v) and ask for more (%v)", dropped, marks.cull)
		} else {
			testing.expectf(t, dropped == {}, "started from its marks, nothing is dropped: %v", dropped)
			testing.expectf(t, r.scene.cull_capacity[.Chunks] >= marks.cull[.Chunks], "the chunks start at %d, past the mark %d", r.scene.cull_capacity[.Chunks], marks.cull[.Chunks])
		}
		testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
	}
}
