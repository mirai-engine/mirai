package mirai_render

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "core:testing"
import "core:time"

// Walks a tree and counts what breaks it: children outside the sphere or the
// reach of their group, power that does not add up, spots under a group that
// does not say so, and in seen the leaves of each light.
@(private = "file")
light_tree_faults :: proc(nodes: []Gpu_Light_Node, seen: []int) -> (outside, spots_split, depth_max: int) {
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
			if c.flags & GPU_LIGHT_NODE_SPOT != 0 && n.flags & GPU_LIGHT_NODE_SPOT == 0 {spots_split += 1}
			// The directions a child faces are within those of its group.
			if n.cone.w < math.PI && math.acos(clamp(linalg.dot(c.cone.xyz, n.cone.xyz), -1, 1)) + c.cone.w > n.cone.w + 1e-3 || c.emission > n.emission {outside += 1}
			append(&stack, struct {node, depth: int}{child, at.depth + 1})
		}
		power := nodes[at.node + 1].power_reach.xyz + nodes[n.child].power_reach.xyz
		if linalg.length(power - n.power_reach.xyz) > 1e-3 * linalg.length(power) {outside += 1}
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
	outside, spots_split, depth_max := light_tree_faults(nodes[:], seen[:])
	for count, i in seen {
		testing.expectf(t, count == (0 if i == 11 else 1), "light %d is in %d leaves", i, count)
		testing.expectf(t, i == 11 ? leaves[i] == LIGHT_TREE_NONE : nodes[leaves[i]].child == u32(i), "the leaf of light %d", i)
	}
	testing.expect_value(t, outside, 0)
	testing.expect_value(t, spots_split, 0)
	testing.expect_value(t, light_tree_unordered(nodes[:]), 0)
	testing.expectf(t, depth_max <= LIGHT_TREE_DEPTH, "%d levels", depth_max)
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
	// Other colors, intensities, ranges and sizes in the same places: the tree a build gives.
	for i := 0; i < len(lights); i += 7 {
		lights[i].color_intensity = {rand.float32_range(0.1, 1), 0.5, 0.2, rand.float32_range(0.5, 40)}
		lights[i].position_range.w = rand.float32_range(0.5, 20)
		lights[i].size.x = rand.float32_range(0, 0.6)
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
	testing.expect(t, abs(cost - light_tree_cost(nodes[:])) <= 1e-6 * cost)
	// Lights that moved far: the refit tree holds them still.
	for i := 3; i < len(lights); i += 5 {
		lights[i].position_range.xyz += {rand.float32_range(-30, 30), rand.float32_range(-3, 3), rand.float32_range(-30, 30)}
		light_tree_refit(nodes[:], lights[:], leaves[i], nil)
	}
	seen: [300]int
	outside, spots_split, _ := light_tree_faults(nodes[:], seen[:])
	for count, i in seen {testing.expectf(t, count == 1, "light %d is in %d leaves", i, count)}
	testing.expect_value(t, outside, 0)
	testing.expect_value(t, spots_split, 0)
	// Refitting light by light gives what refitting the whole tree gives.
	resize(&built, len(nodes))
	copy(built[:], nodes[:])
	light_tree_refit_all(built[:], lights[:])
	testing.expect(t, slice.equal(nodes[:], built[:]))
}

// With room for lights of the GPU the tree of the scene follows it: the root
// stands for the scene until a pass writes the room, an empty leaf stands for
// the room, and a refit keeps the root with the scene.
@(test)
the_room_for_gpu_lights_comes_before_the_tree_of_the_scene :: proc(t: ^testing.T) {
	lights: [40]Gpu_Light
	light_tree_test_lights(lights[:])
	nodes, alone: [dynamic]Gpu_Light_Node
	keys: [dynamic]Light_Key
	leaves, alone_leaves: [dynamic]u32
	dirty: [dynamic]Pool_Range
	defer {delete(nodes); delete(alone); delete(keys); delete(leaves); delete(alone_leaves); delete(dirty)}
	REGION :: Light_Region{lights = 4}
	first := light_region_first(REGION)
	cost, _ := light_tree_build(&nodes, &keys, &leaves, lights[:], REGION)
	alone_cost, _ := light_tree_build(&alone, &keys, &alone_leaves, lights[:])
	testing.expect_value(t, len(nodes), int(first) + len(alone))
	testing.expect_value(t, cost, alone_cost)
	empty := u32(len(lights)) + REGION.lights
	for at in 1 ..= 2 * REGION.lights {
		testing.expectf(t, nodes[at].flags == GPU_LIGHT_NODE_LEAF && nodes[at].child == empty && nodes[at].power_reach == {}, "node %d is a leaf of no light", at)
	}
	testing.expect_value(t, light_tree_unordered(nodes[:]), 0)
	root := nodes[0]
	testing.expect(t, root.child == first && root.flags & GPU_LIGHT_NODE_LEAF == 0 && root.flags >> GPU_LIGHT_NODE_COUNT_SHIFT == len(lights))
	testing.expect(t, root.center_radius == alone[0].center_radius && root.power_reach == alone[0].power_reach)
	for i in 0 ..< len(lights) {testing.expect(t, leaves[i] == alone_leaves[i] + first && nodes[leaves[i]].child == u32(i))}
	lights[5].position_range.xyz += {30, 0, 0}
	light_tree_refit(nodes[:], lights[:], leaves[5], &dirty, REGION)
	light_tree_refit(alone[:], lights[:], alone_leaves[5], nil)
	has_root := false
	for range in dirty {has_root ||= range.first == 0}
	testing.expectf(t, nodes[0].center_radius == alone[0].center_radius && has_root, "the root %v follows the scene %v, in %v", nodes[0].center_radius, alone[0].center_radius, dirty)
	// Without lights of the scene the root stands for none.
	light_tree_build(&nodes, &keys, &leaves, nil, REGION)
	testing.expect(t, len(nodes) == int(first) && nodes[0].child == 2 * REGION.lights && nodes[0].flags == 0)
}

// The lights that cast no shadows have a part of the room of their own,
// after that of those that do: a tree no node under the root leads to, a
// leaf of no light until a pass writes it, with its lights after the light
// of none of the other part and the tree of the scene after it. Asking for
// them alone keeps a leaf for the lights with shadows, which node 0 needs.
@(test)
the_lights_without_shadows_have_a_tree_the_root_does_not_lead_to :: proc(t: ^testing.T) {
	testing.expect_value(t, light_region_of(3, 5), Light_Region{4, 8})
	testing.expect_value(t, light_region_of(0, 5), Light_Region{1, 8})
	testing.expect_value(t, light_region_of(5, 0), Light_Region{8, 0})
	testing.expect_value(t, light_region_of(0, 0), Light_Region{})
	testing.expect_value(t, light_region_of(5000, 1), Light_Region{LIGHT_REGION_MAX, 1})
	lights: [40]Gpu_Light
	light_tree_test_lights(lights[:])
	nodes, alone: [dynamic]Gpu_Light_Node
	keys: [dynamic]Light_Key
	leaves, alone_leaves: [dynamic]u32
	defer {delete(nodes); delete(alone); delete(keys); delete(leaves); delete(alone_leaves)}
	region := Light_Region{4, 8}
	first, root := light_region_first(region), light_region_shadowless(region)
	testing.expect_value(t, root, u32(9))
	testing.expect_value(t, first, u32(25))
	testing.expect_value(t, light_region_lights(region), 4 + 1 + 8 + 1)
	testing.expect_value(t, light_region_frame(region), [4]u32{9, 25, 0, 0})
	testing.expect_value(t, light_region_frame({lights = 4}), [4]u32{})
	light_tree_build(&nodes, &keys, &leaves, lights[:], region)
	light_tree_build(&alone, &keys, &alone_leaves, lights[:])
	testing.expect_value(t, len(nodes), int(first) + len(alone))
	empty, none := u32(len(lights)) + region.lights, u32(len(lights)) + region.lights + 1 + region.shadowless
	for at in 1 ..= 2 * region.lights {
		testing.expectf(t, nodes[at].flags == GPU_LIGHT_NODE_LEAF && nodes[at].child == empty, "node %d is the leaf of no light with shadows", at)
	}
	for at in root ..< root + 2 * region.shadowless {
		testing.expectf(t, nodes[at].flags == GPU_LIGHT_NODE_LEAF && nodes[at].child == none && nodes[at].power_reach == {}, "node %d is the leaf of no light without shadows", at)
	}
	testing.expect(t, nodes[0].child == first && nodes[0].center_radius == alone[0].center_radius && nodes[0].power_reach == alone[0].power_reach)
	testing.expect_value(t, light_tree_unordered(nodes[:]), 0)
	for i in 0 ..< len(lights) {testing.expect(t, leaves[i] == alone_leaves[i] + first)}
	// The traversals of shadows start at node 0: none of them meets the part without.
	pending: [dynamic]u32
	defer delete(pending)
	append(&pending, 0)
	met := 0
	for len(pending) > 0 {
		at := pop(&pending)
		if at >= root && at < first {met += 1}
		if nodes[at].flags & GPU_LIGHT_NODE_LEAF == 0 {append(&pending, at + 1, nodes[at].child)}
	}
	testing.expect_value(t, met, 0)
	// Without lights of the scene node 0 stands for none.
	light_tree_build(&nodes, &keys, &leaves, nil, region)
	testing.expect(t, len(nodes) == int(first) && nodes[0].child == 2 * region.lights && nodes[0].flags == 0)
}

// A room nobody wrote in the frame before goes back to the root of the scene
// and to an empty part without shadows: their nodes go up again.
@(test)
a_room_nobody_wrote_goes_back_to_the_scene_and_no_lights_without_shadows :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	s := &r.scene
	lights_ask(r, 0, 3)
	scene_light_region(r)
	testing.expect_value(t, s.light_region, Light_Region{1, 4})
	testing.expect(t, s.lights_dirty && len(s.light_tree) == int(light_region_first(s.light_region)))
	s.lights_dirty = false
	clear(&s.light_node_ranges)
	lights_ask(r, 0, 3)
	scene_light_region(r)
	root := light_region_shadowless(s.light_region)
	ranges := [2]bool{}
	for range in s.light_node_ranges {
		ranges[0] ||= range.first == 0 && range.count >= 2
		ranges[1] ||= range.first <= root && range.first + range.count > root
	}
	testing.expectf(t, ranges == {true, true}, "the root of all and that of the lights without shadows go up again: %v", s.light_node_ranges)
	testing.expect(t, s.light_tree[root].flags == GPU_LIGHT_NODE_LEAF && s.light_tree[root].power_reach == {})
	scene_light_region(r)
	testing.expect_value(t, s.light_region, Light_Region{})
}

@(test)
the_light_tree_is_refit_while_each_light_keeps_its_kind :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	s := &r.scene
	lights: [100]Light_Desc
	for &light, i in lights {light = {position = {f32(i % 10) * 2, 1, f32(i / 10) * 2}, color = {1, 1, 1}, intensity = 10, range = 4, radius = 0.05}}
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
	outside, _, _ := light_tree_faults(s.light_tree[:], seen[:])
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

	// Another kind, or another number of lights: another set.
	lights[5].cone, lights[5].direction = 0.5, {0, -1, 0}
	scene_lights_given(r, lights[:], {}, {})
	testing.expect(t, s.light_revision == revision + 1 && s.lights_dirty)
	uploaded(s)
	scene_lights_given(r, lights[:99], {}, {})
	testing.expect(t, s.light_revision == revision + 2 && s.lights_dirty && len(s.lights) == 99)
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
			for &light, i in lights {light = {position = {f32(i % 64) - 32, 1, f32(i / 64) - 32}, color = {1, 1, 1}, intensity = 100, range = 4, radius = 0.05}}
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

@(test)
the_lights_of_a_run_follow_a_curve_that_keeps_neighbors_together :: proc(t: ^testing.T) {
	point :: proc(p: Vec3) -> Gpu_Light {return {position_range = {p.x, p.y, p.z, 5}, direction_cone = {0, 0, 0, GPU_LIGHT_POINT}}}
	near := light_curve_place(point({1.1, 2, 3}))
	testing.expect_value(t, light_curve_place(point({1.2, 2.1, 3.1})), near)
	testing.expect(t, light_curve_place(point({40, 2, 3})) != near)
	testing.expect_value(t, light_curve_place(point({transmute(f32)u32(0x7fc00000), 0, 0})), light_curve_place(point({-1e7, 0, 0})))
	spot := point({1.1, 2, 3})
	spot.direction_cone = {0, -1, 0, 0.8}
	testing.expect(t, light_curve_place(spot) > light_curve_place(point({1e6, 1e6, 1e6})))
}

// A group of spots faces what they face: two that look down light nothing
// above them, and a tilted one widens the cone by half the angle between.
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
	testing.expectf(t, abs(root.cone.y + 1) < 1e-5 && root.cone.w < 1e-5 && abs(root.emission - 0.6) < 1e-5, "the cone of two that look down: %v %v", root.cone, root.emission)
	tilt := f32(math.PI / 3)
	lights[2].position_range.x = 2
	lights[2].direction_cone.xyz = {math.sin(tilt), -math.cos(tilt), 0}
	light_tree_build(&nodes, &keys, &leaves, lights[:])
	root = nodes[0]
	testing.expectf(t, abs(root.cone.w - tilt / 2) < 1e-4, "a cone of half the angle between: %v", root.cone)
	point := down
	point.direction_cone = {0, 0, 0, GPU_LIGHT_POINT}
	lights[2] = point
	light_tree_build(&nodes, &keys, &leaves, lights[:])
	testing.expect(t, nodes[0].cone.w >= math.PI, "with a point it faces every way")
	seen: [3]int
	outside, _, _ := light_tree_faults(nodes[:], seen[:])
	testing.expect_value(t, outside, 0)
}
