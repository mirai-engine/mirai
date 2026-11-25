package mirai_render

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:render/abi"

// The local lights as a binary tree, for a point to add up the far ones by
// groups and the near ones one by one (lighting.slang). The tree splits the
// lights that light one side (spots and rectangles) from those that light
// every way, then each kind by how far they reach (light_reach_class), and
// each of those runs where the two halves cost least by the surface area and
// orientation heuristic of pbrt-v4 (light_bounds_cost): lights close
// together, alike in power and facing alike, share a group. A node keeps
// what its lights give together, as one light of their size would, and the
// cone of the directions they face with how far beyond it they shine (the
// orientation bounds of Conty Estevez and Kulla 2018): a group of spots that
// face down lights nothing above them. Nodes are in depth-first order: the
// first child of a node follows it and the second comes after the nodes
// under the first, so every child comes after its group, which the walks of
// lighting.slang hold a node to.
Gpu_Light_Node :: struct {
	center_radius: Vec4, // xyz the center of its lights, weighed by how bright each is; w the radius of the sphere around it that holds them
	power_reach:   Vec4, // rgb the sum of their colors times their intensities; w how far from the center the farthest of them reaches
	cone:          Vec4, // xyz the axis of the directions they face; w the half-angle around it that holds the directions they shine whole, radians; PI: any
	// In steps of LIGHT_WIDTH_STEP: [0] the half-angle past the cone over which
	// their light fades out, the widest of theirs: a spot the edge of its own
	// cone past where it shines whole (light_spot_inner), a rectangle a quarter
	// turn; [1] the half-angle around its own axis each of them shines whole, the
	// narrowest of theirs: PI for a light that does every way.
	widths:        [2]u16,
	range_low:     f32,  // the shortest of their ranges
	range_high:    f32,  // the longest of their ranges
	spread:        f32,  // root of the mean square of how far their light lies from the center, their sizes included
	child:         u32,  // a leaf: its light; a group: its second child
	flags:         u32,  // GPU_LIGHT_NODE_*, and the number of its lights from GPU_LIGHT_NODE_COUNT_SHIFT
	indirect:      f32,  // what of their light the probes gather, the mean of their shares weighed by how bright each is; 0 only if none of it
	scattering:    f32,  // what of their light media scatter, the same way
}
GPU_LIGHT_NODE_LEAF :: abi.GPU_LIGHT_NODE_LEAF
GPU_LIGHT_NODE_COUNT_SHIFT :: abi.GPU_LIGHT_NODE_COUNT_SHIFT

// Below this depth the runs are split where they cost least; deeper, in
// halves. A traversal never holds more than LIGHT_TREE_DEPTH nodes.
LIGHT_TREE_SPLIT_DEPTH :: 32
LIGHT_TREE_DEPTH :: abi.LIGHT_TREE_DEPTH
LIGHTS_MAX :: 1 << (LIGHT_TREE_DEPTH - LIGHT_TREE_SPLIT_DEPTH)

// The most lights or groups a point lights through their shadow rays (light_cut of lighting.slang).
LIGHT_CUT_MAX :: abi.LIGHT_CUT_MAX

Light_Key :: struct {
	part:       u32, // light_part
	light:      u32,
	shadowless: bool, // it goes to the tree of the lights that cast no shadows
}

LIGHT_TREE_NONE :: max(u32) // the leaf of a light the tree does not hold

// A change of the lights that keeps their number and the kind of each one
// refits the tree instead of building it again, while what the tree costs
// stays within this factor of what it cost when it was built.
LIGHT_TREE_REFIT_SLACK :: 1.5

// The memory a tree of that many lights takes at most, two trees and a group
// of none among them: with it light_tree_build does not fail. False without
// memory.
light_tree_reserve :: proc(nodes: ^[dynamic]Gpu_Light_Node, keys: ^[dynamic]Light_Key, leaves: ^[dynamic]u32, lights: int) -> bool {
	placed := min(lights, LIGHTS_MAX)
	return reserve(leaves, lights) == nil && reserve(keys, placed) == nil && reserve(nodes, 2 * placed) == nil
}

// Builds the tree into nodes, with the leaf of each light in leaves, and
// returns what it costs (light_tree_cost). The lights of shadowless that are
// true go to a tree of their own after that of the others
// (light_tree_shadowless), which no traversal from node 0 meets; while all of
// them cast none, the tree of those that do is LIGHT_NODE_NONE. False without
// memory for it: the three stay as they were.
light_tree_build :: proc(nodes: ^[dynamic]Gpu_Light_Node, keys: ^[dynamic]Light_Key, leaves: ^[dynamic]u32, lights: []Gpu_Light, shadowless: []bool = nil) -> (cost: f64, ok: bool) {
	if !light_tree_reserve(nodes, keys, leaves, len(lights)) {return 0, false}
	clear(nodes)
	clear(keys)
	// Reserved: it asks for no memory.
	if resize(leaves, len(lights)) != nil {return 0, false}
	for &leaf in leaves {leaf = LIGHT_TREE_NONE}
	for l, i in lights {
		if light_placed(l) && len(keys) < LIGHTS_MAX {append(keys, Light_Key{light_part(l), u32(i), i < len(shadowless) && shadowless[i]})}
	}
	if len(keys) > 0 {
		slice.sort_by(keys[:], proc(a, b: Light_Key) -> bool {
			if a.shadowless != b.shadowless {return b.shadowless}
			return a.part < b.part || (a.part == b.part && a.light < b.light)
		})
		shadowed := 0
		for shadowed < len(keys) && !keys[shadowed].shadowless {shadowed += 1}
		// Reserved too: they find the room of their nodes.
		if shadowed > 0 {
			if _, built := light_tree_node(nodes, keys[:shadowed], leaves[:], lights, 0); !built {return 0, false}
		} else if _, err := append(nodes, LIGHT_NODE_NONE); err != nil {return 0, false}
		if shadowed < len(keys) {
			if _, built := light_tree_node(nodes, keys[shadowed:], leaves[:], lights, 0); !built {return 0, false}
		}
	}
	return light_tree_cost(nodes[:]), true
}

// A group of no lights, far below anything: it reaches nothing and opens to
// nothing.
LIGHT_NODE_NONE :: Gpu_Light_Node{center_radius = {0, -1e6, 0, 0}, cone = {0, 1, 0, math.PI}, widths = LIGHT_WIDTHS_ANY}

// Radians of a step of Gpu_Light_Node.widths, and an angle in them.
LIGHT_WIDTH_STEP :: math.PI / 65535
light_width :: proc "contextless" (radians: f32) -> u16 {return u16(clamp(radians / math.PI, 0, 1) * 65535 + 0.5)}

// The widths of a light that shines whole every way: a quarter turn, PI.
LIGHT_WIDTHS_ANY :: [2]u16{32768, 65535}

// Whether a node holds lights: LIGHT_NODE_NONE does not.
light_node_holds :: proc "contextless" (n: Gpu_Light_Node) -> bool {
	return n.flags & GPU_LIGHT_NODE_LEAF != 0 || n.flags >> GPU_LIGHT_NODE_COUNT_SHIFT != 0
}

// The root of the tree of the lights that cast no shadows, which follows the
// last node under the root of those that do; 0: none.
light_tree_shadowless :: proc "contextless" (nodes: []Gpu_Light_Node) -> u32 {
	if len(nodes) == 0 {return 0}
	at := u32(0)
	for nodes[at].flags & GPU_LIGHT_NODE_LEAF == 0 && nodes[at].child > at && int(nodes[at].child) < len(nodes) {at = nodes[at].child}
	return at + 1 if int(at) + 1 < len(nodes) else 0
}

@(private = "file")
light_tree_node :: proc(nodes: ^[dynamic]Gpu_Light_Node, keys: []Light_Key, leaves: []u32, lights: []Gpu_Light, depth: int) -> (at: u32, ok: bool) {
	at = u32(len(nodes))
	if len(keys) == 1 {
		light := keys[0].light
		leaves[light] = at
		_, err := append(nodes, light_tree_leaf(lights[light], light))
		return at, err == nil
	}
	split := light_tree_split(keys, lights, depth)
	if _, err := append(nodes, Gpu_Light_Node{}); err != nil {return at, false}
	light_tree_node(nodes, keys[:split], leaves, lights, depth + 1) or_return
	second := light_tree_node(nodes, keys[split:], leaves, lights, depth + 1) or_return
	nodes[at] = light_tree_group(nodes[at + 1], nodes[second], second)
	return at, true
}

// Where the run of keys splits into the two children of its group: between
// two parts, at the highest bit in which its ends differ; within one part,
// where the two halves cost least (light_bounds_cost), over
// LIGHT_TREE_BUCKETS buckets along each axis by the centers of the lights,
// the keys of the first half moved before those of the second; in halves
// where no split costs anything or past LIGHT_TREE_SPLIT_DEPTH. The surface
// area and orientation heuristic of pbrt-v4 (Pharr, Jakob and Humphreys,
// Physically Based Rendering 4th ed., the light BVH).
LIGHT_TREE_BUCKETS :: 12
@(private = "file")
light_tree_split :: proc(keys: []Light_Key, lights: []Gpu_Light, depth: int) -> int {
	half := len(keys) / 2
	if depth >= LIGHT_TREE_SPLIT_DEPTH {return half}
	first, last := keys[0].part, keys[len(keys) - 1].part
	if first != last {
		// The keys of the run share every bit above the highest one in which
		// its ends differ: the second child starts at the first key with it.
		bit := u32(1) << (31 - intrinsics.count_leading_zeros(first ~ last))
		low, high := 0, len(keys) - 1
		for high - low > 1 {
			middle := (low + high) / 2
			if keys[middle].part & bit != 0 {high = middle} else {low = middle}
		}
		return high
	}
	bounds, centers: Light_Bounds
	for k in keys {
		b := light_bounds_of(lights[k.light])
		bounds = light_bounds_union(bounds, b)
		c := 0.5 * (b.low + b.high)
		centers = light_bounds_union(centers, {low = c, high = c, count = 1})
	}
	diagonal := bounds.high - bounds.low
	bucket_of :: proc(l: Gpu_Light, centers: Light_Bounds, dim: int) -> int {
		b := light_bounds_of(l)
		at := (0.5 * (b.low[dim] + b.high[dim]) - centers.low[dim]) / (centers.high[dim] - centers.low[dim])
		return clamp(int(at * LIGHT_TREE_BUCKETS), 0, LIGHT_TREE_BUCKETS - 1)
	}
	best, best_dim, best_bucket := f32(math.F32_MAX), -1, -1
	for dim in 0 ..< 3 {
		if !(centers.high[dim] > centers.low[dim]) {continue}
		buckets: [LIGHT_TREE_BUCKETS]Light_Bounds
		for k in keys {
			b := bucket_of(lights[k.light], centers, dim)
			buckets[b] = light_bounds_union(buckets[b], light_bounds_of(lights[k.light]))
		}
		above: [LIGHT_TREE_BUCKETS]Light_Bounds
		above[LIGHT_TREE_BUCKETS - 1] = buckets[LIGHT_TREE_BUCKETS - 1]
		for i := LIGHT_TREE_BUCKETS - 2; i > 0; i -= 1 {above[i] = light_bounds_union(above[i + 1], buckets[i])}
		below: Light_Bounds
		for i in 0 ..< LIGHT_TREE_BUCKETS - 1 {
			below = light_bounds_union(below, buckets[i])
			cost := light_bounds_cost(below, diagonal, dim) + light_bounds_cost(above[i + 1], diagonal, dim)
			if cost > 0 && cost < best {best, best_dim, best_bucket = cost, dim, i}
		}
	}
	if best_dim < 0 {return half}
	split := 0
	for k, i in keys {
		if bucket_of(lights[k.light], centers, best_dim) <= best_bucket {
			keys[split], keys[i] = keys[i], keys[split]
			split += 1
		}
	}
	return split if split > 0 && split < len(keys) else half
}

// What a run of lights spans, as the splits of the build weigh it: the box
// of their spheres, the sum of their powers (the luminance of their colors
// times their intensities) and the cone of the directions they shine whole,
// with how far past it their light fades out, as Gpu_Light_Node keeps them.
Light_Bounds :: struct {
	low, high: Vec3,
	power:     f32,
	cone:      Vec4,
	falloff:   f32,
	count:     int, // of its lights; 0: it holds none
}

// No light is a box thinner than this, metres: a split weighs its area.
LIGHT_BOUNDS_EXTENT_MIN :: 0.01

light_bounds_of :: proc(l: Gpu_Light) -> Light_Bounds {
	extent, _ := light_shape(l)
	extent = max(extent, LIGHT_BOUNDS_EXTENT_MIN)
	center := l.position_range.xyz
	cone, widths := light_orientation(l)
	return {low = center - extent, high = center + extent, power = luminance_of(l.color_intensity.xyz) * l.color_intensity.w, cone = cone, falloff = f32(widths[0]) * LIGHT_WIDTH_STEP, count = 1}
}

light_bounds_union :: proc(a, b: Light_Bounds) -> Light_Bounds {
	if a.count == 0 {return b}
	if b.count == 0 {return a}
	return {low = linalg.min(a.low, b.low), high = linalg.max(a.high, b.high), power = a.power + b.power, cone = light_cone_union(a.cone, b.cone), falloff = max(a.falloff, b.falloff), count = a.count + b.count}
}

// The solid angle the light of a cone of directions shines through, of half-angle
// theta_o, with a cosine fall-off over theta_e past it (pbrt-v4's M_Omega).
light_orientation_measure :: proc "contextless" (theta_o, theta_e: f32) -> f32 {
	theta_w := min(theta_o + theta_e, math.PI)
	sine, cosine := math.sin(theta_o), math.cos(theta_o)
	return 2 * math.PI * (1 - cosine) + math.PI / 2 * (2 * theta_w * sine - math.cos(theta_o - 2 * theta_w) - 2 * theta_o * sine + cosine)
}

// What lights cost the points that walk them in a group split along dim of a
// run of that diagonal: their power, times the solid angle their light
// shines through, times the area of their box, more for a split across the
// shorter sides of the run.
light_bounds_cost :: proc(b: Light_Bounds, diagonal: Vec3, dim: int) -> f32 {
	if b.count == 0 {return 0}
	d := b.high - b.low
	area := 2 * (d.x * d.y + d.y * d.z + d.z * d.x)
	return b.power * light_orientation_measure(b.cone.w, b.falloff) * (max(diagonal.x, diagonal.y, diagonal.z) / diagonal[dim]) * area
}

// The cone of directions a light shines whole and the widths of
// Gpu_Light_Node: a point or a capsule shines every way; a spot around its
// axis out to the share of its half-angle it shines whole within
// (light_spot_inner), fading out to its edge; a rectangle on its side, as a
// cosine.
light_orientation :: proc(l: Gpu_Light) -> (cone: Vec4, widths: [2]u16) {
	if light_spot(l) {
		outer := math.acos(clamp(l.direction_cone.w, -1, 1))
		inner := light_spot_inner(l)
		return {l.direction_cone.x, l.direction_cone.y, l.direction_cone.z, outer * inner}, {light_width(outer * (1 - inner)), light_width(outer * inner)}
	}
	if light_rect(l) {return {l.direction_cone.x, l.direction_cone.y, l.direction_cone.z, 0}, {LIGHT_WIDTHS_ANY[0], 0}}
	return {0, 1, 0, math.PI}, LIGHT_WIDTHS_ANY
}

@(private = "file")
light_tree_leaf :: proc(l: Gpu_Light, light: u32) -> Gpu_Light_Node {
	extent, spread := light_shape(l)
	shares := light_shares_of(l)
	cone, widths := light_orientation(l)
	return {
		center_radius = {l.position_range.x, l.position_range.y, l.position_range.z, extent},
		power_reach = {l.color_intensity.x * l.color_intensity.w, l.color_intensity.y * l.color_intensity.w, l.color_intensity.z * l.color_intensity.w, l.position_range.w},
		cone = cone,
		widths = widths,
		range_low = l.position_range.w,
		range_high = l.position_range.w,
		spread = spread,
		child = light,
		flags = GPU_LIGHT_NODE_LEAF | 1 << GPU_LIGHT_NODE_COUNT_SHIFT,
		indirect = shares.x,
		scattering = shares.y,
	}
}

// What two nodes give together; second is where the second of them is.
@(private = "file")
light_tree_group :: proc(a, b: Gpu_Light_Node, second: u32) -> Gpu_Light_Node {
	wa, wb := light_tree_weight(a), light_tree_weight(b)
	share := wa / (wa + wb) if wa + wb > 0 else 0.5
	center := linalg.lerp(b.center_radius.xyz, a.center_radius.xyz, share)
	da, db := linalg.length(a.center_radius.xyz - center), linalg.length(b.center_radius.xyz - center)
	return {
		center_radius = {center.x, center.y, center.z, max(da + a.center_radius.w, db + b.center_radius.w)},
		power_reach = {a.power_reach.x + b.power_reach.x, a.power_reach.y + b.power_reach.y, a.power_reach.z + b.power_reach.z, max(da + a.power_reach.w, db + b.power_reach.w)},
		cone = light_cone_union(a.cone, b.cone),
		widths = {max(a.widths[0], b.widths[0]), min(a.widths[1], b.widths[1])},
		range_low = min(a.range_low, b.range_low),
		range_high = max(a.range_high, b.range_high),
		spread = math.sqrt(share * (da * da + a.spread * a.spread) + (1 - share) * (db * db + b.spread * b.spread)),
		child = second,
		flags = (a.flags >> GPU_LIGHT_NODE_COUNT_SHIFT + b.flags >> GPU_LIGHT_NODE_COUNT_SHIFT) << GPU_LIGHT_NODE_COUNT_SHIFT,
		indirect = share * a.indirect + (1 - share) * b.indirect,
		scattering = share * a.scattering + (1 - share) * b.scattering,
	}
}

// The narrowest cone around one axis that holds two cones of directions
// (PBRT's DirectionCone union): xyz the axis, w the half-angle, PI for any.
light_cone_union :: proc "contextless" (a, b: Vec4) -> Vec4 {
	ANY :: Vec4{0, 1, 0, math.PI}
	if a.w >= math.PI || b.w >= math.PI {return ANY}
	between := math.acos(clamp(linalg.dot(a.xyz, b.xyz), -1, 1))
	if min(between + b.w, math.PI) <= a.w {return a}
	if min(between + a.w, math.PI) <= b.w {return b}
	half := (a.w + between + b.w) / 2
	if half >= math.PI {return ANY}
	// The axis turns from that of a towards that of b, in the plane of both.
	across := linalg.cross(a.xyz, b.xyz)
	if linalg.dot(across, across) < 1e-12 {return ANY}
	turned := linalg.quaternion_angle_axis_f32(half - a.w, linalg.normalize(across))
	axis := linalg.quaternion_mul_vector3(turned, a.xyz)
	return {axis.x, axis.y, axis.z, half}
}

@(private = "file")
light_tree_weight :: proc(n: Gpu_Light_Node) -> f32 {
	return 0.2126 * n.power_reach.x + 0.7152 * n.power_reach.y + 0.0722 * n.power_reach.z
}

// Gives the leaf of one light what the light is now and every group above it
// what its children give, keeping the shape of the tree, and adds the nodes it
// changed to dirty. Returns how much it changed what the tree costs.
light_tree_refit :: proc(nodes: []Gpu_Light_Node, lights: []Gpu_Light, leaf: u32, dirty: ^[dynamic]Pool_Range) -> f64 {
	// The first child of a group and the nodes under it come before its second child.
	path: [LIGHT_TREE_DEPTH]u32
	depth := 0
	root := u32(0)
	if shadowless := light_tree_shadowless(nodes); shadowless > 0 && leaf >= shadowless {root = shadowless}
	for at := root; at != leaf && depth < LIGHT_TREE_DEPTH; depth += 1 {
		path[depth] = at
		at = nodes[at].child if leaf >= nodes[at].child else at + 1
	}
	light := nodes[leaf].child
	nodes[leaf] = light_tree_leaf(lights[light], light)
	if dirty != nil {range_add(dirty, {leaf, 1})}
	change: f64
	#reverse for group in path[:depth] {
		before := light_node_cost(nodes[group])
		second := nodes[group].child
		nodes[group] = light_tree_group(nodes[group + 1], nodes[second], second)
		change += light_node_cost(nodes[group]) - before
		if dirty != nil {range_add(dirty, {group, 1})}
	}
	return change
}

// Refits every node to the lights, as light_tree_refit does one light, and
// returns what the tree costs.
light_tree_refit_all :: proc(nodes: []Gpu_Light_Node, lights: []Gpu_Light) -> f64 {
	// Children come after their group.
	for at := len(nodes) - 1; at >= 0; at -= 1 {
		node := &nodes[at]
		if node.flags & GPU_LIGHT_NODE_LEAF != 0 {
			node^ = light_tree_leaf(lights[node.child], node.child)
		} else if light_node_holds(node^) {
			node^ = light_tree_group(nodes[at + 1], nodes[node.child], node.child)
		}
	}
	return light_tree_cost(nodes)
}

// What a tree costs the points that walk it: the sum over its groups of
// light_node_cost, which grows as a refit stretches its groups over lights
// that moved apart or turned away from each other.
light_tree_cost :: proc(nodes: []Gpu_Light_Node) -> (cost: f64) {
	for node in nodes {
		if node.flags & GPU_LIGHT_NODE_LEAF == 0 {cost += light_node_cost(node)}
	}
	return
}

// What a group costs, as light_bounds_cost weighs a run of lights: its
// power, times the solid angle its light shines through, times the area of
// the box around its sphere.
light_node_cost :: proc(n: Gpu_Light_Node) -> f64 {
	r := f64(n.center_radius.w)
	return f64(light_tree_weight(n)) * f64(light_orientation_measure(n.cone.w, f32(n.widths[0]) * LIGHT_WIDTH_STEP)) * 24 * r * r
}

// A light with no place would leave every node above it with none.
light_placed :: proc "contextless" (l: Gpu_Light) -> bool {
	p := l.position_range
	return p.x - p.x == 0 && p.y - p.y == 0 && p.z - p.z == 0
}


// A spot or a rectangle lights one side.
light_directed :: proc "contextless" (l: Gpu_Light) -> bool {return light_spot(l) || light_rect(l)}
light_spot :: proc "contextless" (l: Gpu_Light) -> bool {return l.direction_cone.w > GPU_LIGHT_POINT * 0.5}
light_rect :: proc "contextless" (l: Gpu_Light) -> bool {return l.direction_cone.w < (GPU_LIGHT_POINT + GPU_LIGHT_RECT) * 0.5}

// The radius of the sphere around the center of a light that holds it, and
// the root of the mean square of how far its light lies from the center, no
// less than LIGHT_RADIUS_MIN, which the sphere of a group of them takes.
light_shape :: proc "contextless" (l: Gpu_Light) -> (extent, spread: f32) {
	if light_rect(l) {
		corner := l.size.y * l.size.y + l.size.z * l.size.z
		return math.sqrt(corner), max(math.sqrt(corner / 3), abi.LIGHT_RADIUS_MIN)
	}
	if l.size.y == 0 {return l.size.x, l.size.x}
	return l.size.x + l.size.y, math.sqrt(l.size.x * l.size.x + l.size.y * l.size.y / 3)
}

// How far a light reaches, in steps of four times: below 1 m, below 4 m, and
// so on, from 4 km on the last. The tree never groups lights of two of them,
// so a group never stands for a light where it does not reach, or loses one
// that reaches far among others that do not.
LIGHT_REACH_CLASSES :: 8
light_reach_class :: proc "contextless" (l: Gpu_Light) -> u64 {
	range := l.position_range.w
	if !(range >= 1) {return 0} // NaN too
	return u64(min(math.floor(math.log2(range) / 2) + 1, LIGHT_REACH_CLASSES - 1))
}

// The part of the tree a light goes to: the lights that light every way
// before those that light one side, and within each by reach class. The tree
// never groups lights of two parts.
light_part :: proc "contextless" (l: Gpu_Light) -> u32 {
	return (LIGHT_REACH_CLASSES if light_directed(l) else 0) + u32(light_reach_class(l))
}
