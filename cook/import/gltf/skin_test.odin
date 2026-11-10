package gltf

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:math/linalg"
import "mirai:std/base"
import mm "mirai:std/math"
import importer "mirai:cook/import"

@(test)
skinned_meshes_preserve_bind_geometry_and_the_mesh_basis :: proc(t:^testing.T) {
    model,ok:=import_ok(t,FIXTURES+"skeletal-analytic.gltf")
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.meshes),1)
    testing.expect_value(t,len(model.nodes),4)
    mesh_node:=find_node(&model,"mesh")
    testing.expect(t,mesh_node>=0 && model.nodes[mesh_node].mesh==0 && close_to(model.nodes[mesh_node].transform.position,{-3,0,0}),"the node keeps the transform of the mesh node")
    testing.expect(t,find_node(&model,"root bone")>=0,"joint entities preserve the source hierarchy and target identity")
    mesh:=&model.meshes[0]
    testing.expect_value(t,len(mesh.joints),2)
    testing.expect_value(t,len(mesh.skin),len(mesh.vertices))
    testing.expect_value(t,triangle_count(mesh),4)
    testing.expect(t,close_to(triangle_positions(mesh,1)[1],{-1,1,0}),"blended vertices remain in bind space")
    testing.expect(t,close_to(triangle_positions(mesh,3)[1],{-1,2,0}),"joint rotation does not deform imported vertices")
    testing.expect(t,close_to(triangle_positions(mesh,0)[0],{1,0,0}),"the mesh node transform is not applied twice")
    for vertex in mesh.vertices {
        n:=unpacked_normal(vertex)
        testing.expectf(t,abs(n.x*n.x+n.y*n.y+n.z*n.z-1)<1e-3,"bind normals stay unit length: %v",n)
    }
    testing.expect(t,mesh.bounds_max.y>1.9 && mesh.bounds_max.x>0.9,"bounds describe the bind geometry")
    bones:=model.skeletons[mesh.skeleton].bones
    world:=make([]mm.Mat4,len(bones),context.temp_allocator)
    for node,i in bones {
        world[i]=mm.transform_matrix({position=node.translation,rotation=node.rotation,scale=node.scale})
        if node.parent>=0 {world[i]=world[node.parent]*world[i]}
        testing.expect(t,node.target!=0)
    }
    testing.expect_value(t,model.nodes[mesh_node].target,base.name_hash("shared root/mesh"))
    mesh_inverse:=linalg.inverse(mm.transform_matrix(world_transform(&model,mesh_node)))
    vertex:=mesh.indices[1*3+1]
    posed:[3]f32
    for weight,i in mesh.skin[vertex].weights {
        if weight==0 {continue}
        joint:=mesh.joints[mesh.skin[vertex].joints[i]]
        posed+=mm.mat4_point(mesh_inverse*world[joint.node]*joint.inverse_bind,mesh.vertices[vertex].position)*f32(weight)/255
    }
    testing.expectf(t,close_to(posed,{-.5,1.5,0},0.01),"evaluating the palette once reproduces the authored rest pose, within 8-bit weights: %v",posed)
    // An unused influence may name a joint outside the rig: glTF only recommends 0.
    for influence in mesh.skin {
        for weight,i in influence.weights {
            if weight==0 {testing.expect_value(t,influence.joints[i],u16(0))}
        }
        sum:=int(influence.weights[0])+int(influence.weights[1])+int(influence.weights[2])+int(influence.weights[3])
        testing.expect_value(t,sum,255)
    }
    testing.expect(t,len(bones)>=2 && bones[0].parent==-1)
    for node,i in bones {testing.expect(t,int(node.parent)<i,"a parent comes before its children")}
    for joint in mesh.joints {testing.expect(t,int(joint.node)<len(bones))}

    binary,binary_ok:=import_ok(t,FIXTURES+"skeletal-analytic.glb")
    if !binary_ok {return}
    defer importer.model_destroy(&binary)
    testing.expect_value(t,len(binary.meshes[0].vertices),len(mesh.vertices))
    for i in 0..<triangle_count(mesh) {
        a,b:=triangle_positions(mesh,i),triangle_positions(&binary.meshes[0],i)
        for k in 0..<3 {testing.expect(t,close_to(a[k],b[k],1e-6),"glb and gltf preserve the same bind pose")}
    }
}

@(test)
the_robot_is_one_skinned_mesh_with_its_rig :: proc(t:^testing.T) {
    model,ok:=import_ok(t,DEMO+"characters/robot/robot.glb")
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.nodes),14)
    testing.expect_value(t,len(model.meshes),1)
    mesh:=&model.meshes[0]
    testing.expect_value(t,len(mesh.joints),13)
    testing.expect(t,triangle_count(mesh)>1000)
    blended:=false
    for influence in mesh.skin {
        if influence.weights[0]>0 && influence.weights[1]>0 {blended=true;break}
    }
    testing.expect(t,blended,"the robot has blended skin weights")
    testing.expect_value(t,len(model.warnings),0)
}

@(test)
simple_skin_of_khronos_imports_with_external_buffers :: proc(t:^testing.T) {
    model,ok:=import_ok(t,FIXTURES+"khronos-simple-skin/SimpleSkin.gltf")
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.nodes),3)
    mesh:=&model.meshes[0]
    testing.expect(t,triangle_count(mesh)==8 && len(mesh.joints)==2,"external skeleton nodes preserve their hierarchy")
    testing.expect(t,mesh.bounds_max.y>mesh.bounds_min.y && importer.finite3(mesh.bounds_min) && importer.finite3(mesh.bounds_max))
}

@(test)
invalid_skin_weights_are_rejected :: proc(t:^testing.T) {
    source,read_error:=os.read_entire_file(FIXTURES+"skeletal-analytic.gltf",context.temp_allocator)
    testing.expect(t,read_error==nil)
    folder:=base.test_folder(t,"skin-invalid")
    if folder=="" {return}
    binary,binary_error:=os.read_entire_file(FIXTURES+"skeletal-analytic.bin",context.temp_allocator)
    testing.expect(t,binary_error==nil)
    _=os.write_entire_file(fmt.tprintf("%s/skeletal-analytic.bin",folder),binary)
    text,_:=strings.replace_all(string(source),`"WEIGHTS_0"`,`"TEXCOORD_1"`,context.temp_allocator)
    path:=write_text(folder,"invalid.gltf",text)
    _,error:=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Malformed)
    testing.expect(t,contains(error.message,"WEIGHTS_0"),error.message)
}

@(test)
gltf_preserves_all_eight_skin_influences :: proc(t:^testing.T) {
    source,read_error:=os.read_entire_file(FIXTURES+"skeletal-analytic.gltf",context.temp_allocator)
    if !testing.expect_value(t,read_error,nil) {return}
    binary,binary_error:=os.read_entire_file(FIXTURES+"skeletal-analytic.bin",context.temp_allocator)
    if !testing.expect_value(t,binary_error,nil) {return}
    folder:=base.test_folder(t,"skin-eight")
    if folder=="" {return}
    if !testing.expect_value(t,os.write_entire_file(fmt.tprintf("%s/skeletal-analytic.bin",folder),binary),nil) {return}
    text,_:=strings.replace_all(string(source),`"WEIGHTS_0": 3`,`"WEIGHTS_0": 3, "JOINTS_1": 2, "WEIGHTS_1": 3`,context.temp_allocator)
    model,error:=importer.import_model(write_text(folder,"eight.gltf",text),FORMATS[:])
    if !testing.expect_value(t,error.code,importer.Error_Code.None) {return}
    defer importer.model_destroy(&model)
    for influence in model.meshes[0].skin {
        sum,second:int
        for weight,i in influence.weights {
            sum+=int(weight)
            if i<4 {testing.expect(t,abs(int(weight)-int(influence.weights[i+4]))<=1,"the second set weighs as the first")} else {second+=int(weight)}
        }
        testing.expect(t,sum==255 && abs(second*2-255)<=2,"each set weighs half")
    }
}
