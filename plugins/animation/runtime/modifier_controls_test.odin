package anim

import "base:runtime"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

@(private="file")
Modifier_Controls_World :: struct {
    using world:core.Test_World,
}

@(test)
modifier_controls_preserve_targets_and_fade_independently_through_world_copies :: proc(t:^testing.T) {
    problems:core.Problems
    w:Modifier_Controls_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    rig:=core.create(&w.entities)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    for _ in 0..<2 {value:=IK_CONSTRAINT_DEFAULT;value.rig,value.pole=rig,{4,5,6};value.target=spatial_point({1,2,3});testing.expect(t,modifier_append(&modifiers.ik,rig,value))}
    look:=LOOK_CONSTRAINT_DEFAULT;look.rig=rig;look.target=spatial_point({3,2,1});testing.expect(t,modifier_append(&modifiers.look,rig,look))
    ground:=FOOT_GROUNDING_DEFAULT;ground.rig,ground.global_contact=rig,.7;testing.expect(t,modifier_append(&modifiers.grounding,rig,ground))
    limit:=ROTATION_CONSTRAINT_DEFAULT;limit.rig=rig;testing.expect(t,modifier_append(&modifiers.limits,rig,limit))
    empty:Modifier_Runtime
    testing.expect(t,modifier_controls_prepare(&modifiers,&empty))
    requests:Modifier_Requests;defer delete(requests.queue.items);defer delete(requests.controls.items)
    modifier_take(&modifiers,&requests,&problems)
    modifier_goal(&requests,{rig=rig,kind=.Look,target=spatial_point({}),weight=.8,enabled=true})
    modifier_control(&requests,{rig=rig,kind=.Look,weight=.5,enabled=true,fade=1})
    modifier_control(&requests,{rig=rig,kind=.IK,slot=1,weight=1,enabled=false,fade=1})
    modifier_control(&requests,{rig=rig,kind=.Grounding,weight=.4,enabled=true})
    modifier_control(&requests,{rig=rig,kind=.Limit,weight=.2,enabled=true})
    modifier_take(&modifiers,&requests,&problems,.5)
    testing.expect_value(t,modifiers.look.values[0].weight,f32(.6))
    testing.expect_value(t,modifiers.look.values[0].target.position,mm.Vec3{})
    testing.expect_value(t,modifiers.ik.values[0].weight,f32(1))
    testing.expect_value(t,modifiers.ik.values[1].weight,f32(.5))
    testing.expect_value(t,modifiers.ik.values[1].pole,mm.Vec3{4,5,6})
    testing.expect_value(t,modifiers.grounding.values[0].weight,f32(.4))
    testing.expect_value(t,modifiers.grounding.values[0].global_contact,f32(.7))
    testing.expect_value(t,modifiers.limits.values[0].weight,f32(.2))
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    copy_requests:Modifier_Requests;core.value_copy(&copy_requests,&requests,type_info_of(Modifier_Requests));defer delete(copy_requests.queue.items);defer delete(copy_requests.controls.items)
    testing.expect(t,raw_data(modifiers.controls)!=raw_data(copied.controls))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    modifier_control(&requests,{rig=rig,kind=.Look,weight=.5,enabled=true,fade=1})
    modifier_take(&modifiers,&requests,&problems,.5)
    modifier_take(&copied,&copy_requests,&problems,.5)
    for _ in 0..<120 {modifier_take(&modifiers,&requests,&problems,1.0/60);modifier_take(&copied,&copy_requests,&problems,1.0/60)}
    context=saved
    testing.expect_value(t,modifiers.look.values[0].weight,f32(.4))
    testing.expect_value(t,modifiers.ik.values[1].weight,f32(0))
    testing.expect(t,!modifiers.ik.values[1].enabled && modifiers.ik.values[0].enabled)
    testing.expect_value(t,modifiers.look.values[0],copied.look.values[0])
    testing.expect_value(t,len(modifiers.controls),len(copied.controls))
    for state,i in modifiers.controls {testing.expect_value(t,state,copied.controls[i])}
    testing.expect_value(t,problems.count,0)
}

@(test)
modifier_fades_track_only_active_rows_cancel_restart_and_survive_reordered_profiles :: proc(t:^testing.T) {
    problems:core.Problems
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    empty:Modifier_Runtime
    first,second:=core.entity_make(9,1),core.entity_make(3,2)
    for entity in ([?]core.Entity{first,second}) {
        for _ in 0..<2 {value:=IK_CONSTRAINT_DEFAULT;value.rig=entity;testing.expect(t,modifier_append(&modifiers.ik,entity,value))}
    }
    testing.expect(t,modifier_controls_prepare(&modifiers,&empty))
    requests:Modifier_Requests;defer delete(requests.controls.items)
    modifier_controls_take(&modifiers,&requests,&problems,0)
    testing.expect(t,modifier_control_state(&modifiers,core.entity_make(3,1),.IK,0)==nil && modifier_control_state(&modifiers,second,.IK,2)==nil)
    modifier_control(&requests,{rig=first,kind=.IK,slot=1,weight=0,fade=1})
    modifier_control(&requests,{rig=second,kind=.IK,weight=.5,enabled=true,fade=2})
    modifier_controls_take(&modifiers,&requests,&problems,.25)
    testing.expect_value(t,len(modifiers.fades),2)
    reordered:Modifier_Runtime;defer modifier_runtime_free(&reordered)
    for entity in ([?]core.Entity{second,first}) {for _ in 0..<2 {value:=IK_CONSTRAINT_DEFAULT;value.rig=entity;testing.expect(t,modifier_append(&reordered.ik,entity,value))}}
    testing.expect(t,modifier_controls_prepare(&reordered,&modifiers))
    testing.expect_value(t,len(reordered.fades),2)
    copied:Modifier_Runtime;core.value_copy(&copied,&reordered,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    testing.expect(t,raw_data(copied.fades)!=raw_data(reordered.fades))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    modifier_control(&requests,{rig=second,kind=.IK,weight=.8,enabled=true})
    modifier_controls_take(&reordered,&requests,&problems,0)
    testing.expect_value(t,len(reordered.fades),1)
    modifier_control(&requests,{rig=second,kind=.IK,weight=.2,enabled=true,fade=.5})
    modifier_controls_take(&reordered,&requests,&problems,.5)
    modifier_controls_take(&copied,&requests,&problems,2)
    modifier_controls_take(&reordered,&requests,&problems,1)
    version:=reordered.ik.version
    for _ in 0..<120 {modifier_controls_take(&reordered,&requests,&problems,1.0/60)}
    context=saved
    testing.expect(t,len(reordered.fades)==0 && len(copied.fades)==0 && reordered.ik.version==version && problems.count==0)
    testing.expect_value(t,modifier_control_state(&reordered,first,.IK,1).weight,f32(0))
    testing.expect_value(t,modifier_control_state(&reordered,second,.IK,0).weight,f32(.2))
    testing.expect_value(t,modifier_control_state(&copied,second,.IK,0).weight,f32(.5))
}

@(test)
modifier_control_requests_reject_invalid_slots_values_and_exhausted_capacity :: proc(t:^testing.T) {
    requests:Modifier_Requests;defer delete(requests.controls.items)
    reserve(&requests.controls.items,4)
    control:=Modifier_Control{rig=core.Entity(1),kind=.IK,weight=1,enabled=true}
    modifier_control(nil,control)
    bad:=control;bad.rig=core.NONE;modifier_control(&requests,bad)
    bad=control;bad.slot=POSE_CONSTRAINTS;modifier_control(&requests,bad)
    bad=control;bad.kind=.Grounding;bad.slot=1;modifier_control(&requests,bad)
    bad=control;bad.fade=-1;modifier_control(&requests,bad)
    bad=control;bad.weight=2;modifier_control(&requests,bad)
    for invalid in ([?]f32{transmute(f32)u32(0x7fc00000),transmute(f32)u32(0x7f800000)}) {
        bad=control;bad.weight=invalid;modifier_control(&requests,bad)
        bad=control;bad.fade=invalid;modifier_control(&requests,bad)
    }
    testing.expect_value(t,requests.controls.refused,9)
    for _ in 0..=cap(requests.controls.items) {modifier_control(&requests,control)}
    testing.expect_value(t,requests.controls.dropped,1)
    testing.expect_value(t,len(requests.controls.items),cap(requests.controls.items))
}
