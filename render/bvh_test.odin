package mirai_render

import "core:math/linalg"
import "core:testing"
import mm "mirai:std/math"

// The software trees meet what a walk over every triangle meets, and the
// first triangle of each of a set of rays is the one the trees of the
// builder render had before std/spatial built them met.
@(test)
bvh_matches_brute_force :: proc(t: ^testing.T) {
	// The first triangle the rays below met, by the trees of the old builder.
	RECORDED :: [64]int{
		356, 69, 92, 277, 331, 390, 338, 116, 389, 141, 328, 97, 346, 345, 154, 271,
		138, 128, 208, 27, 351, 79, 143, 71, 337, 382, 177, 240, 5, 143, 388, 308,
		304, 312, 353, 393, 138, 64, 77, 111, 195, 128, 231, 374, 243, 132, 377, 159,
		232, 95, 181, 36, 383, 261, 127, 391, 30, 268, 26, 315, 70, 326, 342, 393,
	}
	state := u32(0x2545f491)
	random :: proc(state: ^u32, lo, hi: f32) -> f32 {
		state^ ~= state^ << 13; state^ ~= state^ >> 17; state^ ~= state^ << 5
		return lo + (hi - lo) * f32(state^ >> 8) / f32(1 << 24)
	}
	COUNT :: 400
	tris := make([][3]Vec3, COUNT)
	defer delete(tris)
	boxes := make([]mm.Aabb, COUNT)
	defer delete(boxes)
	for i in 0 ..< COUNT {
		c := Vec3{random(&state, -10, 10), random(&state, -10, 10), random(&state, -10, 10)}
		for k in 0 ..< 3 {tris[i][k] = c + Vec3{random(&state, -1, 1), random(&state, -1, 1), random(&state, -1, 1)}}
		a, b, cc := tris[i][0], tris[i][1], tris[i][2]
		boxes[i] = {linalg.min(linalg.min(a, b), cc), linalg.max(linalg.max(a, b), cc)}
	}
	nodes: [dynamic]Gpu_Bvh_Node
	order: [dynamic]u32
	defer delete(nodes)
	defer delete(order)
	testing.expect(t, bvh_build(boxes, 4, &nodes, &order))
	triangles := make([]Gpu_Bvh_Triangle, COUNT)
	defer delete(triangles)
	for primitive, i in order {
		a, b, c := tris[primitive][0], tris[primitive][1], tris[primitive][2]
		triangles[i] = {v0 = a, primitive = primitive, v1 = {b.x, b.y, b.z, 0}, v2 = {c.x, c.y, c.z, 0}}
	}
	// Depth bound required by the GPU traversal stack.
	max_depth := 0
	Entry :: struct {node, depth: int}
	stack := make([dynamic]Entry, 0, 64)
	append(&stack, Entry{0, 0})
	defer delete(stack)
	for len(stack) > 0 {
		e := pop(&stack)
		max_depth = max(max_depth, e.depth)
		n := nodes[e.node]
		if n.count == 0 {append(&stack, Entry{int(n.left_first), e.depth + 1}, Entry{int(n.left_first) + 1, e.depth + 1})}
	}
	testing.expect(t, max_depth <= BVH_MAX_DEPTH)
	brute :: proc(tris: [][3]Vec3, origin, dir: Vec3) -> (best: f32, best_p: int) {
		best, best_p = 1e9, -1
		for tri, i in tris {
			one := []Gpu_Bvh_Triangle{{v0 = tri[0], primitive = u32(i), v1 = {tri[1].x, tri[1].y, tri[1].z, 0}, v2 = {tri[2].x, tri[2].y, tri[2].z, 0}}}
			leaf := []Gpu_Bvh_Node{{bounds_min = {-1e9, -1e9, -1e9}, bounds_max = {1e9, 1e9, 1e9}, count = 1}}
			ht, hp := bvh_ray_triangles(leaf, one, origin, dir, best)
			if hp >= 0 {best, best_p = ht, hp}
		}
		return
	}
	recorded := RECORDED
	mismatches, changed := 0, 0
	for ray in 0 ..< 2000 {
		origin := Vec3{random(&state, -15, 15), random(&state, -15, 15), random(&state, -15, 15)}
		toward := int(random(&state, 0, COUNT))
		dir := linalg.normalize((tris[toward][0] + tris[toward][1] + tris[toward][2]) / 3 - origin)
		bt, bp := bvh_ray_triangles(nodes[:], triangles, origin, dir, 1e9)
		if ray < len(recorded) && bp != recorded[ray] {changed += 1}
		best, best_p := brute(tris, origin, dir)
		if bp != best_p || (bp >= 0 && abs(bt - best) > 1e-3) {mismatches += 1}
	}
	testing.expect_value(t, changed, 0)
	testing.expect_value(t, mismatches, 0)
}

// A box an instance that cannot be drawn gives (not finite, or min above
// max) is built as a point, and the others as they are.
@(test)
bvh_takes_boxes_that_are_not_finite_as_points :: proc(t: ^testing.T) {
	zero: f32
	boxes := [4]mm.Aabb{{{0, 0, 0}, {1, 1, 1}}, {{2, 0, 0}, {1, 1, 1}}, {{zero / zero, 0, 0}, {1, 1, 1}}, {{4, 4, 4}, {5, 5, 5}}}
	nodes: [dynamic]Gpu_Bvh_Node
	order: [dynamic]u32
	defer delete(nodes)
	defer delete(order)
	testing.expect(t, bvh_build(boxes[:], 1, &nodes, &order))
	testing.expect_value(t, len(order), 4)
	testing.expect(t, nodes[0].bounds_min == {0, 0, 0} && nodes[0].bounds_max == {5, 5, 5})
	testing.expect(t, !bvh_build(nil, 1, &nodes, &order) && len(nodes) == 0 && len(order) == 0)
}
