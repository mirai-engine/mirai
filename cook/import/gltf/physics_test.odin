package gltf

import "core:encoding/base64"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import importer "mirai:cook/import"

// The colliders of KHR_physics_rigid_bodies (with KHR_implicit_shapes) and
// OMI_physics_body (with OMI_physics_shape) on the nodes under a mesh are
// colliders of that mesh, where they are in its space: an implicit box and
// sphere, and a hull of a mesh no node draws. The nodes of the colliders and
// that mesh leave the model; a trigger is left out with a warning.
@(test)
the_physics_extensions_of_a_gltf_are_the_colliders_of_its_mesh :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"gltf-physics")
    if folder=="" {return}
    positions:=[12]f32{0,0,0, 1,0,0, 0,1,0, 0,0,1}
    order:=[12]u16{0,2,1, 0,1,3, 0,3,2, 1,2,3}
    bytes:=make([dynamic]u8,context.temp_allocator)
    append(&bytes,..mem.slice_to_bytes(positions[:]))
    append(&bytes,..mem.slice_to_bytes(order[:]))
    encoded,_:=base64.encode(bytes[:],allocator=context.temp_allocator)
    text:=strings.concatenate({`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
        "extensionsUsed":["KHR_physics_rigid_bodies","KHR_implicit_shapes","OMI_physics_body","OMI_physics_shape"],
        "extensions":{"KHR_implicit_shapes":{"shapes":[{"type":"box","box":{"size":[2,4,6]}}]},"OMI_physics_shape":{"shapes":[{"type":"sphere","sphere":{"radius":0.5}}]}},
        "buffers":[{"byteLength":72,"uri":"data:application/octet-stream;base64,`,encoded,`"}],
        "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":24}],
        "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[0,0,0],"max":[1,1,1]},{"bufferView":1,"componentType":5123,"count":12,"type":"SCALAR"}],
        "meshes":[{"name":"Crate","primitives":[{"attributes":{"POSITION":0},"indices":1}]},{"name":"Shell","primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
        "nodes":[
            {"name":"Crate","mesh":0,"children":[1,2,3,4]},
            {"name":"Box","translation":[0,3,0],"extensions":{"KHR_physics_rigid_bodies":{"collider":{"geometry":{"shape":0}}}}},
            {"name":"Shell","translation":[5,0,0],"extensions":{"KHR_physics_rigid_bodies":{"collider":{"geometry":{"mesh":1,"convexHull":true}}}}},
            {"name":"Ball","translation":[0,0,-2],"extensions":{"OMI_physics_body":{"collider":{"shape":0}}}},
            {"name":"Zone","extensions":{"KHR_physics_rigid_bodies":{"trigger":{"geometry":{"shape":0}}}}}
        ]}`},context.temp_allocator)
    path:=write_text(folder,"physics.gltf",text)
    model,error:=importer.import_model(path,FORMATS[:])
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.model_destroy(&model)
    names:=make([dynamic]string,context.temp_allocator)
    for node in model.nodes {append(&names,node.name)}
    testing.expectf(t,len(model.meshes)==1 && model.meshes[0].name=="Crate","only the drawn mesh is a mesh: %v",len(model.meshes))
    testing.expectf(t,len(model.nodes)==2,"the crate and the trigger, which collides with nothing, stay: %v",names[:])
    collision:=model.meshes[0].collision
    kinds:[asset.Collider_Kind]int
    for c in collision.colliders {kinds[c.kind]+=1}
    testing.expectf(t,kinds[.Box]==1 && kinds[.Sphere]==1 && kinds[.Hull]==1 && len(collision.colliders)==3,"%v",kinds)
    // A glTF faces +Z: it is turned to face -Z, its colliders with it.
    for c in collision.colliders {
        #partial switch c.kind {
        case .Box: testing.expectf(t,linalg.length(c.center-{0,3,0})<1e-4 && linalg.length(c.size-{1,2,3})<1e-4,"the box: %v",c)
        case .Sphere: testing.expectf(t,linalg.length(c.center-{0,0,2})<1e-4 && abs(c.size.x-0.5)<1e-5,"the sphere: %v",c)
        case .Hull:
            testing.expect_value(t,c.point_count,u32(4))
            testing.expectf(t,linalg.length(collision.points[c.first_point]-{-5,0,0})<1.01,"the hull is where its node is: %v",collision.points[c.first_point])
        }
    }
    warned:=false
    for warning in model.warnings {warned||=strings.contains(warning,"trigger")}
    testing.expect(t,warned,fmt.tprint(model.warnings))
}
