package anim

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

@(test)
modifier_controls_preserve_targets_and_fade_independently_through_world_copies :: proc(t:^testing.T) {
    problems:core.Problems
    rig:=core.entity_make(1,1)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    characters:Character_Assets;defer character_assets_free(&characters)
    ik:=IK_CONSTRAINT_DEFAULT;ik.pole={4,5,6};ik.end=bone_ref("foot")
    other:=ik;base.text_set(other.name[:],"reach")
    look:=LOOK_CONSTRAINT_DEFAULT;look.bone=bone_ref("head");look.target=spatial_definition_point({3,2,1})
    ground:=FOOT_GROUNDING_DEFAULT;ground.global_contact=.7;ground.legs={GROUNDED_LEG_DEFAULT}
    limit:=ROTATION_CONSTRAINT_DEFAULT;limit.bone=bone_ref("foot")
    prepared:=test_modifier_profile(&modifiers,&characters,rig,{ik={ik,other},look={look},limits={limit},grounding=ground})
    requests:Animation_Requests;defer delete(requests.modifiers.items)
    modifier(&requests,{rig=rig,kind=.Look,target=spatial_point({}),weight=.8,enabled=true,goal=true},"head")
    modifier(&requests,{rig=rig,kind=.Look,weight=.5,enabled=true,fade=1},"head")
    modifier(&requests,{rig=rig,kind=.IK,enabled=false,fade=1},"reach")
    modifier(&requests,{rig=rig,kind=.Grounding,weight=.4,enabled=true},"grounding")
    modifier(&requests,{rig=rig,kind=.Grounding,weight=.3,enabled=true,goal=true},"grounding")
    modifier(&requests,{rig=rig,kind=.Limit,weight=.2,enabled=true},"foot")
    modifier_take(&modifiers,&characters,&requests,&problems,.5)
    testing.expect_value(t,test_modifier_weight(&modifiers,rig,.Look,"head"),f32(.6))
    testing.expect_value(t,modifier_target(prepared,.Look,0,&look.target).position,mm.Vec3{})
    testing.expect_value(t,test_modifier_weight(&modifiers,rig,.IK,"foot"),f32(1))
    testing.expect_value(t,test_modifier_weight(&modifiers,rig,.IK,"reach"),f32(.5))
    testing.expect_value(t,modifier_pose(prepared,&characters).ik[1].pole,mm.Vec3{4,5,6})
    config:=modifier_grounding(&modifiers,prepared,ground)
    testing.expect_value(t,config.weight,f32(.4))
    testing.expect_value(t,config.global_contact,f32(.3))
    testing.expect_value(t,test_modifier_weight(&modifiers,rig,.Limit,"foot"),f32(.2))
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    snapshot:=modifier_rig(&copied,rig)
    testing.expect(t,raw_data(modifier_states(prepared,.Look))!=raw_data(modifier_states(snapshot,.Look)))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    modifier(&requests,{rig=rig,kind=.Look,weight=.5,enabled=true,fade=1},"head")
    for _ in 0..<120 {
        modifier_take(&modifiers,&characters,&requests,&problems,1.0/60)
        modifier_take(&copied,&characters,&requests,&problems,1.0/60)
    }
    context=saved
    testing.expect_value(t,test_modifier_weight(&modifiers,rig,.Look,"head"),f32(.4))
    testing.expect_value(t,test_modifier_weight(&modifiers,rig,.IK,"reach"),f32(0))
    for kind in Modifier_Kind {
        for state,i in modifier_states(prepared,kind) {testing.expect_value(t,state,modifier_states(snapshot,kind)[i])}
    }
    testing.expect_value(t,problems.count,0)
}

@(test)
modifier_fades_cancel_restart_and_survive_reordered_profiles :: proc(t:^testing.T) {
    problems:core.Problems
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    characters:Character_Assets;defer character_assets_free(&characters)
    first,second:=core.entity_make(9,1),core.entity_make(3,2)
    left,right:=IK_CONSTRAINT_DEFAULT,IK_CONSTRAINT_DEFAULT
    left.end,right.end=bone_ref("left"),bone_ref("right")
    for rig in ([2]core.Entity{first,second}) {
        test_modifier_profile(&modifiers,&characters,rig,{ik={left,right}})
    }
    requests:Animation_Requests;defer delete(requests.modifiers.items)
    modifier(&requests,{rig=first,kind=.IK,enabled=false,fade=1},"right")
    modifier(&requests,{rig=second,kind=.IK,weight=.5,enabled=true,fade=2},"left")
    modifier_take(&modifiers,&characters,&requests,&problems,.25)
    before:=test_modifier_weight(&modifiers,first,.IK,"right")
    for rig in ([2]core.Entity{second,first}) {test_modifier_profile(&modifiers,&characters,rig,{ik={right,left}})}
    testing.expect_value(t,test_modifier_weight(&modifiers,first,.IK,"right"),before)
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    modifier(&requests,{rig=second,kind=.IK,weight=.8,enabled=true},"left")
    modifier_take(&modifiers,&characters,&requests,&problems,0)
    testing.expect_value(t,test_modifier_weight(&modifiers,second,.IK,"left"),f32(.8))
    modifier(&requests,{rig=second,kind=.IK,weight=.2,enabled=true,fade=.5},"left")
    modifier_take(&modifiers,&characters,&requests,&problems,.5)
    modifier_take(&copied,&characters,&requests,&problems,2)
    for _ in 0..<120 {modifier_take(&modifiers,&characters,&requests,&problems,1.0/60)}
    context=saved
    testing.expect_value(t,test_modifier_weight(&modifiers,first,.IK,"right"),f32(0))
    testing.expect_value(t,test_modifier_weight(&modifiers,second,.IK,"left"),f32(.2))
    testing.expect_value(t,test_modifier_weight(&copied,second,.IK,"left"),f32(.5))
    testing.expect_value(t,problems.count,0)
}

@(test)
modifier_requests_reject_missing_names_invalid_values_and_exhausted_capacity :: proc(t:^testing.T) {
    requests:Animation_Requests;defer delete(requests.modifiers.items)
    reserve(&requests.modifiers.items,4)
    control:=Modifier_Request{rig=core.Entity(1),name=base.name_hash("reach"),kind=.IK,weight=1,enabled=true}
    modifier(nil,control)
    bad:=control;bad.rig=core.NONE;modifier(&requests,bad)
    bad=control;bad.name=0;modifier(&requests,bad)
    bad=control;bad.kind=Modifier_Kind(255);modifier(&requests,bad)
    bad=control;bad.fade=-1;modifier(&requests,bad)
    bad=control;bad.weight=2;modifier(&requests,bad)
    for invalid in ([?]f32{transmute(f32)u32(0x7fc00000),transmute(f32)u32(0x7f800000)}) {
        bad=control;bad.weight=invalid;modifier(&requests,bad)
        bad=control;bad.fade=invalid;modifier(&requests,bad)
    }
    testing.expect_value(t,requests.modifiers.refused,9)
    for _ in 0..=cap(requests.modifiers.items) {modifier(&requests,control)}
    testing.expect_value(t,requests.modifiers.dropped,1)
    testing.expect_value(t,len(requests.modifiers.items),cap(requests.modifiers.items))
    testing.expect(t,size_of(Spatial_Target)<=128 && size_of(Modifier_Request)<=160 && size_of(Animation_Target)<=128)
}
