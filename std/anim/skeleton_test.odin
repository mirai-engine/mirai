package mirai_anim

import "core:testing"
import "core:math/linalg"
import math "mirai:std/math"

@(private)
skel_near :: proc(a,b:math.Vec3) -> bool {return linalg.length(a-b)<0.0002}

@(test)
skeletal_samples_bind_once_and_keep_reference_channels :: proc(t:^testing.T) {
    lib:=make_library(t);defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{tracks={{target=7,property=.Position,keys={{time=0,value={0,0,0,0}},{time=1,value={2,0,0,0}}}}}})
    parents:=[2]i32{-1,0}
    names:=[2]u64{7,8}
    rest:=[2]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}}}
    skeleton:=Skeleton{parents[:],names[:],rest[:]}
    bindings:[2]Bone_Tracks
    local,world:[2]math.Transform
    testing.expect(t,skeleton_bind(&lib,clip,skeleton,bindings[:]))
    testing.expect(t,skeleton_sample(&lib,bindings[:],rest[:],0.5,local[:]))
    testing.expect(t,skeleton_world(skeleton,local[:],world[:]))
    testing.expect(t,skel_near(world[1].position,{1,1,0}))
    testing.expect_value(t,local[1],rest[1])
    socket,ok:=skeleton_socket(world[:],1,{{0,0,1},1,{1,1,1}})
    testing.expect(t,ok && skel_near(socket.position,{1,1,1}))
    inverse:=[2]math.Mat4{1,1}
    palette:[2]math.Mat4
    testing.expect(t,skeleton_palette(world[:],inverse[:],palette[:]))
    testing.expect(t,near(palette[1][0,3],1) && near(palette[1][1,3],1))
    parents[0]=0
    testing.expect(t,!skeleton_validate(skeleton))
    testing.expect(t,!skeleton_world(skeleton,local[:],world[:]))
    testing.expect(t,!skeleton_sample(&lib,bindings[:1],rest[:],0,local[:]))
    bindings[0].position=999
    testing.expect(t,!skeleton_sample(&lib,bindings[:],rest[:],0,local[:]))
}

@(test)
world_poses_validate_topology_values_and_aliases_without_a_reference_skeleton :: proc(t:^testing.T) {
    parents:=[3]i32{-1,0,1}
    local:=[3]math.Transform{math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY}
    local[1].position.y=1;local[2].position.y=1
    out:[3]math.Transform
    testing.expect(t,pose_world(parents[:],local[:],out[:]) && skel_near(out[2].position,{0,2,0}))
    placed:=local
    testing.expect(t,pose_world(parents[:],placed[:],placed[:]) && placed==out)
    parents[2]=2;testing.expect(t,!pose_world(parents[:],local[:],out[:]));parents[2]=1
    parents[1]=-2;testing.expect(t,!pose_world(parents[:],local[:],out[:]));parents[1]=0
    testing.expect(t,!pose_world(parents[:2],local[:],out[:]))
    testing.expect(t,!pose_world(nil,nil,nil))
    testing.expect(t,!pose_world(parents[:],local[:],out[:2]))
    invalid:=local;invalid[1].rotation=0;testing.expect(t,!pose_world(parents[:],invalid[:],out[:]))
    invalid=local;invalid[1].position.x=f32(0h7fc00000);testing.expect(t,!pose_world(parents[:],invalid[:],out[:]))
    invalid=local;invalid[0].scale.x=max(f32);invalid[1].scale.x=2;testing.expect(t,!pose_world(parents[:],invalid[:],out[:]))
    testing.expect(t,!pose_world(parents[:],local[:],out[:],math.Transform{}))
    overlapping:=[4]math.Transform{local[0],local[1],local[2],math.TRANSFORM_IDENTITY}
    testing.expect(t,!pose_world(parents[:],overlapping[:3],overlapping[1:]))
}

@(test)
a_branch_mask_weighs_the_bones_under_its_bone :: proc(t:^testing.T) {
    rest:=[2]math.Transform{math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY}
    weights:=[2]f32{0,0.5}
    parents:=[2]i32{-1,0};names:=[2]u64{1,2}
    testing.expect(t,pose_mask_branch({parents[:],names[:],rest[:]},1,0.7,weights[:]))
    testing.expect(t,weights=={0,0.7})
    zero:Skeleton
    testing.expect(t,!skeleton_validate(zero) && !skeleton_world(zero,nil,nil))
}

@(test)
marker_sync_matches_contacts_across_uneven_clip_timings :: proc(t:^testing.T) {
    lib:=make_library(t);defer library_destroy(&lib)
    a,_:=clip_add(&lib,{loop=.Loop,markers={{0,1},{0.2,2},{1,1}}})
    b,_:=clip_add(&lib,{loop=.Loop,markers={{0,1},{1,2},{2,1}}})
    player:=player_make(a);player.time=0.1
    phase,ok:=sync_phase(&lib,player)
    testing.expect(t,ok && phase.markers)
    target,valid:=sync_time(&lib,b,phase)
    testing.expect(t,valid && near(target,0.5))
    player.time=0.6
    phase,ok=sync_phase(&lib,player)
    target,valid=sync_time(&lib,b,phase)
    testing.expect(t,ok && valid && near(target,1.5))
    follower:=player_make(b)
    testing.expect(t,player_synchronize(&lib,&follower,phase) && near(follower.time,1.5) && !follower.fresh)
}

@(test)
two_bone_ik_preserves_lengths_and_clamps_unreachable_targets :: proc(t:^testing.T) {
    root:=math.TRANSFORM_IDENTITY
    joint:=math.Transform{{1,0,0},1,{1,1,1}}
    end:=math.Transform{{2,0,0},1,{1,1,1}}
    result,ok:=two_bone_ik(root,joint,end,{1,1,0},{0,1,0})
    testing.expect(t,ok && result.reached && skel_near(result.end.position,{1,1,0}))
    testing.expect(t,near(linalg.length(result.joint.position-root.position),1) && near(linalg.length(result.end.position-result.joint.position),1))
    result,ok=two_bone_ik(root,joint,end,{5,0,0},{0,1,0})
    testing.expect(t,ok && !result.reached && skel_near(result.end.position,{2,0,0}))
    result,ok=two_bone_ik(root,joint,end,{0,0,0},{0,0,0})
    testing.expect(t,ok && skel_near(result.end.position,{}) && anim_transform_valid(result.joint))
    _,ok=two_bone_ik(root,root,end,{1,1,0},{0,1,0})
    testing.expect(t,!ok)
    parents:=[3]i32{-1,0,1};names:=[3]u64{1,2,3}
    local:=[3]math.Transform{root,joint,joint}
    world:[3]math.Transform
    testing.expect(t,skeleton_ik({parents[:],names[:],local[:]},local[:],world[:],0,1,2,{1,1,0},{0,1,0}))
    testing.expect(t,skel_near(world[2].position,{1,1,0}))
}

@(test)
look_at_and_swing_twist_limits_respect_angular_bounds :: proc(t:^testing.T) {
    rotation,ok:=look_at(1,{0,0,1},{1,0,0},0.4)
    testing.expect(t,ok && abs(math.quat_angle(1,rotation)-0.4)<0.001)
    turn:=math.quat_axis_angle({0,1,0},1.2)
    limited,valid:=rotation_limit(turn,1,{{0,1,0},1,-0.2,0.3})
    testing.expect(t,valid && abs(math.quat_angle(1,limited)-0.3)<0.001)
    swing:=math.quat_axis_angle({1,0,0},1.2)
    limited,valid=rotation_limit(swing,1,{{0,1,0},0.4,-0.2,0.3})
    testing.expect(t,valid && abs(math.quat_angle(1,limited)-0.4)<0.001)
    _,ok=look_at(1,{}, {1,0,0},1)
    testing.expect(t,!ok)
}

@(test)
foot_contacts_and_pelvis_replay_from_plain_snapshots :: proc(t:^testing.T) {
    state:Foot_Contact
    first,ok:=foot_plant(&state,{0,1,0},{0,0,0},{0,1,0},true,1,0.1,0.2,2)
    testing.expect(t,ok && state.planted && near(first.weight,0.5))
    snapshot:=state
    second,valid:=foot_plant(&state,{0.3,1,0},{0.3,0,0},{0,1,0},true,1,0.1,0.2,2)
    testing.expect(t,valid && skel_near(second.position,{}))
    replay:=snapshot
    repeated,_:=foot_plant(&replay,{0.3,1,0},{0.3,0,0},{0,1,0},true,1,0.1,0.2,2)
    testing.expect_value(t,repeated,second)
    testing.expect_value(t,replay,state)
    feet:=[2]math.Vec3{{0,1,0},{1,1,0}}
    targets:=[2]Foot_Target{second,{{1,0.4,0},{0,1,0},1}}
    pelvis,adjusted:=pelvis_offset(feet[:],targets[:],{0,1,0},0.8,0.2)
    testing.expect(t,adjusted && near(pelvis.y,-0.8))
    _,valid=foot_plant(&state,{0.3,1,0},{},{0,1,0},false,0,0.1,0.2,2)
    testing.expect(t,valid && !state.planted && near(state.weight,0.5))
}

@(test)
retargeting_preserves_target_proportions_and_reference_orientation :: proc(t:^testing.T) {
    parents:=[2]i32{-1,0};names:=[2]u64{1,2}
    source_rest:=[2]math.Transform{math.TRANSFORM_IDENTITY,{{1,0,0},1,{1,1,1}}}
    target_rest:=[2]math.Transform{math.TRANSFORM_IDENTITY,{{2,0,0},math.quat_axis_angle({1,0,0},0.5),{1,1,1}}}
    source:=Skeleton{parents[:],names[:],source_rest[:]}
    target:=Skeleton{parents[:],names[:],target_rest[:]}
    mapping:=[2]i32{0,1}
    translations:=[2]Retarget_Translation{.Absolute,.Reference}
    source_world,target_world,out:[2]math.Transform
    profile:[2]Retarget_Bone
    testing.expect(t,retarget_prepare(source,target,mapping[:],translations[:],source_world[:],target_world[:],profile[:]))
    current:=source_rest
    current[0].position={0,1,0};current[0].rotation=math.quat_axis_angle({0,0,1},0.5)
    testing.expect(t,retarget_pose(source,target,profile[:],current[:],source_world[:],target_world[:],out[:]))
    testing.expect(t,skel_near(out[1].position,{2,0,0}) && skel_near(out[0].position,{0,1,0}))
    testing.expect(t,math.quat_angle(out[1].rotation,target_rest[1].rotation)<0.001)
    profile[1].source=10
    testing.expect(t,!retarget_pose(source,target,profile[:],current[:],source_world[:],target_world[:],out[:]))
}

@(test)
quaternion_cubic_spline_uses_authored_component_tangents :: proc(t:^testing.T) {
    keys:=[2]Keyframe{
        {time=0,value={0,0,0,1},tangents=true,out_slope={0,2,0,0}},
        {time=2,value={0,0,0,1},tangents=true,in_slope={0,-2,0,0},interpolation=.Cubic_Spline},
    }
    value:=track_evaluate(keys[:],.Rotation,1)
    testing.expect(t,near(value.y,0.70710677) && near(value.w,0.70710677))
}
