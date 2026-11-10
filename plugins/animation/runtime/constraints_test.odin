package anim

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(private="file")
Constraints_World :: struct {
    using world:core.Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    modifiers:Modifier_Runtime,
}

@(test)
rotation_limits_blend_from_the_input_pose_and_leave_zero_weight_unchanged :: proc(t:^testing.T) {
    w:Constraints_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    rig:=core.create(&w.entities)
    pose:=[2]mm.Transform{mm.TRANSFORM_IDENTITY,{{0,1,0},mm.quat_axis_angle({1,0,0},1),{1,1,1}}}
    state:=constraint_fixture_state(rig,pose[:]);defer playing_free(&state)
    limit:=ROTATION_CONSTRAINT_DEFAULT;limit.rig,limit.bone,limit.max_swing,limit.weight=rig,bone_ref("11"),.2,.5
    core.add(&w.modifiers.limits,rig,limit);core.table_settle(&w.modifiers.limits,&w.entities)
    playback:Playback;cache:Animation_Constraints;defer constraints_free(&cache)
    problems:core.Problems
    constraints_apply(&state,&playback,{limits=core.read(&w.modifiers.limits),problems=&problems},&cache,&w.transforms,core.read(&w.parents),0)
    testing.expect(t,abs(mm.quat_angle(state.local[1].rotation,mm.QUAT_IDENTITY)-.6)<.001)
    state.local[1]=pose[1];core.edit(&w.modifiers.limits,rig).weight=0
    constraints_apply(&state,&playback,{limits=core.read(&w.modifiers.limits),problems=&problems},&cache,&w.transforms,core.read(&w.parents),0)
    testing.expect_value(t,state.local[1],pose[1])
    testing.expect_value(t,problems.count,0)
}

@(test)
in_place_root_motion_preserves_gameplay_actor_placement_and_restores_internal_bone_reference :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    rig,bone:=core.create(&entities),core.create(&entities)
    transforms:core.Table(core.Transform);parents:core.Table(core.Parent);roots:core.Table(Root_Motion)
    defer core.table_destroy(&transforms);defer core.table_destroy(&parents);defer core.table_destroy(&roots)
    rest:=[2]mm.Transform{{{3,0,0},mm.quat_axis_angle({0,1,0},0.2),{1,1,1}},{{0,1,0},1,{1,1,1}}}
    core.add(&transforms,rig,core.from_math(rest[0]));core.add(&transforms,bone,core.from_math(rest[1]))
    core.add(&parents,bone,{entity=rig});core.add(&roots,rig,ROOT_MOTION_DEFAULT)
    core.table_settle(&transforms,&entities);core.table_settle(&parents,&entities);core.table_settle(&roots,&entities)
    state:=constraint_fixture_state(rig,rest[:]);defer playing_free(&state)
    state.targets[0],state.bindings[0].target=0,0
    state.bindings[0].driven={.Position,.Rotation};state.bindings[1].entity=bone
    state.clip=0
    library:lib.Library
    testing.expect(t,lib.library_init(&library,{max_keys=4,max_tracks=2,max_clips=1,max_markers=0}));defer lib.library_destroy(&library)
    turn:=mm.quat_axis_angle({0,1,0},0.5)
    clip,_:=lib.clip_add(&library,{loop=.Loop,tracks={{target=0,property=.Position,keys={{time=0,value={}},{time=1,value={1,0,0,0}}}},{target=0,property=.Rotation,keys={{time=0,value={0,0,0,1}},{time=1,value={imag(turn),jmag(turn),kmag(turn),real(turn)}}}}}})
    lib.fader_play(&state.fader,clip)
    playback:Playback;defer playback_free(&playback)
    bound:=host.Content_Animation{lib=library}
    testing.expect(t,tracks_bind(&playback,&state,&bound))
    cache:Animation_Constraints;defer constraints_free(&cache)
    problems:core.Problems
    expected:=rest[0]
    for _ in 0..<3 {
        motion:=root_motion_sample(&library,state.fader,ROOT_MOTION_DEFAULT,0.25)
        lib.fader_advance(&library,&state.fader,0.25,nil)
        pose_sample(&playback,&state,&library,ANIMATION_DEFAULT,core.read(&transforms),nil)
        constraints_apply(&state,&playback,{roots=core.read(&roots),problems=&problems},&cache,&transforms,core.read(&parents),0.25)
        pose_write(&playback,&state,&transforms)
        current,_:=core.get(&transforms,rig)
        testing.expect_value(t,core.to_math(current),expected)
        expected.position+=mm.quat_rotate(expected.rotation,motion.translation)
        expected.rotation*=motion.rotation
        core.edit(&transforms,rig)^=core.from_math(expected)
    }
    testing.expect(t,linalg.length(expected.position-rest[0].position)>0.5 && mm.quat_angle(expected.rotation,rest[0].rotation)>0.3)
    state.bindings[0].driven={}
    state.local[0]=expected
    state.local[1].position={5,2,0};state.local[1].rotation=mm.quat_axis_angle({0,1,0},0.8)
    core.edit(&roots,rig).bone=bone_ref("11")
    constraints_apply(&state,&playback,{roots=core.read(&roots),problems=&problems},&cache,&transforms,core.read(&parents),0.25)
    testing.expect_value(t,state.local[0],expected)
    testing.expect_value(t,state.local[1],rest[1])
    testing.expect_value(t,problems.count,0)
}

@(test)
retargeting_ignores_actor_wrapper_placement_and_keeps_the_destination_actor_transform :: proc(t:^testing.T) {
    w:Constraints_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    source_entity,target_entity,mapping:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    source_rest:=[2]mm.Transform{{{3,0,0},mm.quat_axis_angle({0,1,0},0.2),{1,1,1}},{{0,1,0},1,{1,1,1}}}
    target_rest:=[2]mm.Transform{{{5,0,0},mm.quat_axis_angle({0,1,0},0.6),{1,1,1}},{{0,2,0},1,{1,1,1}}}
    playback:Playback;defer playback_free(&playback)
    append(&playback.states,constraint_fixture_state(source_entity,source_rest[:]),constraint_fixture_state(target_entity,target_rest[:]))
    resize(&playback.rows,core.entity_index(target_entity)+1)
    playback.rows[core.entity_index(source_entity)],playback.rows[core.entity_index(target_entity)]=1,2
    source:=&playback.states[0];target:=&playback.states[1]
    source.targets[0],source.bindings[0].target=0,0;target.targets[0],target.bindings[0].target=0,0
    source.sampled[0].position={9,0,0};source.sampled[0].rotation=mm.quat_axis_angle({0,1,0},0.8)
    source.sampled[1].rotation=mm.quat_axis_angle({0,0,1},0.3)
    target.local[0].position={12,0,0};target.local[0].rotation=mm.quat_axis_angle({0,1,0},-0.7)
    actor:=target.local[0]
    core.add(&w.modifiers.retargets,mapping,{rig=target_entity,source=source_entity,source_bone=bone_ref("11"),target_bone=bone_ref("11"),enabled=true});core.table_settle(&w.modifiers.retargets,&w.entities)
    cache:Animation_Constraints;defer constraints_free(&cache)
    problems:core.Problems
    constraints_apply(target,&playback,{retargets=core.read(&w.modifiers.retargets),problems=&problems},&cache,&w.transforms,core.read(&w.parents),0.1)
    testing.expect_value(t,target.local[0],actor)
    testing.expect(t,mm.quat_angle(target.local[1].rotation,source.sampled[1].rotation)<0.001)
    testing.expect_value(t,target.local[1].position,mm.Vec3{0,2,0})
    testing.expect_value(t,problems.count,0)
}

@(private="file")
constraint_fixture_state :: proc(entity:core.Entity,locals:[]mm.Transform) -> Playing {
    state:=Playing{entity=entity,bound=1}
    for value,i in locals {
        target:=base.name_hash(fmt.tprintf("%d",i+10))
        append(&state.parents,i32(i)-1);append(&state.targets,target);append(&state.rest,value)
        append(&state.local,value);append(&state.sampled,value);append(&state.world,mm.TRANSFORM_IDENTITY)
        append(&state.bindings,Binding{target=target,entity=entity,rest=value,parent=i32(i)-1})
    }
    return state
}

@(test)
retarget_paths_bind_dense_skeletons_preserve_actor_placement_and_apply_explicit_overrides_without_stable_allocations :: proc(t:^testing.T) {
    w:Constraints_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    source_entity,target_entity:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.transforms,source_entity,core.Transform{{3,0,0},mm.quat_axis_angle({0,1,0},.2),{1,1,1}})
    core.add(&w.transforms,target_entity,core.Transform{{5,0,0},mm.quat_axis_angle({0,1,0},.6),{1,1,1}})
    core.test_world_settle(&w)
    source_bones:=[4]asset.Skeleton_Bone{{parent=-1},{parent=0,translation={0,1,0}},{parent=1,translation={.5,0,0}},{parent=2,translation={.5,0,0}}}
    target_bones:=[6]asset.Skeleton_Bone{{parent=-1},{parent=0,translation={0,2,0}},{parent=1,translation={0,.5,0}},{parent=1,translation={1,0,0}},{parent=3,translation={1,0,0}},{parent=0,translation={0,0,1}}}
    source_paths:=[4]string{"root","root/hips","root/hips/arm","root/hips/arm/hand"}
    target_paths:=[6]string{"root","root/hips","root/hips/decoration","root/hips/arm","root/hips/arm/hand","root/hand"}
    for bones,set in ([]([]asset.Skeleton_Bone){source_bones[:],target_bones[:]}) {
        paths:=source_paths[:] if set==0 else target_paths[:]
        for &bone,i in bones {
            bone.rotation,bone.scale=1,{1,1,1};bone.target=base.name_hash(paths[i])
            base.text_set(bone.path[:],paths[i]);base.text_set(bone.name[:],"hand" if i==len(bones)-1 else paths[i])
        }
    }
    source_content:=Skeleton_Content{id={1,1},revision=1,bones=source_bones[:]}
    target_content:=Skeleton_Content{id={1,2},revision=1,bones=target_bones[:]}
    playback:Playback;defer playback_free(&playback)
    resize(&playback.states,2);resize(&playback.rows,core.entity_index(target_entity)+1)
    source,target:=&playback.states[0],&playback.states[1]
    source.entity,target.entity=source_entity,target_entity
    playback.rows[core.entity_index(source_entity)],playback.rows[core.entity_index(target_entity)]=1,2
    testing.expect(t,skeleton_bind(&playback,source,&source_content,nil,&w.transforms))
    testing.expect(t,skeleton_bind(&playback,target,&target_content,nil,&w.transforms))
    copy(source.sampled[:],source.rest[:])
    source.sampled[0].position={9,0,0};source.sampled[0].rotation=mm.quat_axis_angle({0,1,0},.8)
    source.sampled[1].position.x=.4;source.sampled[2].position.y=1.25
    source.sampled[2].rotation=mm.quat_axis_angle({0,0,1},.15)
    source.sampled[3].rotation=mm.quat_axis_angle({0,0,1},.4)
    source.local[3].rotation=mm.quat_axis_angle({0,0,1},1.2)
    target.local[0].position={12,0,0};target.local[0].rotation=mm.quat_axis_angle({0,1,0},-.7)
    actor:=target.local[0]
    config:=RETARGET_MAPPING_DEFAULT;config.source=source_entity;config.mode=.Paths;config.translation=.Scaled
    core.add(&w.modifiers.retargets,target_entity,config);core.table_settle(&w.modifiers.retargets,&w.entities)
    cache:Animation_Constraints;defer constraints_free(&cache)
    problems:core.Problems
    inputs:=Constraint_Inputs{retargets=core.read(&w.modifiers.retargets),problems=&problems}
    constraints_apply(target,&playback,inputs,&cache,&w.transforms,core.read(&w.parents),0.1)
    retarget:=&cache.rigs[core.entity_index(target_entity)].retarget
    testing.expect(t,retarget.ready && retarget.source_wrapper && retarget.target_wrapper)
    for mapped,i in ([7]i32{-1,1,2,-1,3,4,-1}) {testing.expect_value(t,retarget.mapping[i],mapped)}
    testing.expect_value(t,target.local[0],actor)
    testing.expect_value(t,target.local[1].position,mm.Vec3{.4,0,0})
    testing.expect_value(t,target.local[2].position,mm.Vec3{0,2.5,0})
    testing.expect_value(t,target.local[4].position,mm.Vec3{1,0,0})
    testing.expect_value(t,target.local[3],target.rest[3]);testing.expect_value(t,target.local[6],target.rest[6])
    testing.expect(t,mm.quat_angle(target.local[4].rotation,source.sampled[3].rotation)<.001)
    testing.expect_value(t,target.world[1],mm.transform_compose(actor,target.local[1]))
    testing.expect_value(t,w.entities.alive,2)
    testing.expect_value(t,len(w.modifiers.retargets.values),1)
    failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=0}
    saved_context:=context
    context.allocator={runtime_failure_allocator,&failure};context.temp_allocator=context.allocator
    for _ in 0..<120 {constraints_apply(target,&playback,inputs,&cache,&w.transforms,core.read(&w.parents),1.0/60)}
    context=saved_context
    testing.expect_value(t,failure.calls,0)
    testing.expect_value(t,problems.count,0)
    for &path,i in source.targets {if i>0 {path=u64(i)}}
    source.bound+=1
    constraints_apply(target,&playback,inputs,&cache,&w.transforms,core.read(&w.parents),0.1)
    testing.expect(t,!retarget.ready && problems.count==1 && core.problem_find(&problems,target_entity,"animation.retarget_paths")!=nil)
    for &bone,i in source_bones {source.targets[i+1]=bone.target}
    source.bound+=1
    constraints_apply(target,&playback,inputs,&cache,&w.transforms,core.read(&w.parents),0.1)
    testing.expect(t,retarget.ready && problems.count==1)
    for mapped,i in ([7]i32{-1,1,2,-1,3,4,-1}) {testing.expect_value(t,retarget.mapping[i],mapped)}
    core.edit(&w.modifiers.retargets,target_entity).enabled=false
    constraints_apply(target,&playback,inputs,&cache,&w.transforms,core.read(&w.parents),0.1)
    testing.expect_value(t,problems.count,1)
    override_entity:=core.create(&w.entities)
    explicit:=RETARGET_MAPPING_DEFAULT;explicit.rig=target_entity;explicit.source=source_entity
    explicit.source_bone=bone_ref("root/hips");explicit.target_bone=bone_ref("root/hips/arm")
    for order in 0..<2 {
        ordered:Modifier_Runtime;defer modifier_runtime_free(&ordered)
        if order==0 {core.add(&ordered.retargets,target_entity,config);core.add(&ordered.retargets,override_entity,explicit)}
        else {core.add(&ordered.retargets,override_entity,explicit);core.add(&ordered.retargets,target_entity,config)}
        core.table_settle(&ordered.retargets,&w.entities)
        overrides:Animation_Constraints;defer constraints_free(&overrides)
        override_problems:core.Problems
        constraints_apply(target,&playback,{retargets=core.read(&ordered.retargets),problems=&override_problems},&overrides,&w.transforms,core.read(&w.parents),0.1)
        testing.expect_value(t,overrides.rigs[core.entity_index(target_entity)].retarget.mapping[4],i32(2))
        testing.expect(t,mm.quat_angle(target.local[4].rotation,mm.QUAT_IDENTITY)<.001)
        testing.expect_value(t,override_problems.count,0)
        duplicate:=config;duplicate.rig=target_entity
        core.edit(&ordered.retargets,override_entity)^=duplicate
        constraints_apply(target,&playback,{retargets=core.read(&ordered.retargets),problems=&override_problems},&overrides,&w.transforms,core.read(&w.parents),0.1)
        testing.expect(t,core.problem_find(&override_problems,target_entity,"animation.retarget_mapping")!=nil && !overrides.rigs[core.entity_index(target_entity)].retarget.ready)
    }
}

@(test)
bone_constraints_solve_world_targets_under_rotated_uneven_parents_and_respect_socket_owners :: proc(t:^testing.T) {
    w:Constraints_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    parent,rig,helper,socket:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    external:=mm.Transform{{3,0,0},mm.quat_axis_angle({0,1,0},0.4),{2,1,1}}
    locals:=[3]mm.Transform{{{1,0,0},mm.quat_axis_angle({0,0,1},0.3),{1,1,1}},{{1,0,0},1,{1,1,1}},{{1,0,0},1,{1,1,1}}}
    state:=constraint_fixture_state(rig,locals[:]);defer playing_free(&state)
    state.bindings[1].entity=core.NONE;state.bindings[2].entity=core.NONE
    core.add(&w.transforms,parent,core.from_math(external));core.add(&w.transforms,rig,core.from_math(locals[0]));core.add(&w.transforms,socket,core.TRANSFORM_IDENTITY)
    core.add(&w.parents,rig,{entity=parent})
    core.test_world_settle(&w)
    lib.skeleton_world(playing_skeleton(&state),state.local[:],state.world[:],external)
    target:=state.world[0].position+mm.Vec3{1,1,0}
    config:=IK_CONSTRAINT_DEFAULT;config.rig=rig;config.root,config.joint,config.end=bone_ref("10"),bone_ref("11"),bone_ref("12");config.target=spatial_point(target);config.pole=target+mm.Vec3{0,0,2}
    core.add(&w.modifiers.ik,helper,config)
    socket_config:=BONE_BINDING_DEFAULT;socket_config.rig=rig;socket_config.bone=bone_ref("12");socket_config.offset.position={0,0,0.2}
    core.add(&w.modifiers.sockets,socket,socket_config)
    core.table_settle(&w.modifiers.ik,&w.entities);core.table_settle(&w.modifiers.sockets,&w.entities)
    cache:Animation_Constraints;defer constraints_free(&cache)
    playback:Playback;defer playback_free(&playback)
    problems:core.Problems
    inputs:=Constraint_Inputs{ik=core.read(&w.modifiers.ik),sockets=core.read(&w.modifiers.sockets),problems=&problems}
    constraints_apply(&state,&playback,inputs,&cache,&w.transforms,core.read(&w.parents),0.1)
    testing.expect_value(t,problems.count,0)
    testing.expect(t,linalg.length(state.world[2].position-target)<0.001)
    attached,_:=core.get(&w.transforms,socket)
    expected,_:=lib.skeleton_socket(state.world[:],2,socket_config.offset)
    testing.expect(t,linalg.length(attached.position-expected.position)<0.001)
    resize(&w.transforms.owners,core.entity_index(socket)+1);w.transforms.owners[core.entity_index(socket)]={core.entity_generation(socket),1}
    core.edit(&w.modifiers.ik,helper).target.position+=mm.Vec3{0.2,0,0}
    constraints_apply(&state,&playback,inputs,&cache,&w.transforms,core.read(&w.parents),0.1)
    locked,_:=core.get(&w.transforms,socket)
    testing.expect_value(t,locked,attached)
    testing.expect(t,problems.count==1 && core.problem_find(&problems,socket,"animation.socket_owner")!=nil)
    w.transforms.owners[core.entity_index(socket)]={}
    stable_context:=context
    context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    constraints_apply(&state,&playback,inputs,&cache,&w.transforms,core.read(&w.parents),0.1)
    context=stable_context
    testing.expect_value(t,problems.count,1)
}

@(test)
foot_contact_cache_clones_and_replays_without_sharing_buffers :: proc(t:^testing.T) {
    w:Constraints_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    rig,helper:=core.create(&w.entities),core.create(&w.entities)
    locals:=[3]mm.Transform{{{0,2,0},1,{1,1,1}},{{0,-1,0},1,{1,1,1}},{{0,-1,0},1,{1,1,1}}}
    state:=constraint_fixture_state(rig,locals[:]);defer playing_free(&state)
    core.add(&w.transforms,rig,core.from_math(locals[0]));core.test_world_settle(&w)
    config:=FOOT_CONTACT_CONSTRAINT_DEFAULT;config.rig=rig;config.root,config.joint,config.end=bone_ref("10"),bone_ref("11"),bone_ref("12")
    config.grounded=true;config.hit_position={0,0.1,0};config.pole={0,1,1}
    core.add(&w.modifiers.feet,helper,config);core.table_settle(&w.modifiers.feet,&w.entities)
    problems:core.Problems
    inputs:=Constraint_Inputs{feet=core.read(&w.modifiers.feet),problems=&problems}
    cache:Animation_Constraints;defer constraints_free(&cache)
    playback:Playback;defer playback_free(&playback)
    constraints_apply(&state,&playback,inputs,&cache,&w.transforms,core.read(&w.parents),0.05)
    saved:Animation_Constraints;defer constraints_free(&saved)
    core.value_copy(&saved,&cache,type_info_of(Animation_Constraints))
    testing.expect(t,raw_data(saved.feet)!=raw_data(cache.feet))
    testing.expect(t,raw_data(saved.rigs[core.entity_index(rig)].rows[3])!=raw_data(cache.rigs[core.entity_index(rig)].rows[3]))
    copy(state.local[:],state.rest[:]);state.local[0].position.x=0.1
    constraints_apply(&state,&playback,inputs,&cache,&w.transforms,core.read(&w.parents),0.05)
    expected:=state.world[2]
    copy(state.local[:],state.rest[:]);state.local[0].position.x=0.1
    constraints_apply(&state,&playback,inputs,&saved,&w.transforms,core.read(&w.parents),0.05)
    testing.expect_value(t,state.world[2],expected)
    testing.expect_value(t,saved.feet[0].contact,cache.feet[0].contact)
    testing.expect_value(t,problems.count,0)
}

@(test)
retarget_constraints_read_frozen_source_pose_and_preserve_target_lengths :: proc(t:^testing.T) {
    w:Constraints_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    a,b,mapping0,mapping1:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    source_rest:=[2]mm.Transform{mm.TRANSFORM_IDENTITY,{{1,0,0},1,{1,1,1}}}
    target_rest:=[2]mm.Transform{mm.TRANSFORM_IDENTITY,{{2,0,0},1,{1,1,1}}}
    playback:Playback;defer playback_free(&playback)
    append(&playback.states,constraint_fixture_state(a,source_rest[:]),constraint_fixture_state(b,target_rest[:]))
    resize(&playback.rows,core.entity_index(b)+1)
    playback.rows[core.entity_index(a)],playback.rows[core.entity_index(b)]=1,2
    source:=&playback.states[0];target:=&playback.states[1]
    source.sampled[0].rotation=mm.quat_axis_angle({0,0,1},0.5)
    source.local[0].rotation=mm.quat_axis_angle({0,0,1},1.5)
    core.add(&w.modifiers.retargets,mapping0,{rig=b,source=a,source_bone=bone_ref("10"),target_bone=bone_ref("10"),enabled=true})
    core.add(&w.modifiers.retargets,mapping1,{rig=b,source=a,source_bone=bone_ref("11"),target_bone=bone_ref("11"),enabled=true})
    core.table_settle(&w.modifiers.retargets,&w.entities)
    cache:Animation_Constraints;defer constraints_free(&cache)
    problems:core.Problems
    constraints_apply(target,&playback,{retargets=core.read(&w.modifiers.retargets),problems=&problems},&cache,&w.transforms,core.read(&w.parents),0.1)
    testing.expect(t,mm.quat_angle(target.local[0].rotation,source.sampled[0].rotation)<0.001)
    testing.expect_value(t,target.local[1].position,mm.Vec3{2,0,0})
    testing.expect_value(t,problems.count,0)
    saved_context:=context
    context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    constraints_apply(target,&playback,{retargets=core.read(&w.modifiers.retargets),problems=&problems},&cache,&w.transforms,core.read(&w.parents),0.1)
    context=saved_context
    testing.expect_value(t,problems.count,0)
}
