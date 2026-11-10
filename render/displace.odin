package mirai_render

import "mirai:rhi"
import "mirai:std/base"

// Surface programs that move vertices (`//! vertex`, Program_Vertex). An
// instance whose materials have one shows a pose of its own of its mesh
// (Skin_State.displaced): a copy of level 0 with current and previous
// vertices, which the stage of each of those programs writes from the rest of
// its clusters (surface_vertices__<program>.comp) before the Geometry stage of
// a frame in which what it reads changed: the transform of the instance, the
// rows of its materials (its parameters, those of a Material_Override too)
// and, of an animated program, the time. The previous vertices are those the
// frame before showed. Raster, shadows, rays (the pose's tree and BLAS, refit
// like a skin's), culling (its box grows by the reach of the programs) and
// motion vectors read that geometry; no pass moves vertices of its own. A
// skinned instance is moved in place after its skin, the current and the
// previous vertices at their own time and transform. A deformable an extension
// writes, and the instances of batches, are drawn as they are. Until the
// pipeline of a program is made, its vertices stay where they were.

@(private)
Instance_Vertex :: struct {
	moves, animated: bool,
	reach:           f32, // the largest of its programs, in the space of the mesh
	inputs:          u64, // what its vertices are moved from
}

// What the programs of the materials of an instance of mesh do to its
// vertices. material: the row in place of the slots' (GPU_NONE: theirs).
@(private)
instance_vertex :: proc(r: ^Renderer, mesh: Mesh_Record, material: u32, slots: [32]u32) -> (v: Instance_Vertex) {
	s := &r.scene
	palette := slots
	v.inputs = base.HASH_SEED
	for packed in s.indices[mesh.slot_word:][:mesh.slot_count] {
		row := instance_row(packed, material, &palette)
		if int(row) >= len(s.materials) || s.materials[row].program_id == 0 {continue}
		values := &s.materials[row]
		program := program_of_id(r, values.program_id)
		if program == nil || program.domain != .Surface || !program.vertex.declared {continue}
		v.moves = true
		v.animated ||= program.vertex.animated
		reach := program.vertex.reach
		if offset := program.vertex.reach_offset; offset >= 0 {
			words := transmute([PROGRAM_PARAMETER_BYTES / 4]u32)values.custom_params
			reach = transmute(f32)words[offset / 4]
			if !(reach >= 0) || reach > 1e30 {reach = 0}
		}
		v.reach = max(v.reach, reach)
		version := s.material_versions[row] if int(row) < len(s.material_versions) else 0
		v.inputs = base.hash_mix(base.hash_mix(v.inputs, u64(row)), u64(version))
	}
	return
}

// Whether a mesh is the pose of an instance whose programs move its vertices.
@(private)
mesh_displaced :: proc "contextless" (s: ^Scene_State, mesh: u32) -> bool {
	return int(mesh) < len(s.meshes) && s.meshes[mesh].skin != nil && s.meshes[mesh].skin.displaced
}

// The mesh an instance shows: its pose when its programs move its vertices
// and it has one of that mesh. One it lacks, or has and no longer needs,
// waits for displaced_reconcile.
@(private)
displaced_mesh :: proc(r: ^Renderer, desc: Instance_Desc) -> Mesh_Handle {
	s := &r.scene
	source := s.meshes[desc.mesh]
	// A pose is moved in place, after its skin, or shown as its extension writes it.
	if source.skin != nil {return desc.mesh}
	material := u32(desc.material) if desc.material != 0 && int(desc.material) < len(s.materials) else GPU_NONE
	slots := desc.slot_materials
	for &row in slots {if row > u32(len(s.materials)) {row = 0}}
	wants := instance_vertex(r, source, material, slots).moves
	pose, has := s.displaced[Instance_Key{desc.object_id, desc.copy_owner, desc.copy_variant}]
	if has && wants && mesh_displaced(s, u32(pose)) && s.meshes[pose].skin.source == desc.mesh {return pose}
	if has || wants {s.displaced_stale = true}
	return desc.mesh
}

// A pose of source for an instance whose programs move its vertices; false
// while the geometry of source still goes to the GPU.
@(private)
displaced_create :: proc(r: ^Renderer, source: Mesh_Handle) -> (Mesh_Handle, bool) {
	s := &r.scene
	if int(source) >= len(s.meshes) || mesh_pending(s, u32(source)) {return 0, false}
	mesh_filled(s, u32(source))
	original := s.meshes[source]
	if original.skin != nil || original.vertex_count == 0 {return 0, false}
	skin, error := new(Skin_State, r.allocator)
	if error != nil {return 0, false}
	skin.allocator, skin.displaced, skin.fresh, skin.source = r.allocator, true, true, source
	skin.binding, error = new(Skin_Binding, r.allocator)
	if error != nil {free(skin, r.allocator); return 0, false}
	skin.binding.allocator, skin.binding.references = r.allocator, 1
	posed, _ := level0_vertices(s, original)
	// Current, then previous.
	handle, ok := pose_store(r, original, posed, 2, skin)
	if !ok {skin_free(r, skin); return 0, false}
	return handle, true
}

// An instance shows another mesh, its pose or its source, with its box.
@(private = "file")
displaced_swap :: proc(r: ^Renderer, index: u32, mesh: Mesh_Handle) {
	s := &r.scene
	inst := &s.instances[index]
	old := inst.meta.x & INSTANCE_MESH_MASK
	before, after := s.instance_prev[index], s.instance_next[index]
	if before >= 0 {s.instance_next[before] = after} else if s.meshes[old].first_instance == i32(index) {s.meshes[old].first_instance = after}
	if after >= 0 {s.instance_prev[after] = before}
	m := &s.meshes[mesh]
	head := m.first_instance
	s.instance_next[index], s.instance_prev[index] = head, -1
	if head >= 0 {s.instance_prev[head] = i32(index)}
	m.first_instance = i32(index)
	inst.meta.x = u32(mesh) | u32(ray_cut_always(m^)) << INSTANCE_RAY_SHIFT
	s.ray_cuts_stale = true
	r.textures.residency.stale = true
	if !pose_instance_box(s, index) {
		instance_touch(s, index)
	}
	s.tlas_moved, s.tlas_dirty = true, true
}

// Gives each instance whose programs move its vertices a pose, takes it from
// those that no longer need one, and lets go of the poses no instance shows.
@(private)
displaced_reconcile :: proc(r: ^Renderer) {
	s := &r.scene
	s.displaced_stale = false
	swapped := false
	for i in 0 ..< len(s.instances) {
		inst := s.instances[i]
		mesh := inst.meta.x & INSTANCE_MESH_MASK
		if int(mesh) >= len(s.meshes) {continue}
		m := s.meshes[mesh]
		if m.skin != nil && !m.skin.displaced {continue}
		has := m.skin != nil
		source := m.skin.source if has else Mesh_Handle(mesh)
		wants := instance_vertex(r, m, inst.meta.y, inst.slot_materials).moves
		if has == wants {continue}
		if has {
			if int(source) < len(s.meshes) && s.meshes[source].vertex_count > 0 && s.meshes[source].skin == nil {
				displaced_swap(r, u32(i), source)
				swapped = true
			}
			continue
		}
		key := s.instance_keys[i]
		pose, found := s.displaced[key]
		if found && !(mesh_displaced(s, u32(pose)) && s.meshes[pose].skin.source == source && s.meshes[pose].first_instance < 0) {
			if mesh_displaced(s, u32(pose)) && s.meshes[pose].first_instance < 0 {mesh_release(r, pose)}
			delete_key(&s.displaced, key)
			found = false
		}
		if !found {
			made, ok := displaced_create(r, source)
			if !ok {
				// It takes its pose once its mesh is there (mesh_shown).
				s.displaced_stale ||= mesh_pending(s, u32(source))
				continue
			}
			pose = made
			s.displaced[key] = pose
		}
		displaced_swap(r, u32(i), pose)
		swapped = true
	}
	gone := make([dynamic]Instance_Key, context.temp_allocator)
	for key, pose in s.displaced {
		if !mesh_displaced(s, u32(pose)) || s.meshes[pose].first_instance < 0 {append(&gone, key)}
	}
	for key in gone {
		if pose := s.displaced[key]; mesh_displaced(s, u32(pose)) {mesh_release(r, pose)}
		delete_key(&s.displaced, key)
	}
	if swapped {instances_moved(s)}
}

// Before the boxes of the poses: the instances that take or leave a pose,
// and the poses whose vertices the frame moves again because what their
// programs read changed. Their reach grows the boxes of their instances.
@(private)
displaced_prepare :: proc(r: ^Renderer) {
	s := &r.scene
	if s.displaced_stale {displaced_reconcile(r)}
	for handle in s.skinned {
		m := &s.meshes[handle]
		skin := m.skin
		if skin == nil || skin.external || !skin.displaced && len(skin.joints) == 0 {continue}
		v: Instance_Vertex
		if index := m.first_instance; index >= 0 {
			inst := &s.instances[index]
			v = instance_vertex(r, m^, inst.meta.y, inst.slot_materials)
			for row in inst.world {for value in row {v.inputs = base.hash_mix(v.inputs, u64(transmute(u32)value))}}
			for row in inst.prev_world {for value in row {v.inputs = base.hash_mix(v.inputs, u64(transmute(u32)value))}}
			if v.animated {v.inputs = base.hash_mix(v.inputs, u64(transmute(u32)r.time) << 32 | u64(transmute(u32)r.previous_time))}
		}
		// A skin that starts or stops being moved is posed again.
		if !skin.displaced && v.moves != skin.moves {skin.moves = v.moves; skin.dirty = true}
		if v.reach != skin.reach {skin.reach = v.reach; skin.bounds_dirty = true}
		if !v.moves || v.inputs == skin.inputs {continue}
		skin.inputs = v.inputs
		skin.dirty = true
	}
}

// surface_vertices.comp
@(private = "file")
Displace_Params :: struct {
	mesh, clusters, instance, program: u32,
	input, output, input_before, output_before: u32,
	before:                            u32, // 0 none, 1 the same at output_before, 2 input_before at the frame before
	time, previous_time:               f32,
	pad:                               u32,
	origin:                            [4]i32,
}

// After the tables of the frame are uploaded: the programs move the vertices
// of the displaced poses that changed, and those of the skins that moved
// that the skin just posed. A program without its pipeline leaves them for
// another frame.
@(private)
displaced_record :: proc(r: ^Renderer, cmd: ^rhi.Command_List) -> bool {
	s := &r.scene
	begun := false
	for handle in s.skinned {
		mesh := s.meshes[handle]
		skin := mesh.skin
		if skin == nil || skin.external || mesh.first_instance < 0 || mesh_pending(s, u32(handle)) {continue}
		if skin.displaced {if !skin.dirty {continue}} else if !skin.moves || !(skin.dirty || skin.settle) {continue}
		index := u32(mesh.first_instance)
		palette := s.instances[index].slot_materials
		material := s.instances[index].meta.y
		written := true
		// The programs of its materials that move vertices, in order of id, each once.
		last := u32(0)
		for {
			next := max(u32)
			for packed in s.indices[mesh.slot_word:][:mesh.slot_count] {
				row := instance_row(packed, material, &palette)
				if int(row) >= len(s.materials) {continue}
				id := s.materials[row].program_id
				if id <= last || id >= next {continue}
				if program := program_of_id(r, id); program != nil && program.domain == .Surface && program.vertex.declared {next = id}
			}
			if next == max(u32) {break}
			last = next
			program := program_of_id(r, next)
			pipeline := program_compute(r, &r.vertex_stages, program^, "surface_vertices", "surface vertices")
			if pipeline == 0 {written = false; continue}
			if !begun {
				begun = true
				rhi.cmd_timestamp(cmd, "surface vertices")
			}
			params := Displace_Params {
				mesh = u32(handle), clusters = posed_clusters(s, mesh), instance = index, program = next,
				input = GPU_NONE, output = mesh.posed_word, input_before = GPU_NONE, output_before = mesh.previous_word,
				origin = origin_cells(r.origin),
			}
			if !skin.displaced {params.input, params.input_before, params.before = mesh.posed_word, mesh.previous_word, 2} else if skin.fresh {params.before = 1}
			if program.vertex.animated {params.time, params.previous_time = r.time, r.previous_time}
			rhi.cmd_bind_pipeline(cmd, pipeline)
			rhi.cmd_bind_buffer(cmd, SLOT_INSTANCES, s.instance_buffer)
			rhi.cmd_bind_buffer(cmd, SLOT_MESHES, s.mesh_buffer)
			rhi.cmd_bind_buffer(cmd, SLOT_VERTICES, s.vertex_buffer)
			rhi.cmd_bind_buffer(cmd, SLOT_INDICES, s.index_buffer)
			rhi.cmd_bind_buffer(cmd, SLOT_MATERIALS, s.material_buffer)
			rhi.cmd_bind_sampler(cmd, SLOT_MATERIAL_SAMPLER, r.material_sampler)
			set_params(cmd, &params)
			rhi.cmd_dispatch(cmd, params.clusters, 1)
		}
		// What was not written is written when its pipeline is there.
		if written {skin.fresh = false} else {skin.inputs = 0}
	}
	return true
}

// The programs of the shaders changed: every instance looks again at whether
// they move its vertices, and those they move are moved again.
@(private)
displaced_programs_changed :: proc(r: ^Renderer) {
	s := &r.scene
	s.displaced_stale = true
	for handle in s.skinned {
		if skin := s.meshes[handle].skin; skin != nil && (skin.displaced || skin.moves) {skin.inputs = 0}
	}
}
