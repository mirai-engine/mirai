package mirai_render

import "core:math"
import "mirai:render/abi"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import mm "mirai:std/math"

// A unit box centred on the origin.
@(private = "file")
batch_box :: proc(r: ^Renderer) -> Mesh_Handle {
	vertices: [8]Mesh_Vertex
	for &v, i in vertices {
		v.position = {f32(i & 1) - 0.5, f32(i >> 1 & 1) - 0.5, f32(i >> 2 & 1) - 0.5}
		v.normal = linalg.normalize(v.position)
		v.color = {1, 1, 1}
		v.tangent = {1, 0, 0, 1}
	}
	indices := [36]u32{0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5}
	handle, ok := mesh_add(r, vertices[:], indices[:])
	assert(ok)
	return handle
}

@(private = "file")
batch_row_word :: proc(row: Gpu_Instance, at: int) -> u32 {
	return transmute(u32)row.world[at / 4][at % 4]
}

@(test)
batch_instances_keep_their_rotation_and_scale_within_their_precision :: proc(t: ^testing.T) {
	rotations := [?]mm.Quat{
		1,
		mm.quat_axis_angle({0, 1, 0}, 2.1),
		mm.quat_axis_angle(linalg.normalize(Vec3{1, 2, -3}), -0.7),
		mm.quat_axis_angle({1, 0, 0}, math.PI * 0.5),
	}
	for q in rotations {
		packed := batch_instance({12.5, -3, 1000}, q, {0.8, 1.6, 3.2})
		back, scale := batch_instance_unpack(packed)
		testing.expect(t, mm.quat_angle(q, back) < 0.3 * math.PI / 180, "the rotation comes back within 0.3 degrees")
		testing.expect(t, linalg.length(scale - Vec3{0.8, 1.6, 3.2}) < 2e-3, "each scale comes back as a half float")
		// The rows are the rotation of each axis scaled by its own scale and the position, as batch_placement makes them.
		rows := batch_instance_rows(packed)
		for axis in 0 ..< 3 {
			unit: Vec3
			unit[axis] = scale[axis]
			testing.expect(t, linalg.length(Vec3{rows[0][axis], rows[1][axis], rows[2][axis]} - mm.quat_rotate(back, unit)) < 1e-4)
		}
		testing.expect(t, rows[0].w == 12.5 && rows[1].w == -3 && rows[2].w == 1000)
	}
}

@(test)
a_batch_keeps_its_handle_and_reuses_its_words_and_a_wrong_one_changes_nothing :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	mesh := batch_box(r)
	pool := len(r.scene.indices)
	instances := [3]Batch_Instance{batch_instance({0, 0, 0}, 1, {1, 1, 1}), batch_instance({4, 0, 0}, 1, {1, 2, 1}), batch_instance({8, 0, 0}, 1, {2, 1, 2})}
	handle, error := batch_set(r, 0, 0, {mesh = mesh, tint = 1}, instances[:])
	if !testing.expect_value(t, error, "") {return}
	testing.expect_value(t, len(r.scene.indices), pool + 3 * BATCH_WORDS)
	batches, held := batch_count(r)
	testing.expect(t, batches == 1 && held == 3)
	// Replacing keeps the handle and the words of the pool.
	again, replaced := batch_set(r, handle, 0, {mesh = mesh, tint = 1}, instances[:2])
	testing.expect(t, replaced == "" && again == handle)
	testing.expect_value(t, len(r.scene.indices), pool + 2 * BATCH_WORDS)
	testing.expect_value(t, batch_instance_at(&r.scene, &r.scene.batch.records[0], 0), instances[0])
	// Wrong input says what is wrong and leaves the batch as it was.
	bad_scale := [1]Batch_Instance{batch_instance({0, 0, 0}, 1, {0, 1, 0})}
	infinite := math.inf_f32(1)
	bad_position := [1]Batch_Instance{batch_instance({infinite, 0, 0}, 1, {1, 1, 1})}
	_, refused := batch_set(r, handle, 0, {mesh = mesh}, bad_scale[:])
	testing.expect(t, refused != "")
	_, refused = batch_set(r, handle, 0, {mesh = mesh}, bad_position[:])
	testing.expect(t, refused != "")
	_, refused = batch_set(r, handle, 0, {mesh = Mesh_Handle(99)}, instances[:])
	testing.expect(t, refused != "")
	_, refused = batch_set(r, handle, 0, {mesh = mesh, cull_distance = -1}, instances[:])
	testing.expect(t, refused != "")
	testing.expect_value(t, r.scene.batch.records[0].count, 2)
	// A removed batch frees its words, and its handle names nothing after.
	testing.expect(t, batch_remove(r, handle))
	testing.expect_value(t, len(r.scene.indices), pool)
	testing.expect(t, !batch_remove(r, handle))
	_, refused = batch_set(r, handle, 0, {mesh = mesh}, instances[:])
	testing.expect(t, refused != "", "a removed handle is refused")
	next, _ := batch_set(r, 0, 0, {mesh = mesh}, instances[:])
	testing.expect(t, next != handle, "the record comes back with another generation")
	// What each instance shows of its own is a word of each, which the row names; a color for each instance, or none.
	colors := [3]u32{batch_color({1, 0.5, 0.25}, 1), batch_color(1, 0), batch_color(0, 0.5)}
	_, refused = batch_set(r, next, 0, {mesh = mesh}, instances[:], colors[:2])
	testing.expect(t, refused != "")
	_, colored := batch_set(r, next, 0, {mesh = mesh, tint = 1}, instances[:], colors[:])
	testing.expect_value(t, colored, "")
	index, _ := batch_index(&r.scene, next)
	record := &r.scene.batch.records[index]
	testing.expect(t, record.colored && r.scene.indices[record.colors] == 0xff4080ff && r.scene.indices[record.colors + 1] == 0x00ffffff)
	batches_build(r)
	testing.expect_value(t, transmute(u32)r.scene.batch.rows[0].world_inv[2].x, record.colors + 1)
	_, _ = batch_set(r, next, 0, {mesh = mesh, tint = 1}, instances[:])
	batches_build(r)
	testing.expect(t, !record.colored && r.scene.batch.rows[0].world_inv[2].x == 0, "set again without them, it has none")
}

@(test)
the_tables_of_the_batches_drawn_follow_the_world_shown_and_the_instances :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	mesh := batch_box(r)
	many := make([]Batch_Instance, 70)
	defer delete(many)
	for &b, i in many {b = batch_instance({f32(i) * 2, 0, 0}, 1, {1, 1, 1})}
	shown, _ := batch_set(r, 0, 7, {mesh = mesh, cull_distance = 50, fade_distance = 40}, many[:])
	_, _ = batch_set(r, 0, 8, {mesh = mesh}, many[:3])
	traced, _ := batch_set(r, 0, 7, {mesh = mesh, flags = {.Casts_Shadow, .Ray_Visible}}, many[:3])
	r.world_key = 7
	batches_build(r)
	b := &r.scene.batch
	testing.expect_value(t, len(b.drawn), 2)
	// Two groups of 64 slots for 70 instances, then one for 3.
	testing.expect_value(t, b.slots, 3 * BATCH_GROUP)
	testing.expect_value(t, b.groups.count, 3)
	testing.expect(t, r.scene.indices[b.groups.first] == 0 && r.scene.indices[b.groups.first + 1] == 0 && r.scene.indices[b.groups.first + 2] == 1)

	first := b.rows[0]
	testing.expect_value(t, batch_row_word(first, 1), 70)
	testing.expect_value(t, batch_row_word(first, 2), 0)
	testing.expect(t, first.world[1].y == 40 && first.world[1].z == 50, "fade and cull distances")
	testing.expect_value(t, batch_row_word(first, 11), 0)
	second := b.rows[1]
	testing.expect_value(t, batch_row_word(second, 2), 2 * BATCH_GROUP)
	testing.expect_value(t, batch_row_word(second, 11), RAY_SMALL) // unit boxes: within SMALL_INSTANCE_REACH

	// Rays meet the second one: an item of the software TLAS, whose reference
	// past the instances names it, and its instances in a native TLAS.
	testing.expect_value(t, len(b.traced), 1)
	testing.expect_value(t, len(b.hw), 0)
	found := false
	for ref in r.scene.tlas_refs {found ||= ref == 1}
	testing.expect(t, found, "the reference of the traced batch is its index past the instances")
	testing.expect(t, r.scene.batch.records[2].tree_nodes > 0, "a traced batch has the tree of its instances")
	// Instances of the scene move the rows and the visible lists after them.
	instance := Instance_Desc{object_id = 1, mesh = mesh, transform = 1, tint = 1}
	scene_given(r, {instance}, nil, {}, {})
	batches_build(r)

	// Traced by hardware, the native TLAS takes their instances after the one
	// of the scene, with the custom indices of their slots (tlas_batches.comp).
	r.hardware_rt = true
	b.built = false
	batches_build(r)
	testing.expect_value(t, b.hw_count, 3)
	testing.expect(t, len(b.hw) == 1 && b.hw[0].slot == 2 * BATCH_GROUP && b.hw[0].mask == RAY_SMALL)
	r.hardware_rt = false
	found = false
	for ref in r.scene.tlas_refs {found ||= ref == 2}
	testing.expect(t, found)
	// Another world draws its own.
	r.world_key = 8
	batches_build(r)
	testing.expect_value(t, len(b.drawn), 1)
	testing.expect_value(t, b.slots, BATCH_GROUP)
	testing.expect_value(t, b.hw_count, 0)
	// A removed mesh takes its batches out of the tables.
	r.world_key = 7
	testing.expect(t, mesh_remove(r, mesh))
	batches_build(r)
	testing.expect_value(t, len(b.drawn), 0)
	testing.expect(t, batch_remove(r, shown) && batch_remove(r, traced))
}

@(test)
batches_rays_meet_change_the_light_and_others_do_not :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	mesh := batch_box(r)
	instances := [2]Batch_Instance{batch_instance({0, 0, 0}, 1, {1, 1, 1}), batch_instance({30, 0, 0}, 1, {1, 1, 1})}
	r.scene.changes = {}
	raster, _ := batch_set(r, 0, 0, {mesh = mesh}, instances[:])
	testing.expect(t, r.scene.changes.count == 0 && !r.scene.changes.all, "what no ray meets changes no light")
	shadow, _ := batch_set(r, 0, 0, {mesh = mesh, flags = {.Casts_Shadow}}, instances[:])
	testing.expect_value(t, r.scene.changes.count, 1)
	sphere := r.scene.changes.spheres[0]
	testing.expect(t, abs(sphere.x - 15) < 1e-3 && sphere.w > 15, "around the box of its instances")
	// Of another world: the light of the world shown stays.
	r.scene.changes = {}
	_, _ = batch_set(r, 0, 5, {mesh = mesh, flags = {.Ray_Visible}}, instances[:])
	testing.expect_value(t, r.scene.changes.count, 0)
	// Taking it out changes the light where it was.
	testing.expect(t, batch_remove(r, shadow))
	testing.expect_value(t, r.scene.changes.count, 1)
	testing.expect(t, batch_remove(r, raster))
	testing.expect_value(t, r.scene.changes.count, 1)
}

@(test)
meshes_clear_forgets_every_batch_and_says_so :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	mesh := batch_box(r)
	instances := [1]Batch_Instance{batch_instance({0, 0, 0}, 1, {1, 1, 1})}
	handle, _ := batch_set(r, 0, 0, {mesh = mesh}, instances[:])
	epoch := batches_epoch(r)
	meshes_clear(r)
	testing.expect(t, batches_epoch(r) != epoch)
	testing.expect(t, !batch_remove(r, handle))
	batches, _ := batch_count(r)
	testing.expect_value(t, batches, 0)
}

@(test)
the_tree_of_a_traced_batch_is_built_for_rays_traced_by_software_alone :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	mesh := batch_box(r)
	instances := make([]Batch_Instance, 37)
	defer delete(instances)
	for &b, i in instances {b = batch_instance({f32(i % 6) * 3, 0, f32(i / 6) * 3}, 1, {1, 1, 1})}
	r.hardware_rt = true
	handle, _ := batch_set(r, 0, 0, {mesh = mesh, flags = {.Casts_Shadow}}, instances[:])
	record := &r.scene.batch.records[0]
	testing.expect_value(t, record.tree_nodes, 0)
	r.hardware_rt = false
	batches_trees_build(r)
	if !testing.expect(t, record.tree_nodes > 0) {return}
	// Its leaves name every instance once, and their boxes hold them.
	seen := make([]bool, len(instances))
	defer delete(seen)
	for node in r.scene.blas_nodes[record.tree:][:record.tree_nodes] {
		if node.count == 0 {continue}
		for local in r.scene.indices[record.order + node.left_first:][:node.count] {
			testing.expect(t, !seen[local])
			seen[local] = true
			p := instances[local].position
			testing.expect(t, p.x >= node.bounds_min.x && p.x <= node.bounds_max.x && p.z >= node.bounds_min.z && p.z <= node.bounds_max.z)
		}
	}
	for s in seen {testing.expect(t, s)}
	// Moving an instance of the scene refits the software TLAS over the box of the batch too.
	scene_given(r, {{object_id = 1, mesh = mesh, transform = 1, tint = 1}}, nil, {}, {})
	batches_build(r)
	moved := linalg.matrix4_translate_f32({0, 50, 0})
	testing.expect(t, scene_move(r, {0}, {moved}))
	root := r.scene.tlas_nodes[0]
	testing.expect(t, root.bounds_max.y >= 50.4 && root.bounds_min.x <= -0.5 && root.bounds_max.z >= 18, "the root holds the moved instance and the batch")
	// The instances of the scene, the batches rays meet or both down to none
	// and back, a frame each: the tree holds what there is, and is refit over it.
	holds :: proc(r: ^Renderer) -> bool {
		s := &r.scene
		if len(s.instances) + len(s.batch.traced) == 0 {return s.tlas_nodes[0].bounds_min.x > s.tlas_nodes[0].bounds_max.x}
		seen := 0
		for ref in s.tlas_refs {
			index := int(ref &~ TLAS_REF_GLASS)
			if index >= len(s.instances) && !slice.contains(s.batch.traced[:], u32(index - len(s.instances))) {return false}
			seen += 1
		}
		return seen == len(s.instances) + len(s.batch.traced)
	}
	cases := [?]struct {
		name:               string,
		instances, batches: bool, // which go to none
	}{{"instances to none and back with batches that trace", true, false}, {"batches to none and back with instances", false, true}, {"both to none and back", true, true}}
	for c in cases {
		if c.instances {testing.expect(t, scene_given(r, nil, nil, {}, {}))}
		if c.batches {testing.expect(t, batch_remove(r, handle))}
		batches_build(r)
		testing.expectf(t, holds(r), "%s: the tree holds what there is with none", c.name)
		if c.instances {testing.expect(t, scene_given(r, {{object_id = 1, mesh = mesh, transform = 1, tint = 1}}, nil, {}, {}))}
		if c.batches {handle, _ = batch_set(r, 0, 0, {mesh = mesh, flags = {.Casts_Shadow}}, instances[:])}
		batches_build(r)
		testing.expect(t, scene_move(r, {0}, {linalg.matrix4_translate_f32({0, 60, 0})}))
		root = r.scene.tlas_nodes[0]
		testing.expectf(t, holds(r) && len(r.scene.batch.traced) == 1, "%s: the tree holds what came back", c.name)
		testing.expectf(t, root.bounds_max.y >= 60.4 && root.bounds_max.z >= 18, "%s: the root holds the moved instance and the batch", c.name)
	}
	testing.expect(t, batch_remove(r, handle))
}

@(test)
a_batch_says_what_it_is_and_its_revision_moves_when_it_is_set_again :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	mesh := batch_box(r)
	instances := [2]Batch_Instance{batch_instance({0, 0, 0}, 1, {1, 1, 1}), batch_instance({3, 0, 0}, 1, {1, 1, 1})}
	handle, _ := batch_set(r, 0, 0, {mesh = mesh, object_id = 42}, instances[:])
	revision := batches_revision(r)
	info, ok := batch_info(r, 0)
	testing.expect(t, ok && info.handle == handle && info.object_id == 42 && info.count == 2)
	batch_set(r, handle, 0, {mesh = mesh, object_id = 42}, instances[:])
	testing.expect(t, batches_revision(r) > revision)
	testing.expect(t, batch_remove(r, handle))
	_, ok = batch_info(r, 0)
	testing.expect(t, !ok)
}

@(test)
a_ray_finds_the_instance_of_a_batch_it_meets_first :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	mesh := batch_box(r)
	instances := [3]Batch_Instance{batch_instance({0, 0, 0}, 1, {1, 1, 1}), batch_instance({4, 0, 0}, 1, {1, 3, 1}), batch_instance({8, 0, 0}, 1, {2, 1, 2})}
	handle, _ := batch_set(r, 0, 5, {mesh = mesh, object_id = 9}, instances[:])
	other, _ := batch_set(r, 0, 6, {mesh = mesh}, instances[:])
	hit, found := batch_ray(r, 5, {4, 10, 0}, {0, -1, 0}, 100)
	testing.expect(t, found && hit.handle == handle && hit.instance == 1 && hit.object_id == 9)
	testing.expect(t, abs(hit.distance - 8.5) < 1e-3, "the top of the instance one and a half metres up")
	testing.expect(t, linalg.length(hit.normal - Vec3{0, 1, 0}) < 1e-3)
	// Along x the nearest one is met first; past max_distance or in another world, none.
	hit, found = batch_ray(r, 5, {-10, 0, 0}, {1, 0, 0}, 100)
	testing.expect(t, found && hit.instance == 0 && abs(hit.distance - 9.5) < 1e-3)
	_, found = batch_ray(r, 5, {-10, 0, 0}, {1, 0, 0}, 5)
	testing.expect(t, !found)
	_, found = batch_ray(r, 7, {-10, 0, 0}, {1, 0, 0}, 100)
	testing.expect(t, !found)
	_, found = batch_ray(r, 5, {2, 10, 0}, {0, -1, 0}, 100)
	testing.expect(t, !found, "between instances")
	_ = other
}

// A batch of Rays_Only is in no layer, so no view draws it, and the rays of
// its other flags meet it as any other: the far crown of foliage and the
// pose its probes see.
@(test)
a_batch_only_rays_meet_is_in_no_layer_and_the_picker_does_not_find_it :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	mesh := batch_box(r)
	instances := [2]Batch_Instance{batch_instance({0, 0, 0}, 1, {1, 1, 1}), batch_instance({4, 0, 0}, 1, {1, 1, 1})}
	_, refused := batch_set(r, 0, 0, {mesh = mesh, flags = {.Rays_Only}}, instances[:])
	testing.expect(t, refused != "", "no ray meets a batch of Rays_Only alone")
	crown, error := batch_set(r, 0, 0, {mesh = mesh, flags = {.Casts_Shadow, .Rays_Only}}, instances[:])
	if !testing.expect_value(t, error, "") {return}
	drawn, _ := batch_set(r, 0, 0, {mesh = mesh, layers = 2, flags = {.Casts_Shadow}}, instances[:])
	batches_build(r)
	b := &r.scene.batch
	testing.expect_value(t, len(b.drawn), 2)
	testing.expect_value(t, b.rows[0].meta.w >> INSTANCE_LAYERS_SHIFT, 0)
	testing.expect_value(t, b.rows[1].meta.w >> INSTANCE_LAYERS_SHIFT, 2)
	testing.expect_value(t, batch_row_word(b.rows[0], 11), RAY_SHADOW_ONLY)
	testing.expect_value(t, len(b.traced), 2)
	hit, found := batch_ray(r, 0, {0, 10, 0}, {0, -1, 0}, 100)
	testing.expect(t, found && hit.handle == drawn, "the picker meets what is drawn, not the crown")
	testing.expect(t, batch_remove(r, crown) && batch_remove(r, drawn))
}

// A batch keeps its instances relative to an anchor of its own: a jump of the
// origin moves its row and its box, not the words of its instances, its tree
// or the rows a native TLAS takes, and they stay where they are in the world.
@(test)
a_jump_of_the_origin_moves_the_row_of_a_batch_and_not_its_instances :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	mesh := batch_box(r)
	far := Vec3{15003.25, 2, -12001.5}
	instances := [3]Batch_Instance{batch_instance(far, 1, {1, 1, 1}), batch_instance(far + {4, 0, 0}, 1, {1, 2, 1}), batch_instance(far + {0, 0, 9}, 1, {2, 1, 2})}
	handle, _ := batch_set(r, 0, 0, {mesh = mesh, flags = {.Casts_Shadow, .Ray_Visible}}, instances[:])
	batches_build(r)
	record := &r.scene.batch.records[0]
	testing.expect_value(t, record.anchor, Vec3{15360, 0, -12288})
	words := make([]u32, record.count * BATCH_WORDS)
	defer delete(words)
	copy(words, r.scene.indices[record.words:][:len(words)])
	nodes := make([]Gpu_Bvh_Node, record.tree_nodes)
	defer delete(nodes)
	copy(nodes, r.scene.blas_nodes[record.tree:][:record.tree_nodes])
	clear(&r.scene.pool_dirty[.Index])
	clear(&r.scene.pool_dirty[.Node])
	renderer_origin_set(r, far + {300, 0, 900})
	testing.expect_value(t, renderer_origin(r), Vec3{15360, 0, -11264})
	batches_build(r)
	testing.expect(t, len(r.scene.pool_dirty[.Node]) == 0, "the tree of the batch stays")
	for word, i in words {testing.expect_value(t, r.scene.indices[record.words + u32(i)], word)}
	for node, i in nodes {testing.expect_value(t, r.scene.blas_nodes[record.tree + u32(i)], node)}
	// The row takes them where they are: an instance placed as the shaders place it.
	row := r.scene.batch.rows[0]
	offset := row.world_inv[1].xyz
	testing.expect_value(t, offset, Vec3{0, 0, -1024})
	rows := batch_instance_rows(batch_instance_at(&r.scene, record, 1))
	place := Vec3{rows[0].w, rows[1].w, rows[2].w} + offset
	testing.expect_value(t, place, origin_point(far + {4, 0, 0}, renderer_origin(r)))
	testing.expect(t, row.bounds_min.x <= place.x - 0.5 && row.bounds_max.z >= origin_point(far, renderer_origin(r)).z + 9.5)
	// So does a ray of the CPU.
	hit, found := batch_ray(r, 0, far + {4, 10, 0}, {0, -1, 0}, 100)
	testing.expect(t, found && hit.instance == 1 && abs(hit.distance - 9) < 1e-3)
	testing.expect(t, batch_remove(r, handle))
}

// What the culls of the maps of the shadows keep of what reaches each slot
// (shadow_reach) is what the maps give found anew, frame after frame, through
// a sequence of changes: the eye moving or jumping, the sun turning, lights
// moving, changing range or cone or trading their slots, slots letting go of
// their pages, batches set again, coming, going, casting or not and reaching
// farther, batches moving and swaying, instances of the scene coming and
// going, another world shown, a jump of the origin, the targets of a view
// made anew and two views; and none of the casters a map reaches is left out.
@(test)
the_kept_reach_of_the_shadow_maps_is_what_the_maps_give :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	box := batch_box(r)
	random := u32(12345)
	next :: proc(random: ^u32, n: int) -> int {
		random^ = random^ * 1664525 + 1013904223
		return int(random^ >> 8) % max(n, 1)
	}
	instances: [12]Batch_Instance
	place :: proc(instances: []Batch_Instance, random: ^u32) {
		corner := Vec3{f32(next(random, 120)) - 60, f32(next(random, 4)), f32(next(random, 120)) - 60}
		for &instance, k in instances {instance = batch_instance(corner + {f32(k % 4) * 1.5, 0, f32(k / 4) * 1.5}, 1, {1, f32(1 + next(random, 3)), 1})}
	}
	handles: [dynamic]Batch_Handle
	defer delete(handles)
	set :: proc(r: ^Renderer, handle: Batch_Handle, box: Mesh_Handle, instances: []Batch_Instance, random: ^u32) -> Batch_Handle {
		flags := Batch_Flags{.Ray_Visible} if next(random, 5) == 0 else {.Casts_Shadow, .Ray_Visible}
		made, _ := batch_set(r, handle, u64(1 if next(random, 6) == 0 else 0), {mesh = box, flags = flags, reach = f32(next(random, 3)) * 0.5}, instances)
		return made
	}
	for _ in 0 ..< 80 {
		place(instances[:], &random)
		append(&handles, set(r, 0, box, instances[:next(&random, 12) + 1], &random))
	}
	descs: [40]Instance_Desc
	scene :: proc(r: ^Renderer, descs: []Instance_Desc, box: Mesh_Handle, random: ^u32) {
		count := next(random, len(descs))
		for &desc, i in descs[:count] {desc = {object_id = u64(i + 1), mesh = box, transform = linalg.matrix4_translate_f32({f32(next(random, 80)) - 40, 1, f32(next(random, 80)) - 40}), tint = 1}}
		scene_given(r, descs[:count], nil, {}, {})
	}
	scene(r, descs[:], box, &random)
	lights: [SHADOW_RASTER_LIGHTS]Gpu_Light
	for &l in lights {
		l = {position_range = {f32(next(&random, 100)) - 50, 3, f32(next(&random, 100)) - 50, f32(5 + next(&random, 20))}, size = {0.1, 0, 0, 0}, direction_cone = {0, -1, 0, GPU_LIGHT_POINT}}
	}
	blocks: [SHADOW_RASTER_LIGHTS]int
	for &block, k in blocks {block = k}
	eye, toward := Vec3{0, 12, 0}, Vec3{-0.3, -1, -0.2}
	views: [2]Shadow_Raster
	fresh: Shadow_Raster
	defer for &b in views {shadow_reach_release(r, &b)}
	defer shadow_reach_release(r, &fresh)
	for frame in 0 ..< 120 {
		view := &views[1 if frame % 3 == 2 else 0]
		// The changes of this frame.
		for _ in 0 ..< 1 + next(&random, 3) {
			switch next(&random, 14) {
			case 0: eye += {f32(next(&random, 5)) - 2, 0, f32(next(&random, 5)) - 2}
			case 1: eye = {f32(next(&random, 400)) - 200, 12, f32(next(&random, 400)) - 200}
			case 2: toward = linalg.normalize(toward + {f32(next(&random, 3) - 1) * 0.2, 0, 0.1})
			case 3: lights[next(&random, len(lights))].position_range.xz += {f32(next(&random, 9)) - 4, f32(next(&random, 9)) - 4}
			case 4: lights[next(&random, len(lights))].position_range.w = f32(3 + next(&random, 30))
			case 5:
				l := &lights[next(&random, len(lights))]
				l.direction_cone.w = GPU_LIGHT_POINT if l.direction_cone.w > -1.5 else 0.6 + 0.3 * f32(next(&random, 2))
			case 6:
				a, b := next(&random, len(blocks)), next(&random, len(blocks))
				blocks[a], blocks[b] = blocks[b], blocks[a]
			case 7:
				at := next(&random, len(handles))
				place(instances[:], &random)
				handles[at] = set(r, handles[at], box, instances[:next(&random, 12) + 1], &random)
			case 8:
				at := next(&random, len(handles))
				batch_remove(r, handles[at])
				place(instances[:], &random)
				handles[at] = set(r, 0, box, instances[:next(&random, 12) + 1], &random)
			case 9:
				for _ in 0 ..< 4 {
					record := &r.scene.batch.records[next(&random, len(r.scene.batch.records))]
					record.shadow_moving = !record.shadow_moving
				}
				r.scene.shadow_movers_version += 1
			case 10: scene(r, descs[:], box, &random)
			case 11: r.world_key = u64(next(&random, 2))
			case 12: renderer_origin_set(r, {f32(next(&random, 3) - 1) * ORIGIN_STEP * 2, 0, 0})
			case 13: shadow_reach_release(r, view)
			}
		}
		batches_build(r)
		low, high := scene_box(r)
		wants: [SHADOW_SLOTS]Shadow_Want
		plans: [SHADOW_SLOTS]Shadow_Slot_Plan
		levels := shadow_sun_levels(&wants, toward, eye, r.origin, 3000, low, high, low.x <= high.x, view.held[:SHADOW_SUN_LEVELS])
		for &h, k in view.held[:levels] {h = {m = wants[k].m, grid = wants[k].grid}}
		forward := linalg.normalize(Vec3{0, -0.3, -1})
		right := linalg.normalize(linalg.cross(forward, Vec3{0, 1, 0}))
		up := linalg.cross(right, forward)
		for l, light in lights {
			faces: [abi.SHADOW_LIGHT_SLOTS]Shadow_Want
			shadow_light_faces(&faces, l, 0.1, eye, forward, right, up, 1, 0.6, 0.1, low, high, low.x <= high.x)
			for &w, face in faces {
				if w.weight <= 0 {continue}
				slot := SHADOW_SUN_LEVELS + blocks[light] * abi.SHADOW_LIGHT_SLOTS + face
				w.m.rect = {u32(slot), 0, SHADOW_MAP_SIDE, u32(light)}
				wants[slot] = w
			}
		}
		for &p in plans {if next(&random, 8) == 0 {p.flags = abi.SHADOW_PLAN_RESET}}
		// The reach of what sways of the view: none, near, or every map.
		reaches := [3]f32{0, 0.02, max(f32)}
		if next(&random, 8) == 0 {view.sway = reaches[next(&random, 3)]}
		fresh.sway = view.sway
		kept, anew: [SHADOW_SLOTS]Shadow_Reach
		if !testing.expect(t, shadow_reach(r, view, wants[:], plans[:], kept[:])) {return}
		ranges := make([][2]u32, len(r.scene.shadow_ranges), context.temp_allocator)
		copy(ranges, r.scene.shadow_ranges[:])
		shadow_reach_release(r, &fresh)
		if !testing.expect(t, shadow_reach(r, &fresh, wants[:], plans[:], anew[:])) {return}
		same := kept == anew && len(ranges) == len(r.scene.shadow_ranges) && shadow_view_reach(r, view).mover_threads == shadow_view_reach(r, &fresh).mover_threads
		for range, i in ranges {same = same && range == r.scene.shadow_ranges[i]}
		if !testing.expectf(t, same, "frame %d: what was kept differs from what the maps give found anew", frame) {return}
		// None of what a map reaches is left out: the instances of each caster
		// that reaches it lie within a range of its list.
		holds :: proc(ranges: [][2]u32, list: Shadow_Reach_List, first, count: u32) -> bool {
			for range, i in ranges[list.first:][:list.count] {
				past := range.x + ((ranges[list.first + u32(i) + 1].y if u32(i) + 1 < list.count else list.threads) - range.y)
				if first >= range.x && first + count <= past {return true}
			}
			return false
		}
		s := &r.scene
		for w, slot in wants {
			if w.m.rect.z == 0 {continue}
			lists := kept[slot]
			if len(s.instances) > 0 && !testing.expectf(t, holds(ranges, lists[Shadow_Round.Stays], 0, u32(len(s.instances))), "frame %d, slot %d: the instances of the scene are left out", frame, slot) {return}
			for record, k in s.batch.drawn {
				low, high, casts := shadow_batch_box(s, k)
				first, count := shadow_batch_instances(s, k)
				// Of a light, what lies past its range blocks none of what it lights.
				within := slot < SHADOW_SUN_LEVELS || linalg.length(linalg.max(linalg.max(low - w.m.origin, w.m.origin - high), Vec3{})) <= w.m.far
				if casts && within && shadow_map_reaches(w.m, low, high) && !testing.expectf(t, holds(ranges, lists[Shadow_Round.Stays], first, count), "frame %d, slot %d: a batch that casts into the map is left out", frame, slot) {return}
				moving := s.batch.records[record].shadow_moving && casts && within && shadow_change_reaches(w.m, shadow_batch_change(s, k), view.sway, shadow_coarser(view))
				if moving && !testing.expectf(t, holds(ranges, lists[Shadow_Round.Moves], first, count), "frame %d, slot %d: a batch that moves in the map is left out of what moves", frame, slot) {return}
			}
		}
	}
}
