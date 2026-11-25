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

// The scale of the root of a file goes into the meshes one node alone draws:
// vertices, bounds and colliders grow by it, the nodes above take 1 and what
// hangs from them the scale they lost, so every node stays where it was. The
// scale of a node below the root is its own, as are a negative and an uneven
// one, and a mesh other nodes also draw keeps it on its nodes. Only what still
// draws a mesh at a change of units is warned of, never a level's own scales.
@(test)
the_root_scale_goes_into_the_meshes_and_only_a_change_of_units_left_warns :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"gltf-root-scale")
    if folder=="" {return}
    COLLIDER :: `{"name":"Box","translation":[0,3,0],"extensions":{"KHR_physics_rigid_bodies":{"collider":{"geometry":{"shape":0}}}}}`
    SOCKET :: `{"name":"Socket","translation":[0,1,0]}`
    Case :: struct {
        name:string,
        nodes,scene:string,
        grown:f32,      // how much the mesh grew: 1 when it was not baked
        kept:[3]f32,    // the scale node Prop keeps
        socket:f32,     // the height of the socket in the world, when there is one
        warned:string,  // what a warning says; "": there is none
    }
    cases:=[?]Case{
        {"root",`[{"name":"Prop","mesh":0,"scale":[100,100,100],"children":[1,2]},`+COLLIDER+`,`+SOCKET+`]`,"[0]",100,{1,1,1},100,""},
        {"small",`[{"name":"Prop","mesh":0,"scale":[0.01,0.01,0.01],"children":[1]},`+COLLIDER+`]`,"[0]",0.01,{1,1,1},0,""},
        {"group",`[{"name":"Units","scale":[100,100,100],"children":[2]},`+COLLIDER+`,{"name":"Prop","mesh":0,"children":[1,3]},`+SOCKET+`]`,"[0]",100,{1,1,1},100,""},
        {"chain",`[{"name":"Units","scale":[10,10,10],"children":[2]},`+COLLIDER+`,{"name":"Fbx","scale":[10,10,10],"children":[3,4]},{"name":"Prop","mesh":0,"children":[1]},{"name":"Lamp"}]`,"[0]",100,{1,1,1},0,""},
        {"own",`[{"name":"Level","children":[2,3]},`+COLLIDER+`,{"name":"Prop","mesh":0,"scale":[3,3,3],"children":[1]},{"name":"Lamp"}]`,"[0]",1,{3,3,3},0,""},
        {"instances",`[{"name":"Prop","mesh":0,"scale":[3,3,3],"children":[1]},`+COLLIDER+`,{"name":"Other","mesh":0,"scale":[3,3,3]}]`,"[0,2]",1,{3,3,3},0,""},
        {"shared",`[{"name":"Units","scale":[100,100,100],"children":[2,3]},`+COLLIDER+`,{"name":"Prop","mesh":0,"children":[1]},{"name":"Other","mesh":0}]`,"[0]",1,{100,100,100},0,"at 100 times their size"},
        {"deep",`[{"name":"Level","children":[2,3]},`+COLLIDER+`,{"name":"Prop","mesh":0,"scale":[0.01,0.01,0.01],"children":[1]},{"name":"Lamp"}]`,"[0]",1,{0.01,0.01,0.01},0,"at 0.01 times their size"},
        {"negative",`[{"name":"Prop","mesh":0,"scale":[-2,-2,-2],"children":[1]},`+COLLIDER+`]`,"[0]",1,{-2,-2,-2},0,""},
        {"uneven",`[{"name":"Prop","mesh":0,"scale":[1,2,1],"children":[1]},`+COLLIDER+`]`,"[0]",1,{1,2,1},0,""},
    }
    for c in cases {
        path:=write_text(folder,fmt.tprintf("%s.gltf",c.name),scaled_gltf(c.nodes,c.scene))
        model,error:=importer.import_model(path,FORMATS[:],{ignore_stored=true})
        if !testing.expectf(t,error.code==.None,"%s: %s",c.name,error.message) {continue}
        defer importer.model_destroy(&model)
        prop:=find_node(&model,"Prop")
        if !testing.expectf(t,prop>=0 && len(model.meshes)==1,"%s: the prop and its mesh",c.name) {continue}
        mesh:=&model.meshes[0]
        testing.expectf(t,abs(mesh.bounds_max.y-c.grown)<1e-3*c.grown,"%s: bounds %v",c.name,mesh.bounds_max)
        tallest:=f32(0)
        for v in mesh.vertices {tallest=max(tallest,v.position.y)}
        testing.expectf(t,abs(tallest-c.grown)<1e-3*c.grown,"%s: the vertices reach %v",c.name,tallest)
        box:=mesh.collision.colliders[0] if len(mesh.collision.colliders)>0 else asset.Collider{}
        testing.expectf(t,box.kind==.Box && linalg.length(box.center-[3]f32{0,3,0}*c.grown)<1e-2*c.grown && linalg.length(box.size-[3]f32{1,2,3}*c.grown)<1e-2*c.grown,"%s: the collider %v",c.name,box)
        testing.expectf(t,linalg.length(model.nodes[prop].transform.scale-c.kept)<1e-4*linalg.length(c.kept),"%s: the node keeps %v",c.name,model.nodes[prop].transform.scale)
        // Every node stays where it was, its size in the world with it.
        if socket:=find_node(&model,"Socket");socket>=0 {
            testing.expectf(t,linalg.length(world_transform(&model,socket).position-[3]f32{0,c.socket,0})<1e-2,"%s: the socket %v",c.name,world_transform(&model,socket).position)
        }
        if c.warned=="" {testing.expectf(t,len(model.warnings)==0,"%s: %v",c.name,model.warnings)}
        else {testing.expectf(t,scale_warned(&model,c.warned),"%s: no warning says '%s': %v",c.name,c.warned,model.warnings)}
    }
}

// A rig keeps the scale of its root: a skin binds the space its joints were
// bound in. A skinned mesh is drawn by its joints, never warned of.
@(test)
the_root_scale_above_a_skinned_mesh_stays :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"gltf-root-scale-skin")
    if folder=="" {return}
    text,read_error:=os.read_entire_file(FIXTURES+"skeletal-analytic.gltf",context.temp_allocator)
    binary,binary_error:=os.read_entire_file(FIXTURES+"skeletal-analytic.bin",context.temp_allocator)
    if !testing.expect(t,read_error==nil && binary_error==nil) {return}
    _=os.write_entire_file(fmt.tprintf("%s/skeletal-analytic.bin",folder),binary)
    scaled,replaced:=strings.replace(string(text),`"name": "shared root",`,`"name": "shared root", "scale": [100, 100, 100],`,1,context.temp_allocator)
    if !testing.expect(t,replaced,"the fixture has its shared root") {return}
    path:=write_text(folder,"rig.gltf",scaled)
    model,error:=importer.import_model(path,FORMATS[:],{ignore_stored=true})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.model_destroy(&model)
    root:=find_node(&model,"shared root")
    testing.expect(t,root>=0 && linalg.length(model.nodes[root].transform.scale-[3]f32{100,100,100})<1e-3,"the root keeps its scale")
    testing.expectf(t,len(model.warnings)==0,"%v",model.warnings)
}
