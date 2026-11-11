package mirai_render

import "core:mem"
import "core:slice"
import "core:testing"
import "mirai:asset"
import mm "mirai:std/math"

// A square grid on the ground, two triangles per cell, the far half in slot 1.
@(private)
edit_grid :: proc(cells: int, size: f32, height: f32 = 0) -> (vertices: [dynamic]Gpu_Vertex, indices: [dynamic]u32) {
	for z in 0 ..= cells {
		for x in 0 ..= cells {
			u, v := f32(x) / f32(cells), f32(z) / f32(cells)
			append(&vertices, Gpu_Vertex{
				position = {(u - 0.5) * size, height, (v - 0.5) * size}, normal = mm.normal_pack({0, 1, 0}), uv = {u, v}, uv1 = {u, v}, tangent = mm.tangent_pack({1, 0, 0}, 1),
				color = mm.rgba8_pack({u, 1, v, 1}), material = 1 if z > cells / 2 else 0,
			})
		}
	}
	row := u32(cells + 1)
	for z in 0 ..< u32(cells) {
		for x in 0 ..< u32(cells) {
			a := z * row + x
			append(&indices, a, a + row, a + 1, a + 1, a + row, a + row + 1)
		}
	}
	return
}

@(private = "file")
edit_bytes :: proc(data: []$T) -> []u8 {return mem.slice_to_bytes(data)}

// The vertex mesh_add takes for a packed one.
@(private = "file")
edit_plain :: proc(v: Gpu_Vertex) -> Mesh_Vertex {
	tangent, sign := mm.tangent_unpack(v.tangent)
	return {
		position = v.position, normal = mm.normal_unpack(v.normal), uv = v.uv, uv1 = v.uv1, tangent = {tangent.x, tangent.y, tangent.z, sign},
		color = {f32(v.color & 0xff) / 255, f32(v.color >> 8 & 0xff) / 255, f32(v.color >> 16 & 0xff) / 255},
	}
}

// Registers a grid of edit_grid as mesh_add does: the material of a vertex
// is the row its slot (Gpu_Vertex.material) names in rows.
@(private)
edit_add :: proc(r: ^Renderer, packed: []Gpu_Vertex, indices: []u32, rows: []u32) -> (Mesh_Handle, bool) {
	plain := make([]Mesh_Vertex, len(packed), context.temp_allocator)
	for v, i in packed {
		if int(v.material) >= len(rows) {return 0, false}
		plain[i] = edit_plain(v)
		plain[i].material = Material_Handle(rows[v.material])
		plain[i].slot = v.material + 1
	}
	return mesh_add(r, plain, indices)
}

@(test)
mesh_add_makes_a_slot_of_each_material_and_refuses_what_it_cannot_store :: proc(t: ^testing.T) {
	packed, indices := edit_grid(16, 4)
	defer delete(packed)
	defer delete(indices)
	rows := [2]u32{3, 1}
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	handle, added := edit_add(r, packed[:], indices[:], rows[:])
	if !testing.expect(t, added) {return}
	record := r.scene.meshes[handle]
	testing.expect_value(t, record.slot_count, u32(2))
	testing.expect(t, r.scene.indices[record.slot_word] == 3 | 1 << 24 && r.scene.indices[record.slot_word + 1] == 1 | 2 << 24, "a slot holds the row and the source slot")
	testing.expect_value(t, record.level_count, u32(1))
	testing.expect_value(t, record.triangle_count, u32(len(indices) / 3))
	g, _ := record_decode(&r.scene, record, context.temp_allocator)
	slots: bit_set[0 ..< 32]
	triangles := 0
	for c in g.clusters {
		testing.expect(t, asset.cluster_triangle_count(c) <= asset.CLUSTER_TRIANGLES && asset.cluster_vertex_count(c) <= asset.CLUSTER_VERTICES)
		slots += {int(asset.cluster_slot(c))}
		triangles += int(asset.cluster_triangle_count(c))
	}
	testing.expect(t, slots == {0, 1} && triangles == len(indices) / 3, "the clusters hold every triangle, in one slot each")
	testing.expect_value(t, len(r.scene.materials), 4)
	far := packed[len(packed) - 6:]
	_, out_of_range := edit_add(r, far, []u32{0, 2, 9}, rows[:])
	testing.expect(t, !out_of_range, "an index past the vertices")
	_, not_triangles := edit_add(r, far, []u32{0, 2}, rows[:])
	testing.expect(t, !not_triangles, "indices that are not triangles")
	testing.expect_value(t, mesh_count(r), 1)
}

@(test)
mesh_add_geometry_takes_the_levels_a_mesh_comes_with :: proc(t: ^testing.T) {
	packed, indices := edit_grid(16, 4)
	defer delete(packed)
	defer delete(indices)
	plain := make([]Mesh_Vertex, len(packed), context.temp_allocator)
	for v, i in packed {plain[i] = edit_plain(v)}
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	// Two levels of its own after level 0: two triangles, then one.
	all := make([dynamic]u32, 0, len(indices) + 9, context.temp_allocator)
	append(&all, ..indices[:])
	append(&all, 0, 1, 2, 3, 4, 5, 0, 2, 1)
	levels := [3]asset.Level_Source{{0, u32(len(indices)), 0}, {u32(len(indices)), 6, 0.25}, {u32(len(indices)) + 6, 3, 0.5}}
	handle, _, added := test_mesh_add(r, plain, all[:], levels[:])
	if !testing.expect(t, added) {return}
	record := r.scene.meshes[handle]
	testing.expect_value(t, record.level_count, u32(3))
	g, _ := record_decode(&r.scene, record, context.temp_allocator)
	testing.expect(t, g.levels[1].triangle_count == 2 && g.levels[1].error == 0.25 && g.levels[2].triangle_count == 1 && g.levels[2].error == 0.5, "the levels are those given, not derived ones")
	testing.expect_value(t, record.triangle_count, u32(len(indices) / 3))
	// The mesh leaves with its levels.
	testing.expect(t, mesh_remove(r, handle))
	testing.expect(t, len(r.scene.vertices) == 0 && len(r.scene.indices) == 0)
}

@(test)
mesh_remove_preserves_other_ranges_and_instances_and_reuses_the_freed_space :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	sizes := [3]int{4, 16, 20}
	handles: [3]Mesh_Handle
	for cells, i in sizes {
		vertices, indices := edit_grid(cells, f32(cells), f32(i))
		handles[i], _ = edit_add(r, vertices[:], indices[:], []u32{0, u32(i + 1)})
		delete(vertices)
		delete(indices)
	}
	s := &r.scene
	last := s.meshes[handles[2]]
	kept := make([]u32, last.vertex_span)
	defer delete(kept)
	copy(kept, s.vertices[last.vertex_word:][:last.vertex_span])
	kept_indices := make([]u32, last.index_span)
	defer delete(kept_indices)
	copy(kept_indices, s.indices[last.index_word:][:last.index_span])
	node, triangle := s.blas_nodes[last.rays[0].bvh_root], s.blas_triangles[last.rays[0].triangle_offset]
	sizes_before := [4]int{len(s.vertices), len(s.indices), len(s.blas_nodes), len(s.blas_triangles)}
	middle := s.meshes[handles[1]]
	for &ranges in s.pool_dirty {clear(&ranges)}
	clear(&s.mesh_dirty)
	scene_given(r,[]Instance_Desc{{object_id=1,mesh=handles[0],transform=Mat4(1)},{object_id=2,mesh=handles[1],transform=Mat4(1)},{object_id=3,mesh=handles[2],transform=Mat4(1)}},nil,{},{})
	touched_settle(s);touched_settle(s)
	s.instances_dirty=false
	kept_instance:=s.instances[2]
	triangles := s.triangle_total

	testing.expect(t, mesh_remove(r, handles[1]))
	testing.expect(t, !mesh_remove(r, handles[1]), "a removed mesh is not a mesh")
	testing.expect(t, !mesh_remove(r, 99))
	moved := s.meshes[handles[2]]
	testing.expect_value(t, len(s.meshes), 3)
	testing.expect_value(t, s.meshes[handles[1]].vertex_count, u32(0))
	testing.expect_value(t, moved.vertex_word, last.vertex_word)
	testing.expect_value(t, moved.index_word, last.index_word)
	testing.expect_value(t, moved.rays[0].bvh_root, last.rays[0].bvh_root)
	testing.expect_value(t, moved.rays[0].triangle_offset, last.rays[0].triangle_offset)
	testing.expect_value(t,[4]int{len(s.vertices),len(s.indices),len(s.blas_nodes),len(s.blas_triangles)},sizes_before)
	testing.expect(t, mem.compare(edit_bytes(kept), edit_bytes(s.vertices[moved.vertex_word:][:moved.vertex_span])) == 0, "the mesh behind keeps its vertices")
	testing.expect(t, mem.compare(edit_bytes(kept_indices), edit_bytes(s.indices[moved.index_word:][:moved.index_span])) == 0, "and its clusters")
	testing.expect_value(t, s.blas_nodes[moved.rays[0].bvh_root], node)
	testing.expect_value(t, s.blas_triangles[moved.rays[0].triangle_offset], triangle)
	testing.expect(t,len(s.pool_dirty[.Vertex])==0 && len(s.pool_dirty[.Index])==0)
	testing.expect_value(t, s.triangle_total, triangles - u64(middle.triangle_count))
	testing.expect(t,s.geometry_dirty && len(s.instances)==3)
	testing.expect(t,!s.instances_dirty && s.touched_count==1 && instance_touched(s,1),"only the retired instance is staged")
	testing.expect_value(t,s.instances[2],kept_instance)
	testing.expect(t,s.instances[1].meta.w&INSTANCE_FLAG_HIDDEN!=0)
	vertices, indices := edit_grid(2, 1)
	defer delete(vertices)
	defer delete(indices)
	reused, _ := edit_add(r, vertices[:], indices[:], []u32{0, 0})
	testing.expect_value(t, reused, handles[1])
	testing.expect_value(t,len(s.free_meshes),0)
	testing.expect_value(t,s.meshes[reused].vertex_word,middle.vertex_word)
	testing.expect_value(t,s.meshes[reused].index_word,middle.index_word)
	testing.expect(t,s.instances[1].meta.w&INSTANCE_FLAG_HIDDEN!=0,"retired instances do not follow a reused handle")
	testing.expect(t, mesh_remove(r, handles[0]) && mesh_remove(r, handles[2]) && mesh_remove(r, handles[1]))
	testing.expect_value(t,mesh_count(r),0)
	testing.expect_value(t, len(s.vertices) + len(s.indices) + len(s.blas_nodes) + len(s.blas_triangles), 0)
	testing.expect_value(t, s.triangle_total, u64(0))
}

@(test)
material_rows_go_to_the_gpu_alone_and_only_when_their_values_change :: proc(t:^testing.T) {
    r:=new(Renderer);defer free(r)
    r.allocator=context.allocator
    scene_init(r)
    defer scene_destroy(r)
    s:=&r.scene
    vertices,indices:=edit_grid(4,2)
    defer delete(vertices);defer delete(indices)
    handle,_:=edit_add(r,vertices[:],indices[:],{1,2})
    materials:=[3]Material_Desc{DEFAULT_MATERIAL,DEFAULT_MATERIAL,DEFAULT_MATERIAL}
    materials_set(r,materials[:])
    scene_given(r,{Instance_Desc{object_id=1,mesh=handle,transform=Mat4(1)}},nil,{},{})
    uploaded :: proc(s:^Scene_State) {
        s.materials_dirty=false
        clear(&s.material_ranges)
        s.changes={}
    }
    uploaded(s)
    materials_set(r,materials[:])
    testing.expect(t,!s.materials_dirty && len(s.material_ranges)==0 && !s.changes.all,"the same table changes nothing")

    materials[1].roughness=0.2
    materials_update(r,materials[:],{2})
    testing.expect(t,!s.materials_dirty && len(s.material_ranges)==1 && s.material_ranges[0]==Pool_Range{2,1},"the row that changed goes alone")
    testing.expect_value(t,s.materials[2].roughness,f32(0.2))
    testing.expect_value(t,s.smoothest,f32(0.2))
    testing.expect(t,!s.changes.all && s.changes.count==1,"the light of the world sees the roughness, around what shows it")
    center:=s.changes.spheres[0].xyz
    testing.expect(t,abs(center.x)<1e-4 && abs(center.z)<1e-4 && s.changes.spheres[0].w>LIGHT_CHANGE_REACH)
    uploaded(s)
    materials[1].occlusion_strength=0.25
    materials_update(r,materials[:],{2})
    testing.expect(t,len(s.material_ranges)==1 && !s.changes.all && s.changes.count==0,"nor its occlusion, which the light of the world does not see")
    uploaded(s)
    materials[1].roughness=0.9
    materials_update(r,materials[:],{2})
    testing.expect_value(t,s.smoothest,f32(0.9))
    uploaded(s)
    materials[2].base_color={0,0,1}
    materials_update(r,materials[:],{3})
    testing.expect(t,len(s.material_ranges)==1 && !s.changes.all && s.changes.count==0,"a row nothing shows changes no light")

    uploaded(s)
    testing.expect(t,s.instances[0].meta.w&INSTANCE_FLAG_TRANSLUCENT==0)
    materials[0].alpha_mode,materials[0].opacity=.Blend,0.5
    materials_update(r,materials[:],{1})
    testing.expect(t,s.instances[0].meta.w&INSTANCE_FLAG_TRANSLUCENT!=0 && len(s.translucent)==1,"a row that blends makes its instances translucent")

    uploaded(s)
    more:=[5]Material_Desc{materials[0],materials[1],materials[2],DEFAULT_MATERIAL,DEFAULT_MATERIAL}
    more[4].base_color={1,0,0}
    materials_update(r,more[:],{5})
    testing.expect_value(t,len(s.materials),6)
    testing.expect(t,!s.materials_dirty && s.materials[5].base_color=={1,0,0},"a row past the table grows it")

    many:=make([]Material_Desc,2*MATERIAL_RANGES_MAX+2)
    defer delete(many)
    for &m in many {m=DEFAULT_MATERIAL}
    materials_set(r,many)
    uploaded(s)
    rows:=make([]u32,MATERIAL_RANGES_MAX+1)
    defer delete(rows)
    for &row,i in rows {
        row=u32(2*i+1)
        many[row-1].roughness=0.5
    }
    materials_update(r,many,rows)
    testing.expect(t,s.materials_dirty && len(s.material_ranges)==0,"past the ranges the whole table goes")
}

@(test)
scene_set_changes_the_light_only_around_what_comes_goes_or_changes :: proc(t:^testing.T) {
    r:=new(Renderer);defer free(r)
    r.allocator=context.allocator
    scene_init(r)
    defer scene_destroy(r)
    vertices,indices:=edit_grid(4,2)
    defer delete(vertices);defer delete(indices)
    handle,_:=edit_add(r,vertices[:],indices[:],{0,1})
    materials_set(r,{DEFAULT_MATERIAL})
    at :: proc(x:f32) -> Mat4 {m:=Mat4(1);m[0,3]=x;return m}
    a:=Instance_Desc{object_id=1,mesh=handle,transform=at(0),tint={1,1,1}}
    b:=Instance_Desc{object_id=2,mesh=handle,transform=at(20),tint={1,1,1}}
    scene_given(r,{a,b},nil,{},{})
    s:=&r.scene
    s.changes={}
    scene_given(r,{a,b},nil,{},{})
    testing.expect(t,!s.changes.all && s.changes.count==0,"the same set changes no light")
    shown:=b
    shown.highlight=1
    scene_given(r,{a,shown},nil,{},{})
    testing.expect(t,!s.changes.all && s.changes.count==0,"nor a highlight, drawn over the image")
    c:=Instance_Desc{object_id=3,mesh=handle,transform=at(-20),tint={1,1,1}}
    scene_given(r,{a,b,c},nil,{},{})
    testing.expect(t,!s.changes.all && s.changes.count==1,"one that comes changes the light around it")
    s.changes={}
    scene_given(r,{a,b},nil,{},{})
    testing.expect(t,!s.changes.all && s.changes.count==1,"one that goes, around where it was")
    s.changes={}
    touched_settle(s);touched_settle(s)
    moved:=b
    moved.transform=at(25)
    scene_given(r,{a,moved},nil,{},{})
    testing.expect(t,!s.changes.all && s.changes.count==2,"one that moves, around where it was and where it is")
    testing.expect(t,s.touched_count==1 && instance_touched(s,1),"and it has its motion")
    s.changes={}
    small:=Instance_Desc{object_id=4,mesh=handle,transform=at(40)*Mat4{0.1,0,0,0,0,0.1,0,0,0,0,0.1,0,0,0,0,1},tint={1,1,1}}
    scene_given(r,{a,moved,small},nil,{},{})
    testing.expect(t,s.changes.count==1 && s.changes.spheres[0].w<2,"a small one changes the light only within ten of its sizes")
    s.changes={}
    glowing:=small
    glowing.emission={1,1,1}
    scene_given(r,{a,moved,glowing},nil,{},{})
    testing.expect(t,s.changes.count==2 && max(s.changes.spheres[0].w,s.changes.spheres[1].w)>LIGHT_CHANGE_REACH,"its glow, as far as a glow reaches")
}

@(test)
scene_update_replaces_geometry_and_classification_and_keeps_other_rows :: proc(t:^testing.T) {
    r:=new(Renderer);defer free(r)
    r.allocator=context.allocator
    scene_init(r)
    defer scene_destroy(r)
    vertices,indices:=edit_grid(4,2)
    defer delete(vertices);defer delete(indices)
    handle,_:=edit_add(r,vertices[:],indices[:],{0,1})
    blend:=DEFAULT_MATERIAL
    blend.opacity,blend.alpha_mode=0.5,.Blend
    materials_set(r,{DEFAULT_MATERIAL,blend})
    original:=Instance_Desc{object_id=1,mesh=handle,transform=Mat4(1),tint={1,0,0},overlays={count=1,entries={0={material=1,enabled=true}}}}
    scene_given(r,{original,Instance_Desc{object_id=2,mesh=handle,transform=Mat4(1),tint={0,1,0}}},nil,{},{})
    kept:=r.scene.instances[0]
    r.scene.instances_dirty=false
    replacement:=Instance_Desc{object_id=2,copy_owner=1,mesh=handle,transform=Mat4(1),material=2,tint={0,0,1}}
    r.scene.changes={}
    testing.expect(t,scene_update(r,1,{replacement}))
    testing.expect(t,!r.scene.changes.all && r.scene.changes.count==2,"the light changes around the instance before and after, not everywhere")
    testing.expect_value(t,r.scene.instances[0],kept)
    testing.expect(t,!r.scene.instances_dirty && r.scene.instances[1].meta.w&INSTANCE_FLAG_TRANSLUCENT!=0)
    testing.expect_value(t,len(r.scene.translucent),1)
    testing.expect_value(t,r.scene.overlay_count,1)
    testing.expect(t,scene_update(r,2,{original}))
    testing.expect_value(t,len(r.scene.instances),3)
    testing.expect(t,scene_update(r,1,nil,true))
    testing.expect_value(t,len(r.scene.instances),1)
    testing.expect_value(t,len(r.scene.translucent),0)
    testing.expect_value(t,r.scene.overlay_count,1)
    testing.expect(t,mesh_remove(r,handle))
    testing.expect_value(t,r.scene.overlay_count,0)
}

@(test)
program_catalog_names_the_programs_and_packs_their_parameters :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	defer program_catalog_destroy(&r.programs)
	if !fixture_catalog(t, r) {return}
	grid := program_find(r, "Grid", .Surface)
	if !testing.expect(t, grid != nil) {return}
	testing.expect(t, grid.id != 0 && grid.domain == .Surface)
	testing.expect(t, program_find(r, "Grid", .Postprocess) == nil && program_find(r, "Nothing", .Surface) == nil)
	testing.expect_value(t, program_find(r, "ColorGrade", .Postprocess).id, u32(1))
	params := program_defaults(grid)
	color := program_parameter(grid, "color")
	testing.expect(t, color != nil && color.color && color.components == 3 && color.offset == 0)
	testing.expect_value(t, params[0].xyz, Vec3{0.42, 0.42, 0.42})
	testing.expect(t, program_parameter_set(&params, color, {0.5, 0.25, 1, 0}))
	testing.expect_value(t, params[0].xyz, Vec3{0.5, 0.25, 1})
	testing.expect(t, !program_parameter_set(&params, color, {2, 0, 0, 0}), "a value outside the range of the parameter is refused")
	testing.expect_value(t, params[0].xyz, Vec3{0.5, 0.25, 1})
	testing.expect(t, program_parameter(grid, "nothing") == nil)

	text := `{"programs":[{"id":3,"name":"Paint","domain":"surface","size":24,"parameters":[
		{"name":"image","kind":"texture","components":1,"offset":0,"default":"","min":0,"max":0,"srgb":true},
		{"name":"steps","kind":"int32","components":2,"offset":4,"default":[-2,5],"min":-8,"max":8,"group":"Pattern"},
		{"name":"on","kind":"bool","components":1,"offset":12,"default":true,"min":0,"max":1},
		{"name":"mask","kind":"uint32","components":1,"offset":16,"default":7,"min":0,"max":4294967295}]}]}`
	catalog, parsed := program_catalog_parse(transmute([]u8)text)
	if !testing.expect(t, parsed) {return}
	defer program_catalog_destroy(&catalog)
	paint := &catalog.programs[0]
	words := transmute([64]u32)program_defaults(paint)
	testing.expect_value(t, words[0], GPU_NONE)
	testing.expect_value(t, transmute(i32)words[1], i32(-2))
	testing.expect_value(t, words[2], u32(5))
	testing.expect_value(t, words[3], u32(1))
	testing.expect_value(t, words[4], u32(7))
	testing.expect(t, paint.parameters[1].group == "Pattern" && paint.parameters[0].group == "", "a parameter keeps its group")
	values := transmute([16]Vec4)words
	testing.expect_value(t, program_parameter_get(&values, &paint.parameters[1]), [4]f64{-2, 5, 0, 0})
	testing.expect_value(t, program_parameter_get(&values, &paint.parameters[2]), [4]f64{1, 0, 0, 0})
	testing.expect_value(t, program_parameter_get(&values, &paint.parameters[3]), [4]f64{7, 0, 0, 0})
	testing.expect_value(t, program_parameter_get(&values, &paint.parameters[0]), [4]f64{})
	testing.expect_value(t, program_parameter_get(&params, color), [4]f64{0.5, 0.25, 1, 0})
	testing.expect(t, !program_parameter_set(&values, &paint.parameters[1], {1.5, 0, 0, 0}), "an integer parameter takes whole numbers")
	testing.expect(t, !program_parameter_set(&values, &paint.parameters[0], {1, 0, 0, 0}), "a texture is not a number")
	testing.expect(t, paint.parameters[0].srgb && program_parameter_set_texture(r, &values, &paint.parameters[0], 0))
	testing.expect(t, !program_parameter_set_texture(r, &values, &paint.parameters[1], 0))
	broken := `{"programs":[{"id":1,"name":"Wide","domain":"surface","size":8,"parameters":[{"name":"far","kind":"float32","components":4,"offset":248}]}]}`
	_, wide := program_catalog_parse(transmute([]u8)broken)
	testing.expect(t, !wide, "a parameter past the 256 bytes of a row makes the catalog invalid")
}

@(test)
program_catalog_keeps_the_ui_programs_apart :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	defer program_catalog_destroy(&r.programs)
	for name in ([]string{"Ui_Radial_Wipe", "Ui_Dissolve", "Ui_Shine", "Ui_Gradient_Sweep"}) {
		program := program_find(r, name, .Ui)
		testing.expectf(t, program != nil && program.size <= 16, "%s is a ui program of the engine", name)
		testing.expectf(t, program_find(r, name, .Postprocess) == nil && program_find(r, name, .Surface) == nil, "%s is of the ui domain alone", name)
	}
	testing.expect(t, program_find(r, "ColorGrade", .Ui) == nil)
	text := `{"programs":[{"id":4,"name":"Wipe","domain":"ui","size":8,"parameters":[
		{"name":"fill","kind":"float32","components":1,"offset":0,"default":1,"min":0,"max":1},
		{"name":"start","kind":"float32","components":1,"offset":4,"default":0,"min":-1,"max":1}]}]}`
	catalog, parsed := program_catalog_parse(transmute([]u8)text)
	if !testing.expect(t, parsed) {return}
	defer program_catalog_destroy(&catalog)
	wipe := &catalog.programs[0]
	testing.expect(t, wipe.domain == .Ui && wipe.id == 4 && len(wipe.parameters) == 2)
	testing.expect_value(t, program_defaults(wipe)[0], Vec4{1, 0, 0, 0})
	unknown := `{"programs":[{"id":1,"name":"Fog","domain":"volume","size":0,"parameters":[]}]}`
	_, known := program_catalog_parse(transmute([]u8)unknown)
	testing.expect(t, !known, "a domain the renderer does not know makes the catalog invalid")
}

@(test)
mesh_slab_axes_need_every_vertex_on_a_face_of_the_box :: proc(t: ^testing.T) {
	box: [8]Mesh_Vertex
	for &v, i in box {v = {position = {f32(i & 1), f32((i >> 1) & 1) * 0.1, f32(i >> 2)}, normal = {0, 1, 0}, color = {1, 1, 1}, tangent = {1, 0, 0, 1}}}
	indices := [9]u32{0, 1, 3, 4, 5, 6, 2, 7, 6}
	g, _, _, built := test_geometry(box[:], indices[:])
	if !testing.expect(t, built) {return}
	testing.expect_value(t, mesh_slab_axes(g, {0, 0, 0}, {1, 0.1, 1}), 0b111)
	// A vertex inside the box along x and y, on a face along z.
	box[0].position = {0.5, 0.05, 0}
	g, _, _, built = test_geometry(box[:], indices[:])
	if !testing.expect(t, built) {return}
	testing.expect_value(t, mesh_slab_axes(g, {0, 0, 0}, {1, 0.1, 1}), 0b100)
}

@(test)
how_wet_an_instance_is_stays_with_its_identity_and_changes_no_light :: proc(t:^testing.T) {
    r:=new(Renderer);defer free(r)
    r.allocator=context.allocator
    scene_init(r)
    defer scene_destroy(r)
    vertices,indices:=edit_grid(4,2)
    defer delete(vertices);defer delete(indices)
    handle,_:=edit_add(r,vertices[:],indices[:],{0,1})
    materials_set(r,{DEFAULT_MATERIAL})
    a:=Instance_Desc{object_id=1,mesh=handle,transform=Mat4(1),tint={1,1,1}}
    b:=Instance_Desc{object_id=2,mesh=handle,transform=Mat4(1),tint={1,1,1}}
    scene_given(r,{a,b},nil,{},{})
    s:=&r.scene
    s.changes={}
    testing.expect(t,scene_set_instance_wet(r,1,0.75))
    testing.expect_value(t,s.instances[1].wet,f32(0.75))
    testing.expect_value(t,s.instances[0].wet,f32(0))
    testing.expect(t,!s.changes.all && s.changes.count==0,"how wet it is changes no light")
    testing.expect(t,!scene_set_instance_wet(r,2,1),"a descriptor the scene does not have")
    testing.expect(t,!scene_set_instance_wet(r,1,max(f32)*2),"a value that is not finite")
    testing.expect(t,scene_set_instance_wet(r,0,4))
    testing.expect_value(t,s.instances[0].wet,f32(1))
    testing.expect(t,scene_set_instance_wet(r,0,0))
    moved:=Mat4(1);moved[0,3]=2
    scene_move(r,{1},{moved})
    testing.expect(t,scene_tint(r,{1},{{0.5,0.5,0.5}},{{0,0,0}}))
    testing.expect_value(t,s.instances[1].wet,f32(0.75))
    // Moved to another index, as the sync closes a gap with the last, it keeps it.
    testing.expect(t,scene_update(r,0,{b}) && scene_instance_was(r,0,1) && scene_update(r,1,nil,true))
    testing.expect_value(t,s.instances[0].wet,f32(0.75))
    testing.expect(t,scene_update(r,0,{b}))
    testing.expect_value(t,s.instances[0].wet,f32(0.75))
    other:=b
    other.object_id=3
    testing.expect(t,scene_update(r,0,{other}))
    testing.expect_value(t,s.instances[0].wet,f32(0))
}

// The colors an instance shows over its mesh stay with its identity while
// its mesh has as many vertices, and leave every instance with the colors;
// none, colors of another number of vertices and handles the renderer does
// not have are refused.
@(test)
the_colors_of_an_instance_stay_with_its_identity_and_its_mesh :: proc(t:^testing.T) {
    r:=new(Renderer);defer free(r)
    r.allocator=context.allocator
    scene_init(r)
    defer scene_destroy(r)
    vertices,indices:=edit_grid(4,2)
    defer delete(vertices);defer delete(indices)
    handle,_:=edit_add(r,vertices[:],indices[:],{0,1})
    fewer_vertices,fewer_indices:=edit_grid(2,2)
    defer delete(fewer_vertices);defer delete(fewer_indices)
    fewer,_:=edit_add(r,fewer_vertices[:],fewer_indices[:],{0,1})
    materials_set(r,{DEFAULT_MATERIAL})
    a:=Instance_Desc{object_id=1,mesh=handle,transform=Mat4(1),tint={1,1,1}}
    b:=Instance_Desc{object_id=2,mesh=handle,transform=Mat4(1),tint={1,1,1}}
    scene_given(r,{a,b},nil,{},{})
    s:=&r.scene
    count:=s.meshes[handle].vertex_count
    red:=make([]u32,count,context.temp_allocator)
    for &color in red {color=0xff0000ff}
    reds,loaded:=colors_load(r,red)
    short,_:=colors_load(r,red[:count-1])
    _,empty:=colors_load(r,nil)
    testing.expect(t,loaded && !empty)
    cases:=[]struct{descriptor:u32,colors:Colors_Handle,why:string}{
        {1,short,"colors of another number of vertices"},
        {1,Colors_Handle(len(s.colors)+1),"colors the renderer does not have"},
        {2,reds,"a descriptor the scene does not have"},
    }
    for c in cases {testing.expect(t,!scene_set_instance_colors(r,c.descriptor,c.colors),c.why)}
    testing.expect(t,scene_set_instance_colors(r,1,reds))
    shown:=s.instances[1]
    testing.expect(t,shown.color_count==count && slice.equal(s.vertices[shown.colors:][:count],red))
    testing.expect_value(t,s.instances[0].color_count,u32(0))
    // Another order keeps them with the instance; another mesh of other vertices does not.
    testing.expect(t,scene_update(r,0,{b}) && scene_instance_was(r,0,1) && scene_update(r,1,{a}))
    testing.expect_value(t,s.instances[0].color_count,count)
    testing.expect_value(t,s.instances[1].color_count,u32(0))
    other:=b
    other.mesh=fewer
    testing.expect(t,scene_update(r,0,{other}))
    testing.expect_value(t,s.instances[0].color_count,u32(0))
    testing.expect(t,scene_update(r,0,{b}) && scene_set_instance_colors(r,0,reds) && scene_set_instance_colors(r,1,reds))
    testing.expect(t,colors_remove(r,reds))
    testing.expect(t,s.instances[0].color_count==0 && s.instances[1].color_count==0)
    testing.expect(t,!colors_remove(r,reds),"colors that are gone")
}

// What casts shadows and changed since the last frame drew the scene: each
// instance that moved, came or went with the box it covers in both frames,
// the lights that moved and a sun that turned past its radius; nothing for
// what changes no shadow.
@(test)
occluders_list_what_moved_came_or_went_and_the_lights_that_moved :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	s := &r.scene
	vertices, indices := edit_grid(2, 1, 0.5)
	defer delete(vertices)
	defer delete(indices)
	mesh, added := edit_add(r,vertices[:],indices[:],[]u32{0, 0})
	if !testing.expect(t, added) {return}
	at :: proc(x: f32) -> Mat4 {m := Mat4(1); m[0, 3] = x; return m}
	set := make([]Instance_Desc, OCCLUDER_CHANGES_MAX + 4)
	defer delete(set)
	for &desc, i in set {desc = {object_id = u64(i + 1), mesh = mesh, transform = at(f32(i) * 4)}}
	scene_given(r, set[:3], nil, {}, {})
	testing.expect_value(t, s.occluders.count, 3)
	for box, i in s.occluders.boxes[:3] {testing.expect(t, box.instance == u32(i) && box.low.x == f32(i) * 4 - 0.5 && box.high.x == f32(i) * 4 + 0.5, "an instance that came")}

	s.occluders = {}
	testing.expect(t, scene_move(r, {1}, {at(6)}))
	testing.expect(t, scene_move(r, {1}, {at(7)}))
	o := s.occluders
	testing.expect(t, o.count == 1 && o.boxes[0].instance == 1, "one box for one instance that moves twice")
	testing.expect(t, o.boxes[0].low.x == 3.5 && o.boxes[0].high.x == 7.5 && o.boxes[0].low.y == 0.5 && o.boxes[0].high.y == 0.5, "where it was and where it is")

	s.occluders = {}
	moved := set[:3]
	moved[1].transform = at(7)
	scene_given(r, moved, nil, {}, {})
	tinted := moved
	tinted[0].tint = {0.2, 0.3, 0.4}
	scene_given(r, tinted, nil, {}, {})
	testing.expect_value(t, s.occluders.count, 0)
	scene_given(r, moved[:2], nil, {}, {})
	testing.expect(t, s.occluders.count == 1 && s.occluders.boxes[0].instance == OCCLUDERS_MANY && s.occluders.boxes[0].low.x == 7.5, "an instance that went leaves its box alone")

	scene_given(r, set, nil, {}, {})
	s.occluders = {}
	descs := make([]u32, len(set))
	defer delete(descs)
	transforms := make([]Mat4, len(set))
	defer delete(transforms)
	for &desc, i in descs {desc = u32(i); transforms[i] = at(f32(i) * 4 + 1)}
	testing.expect(t, scene_move(r, descs, transforms))
	testing.expect_value(t, s.occluders.count, OCCLUDER_CHANGES_MAX)
	many := 0
	for box in s.occluders.boxes {if box.instance == OCCLUDERS_MANY {many += 1}}
	testing.expect(t, many > 0, "past the room, boxes stand for several")
	for i in 0 ..< len(set) {
		low, high := f32(i) * 4 - 0.5, f32(i) * 4 + 1.5
		inside := false
		for box in s.occluders.boxes {inside ||= box.low.x <= low && box.high.x >= high}
		testing.expectf(t, inside, "instance %d lies in a box", i)
	}

	s.occluders = {}
	batch, problem := batch_set(r, 0, r.world_key, {mesh = mesh, flags = {.Casts_Shadow, .Ray_Visible}}, {batch_instance({40, 0, 0}, 1, 1, 1)})
	testing.expect_value(t, problem, "")
	testing.expect(t, s.occluders.count == 1 && s.occluders.boxes[0].instance == OCCLUDERS_MANY && s.occluders.boxes[0].low.x == 39.5, "a batch that comes casts shadows in its box")
	s.occluders = {}
	testing.expect(t, batch_remove(r, batch))
	testing.expect(t, s.occluders.count == 1 && s.occluders.boxes[0].high.x == 40.5, "and one that goes")
	_, problem = batch_set(r, 0, r.world_key, {mesh = mesh, flags = {.Ray_Visible}}, {batch_instance({40, 0, 0}, 1, 1, 1)})
	testing.expect(t, problem == "" && s.occluders.count == 1, "one that casts none changes no shadow")

	s.occluders = {}
	testing.expect(t, mesh_remove(r, mesh))
	testing.expect(t, s.occluders.count > 0, "the instances of a mesh that goes")

	lights := [2]Light_Desc{{position = {0, 2, 0}, color = 1, intensity = 10, range = 5}, {position = {4, 2, 0}, color = 1, intensity = 10, range = 5}}
	sun := Sun_Desc{direction = {0, 1, 0}, color = 1, illuminance = 1000, enabled = true}
	scene_lights_given(r, lights[:], sun, {})
	s.occluders = {}
	lights[0].intensity = 20
	scene_lights_given(r, lights[:], sun, {})
	testing.expect(t, s.occluders.light_count == 0 && !s.occluders.sun, "a light that only grows brighter moves no shadow")
	lights[1].position.x += 0.5
	sun.direction = {0.001, 1, 0}
	scene_lights_given(r, lights[:], sun, {})
	testing.expect(t, s.occluders.light_count == 1 && s.occluders.lights[0] == 1 && !s.occluders.sun, "a light that moved; a sun that turned less than its radius")
	sun.direction = {0.2, 1, 0}
	scene_lights_given(r, lights[:], sun, {})
	testing.expect(t, s.occluders.sun, "a sun that turned past its radius")

	f: Gpu_Frame
	s.occluders.boxes[0] = {{1, 2, 3}, {4, 5, 6}, 7}
	s.occluders.count = 1
	frame_occluders(&f, &s.occluders)
	testing.expect_value(t, f.moved, [4]u32{1, 1, MOVED_SUN, 0})
	testing.expect(t, transmute(u32)f.moved_boxes[0][0].w == 7 && f.moved_boxes[0][0].xyz == Vec3{1, 2, 3} && f.moved_boxes[0][1].xyz == Vec3{4, 5, 6} && f.moved_lights[0][0] == 1)
}

@(test)
material_program_roughness_keeps_reflections_active :: proc(t:^testing.T) {
    r:=new(Renderer);defer free(r)
    r.allocator=context.allocator
    defer {delete(r.scene.materials);delete(r.scene.material_versions)}
    defer program_catalog_destroy(&r.programs)
    material:=DEFAULT_MATERIAL
    materials_set(r,{material})
    testing.expect_value(t,r.scene.smoothest,f32(1))
    material.program_id=2
    materials_set(r,{material})
    testing.expect_value(t,r.scene.smoothest,f32(0))
    material.program_id=0;material.roughness=.3
    materials_set(r,{material})
    testing.expect_value(t,r.scene.smoothest,f32(.3))
}

@(private)
instance_touched :: proc(s:^Scene_State,index:u32) -> bool {return s.touched[index>>6]&(u64(1)<<(index&63))!=0}

// The instances that changed go to the GPU alone, in runs of the table,
// however many they are: the others are neither sent nor walked. What moved
// is drawn in motion by the frame that sends it and goes once more, at rest.
@(test)
touched_instances_go_in_runs_of_the_table_however_many_they_are :: proc(t:^testing.T) {
    r:=new(Renderer);defer free(r)
    r.allocator=context.allocator
    scene_init(r)
    defer scene_destroy(r)
    vertices,indices:=edit_grid(1,1)
    defer delete(vertices);defer delete(indices)
    handle,_:=edit_add(r,vertices[:],indices[:],{0,0})
    at :: proc(i:int,y:f32=0) -> Mat4 {m:=Mat4(1);m[0,3],m[1,3],m[2,3]=f32(i%40)*2,y,f32(i/40)*2;return m}
    descs:=make([]Instance_Desc,1000);defer delete(descs)
    for &desc,i in descs {desc={object_id=u64(i+1),mesh=handle,transform=at(i),tint={1,1,1}}}
    testing.expect(t,scene_given(r,descs,nil,{},{}))
    s:=&r.scene
    // The table goes whole once.
    touched_settle(s);touched_settle(s)
    testing.expect_value(t,s.touched_count,0)
    s.instances_dirty=false
    rest:=make([]Gpu_Instance,len(s.instances));defer delete(rest)
    copy(rest,s.instances[:])

    // 300 move: a run of 250 that crosses words of the set, and 50 apart from each other.
    moved:=make([dynamic]u32);defer delete(moved)
    places:=make([dynamic]Mat4);defer delete(places)
    for i in 100..<350 {append(&moved,u32(i));append(&places,at(i,1))}
    for i in 0..<50 {append(&moved,u32(500+i*3));append(&places,at(500+i*3,1))}
    testing.expect(t,scene_move(r,moved[:],places[:]))
    // Given the same places again, none moves and each still goes once.
    testing.expect(t,scene_move(r,moved[:10],places[:10]))
    testing.expect(t,!s.instances_dirty,"the table does not go whole")
    testing.expect_value(t,s.touched_count,300)
    runs,rows:=0,0
    for range,ok:=touched_range(s,0);ok;range,ok=touched_range(s,range.first+range.count) {
        if runs==0 {testing.expect_value(t,range,Pool_Range{100,250})}
        else {testing.expect_value(t,range,Pool_Range{u32(500+(runs-1)*3),1})}
        runs+=1
        rows+=int(range.count)
    }
    testing.expect_value(t,runs,51)
    testing.expect_value(t,rows,300)

    // The frame that sends them draws their motion: they go once more, at rest, and then no more.
    touched_settle(s)
    testing.expect_value(t,s.touched_count,300)
    for index in moved {testing.expect(t,s.instances[index].prev_world==s.instances[index].world)}
    touched_settle(s)
    testing.expect_value(t,s.touched_count,0)
    _,any:=touched_range(s,0)
    testing.expect(t,!any)
    still:=true
    for inst,i in s.instances {if i<100 || i>=350 && (i<500 || i>=650 || (i-500)%3!=0) {still&&=inst==rest[i]}}
    testing.expect(t,still,"what did not move was not written")

    // A set that moves some marks those alone to go again at rest.
    for index,i in moved {descs[index].transform=places[i]}
    descs[7].transform,descs[64].transform,descs[999].transform=at(7,2),at(64,2),at(999,2)
    testing.expect(t,scene_given(r,descs,nil,{},{}))
    testing.expect(t,s.touched_count==3 && instance_touched(s,7) && instance_touched(s,64) && instance_touched(s,999))
    // An instance the table no longer has is touched no more.
    testing.expect(t,scene_update(r,900,nil,true))
    testing.expect(t,s.touched_count==2 && len(s.instances)==900)
    testing.expect(t,scene_tint(r,{899,898},{{1,0,0},{1,1,1}},{{},{}}))
    testing.expect(t,s.touched_count==3 && instance_touched(s,899) && !instance_touched(s,898),"the tint it had touches nothing")
    // An instance given again with another highlight goes alone, and changes no light; given again as they are, none goes.
    touched_settle(s);touched_settle(s)
    s.instances_dirty=false
    s.changes={}
    descs[5].highlight=2
    testing.expect(t,scene_update(r,5,descs[5:6]))
    testing.expect(t,!s.instances_dirty && s.touched_count==1 && instance_touched(s,5) && s.highlighted==1 && s.changes.count==0 && !s.changes.all)
    touched_settle(s)
    testing.expect(t,scene_update(r,0,descs[:890]))
    testing.expect(t,!s.instances_dirty && s.touched_count==0 && s.highlighted==1 && s.changes.count==0)
}

// What the scene answers of an instance it was given: the rows of the
// material table it shows, its mesh and where it is in the world, whatever
// the origin of the renderer.
@(test)
the_scene_answers_what_an_instance_shows_and_where_it_is :: proc(t:^testing.T) {
    r:=new(Renderer);defer free(r)
    r.allocator=context.allocator
    scene_init(r)
    defer scene_destroy(r)
    vertices,indices:=edit_grid(1,1)
    defer delete(vertices);defer delete(indices)
    handle,_:=edit_add(r,vertices[:],indices[:],{0,0})
    materials_set(r,{DEFAULT_MATERIAL,DEFAULT_MATERIAL,DEFAULT_MATERIAL})
    r.origin={2048,0,-4096}
    desc:=Instance_Desc{object_id=1,mesh=handle,transform=Mat4(1),material=2,tint={1,1,1},overlays={count=1,entries={0={material=1,enabled=true}}}}
    desc.transform[0,3],desc.transform[1,3],desc.transform[2,3]=2050.5,3,-4000.25
    desc.slot_materials[0]=3
    testing.expect(t,scene_given(r,{desc},nil,{},{}))
    material,slots,overlays,shown:=scene_instance_materials(r,0)
    testing.expect(t,shown && material==2 && slots[0]==3 && slots[1]==0 && overlays.count==1 && overlays.entries[0].material==1)
    mesh,transform,placed:=scene_instance_placed(r,0)
    testing.expect(t,placed && mesh==handle)
    testing.expect_value(t,transform,desc.transform)
    // Described again in another place of the list, it keeps the motion from where it was.
    other:=desc
    other.object_id=5
    testing.expect(t,scene_update(r,1,{other}))
    was:=r.scene.instances[1].world
    other.transform[1,3]=4
    testing.expect(t,scene_update(r,0,{other}) && scene_instance_was(r,0,1) && !scene_instance_was(r,0,9))
    testing.expect(t,r.scene.instances[0].prev_world==was && r.scene.instances[0].world!=was)
    // A mesh the scene does not have is refused, and the scene stays as it was.
    testing.expect(t,!scene_update(r,0,{desc,Instance_Desc{object_id=2,mesh=Mesh_Handle(99),transform=Mat4(1)}},true) && len(r.scene.instances)==2)
    testing.expect(t,scene_update(r,1,nil,true))
    for missing in ([2]u32{1,7}) {
        _,_,_,shown=scene_instance_materials(r,missing)
        _,_,placed=scene_instance_placed(r,missing)
        testing.expect(t,!shown && !placed)
    }
}

// The values an instance gives over the rows of its materials are words of
// its own in the index pool: another value touches that instance alone, no
// row of the material table, and what goes gives its words back.
@(test)
the_values_of_an_instance_cost_words_of_the_pool_and_no_material_row :: proc(t:^testing.T) {
    r:=new(Renderer);defer free(r)
    r.allocator=context.allocator
    scene_init(r)
    defer scene_destroy(r)
    vertices,indices:=edit_grid(4,2)
    defer delete(vertices);defer delete(indices)
    handle,_:=edit_add(r,vertices[:],indices[:],{0,1})
    materials_set(r,{DEFAULT_MATERIAL,DEFAULT_MATERIAL})
    s:=&r.scene
    COUNT :: 1000
    descs:=make([]Instance_Desc,COUNT,context.temp_allocator)
    for &desc,i in descs {
        desc={object_id=u64(i+1),mesh=handle,transform=Mat4(1),tint={1,1,1}}
        desc.material_values={count=1,entries={0=instance_material_value(1,Instance_Material_Value_Target.Roughness,{f32(i)/COUNT,0,0,0})}}
    }
    rows,words:=len(s.materials),len(s.indices)
    if !testing.expect(t,scene_given(r,descs,nil,{},{})) {return}
    // What a thousand entities with a roughness of their own cost: before, a row of the table each.
    held:=(len(s.indices)-words)*size_of(u32)
    testing.expect_value(t,len(s.materials),rows)
    testing.expect_value(t,held,COUNT*(INSTANCE_VALUES_HEADER+INSTANCE_VALUE_WORDS)*size_of(u32))
    testing.expect(t,held*20<COUNT*size_of(Gpu_Material_Row),"a value is far smaller than the row it was")
    block:=instance_material_values_words(s,s.instances[7].material_values)
    if testing.expect_value(t,len(block),INSTANCE_VALUE_WORDS) {
        testing.expect(t,block[0]==1 && block[1]&0xff==u32(Instance_Material_Value_Target.Roughness) && transmute(f32)block[2]==7.0/COUNT)
    }

    // Another value of one instance: its words alone go to the GPU, and no light changes around it.
    for &ranges in s.pool_dirty {clear(&ranges)}
    for &word in s.touched {word=0}
    s.touched_count=0
    s.changes={}
    version:=s.material_versions[1] if len(s.material_versions)>1 else 0
    next:=descs[7].material_values
    next.entries[0]=instance_material_value(1,Instance_Material_Value_Target.Roughness,{0.5,0,0,0})
    testing.expect(t,scene_tint(r,{7,8},{{1,1,1},{1,1,1}},{{},{}},{next,descs[8].material_values}))
    testing.expect(t,len(s.pool_dirty[.Index])==1 && s.pool_dirty[.Index][0].count==INSTANCE_VALUES_HEADER+INSTANCE_VALUE_WORDS,"the words of that instance alone")
    testing.expect_value(t,s.touched_count,1)
    testing.expect_value(t,len(s.materials),rows)
    testing.expect_value(t,s.material_versions[1] if len(s.material_versions)>1 else 0,version)
    testing.expect_value(t,transmute(f32)instance_material_values_words(s,s.instances[7].material_values)[2],f32(0.5))
    // An emission is light: it changes around the instance that gives it.
    glow:=next
    glow.entries[1],glow.count=instance_material_value(1,Instance_Material_Value_Target.Emission,{4,4,4,0}),2
    testing.expect(t,scene_tint(r,{7},{{1,1,1}},{{}},{glow}) && (s.changes.all || s.changes.count>0))
    // A layer given in place puts it with what has layers, still without a row.
    coat:=next
    coat.entries[1],coat.count=instance_material_value(1,Instance_Material_Value_Target.Coat,{1,0,0,0}),2
    testing.expect(t,len(s.reflective)==0 && scene_tint(r,{7},{{1,1,1}},{{}},{coat}))
    testing.expect(t,len(s.reflective)==1 && s.reflective[0].instance==u32(7) && s.reflective[0].layered && len(s.materials)==rows)
    // A fade given in place blends every row it shows, but one a mode of its own masks.
    faded:=next
    faded.fade=0.5
    testing.expect(t,len(s.translucent)==0 && scene_tint(r,{7},{{1,1,1}},{{}},{faded}) && len(s.translucent)==1 && s.translucent[0].instance==7)
    testing.expect(t,s.instances[7].meta.w&INSTANCE_FLAG_BLENDED!=0)
    faded.entries[1],faded.count=instance_material_value(1,Instance_Material_Value_Target.Alpha_Mode,{f32(asset.Alpha_Mode.Mask),0,0,0}),2
    testing.expect(t,scene_tint(r,{7},{{1,1,1}},{{}},{faded}) && s.instances[7].meta.w&INSTANCE_FLAG_BLENDED==0 && len(s.materials)==rows)
    testing.expect(t,!scene_tint(r,{COUNT},{{1,1,1}},{{}},{next}) && !scene_tint(r,{1},{{1,1,1}},{{}},{next,next}),"a descriptor the scene does not have, lists that differ")

    // What goes gives its words back.
    testing.expect(t,scene_given(r,descs[:COUNT/2],nil,{},{}))
    testing.expect_value(t,len(s.indices)-words,COUNT/2*(INSTANCE_VALUES_HEADER+INSTANCE_VALUE_WORDS))
    testing.expect(t,scene_update(r,0,nil,true))
    testing.expect(t,scene_given(r,nil,nil,{},{}))
    testing.expect_value(t,len(s.indices),words)
    // Values an instance cannot hold are not there: no words past its own.
    full:=Instance_Material_Values{}
    for &entry,i in full.entries {entry={row=1,target=u32(i)|1<<8}}
    full.count=max(u32)
    only:=Instance_Desc{object_id=1,mesh=handle,transform=Mat4(1),tint={1,1,1},material_values=full}
    testing.expect(t,scene_given(r,{only},nil,{},{}))
    testing.expect_value(t,len(s.indices)-words,INSTANCE_VALUES_HEADER+INSTANCE_VALUES_MAX*INSTANCE_VALUE_WORDS)
}
