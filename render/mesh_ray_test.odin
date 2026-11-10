package mirai_render

import "core:math/linalg"
import "core:testing"

// A ray meets a placed mesh at the same place and normal through each way
// the renderer keeps it on the CPU: its software tree, the tree
// mesh_ray_prepare makes while rays are traced by hardware, and its
// triangles one by one; the tree a mesh was prepared with goes with it.
@(test)
mesh_ray_meets_a_mesh_through_its_tree_or_its_triangles :: proc(t: ^testing.T) {
	vertices: [8]Mesh_Vertex
	for &v, i in vertices {
		v.position = {f32(i & 1) - 0.5, f32(i >> 1 & 1) - 0.5, f32(i >> 2 & 1) - 0.5}
		v.normal, v.color, v.tangent = v.position * 2, {1, 1, 1}, {1, 0, 0, 1}
	}
	indices := [36]u32{0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5}
	placed := linalg.matrix4_translate_f32({3, 0, 0}) * linalg.matrix4_scale_f32({2, 2, 2})
	Way :: enum {Software, Prepared, Triangles}
	for way in Way {
		r := new(Renderer)
		defer free(r)
		r.allocator = context.allocator
		r.hardware_rt = way != .Software
		if !testing.expect(t, scene_init(r)) {return}
		defer scene_destroy(r)
		defer ui_offscreen_destroy(r)
		mesh, added := mesh_add(r, vertices[:], indices[:])
		if !testing.expect(t, added) {return}
		if way == .Prepared {
			testing.expect(t, mesh_ray_prepare(r, mesh))
			testing.expect(t, mesh_ray_tree(r, mesh) != nil)
		}
		distance, _, normal, hit := mesh_ray(r, mesh, placed, {3.2, 5, 0.3}, {0, -1, 0})
		testing.expectf(t, hit && abs(distance - 4) < 1e-4, "%v: the top of the cube at %v", way, distance)
		testing.expectf(t, linalg.length(normal - {0, 1, 0}) < 1e-4, "%v: its normal %v", way, normal)
		_, _, normal, hit = mesh_ray(r, mesh, placed, {3.2, -5, 0.3}, {0, 1, 0})
		testing.expectf(t, hit && linalg.length(normal - {0, -1, 0}) < 1e-4, "%v: the normal faces the ray from below", way)
		_, _, _, hit = mesh_ray(r, mesh, placed, {0, 5, 0}, {0, -1, 0})
		testing.expect(t, !hit)
		_, _, _, hit = mesh_ray(r, mesh, placed, {3.2, 5, 0.3}, {0, -1, 0}, 3)
		testing.expect(t, !hit, "a limit before the mesh")
		if way == .Prepared {
			testing.expect(t, mesh_remove(r, mesh))
			testing.expect(t, r.ui_offscreen.trees[0].rays.count == 0, "the tree goes with its mesh")
		}
	}
}
