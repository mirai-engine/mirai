package animation_editor

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import anim "plugins:animation/runtime"

// A character set up as character.setup leaves it: a skinned mesh with a body and one .character
// with a look and hand IK, a wave gesture, a layer Speed whose weight is a parameter and a
// locomote warp window. Returns the entity it looks at.
request_test_character :: proc(f:^Pose_Bake_Test,t:^testing.T) -> core.Entity {
    a:=&f.authoring
    source_id,skeleton_id,mesh_id,character_id:=base.Asset_Id{830,1},base.Asset_Id{830,2},base.Asset_Id{830,3},base.Asset_Id{830,4}
    bones:=body_test_figure()
    map_,_:=asset.skeleton_body_detect(bones,lib.body_map_empty())
    body:asset.Skeleton_Body
    rows:[len(lib.Body_Part)]asset.Skeleton_Body_Part
    count,_:=asset.skeleton_body_rows(bones,map_,&body,&rows)
    testing.expect_value(t,asset.skeleton_save(fmt.tprintf("%s/figure.skeleton",a.root),&a.assets.types,{id=skeleton_id,bones=bones,body=&body,body_parts=rows[:count]}),asset.Error.None)
    vertices:=[3]asset.Vertex{{position={0,0,0},color=0xffffffff},{position={1,0,0},color=0xffffffff},{position={0,1,0},color=0xffffffff}}
    skin:[3]asset.Skin_Vertex;for &vertex in skin {vertex.weights[0]=255}
    testing.expect_value(t,source_mesh_save(fmt.tprintf("%s/figure.mesh",a.root),&a.assets.types,{id=mesh_id,skeleton=skeleton_id,joints={{node=0,inverse_bind=1}}},{vertices=vertices[:],skin=skin[:]},{0,1,2}),asset.Error.None)
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/moves.anim",a.root),&a.assets.types,{id=source_id,clips={{name="idle"},{name="walk"},{name="wave"}}}),asset.Error.None)
    path :: proc(bones:[]asset.Skeleton_Bone,bone:i32) -> anim.Bone_Ref {return anim.bone_ref(base.text_get(bones[bone].path[:]))}
    look:=anim.LOOK_CONSTRAINT_DEFAULT;look.bone=path(bones,map_.bones[.Head]);look.enabled=false
    hands:[2]anim.IK_Constraint
    for &ik,i in hands {
        ik=anim.IK_CONSTRAINT_DEFAULT;ik.enabled=false
        parts:=[3]lib.Body_Part{.Shoulder_L,.Elbow_L,.Hand_L} if i==0 else {.Shoulder_R,.Elbow_R,.Hand_R}
        ik.root,ik.joint,ik.end=path(bones,map_.bones[parts[0]]),path(bones,map_.bones[parts[1]]),path(bones,map_.bones[parts[2]])
        // The right arm names the parts of the body the skeleton keeps.
        if i==1 {ik.root,ik.joint,ik.end=anim.bone_ref_part(parts[0]),anim.bone_ref_part(parts[1]),anim.bone_ref_part(parts[2])}
    }
    wave:=anim.ACTION_DEFINITION_DEFAULT;base.text_set(wave.name[:],"wave");base.text_set(wave.clip[:],"wave")
    speed:=anim.STACK_LAYER_DEFAULT;base.text_set(speed.name[:],"Speed");base.text_set(speed.clip[:],"walk");speed.weight=0
    set:=anim.character_set_make(source_id);set.pose,set.actions={look={look},ik=hands[:]},{layers={speed},actions={wave}}
    testing.expect_value(t,anim.character_save(fmt.tprintf("%s/figure.character",a.root),&a.assets.types,character_id,set),asset.Error.None)
    testing.expect(t,host.assets_scan(&a.assets))
    motion:=motion_write_defaults();authoring_test_register(a,t,"motion",Motion_Write_Params,authoring_motion_set,motion)
    result:=authoring_test_execute(a,"motion",`{"path":"figure.character","windows":[{"name":"locomote"}]}`)
    testing.expectf(t,result.code==0,"motion: %s %s",result.message,result.data)
    description:=anim.ANIMATION_DEFAULT;description.asset=character_id;base.text_set(description.clip[:],"idle")
    core.add(&f.world.animations,f.rig,description)
    core.add(&f.world.meshes,f.rig,erender.Mesh_Renderer{mesh=mesh_id})
    friend:=core.create(&f.world.entities);core.add(&f.world.ids,friend,{value=18})
    core.settle(&f.info,&f.world,nil)
    return friend
}

@(test)
request_intents_compile_to_goals_controls_actions_parameters_and_motion :: proc(t:^testing.T) {
    f:=new(Pose_Bake_Test);defer free(f);if !pose_bake_test_init(f,t,"request-intents") {return};defer pose_bake_test_destroy(f)
    friend:=request_test_character(f,t)
    a:=&f.authoring
    a.session.mode=.Play;a.session.runs[0]={world=&f.world}
    defaults:=request_defaults()
    authoring_test_register(a,t,"request",Request_Params,request,defaults)
    result:=authoring_test_execute(a,"request",`{"entity":"0000000000000011","look":{"target":{"kind":"Entity","entity":"0000000000000012"}},"reach":[{"hand":"Right","target":{"position":[0.4,1.3,-0.3]}}],"gesture":{"clip":"wave"},"locomote":{"target":{"position":[0,0,-5]},"speed":1.2}}`)
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    testing.expect_value(t,result_shape_mismatch(Request_Result,string(serial_bytes(a))),"")
    goals:=f.world.requests.goals.items
    if !testing.expect(t,len(goals)==2 && len(f.world.requests.controls.items)==0) {return}
    testing.expect(t,goals[0].kind==.Look && goals[0].enabled && goals[0].weight==1 && abs(goals[0].fade-.3)<1e-6 && goals[0].target.kind==.Entity && goals[0].target.entity==friend)
    testing.expect(t,goals[1].kind==.IK && goals[1].slot==1 && goals[1].enabled && goals[1].target.position=={.4,1.3,-.3})
    actions:=f.world.requests.plays.items
    testing.expect(t,len(actions)==1 && !actions[0].stop && base.text_get(actions[0].action[:])=="wave")
    locomotion,targets:=f.world.requests.locomotion.items,f.world.requests.warps.items
    testing.expectf(t,len(locomotion)==1 && abs(locomotion[0].velocity.z+1.2)<1e-5 && abs(locomotion[0].velocity.x)<1e-5 && abs(locomotion[0].source_velocity.z+1.2)<1e-5,"locomotion %v",locomotion)
    testing.expect(t,len(targets)==1 && targets[0].target.target.kind==.World && targets[0].target.target.position=={0,0,-5})
    text:=string(serial_bytes(a))
    testing.expect(t,strings.contains(text,`"kind":"Look"`) && strings.contains(text,`"kind":"Reach"`) && strings.contains(text,`"kind":"Gesture","name":"wave"`) && strings.contains(text,`"kind":"Locomotion"`))

    // Letting go: a goal fades the operation out from where it aims.
    result=authoring_test_execute(a,"request",`{"entity":"0000000000000011","look":{"off":true,"fade":0.5}}`)
    testing.expectf(t,result.code==0 && len(f.world.requests.goals.items)==3,"%s %s",result.message,result.data)
    off:=f.world.requests.goals.items[2];testing.expect(t,off.kind==.Look && !off.enabled && off.weight==0 && off.fade==.5)

    result=authoring_test_execute(a,"request",`{"entity":"0000000000000011","gesture":{"clip":"bow"}}`)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"gesture.clip"`) && strings.contains(result.data,"wave"))
    result=authoring_test_execute(a,"request",`{"entity":"0000000000000011","locomote":{"target":{"kind":"Bone","entity":"0000000000000012"}}}`)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Unsupported_Target"))
    result=authoring_test_execute(a,"request",`{"entity":"0000000000000011","look":{"target":{"position":[0,1,1]}},"parameters":[{"name":"Speed","value":9}]}`)
    testing.expect(t,result.code==api.INVALID_PARAMS && len(f.world.requests.goals.items)==3)
    a.session.mode=.Edit
    result=authoring_test_execute(a,"request",`{"entity":"0000000000000011","look":{"target":{"position":[0,1,1]}}}`)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Runtime_Required") && strings.contains(result.data,"animation.preview"))
    testing.expect_value(t,len(f.world.requests.goals.items),3)
}

@(private)
serial_bytes :: proc(a:^Authoring_Test) -> []u8 {return a.out.data[:a.out.count]}
