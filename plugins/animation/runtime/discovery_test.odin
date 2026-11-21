package anim

import "base:runtime"
import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

@(private)
@(test_world)
Discovery_World :: struct {
    using world:Test_World,
    animations:core.Table(Animation),
    attachments:core.Table(Bone_Attachment),
}

@(test)
modifier_preparation_ignores_unrelated_writes_reloads_only_changed_definitions_and_preserves_headers_on_failure :: proc(t:^testing.T) {
    w:Discovery_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    looker,plain:=core.create(&w.entities),core.create(&w.entities)
    description:=ANIMATION_DEFAULT;description.asset={3,4}
    core.add(&w.animations,looker,description);core.add(&w.animations,plain,ANIMATION_DEFAULT);test_world_settle(&w)
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
    tracked:=mem.tracking_allocator(&tracker)
    characters:Character_Assets;defer character_assets_free(&characters)
    look:=make([]Look_Constraint,1);defer delete(look);look[0]=LOOK_CONSTRAINT_DEFAULT;look[0].bone=bone_ref("head")
    spring:=SPRING_CONSTRAINT_DEFAULT;base.text_set(spring.name[:],"tail")
    spring.root,spring.end=bone_ref("joint1"),bone_ref("joint3")
    follow:=FOLLOW_CONSTRAINT_DEFAULT;base.text_set(follow.name[:],"chest")
    follow.bone=bone_ref("joint2");follow.keep_world=true
    test_character_seed(&characters,{3,4},{pose={look=look,springs={spring},follow={follow}}})
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=tracked}
    test_character_register(&host_assets,{3,4});defer test_registry_free(&host_assets)
    playback:Playback;defer playback_free(&playback)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    prepare :: proc(modifiers:^Modifier_Runtime,w:^Discovery_World,characters:^Character_Assets,skeletons:^Skeleton_Assets,playback:^Playback,app:^host.App) -> bool {
        return modifier_prepare(modifiers,&w.animations,&w.attachments,characters,skeletons,playback,app.assets,app.allocator,nil)
    }
    if !testing.expect(t,prepare(&modifiers,&w,&characters,&skeletons,&playback,&app)) {return}
    rig:=modifier_rig(core.ref(&modifiers),looker)
    revision:=rig.revision
    buffer:=raw_data(rig.look_states)
    testing.expect(t,len(rig.look_states)==1 && len(modifiers.rigs)==1)
    core.edit(&w.animations,plain).weight=.4;core.edit(&w.animations,looker).speed=.7
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared:=prepare(&modifiers,&w,&characters,&skeletons,&playback,&app)
    host_assets.revision+=1
    prepared &&=prepare(&modifiers,&w,&characters,&skeletons,&playback,&app)
    context=saved;app.allocator=tracked;characters.allocator=tracked
    testing.expect(t,prepared && rig.revision==revision && raw_data(rig.look_states)==buffer)

    state:=rig_test_state(looker,3,1);defer playing_free(&state)
    requests:Animation_Requests;defer delete(requests.modifiers.items)
    modifier(&requests,{rig=looker,kind=.Spring,position={1,0,0},weight=1,enabled=true,goal=true},"tail")
    modifier(&requests,{rig=looker,kind=.Follow,target=spatial_point({1,2,3}),weight=1,enabled=true,goal=true},"chest")
    modifier_take(&modifiers,&characters,&requests,nil,0)
    testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,{},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60))
    spring_state,follow_state:=raw_data(rig.spring_states),raw_data(rig.follow_states)
    joint,offset:=spring_state[0].springs[1],follow_state[0].offset
    testing.expect(t,joint.ready && follow_state[0].space_ready)

    testing.expect(t,reserve(&modifiers.rigs,4)==nil && reserve(&modifiers.rows,8)==nil)
    testing.expect(t,resize(&modifiers.rows,8)==nil)
    rigs,rows:=raw_data(modifiers.rigs),raw_data(modifiers.rows)
    born:=core.create(&w.entities)
    core.add(&w.animations,born,description);test_world_settle(&w)
    if !testing.expect(t,prepare(&modifiers,&w,&characters,&skeletons,&playback,&app)) {return}
    rig=modifier_rig(core.ref(&modifiers),looker)
    testing.expect(t,modifier_rig(core.ref(&modifiers),born)!=nil && raw_data(modifiers.rigs)==rigs &&
        raw_data(modifiers.rows)==rows && raw_data(rig.spring_states)==spring_state &&
        raw_data(rig.follow_states)==follow_state)
    testing.expect(t,spring_state[0].springs[1]==joint && follow_state[0].offset==offset)

    core.destroy(&w.entities,born);test_world_settle(&w)
    allocations:=tracker.total_allocation_count
    failure:=Runtime_Allocation_Failure{owner=saved.allocator}
    context.allocator={runtime_failure_allocator,&failure}
    context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared=prepare(&modifiers,&w,&characters,&skeletons,&playback,&app)
    preserved:=spring_state[0].springs[1]==joint && follow_state[0].offset==offset
    stable:=true
    for _ in 0..<64 {
        copy(playing_pose(&state,.Local),state.rest[:])
        stable &&=prepare(&modifiers,&w,&characters,&skeletons,&playback,&app)
        stable &&=test_rigs_apply(&state,&modifiers,&characters,{},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60)
    }
    context=saved;app.allocator=tracked;characters.allocator=tracked
    testing.expect_value(t,tracker.total_allocation_count,allocations)
    testing.expect(t,prepared && stable && preserved && failure.calls==0 &&
        modifier_rig(core.ref(&modifiers),born)==nil && raw_data(modifier_rig(core.ref(&modifiers),looker).spring_states)==spring_state)

    look[0].weight=.3;characters.contents[0].revision+=1;host_assets.revision+=1
    if !testing.expect(t,prepare(&modifiers,&w,&characters,&skeletons,&playback,&app)) {return}
    rig=modifier_rig(core.ref(&modifiers),looker)
    testing.expect(t,rig.revision==revision+1 && test_modifier_weight(&modifiers,looker,.Look,"head")==.3)
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    modifier_rig(core.ref(&copied),looker).revision+=100
    testing.expect(t,modifier_rig(core.ref(&copied),looker).revision!=rig.revision)
    inputs:=modifiers.inputs;revision=rig.revision
    look[0].weight=.6;characters.contents[0].revision+=1;host_assets.revision+=1
    context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared=prepare(&modifiers,&w,&characters,&skeletons,&playback,&app)
    context=saved;app.allocator=tracked;characters.allocator=tracked
    testing.expect(t,!prepared && modifiers.inputs==inputs && rig.revision==revision &&
        test_modifier_weight(&modifiers,looker,.Look,"head")==.3)
    testing.expect(t,prepare(&modifiers,&w,&characters,&skeletons,&playback,&app) &&
        test_modifier_weight(&modifiers,looker,.Look,"head")==.6 && rig.revision==revision+1)

    old:=looker;index:=core.entity_index(looker)
    core.destroy(&w.entities,looker);test_world_settle(&w)
    looker=core.create(&w.entities);core.add(&w.animations,looker,description);test_world_settle(&w)
    testing.expect(t,prepare(&modifiers,&w,&characters,&skeletons,&playback,&app) && looker!=old &&
        core.entity_index(looker)==index && modifier_rig(core.ref(&modifiers),old)==nil &&
        modifier_rig(core.ref(&modifiers),looker)!=nil)
}


@(test)
ordering_requests_keeps_each_entities_sequence_without_stable_allocations :: proc(t:^testing.T) {
    playback:Playback
    defer playback_free(&playback)
    commands:=[5]Animation_Command{
        {entity=core.Entity(2),command=.Pause},
        {entity=core.Entity(1),command=.Play},
        {entity=core.Entity(2),command=.Resume},
        {entity=core.Entity(3),command=.Stop},
        {entity=core.Entity(1),command=.Pause},
    }
    if !testing.expect(t,program_array_reserve(&playback.request_order,len(commands))) {return}
    saved:=context
    failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=0}
    context.allocator={runtime_failure_allocator,&failure}
    context.temp_allocator=context.allocator
    sorted:=request_sort(&playback,commands[:])
    context=saved
    testing.expect(t,sorted && failure.calls==0)
    for entity in 1..=2 {
        requests:=entity_requests(commands[:],core.Entity(entity))
        if !testing.expect_value(t,len(requests),2) {return}
        testing.expect_value(t,requests[0].command,.Play if entity==1 else .Pause)
        testing.expect_value(t,requests[1].command,.Pause if entity==1 else .Resume)
    }
}
