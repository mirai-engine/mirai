package animation_editor

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

@(private) @(test_world) Grounding_Inspect_World :: struct {using world:Test_World,grounding:anim.Grounding_Runtime,playback:anim.Playback}

@(test)
grounding_inspection_derives_final_pose_errors_and_reports_blocked_legs_without_cached_residuals :: proc(t:^testing.T) {
    world:Grounding_Inspect_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    ref:=test_world_ref(&world)
    entity:=core.Entity(1)
    local:=make([dynamic]mm.Transform,3);for &value in local {value=mm.TRANSFORM_IDENTITY}
    append(&world.playback.states,anim.Playing{entity=entity,world=local,pose_ready=true})
    record:=anim.Grounding_Record{rig=entity,count=1,mode=.Procedural,initialized=true}
    record.bones[0]={0,1,2};record.targets[0]={position={0,0,0},weight=1};record.rotations[0]=mm.QUAT_IDENTITY
    append(&world.grounding.records,record)
    config:=anim.FOOT_GROUNDING_DEFAULT
    result:=program_grounding_diagnostic(ref,entity,0,config)
    testing.expect(t,result.valid && result.reached && result.residual==0 && result.blocked_legs==0)
    world.playback.states[0].world[2].position={0,.02,0}
    world.playback.states[0].world[2].rotation=mm.quat_axis_angle({0,1,0},.2)
    result=program_grounding_diagnostic(ref,entity,0,config)
    testing.expect(t,result.valid && !result.reached && abs(result.residual-.02)<1e-6 && abs(result.angular_error-.2)<1e-5)
    world.playback.states[0].world[2]=mm.TRANSFORM_IDENTITY;world.grounding.records[0].blocked=1
    result=program_grounding_diagnostic(ref,entity,0,config)
    testing.expect(t,result.valid && !result.reached && result.residual==0 && result.blocked_legs==1)
    world.grounding.records[0].blocked=0;world.grounding.records[0].bones[0][2]=3
    testing.expect(t,!program_grounding_diagnostic(ref,entity,0,config).valid)
    world.grounding.records[0].bones[0][2]=2;world.grounding.records[0].targets[0].weight=0
    testing.expect(t,!program_grounding_diagnostic(ref,entity,0,config).valid)
    testing.expect(t,!program_grounding_diagnostic(ref,entity,1,config).valid)
}

@(test)
rig_modifier_api_discovers_named_operations_effectors_and_retarget_chains_of_the_character :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"rig-modifiers") {return};defer authoring_test_destroy(f)
    pose_id,retarget_id:=base.Asset_Id{111,222},base.Asset_Id{112,223}
    chain:=anim.CHAIN_IK_CONSTRAINT_DEFAULT;base.text_set(chain.name[:],"arm");chain.root,chain.end=anim.bone_ref("a"),anim.bone_ref("c")
    spring:=anim.SPRING_CONSTRAINT_DEFAULT;base.text_set(spring.name[:],"tail");spring.root,spring.end=chain.root,chain.end
    twist:=anim.TWIST_CONSTRAINT_DEFAULT;base.text_set(twist.name[:],"roll");twist.source,twist.root,twist.end=anim.bone_ref("d"),chain.root,chain.end
    multi:=anim.MULTI_IK_CONSTRAINT_DEFAULT;base.text_set(multi.name[:],"body");multi.root=chain.root;multi.joint_count,multi.effector_count=1,2
    multi.joints[0]=anim.MULTI_IK_JOINT_DEFAULT;multi.joints[0].bone=chain.root
    for &effector in multi.effectors[:2] {effector=anim.MULTI_IK_EFFECTOR_DEFAULT;effector.bone=chain.end}
    base.text_set(multi.effectors[0].name[:],"left");base.text_set(multi.effectors[1].name[:],"right")
    retarget:=anim.CHAIN_RETARGET_CONSTRAINT_DEFAULT;base.text_set(retarget.name[:],"transfer")
    retarget.source_root,retarget.source_end,retarget.target_root,retarget.target_end=chain.root,chain.end,chain.root,chain.end
    set:=anim.character_set_make({});set.pose={chain_ik={chain},twist={twist},springs={spring},multi_ik={multi},retarget_chains={retarget}}
    testing.expect_value(t,anim.character_save(fmt.tprintf("%s/rig.character",f.root),&f.assets.types,pose_id,set),asset.Error.None)
    set.pose={retarget_chains={retarget}}
    testing.expect_value(t,anim.character_save(fmt.tprintf("%s/transfer.character",f.root),&f.assets.types,retarget_id,set),asset.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    play:Program_Test_World;if !test_world_init(t,&play) {return};defer test_world_destroy(&play)
    first,second:=core.create(&play.entities),core.create(&play.entities)
    core.add(&play.ids,first,{value=17});core.add(&play.ids,second,{value=18})
    value:=anim.ANIMATION_DEFAULT;value.asset=pose_id;core.add(&play.animations,first,value)
    value.asset=retarget_id;core.add(&play.animations,second,value);test_world_settle(&play)
    f.session.info,f.session.mode=test_world_info(&play),.Play;f.session.runs[0]={world=&play}
    inspect:=Instance_Inspect_Params{parts={.Modifiers},limit=256};requested:=request_defaults()
    authoring_test_register(f,t,"request",Request_Params,request,requested)
    authoring_test_register(f,t,"inspect",Instance_Inspect_Params,instance_inspect,&inspect)
    testing.expect_value(t,authoring_test_execute(f,"inspect",`{"entity":"0000000000000011"}`).code,0)
    output:=api.json_compact(string(serial.writer_bytes(&f.out)))
    testing.expect(t,strings.contains(output,`"total":5`) && strings.contains(output,`"name":"transfer"`))
    testing.expect(t,!strings.contains(output,`"diagnostic"`) && !strings.contains(output,`"slot"`) && !strings.contains(output,`"index"`) && strings.contains(output,`"left"`) && strings.contains(output,`"right"`))
    testing.expect_value(t,authoring_test_execute(f,"inspect",`{"entity":"0000000000000011","diagnostics":true}`).code,0)
    testing.expect(t,strings.contains(api.json_compact(string(serial.writer_bytes(&f.out))),`"target_alpha"`))
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000012","controls":[{"kind":"Chain_Retarget","name":"transfer","weight":0.4}]}`).code,0)
    testing.expect(t,len(play.animation_requests.controls.items)==1 && play.animation_requests.controls.items[0].rig==second && play.animation_requests.controls.items[0].slot==0)
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000011","goals":[{"kind":"Multi_IK","name":"body","effector":"right","target":{"position":[1,2,3]}}]}`).code,0)
    testing.expect_value(t,play.animation_requests.goals.items[0].effector,u8(1))
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000011","goals":[{"kind":"Multi_IK","name":"body","effector":"left","target":{"position":[4,5,6]}}]}`).code,0)
    testing.expect_value(t,play.animation_requests.goals.items[1].effector,u8(0))
    for request in ([8]string{`{"entity":"0000000000000011","goals":[{"kind":"Multi_IK","name":"body","effector":"absent"}]}`,`{"entity":"0000000000000011","goals":[{"kind":"Multi_IK","name":"body","effector_index":0}]}`,`{"entity":"0000000000000011","goals":[{"kind":"Multi_IK","name":"body"}]}`,`{"entity":"0000000000000011","goals":[{"kind":"Spring","name":"tail","target":"0000000000000012"}]}`,`{"entity":"0000000000000011","goals":[{"kind":"Chain_Retarget","name":"transfer"}]}`,`{"entity":"0000000000000011","goals":[{"kind":"Twist","name":"roll"}]}`,`{"entity":"0000000000000011","goals":[{"kind":"Multi_IK","name":"body","effector":"left","weight":0.5}]}`,`{"entity":"0000000000000012","goals":[{"kind":"Multi_IK","name":"body","effector":"left"}]}`}) {result:=authoring_test_execute(f,"request",request);testing.expectf(t,result.code==api.INVALID_PARAMS,"%s: %d %s",request,result.code,result.data)}
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000012","controls":[{"kind":"Chain_Retarget","name":"transfer","slot":0}]}`).code,api.INVALID_PARAMS)
    testing.expect_value(t,len(play.animation_requests.goals.items),2)
    preview:Preview_Params;copy(preview.entity[:],"0000000000000011");preview.controls[0]={kind=.Chain_Retarget,weight=.3,enabled=true};base.text_set(preview.controls[0].name[:],"transfer")
    preview.goals[0]={kind=.Multi_IK,target={position={0,1,0},rotation=1,scale={1,1,1}}};base.text_set(preview.goals[0].name[:],"body");base.text_set(preview.goals[0].effector[:],"right")
    call:=api.Call{raw=`{"controls":[{"kind":"Chain_Retarget","name":"transfer"}],"goals":[{"kind":"Multi_IK","name":"body","effector":"right","target":{"position":[0,1,0]}}]}`,allocator=context.temp_allocator}
    testing.expect(t,request_apply(&f.session,&call,test_world_ref(&play),first,&preview,0,nil))
    testing.expect_value(t,len(play.animation_requests.controls.items),2);testing.expect_value(t,len(play.animation_requests.goals.items),3)
    call.raw=`{"goals":[{"kind":"Multi_IK","name":"body","effector":"right","target":{"position":[0,1,0]},"contact":0.5}]}`
    testing.expect(t,!request_apply(&f.session,&call,test_world_ref(&play),first,&preview,0,nil))
    testing.expect(t,strings.contains(call.error.data,`"path":"goals[0].contact"`));testing.expect_value(t,len(play.animation_requests.goals.items),3)
}
