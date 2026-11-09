package gltf

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import anim "mirai:std/anim"
import "mirai:std/base"
import importer "mirai:cook/import"

@(test)
gltf_animation_import_preserves_tangents_and_unambiguous_targets :: proc(t:^testing.T) {
    model,ok:=import_ok(t,FIXTURES+"animation.gltf")
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.meshes),0)
    testing.expect_value(t,len(model.animations),2)
    testing.expect(t,model.nodes[0].name==model.nodes[1].name && model.nodes[0].target!=model.nodes[1].target)
    testing.expect_value(t,model.nodes[0].target,base.name_hash("Bone"))
    testing.expect(t,model.animations[0].name=="move" && model.animations[1].name=="move (1)")
    tracks:=model.animations[0].tracks
    testing.expect(t,len(tracks)==3 && tracks[0].target=="Bone" && tracks[2].target=="Bone/Bone")
    testing.expect(t,tracks[0].keys[0].tangents && tracks[0].keys[0].out_slope.x==-2)
    position:=anim.track_evaluate(tracks[0].keys,.Position,1)
    rotation:=anim.track_evaluate(tracks[1].keys,.Rotation,1)
    scale:=anim.track_evaluate(tracks[2].keys,.Scale,1)
    testing.expect(t,abs(position.x+1.5)<1e-6,"cubic tangents scale by the two-second interval")
    testing.expect(t,abs(rotation.z+0.8944272)<1e-6 && abs(rotation.w-0.4472136)<1e-6,"cubic quaternion uses component Hermite and normalization")
    testing.expect_value(t,scale,[4]f32{1,1,1,0})
    testing.expect_value(t,anim.track_evaluate(tracks[2].keys,.Scale,2),[4]f32{3,3,3,0})
    testing.expect_value(t,anim.track_evaluate(model.animations[1].tracks[0].keys,.Position,1),[4]f32{-2,2,-2,0})

    folder:=temp_folder("write-animation")
    defer os.remove_all(folder)
    report,error:=importer.import_write(&model,folder)
    defer importer.report_destroy(&report)
    if !testing.expect_value(t,error.code,importer.Error_Code.None) {return}
    testing.expect(t,report.animation_id!={} && len(report.assets)==1 && report.assets[0].id==report.animation_id)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    a:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&a,report.assets[0].path),asset.Error.None) {return}
    defer asset.asset_close(&a)
    view,view_error:=asset.animation_view(&a,&types)
    if !testing.expect_value(t,view_error,asset.Error.None) {return}
    library:anim.Library
    testing.expect(t,anim.library_init(&library,asset.animation_library_desc(view)))
    defer anim.library_destroy(&library)
    testing.expect_value(t,asset.animation_clips_add(view,&library),anim.Clip(1))
    bound:=anim.clip_tracks(&library,1)
    testing.expect_value(t,bound[0].target,model.nodes[0].target)
    testing.expect_value(t,bound[2].target,model.nodes[1].target)
    testing.expect_value(t,anim.clip_evaluate(&library,bound[0],1),position)
    testing.expect_value(t,anim.clip_evaluate(&library,bound[1],1),rotation)
    // Imported again over its files, it keeps their ids.
    again,again_error:=importer.import_write(&model,folder)
    defer importer.report_destroy(&again)
    if !testing.expect_value(t,again_error.code,importer.Error_Code.None) {return}
    testing.expect_value(t,again.animation_id,report.animation_id)
    bytes,read_error:=os.read_entire_file(again.assets[0].path,context.temp_allocator)
    testing.expect(t,read_error==nil && mem.compare(a.file,bytes)==0,"reimport writes identical animation bytes")
}

@(test)
gltf_animation_rejects_inconsistent_channels :: proc(t:^testing.T) {
    source,error:=os.read_entire_file(FIXTURES+"animation.gltf",context.temp_allocator)
    if !testing.expect_value(t,error,nil) {return}
    folder:=temp_folder("invalid-animation")
    defer os.remove_all(folder)
    cases:=[?]struct {from,to:string}{
        {`"path":"scale"`,`"path":"weights"`},
        {`"path":"scale"`,`"path":"rotation"`},
        {`"path":"rotation"`,`"path":"translation"`},
        {`"interpolation":"CUBICSPLINE"`,`"interpolation":"LINEAR"`},
    }
    for test,i in cases {
        changed,_:=strings.replace_all(string(source),test.from,test.to,context.temp_allocator)
        model,import_error:=importer.import_model(write_text(folder,fmt.tprintf("bad-%d.gltf",i),changed),FORMATS[:])
        defer importer.model_destroy(&model)
        testing.expectf(t,import_error.code!=.None,"invalid channel accepted: %s",test.to)
    }
}

@(test)
gltf_animation_paths_survive_node_reordering_and_reject_ambiguity :: proc(t:^testing.T) {
    source,error:=os.read_entire_file(FIXTURES+"animation.gltf",context.temp_allocator)
    if !testing.expect_value(t,error,nil) {return}
    original,ok:=import_ok(t,FIXTURES+"animation.gltf")
    if !ok {return}
    defer importer.model_destroy(&original)
    text,_:=strings.replace_all(string(source),`"nodes":[{"name":"Bone","children":[1]},{"name":"Bone"}]`,`"nodes":[{"name":"Bone"},{"name":"Bone","children":[0]}]`,context.temp_allocator)
    text,_=strings.replace_all(text,`"nodes":[0]`,`"nodes":[1]`,context.temp_allocator)
    text,_=strings.replace_all(text,`"node":0`,`"node":999`,context.temp_allocator)
    text,_=strings.replace_all(text,`"node":1`,`"node":0`,context.temp_allocator)
    text,_=strings.replace_all(text,`"node":999`,`"node":1`,context.temp_allocator)
    folder:=temp_folder("animation-order");defer os.remove_all(folder)
    reordered,reorder_error:=importer.import_model(write_text(folder,"reordered.gltf",text),FORMATS[:])
    if !testing.expect_value(t,reorder_error.code,importer.Error_Code.None) {return}
    defer importer.model_destroy(&reordered)
    for clip,i in original.animations {for track,j in clip.tracks {
        testing.expect_value(t,reordered.animations[i].tracks[j].target,track.target)
        testing.expect_value(t,anim.track_evaluate(reordered.animations[i].tracks[j].keys,track.property,1),anim.track_evaluate(track.keys,track.property,1))
    }}
    text,_=strings.replace_all(string(source),`{"name":"Bone","children":[1]}`,`{"name":"Bone"}`,context.temp_allocator)
    ambiguous,ambiguity_error:=importer.import_model(write_text(folder,"ambiguous.gltf",text),FORMATS[:])
    defer importer.model_destroy(&ambiguous)
    testing.expect(t,ambiguity_error.code==.Malformed && strings.contains(ambiguity_error.message,"distinct names"))
}

// The instances of a scene are often named after what they place: siblings
// that share a name import when no clip or skin binds them.
@(test)
siblings_that_share_a_name_import_when_nothing_binds_them :: proc(t:^testing.T) {
    text:=`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
"nodes":[{"name":"Map","children":[1,2]},{"name":"Crate","mesh":0,"translation":[1,0,0]},{"name":"Crate","mesh":0,"translation":[2,0,0]}],
"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]}],
"bufferViews":[{"buffer":0,"byteLength":36}],
"buffers":[{"byteLength":36,"uri":"data:application/octet-stream;base64,AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAA"}]}`
    folder:=temp_folder("shared-names");defer os.remove_all(folder)
    model,error:=importer.import_model(write_text(folder,"shared.gltf",text),FORMATS[:])
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.nodes),3)
    testing.expect_value(t,model.nodes[2].transform.position,[3]f32{-2,0,0})
}
