package gltf

import "core:encoding/base64"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:std/base"

// A tetrahedron of a meter whose box collider stands 3 m above it, drawn by
// the nodes given (the scene holds node 0); the collider is node 1.
@(private="file")
scaled_gltf :: proc(nodes,scene:string) -> string {
    positions:=[12]f32{0,0,0, 1,0,0, 0,1,0, 0,0,1}
    order:=[12]u16{0,2,1, 0,1,3, 0,3,2, 1,2,3}
    bytes:=make([dynamic]u8,context.temp_allocator)
    append(&bytes,..mem.slice_to_bytes(positions[:]))
    append(&bytes,..mem.slice_to_bytes(order[:]))
    encoded,_:=base64.encode(bytes[:],allocator=context.temp_allocator)
    return strings.concatenate({`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":`,scene,`}],
        "extensionsUsed":["KHR_physics_rigid_bodies","KHR_implicit_shapes"],
        "extensions":{"KHR_implicit_shapes":{"shapes":[{"type":"box","box":{"size":[2,4,6]}}]}},
        "buffers":[{"byteLength":72,"uri":"data:application/octet-stream;base64,`,encoded,`"}],
        "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":24}],
        "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[0,0,0],"max":[1,1,1]},{"bufferView":1,"componentType":5123,"count":12,"type":"SCALAR"}],
        "meshes":[{"name":"Prop","primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
        "nodes":`,nodes,`}`},context.temp_allocator)
}

@(private="file")
scale_warned :: proc(model:^importer.Imported_Model,text:string) -> bool {
    for warning in model.warnings {if strings.contains(warning,text) {return true}}
    return false
}

// bake_scale puts a positive scale that is the same on every axis into the
// mesh its node draws: vertices, bounds and colliders grow by it, the node
// takes 1 and what hangs from it the scale it lost, so it stays where it was.
// It keeps a negative, an uneven or a skinned scale, and that of a mesh nodes
// of different scales draw, with a warning that says why. Without it, the
// same file imports as it is, and a mesh drawn at more than twice or less
// than half its size is warned of.
@(test)
bake_scale_puts_a_uniform_scale_into_its_mesh_and_keeps_what_it_cannot :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"gltf-bake-scale")
    if folder=="" {return}
    COLLIDER :: `{"name":"Box","translation":[0,3,0],"extensions":{"KHR_physics_rigid_bodies":{"collider":{"geometry":{"shape":0}}}}}`
    Case :: struct {
        name:string,
        nodes,scene:string,
        bake:bool,
        grown:f32,      // how much the mesh grew: 1 when it was not baked
        kept:[3]f32,    // the scale node Prop keeps
        warned:string,  // what a warning says; "": there is none
    }
    cases:=[?]Case{
        {"baked",`[{"name":"Prop","mesh":0,"scale":[100,100,100],"children":[1,2]},`+COLLIDER+`,{"name":"Socket","translation":[0,1,0]}]`,"[0]",true,100,{1,1,1},""},
        {"default",`[{"name":"Prop","mesh":0,"scale":[100,100,100],"children":[1,2]},`+COLLIDER+`,{"name":"Socket","translation":[0,1,0]}]`,"[0]",false,1,{100,100,100},"at 100 times their size"},
        {"small",`[{"name":"Prop","mesh":0,"scale":[0.01,0.01,0.01],"children":[1]},`+COLLIDER+`]`,"[0]",false,1,{0.01,0.01,0.01},"at 0.01 times their size"},
        {"parent",`[{"name":"Units","scale":[100,100,100],"children":[2]},`+COLLIDER+`,{"name":"Prop","mesh":0,"children":[1]}]`,"[0]",true,100,{1,1,1},""},
        {"negative",`[{"name":"Prop","mesh":0,"scale":[-2,-2,-2],"children":[1]},`+COLLIDER+`]`,"[0]",true,1,{-2,-2,-2},"its scale is negative"},
        {"uneven",`[{"name":"Prop","mesh":0,"scale":[1,2,1],"children":[1]},`+COLLIDER+`]`,"[0]",true,1,{1,2,1},"not the same on every axis"},
        {"shared",`[{"name":"Prop","mesh":0,"scale":[3,3,3],"children":[1]},`+COLLIDER+`,{"name":"Other","mesh":0,"scale":[4,4,4]}]`,"[0,2]",true,1,{3,3,3},"nodes of other scales draw its mesh"},
        {"same",`[{"name":"Prop","mesh":0,"scale":[3,3,3],"children":[1]},`+COLLIDER+`,{"name":"Other","mesh":0,"scale":[3,3,3]}]`,"[0,2]",true,3,{1,1,1},""},
    }
    for c in cases {
        path:=write_text(folder,fmt.tprintf("%s.gltf",c.name),scaled_gltf(c.nodes,c.scene))
        model,error:=importer.import_model(path,FORMATS[:],{settings={bake_scale=c.bake},ignore_stored=true})
        if !testing.expectf(t,error.code==.None,"%s: %s",c.name,error.message) {continue}
        defer importer.model_destroy(&model)
        prop:=find_node(&model,"Prop")
        if !testing.expectf(t,prop>=0 && len(model.meshes)==1,"%s: the prop and its mesh",c.name) {continue}
        mesh:=&model.meshes[0]
        testing.expectf(t,abs(mesh.bounds_max.y-c.grown)<1e-3,"%s: bounds %v",c.name,mesh.bounds_max)
        tallest:=f32(0)
        for v in mesh.vertices {tallest=max(tallest,v.position.y)}
        testing.expectf(t,abs(tallest-c.grown)<1e-3,"%s: the vertices reach %v",c.name,tallest)
        box:=mesh.collision.colliders[0] if len(mesh.collision.colliders)>0 else asset.Collider{}
        testing.expectf(t,box.kind==.Box && linalg.length(box.center-[3]f32{0,3,0}*c.grown)<1e-2 && linalg.length(box.size-[3]f32{1,2,3}*c.grown)<1e-2,"%s: the collider %v",c.name,box)
        testing.expectf(t,linalg.length(model.nodes[prop].transform.scale-c.kept)<1e-4,"%s: the node keeps %v",c.name,model.nodes[prop].transform.scale)
        // Every node stays where it was, its size in the world with it.
        if socket:=find_node(&model,"Socket");socket>=0 {
            testing.expectf(t,linalg.length(world_transform(&model,socket).position-[3]f32{0,100,0})<1e-2,"%s: the socket %v",c.name,world_transform(&model,socket).position)
        }
        if c.warned=="" {testing.expectf(t,len(model.warnings)==0,"%s: %v",c.name,model.warnings)}
        else {testing.expectf(t,scale_warned(&model,c.warned),"%s: no warning says '%s': %v",c.name,c.warned,model.warnings)}
    }
}

// A rig keeps the scales of its nodes: a skin binds the space its joints
// were bound in.
@(test)
bake_scale_keeps_the_scale_above_a_skinned_mesh :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"gltf-bake-scale-skin")
    if folder=="" {return}
    text,read_error:=os.read_entire_file(FIXTURES+"skeletal-analytic.gltf",context.temp_allocator)
    binary,binary_error:=os.read_entire_file(FIXTURES+"skeletal-analytic.bin",context.temp_allocator)
    if !testing.expect(t,read_error==nil && binary_error==nil) {return}
    _=os.write_entire_file(fmt.tprintf("%s/skeletal-analytic.bin",folder),binary)
    scaled,replaced:=strings.replace(string(text),`"name": "shared root",`,`"name": "shared root", "scale": [100, 100, 100],`,1,context.temp_allocator)
    if !testing.expect(t,replaced,"the fixture has its shared root") {return}
    path:=write_text(folder,"rig.gltf",scaled)
    model,error:=importer.import_model(path,FORMATS[:],{settings={bake_scale=true},ignore_stored=true})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.model_destroy(&model)
    root:=find_node(&model,"shared root")
    testing.expect(t,root>=0 && linalg.length(model.nodes[root].transform.scale-[3]f32{100,100,100})<1e-3,"the root keeps its scale")
    testing.expectf(t,scale_warned(&model,"skinned mesh"),"%v",model.warnings)
}
