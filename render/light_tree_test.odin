package mirai_render

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "core:testing"
import "core:time"

// Walks a tree and counts what breaks it: children outside the sphere, the
// reach or the directions of their group, power that does not add up, and in
// seen the leaves of each light.
@(private = "file")
light_tree_faults :: proc(nodes: []Gpu_Light_Node, seen: []int) -> (outside, depth_max: int) {
	stack: [dynamic]struct {node, depth: int}
	defer delete(stack)
	append(&stack, struct {node, depth: int}{0, 1})
	for len(stack) > 0 {
		at := pop(&stack)
		n := nodes[at.node]
		depth_max = max(depth_max, at.depth)
		if n.flags & GPU_LIGHT_NODE_LEAF != 0 {
			seen[n.child] += 1
			continue
		}
		for child in ([2]int{at.node + 1, int(n.child)}) {
			c := nodes[child]
			gap := linalg.length(c.center_radius.xyz - n.center_radius.xyz)
			if gap + c.center_radius.w > n.center_radius.w * 1.0001 + 1e-4 || gap + c.power_reach.w > n.power_reach.w * 1.0001 + 1e-4 {outside += 1}
			// The directions a child faces are within those of its group, its
			// fall-off no wider and the cones of its lights no narrower.
			if n.cone.w < math.PI && math.acos(clamp(linalg.dot(c.cone.xyz, n.cone.xyz), -1, 1)) + c.cone.w > n.cone.w + 1e-3 || c.widths[0] > n.widths[0] || c.widths[1] < n.widths[1] {outside += 1}
			append(&stack, struct {node, depth: int}{child, at.depth + 1})
		}
		power := nodes[at.node + 1].power_reach.xyz + nodes[n.child].power_reach.xyz
		if linalg.length(power - n.power_reach.xyz) > 1e-3 * linalg.length(power) {outside += 1}
		a, b := nodes[at.node + 1], nodes[n.child]
		if n.range_low != min(a.range_low, b.range_low) || n.range_high != max(a.range_high, b.range_high) {outside += 1}
	}
	return
}

// The groups whose children do not both come after them within the tree,
// which the walks of lighting.slang do not open.
@(private = "file")
light_tree_unordered :: proc(nodes: []Gpu_Light_Node) -> (count: int) {
	for n, at in nodes {
		if n.flags & GPU_LIGHT_NODE_LEAF == 0 && (int(n.child) <= at + 1 || int(n.child) >= len(nodes)) {count += 1}
	}
	return
}

@(private = "file")
light_tree_test_lights :: proc(lights: []Gpu_Light) {
	for &l, i in lights {
		l.position_range = {rand.float32_range(-40, 40), rand.float32_range(-4, 6), rand.float32_range(-40, 40), rand.float32_range(0.5, 12)}
		l.color_intensity = {rand.float32_range(0.1, 1), rand.float32_range(0.1, 1), rand.float32_range(0.1, 1), rand.float32_range(0.5, 20)}
		l.direction_cone = {0, -1, 0, 0.7} if i % 37 == 0 else {0, 0, 0, GPU_LIGHT_POINT}
		if i % 37 == 0 && i % 2 == 1 {l.direction_cone.xyz = linalg.normalize([3]f32{rand.float32_range(-1, 1), -1, rand.float32_range(-1, 1)})}
		l.size.x = rand.float32_range(0, 0.3)
	}
}

@(test)
the_light_tree_holds_every_light_inside_the_bounds_of_its_nodes :: proc(t: ^testing.T) {
	lights: [300]Gpu_Light
	light_tree_test_lights(lights[:])
	// One that reaches far, one with no place and a crowd in one spot: none breaks the rest.
	lights[7].position_range = {3, 2, -5, 400}
	lights[11].position_range.x = transmute(f32)u32(0x7fc00000)
	for i in 100 ..< 140 {lights[i].position_range.xyz = {1, 1, 1}}
	nodes: [dynamic]Gpu_Light_Node
	keys: [dynamic]Light_Key
	leaves: [dynamic]u32
	defer delete(nodes)
	defer delete(keys)
	defer delete(leaves)
	cost, _ := light_tree_build(&nodes, &keys, &leaves, lights[:])
	testing.expect_value(t, len(nodes), 2 * (len(lights) - 1) - 1)
	testing.expect(t, cost > 0 && cost == light_tree_cost(nodes[:]))
	seen: [300]int
	outside, depth_max := light_tree_faults(nodes[:], seen[:])
	for count, i in seen {
		testing.expectf(t, count == (0 if i == 11 else 1), "light %d is in %d leaves", i, count)
		testing.expectf(t, i == 11 ? leaves[i] == LIGHT_TREE_NONE : nodes[leaves[i]].child == u32(i), "the leaf of light %d", i)
	}
	testing.expect_value(t, outside, 0)
	testing.expect_value(t, light_tree_unordered(nodes[:]), 0)
	testing.expectf(t, depth_max <= LIGHT_TREE_DEPTH, "%d levels", depth_max)
	// The lights of a reach class and a kind are one subtree: the nodes of one
	// class whose group holds more are one per class and kind at most.
	pairs: map[[2]u64]bool
	defer delete(pairs)
	for l, i in lights {if i != 11 {pairs[{u64(light_directed(l)), light_reach_class(l)}] = true}}
	mixed :: proc(n: Gpu_Light_Node) -> bool {
		return light_reach_class({position_range = {0, 0, 0, n.range_low}}) != light_reach_class({position_range = {0, 0, 0, n.range_high}})
	}
	parent := make([]int, len(nodes))
	defer delete(parent)
	for n, at in nodes {
		if n.flags & GPU_LIGHT_NODE_LEAF == 0 {parent[at + 1], parent[n.child] = at, at}
	}
	alone := 0
	for n, at in nodes {alone += int(!mixed(n) && (at == 0 || mixed(nodes[parent[at]])))}
	testing.expectf(t, alone <= len(pairs), "%d subtrees of one reach class for %d classes and kinds", alone, len(pairs))
	light_tree_build(&nodes, &keys, &leaves, nil)
	testing.expect(t, len(nodes) == 0 && len(leaves) == 0)
}

@(test)
a_refit_light_tree_keeps_its_bounds_and_is_the_built_one_where_the_lights_stay :: proc(t: ^testing.T) {
	lights: [300]Gpu_Light
	light_tree_test_lights(lights[:])
	nodes, built: [dynamic]Gpu_Light_Node
	keys: [dynamic]Light_Key
	leaves, built_leaves: [dynamic]u32
	dirty: [dynamic]Pool_Range
	defer {delete(nodes); delete(built); delete(keys); delete(leaves); delete(built_leaves); delete(dirty)}
	cost, _ := light_tree_build(&nodes, &keys, &leaves, lights[:])
	// Other colors as bright and ranges of their reach class in the same
	// places, which a build splits alike: the tree a build gives.
	for i := 0; i < len(lights); i += 7 {
		gray := luminance_of(lights[i].color_intensity.xyz)
		lights[i].color_intensity.xyz = {gray, gray, gray}
		class := light_reach_class(lights[i])
		low := f32(0.1) if class == 0 else math.pow(f32(4), f32(class) - 1)
		lights[i].position_range.w = rand.float32_range(low, 0.99 if class == 0 else 3.9 * low)
		clear(&dirty)
		cost += light_tree_refit(nodes[:], lights[:], leaves[i], &dirty)
		has_root, has_leaf := false, false
		for range in dirty {
			has_root ||= range.first == 0
			has_leaf ||= leaves[i] >= range.first && leaves[i] < range.first + range.count
		}
		testing.expectf(t, has_root && has_leaf, "the nodes the refit of light %d changed: %v", i, dirty)
	}
	light_tree_build(&built, &keys, &built_leaves, lights[:])
	testing.expect(t, slice.equal(nodes[:], built[:]), "a refit where no light moved is the tree a build gives")
	testing.expect(t, abs(cost - light_tree_cost(nodes[:])) <= 1e-4 * cost)
	// Lights that moved far, brightened and grew: the refit tree holds them
	// still, and costs more.
	for i := 3; i < len(lights); i += 5 {
		lights[i].position_range.xyz += {rand.float32_range(-30, 30), rand.float32_range(-3, 3), rand.float32_range(-30, 30)}
		lights[i].color_intensity.w *= 3
		lights[i].size.x = rand.float32_range(0, 0.6)
		cost += light_tree_refit(nodes[:], lights[:], leaves[i], nil)
	}
	testing.expect(t, abs(cost - light_tree_cost(nodes[:])) <= 1e-4 * cost)
	light_tree_build(&built, &keys, &built_leaves, lights[:])
	testing.expectf(t, light_tree_cost(built[:]) < cost, "a build of the lights where they are costs less than the refit tree: %v against %v", light_tree_cost(built[:]), cost)
	seen: [300]int
	outside, _ := light_tree_faults(nodes[:], seen[:])
	for count, i in seen {testing.expectf(t, count == 1, "light %d is in %d leaves", i, count)}
	testing.expect_value(t, outside, 0)
	// Refitting light by light gives what refitting the whole tree gives.
	resize(&built, len(nodes))
	copy(built[:], nodes[:])
	light_tree_refit_all(built[:], lights[:])
	testing.expect(t, slice.equal(nodes[:], built[:]))
}

@(test)
the_light_tree_is_refit_while_each_light_keeps_its_kind :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	s := &r.scene
	lights: [100]Light_Desc
	for &light, i in lights {light = {position = {f32(i % 10) * 2, 1, f32(i / 10) * 2}, color = {1, 1, 1}, intensity = 10, range = 4, radius = 0.05, indirect = 1, scattering = 1}}
	uploaded :: proc(s: ^Scene_State) {
		s.lights_dirty = false
		clear(&s.light_ranges)
		clear(&s.light_node_ranges)
	}
	scene_lights_given(r, lights[:], {}, {})
	revision := s.light_revision
	testing.expect(t, s.lights_dirty && len(s.light_tree) == 2 * len(lights) - 1)
	uploaded(s)

	lights[42].position.x += 0.3
	lights[42].intensity = 12
	scene_lights_given(r, lights[:], {}, {})
	testing.expect_value(t, s.light_revision, revision)
	testing.expect(t, !s.lights_dirty && len(s.light_ranges) == 1 && s.light_ranges[0] == Pool_Range{42, 1}, "the light that changed goes alone")
	testing.expect(t, len(s.light_node_ranges) > 0 && s.light_node_ranges[0].count < u32(len(s.light_tree)), "and the nodes above it")
	testing.expect_value(t, s.lights[42].position_range.x, lights[42].position.x)
	seen: [100]int
	outside, _ := light_tree_faults(s.light_tree[:], seen[:])
	testing.expect_value(t, outside, 0)
	uploaded(s)
	scene_lights_given(r, lights[:], {}, {})
	testing.expect(t, !s.lights_dirty && len(s.light_ranges) == 0 && len(s.light_node_ranges) == 0, "nothing changed, nothing goes")

	for &light in lights[:LIGHT_REFITS_MAX + 1] {light.position.y += 0.1}
	scene_lights_given(r, lights[:], {}, {})
	testing.expect(t, s.light_revision == revision && s.lights_dirty, "many changed: the whole tree is refit and goes")
	uploaded(s)

	// Far from the others, the light stretches the groups above it: the tree is built again.
	lights[0].position = {500, 1, 500}
	scene_lights_given(r, lights[:], {}, {})
	testing.expect(t, s.light_revision == revision && s.lights_dirty && s.light_tree_cost == s.light_tree_built)
	nodes: [dynamic]Gpu_Light_Node
	keys: [dynamic]Light_Key
	leaves: [dynamic]u32
	defer {delete(nodes); delete(keys); delete(leaves)}
	light_tree_build(&nodes, &keys, &leaves, s.lights[:])
	testing.expect(t, slice.equal(nodes[:], s.light_tree[:]))
	uploaded(s)

	// Another kind, another reach class or another number of lights: another set.
	lights[5].cone, lights[5].direction = 0.5, {0, -1, 0}
	scene_lights_given(r, lights[:], {}, {})
	testing.expect(t, s.light_revision == revision + 1 && s.lights_dirty)
	uploaded(s)
	lights[6].range = 5
	scene_lights_given(r, lights[:], {}, {})
	testing.expect(t, s.light_revision == revision + 1 && !s.lights_dirty, "a range within its class refits")
	uploaded(s)
	lights[6].range = 40
	scene_lights_given(r, lights[:], {}, {})
	testing.expect(t, s.light_revision == revision + 2 && s.lights_dirty)
	uploaded(s)
	scene_lights_given(r, lights[:99], {}, {})
	testing.expect(t, s.light_revision == revision + 3 && s.lights_dirty && len(s.lights) == 99)
	uploaded(s)

	// A light that stops casting shadows is another set: it goes to the tree of
	// those without, which no traversal from node 0 meets, and refits there.
	lights[7].shadowless = true
	scene_lights_given(r, lights[:99], {}, {})
	testing.expect(t, s.light_revision == revision + 4 && s.lights_dirty)
	uploaded(s)
	root := light_tree_shadowless(s.light_tree[:])
	testing.expect(t, root > 0 && s.light_leaves[7] == root && s.light_tree[root].child == 7, "the one light without shadows is the leaf of its tree")
	reached := false
	pending: [dynamic]u32
	defer delete(pending)
	append(&pending, 0)
	for len(pending) > 0 {
		at := pop(&pending)
		reached ||= at >= root
		if s.light_tree[at].flags & GPU_LIGHT_NODE_LEAF == 0 {append(&pending, at + 1, s.light_tree[at].child)}
	}
	testing.expect(t, !reached, "the traversals of shadows do not meet it")
	lights[7].intensity = 20
	scene_lights_given(r, lights[:99], {}, {})
	testing.expect(t, s.light_revision == revision + 4 && !s.lights_dirty && len(s.light_node_ranges) == 1 && s.light_node_ranges[0] == Pool_Range{root, 1}, "it refits alone")
	uploaded(s)
	// While every light casts none, the root of those that do stands for none.
	for &light in lights[:3] {light.shadowless = true}
	scene_lights_given(r, lights[:3], {}, {})
	testing.expect(t, s.light_tree[0] == LIGHT_NODE_NONE && light_tree_shadowless(s.light_tree[:]) == 1 && len(s.light_tree) == 6)
	testing.expect(t, light_tree_refit_all(s.light_tree[:], s.lights[:]) == s.light_tree_built && s.light_tree[0] == LIGHT_NODE_NONE, "a refit leaves it")
}

// -define:RENDER_BENCHMARK=true, with --release: the time to build the tree of
// 1024 lights 32 by 32 over a floor.
@(test)
light_tree_benchmark_reports_the_time_of_a_build :: proc(t: ^testing.T) {
	when !RENDER_BENCHMARK {return} else {
		lights: [1024]Gpu_Light
		for &l, i in lights {
			l.position_range = {-9 + 18 * (f32(i % 32) + 0.5) / 32, 3.5, -8 + 16 * (f32(i / 32) + 0.5) / 32, 8}
			l.color_intensity = {1, 0.7, 0.4, 4}
			l.direction_cone.w = GPU_LIGHT_POINT
		}
		nodes: [dynamic]Gpu_Light_Node
		keys: [dynamic]Light_Key
		leaves: [dynamic]u32
		defer {delete(nodes); delete(keys); delete(leaves)}
		started := time.tick_now()
		for _ in 0 ..< 200 {light_tree_build(&nodes, &keys, &leaves, lights[:])}
		fmt.printfln("light tree: %.3f ms for %d lights", time.duration_milliseconds(time.tick_since(started)) / 200, len(lights))
	}
}

// -define:RENDER_BENCHMARK=true, with --release: the CPU of scene_set_lights
// when one light of a grid moves and the others stay, as engine/render
// gives every light when one changes.
@(test)
light_update_benchmark_reports_the_time_of_moving_one_light :: proc(t: ^testing.T) {
	when !RENDER_BENCHMARK {return} else {
		for count in ([3]int{64, 1024, 4096}) {
			r: Renderer
			r.allocator = context.allocator
			scene_init(&r)
			defer scene_destroy(&r)
			lights := make([]Light_Desc, count)
			defer delete(lights)
			for &light, i in lights {light = {position = {f32(i % 64) - 32, 1, f32(i / 64) - 32}, color = {1, 1, 1}, intensity = 100, range = 4, radius = 0.05, indirect = 1, scattering = 1}}
			scene_lights_given(&r, lights, {}, {})
			started := time.tick_now()
			for _ in 0 ..< 200 {
				lights[count / 2].position.x += 0.01
				scene_lights_given(&r, lights, {}, {})
			}
			fmt.printfln("scene_set_lights moving one light of %d: %.4f ms", count, time.duration_milliseconds(time.tick_since(started)) / 200)
		}
	}
}

// The tree splits each part where its halves cost least: two crowds far
// apart are the two children of the root, and two rows of spots, one that
// looks down and one up, long beside each other, split by what they face
// before they split along the rows, which a split by place alone would do.
@(test)
the_light_tree_groups_lights_by_place_and_by_what_they_face :: proc(t: ^testing.T) {
	nodes: [dynamic]Gpu_Light_Node
	keys: [dynamic]Light_Key
	leaves: [dynamic]u32
	defer {delete(nodes); delete(keys); delete(leaves)}
	crowds: [32]Gpu_Light
	for &l, i in crowds {
		x := f32(-20 if i % 2 == 0 else 20) + rand.float32_range(-2, 2)
		l = {position_range = {x, rand.float32_range(0, 3), rand.float32_range(-2, 2), 6}, color_intensity = {1, 1, 1, rand.float32_range(1, 4)}, direction_cone = {0, 0, 0, GPU_LIGHT_POINT}}
	}
	light_tree_build(&nodes, &keys, &leaves, crowds[:])
	testing.expect(t, light_tree_halves(nodes[:], crowds[:], proc(l: Gpu_Light) -> bool {return l.position_range.x < 0}), "each crowd is a child of the root")
	rows: [32]Gpu_Light
	for &l, i in rows {
		up := i % 2 == 0
		l = {position_range = {f32(i / 2) * 1.3 - 10, 3, 0.5 if up else -0.5, 6}, color_intensity = {1, 1, 1, 2}, direction_cone = {0, 1 if up else -1, 0, math.cos(f32(0.6))}}
	}
	light_tree_build(&nodes, &keys, &leaves, rows[:])
	testing.expect(t, light_tree_halves(nodes[:], rows[:], proc(l: Gpu_Light) -> bool {return l.direction_cone.y > 0}), "each row is a child of the root")
	testing.expectf(t, nodes[1].cone.w < 1 && nodes[nodes[0].child].cone.w < 1, "each child faces one way: %v, %v", nodes[1].cone, nodes[nodes[0].child].cone)
	testing.expect_value(t, light_part(crowds[0]), u32(light_reach_class(crowds[0])))
	testing.expect_value(t, light_part(rows[0]), LIGHT_REACH_CLASSES + u32(light_reach_class(rows[0])))
}

// Whether the two children of the root of a tree hold the lights `of` says
// and the others, each all of one kind.
@(private = "file")
light_tree_halves :: proc(nodes: []Gpu_Light_Node, lights: []Gpu_Light, of: proc(l: Gpu_Light) -> bool) -> bool {
	kinds: [2]int // of each child, +1 for a light `of` says, -1 for another
	counts: [2]int
	for child, k in ([2]int{1, int(nodes[0].child)}) {
		pending := make([dynamic]int, context.temp_allocator)
		append(&pending, child)
		for len(pending) > 0 {
			at := pop(&pending)
			n := nodes[at]
			if n.flags & GPU_LIGHT_NODE_LEAF != 0 {
				kinds[k] += 1 if of(lights[n.child]) else -1
				counts[k] += 1
				continue
			}
			append(&pending, at + 1, int(n.child))
		}
	}
	return abs(kinds[0]) == counts[0] && abs(kinds[1]) == counts[1] && kinds[0] * kinds[1] < 0
}

// A group of spots faces what they face: two that look down light nothing
// above them and keep the cone each shines whole in, and a tilted one widens
// the cone by half the angle between.
@(test)
light_groups_face_the_directions_of_their_lights :: proc(t: ^testing.T) {
	down := Gpu_Light{position_range = {0, 3, 0, 5}, color_intensity = {1, 1, 1, 2}, direction_cone = {0, -1, 0, math.cos(f32(0.6))}}
	lights := [3]Gpu_Light{down, down, down}
	lights[1].position_range.x = 1
	nodes: [dynamic]Gpu_Light_Node
	keys: [dynamic]Light_Key
	leaves: [dynamic]u32
	defer delete(nodes)
	defer delete(keys)
	defer delete(leaves)
	light_tree_build(&nodes, &keys, &leaves, lights[:2])
	root := nodes[0]
	whole := 0.6 * f32(GPU_LIGHT_SPOT_FULL)
	testing.expectf(t, abs(root.cone.y + 1) < 1e-5 && abs(root.cone.w - whole) < 1e-5 && abs(f32(root.widths[0]) * LIGHT_WIDTH_STEP - (0.6 - whole)) < 1e-4 && abs(f32(root.widths[1]) * LIGHT_WIDTH_STEP - whole) < 1e-4, "the cone of two that look down: %v %v", root.cone, root.widths)
	tilt := f32(math.PI / 3)
	lights[2].position_range.x = 2
	lights[2].direction_cone.xyz = {math.sin(tilt), -math.cos(tilt), 0}
	light_tree_build(&nodes, &keys, &leaves, lights[:])
	root = nodes[0]
	testing.expectf(t, abs(root.cone.w - (tilt / 2 + whole)) < 1e-4 && abs(f32(root.widths[1]) * LIGHT_WIDTH_STEP - whole) < 1e-4, "a cone of half the angle between: %v %v", root.cone, root.widths)
	point := down
	point.direction_cone = {0, 0, 0, GPU_LIGHT_POINT}
	lights[2] = point
	light_tree_build(&nodes, &keys, &leaves, lights[:])
	testing.expect(t, nodes[0].cone.w >= math.PI, "with a point it faces every way")
	seen: [3]int
	outside, _ := light_tree_faults(nodes[:], seen[:])
	testing.expect_value(t, outside, 0)
}

// Whatever the lights reach, even past any scene, the grid of the lights fits
// its rows and holds each placed light in some cell.
@(test)
the_grid_of_the_lights_fits_its_rows_however_far_they_reach :: proc(t: ^testing.T) {
	ranges := [?]f32{0.5, 20, 1e4, 1e7, 1e30, math.inf_f32(1), math.nan_f32()}
	for range in ranges {
		lights := [2]Gpu_Light{{position_range = {0, 0, 0, range}}, {position_range = {500, 2, -300, 4}}}
		for &l in lights {l.direction_cone.w = GPU_LIGHT_POINT}
		grid := light_grid_place(lights[:])
		testing.expectf(t, grid.rows > 0 && grid.rows <= LIGHT_GRID_ROWS_MAX, "range %v: %d rows", range, grid.rows)
		testing.expectf(t, grid.size.x >= 1 && grid.size.y >= 1 && grid.size.z >= 1 && grid.cell >= LIGHT_GRID_CELL, "range %v: %v cells of %v m", range, grid.size, grid.cell)
	}
}
