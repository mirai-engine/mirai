package mirai_render

import "base:runtime"
import mm "mirai:std/math"
import "mirai:std/spatial"

// The trees of the software ray tracer, at both levels: the BLAS of each cut
// of a mesh over its triangles, the TLAS over the boxes of the instances and
// the tree of each batch. spatial.bvh_build makes them and they are uploaded
// as it lays them out (Gpu_Bvh_Node is its Bvh_Node): an inner node has its
// children at left_first and left_first + 1 from the root of its tree, a leaf
// its first item in the order, and nodes[1] is a slot no node points at.
// Depth is bounded so the fixed traversal stack of trace.slang cannot overflow.

BVH_MAX_DEPTH :: 28

#assert(size_of(Gpu_Bvh_Node) == size_of(spatial.Bvh_Node) && offset_of(Gpu_Bvh_Node, left_first) == offset_of(spatial.Bvh_Node, first) && offset_of(Gpu_Bvh_Node, bounds_max) == offset_of(spatial.Bvh_Node, max) && offset_of(Gpu_Bvh_Node, count) == offset_of(spatial.Bvh_Node, count))

// The slot of a tree no node points at, which a walk over all its nodes skips.
BVH_UNUSED_NODE :: 1

// Builds into nodes/order (cleared first) the tree of boxes, leaves of up to
// max_leaf. A box that is not finite or has min above max (an instance that
// cannot be drawn) counts as the point at the origin. Returns false when
// there are no boxes or no memory for them, with both empty. Allocations
// happen in the caller's arrays (load transactions).
bvh_build :: proc(boxes: []mm.Aabb, max_leaf: int, nodes: ^[dynamic]Gpu_Bvh_Node, order: ^[dynamic]u32) -> bool {
	clear(nodes)
	clear(order)
	if len(boxes) == 0 {return false}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	given := boxes
	for box, i in boxes {
		if spatial.aabb_valid(box) {continue}
		copied, error := make([]mm.Aabb, len(boxes), context.temp_allocator)
		if error != nil {return false}
		copy(copied, boxes)
		for &each in copied[i:] {if !spatial.aabb_valid(each) {each = {}}}
		given = copied
		break
	}
	tree: spatial.Bvh
	if !spatial.bvh_build(&tree, given, {max_leaf_size = max_leaf, max_depth = BVH_MAX_DEPTH, allocator = context.temp_allocator}) {return false}
	if resize(nodes, len(tree.nodes)) != nil || resize(order, len(tree.order)) != nil {
		clear(nodes)
		clear(order)
		return false
	}
	copy(nodes[:], transmute([]Gpu_Bvh_Node)tree.nodes)
	copy(order[:], tree.order)
	return true
}

// Reference closest-hit query against a built BLAS, used by tests to check
// the GPU walker and by tools that need CPU ray casts.
bvh_ray_triangles :: proc(nodes: []Gpu_Bvh_Node, triangles: []Gpu_Bvh_Triangle, origin, dir: Vec3, t_max: f32) -> (t: f32, primitive: int) {
	t = t_max
	primitive = -1
	if len(nodes) == 0 {return -1, -1}
	inv := Vec3{1 / (dir.x if abs(dir.x) > 1e-12 else 1e-12), 1 / (dir.y if abs(dir.y) > 1e-12 else 1e-12), 1 / (dir.z if abs(dir.z) > 1e-12 else 1e-12)}
	stack: [64]int
	top := 1
	for top > 0 {
		top -= 1
		node := nodes[stack[top]]
		t0 := (node.bounds_min - origin) * inv
		t1 := (node.bounds_max - origin) * inv
		enter := max(max(min(t0.x, t1.x), min(t0.y, t1.y)), max(min(t0.z, t1.z), 0))
		exit := min(min(max(t0.x, t1.x), max(t0.y, t1.y)), min(max(t0.z, t1.z), t))
		if enter > exit {continue}
		if node.count == 0 {
			stack[top] = int(node.left_first)
			stack[top + 1] = int(node.left_first) + 1
			top += 2
			continue
		}
		for i in node.left_first ..< node.left_first + node.count {
			tri := triangles[i]
			if hit, _, crossed := mm.ray_triangle({origin, dir}, {tri.v0, tri.v1.xyz, tri.v2.xyz}); crossed && hit > 0 && hit < t {
				t = hit
				primitive = int(tri.primitive)
			}
		}
	}
	if primitive < 0 {t = -1}
	return
}
