package mirai_render

import "core:testing"
import "mirai:asset"
import mm "mirai:std/math"

// A deformable that keeps the levels of its source poses every vertex of
// its clusters three times (current, previous and rest) after its own copy of
// them; one without them poses those of level 0 alone and stays there.
@(test)
a_deformable_with_levels_keeps_the_levels_of_its_source_in_its_own_vertices :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	SIDE :: 33
	vertices := make([]asset.Vertex, SIDE * SIDE, context.temp_allocator)
	for &v, i in vertices {
		x, z := f32(i % SIDE), f32(i / SIDE)
		v = {position = {x, 0.3 * f32((i * 7) % 5), z}, normal = mm.normal_pack({0, 1, 0}), color = 0xffffffff, tangent = mm.tangent_pack({1, 0, 0}, 1), uv = {x / SIDE, z / SIDE}}
	}
	indices := make([dynamic]u32, context.temp_allocator)
	for z in 0 ..< SIDE - 1 {
		for x in 0 ..< SIDE - 1 {
			a := u32(z * SIDE + x)
			append(&indices, a, a + SIDE, a + 1, a + 1, a + SIDE, a + SIDE + 1)
		}
	}
	whole := len(indices)
	for q := 0; q < whole / 6; q += 2 {append(&indices, ..indices[q * 6:][:6])}
	levels := [2]asset.Level_Source{{0, u32(whole), 0}, {u32(whole), u32(len(indices) - whole), 0.1}}
	g: asset.Mesh_Geometry
	if !testing.expect(t, asset.mesh_build({vertices = vertices}, indices[:], levels[:], &g, context.temp_allocator)) {return}
	source, added := mesh_add_geometry(r, g, {0})
	if !testing.expect(t, added) {return}
	original := r.scene.meshes[source]
	testing.expect_value(t, original.level_count, 2)
	with, made := deformable_create(r, source, true)
	if !testing.expect(t, made) {return}
	mesh := r.scene.meshes[with]
	count := original.vertex_count
	testing.expect_value(t, mesh.level_count, original.level_count)
	testing.expect(t, mesh.flags & MESH_FLAG_LEVEL0 == 0 && mesh.vertices_posed == count)
	testing.expect_value(t, mesh.vertex_span, original.vertex_span + 3 * count * POSED_WORDS)
	testing.expect_value(t, mesh.index_span, original.index_span)
	written, rest, posed, row, known := deformable_vertices(r, with)
	testing.expect_value(t, row, u32(with))
	testing.expect(t, known && posed == count && written == mesh.posed_word && rest == written + 2 * count * POSED_WORDS)
	testing.expect_value(t, gpu_mesh(mesh).previous_word, written + count * POSED_WORDS)
	without, _ := deformable_create(r, source)
	plain := r.scene.meshes[without]
	level0, _ := level0_vertices(&r.scene, original)
	testing.expect(t, plain.flags & MESH_FLAG_LEVEL0 != 0 && plain.vertices_posed == level0 && level0 < count)
	testing.expect(t, mesh_remove(r, with) && mesh_remove(r, without))
}

// An instance whose material program moves vertices shows a pose of its own
// of level 0 of its mesh, kept while it keeps its identity, mesh and
// program, with a box grown by the reach the program reads from its
// parameters; the pose goes when the instance goes or its material stops
// moving vertices.
@(test)
an_instance_whose_program_moves_vertices_shows_a_pose_of_its_own :: proc(t: ^testing.T) {
	r := new(Renderer); defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	defer program_catalog_destroy(&r.programs)
	vertices := make([]asset.Vertex, 9, context.temp_allocator)
	for &v, i in vertices {
		x, z := f32(i % 3), f32(i / 3)
		v = {position = {x, 0, z}, normal = mm.normal_pack({0, 1, 0}), color = 0xffffffff, tangent = mm.tangent_pack({1, 0, 0}, 1), uv = {x / 2, z / 2}, uv1 = {f32(i), 0}}
	}
	indices := []u32{0, 3, 1, 1, 3, 4, 1, 4, 2, 2, 4, 5, 3, 6, 4, 4, 6, 7, 4, 7, 5, 5, 7, 8}
	g: asset.Mesh_Geometry
	levels := [1]asset.Level_Source{{0, u32(len(indices)), 0}}
	if !testing.expect(t, asset.mesh_build({vertices = vertices}, indices, levels[:], &g, context.temp_allocator)) {return}
	source, added := mesh_add_geometry(r, g, {0})
	if !testing.expect(t, added) {return}
	pieces := program_find(r, "Pieces", .Surface)
	if !testing.expect(t, pieces != nil && pieces.vertex.declared && pieces.vertex.reach_offset >= 0, "the engine has the Pieces program, whose reach is a parameter") {return}
	moving := DEFAULT_MATERIAL
	moving.program_id = pieces.id
	moving.custom_params = program_defaults(pieces)
	testing.expect(t, program_parameter_set(&moving.custom_params, program_parameter(pieces, "reach"), {0.5, 0, 0, 0}))
	materials_set(r, {moving, DEFAULT_MATERIAL})
	s := &r.scene
	desc := Instance_Desc{object_id = 1, mesh = source, transform = Mat4(1), material = 1, tint = {1, 1, 1}}
	scene_set(r, {desc}, nil, {}, {})
	displaced_prepare(r)
	pose := Mesh_Handle(s.instances[0].meta.x & INSTANCE_MESH_MASK)
	if !testing.expect(t, pose != source && mesh_displaced(s, u32(pose)), "the instance shows its pose") {return}
	skin := s.meshes[pose].skin
	testing.expect(t, skin.source == source && skin.fresh && skin.dirty && len(s.displaced) == 1)
	testing.expect_value(t, s.meshes[pose].previous_word, s.meshes[pose].posed_word + s.meshes[pose].vertices_posed * POSED_WORDS)
	testing.expect(t, s.meshes[pose].bounds_min == s.meshes[source].bounds_min, "the pose keeps the box of its mesh, which programs read")
	skins_bounds(r)
	testing.expect_value(t, s.instances[0].bounds_min.xyz, s.meshes[source].bounds_min - 0.5)
	testing.expect_value(t, s.instances[0].bounds_max.xyz, s.meshes[source].bounds_max + 0.5)
	// Another reach grows its box; the same scene keeps its pose.
	testing.expect(t, program_parameter_set(&moving.custom_params, program_parameter(pieces, "reach"), {1, 0, 0, 0}))
	skin.inputs = 0
	materials_update(r, {moving, DEFAULT_MATERIAL}, {1})
	displaced_prepare(r)
	testing.expect(t, skin.dirty && skin.inputs != 0)
	skins_bounds(r)
	testing.expect_value(t, s.instances[0].bounds_max.xyz, s.meshes[source].bounds_max + 1)
	// A reach the instance gives over its row grows its box alone and moves its pose again: the row stays.
	given: Instance_Material_Values
	params: [16]Vec4
	testing.expect(t, program_parameter_set(&params, program_parameter(pieces, "reach"), {2, 0, 0, 0}))
	value, held := instance_material_value_parameter(1, program_parameter(pieces, "reach"), &params)
	testing.expect(t, held && instance_material_values_put(&given, value))
	version := s.material_versions[1]
	skin.dirty = false
	testing.expect(t, scene_material_values(r, {0}, {given}))
	displaced_prepare(r)
	testing.expect(t, skin.dirty && s.material_versions[1] == version)
	skins_bounds(r)
	testing.expect_value(t, s.instances[0].bounds_max.xyz, s.meshes[source].bounds_max + 2)
	testing.expect(t, scene_material_values(r, {0}, {{}}))
	displaced_prepare(r)
	skins_bounds(r)
	testing.expect_value(t, s.instances[0].bounds_max.xyz, s.meshes[source].bounds_max + 1)
	scene_set(r, {desc}, nil, {}, {})
	displaced_prepare(r)
	testing.expect_value(t, Mesh_Handle(s.instances[0].meta.x & INSTANCE_MESH_MASK), pose)
	// A material that moves nothing gives it its mesh back, and the pose goes.
	plain := DEFAULT_MATERIAL
	materials_update(r, {plain, DEFAULT_MATERIAL}, {1})
	displaced_prepare(r)
	testing.expect_value(t, Mesh_Handle(s.instances[0].meta.x & INSTANCE_MESH_MASK), source)
	testing.expect(t, len(s.displaced) == 0 && s.meshes[pose].vertex_count == 0)
	testing.expect_value(t, s.instances[0].bounds_max.xyz, s.meshes[source].bounds_max)
	// Moving again it takes a new pose, which goes with the instance.
	materials_update(r, {moving, DEFAULT_MATERIAL}, {1})
	displaced_prepare(r)
	testing.expect(t, mesh_displaced(s, s.instances[0].meta.x & INSTANCE_MESH_MASK) && len(s.displaced) == 1)
	other := desc
	other.object_id = 2
	testing.expect(t, scene_update(r, 0, {other}))
	displaced_prepare(r)
	moved := s.instances[0].meta.x & INSTANCE_MESH_MASK
	testing.expect(t, mesh_displaced(s, moved) && len(s.displaced) == 1, "another identity, another pose: the first goes")
	scene_set(r, {}, nil, {}, {})
	displaced_prepare(r)
	testing.expect(t, len(s.displaced) == 0 && s.meshes[moved].vertex_count == 0)
}
