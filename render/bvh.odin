package mirai_render

// Binned SAH bounding volume hierarchy builder used for both levels of the
// software ray tracer: per-mesh BLAS over triangles and the scene TLAS over
// instance bounds. The layout matches the GPU walker in trace.slang:
//   - nodes are stored depth-first with both children adjacent (left, left+1);
//   - inner nodes have count == 0 and left_first = left child index relative
//     to the root of this tree; leaves have left_first = first item in `order`.
// Depth is bounded so the shader's fixed traversal stack can never overflow.

BVH_MAX_DEPTH :: 28
BVH_BINS      :: 12

Bvh_Item :: struct {
	bounds_min: Vec3,
	bounds_max: Vec3,
	center:     Vec3,
}

@(private = "file")
Bin :: struct {
	bounds_min, bounds_max: Vec3,
	count:                  int,
}

@(private = "file")
Task :: struct {
	node, start, count, depth: int,
}

aabb_area :: proc "contextless" (bmin, bmax: Vec3) -> f32 {
	e := bmax - bmin
	if e.x < 0 || e.y < 0 || e.z < 0 {return 0}
	return 2 * (e.x * e.y + e.y * e.z + e.z * e.x)
}

@(private)
EMPTY_BOUNDS_MIN :: Vec3{1e30, 1e30, 1e30}
@(private)
EMPTY_BOUNDS_MAX :: Vec3{-1e30, -1e30, -1e30}

// Builds into nodes/order (cleared first). Returns false when there are no
// items or no memory for them, with both empty. Allocations happen in the
// caller's arrays (load transactions).
bvh_build :: proc(items: []Bvh_Item, max_leaf: int, nodes: ^[dynamic]Gpu_Bvh_Node, order: ^[dynamic]u32) -> bool {
	clear(nodes)
	clear(order)
	if len(items) == 0 {return false}
	if resize(order, len(items)) != nil || reserve(nodes, 2 * len(items)) != nil {
		clear(order)
		return false
	}
	for i in 0 ..< len(items) {order[i] = u32(i)}
	append(nodes, Gpu_Bvh_Node{})
	stack := make([dynamic]Task, 0, 64, context.temp_allocator)
	append(&stack, Task{node = 0, start = 0, count = len(items), depth = 0})
	for len(stack) > 0 {
		task := pop(&stack)
		bmin, bmax := EMPTY_BOUNDS_MIN, EMPTY_BOUNDS_MAX
		cmin, cmax := EMPTY_BOUNDS_MIN, EMPTY_BOUNDS_MAX
		for i in task.start ..< task.start + task.count {
			item := &items[order[i]]
			bmin = {min(bmin.x, item.bounds_min.x), min(bmin.y, item.bounds_min.y), min(bmin.z, item.bounds_min.z)}
			bmax = {max(bmax.x, item.bounds_max.x), max(bmax.y, item.bounds_max.y), max(bmax.z, item.bounds_max.z)}
			cmin = {min(cmin.x, item.center.x), min(cmin.y, item.center.y), min(cmin.z, item.center.z)}
			cmax = {max(cmax.x, item.center.x), max(cmax.y, item.center.y), max(cmax.z, item.center.z)}
		}
		node := &nodes[task.node]
		node.bounds_min = bmin
		node.bounds_max = bmax
		make_leaf := task.count <= max_leaf || task.depth >= BVH_MAX_DEPTH
		split := -1
		if !make_leaf {
			leaf_cheaper: bool
			split, leaf_cheaper = find_split(items, order[task.start:task.start + task.count], cmin, cmax, bmin, bmax, max_leaf)
			if leaf_cheaper {
				make_leaf = true
			} else if split <= 0 || split >= task.count {
				// Degenerate centroids: split by count so depth keeps shrinking.
				split = task.count / 2
			}
		}
		if make_leaf {
			node.left_first = u32(task.start)
			node.count = u32(task.count)
			continue
		}
		left := len(nodes)
		append(nodes, Gpu_Bvh_Node{}, Gpu_Bvh_Node{})
		node = &nodes[task.node]
		node.left_first = u32(left)
		node.count = 0
		append(&stack, Task{node = left + 1, start = task.start + split, count = task.count - split, depth = task.depth + 1})
		append(&stack, Task{node = left, start = task.start, count = split, depth = task.depth + 1})
	}
	return true
}

// Partitions `order` in place by the best binned SAH plane and returns the
// size of the left part. leaf_cheaper reports that no split beats a leaf;
// split = -1 without it means the centroids are degenerate.
@(private = "file")
find_split :: proc(items: []Bvh_Item, order: []u32, cmin, cmax, bmin, bmax: Vec3, max_leaf: int) -> (split: int, leaf_cheaper: bool) {
	best_cost := f32(1e30)
	best_axis := -1
	best_bin := 0
	extent := cmax - cmin
	for axis in 0 ..< 3 {
		if extent[axis] <= 1e-9 {continue}
		bins: [BVH_BINS]Bin
		for &b in bins {b.bounds_min, b.bounds_max = EMPTY_BOUNDS_MIN, EMPTY_BOUNDS_MAX}
		scale := f32(BVH_BINS) / extent[axis]
		for index in order {
			item := &items[index]
			b := min(int((item.center[axis] - cmin[axis]) * scale), BVH_BINS - 1)
			bin := &bins[b]
			bin.count += 1
			bin.bounds_min = {min(bin.bounds_min.x, item.bounds_min.x), min(bin.bounds_min.y, item.bounds_min.y), min(bin.bounds_min.z, item.bounds_min.z)}
			bin.bounds_max = {max(bin.bounds_max.x, item.bounds_max.x), max(bin.bounds_max.y, item.bounds_max.y), max(bin.bounds_max.z, item.bounds_max.z)}
		}
		// Sweep from the right to get suffix areas, then from the left.
		right_area: [BVH_BINS]f32
		right_count: [BVH_BINS]int
		rmin, rmax := EMPTY_BOUNDS_MIN, EMPTY_BOUNDS_MAX
		count := 0
		for i := BVH_BINS - 1; i > 0; i -= 1 {
			b := &bins[i]
			count += b.count
			if b.count > 0 {
				rmin = {min(rmin.x, b.bounds_min.x), min(rmin.y, b.bounds_min.y), min(rmin.z, b.bounds_min.z)}
				rmax = {max(rmax.x, b.bounds_max.x), max(rmax.y, b.bounds_max.y), max(rmax.z, b.bounds_max.z)}
			}
			right_area[i] = aabb_area(rmin, rmax)
			right_count[i] = count
		}
		lmin, lmax := EMPTY_BOUNDS_MIN, EMPTY_BOUNDS_MAX
		count = 0
		for i in 0 ..< BVH_BINS - 1 {
			b := &bins[i]
			count += b.count
			if b.count > 0 {
				lmin = {min(lmin.x, b.bounds_min.x), min(lmin.y, b.bounds_min.y), min(lmin.z, b.bounds_min.z)}
				lmax = {max(lmax.x, b.bounds_max.x), max(lmax.y, b.bounds_max.y), max(lmax.z, b.bounds_max.z)}
			}
			if count == 0 || right_count[i + 1] == 0 {continue}
			cost := aabb_area(lmin, lmax) * f32(count) + right_area[i + 1] * f32(right_count[i + 1])
			if cost < best_cost {
				best_cost = cost
				best_axis = axis
				best_bin = i
			}
		}
	}
	if best_axis < 0 {return -1, false}
	parent_area := max(aabb_area(bmin, bmax), 1e-12)
	// Traversal cost 1, intersection cost 1, normalized by the parent area.
	split_cost := 1 + best_cost / parent_area
	if f32(len(order)) <= split_cost && len(order) <= max_leaf * 4 {return -1, true}
	scale := f32(BVH_BINS) / extent[best_axis]
	left := 0
	for i in 0 ..< len(order) {
		item := &items[order[i]]
		b := min(int((item.center[best_axis] - cmin[best_axis]) * scale), BVH_BINS - 1)
		if b <= best_bin {
			order[i], order[left] = order[left], order[i]
			left += 1
		}
	}
	return left, false
}

// Moller-Trumbore ray/triangle intersection for the CPU BVH reference query.
// Returns the ray distance, or -1 when the ray misses.
ray_triangle :: proc(origin, dir, v0, e1, e2: Vec3) -> f32 {
	t, _, _ := ray_triangle_barycentric(origin, dir, v0, e1, e2)
	return t
}

// The same, with the weights of the second and the third vertex where it meets the triangle.
ray_triangle_barycentric :: proc(origin, dir, v0, e1, e2: Vec3) -> (t, u, v: f32) {
	p := Vec3{dir.y * e2.z - dir.z * e2.y, dir.z * e2.x - dir.x * e2.z, dir.x * e2.y - dir.y * e2.x}
	det := e1.x * p.x + e1.y * p.y + e1.z * p.z
	if abs(det) < 1e-12 {return -1, 0, 0}
	inv_det := 1 / det
	s := origin - v0
	u = (s.x * p.x + s.y * p.y + s.z * p.z) * inv_det
	if u < 0 || u > 1 {return -1, 0, 0}
	q := Vec3{s.y * e1.z - s.z * e1.y, s.z * e1.x - s.x * e1.z, s.x * e1.y - s.y * e1.x}
	v = (dir.x * q.x + dir.y * q.y + dir.z * q.z) * inv_det
	if v < 0 || u + v > 1 {return -1, 0, 0}
	return (e2.x * q.x + e2.y * q.y + e2.z * q.z) * inv_det, u, v
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
			hit := ray_triangle(origin, dir, tri.v0, tri.e1.xyz, tri.e2.xyz)
			if hit > 0 && hit < t {
				t = hit
				primitive = int(tri.primitive)
			}
		}
	}
	if primitive < 0 {t = -1}
	return
}
