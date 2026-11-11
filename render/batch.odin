package mirai_render

import "core:fmt"
import "mirai:asset"
import "core:math/linalg"
import "mirai:rhi"
import mm "mirai:std/math"
import "mirai:render/abi"

// Instance batches: many instances of one mesh with its materials, drawn by
// the same cull and G-buffer as the instances of the scene and met by the
// same rays, without a row of the instance table for each one.
//
// A batch keeps its instances in the u32 pool of the scene, BATCH_WORDS words
// each, as ranges of the same allocator as the indices of the meshes,
// published with the geometry. The batches of the world shown are drawn: each
// has a row of the instance table after the instances and BATCH_GROUP
// instance slots per group of its instances, which the group table in the
// pool names (scene.slang). The cull runs a thread per slot, which hands the
// clusters of its instance to the cluster pass as an instance of the scene
// does: they share its visible list and its draw. Those that rays meet have a
// tree of their instances in the BLAS nodes while rays are traced by
// software, an item of the software TLAS each, and their instances are
// instances of a native TLAS.

BATCH_GROUP :: abi.BATCH_GROUP
BATCH_WORDS :: abi.BATCH_WORDS
// Instance indices, of the scene and of the slots of batches, that a native
// TLAS tells apart by its custom index.
BATCH_INDICES_MAX :: 1 << 24

// A batch: the index of its record + 1 in the low half, its generation in the high one.
Batch_Handle :: distinct u64

Batch_Flag :: enum u8 {
	Casts_Shadow, // the shadow rays of lights meet its instances
	Ray_Visible,  // the rays of reflections, of the indirect light and of the probe volume see them
	Rays_Only,    // no view draws its instances: only the rays of the flags above meet them
}
Batch_Flags :: bit_set[Batch_Flag;u8]

Batch_Desc :: struct {
	mesh:           Mesh_Handle,
	material:       Material_Handle, // replaces the materials of the mesh's vertices; 0 keeps them
	slot_materials: [32]u32,         // row+1 per source slot; zero inherits
	tint:           Vec3,            // multiplies the base color
	layers:         u32,             // the layers its instances are in; 0: the first one alone
	flags:          Batch_Flags,
	fade_distance:  f32,  // metres from the eye where its instances start to fade out
	cull_distance:  f32,  // metres from the eye where they are gone; 0: never
	vertex:         Vec4, // the four numbers the vertex hook of the shaders reads of it (wind)
	reach:          f32,  // metres the vertex hook moves a point of an instance at most: the boxes the views cull its instances by grow by it
	values:         Vec4, // the four numbers of extensions (instance_values)
	object_id:      u64,  // what its instances give as object id
}

// An instance of a batch as the GPU reads it, 20 bytes: where it is, its
// rotation (quat_pack of std/math, 10 bits a component, under 0.3 degrees)
// and its scale across, along x and z, and along y, half floats. A position
// of the world in f32, as every transform of the renderer; the pool keeps it
// relative to the anchor of its batch.
Batch_Instance :: struct {
	position: Vec3,
	rotation: u32,
	scale:    u32, // across in the low half, along y in the high one
}
#assert(size_of(Batch_Instance) == BATCH_WORDS * 4)

batch_instance :: proc "contextless" (position: Vec3, rotation: mm.Quat, across, along: f32) -> Batch_Instance {
	return {position = position, rotation = u32(mm.quat_pack(rotation, 10)), scale = u32(mm.half_pack(across)) | u32(mm.half_pack(along)) << 16}
}

// The rotation and the scales an instance holds, as the GPU reads them.
batch_instance_unpack :: proc "contextless" (b: Batch_Instance) -> (rotation: mm.Quat, across, along: f32) {
	return mm.quat_unpack(u64(b.rotation), 10), mm.half_unpack(u16(b.scale & 0xffff)), mm.half_unpack(u16(b.scale >> 16))
}

// The transform of an instance, the rows of a 3x4 matrix, as the shaders make it (batch_placement).
batch_instance_rows :: proc "contextless" (b: Batch_Instance) -> [3]Vec4 {
	q, across, along := batch_instance_unpack(b)
	m := mm.quat_to_mat3(q)
	return {
		{m[0, 0] * across, m[0, 1] * along, m[0, 2] * across, b.position.x},
		{m[1, 0] * across, m[1, 1] * along, m[1, 2] * across, b.position.y},
		{m[2, 0] * across, m[2, 1] * along, m[2, 2] * across, b.position.z},
	}
}

@(private)
Batch_Record :: struct {
	generation:             u32,
	used:                   bool,
	gone:                   bool, // its mesh was removed: nothing is drawn until the next batch_set
	world:                  u64,
	desc:                   Batch_Desc,
	count:                  u32,
	words:                  u32, // its instances in the u32 pool, BATCH_WORDS each
	order:                  u32, // the instances of the leaves of its tree, in the pool
	tree, tree_nodes:       u32, // the tree of its instances in the BLAS nodes; no nodes when no ray meets it, or rays are traced by hardware
	// The place of the world, a multiple of ORIGIN_STEP near its instances,
	// that their positions in the pool, its box and its tree are relative to: a jump of the origin moves its row alone (batch_offset).
	anchor:                 Vec3,
	bounds_min, bounds_max: Vec3,
	reach:                  f32, // half the diagonal of the box of its largest instance
	scale:                  f32, // the largest scale of its instances
	small:                  bool, // every instance within SMALL_INSTANCE_REACH of its centre
	drawn:                  i32,  // its row among those drawn; -1 when it is not drawn
}

// The batches of the renderer and the tables of those drawn, which the next
// frame builds again when a batch comes, goes or changes, another world is
// shown or the instances of the scene change in number.
Batch_State :: struct {
	records:         [dynamic]Batch_Record,
	free:            [dynamic]u32,
	drawn:           [dynamic]u32,               // the record of each batch drawn
	rows:            [dynamic]Gpu_Instance,      // the row of each, after the instances of the instance table
	boxes:           [dynamic]Bvh_Item,          // its box
	traced:          [dynamic]u32,               // the batches drawn that rays meet with a tree, an item of the software TLAS each
	hw:              [dynamic]Batch_Hw,          // the batches drawn that rays meet, whose instances a native TLAS holds
	hw_count:        int,                        // those instances
	reflective:      [dynamic]Reflective_Instance, // batches drawn whose materials need the reflectance target, by their index there
	groups:          Pool_Range,                 // the group table in the u32 pool
	slots:           u32,                        // instance slots
	built:           bool,                       // the tables are those of the records
	built_instances: int,                        // for this many instances of the scene
	built_world:     u64,                        // and this world
	bounds_min, bounds_max: Vec3,                // the box of the batches drawn; low above high: none
	upload:          bool,                       // the rows go to the GPU with the next frame
	epoch:           u64,                        // what meshes_clear raises: every batch is gone
	revision:        u64,                        // raised when a batch comes, goes or is set again: what extensions that give batches values compare
	dropped:         int,                        // batches left out of the tables: more instance indices than BATCH_INDICES_MAX
}

// A batch drawn whose instances a native TLAS holds: their first custom
// index past the instances of the scene, the rays that meet them and
// whether their materials are tested.
@(private)
Batch_Hw :: struct {
	record: u32,
	slot:   u32,
	mask:   u8,
	tested: bool,
}

@(private)
batches_init :: proc(r: ^Renderer) {
	b := &r.scene.batch
	a := r.allocator
	b.records = make([dynamic]Batch_Record, a)
	b.free = make([dynamic]u32, a)
	b.drawn = make([dynamic]u32, a)
	b.rows = make([dynamic]Gpu_Instance, a)
	b.boxes = make([dynamic]Bvh_Item, a)
	b.traced = make([dynamic]u32, a)
	b.hw = make([dynamic]Batch_Hw, a)
	b.reflective = make([dynamic]Reflective_Instance, a)
}

@(private)
batches_destroy :: proc(r: ^Renderer) {
	b := &r.scene.batch
	delete(b.records);delete(b.free);delete(b.drawn);delete(b.rows);delete(b.boxes)
	delete(b.traced);delete(b.hw);delete(b.reflective)
	b^ = {}
}

@(private)
batch_index :: proc "contextless" (s: ^Scene_State, handle: Batch_Handle) -> (index: int, ok: bool) {
	index = int(u64(handle) & 0xffffffff) - 1
	if index < 0 || index >= len(s.batch.records) {return}
	record := &s.batch.records[index]
	return index, record.used && record.generation == u32(u64(handle) >> 32)
}

// The classes of rays that meet the instances of a batch (RAY_* of trace.slang).
@(private)
batch_classes :: proc "contextless" (flags: Batch_Flags, small: bool) -> u32 {
	switch {
	case flags >= {.Casts_Shadow, .Ray_Visible}: return RAY_SMALL if small else RAY_SOLID
	case .Casts_Shadow in flags:                 return RAY_SHADOW_ONLY
	case .Ray_Visible in flags:                  return RAY_UNSHADOWED
	}
	return 0
}

// The box in the world of a mesh box under the rows of a transform.
@(private)
rows_bounds :: proc "contextless" (rows: [3]Vec4, low, high: Vec3) -> (Vec3, Vec3) {
	center := (low + high) * 0.5
	half := (high - low) * 0.5
	world, extent: Vec3
	for i in 0 ..< 3 {
		world[i] = rows[i].x * center.x + rows[i].y * center.y + rows[i].z * center.z + rows[i].w
		extent[i] = abs(rows[i].x) * half.x + abs(rows[i].y) * half.y + abs(rows[i].z) * half.z
	}
	return world - extent, world + extent
}

// The light changes around what the instances of a batch block and reflect,
// as around an instance that comes or goes: none for one no ray meets. One
// that casts shadows changes them in its box (occluder_changed).
@(private)
batch_changed_near :: proc(r: ^Renderer, record: ^Batch_Record) {
	if batch_classes(record.desc.flags, record.small) == 0 || record.count == 0 || record.world != r.world_key {return}
	offset := batch_offset(r, record)
	radius := linalg.length(record.bounds_max - record.bounds_min) * 0.5
	scene_changed_near(&r.scene, (record.bounds_min + record.bounds_max) * 0.5 + offset, radius + min(LIGHT_CHANGE_REACH, LIGHT_CHANGE_SIZES * record.reach))
	if .Casts_Shadow in record.desc.flags {occluder_changed(&r.scene, OCCLUDERS_MANY, record.bounds_min + offset, record.bounds_max + offset)}
}

// Where the anchor of a batch is from the origin: what takes its instances,
// box and tree to the places the renderer keeps. Exact: both are
// multiples of ORIGIN_STEP.
@(private)
batch_offset :: #force_inline proc "contextless" (r: ^Renderer, record: ^Batch_Record) -> Vec3 {return record.anchor - r.origin}

@(private)
batch_release :: proc(s: ^Scene_State, record: ^Batch_Record) {
	if record.count > 0 {pool_release(&s.indices, &s.pool_free[.Index], record.words, record.count * BATCH_WORDS)}
	batch_tree_release(s, record)
	record.count = 0
}

@(private)
batch_tree_release :: proc(s: ^Scene_State, record: ^Batch_Record) {
	if record.tree_nodes == 0 {return}
	pool_release(&s.indices, &s.pool_free[.Index], record.order, record.count)
	pool_release(&s.blas_nodes, &s.pool_free[.Node], record.tree, record.tree_nodes)
	record.tree_nodes = 0
}

// The tree of the instances of a batch rays meet, for rays traced by
// software: a SAH tree of their boxes in the BLAS nodes, whose leaves name
// them through the order it keeps in the u32 pool.
@(private)
batch_tree_build :: proc(r: ^Renderer, record: ^Batch_Record) {
	s := &r.scene
	if record.count == 0 || record.tree_nodes > 0 || batch_classes(record.desc.flags, false) == 0 {return}
	mesh := s.meshes[record.desc.mesh]
	items, items_error := make([]Bvh_Item, record.count, r.allocator)
	if items_error != nil {set_error(r, "batch tree of %d instances: out of memory", record.count);return}
	defer delete(items, r.allocator)
	for &item, k in items {
		words := s.indices[record.words + u32(k) * BATCH_WORDS:][:BATCH_WORDS]
		instance := transmute(Batch_Instance)[BATCH_WORDS]u32{words[0], words[1], words[2], words[3], words[4]}
		a, z := rows_bounds(batch_instance_rows(instance), mesh.bounds_min, mesh.bounds_max)
		item = {bounds_min = a, bounds_max = z, center = (a + z) * 0.5}
	}
	nodes := make([dynamic]Gpu_Bvh_Node, 0, 0, r.allocator)
	order := make([dynamic]u32, 0, 0, r.allocator)
	defer delete(nodes)
	defer delete(order)
	if !bvh_build(items, 2, &nodes, &order) {set_error(r, "batch tree of %d instances: out of memory", record.count);return}
	if !pool_room(r, .Index, len(order)) || !pool_room(r, .Node, len(nodes)) {s.refused.batches += 1;return}
	first := u32(len(s.indices))
	append(&s.indices, ..order[:])
	record.order = pool_store(&s.indices, &s.pool_free[.Index], &s.pool_dirty[.Index], first)
	node_first := u32(len(s.blas_nodes))
	append(&s.blas_nodes, ..nodes[:])
	record.tree_nodes = u32(len(nodes))
	record.tree = pool_store(&s.blas_nodes, &s.pool_free[.Node], &s.pool_dirty[.Node], node_first)
	s.geometry_dirty = true
	s.batch.built = false
}

// The trees of the batches rays meet, once rays are traced by software.
@(private)
batches_trees_build :: proc(r: ^Renderer) {
	for &record in r.scene.batch.records {
		if record.used {batch_tree_build(r, &record)}
	}
}

// Gives a batch its mesh, its materials, how it is drawn and traced, and its
// instances: a new batch for handle 0, or the batch handle names, which
// keeps it. world: the key of the world it belongs to, as scene_world names
// it; a frame draws the batches of the world shown. A load transaction: the
// instances go to the u32 pool of the scene with the geometry, and those
// rays meet get the tree rays walk. The light changes around the instances
// rays met and those they meet now. On an error, which says what is wrong
// and how to fix it, nothing changes.
batch_set :: proc(r: ^Renderer, handle: Batch_Handle, world: u64, desc: Batch_Desc, instances: []Batch_Instance) -> (Batch_Handle, string) {
	s := &r.scene
	b := &s.batch
	index := -1
	if handle != 0 {
		found, ok := batch_index(s, handle)
		if !ok {return handle, "batch_set: the handle names no batch of the renderer; pass 0 for a new batch"}
		index = found
	}
	if int(desc.mesh) >= len(s.meshes) || s.meshes[desc.mesh].vertex_count == 0 {
		return handle, "batch_set: the mesh is not one of the renderer; give it a handle that mesh_add or the assets returned"
	}
	if len(instances) > BATCH_INDICES_MAX {
		return handle, fmt.tprintf("batch_set: %d instances, more than the %d a batch holds; split them in several batches", len(instances), BATCH_INDICES_MAX)
	}
	finite :: proc "contextless" (v: f32) -> bool {return v - v == 0}
	if !finite(desc.fade_distance) || !finite(desc.cull_distance) || desc.fade_distance < 0 || desc.cull_distance < 0 {
		return handle, "batch_set: a fade or cull distance is negative or not finite; give 0 or more metres (a cull distance of 0 never culls)"
	}
	if .Rays_Only in desc.flags && desc.flags & {.Casts_Shadow, .Ray_Visible} == {} {
		return handle, "batch_set: no ray meets a batch of Rays_Only and no view draws it; give it Casts_Shadow or Ray_Visible, or take Rays_Only out"
	}
	for value in desc.vertex {if !finite(value) {return handle, "batch_set: a number of Batch_Desc.vertex is not finite"}}
	if !finite(desc.reach) || desc.reach < 0 {return handle, "batch_set: Batch_Desc.reach is negative or not finite; give the metres the vertex hook moves a point at most, or 0"}
	for value in desc.values {if !finite(value) {return handle, "batch_set: a number of Batch_Desc.values is not finite"}}
	for instance, i in instances {
		_, across, along := batch_instance_unpack(instance)
		if !finite(instance.position.x) || !finite(instance.position.y) || !finite(instance.position.z) {
			return handle, fmt.tprintf("batch_set: instance %d has a position that is not finite", i)
		}
		if !(across > 0) || !(along > 0) || !finite(across) || !finite(along) {
			return handle, fmt.tprintf("batch_set: instance %d has a scale of %v across and %v along y; give scales above 0 and below 65504", i, across, along)
		}
	}
	// The instances and, at most, their order for the tree; a batch it
	// replaces gives its words back only after.
	if !pool_room(r, .Index, len(instances) * (BATCH_WORDS + 1)) {
		s.refused.batches += 1
		return handle, fmt.tprintf("batch_set: the GPU has no memory for %d instances (renderer_stats().problem says what it holds); fewer sections loaded at once or fewer instances avoid it", len(instances))
	}
	mesh := s.meshes[desc.mesh]
	if index < 0 {
		if len(b.free) > 0 {index = int(pop(&b.free))} else {
			append(&b.records, Batch_Record{drawn = -1})
			index = len(b.records) - 1
		}
	} else {
		record := &b.records[index]
		batch_changed_near(r, record)
		batch_release(s, record)
	}
	record := &b.records[index]
	record.used, record.gone, record.world, record.desc, record.count = true, false, world, desc, u32(len(instances))
	record.bounds_min, record.bounds_max, record.reach, record.small, record.scale = {}, {}, 0, true, 0
	// The anchor: the multiple of ORIGIN_STEP nearest the middle of their positions.
	low, high := Vec3{max(f32), max(f32), max(f32)}, Vec3{min(f32), min(f32), min(f32)}
	for given in instances {low, high = linalg.min(low, given.position), linalg.max(high, given.position)}
	record.anchor = origin_snap(low * 0.5 + high * 0.5) if len(instances) > 0 else {}
	low, high = {1e30, 1e30, 1e30}, {-1e30, -1e30, -1e30}
	first := u32(len(s.indices))
	for given in instances {
		instance := given
		instance.position = origin_point(given.position, record.anchor)
		a, z := rows_bounds(batch_instance_rows(instance), mesh.bounds_min, mesh.bounds_max)
		low, high = linalg.min(low, a), linalg.max(high, z)
		reach := linalg.length(z - a) * 0.5
		record.reach = max(record.reach, reach)
		_, across, along := batch_instance_unpack(given)
		record.scale = max(record.scale, abs(across), abs(along))
		record.small &&= reach <= SMALL_INSTANCE_REACH
		words := transmute([BATCH_WORDS]u32)instance
		append(&s.indices, ..words[:])
	}
	record.words = 0
	if len(instances) > 0 {
		record.bounds_min, record.bounds_max = low, high
		record.words = pool_store(&s.indices, &s.pool_free[.Index], &s.pool_dirty[.Index], first)
	}
	if !r.hardware_rt {batch_tree_build(r, record)}
	batch_changed_near(r, record)
	s.geometry_dirty = true
	b.built = false
	b.revision += 1
	return Batch_Handle(u64(record.generation) << 32 | u64(index + 1)), ""
}

// Takes a batch out of the renderer: its instances leave the pool and the
// light changes around those rays met. False for a handle that names none.
batch_remove :: proc(r: ^Renderer, handle: Batch_Handle) -> bool {
	s := &r.scene
	index, ok := batch_index(s, handle)
	if !ok {return false}
	record := &s.batch.records[index]
	batch_changed_near(r, record)
	geometry_released(s, u64(record.count) * (BATCH_WORDS + 1) * 4)
	batch_release(s, record)
	generation := record.generation + 1
	record^ = {generation = generation, drawn = -1}
	append(&s.batch.free, u32(index))
	s.geometry_dirty = true
	s.batch.built = false
	s.batch.revision += 1
	return true
}

// The batches of the renderer, and the instances they hold.
batch_count :: proc(r: ^Renderer) -> (batches, instances: int) {
	for record in r.scene.batch.records {
		if !record.used {continue}
		batches += 1
		instances += int(record.count)
	}
	return
}

// Appends the material rows the live batches draw with: their material and,
// row+1, those of their slots.
batches_materials :: proc(r: ^Renderer, out: ^[dynamic]u32) {
	for &record in r.scene.batch.records {
		if !record.used {continue}
		append(out, u32(record.desc.material))
		for row in record.desc.slot_materials {if row > 0 {append(out, row - 1)}}
	}
}

// Raised by meshes_clear, which forgets every batch: whoever set them sets them again.
batches_epoch :: proc(r: ^Renderer) -> u64 {return r.scene.batch.epoch}

// The batches of a mesh that is removed draw nothing until they are set again.
@(private)
batches_mesh_removed :: proc(s: ^Scene_State, mesh: Mesh_Handle) {
	for &record in s.batch.records {
		if record.used && record.desc.mesh == mesh {record.gone = true;s.batch.built = false}
	}
}

// Every batch is forgotten along with the pools (meshes_clear).
@(private)
batches_clear :: proc(s: ^Scene_State) {
	b := &s.batch
	for &record in b.records {record = {generation = record.generation + 1, drawn = -1}}
	clear(&b.free)
	#reverse for _, i in b.records {append(&b.free, u32(i))}
	b.groups = {}
	b.built = false
	b.epoch += 1
	b.revision += 1
}

// The tables of the batches drawn, when a batch, the world shown or the
// number of instances changed: rows, draw template, group table, the native
// TLAS instances of those rays meet and the software TLAS with their trees.
@(private)
batches_build :: proc(r: ^Renderer) {
	s := &r.scene
	b := &s.batch
	if b.built && b.built_instances == len(s.instances) && b.built_world == r.world_key {return}
	clear(&b.drawn);clear(&b.rows);clear(&b.boxes);clear(&b.traced);clear(&b.hw);clear(&b.reflective)
	if b.groups.count > 0 {pool_release(&s.indices, &s.pool_free[.Index], b.groups.first, b.groups.count)}
	b.groups = {}
	b.slots, b.dropped, b.hw_count = 0, 0, 0
	b.bounds_min, b.bounds_max = {1e30, 1e30, 1e30}, {-1e30, -1e30, -1e30}
	for &record in b.records {record.drawn = -1}
	instance_count := u32(len(s.instances))
	// A word of the group table for each group of BATCH_GROUP instances.
	group_words := 0
	for record in b.records {if record.used && !record.gone && record.world == r.world_key {group_words += int(record.count + BATCH_GROUP - 1) / BATCH_GROUP}}
	room := pool_room(r, .Index, group_words)
	if !room {s.refused.batches = max(s.refused.batches, len(b.records) - len(b.free))}
	group_first := u32(len(s.indices))
	for &record, index in b.records {
		if !room || !record.used || record.gone || record.world != r.world_key || record.count == 0 {continue}
		// A mesh whose geometry still goes to the GPU is drawn once it is there (mesh_shown).
		if int(record.desc.mesh) >= len(s.meshes) || s.meshes[record.desc.mesh].vertex_count == 0 || mesh_pending(s, u32(record.desc.mesh)) {continue}
		groups := (record.count + BATCH_GROUP - 1) / BATCH_GROUP
		if u64(instance_count) + u64(b.slots) + u64(groups) * BATCH_GROUP > BATCH_INDICES_MAX {b.dropped += 1;continue}
		drawn := u32(len(b.drawn))
		mesh := s.meshes[record.desc.mesh]
		desc := &record.desc
		material := u32(desc.material) if desc.material != 0 && int(desc.material) < len(s.materials) else GPU_NONE
		slots := desc.slot_materials
		for &row in slots {if row > u32(len(s.materials)) {row = 0}}
		tested, _, glass, reflectance, layered, _, _ := instance_alpha(s, mesh, material, slots)
		// A batch draws no glass: blended triangles leave the G-buffer, and
		// one all of glass is neither drawn nor traced.
		classes := batch_classes(desc.flags, record.small) if !glass else 0
		layers := desc.layers & LAYERS_ALL if desc.layers & LAYERS_ALL != 0 else 1
		// In no layer, no view draws them: rays alone meet a batch of Rays_Only.
		if .Rays_Only in desc.flags {layers = 0}
		flags := layers << INSTANCE_LAYERS_SHIFT | alpha_flags(tested, false, glass)
		record.drawn = i32(drawn)
		append(&b.drawn, u32(index))
		offset := batch_offset(r, &record)
		low, high := record.bounds_min + offset, record.bounds_max + offset
		append(&b.rows, Gpu_Instance{
			world = {
				{bits(record.words), bits(record.count), bits(b.slots), bits(record.tree)},
				{bits(record.order), desc.fade_distance, desc.cull_distance, 0},
				{0, 0, 0, bits(classes)},
			},
			world_inv = {desc.vertex, {offset.x, offset.y, offset.z, desc.reach}, {}},
			// Rays meet the instances of a batch in the cut its mesh always has.
			meta = {u32(desc.mesh) | (u32(ray_cut_always(s.meshes[desc.mesh])) << INSTANCE_RAY_SHIFT if int(desc.mesh) < len(s.meshes) else 0), material, u32(desc.object_id), flags},
			bounds_min = {low.x, low.y, low.z, desc.values.z},
			bounds_max = {high.x, high.y, high.z, desc.values.w},
			tint = {desc.tint.x, desc.tint.y, desc.tint.z, desc.values.x},
			emission = {0, 0, 0, desc.values.y},
			slot_materials = slots,
		})
		append(&b.boxes, Bvh_Item{bounds_min = low, bounds_max = high, center = (low + high) * 0.5})
		b.bounds_min, b.bounds_max = linalg.min(b.bounds_min, low), linalg.max(b.bounds_max, high)
		if reflectance && !glass && layers != 0 {append(&b.reflective, Reflective_Instance{drawn, layered})}
		for _ in 0 ..< groups {append(&s.indices, drawn)}
		if classes != 0 {
			if record.tree_nodes > 0 {append(&b.traced, drawn)}
			if r.hardware_rt {
				append(&b.hw, Batch_Hw{record = u32(index), slot = b.slots, mask = u8(classes), tested = tested})
				b.hw_count += int(record.count)
			}
		}
		b.slots += groups * BATCH_GROUP
	}
	count := u32(len(s.indices)) - group_first
	if count > 0 {b.groups = {pool_store(&s.indices, &s.pool_free[.Index], &s.pool_dirty[.Index], group_first), count}}
	s.geometry_dirty = true
	b.built, b.built_instances, b.built_world = true, len(s.instances), r.world_key
	b.upload = true
	tlas_build(s)
	s.tlas_nodes_dirty, s.tlas_refs_dirty, s.tlas_dirty = true, true, true
}

// The box of what the frame draws and rays meet, relative to the origin: its
// instances and the batches drawn. Low above high: nothing.
@(private)
scene_box :: proc "contextless" (r: ^Renderer) -> (low, high: Vec3) {
	s := &r.scene
	low, high = s.batch.bounds_min, s.batch.bounds_max
	if s.has_bounds {low, high = linalg.min(low, s.bounds_min), linalg.max(high, s.bounds_max)}
	return
}

@(private = "file")
bits :: #force_inline proc "contextless" (v: u32) -> f32 {return transmute(f32)v}

// The box of a reference of the software TLAS: an instance, or past them a batch drawn.
@(private)
tlas_item :: proc "contextless" (s: ^Scene_State, ref: u32) -> ^Bvh_Item {
	index := int(ref &~ TLAS_REF_GLASS)
	if index < len(s.tlas_items) {return &s.tlas_items[index]}
	return &s.batch.boxes[index - len(s.instances)]
}

// The rows of the batches drawn go after the instances in the instance table.
@(private)
batches_upload :: proc(r: ^Renderer, cmd: ^rhi.Command_List, with_instances: bool) -> bool {
	s := &r.scene
	b := &s.batch
	if !b.upload && !with_instances {return true}
	if !upload_transient(r, cmd, b.rows[:], s.instance_buffer, u64(len(s.instances)) * size_of(Gpu_Instance)) {return false}
	b.upload = false
	return true
}
// The mask and the flags of an instance of the native TLAS.
@(private)
tlas_mask_flags :: #force_inline proc "contextless" (mask: u8, tested: bool) -> u32 {
	return u32(mask) | (rhi.TLAS_ALPHA_TESTED if tested else 0)
}

// A batch rays meet, as the compute that writes the instances of the native
// TLAS reads it (tlas_batches.comp).
@(private)
Gpu_Tlas_Batch :: struct {
	words, first, custom, blas, mask_flags: u32,
	pad:                                    [3]u32,
	anchor:                                 Vec4,
}
#assert(size_of(Gpu_Tlas_Batch) == 48)
@(private)
Tlas_Batches_Params :: struct {jobs, first, total, pad: u32}

// The instances of the native TLAS in its buffer: those of the scene, each
// with the BLAS of the cut its rays trace, from the CPU; then those of the
// batches drawn that rays meet, written on the GPU from their places in the
// pool. How many, or -1 when they could not be written.
@(private)
tlas_instances_record :: proc(r: ^Renderer, cmd: ^rhi.Command_List) -> int {
	s := &r.scene
	d := r.device
	for &h, i in s.hw_instances {
		mesh := s.instances[i].meta.x
		rays := &s.meshes[mesh & INSTANCE_MESH_MASK].rays
		blas := rays[mesh >> INSTANCE_RAY_SHIFT & 3].blas
		if blas == 0 {blas = rays[ray_cut_always(s.meshes[mesh & INSTANCE_MESH_MASK])].blas}
		h.blas = rhi.accel_id(d, blas)
	}
	scene := len(s.hw_instances)
	total := scene + s.batch.hw_count
	if total > int(s.tlas_capacity) || s.tlas_instance_buffer == 0 {return -1}
	if !upload_transient(r, cmd, s.hw_instances[:], s.tlas_instance_buffer) {return -1}
	if len(s.batch.hw) == 0 {return scene}
	jobs := rhi.frame_alloc(d, u64(len(s.batch.hw)) * size_of(Gpu_Tlas_Batch), 16)
	if jobs.ptr == nil {return -1}
	rows := ([^]Gpu_Tlas_Batch)(jobs.ptr)[:len(s.batch.hw)]
	first := u32(len(s.instances))
	at := u32(scene)
	for hw, k in s.batch.hw {
		record := &s.batch.records[hw.record]
		offset := batch_offset(r, record)
		rows[k] = {
			words = record.words, first = at, custom = first + hw.slot, blas = rhi.accel_id(d, s.meshes[record.desc.mesh].rays[ray_cut_always(s.meshes[record.desc.mesh])].blas),
			mask_flags = tlas_mask_flags(hw.mask, hw.tested), anchor = {offset.x, offset.y, offset.z, 0},
		}
		at += record.count
	}
	params := Tlas_Batches_Params{jobs = u32(len(rows)), first = u32(scene), total = u32(s.batch.hw_count)}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Tlas_Batches])
	rhi.cmd_bind_transient(cmd, SLOT_PASS0, jobs)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, s.tlas_instance_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_INDICES, s.index_buffer)
	set_params(cmd, &params)
	rhi.cmd_barrier_buffer(cmd, s.index_buffer, .Shader_Read)
	rhi.cmd_barrier_buffer(cmd, s.tlas_instance_buffer, .Shader_Write)
	batch_groups := groups(u32(s.batch.hw_count), 64)
	rhi.cmd_dispatch(cmd, min(batch_groups, rhi.TLAS_DISPATCH_X), (batch_groups + rhi.TLAS_DISPATCH_X - 1) / rhi.TLAS_DISPATCH_X)
	return total
}

// Gives a batch the four numbers of extensions (Batch_Desc.values, what
// instance_values reads), as an extension that is not its owner gives them:
// its row changes in place, without building the tables again, and it
// keeps them until it is set again. False for a handle that names no batch
// or a value that is not finite.
batch_values_set :: proc(r: ^Renderer, handle: Batch_Handle, values: Vec4) -> bool {
	s := &r.scene
	index, ok := batch_index(s, handle)
	if !ok {return false}
	for value in values {if value - value != 0 {return false}}
	record := &s.batch.records[index]
	if record.desc.values == values {return true}
	record.desc.values = values
	if s.batch.built && record.drawn >= 0 && int(record.drawn) < len(s.batch.rows) {
		row := &s.batch.rows[record.drawn]
		row.tint.w, row.emission.w, row.bounds_min.w, row.bounds_max.w = values.x, values.y, values.z, values.w
		s.batch.upload = true
	}
	return true
}

// What a batch is, as whoever goes through the batches reads it.
Batch_Info :: struct {
	handle:    Batch_Handle,
	world:     u64,
	object_id: u64,
	values:    Vec4,
	mesh:      Mesh_Handle,
	count:     int,
}

// The batch of a record, to go through every one from 0 to batch_records:
// false for a record that holds none.
batch_info :: proc(r: ^Renderer, index: int) -> (info: Batch_Info, ok: bool) {
	records := r.scene.batch.records[:]
	if index < 0 || index >= len(records) || !records[index].used {return}
	record := &records[index]
	return {handle = Batch_Handle(u64(record.generation) << 32 | u64(index + 1)), world = record.world, object_id = record.desc.object_id, values = record.desc.values, mesh = record.desc.mesh, count = int(record.count)}, true
}

batch_records :: proc(r: ^Renderer) -> int {return len(r.scene.batch.records)}

// Raised when a batch comes, goes or is set again, or every one is forgotten.
batches_revision :: proc(r: ^Renderer) -> u64 {return r.scene.batch.revision}

// The instance of a batch of a world that a ray meets first, within
// max_distance, on the triangles of the first level of its mesh, at rest:
// what the picker of an editor asks. The batch box, then the box of each
// instance, keep the triangles of most of them out. A batch of Rays_Only,
// which no view draws, is not met.
Batch_Hit :: struct {
	handle:    Batch_Handle,
	instance:  int,
	distance:  f32,
	normal:    Vec3, // in the world, against the ray
	object_id: u64,
}

batch_ray :: proc(r: ^Renderer, world: u64, origin, direction: Vec3, max_distance: f32) -> (hit: Batch_Hit, found: bool) {
	s := &r.scene
	d := linalg.normalize0(direction)
	if d == {} {return}
	inverse := Vec3{1 / d.x, 1 / d.y, 1 / d.z}
	nearest := max_distance
	for &record, index in s.batch.records {
		if !record.used || record.gone || record.world != world || record.count == 0 || .Rays_Only in record.desc.flags {continue}
		if int(record.desc.mesh) >= len(s.meshes) || s.meshes[record.desc.mesh].vertex_count == 0 || mesh_pending(s, u32(record.desc.mesh)) {continue}
		origin := origin_point(origin, record.anchor)
		if t, crossed := mm.ray_aabb_fast(origin, inverse, {record.bounds_min, record.bounds_max}, nearest); !crossed || t > nearest {continue}
		mesh := s.meshes[record.desc.mesh]
		for k in 0 ..< record.count {
			words := s.indices[record.words + k * BATCH_WORDS:][:BATCH_WORDS]
			rows := batch_instance_rows(transmute(Batch_Instance)[BATCH_WORDS]u32{words[0], words[1], words[2], words[3], words[4]})
			low, high := rows_bounds(rows, mesh.bounds_min, mesh.bounds_max)
			if t, crossed := mm.ray_aabb_fast(origin, inverse, {low, high}, nearest); !crossed || t > nearest {continue}
			m := Mat4{rows[0].x, rows[0].y, rows[0].z, rows[0].w, rows[1].x, rows[1].y, rows[1].z, rows[1].w, rows[2].x, rows[2].y, rows[2].z, rows[2].w, 0, 0, 0, 1}
			to_local := linalg.inverse(m)
			local := mm.Ray{(to_local * Vec4{origin.x, origin.y, origin.z, 1}).xyz, (to_local * Vec4{d.x, d.y, d.z, 0}).xyz}
			p := record_pooled(s, mesh)
			_, level0 := record_level(s, mesh, 0)
			for ordinal in 0 ..< level0 {
				g, cluster, resident := pooled_cluster(p, ordinal)
				if !resident {continue}
				for triangle in 0 ..< asset.cluster_triangle_count(cluster) {
					a, b, c := cluster_triangle_positions(g, cluster, triangle)
					// t along the local ray is the distance in the world: its direction is the world's, unscaled.
					t, _, crossed := mm.ray_triangle(local, {a, b, c})
					if !crossed || t >= nearest || t < 0 {continue}
					nearest, found = t, true
					face := linalg.cross(b - a, c - a)
					n := linalg.normalize0((linalg.transpose(to_local) * Vec4{face.x, face.y, face.z, 0}).xyz)
					if linalg.dot(n, d) > 0 {n = -n}
					hit = {handle = Batch_Handle(u64(record.generation) << 32 | u64(index + 1)), instance = int(k), distance = t, normal = n, object_id = record.desc.object_id}
				}
			}
		}
	}
	return
}
