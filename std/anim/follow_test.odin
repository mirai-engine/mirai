package mirai_anim

import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

@(test)
a_follower_takes_the_bones_it_shares_by_name_wherever_their_parents_differ_and_keeps_its_own :: proc(t:^testing.T) {
    // Leader: root, pelvis, spine, neck, head; follower: root, neck under root, head, jaw.
    leader_parents:=[5]i32{-1,0,1,2,3}
    leader_names:=[5]u64{1,2,3,4,5}
    leader_paths:=[5]u64{11,12,13,14,15}
    rest:=[5]math.Transform{}
    for &value,i in rest {value={{0,f32(i)*.2,0},1,{1,1,1}}}
    leader_local:=rest
    leader_local[2].rotation=math.quat_axis_angle({0,0,1},.3)
    leader_local[4].rotation=math.quat_axis_angle({0,1,0},.4)
    leader_world:[5]math.Transform
    testing.expect(t,pose_world(leader_parents[:],leader_local[:],leader_world[:]))

    follower_parents:=[4]i32{-1,0,1,2}
    follower_names:=[4]u64{1,4,5,99}
    follower_paths:=[4]u64{11,21,22,23}
    follower_rest:=[4]math.Transform{rest[0],rest[3],rest[4],{{0,0,.1},1,{1,1,1}}}
    bones:[4]Follow_Bone
    shared,ok:=follow_prepare({follower_parents[:],follower_paths[:],follower_rest[:]},{leader_parents[:],leader_paths[:],rest[:]},follower_names[:],leader_names[:],bones[:])
    testing.expect(t,ok && shared==3)
    testing.expect_value(t,bones[1],Follow_Bone{leader=3,local=false}) // its parent is root, the leader's spine
    testing.expect_value(t,bones[2],Follow_Bone{leader=4,local=true})
    testing.expect_value(t,bones[3].leader,i32(-1))

    local:=follower_rest
    local[3].rotation=math.quat_axis_angle({1,0,0},.5) // its own animation
    world:[4]math.Transform
    testing.expect(t,follow_pose(follower_parents[:],bones[:],leader_local[:],leader_world[:],local[:],world[:]))
    for pair in ([2][2]int{{1,3},{2,4}}) {
        testing.expect(t,linalg.length(world[pair[0]].position-leader_world[pair[1]].position)<1e-5 && math.quat_angle(world[pair[0]].rotation,leader_world[pair[1]].rotation)<1e-4)
    }
    testing.expect_value(t,local[3].rotation,math.quat_axis_angle({1,0,0},.5))

    // A name that repeats pairs by path, and a name or path 0 with nothing.
    repeated:=[4]u64{1,4,4,0}
    paths:=[4]u64{11,14,15,0}
    shared,ok=follow_prepare({follower_parents[:],paths[:],follower_rest[:]},{leader_parents[:],leader_paths[:],rest[:]},repeated[:],leader_names[:],bones[:])
    testing.expect(t,ok && shared==3 && bones[1].leader==3 && bones[2].leader==4 && bones[3].leader==-1)
}

@(test)
follow_and_pose_deltas_refuse_hostile_inputs_without_touching_what_they_refuse :: proc(t:^testing.T) {
    parents:=[3]i32{-1,0,1}
    names:=[3]u64{1,2,3}
    rest:=[3]math.Transform{math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY}
    bones:[3]Follow_Bone
    _,ok:=follow_prepare({parents[:],names[:],rest[:]},{parents[:],names[:],rest[:]},names[:],names[:],bones[:2])
    testing.expect(t,!ok,"a table of another length")
    unordered:=[3]i32{-1,2,0}
    _,ok=follow_prepare({unordered[:],names[:],rest[:]},{parents[:],names[:],rest[:]},names[:],names[:],bones[:])
    testing.expect(t,!ok,"a parent after its child")
    _,ok=follow_prepare({parents[:],names[:],rest[:]},{parents[:],names[:],rest[:]},names[:],names[:],bones[:])
    testing.expect(t,ok)
    local,world,leader:=rest,rest,rest
    nan:=f32(0);nan=nan/nan
    leader[1].position.x=nan
    testing.expect(t,!follow_pose(parents[:],bones[:],leader[:],leader[:],local[:],world[:]),"a leader that is not finite")
    zero:=rest;zero[0].scale={}
    testing.expect(t,!follow_pose(parents[:],bones[:],rest[:],rest[:],local[:],world[:],zero[0]),"a root of zero scale")
    far:=bones;far[2].leader=7
    testing.expect(t,!follow_pose(parents[:],far[:],rest[:],rest[:],local[:],world[:]),"a leader bone out of range")
    testing.expect(t,!follow_pose(parents[:],bones[:],rest[:],rest[:],local[:],local[:]),"overlapping buffers")

    value:=math.TRANSFORM_IDENTITY
    delta:=math.Transform{{0,1,0},math.quat_axis_angle({1,0,0},1),{2,2,2}}
    sum:Pose_Accumulator
    testing.expect(t,!pose_delta_accumulate(&sum,delta,nan) && sum=={})
    testing.expect(t,!pose_delta_accumulate(nil,delta,1))
    bad:=delta;bad.rotation={}
    testing.expect(t,!pose_delta_accumulate(&sum,bad,1) && sum=={})
    testing.expect(t,pose_delta_accumulate(&sum,delta,4) && pose_accumulated_apply(&value,sum)) // a weight past 1 is 1
    testing.expect(t,linalg.length(value.position-math.Vec3{0,1,0})<1e-6 && linalg.length(value.scale-math.Vec3{2,2,2})<1e-6 && math.quat_angle(value.rotation,delta.rotation)<1e-5)
    half:=math.TRANSFORM_IDENTITY
    sum={}
    testing.expect(t,pose_delta_accumulate(&sum,delta,.5) && pose_delta_accumulate(&sum,delta,-1) && pose_accumulated_apply(&half,sum),"below 0 is 0")
    testing.expect(t,linalg.length(half.scale-math.Vec3{1.5,1.5,1.5})<1e-6 && abs(math.quat_angle(half.rotation,1)-.5)<1e-4)
}

@(test)
additive_poses_of_a_bone_give_the_same_pose_in_any_order :: proc(t:^testing.T) {
    poses:=[3]math.Transform{
        {{0,1,0},math.quat_axis_angle({1,0,0},.6),{1.2,1,1}},
        {{.5,0,0},math.quat_axis_angle({0,1,0},.9),{1,1,.5}},
        {{0,0,-1},-math.quat_axis_angle({0,0,1},.4),{1,1,1}}, // the other side of its rotation
    }
    weights:=[3]f32{1,.5,.75}
    rest:=math.Transform{{0,.1,0},math.quat_axis_angle({0,0,1},.2),{1,1,1}}
    apply :: proc(poses:[3]math.Transform,weights:[3]f32,order:[3]int,rest:math.Transform) -> (math.Transform,bool) {
        sum:Pose_Accumulator
        for i in order {if !pose_delta_accumulate(&sum,poses[i],weights[i]) {return {},false}}
        local:=rest
        applied:=pose_accumulated_apply(&local,sum)
        return local,applied
    }
    first,ok:=apply(poses,weights,{0,1,2},rest)
    testing.expect(t,ok && math.quat_angle(first.rotation,rest.rotation)>.5,"the poses move the bone")
    for order in ([5][3]int{{0,2,1},{1,0,2},{1,2,0},{2,0,1},{2,1,0}}) {
        other,applied:=apply(poses,weights,order,rest)
        testing.expect(t,applied && linalg.length(other.position-first.position)<1e-6 && linalg.length(other.scale-first.scale)<1e-6 && math.quat_angle(other.rotation,first.rotation)<1e-5)
    }
    // One pose alone turns by the slerp from none to it, before the rotation of the bone.
    alone,_:=apply({poses[0],math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY},{.5,0,0},{0,1,2},rest)
    testing.expect(t,math.quat_angle(alone.rotation,math.quat_slerp(1,poses[0].rotation,.5)*rest.rotation)<1e-5 && linalg.length(alone.scale-math.Vec3{1.1,1,1})<1e-6)
    // Full poses go first whatever the order they were added in.
    sum:Pose_Accumulator
    testing.expect(t,pose_delta_accumulate(&sum,{{0,0,1},1,{1,1,1}},1) && pose_accumulate(&sum,{{3,0,0},1,{1,1,1}},1))
    local:=rest
    testing.expect(t,pose_accumulated_apply(&local,sum) && linalg.length(local.position-math.Vec3{3,0,1})<1e-6)
}

@(test)
full_poses_blend_by_their_weights_normalized_past_one_and_refuse_hostile_inputs :: proc(t:^testing.T) {
    a:=math.Transform{{1,0,0},math.quat_axis_angle({0,1,0},.4),{2,2,2}}
    b:=math.Transform{{0,1,0},-math.quat_axis_angle({0,1,0},.8),{1,1,1}} // the other side of its rotation
    sum:Pose_Accumulator
    testing.expect(t,pose_accumulate(&sum,a,1) && pose_accumulate(&sum,b,1))
    local:=math.TRANSFORM_IDENTITY
    testing.expect(t,pose_accumulated_apply(&local,sum))
    testing.expect(t,linalg.length(local.position-math.Vec3{.5,.5,0})<1e-5 && linalg.length(local.scale-math.Vec3{1.5,1.5,1.5})<1e-5,"past 1 only the poses count")
    testing.expect(t,abs(math.quat_angle(local.rotation,math.quat_axis_angle({0,1,0},.6)))<1e-3,"rotations of either side average")
    sum={}
    testing.expect(t,pose_accumulate(&sum,a,.25))
    local=math.TRANSFORM_IDENTITY
    testing.expect(t,pose_accumulated_apply(&local,sum) && linalg.length(local.position-math.Vec3{.25,0,0})<1e-5 && abs(math.quat_angle(local.rotation,1)-.1)<1e-3,"below 1 the pose blends over the bone")
    nan:=f32(0);nan/=nan
    held:=sum
    testing.expect(t,!pose_accumulate(&sum,a,nan) && sum==held)
    testing.expect(t,!pose_accumulate(nil,a,1))
    bad:=a;bad.rotation={}
    testing.expect(t,!pose_accumulate(&sum,bad,1) && sum==held)
    testing.expect(t,pose_accumulate(&sum,a,0) && sum==held,"a weight of zero adds nothing")
    testing.expect(t,!pose_accumulated_apply(&local,{}),"nothing summed")
    testing.expect(t,!pose_accumulated_apply(nil,held))
}
