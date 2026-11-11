package gltf

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// A triangle with two targets, mesh and node weights, and a clip of each interpolation of the weights.
@(private="file")
morph_fixture :: proc(folder:string) -> string {
    values:=[54]f32{
        0,0,0, 1,0,0, 0,1,0,
        0,0,1, 0,0,1, 0,0,1,
        0,0,0, 2,0,0, 0,0,0,
        0,0,0, 0,0,0, 0,3,0,
        0,1, 0,0,2,-1,
        0,0, 0,0, 2,0, 0,0, 2,-1, 0,0,
    }
    if os.write_entire_file(fmt.tprintf("%s/morph.bin",folder),mem.slice_data_cast([]u8,values[:]))!=nil {return ""}
    return write_text(folder,"morph.gltf",`{"asset":{"version":"2.0"},"buffers":[{"uri":"morph.bin","byteLength":216}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":36},{"buffer":0,"byteOffset":72,"byteLength":36},{"buffer":0,"byteOffset":108,"byteLength":36},{"buffer":0,"byteOffset":144,"byteLength":8},{"buffer":0,"byteOffset":152,"byteLength":16},{"buffer":0,"byteOffset":168,"byteLength":48}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},{"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},{"bufferView":2,"componentType":5126,"count":3,"type":"VEC3"},{"bufferView":3,"componentType":5126,"count":3,"type":"VEC3"},{"bufferView":4,"componentType":5126,"count":2,"type":"SCALAR"},{"bufferView":5,"componentType":5126,"count":4,"type":"SCALAR"},{"bufferView":6,"componentType":5126,"count":12,"type":"SCALAR"}],"meshes":[{"name":"Blob","weights":[0.1,-0.2],"extras":{"targetNames":["Wide","Smile"]},"primitives":[{"attributes":{"POSITION":0,"NORMAL":1},"targets":[{"POSITION":2},{"POSITION":3}]}]}],"nodes":[{"name":"Blob","mesh":0,"weights":[1,0]},{"name":"Clone","mesh":0,"weights":[-1,0.4]}],"scenes":[{"nodes":[0,1]}],"scene":0,"animations":[{"name":"Linear","samplers":[{"input":4,"output":5,"interpolation":"LINEAR"}],"channels":[{"sampler":0,"target":{"node":0,"path":"weights"}}]},{"name":"Step","samplers":[{"input":4,"output":5,"interpolation":"STEP"}],"channels":[{"sampler":0,"target":{"node":0,"path":"weights"}}]},{"name":"Cubic","samplers":[{"input":4,"output":6,"interpolation":"CUBICSPLINE"}],"channels":[{"sampler":0,"target":{"node":0,"path":"weights"}}]}]}`)
}

// The bytes of a GLB of a JSON whose one buffer has no uri.
@(private="file")
glb_bytes :: proc(json:string,binary:[]u8) -> []u8 {
    text:=make([dynamic]u8,context.temp_allocator);append(&text,..transmute([]u8)json);for len(text)%4!=0 {append(&text,u8(' '))}
    header:=[3]u32{0x46546c67,2,u32(12+8+len(text)+8+len(binary))}
    json_header:=[2]u32{u32(len(text)),0x4e4f534a};binary_header:=[2]u32{u32(len(binary)),0x004e4942}
    bytes:=make([dynamic]u8,context.temp_allocator)
    append(&bytes,..mem.slice_data_cast([]u8,header[:]));append(&bytes,..mem.slice_data_cast([]u8,json_header[:]));append(&bytes,..text[:])
    append(&bytes,..mem.slice_data_cast([]u8,binary_header[:]));append(&bytes,..binary)
    return bytes[:]
}

@(private="file")
morph_delta :: proc(mesh:importer.Imported_Mesh,target:int,vertex:u32) -> asset.Morph_Delta {
    shape:=mesh.morphs[target]
    for delta in mesh.morph_deltas[shape.first:][:shape.count] {if delta.vertex==vertex {return delta}}
    return {vertex=vertex}
}

@(test)
gltf_morphs_keep_sparse_named_targets_node_weights_and_every_weight_interpolation :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"morph-import")
    if folder=="" {return}
    model,ok:=import_ok(t,morph_fixture(folder));defer importer.model_destroy(&model)
    if !ok {return}
    testing.expect_value(t,len(model.meshes),1)
    mesh:=model.meshes[0]
    testing.expect_value(t,len(mesh.morphs),2);testing.expect_value(t,len(mesh.morph_deltas),2)
    testing.expect_value(t,base.text_get(mesh.morphs[1].name[:]),"Smile")
    testing.expect_value(t,mesh.morphs[0].weight,f32(.1))
    testing.expect_value(t,model.nodes[1].morph_weights[0],f32(-1))
    for clip in model.animations {testing.expect_value(t,len(clip.tracks),2);testing.expect_value(t,clip.tracks[0].target,"Blob/@morph/Wide")}
    testing.expect_value(t,anim.track_evaluate(model.animations[0].tracks[0].keys,.Float,.5).x,f32(1))
    testing.expect_value(t,anim.track_evaluate(model.animations[1].tracks[0].keys,.Float,.5).x,f32(0))
    testing.expect_value(t,anim.track_evaluate(model.animations[2].tracks[0].keys,.Float,.5).x,f32(1.25))
    report,written,_:=write_model(t,&model,"write-morphs");defer importer.report_destroy(&report)
    if !testing.expectf(t,written.code==.None,"%s",written.message) {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    for item in report.assets {
        if item.kind!=asset.KIND_MESH {continue}
        file:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&file,item.path),asset.Error.None) {return}
        defer asset.asset_close(&file)
        view,read:=asset.mesh_view(&file,&types)
        testing.expect_value(t,read,asset.Error.None)
        testing.expect(t,len(view.morph_deltas)==2 && asset.mesh_check_indices(view))
    }
    source,_:=os.read_entire_file(fmt.tprintf("%s/morph.gltf",folder),context.temp_allocator)
    broken:=[?]struct {from,to:string}{
        {`"targetNames":["Wide","Smile"]`,`"targetNames":["Wide","Wide"]`},
        {`"weights":[1,0]`,`"weights":[1]`},
        {`"weights":[0.1,-0.2]`,`"weights":[0.1]`},
    }
    for change,i in broken {
        text,_:=strings.replace_all(string(source),change.from,change.to,context.temp_allocator)
        invalid,failure:=importer.import_model(write_text(folder,fmt.tprintf("bad-%d.gltf",i),text),FORMATS[:]);defer importer.model_destroy(&invalid)
        testing.expectf(t,failure.code!=.None,"accepted: %s",change.to)
    }
}

@(test)
glb_morphs_decode_sparse_accessors :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"sparse-morph-glb")
    if folder=="" {return}
    path:=morph_fixture(folder)
    json_bytes,_:=os.read_entire_file(path,context.temp_allocator)
    original,_:=os.read_entire_file(fmt.tprintf("%s/morph.bin",folder),context.temp_allocator)
    binary:=make([dynamic]u8,context.temp_allocator);append(&binary,..original)
    index:=[1]u32{1};delta:=[3]f32{2,0,0}
    append(&binary,..mem.slice_data_cast([]u8,index[:]));append(&binary,..mem.slice_data_cast([]u8,delta[:]))
    json,_:=strings.replace_all(string(json_bytes),`"uri":"morph.bin","byteLength":216`,`"byteLength":232`,context.temp_allocator)
    json,_=strings.replace_all(json,`{"buffer":0,"byteOffset":168,"byteLength":48}`,`{"buffer":0,"byteOffset":168,"byteLength":48},{"buffer":0,"byteOffset":216,"byteLength":4},{"buffer":0,"byteOffset":220,"byteLength":12}`,context.temp_allocator)
    json,_=strings.replace_all(json,`{"bufferView":2,"componentType":5126,"count":3,"type":"VEC3"}`,`{"componentType":5126,"count":3,"type":"VEC3","sparse":{"count":1,"indices":{"bufferView":7,"componentType":5125},"values":{"bufferView":8}}}`,context.temp_allocator)
    file:=fmt.tprintf("%s/sparse.glb",folder)
    if !testing.expect_value(t,os.write_entire_file(file,glb_bytes(json,binary[:])),nil) {return}
    model,ok:=import_ok(t,file);defer importer.model_destroy(&model)
    if !ok {return}
    testing.expect_value(t,len(model.meshes[0].morph_deltas),2)
    testing.expect_value(t,model.meshes[0].morph_deltas[0].position,[3]f32{-2,0,0})
}

// Two panels: the first without normals, the second with them and a normal target.
@(private="file")
flat_fixture :: proc(folder:string,glb:bool) -> string {
    values:=[60]f32{
        0,0,0, 1,0,0, 1,1,0, 0,1,0,
        0,0,1, 0,0,1, 0,0,1, 0,0,1,
        0,0,0, 0,0,0, 0,0,1, 0,0,0,
        .2,0,0, .2,0,0, .2,0,0, .2,0,0,
        0,0,0, 0,0,1, 0,0,0, 0,0,0,
    }
    indices:=[6]u32{0,1,2,0,2,3}
    binary:=make([dynamic]u8,context.temp_allocator)
    append(&binary,..mem.slice_data_cast([]u8,values[:]));append(&binary,..mem.slice_data_cast([]u8,indices[:]))
    json:=`{"asset":{"version":"2.0"},"buffers":[{"byteLength":264,"uri":"flat.bin"}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":48},{"buffer":0,"byteOffset":96,"byteLength":48},{"buffer":0,"byteOffset":144,"byteLength":48},{"buffer":0,"byteOffset":192,"byteLength":48},{"buffer":0,"byteOffset":240,"byteLength":24}],"accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},{"bufferView":1,"componentType":5126,"count":4,"type":"VEC3"},{"bufferView":2,"componentType":5126,"count":4,"type":"VEC3","min":[0,0,0],"max":[0,0,1]},{"bufferView":3,"componentType":5126,"count":4,"type":"VEC3"},{"bufferView":4,"componentType":5126,"count":4,"type":"VEC3","min":[0,0,0],"max":[0,0,1]},{"bufferView":5,"componentType":5125,"count":6,"type":"SCALAR"}],"meshes":[{"name":"Panels","weights":[0,0],"extras":{"targetNames":["Corner","Edge"]},"primitives":[{"attributes":{"POSITION":0},"indices":5,"targets":[{"POSITION":2},{"POSITION":4}]},{"attributes":{"POSITION":0,"NORMAL":1},"indices":5,"targets":[{"POSITION":2,"NORMAL":3},{"POSITION":4}]}]}],"nodes":[{"name":"Panels","mesh":0}],"scenes":[{"nodes":[0]}],"scene":0}`
    if !glb {
        if os.write_entire_file(fmt.tprintf("%s/flat.bin",folder),binary[:])!=nil {return ""}
        return write_text(folder,"flat.gltf",json)
    }
    json,_=strings.replace_all(json,`,"uri":"flat.bin"`,"",context.temp_allocator)
    path:=fmt.tprintf("%s/flat.glb",folder)
    if os.write_entire_file(path,glb_bytes(json,binary[:]))!=nil {return ""}
    return path
}

@(test)
gltf_and_glb_morphs_follow_each_face_without_normals_and_keep_stated_normals :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"morph-flat-normals")
    if folder=="" {return}
    for glb in ([2]bool{false,true}) {
        model,ok:=import_ok(t,flat_fixture(folder,glb));defer importer.model_destroy(&model)
        if !ok {return}
        mesh:=model.meshes[0]
        testing.expect_value(t,len(mesh.indices),12)
        testing.expect(t,mesh.indices[0]!=mesh.indices[3] && mesh.indices[2]!=mesh.indices[4],"flat corners of coplanar faces that morph stay apart")
        faces:=[2][2][3]f32{{linalg.normalize([3]f32{0,-1,-1}),linalg.normalize([3]f32{1,0,-1})},{linalg.normalize([3]f32{1,1,-1}),{0,0,-1}}}
        weights:=[5][2]f32{{0,0},{1,0},{0,1},{.35,.65},{-1,.5}}
        for face in 0..<2 {
            for vertex in mesh.indices[face*3:][:3] {
                rest:=mm.normal_unpack(mesh.vertices[vertex].normal)
                a,b:=morph_delta(mesh,0,vertex),morph_delta(mesh,1,vertex)
                for weight in weights {
                    actual:=linalg.normalize(rest+a.normal*weight[0]+b.normal*weight[1])
                    expected:=linalg.normalize([3]f32{0,0,-1}*(1-weight[0]-weight[1])+faces[0][face]*weight[0]+faces[1][face]*weight[1])
                    testing.expect(t,linalg.length(actual-expected)<1e-4)
                }
            }
        }
        for vertex in mesh.indices[6:] {
            testing.expect_value(t,morph_delta(mesh,0,vertex).normal,[3]f32{-.2,0,0})
            testing.expect_value(t,morph_delta(mesh,1,vertex).normal,[3]f32{})
        }
    }
}

@(test)
gltf_morph_tangents_are_read_where_the_file_states_the_tangents :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"morph-tangents")
    if folder=="" {return}
    values:=[48]f32{
        0,0,0, 1,0,0, 0,1,0,
        0,0,1, 0,0,1, 0,0,1,
        1,0,0,1, 1,0,0,1, 1,0,0,1,
        0,0,0, 0,0,0, 0,0,0,
        0,.5,0, 0,0,0, 0,0,0,
    }
    if !testing.expect_value(t,os.write_entire_file(fmt.tprintf("%s/tangent.bin",folder),mem.slice_data_cast([]u8,values[:])),nil) {return}
    path:=write_text(folder,"tangent.gltf",`{"asset":{"version":"2.0"},"buffers":[{"uri":"tangent.bin","byteLength":192}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":36},{"buffer":0,"byteOffset":72,"byteLength":48},{"buffer":0,"byteOffset":120,"byteLength":36},{"buffer":0,"byteOffset":156,"byteLength":36}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},{"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},{"bufferView":2,"componentType":5126,"count":3,"type":"VEC4"},{"bufferView":3,"componentType":5126,"count":3,"type":"VEC3"},{"bufferView":4,"componentType":5126,"count":3,"type":"VEC3"}],"meshes":[{"name":"Tri","extras":{"targetNames":["Turn"]},"primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"TANGENT":2},"targets":[{"POSITION":3,"TANGENT":4}]}]}],"nodes":[{"name":"Tri","mesh":0}],"scenes":[{"nodes":[0]}],"scene":0}`)
    model,ok:=import_ok(t,path);defer importer.model_destroy(&model)
    if !ok {return}
    mesh:=model.meshes[0]
    testing.expect_value(t,mesh.morphs[0].count,1)
    delta:=mesh.morph_deltas[0]
    testing.expect(t,delta.position=={} && delta.tangent==[3]f32{0,.5,0},"a stated tangent takes the tangent delta of the file")
    testing.expect_value(t,mesh.vertices[delta.vertex].position,[3]f32{0,0,0})
}
