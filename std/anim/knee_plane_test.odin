package mirai_anim

import "base:runtime"
import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

@(test)
two_bone_pose_poles_keep_raised_targets_on_the_source_bending_side_without_allocations :: proc(t:^testing.T) {
    source:=[3]math.Transform{
        {{0,1,0},1,{1,1,1}},{{.05,.5,0},1,{1,1,1}},{{0,0,0},1,{1,1,1}},
    }
    poses:[9]IK_Result
    valid:=true
    previous_context:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    for &pose,i in poses {
        target:=math.Vec3{.04+.01*f32(i),.2,0}
        pole,ok:=two_bone_pole_from_pose(source[0],source[1],source[2],target)
        valid &&=ok
        pose,ok=two_bone_ik(source[0],source[1],source[2],target,pole)
        valid &&=ok && pose.reached
    }
    context=previous_context
    testing.expect(t,valid)
    for pose,i in poses {
        testing.expect(t,pose.joint.position.x>.25)
        testing.expect(t,linalg.length(pose.end.position-math.Vec3{.04+.01*f32(i),.2,0})<1e-5)
        if i>0 {testing.expect(t,linalg.length(pose.joint.position-poses[i-1].joint.position)<.02)}
    }
}

@(test)
two_bone_pose_poles_follow_rotated_actors_and_keep_antiparallel_and_straight_sources_finite :: proc(t:^testing.T) {
    source:=[3]math.Transform{
        {{0,1,0},1,{1,1,1}},{{.05,.5,0},1,{1,1,1}},{{0,0,0},1,{1,1,1}},
    }
    for shape in 0..<3 {
        pose:=source
        if shape==1 {pose[1].position.x=0}
        if shape==2 {pose[2]=pose[0]}
        for angle in ([4]f32{0,.7,math.PI*.5,math.PI}) {
            for target in ([3]math.Vec3{{.1,.2,0},{0,1.8,0},pose[0].position}) {
                reference,valid:=two_bone_pole_from_pose(pose[0],pose[1],pose[2],target)
                testing.expect(t,valid)
                actor:=math.Transform{{4,2,-3},math.quat_from_euler({.2,angle,-.4}),{1,1,1}}
                moved:[3]math.Transform
                for &bone,i in moved {bone=math.transform_compose(actor,pose[i])}
                world_target:=math.transform_point(actor,target)
                pole,ok:=two_bone_pole_from_pose(moved[0],moved[1],moved[2],world_target)
                testing.expect(t,ok)
                testing.expect(t,linalg.length(pole-math.transform_point(actor,reference))<1e-4)
                solved,solved_ok:=two_bone_ik(moved[0],moved[1],moved[2],world_target,pole)
                testing.expect(t,solved_ok)
                if linalg.length(target-pose[0].position)>1e-6 {testing.expect(t,solved.reached)}
                testing.expect(t,linalg.length(solved.end.position-world_target)<1e-5)
                testing.expect(t,abs(linalg.length(solved.joint.position-solved.root.position)-linalg.length(moved[1].position-moved[0].position))<1e-5)
                testing.expect(t,abs(linalg.length(solved.end.position-solved.joint.position)-linalg.length(moved[2].position-moved[1].position))<1e-5)
                testing.expect(t,anim_transform_valid(solved.root) && anim_transform_valid(solved.joint) && anim_transform_valid(solved.end))
            }
        }
    }
}

@(test)
two_bone_pose_poles_reject_invalid_poses_segments_and_targets :: proc(t:^testing.T) {
    source:=[3]math.Transform{
        {{0,1,0},1,{1,1,1}},{{.05,.5,0},1,{1,1,1}},{{0,0,0},1,{1,1,1}},
    }
    for value in ([3]f32{cmath.nan_f32(),cmath.inf_f32(1),3e38}) {
        _,ok:=two_bone_pole_from_pose(source[0],source[1],source[2],{value,value,value})
        testing.expect(t,!ok)
    }
    invalid:=source[1];invalid.position=source[0].position
    _,zero_segment:=two_bone_pole_from_pose(source[0],invalid,source[2],{})
    testing.expect(t,!zero_segment)
    invalid=source[1];invalid.rotation={}
    _,zero_rotation:=two_bone_pole_from_pose(source[0],invalid,source[2],{})
    testing.expect(t,!zero_rotation)
}
