package mirai_render

import "core:math"
import "core:math/linalg"
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
		packed := batch_instance({12.5, -3, 1000}, q, 0.8, 1.6)
		back, across, along := batch_instance_unpack(packed)
		testing.expect(t, mm.quat_angle(q, back) < 0.3 * math.PI / 180, "the rotation comes back within 0.3 degrees")
		testing.expect(t, abs(across - 0.8) < 1e-3 && abs(along - 1.6) < 1e-3, "the scales come back as half floats")
		// The rows are the rotation of the scaled axes and the position, as batch_placement makes them.
		rows := batch_instance_rows(packed)
		x := mm.quat_rotate(back, {0.8 * across / 0.8, 0, 0})
		y := mm.quat_rotate(back, {0, along, 0})
		testing.expect(t, linalg.length(Vec3{rows[0].x, rows[1].x, rows[2].x} - x) < 1e-4 && linalg.length(Vec3{rows[0].y, rows[1].y, rows[2].y} - y) < 1e-4)
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
	instances := [3]Batch_Instance{batch_instance({0, 0, 0}, 1, 1, 1), batch_instance({4, 0, 0}, 1, 1, 2), batch_instance({8, 0, 0}, 1, 2, 1)}
	handle, error := batch_set(r, 0, 0, {mesh = mesh, tint = 1}, instances[:])
	if !testing.expect_value(t, error, "") {return}
	testing.expect_value(t, len(r.scene.indices), pool + 3 * BATCH_WORDS)
	batches, held := batch_count(r)
	testing.expect(t, batches == 1 && held == 3)
	// Replacing keeps the handle and the words of the pool.
	again, replaced := batch_set(r, handle, 0, {mesh = mesh, tint = 1}, instances[:2])
	testing.expect(t, replaced == "" && again == handle)
	testing.expect_value(t, len(r.scene.indices), pool + 2 * BATCH_WORDS)
	words := r.scene.indices[r.scene.batch.records[0].words:][:BATCH_WORDS]
	testing.expect_value(t, transmute(Batch_Instance)[BATCH_WORDS]u32{words[0], words[1], words[2], words[3], words[4]}, instances[0])
	// Wrong input says what is wrong and leaves the batch as it was.
	bad_scale := [1]Batch_Instance{batch_instance({0, 0, 0}, 1, 0, 1)}
	infinite := math.inf_f32(1)
	bad_position := [1]Batch_Instance{batch_instance({infinite, 0, 0}, 1, 1, 1)}
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
	for &b, i in many {b = batch_instance({f32(i) * 2, 0, 0}, 1, 1, 1)}
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
	instances := [2]Batch_Instance{batch_instance({0, 0, 0}, 1, 1, 1), batch_instance({30, 0, 0}, 1, 1, 1)}
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
	instances := [1]Batch_Instance{batch_instance({0, 0, 0}, 1, 1, 1)}
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
	for &b, i in instances {b = batch_instance({f32(i % 6) * 3, 0, f32(i / 6) * 3}, 1, 1, 1)}
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
	testing.expect(t, batch_remove(r, handle))
}

@(test)
a_batch_says_what_it_is_and_its_revision_moves_when_it_is_set_again :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	mesh := batch_box(r)
	instances := [2]Batch_Instance{batch_instance({0, 0, 0}, 1, 1, 1), batch_instance({3, 0, 0}, 1, 1, 1)}
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
	instances := [3]Batch_Instance{batch_instance({0, 0, 0}, 1, 1, 1), batch_instance({4, 0, 0}, 1, 1, 3), batch_instance({8, 0, 0}, 1, 2, 1)}
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
	instances := [2]Batch_Instance{batch_instance({0, 0, 0}, 1, 1, 1), batch_instance({4, 0, 0}, 1, 1, 1)}
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
	instances := [3]Batch_Instance{batch_instance(far, 1, 1, 1), batch_instance(far + {4, 0, 0}, 1, 1, 2), batch_instance(far + {0, 0, 9}, 1, 2, 1)}
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
	rows := batch_instance_rows(transmute(Batch_Instance)[BATCH_WORDS]u32{words[5], words[6], words[7], words[8], words[9]})
	place := Vec3{rows[0].w, rows[1].w, rows[2].w} + offset
	testing.expect_value(t, place, origin_point(far + {4, 0, 0}, renderer_origin(r)))
	testing.expect(t, row.bounds_min.x <= place.x - 0.5 && row.bounds_max.z >= origin_point(far, renderer_origin(r)).z + 9.5)
	// So does a ray of the CPU.
	hit, found := batch_ray(r, 0, far + {4, 10, 0}, {0, -1, 0}, 100)
	testing.expect(t, found && hit.instance == 1 && abs(hit.distance - 9) < 1e-3)
	testing.expect(t, batch_remove(r, handle))
}
