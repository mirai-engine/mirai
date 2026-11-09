package mirai_render

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import "core:slice"

// The local lights as a binary tree, for a point to add up the far ones by
// groups and the near ones one by one (lighting.slang). The lights are
// sorted along a curve that keeps neighbors together, the points before the
// spots, and every node holds a run of them: its children split the run
// where the curve leaves one half of space for the other. A node keeps what
// its lights give together, as one light of their size would, and the cone
// of the directions they face with how far beyond it they shine (the
// orientation bounds of Conty Estevez and Kulla 2018): a group of spots that
// face down lights nothing above them. Nodes are in depth-first order: the
// first child of a node follows it and the second comes after the nodes
// under the first, so every child comes after its group, which the walks of
// lighting.slang hold a node to.
Gpu_Light_Node :: struct {
	center_radius: Vec4, // xyz the center of its lights, weighed by how bright each is; w the radius of the sphere around it that holds them
	power_reach:   Vec4, // rgb the sum of their colors times their intensities; w how far from the center the farthest of them reaches
	cone:          Vec4, // xyz the axis of the directions they face; w the half-angle around it that holds those directions, radians; PI: any
	emission:      f32,  // the half-angle beyond the directions they face that their light goes, radians: a spot its cone, a rectangle a quarter turn
	range:         f32,  // of a group, the mean of their ranges weighed by how bright each is
	spread:        f32,  // root of the mean square of how far their light lies from the center, their sizes included
	child:         u32,  // a leaf: its light; a group: its second child
	flags:         u32,  // GPU_LIGHT_NODE_*, and the number of its lights from GPU_LIGHT_NODE_COUNT_SHIFT
}
GPU_LIGHT_NODE_LEAF :: 1
GPU_LIGHT_NODE_SPOT :: 2 // it is a spot or holds one: it opens before the others, and stands for its spots by the cone of their directions
GPU_LIGHT_NODE_COUNT_SHIFT :: 2

// Below this depth the runs are split where the curve says; deeper, in
// halves. A traversal never holds more than LIGHT_TREE_DEPTH nodes.
LIGHT_TREE_CURVE_DEPTH :: 32
LIGHT_TREE_DEPTH :: 48
LIGHTS_MAX :: 1 << (LIGHT_TREE_DEPTH - LIGHT_TREE_CURVE_DEPTH)

// The most lights or groups a point lights through their shadow rays (light_cut of lighting.slang).
LIGHT_CUT_MAX :: 32

Light_Key :: struct {
	place: u64,
	light: u32,
}

LIGHT_TREE_NONE :: max(u32) // the leaf of a light the tree does not hold

// A change of the lights that keeps their number and the kind of each one
// refits the tree instead of building it again, while what the tree costs
// stays within this factor of what it cost when it was built.
LIGHT_TREE_REFIT_SLACK :: 1.5

// Room for lights a pass of an extension writes on the GPU each frame
// (pass_lights), before the tree of the scene, in two parts: the lights
// that cast shadows and those that do not. Each part is a tree of its
// leaves the pass builds, then a leaf of no light; its lights are its leaves
// and then that of the empty leaf. Node 0 is the root of the scene and of
// the part with shadows, whose tree starts at 1; the tree of the part
// without shadows follows it, and its root is no child of node 0
// (light_region_shadowless): the traversals of shadows never meet it. The
// lights follow those of the scene, those with shadows first. The tree of
// the scene starts at light_region_first. Until a pass writes a part, each
// of its nodes is its empty leaf: a group the pass wrote over children it
// did not leads to a leaf, never back to the root. A pass that does not
// write the room leaves the root of the scene alone and the part without
// shadows empty.
LIGHT_REGION_MAX :: 1024 // lights of a part
LIGHT_REGION_AWAY :: Vec3{0, -1e6, 0} // where the empty leaf lies: it reaches and weighs nothing

// The leaves of each part, a power of two. With a part without shadows the
// part with them has a leaf at least, which may hold no light.
Light_Region :: struct {
	lights:     u32, // that cast shadows
	shadowless: u32, // that do not
}

// The room for the lights asked for: each part the power of two that holds
// them, up to LIGHT_REGION_MAX.
light_region_of :: proc "contextless" (lights, shadowless: u32) -> Light_Region {
	fit :: proc "contextless" (count: u32) -> u32 {
		if count == 0 {return 0}
		leaves := u32(1)
		for leaves < min(count, LIGHT_REGION_MAX) {leaves <<= 1}
		return leaves
	}
	region := Light_Region{fit(lights), fit(shadowless)}
	if region.shadowless > 0 {region.lights = max(region.lights, 1)}
	return region
}

light_region_first :: proc "contextless" (region: Light_Region) -> u32 {
	return 2 * (region.lights + region.shadowless) + 1 if region.lights > 0 else 0
}

// The root of the tree of the lights that cast no shadows; 0: none.
light_region_shadowless :: proc "contextless" (region: Light_Region) -> u32 {
	return 2 * region.lights + 1 if region.shadowless > 0 else 0
}

// The part without shadows as the frame constants give it
// (Gpu_Frame.shadowless_lights): the root of its tree and the node after it.
light_region_frame :: proc "contextless" (region: Light_Region) -> [4]u32 {
	root := light_region_shadowless(region)
	return {root, root + 2 * region.shadowless if root > 0 else 0, 0, 0}
}

// The lights of the room, those of the empty leaves among them.
light_region_lights :: proc "contextless" (region: Light_Region) -> int {
	if region.lights == 0 {return 0}
	return int(region.lights) + 1 + (int(region.shadowless) + 1 if region.shadowless > 0 else 0)
}

// The memory a tree of that many lights after the room of region takes at
// most: with it light_tree_build does not fail. False without memory.
light_tree_reserve :: proc(nodes: ^[dynamic]Gpu_Light_Node, keys: ^[dynamic]Light_Key, leaves: ^[dynamic]u32, lights: int, region: Light_Region = {}) -> bool {
	placed := min(lights, LIGHTS_MAX)
	return reserve(leaves, lights) == nil && reserve(keys, placed) == nil && reserve(nodes, int(light_region_first(region)) + max(2 * placed - 1, 0)) == nil
}

// Builds the tree into nodes, after the room of region, with the leaf of
// each light in leaves, and returns what it costs (light_tree_cost). False
// without memory for it: the three stay as they were.
light_tree_build :: proc(nodes: ^[dynamic]Gpu_Light_Node, keys: ^[dynamic]Light_Key, leaves: ^[dynamic]u32, lights: []Gpu_Light, region: Light_Region = {}) -> (cost: f64, ok: bool) {
	if !light_tree_reserve(nodes, keys, leaves, len(lights), region) {return 0, false}
	clear(nodes)
	clear(keys)
	first := light_region_first(region)
	// Reserved: neither asks for memory.
	if resize(leaves, len(lights)) != nil || resize(nodes, int(first)) != nil {return 0, false}
	for &leaf in leaves {leaf = LIGHT_TREE_NONE}
	for l, i in lights {
		if light_placed(l) && len(keys) < LIGHTS_MAX {append(keys, Light_Key{light_curve_place(l), u32(i)})}
	}
	if len(keys) > 0 {
		slice.sort_by(keys[:], proc(a, b: Light_Key) -> bool {return a.place < b.place || (a.place == b.place && a.light < b.light)})
		light_tree_node(nodes, keys[:], leaves[:], lights, 0)
	}
	if region.lights > 0 {
		empty := light_region_empty(u32(len(lights)) + region.lights)
		for &node in nodes[1:][:2 * region.lights] {node = empty}
		if root := light_region_shadowless(region); root > 0 {
			none := light_region_empty(u32(len(lights)) + region.lights + 1 + region.shadowless)
			for &node in nodes[root:][:2 * region.shadowless] {node = none}
		}
		light_region_root(nodes[:], region)
	}
	return light_tree_cost(nodes[first:]), true
}

// A leaf of no light: the light it names is the one after those of its part.
@(private = "file")
light_region_empty :: proc(light: u32) -> Gpu_Light_Node {
	return {center_radius = {LIGHT_REGION_AWAY.x, LIGHT_REGION_AWAY.y, LIGHT_REGION_AWAY.z, 0}, cone = {0, 1, 0, math.PI}, emission = math.PI / 2, child = light, flags = GPU_LIGHT_NODE_LEAF}
}

// The root of the room before the pass writes it: the root of the scene,
// whose lights are all, or what stands for none.
light_region_root :: proc(nodes: []Gpu_Light_Node, region: Light_Region) {
	first := light_region_first(region)
	if int(first) >= len(nodes) {
		nodes[0] = nodes[2 * region.lights]
		nodes[0].child, nodes[0].flags = 2 * region.lights, 0
		return
	}
	nodes[0] = nodes[first]
	nodes[0].child = first
	nodes[0].flags &= ~u32(GPU_LIGHT_NODE_LEAF)
}

@(private = "file")
light_tree_node :: proc(nodes: ^[dynamic]Gpu_Light_Node, keys: []Light_Key, leaves: []u32, lights: []Gpu_Light, depth: int) -> u32 {
	at := u32(len(nodes))
	if len(keys) == 1 {
		light := keys[0].light
		leaves[light] = at
		append(nodes, light_tree_leaf(lights[light], light))
		return at
	}
	first, last := keys[0].place, keys[len(keys) - 1].place
	split := len(keys) / 2
	if first != last && depth < LIGHT_TREE_CURVE_DEPTH {
		// The keys of the run share every bit above the highest one in which
		// its ends differ: the second child starts at the first key with it.
		bit := u64(1) << (63 - intrinsics.count_leading_zeros(first ~ last))
		low, high := 0, len(keys) - 1
		for high - low > 1 {
			middle := (low + high) / 2
			if keys[middle].place & bit != 0 {high = middle} else {low = middle}
		}
		split = high
	}
	append(nodes, Gpu_Light_Node{})
	light_tree_node(nodes, keys[:split], leaves, lights, depth + 1)
	second := light_tree_node(nodes, keys[split:], leaves, lights, depth + 1)
	nodes[at] = light_tree_group(nodes[at + 1], nodes[second], second)
	return at
}

@(private = "file")
light_tree_leaf :: proc(l: Gpu_Light, light: u32) -> Gpu_Light_Node {
	extent, spread := light_shape(l)
	// A point or a capsule faces every way; a spot and a rectangle, their side.
	cone, emission := Vec4{0, 1, 0, math.PI}, f32(math.PI / 2)
	if light_spot(l) {
		cone, emission = {l.direction_cone.x, l.direction_cone.y, l.direction_cone.z, 0}, math.acos(clamp(l.direction_cone.w, -1, 1))
	} else if light_rect(l) {
		cone = {l.direction_cone.x, l.direction_cone.y, l.direction_cone.z, 0}
	}
	return {
		center_radius = {l.position_range.x, l.position_range.y, l.position_range.z, extent},
		power_reach = {l.color_intensity.x * l.color_intensity.w, l.color_intensity.y * l.color_intensity.w, l.color_intensity.z * l.color_intensity.w, l.position_range.w},
		cone = cone,
		emission = emission,
		range = l.position_range.w,
		spread = spread,
		child = light,
		flags = GPU_LIGHT_NODE_LEAF | (GPU_LIGHT_NODE_SPOT if light_directed(l) else 0) | 1 << GPU_LIGHT_NODE_COUNT_SHIFT,
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
		emission = max(a.emission, b.emission),
		range = share * a.range + (1 - share) * b.range,
		spread = math.sqrt(share * (da * da + a.spread * a.spread) + (1 - share) * (db * db + b.spread * b.spread)),
		child = second,
		flags = (a.flags | b.flags) & GPU_LIGHT_NODE_SPOT | (a.flags >> GPU_LIGHT_NODE_COUNT_SHIFT + b.flags >> GPU_LIGHT_NODE_COUNT_SHIFT) << GPU_LIGHT_NODE_COUNT_SHIFT,
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
light_tree_refit :: proc(nodes: []Gpu_Light_Node, lights: []Gpu_Light, leaf: u32, dirty: ^[dynamic]Pool_Range, region: Light_Region = {}) -> f64 {
	// The first child of a group and the nodes under it come before its second child.
	path: [LIGHT_TREE_DEPTH]u32
	depth := 0
	for at := light_region_first(region); at != leaf && depth < LIGHT_TREE_DEPTH; depth += 1 {
		path[depth] = at
		at = nodes[at].child if leaf >= nodes[at].child else at + 1
	}
	light := nodes[leaf].child
	nodes[leaf] = light_tree_leaf(lights[light], light)
	if dirty != nil {range_add(dirty, {leaf, 1})}
	change: f64
	#reverse for group in path[:depth] {
		before := f64(nodes[group].center_radius.w)
		second := nodes[group].child
		nodes[group] = light_tree_group(nodes[group + 1], nodes[second], second)
		after := f64(nodes[group].center_radius.w)
		change += after * after - before * before
		if dirty != nil {range_add(dirty, {group, 1})}
	}
	if region.lights > 0 {
		light_region_root(nodes, region)
		if dirty != nil {range_add(dirty, {0, 1})}
	}
	return change
}

// Refits every node to the lights, as light_tree_refit does one light, and
// returns what the tree costs.
light_tree_refit_all :: proc(nodes: []Gpu_Light_Node, lights: []Gpu_Light, region: Light_Region = {}) -> f64 {
	// Children come after their group.
	first := int(light_region_first(region))
	for at := len(nodes) - 1; at >= first; at -= 1 {
		node := &nodes[at]
		if node.flags & GPU_LIGHT_NODE_LEAF != 0 {
			node^ = light_tree_leaf(lights[node.child], node.child)
		} else {
			node^ = light_tree_group(nodes[at + 1], nodes[node.child], node.child)
		}
	}
	if region.lights > 0 {light_region_root(nodes, region)}
	return light_tree_cost(nodes[first:])
}

// What a tree costs the points that walk it: the sum over its groups of the
// square of their radius, which grows as a refit stretches its groups over
// lights that moved apart.
light_tree_cost :: proc(nodes: []Gpu_Light_Node) -> (cost: f64) {
	for node in nodes {
		if node.flags & GPU_LIGHT_NODE_LEAF == 0 {cost += f64(node.center_radius.w) * f64(node.center_radius.w)}
	}
	return
}

// A light with no place would leave every node above it with none.
light_placed :: proc "contextless" (l: Gpu_Light) -> bool {
	p := l.position_range
	return p.x - p.x == 0 && p.y - p.y == 0 && p.z - p.z == 0
}


// A spot or a rectangle lights one side: a group that holds one opens before the others.
light_directed :: proc "contextless" (l: Gpu_Light) -> bool {return light_spot(l) || light_rect(l)}
light_spot :: proc "contextless" (l: Gpu_Light) -> bool {return l.direction_cone.w > GPU_LIGHT_POINT * 0.5}
light_rect :: proc "contextless" (l: Gpu_Light) -> bool {return l.direction_cone.w < (GPU_LIGHT_POINT + GPU_LIGHT_RECT) * 0.5}

// The radius of the sphere around the center of a light that holds it, and
// the root of the mean square of how far its light lies from the center.
light_shape :: proc "contextless" (l: Gpu_Light) -> (extent, spread: f32) {
	if light_rect(l) {
		corner := l.size.y * l.size.y + l.size.z * l.size.z
		return math.sqrt(corner), math.sqrt(corner / 3)
	}
	if l.size.y == 0 {return l.size.x, l.size.x}
	return l.size.x + l.size.y, math.sqrt(l.size.x * l.size.x + l.size.y * l.size.y / 3)
}

// The place of a light along a curve that visits every quarter of a metre up to
// 262 km from the origin, spots after points: lights close to each other are
// close along it, and a light keeps its place wherever the others are.
light_curve_place :: proc(l: Gpu_Light) -> u64 {
	spread :: proc(v: u64) -> u64 {
		x := v & 0x1fffff
		x = (x | x << 32) & 0x1f00000000ffff
		x = (x | x << 16) & 0x1f0000ff0000ff
		x = (x | x << 8) & 0x100f00f00f00f00f
		x = (x | x << 4) & 0x10c30c30c30c30c3
		x = (x | x << 2) & 0x1249249249249249
		return x
	}
	cell :: proc(v: f32) -> u64 {
		q := v * 4 + f32(1 << 20)
		if !(q > 0) {return 0} // NaN too
		return u64(min(q, f32((1 << 21) - 1)))
	}
	spot := u64(1) << 63 if light_directed(l) else 0
	return spot | spread(cell(l.position_range.x)) | spread(cell(l.position_range.y)) << 1 | spread(cell(l.position_range.z)) << 2
}
