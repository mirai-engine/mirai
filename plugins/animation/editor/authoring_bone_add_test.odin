package animation_editor

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"
import mm "mirai:std/math"

// A bone the clips animate and the skeleton lacks (hand_attach_r of a body
// that does not weight it) is added after the others, under its parent, and
// the tracks of a clip that name it under another path drive it then. A bone
// at a taken path or under a parent that is not there changes nothing.
@(test)
a_bone_added_to_a_skeleton_goes_last_and_takes_the_tracks_of_its_name :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"bone-add") {return};defer authoring_test_destroy(f)
    authoring_test_register(f,t,"create",Skeleton_Create_Params,authoring_skeleton_create,authoring_skeleton_create_defaults())
    added:=Skeleton_Bone_Add_Params{bone={rotation={0,0,0,1},scale={1,1,1}}}
    authoring_test_register(f,t,"add",Skeleton_Bone_Add_Params,authoring_bone_add,&added)
    authoring_test_register(f,t,"clip",Clip_Create_Params,authoring_clip_create)
    track:=Track_Set_Params{}
    authoring_test_register(f,t,"track",Track_Set_Params,authoring_track_set,&track)
    if !testing.expect_value(t,authoring_test_execute(f,"create",`{"path":"body.skeleton","bones":[{"name":"root","path":"root"},{"name":"hand_r","path":"root/hand_r","parent":"root","position":[0.5,1,0]}]}`).code,0) {return}
    skeleton:=authoring_test_id_text(authoring_test_id(f,"body.skeleton"))
    // The clips of another skeleton name the bone under their own root.
    if !testing.expect_value(t,authoring_test_execute(f,"clip",`{"path":"katana.anim","name":"idle"}`).code,0) {return}
    clip:=authoring_test_id_text(authoring_test_id(f,"katana.anim"))
    for target in ([?]string{"Armature/root/hand_r/hand_attach_r","Armature/root/hand_r"}) {
        params:=fmt.tprintf(`{{"asset":"%s","clip":"idle","target":"%s","property":"Position","keys":[{{"time":0,"value":[0,0,0,0]}},{{"time":1,"value":[0.1,0,0,0]}}]}}`,clip,target)
        if !testing.expect_value(t,authoring_test_execute(f,"track",params).code,0) {return}
    }

    params:=fmt.tprintf(`{{"asset":"%s","parent":"root/hand_r","bone":{{"name":"hand_attach_r","position":[-0.085,0,0.03]}},"clips":["%s"]}}`,skeleton,clip)
    if !testing.expect_value(t,authoring_test_execute(f,"add",params).code,0) {return}
    text:=api.json_compact(string(serial.writer_bytes(&f.out)))
    testing.expect(t,strings.contains(text,`"bone":"root/hand_r/hand_attach_r"`) && strings.contains(text,`"renamed":1`) && strings.contains(text,`"driving":1`),text)

    file:asset.Asset
    if testing.expect_value(t,authoring_test_load(f,"body.skeleton",&file),asset.Error.None) {
        view,error:=asset.skeleton_view(&file,&f.assets.types)
        if testing.expect_value(t,error,asset.Error.None) && testing.expect_value(t,len(view.bones),3) {
            testing.expect_value(t,base.text_get(view.bones[1].path[:]),"root/hand_r")
            added:=view.bones[2]
            testing.expect_value(t,base.text_get(added.path[:]),"root/hand_r/hand_attach_r")
            testing.expect_value(t,added.parent,i32(1))
            testing.expect_value(t,added.translation,mm.Vec3{-0.085,0,0.03})
            testing.expect_value(t,added.target,base.name_hash("root/hand_r/hand_attach_r"))
        }
        asset.asset_close(&file)
    }
    if testing.expect_value(t,authoring_test_load(f,"katana.anim",&file),asset.Error.None) {
        view,error:=asset.animation_view(&file,&f.assets.types)
        if testing.expect_value(t,error,asset.Error.None) {
            targets:=make([dynamic]string,context.temp_allocator)
            for &track in view.tracks {append(&targets,base.text_get(track.target[:]))}
            testing.expect(t,len(targets)==2 && targets[0]=="root/hand_r/hand_attach_r" && targets[1]=="Armature/root/hand_r",fmt.tprint(targets))
        }
        asset.asset_close(&file)
    }

    revision:=authoring_test_revision(f,"body.skeleton")
    result:=authoring_test_execute(f,"add",params)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.message,"bone at that path"),result.message)
    result=authoring_test_execute(f,"add",fmt.tprintf(`{{"asset":"%s","parent":"root/foot_l","bone":{{"name":"toe"}}}}`,skeleton))
    testing.expect_value(t,result.code,api.INVALID_PARAMS)
    testing.expect_value(t,authoring_test_revision(f,"body.skeleton"),revision)
}
