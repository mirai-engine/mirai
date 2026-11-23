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

@(private)
@(test_world)
Constraints_World :: struct {
    using world:Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    modifiers:Modifier_Runtime,
}

@(test)
rotation_limits_blend_from_the_input_pose_and_leave_zero_weight_unchanged :: proc(t:^testing.T) {
    w:Constraints_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    rig:=core.create(&w.entities)
    pose:=[2]mm.Transform{mm.TRANSFORM_IDENTITY,{{0,1,0},mm.quat_axis_angle({1,0,0},1),{1,1,1}}}
    state:=constraint_fixture_state(rig,pose[:]);defer playing_free(&state)
    limit:=ROTATION_CONSTRAINT_DEFAULT;limit.bone,limit.max_swing,limit.weight=bone_ref("11"),.2,.5
    characters:Character_Assets;defer character_assets_free(&characters)
    prepared:=test_modifier_profile(&w.modifiers,&characters,rig,{limits={limit}})
    playback:Playback
    problems:core.Problems
    constraints_apply(&state,&playback,{problems=&problems},&w.modifiers,&w.transforms,core.read(&w.parents),0,characters=&characters)
    testing.expect(t,abs(mm.quat_angle(playing_pose(&state,.Local)[1].rotation,mm.QUAT_IDENTITY)-.6)<.001)
    playing_pose(&state,.Local)[1]=pose[1];modifier_states(prepared,.Limit)[0].base_weight=0
    constraints_apply(&state,&playback,{problems=&problems},&w.modifiers,&w.transforms,core.read(&w.parents),0,characters=&characters)
    testing.expect_value(t,playing_pose(&state,.Local)[1],pose[1])
    testing.expect_value(t,problems.count,0)
}

@(test)
in_place_root_motion_preserves_gameplay_actor_placement_and_restores_internal_bone_reference :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    rig,bone:=core.create(&entities),core.create(&entities)
    transforms:core.Table(core.Transform);parents:core.Table(core.Parent)
    defer core.table_destroy(&transforms);defer core.table_destroy(&parents)
    rest:=[2]mm.Transform{{{3,0,0},mm.quat_axis_angle({0,1,0},0.2),{1,1,1}},{{0,1,0},1,{1,1,1}}}
    core.add(&transforms,rig,core.from_math(rest[0]));core.add(&transforms,bone,core.from_math(rest[1]))
    core.add(&parents,bone,{entity=rig})
    core.table_settle(&transforms,&entities);core.table_settle(&parents,&entities)
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
    roots:=[1]asset.Animation_Root{{translation=true,rotation=true}}
    bound:=host.Content_Animation{lib=library,clip_count=1,roots=roots[:]}
    testing.expect(t,tracks_bind(&playback,&state,&bound))
    cache:Modifier_Runtime;defer modifier_runtime_free(&cache)
    problems:core.Problems
    animation:=ANIMATION_DEFAULT;animation.root_motion=.In_Place
    state.root={translation=true,rotation=true,in_place=true}
    expected:=rest[0]
    for _ in 0..<3 {
        motion:=root_motion_sample(&library,state.fader,ROOT_MOTION_DEFAULT,0.25)
        lib.fader_advance(&library,&state.fader,0.25,nil)
        pose_sample(&playback,&state,&bound,animation,core.read(&transforms))
        constraints_apply(&state,&playback,{problems=&problems},&cache,&transforms,core.read(&parents),0.25)
        pose_write(&playback,&state,&transforms)
        current,_:=core.get(&transforms,rig)
        testing.expect_value(t,core.to_math(current),expected)
        expected.position+=mm.quat_rotate(expected.rotation,motion.translation)
        expected.rotation*=motion.rotation
        core.edit(&transforms,rig)^=core.from_math(expected)
    }
    testing.expect(t,linalg.length(expected.position-rest[0].position)>0.5 && mm.quat_angle(expected.rotation,rest[0].rotation)>0.3)
    testing.expect_value(t,problems.count,0)
}

@(private="file")
constraint_fixture_state :: proc(entity:core.Entity,locals:[]mm.Transform) -> Playing {
    state:=Playing{entity=entity,bound=1}
    for value,i in locals {
        target:=base.name_hash(fmt.tprintf("%d",i+10))
        append(&state.parents,i32(i)-1);append(&state.targets,target);append(&state.aliases,target);append(&state.rest,value)
        index:=state.pose_count
        playing_pose_resize(&state,index+1)
        playing_pose(&state,.Local)[index]=value;playing_pose(&state,.Sampled)[index]=value;playing_pose(&state,.World)[index]=mm.TRANSFORM_IDENTITY;
        append(&state.bindings,Binding{target=target,entity=entity,parent=i32(i)-1})
    }
    return state
}

@(test)
bone_constraints_solve_world_targets_under_rotated_uneven_parents_and_respect_socket_owners :: proc(t:^testing.T) {
    w:Constraints_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    parent,rig,socket:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    external:=mm.Transform{{3,0,0},mm.quat_axis_angle({0,1,0},0.4),{2,1,1}}
    locals:=[3]mm.Transform{{{1,0,0},mm.quat_axis_angle({0,0,1},0.3),{1,1,1}},{{1,0,0},1,{1,1,1}},{{1,0,0},1,{1,1,1}}}
    state:=constraint_fixture_state(rig,locals[:]);defer playing_free(&state)
    state.bindings[1].entity=core.NONE;state.bindings[2].entity=core.NONE
    core.add(&w.transforms,parent,core.from_math(external));core.add(&w.transforms,rig,core.from_math(locals[0]));core.add(&w.transforms,socket,core.TRANSFORM_IDENTITY)
    core.add(&w.parents,rig,{entity=parent})
    test_world_settle(&w)
    lib.skeleton_world(playing_skeleton(&state),playing_pose(&state,.Local),playing_pose(&state,.World),external)
    target:=playing_pose(&state,.World)[0].position+mm.Vec3{1,1,0}
    config:=IK_CONSTRAINT_DEFAULT;config.root,config.joint,config.end=bone_ref("10"),bone_ref("11"),bone_ref("12");config.target=spatial_definition_point(target);config.pole=target+mm.Vec3{0,0,2}
    values:=[1]IK_Constraint{config}
    characters:Character_Assets;defer character_assets_free(&characters)
    prepared:=test_modifier_profile(&w.modifiers,&characters,rig,{ik=values[:]})
    socket_config:=Attachment_Binding{entity=socket,bone=base.name_hash("12"),index=-1,offset=mm.TRANSFORM_IDENTITY}
    socket_config.offset.position={0,0,.2}
    append(&prepared.attachments,socket_config)
    playback:Playback;defer playback_free(&playback)
    problems:core.Problems
    inputs:=Constraint_Inputs{problems=&problems}
    constraints_apply(&state,&playback,inputs,&w.modifiers,&w.transforms,core.read(&w.parents),0.1,characters=&characters)
    testing.expect_value(t,problems.count,0)
    testing.expect(t,linalg.length(playing_pose(&state,.World)[2].position-target)<0.001)
    attached,_:=core.get(&w.transforms,socket)
    expected,_:=lib.skeleton_socket(playing_pose(&state,.World),2,socket_config.offset)
    testing.expect(t,linalg.length(attached.position-expected.position)<0.001)
    testing.expect(t,core.owner_set(&w.transforms,socket,1))
    values[0].target.position+=mm.Vec3{0.2,0,0}
    constraints_apply(&state,&playback,inputs,&w.modifiers,&w.transforms,core.read(&w.parents),0.1,characters=&characters)
    locked,_:=core.get(&w.transforms,socket)
    testing.expect_value(t,locked,attached)
    testing.expect(t,problems.count==1 && core.problem_find(&problems,socket,"animation.socket_owner")!=nil)
    testing.expect(t,core.owner_set(&w.transforms,socket,0))
    stable_context:=context
    context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    constraints_apply(&state,&playback,inputs,&w.modifiers,&w.transforms,core.read(&w.parents),0.1,characters=&characters)
    context=stable_context
    testing.expect_value(t,problems.count,1)
}

