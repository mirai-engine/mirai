package obj

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import importer "mirai:cook/import"
import mm "mirai:std/math"

@(test)
a_concave_polygon_triangulates_without_filling_its_notch :: proc(t:^testing.T) {
    model,ok:=import_ok(t,FIXTURES+"concave.obj")
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.meshes),1)
    testing.expect_value(t,len(model.nodes),1)
    mesh:=&model.meshes[0]
    testing.expect_value(t,mesh.name,"ConcaveL")
    testing.expect_value(t,triangle_count(mesh),4)
    testing.expect(t,abs(mesh_area(mesh)-3)<1e-5,"the six-corner polygon keeps its notch and area")
    testing.expect_value(t,len(mesh.vertices),6)
    testing.expect(t,.Has_Colors in mesh.flags,"the vertex colors of the file are kept")
    for vertex in mesh.vertices {
        testing.expect_value(t,vertex.color,u32(0xff0000ff))
        testing.expect(t,close_to(unpacked_normal(vertex),{0,0,-1},1e-3),"a face without normals is flat")
    }
    testing.expect(t,close_to(mesh.bounds_min,{-2,0,0}) && close_to(mesh.bounds_max,{0,2,0}))
    testing.expect_value(t,len(model.materials),1)
    red:=&model.materials[0]
    testing.expect_value(t,red.name,"red")
    testing.expect(t,close_to(red.info.base_color,{0.5,1,0.5}) && close_to(red.info.emission,{0.1,0,0}),"Kd and Ke become base color and emission")
    testing.expect_value(t,len(mesh.slots),1)
    testing.expect(t,mesh.slots[0].label=="red" && mesh.slots[0].material==0 && mesh.slots[0].id==1)
    testing.expect_value(t,len(mesh.submeshes),1)
    testing.expect_value(t,mesh.submeshes[0].index_count,u32(12))
    testing.expect_value(t,len(model.warnings),0)
}

@(test)
objects_of_one_file_become_separate_meshes_and_nodes :: proc(t:^testing.T) {
    model,ok:=import_ok(t,FIXTURES+"multiple.obj")
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.meshes),2)
    testing.expect_value(t,len(model.nodes),2)
    testing.expect(t,model.meshes[0].name=="Near" && model.meshes[1].name=="Far")
    testing.expect(t,close_to(model.meshes[1].bounds_min,{-11,0,0}) && close_to(model.meshes[1].bounds_max,{-10,1,0}))
    testing.expect(t,model.nodes[0].parent==-1 && model.nodes[1].mesh==1)
    testing.expect_value(t,len(model.meshes[0].slots),1)
    testing.expect_value(t,model.meshes[0].slots[0].label,"Slot 1")
    testing.expect_value(t,model.meshes[0].slots[0].material,-1)
}

@(test)
normals_texture_coordinates_and_maps_of_an_mtl_survive :: proc(t:^testing.T) {
    folder:=temp_folder("obj-material")
    defer os.remove_all(folder)
    write_text(folder,"wall.mtl",`newmtl plaster
Kd 0.8 0.6 0.4
Ns 250
Pm 0.25
map_Kd color map.png
map_Bump -bm 0.5 normal.png
newmtl unused
Kd 1 0 0
map_Kd unused.png
`)
    path:=write_text(folder,"wall.obj",`mtllib wall.mtl
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
vt 0 0
vt 1 0
vt 1 1
vt 0 1
vn 0 0 1
vn 1 0 1
usemtl plaster
f 1/1/1 2/2/2 3/3/1
f 1/1 3/3 4/4
`)
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    mesh:=&model.meshes[0]
    testing.expect_value(t,triangle_count(mesh),2)
    first,second:=importer.mesh_triangle(mesh,0),importer.mesh_triangle(mesh,1)
    testing.expect(t,first[0].uv=={0,1} && first[1].uv=={1,1} && first[2].uv=={1,0},"OBJ counts v from the bottom of the image")
    testing.expect(t,close_to(unpacked_normal(first[0]),{0,0,-1},1e-3) && close_to(unpacked_normal(first[1]),{-0.70710678,0,-0.70710678},1e-3),"the normals of the file are kept per corner")
    testing.expect(t,close_to(unpacked_normal(second[0]),{0,0,-1},1e-3) && second[2].uv=={0,0},"a face without normals is flat and keeps its texture coordinates")
    testing.expect_value(t,len(mesh.vertices),4)
    testing.expect_value(t,len(model.materials),1)
    plaster:=&model.materials[0]
    testing.expect_value(t,plaster.name,"plaster")
    testing.expect(t,abs(plaster.info.roughness-0.5)<1e-5 && abs(plaster.info.metallic-0.25)<1e-5 && abs(plaster.info.normal_scale-0.5)<1e-5,"Ns, Pm and -bm become roughness, metallic and normal scale")
    color,normal:=plaster.images[.Base_Color],plaster.images[.Normal]
    testing.expect(t,color>=0 && normal>=0 && plaster.images[.Emission]<0)
    testing.expect_value(t,len(model.images),2)
    if color<0 || normal<0 {return}
    testing.expect(t,strings.has_suffix(model.images[color].path,"/color map.png") && model.images[color].srgb && !model.images[color].normal_map,"a map is a file next to the MTL, with the spaces of its name")
    testing.expect(t,model.images[normal].normal_map && !model.images[normal].srgb,"a bump statement is read as a normal map")
}

@(test)
transparency_and_blender_roughness_follow_the_mtl_conventions :: proc(t:^testing.T) {
    folder:=temp_folder("obj-alpha")
    defer os.remove_all(folder)
    write_text(folder,"m.mtl","newmtl glass\nTr 0.75\nNs 1000\nnewmtl exact\nNs 1000\nPr 0.3\nd 1\n")
    path:=write_text(folder,"m.obj","mtllib m.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nusemtl glass\nf 1 2 3\nusemtl exact\nf 1 2 3\nusemtl absent\nf 1 2 3\n")
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.materials),2)
    glass,exact:=model.materials[0],model.materials[1]
    testing.expect(t,glass.info.alpha_mode==.Blend && abs(glass.info.opacity-0.25)<1e-5 && abs(glass.info.roughness-0)<1e-5,"Tr is the opposite of d; Ns without Pr is Blender's roughness")
    testing.expect(t,exact.info.alpha_mode==.Opaque && abs(exact.info.roughness-0.3)<1e-5,"Pr wins over Ns")
    mesh:=&model.meshes[0]
    testing.expect_value(t,len(mesh.slots),3)
    testing.expect(t,mesh.slots[2].label=="absent" && mesh.slots[2].material==-1,"a material the MTL does not define still gets a slot")
    testing.expect_value(t,len(mesh.submeshes),3)
    testing.expect(t,mesh.submeshes[1].slot==1 && mesh.submeshes[1].first_index==3)
}

@(test)
faces_of_several_materials_are_grouped_by_slot :: proc(t:^testing.T) {
    folder:=temp_folder("obj-slots")
    defer os.remove_all(folder)
    path:=write_text(folder,"s.obj","v 0 0 0\nv 1 0 0\nv 0 1 0\nusemtl a\nf 1 2 3\nusemtl b\nf 1 2 3\nusemtl a\nf 3 2 1\n")
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    mesh:=&model.meshes[0]
    testing.expect_value(t,len(mesh.submeshes),2)
    testing.expect(t,mesh.submeshes[0].slot==0 && mesh.submeshes[0].index_count==6 && mesh.submeshes[1].slot==1 && mesh.submeshes[1].first_index==6)
    for vertex in mesh.vertices[:2] {testing.expect(t,vertex.material<2)}
}

@(test)
a_broken_obj_fails_cleanly_and_leaves_nothing_behind :: proc(t:^testing.T) {
    folder:=temp_folder("obj-broken")
    defer os.remove_all(folder)
    path:=write_text(folder,"invalid.obj","v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 99\n")
    _,error:=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Malformed)
    testing.expect(t,strings.contains(error.message,"outside"),error.message)

    write_text(folder,"invalid.mtl","newmtl paint\nKd 1 0 0\nmap_Kd paint.png\n")
    path=write_text(folder,"invalid.obj","mtllib invalid.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nusemtl paint\nf 1 2 3\nf 1 2 99\n")
    _,error=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Malformed)

    path=write_text(folder,"number.obj","v 0 zero 0\n")
    _,error=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Malformed)

    path=write_text(folder,"empty.obj","# nothing\n")
    _,error=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Malformed)

    _,error=importer.import_model(fmt.tprintf("%s/missing.obj",folder),FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Not_Found)

    path=write_text(folder,"model.fbx","; FBX 7.4.0 project file")
    _,error=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Unsupported)
}

@(test)
faces_without_area_are_skipped_with_a_warning :: proc(t:^testing.T) {
    folder:=temp_folder("obj-degenerate")
    defer os.remove_all(folder)
    path:=write_text(folder,"d.obj","v 0 0 0\nv 1 0 0\nv 2 0 0\nv 0 1 0\nf 1 2 3\nf 1 2 4\n")
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,triangle_count(&model.meshes[0]),1)
    testing.expect_value(t,len(model.warnings),1)
    testing.expect(t,strings.contains(model.warnings[0],"without area"))
}

@(test)
a_model_larger_than_the_scratch_memory_of_its_caller_imports :: proc(t:^testing.T) {
    QUADS :: 4000
    folder:=temp_folder("obj-large")
    defer os.remove_all(folder)
    text:=strings.builder_make();defer strings.builder_destroy(&text)
    for i in 0..=QUADS {fmt.sbprintf(&text,"v %d 0 0\nv %d 0 1\n",i,i)}
    for i in 0..<QUADS {a:=i*2+1;fmt.sbprintf(&text,"f %d %d %d %d\n",a,a+1,a+3,a+2)}
    path:=write_text(folder,"strip.obj",string(text.buf[:]))
    memory:=make([]byte,64*1024);defer delete(memory)
    arena:mem.Arena
    mem.arena_init(&arena,memory)
    context.temp_allocator=mem.arena_allocator(&arena)
    model,error:=importer.import_model(path,FORMATS[:])
    defer importer.model_destroy(&model)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    testing.expect_value(t,triangle_count(&model.meshes[0]),QUADS*2)
    testing.expect_value(t,len(model.meshes[0].vertices),(QUADS+1)*2)
    _,error=importer.import_model(fmt.tprintf("%s/missing.obj",folder),FORMATS[:])
    testing.expect(t,error.code==.Not_Found && strings.contains(error.message,"missing.obj"),"the reason of a failure outlives the memory of the import")
}

@(test)
the_vase_of_the_demo_imports_without_warnings :: proc(t:^testing.T) {
    model,ok:=import_ok(t,DEMO+"models/vase.obj")
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.warnings),0)
    testing.expect_value(t,len(model.nodes),1)
    testing.expect_value(t,len(model.meshes),1)
    testing.expect_value(t,len(model.meshes[0].slots),2)
    testing.expect_value(t,len(model.materials),2)
    testing.expect_value(t,len(model.images),1)
    testing.expect(t,model.images[0].srgb && strings.has_suffix(model.images[0].path,"/demo/source/textures/vase_color.png"),model.images[0].path)
}

@(test)
a_path_with_a_control_character_is_not_read :: proc(t:^testing.T) {
    folder:=temp_folder("control")
    defer os.remove_all(folder)
    write_text(folder,"c.mtl","newmtl a\nKd 1 0 0\n")
    path:=write_text(folder,"c.obj","mtllib c\x00.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nusemtl a\nf 1 2 3\n")
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect(t,len(model.materials)==0 && len(model.warnings)==1,"the library behind the control character is not read")
}

// Two halves that mirror their uvs across x = 0, as a symmetric model is
// baked: MikkTSpace turns the tangent around on the mirrored half and keeps
// the bitangent up the image (+Y here, since OBJ counts v from the bottom).
@(test)
mirrored_uvs_turn_the_tangent_and_keep_the_bitangent :: proc(t:^testing.T) {
    folder:=temp_folder("obj-mirror")
    defer os.remove_all(folder)
    path:=write_text(folder,"mirror.obj",`v -1 0 0
v 0 0 0
v 0 1 0
v -1 1 0
v 1 0 0
v 1 1 0
vt 0 0
vt 1 0
vt 1 1
vt 0 1
vt 0 0
vt 0 1
vn 0 0 1
f 1/1/1 2/2/1 3/3/1
f 1/1/1 3/3/1 4/4/1
f 2/2/1 5/5/1 6/6/1
f 2/2/1 6/6/1 3/3/1
`)
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    mesh:=&model.meshes[0]
    testing.expect_value(t,len(mesh.vertices),8)
    for i in 0..<triangle_count(mesh) {
        corners:=importer.mesh_triangle(mesh,i)
        side:=f32(1) if corners[0].position.x+corners[1].position.x+corners[2].position.x>0 else -1
        for corner in corners {
            tangent,sign:=mm.tangent_unpack(corner.tangent)
            bitangent:=sign*linalg.cross(unpacked_normal(corner),tangent)
            testing.expectf(t,close_to(tangent,{-side,0,0},1e-3) && close_to(bitangent,{0,1,0},1e-3),"triangle %d: tangent %v, bitangent %v",i,tangent,bitangent)
        }
    }
}
