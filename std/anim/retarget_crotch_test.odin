package mirai_anim

import cmath "core:math"
import "core:testing"
import "core:math/linalg"
import math "mirai:std/math"

// A body standing on the floor: a root, the pelvis, and two legs of hip, knee, foot and toe,
// facing -Z, its toes on the floor.
@(private="file")
Test_Body :: struct {
    parents:[10]i32,
    names:[10]u64,
    rest:[10]math.Transform,
    body:Body_Map,
}

@(private="file")
test_body :: proc(pelvis,hip,drop,thigh,shin,ankle,toe:f32) -> (b:Test_Body) {
    b.parents={-1,0,1,2,3,4,1,6,7,8}
    for &name,i in b.names {name=u64(i+1)}
    at :: proc(p:math.Vec3) -> math.Transform {return {p,1,{1,1,1}}}
    b.rest={at({}),at({0,pelvis,0}),at({hip,-drop,0}),at({0,-thigh,0}),at({0,-shin,0}),at({0,-ankle,-toe}),at({-hip,-drop,0}),at({0,-thigh,0}),at({0,-shin,0}),at({0,-ankle,-toe})}
    b.body=body_map_empty()
    b.body.up={0,1,0}
    parts:=[9]Body_Part{.Pelvis,.Hip_L,.Knee_L,.Foot_L,.Toe_L,.Hip_R,.Knee_R,.Foot_R,.Toe_R}
    for part,i in parts {b.body.bones[part]=i32(i+1);b.body.confidence[part]=1}
    return
}

@(private="file")
test_skeleton :: proc(b:^Test_Body) -> Skeleton {return {b.parents[:],b.names[:],b.rest[:]}}

@(test)
retarget_crotch_keeps_the_hips_of_a_long_bodied_target_off_the_floor_in_a_crouch_and_its_feet_in_place :: proc(t:^testing.T) {
    // Half as tall, with its hips low: the bones scaled by their own lengths take its crotch
    // through the floor when the source crouches.
    source_body:=test_body(1,.1,.05,.45,.42,.08,.12)
    target_body:=test_body(.5,.05,.2,.15,.12,.03,.06)
    source,target:=test_skeleton(&source_body),test_skeleton(&target_body)
    mapping:=[10]i32{0,1,2,3,4,5,6,7,8,9}
    profile:[10]Retarget_Bone
    source_world,target_world,target_local,rest:[10]math.Transform
    testing.expect(t,retarget_prepare(source,target,mapping[:],source_world[:],target_world[:],profile[:]))
    crotch,error:=retarget_crotch_prepare(source,target,source_body.body,target_body.body,source_world[:],target_world[:])
    if !testing.expect_value(t,error,Retarget_Error.None) {return}
    testing.expect(t,abs(crotch.scale-.3/.95)<1e-5)
    testing.expect(t,pose_world(source.parents,source.rest,rest[:]))
    for drop in ([3]f32{-.1,.2,.5}) {
        // The pelvis goes down by drop, the knees bending to keep the feet where they stand.
        source_local:=source_body.rest
        source_local[1].position.y-=drop
        world:[10]math.Transform
        testing.expect(t,pose_world(source.parents,source_local[:],world[:]))
        for leg in 0..<2 {
            hip,knee,foot:=2+4*leg,3+4*leg,4+4*leg
            testing.expect(t,skeleton_ik(source,source_local[:],world[:],hip,knee,foot,rest[foot].position,rest[foot].position+{0,.5,-1}))
        }
        testing.expect(t,retarget_pose(source,target,profile[:],source_local[:],source_world[:],target_world[:],target_local[:]))
        feet:=[2]math.Vec3{target_world[4].position,target_world[8].position}
        hips:=target_world[2].position.y
        testing.expect(t,retarget_crotch_pose(target,crotch,source_world[:],target_local[:],target_world[:]))
        share:=(source_world[2].position.y)/.95
        wanted:=max(.3*share,hips) if drop>0 else hips
        testing.expectf(t,abs(target_world[2].position.y-wanted)<1e-4,"drop %v: the hips stand at %v, %v asked",drop,target_world[2].position.y,wanted)
        if drop>.4 {testing.expect(t,hips<.3*share-.01)}
        for foot,i in ([2]int{4,8}) {testing.expect(t,linalg.length(target_world[foot].position-feet[i])<1e-4)}
    }
}

@(test)
retarget_crotch_rejects_hips_on_the_floor_and_values_that_are_not_finite :: proc(t:^testing.T) {
    source_body:=test_body(1,.1,.05,.45,.42,.08,.12)
    target_body:=test_body(.5,.05,.2,.15,.12,.03,.06)
    source,target:=test_skeleton(&source_body),test_skeleton(&target_body)
    source_world,target_world,local:[10]math.Transform
    crotch,error:=retarget_crotch_prepare(source,target,source_body.body,target_body.body,source_world[:],target_world[:])
    testing.expect_value(t,error,Retarget_Error.None)
    flat:=source_body
    for i in 3..<10 {flat.rest[i].position={}}
    flat.rest[2].position={.1,0,0};flat.rest[6].position={-.1,0,0}
    _,error=retarget_crotch_prepare(test_skeleton(&flat),target,flat.body,target_body.body,source_world[:],target_world[:])
    testing.expect_value(t,error,Retarget_Error.Hips_Height)
    broken:=source_body;broken.rest[3].position.y=cmath.nan_f32()
    _,error=retarget_crotch_prepare(test_skeleton(&broken),target,broken.body,target_body.body,source_world[:],target_world[:])
    testing.expect_value(t,error,Retarget_Error.Invalid)
    _,error=retarget_crotch_prepare(source,target,source_body.body,target_body.body,source_world[:9],target_world[:])
    testing.expect_value(t,error,Retarget_Error.Invalid)
    // Without a body there is nothing to keep, and the pose stays.
    none,_:=retarget_crotch_prepare(source,target,body_map_empty(),target_body.body,source_world[:],target_world[:])
    testing.expect_value(t,none,RETARGET_CROTCH_NONE)
    testing.expect(t,pose_world(source.parents,source.rest,source_world[:]))
    source_world[1].position.y-=.5
    hostile:=[?]Retarget_Crotch{crotch,crotch,crotch,crotch,crotch}
    hostile[0].source_pelvis=99
    hostile[1].scale=cmath.nan_f32()
    hostile[2].legs[0][1]=-7
    hostile[3].target_up={}
    hostile[4].legs[1]={8,7,6}
    for value in hostile {
        local=target_body.rest
        testing.expect(t,!retarget_crotch_pose(target,value,source_world[:],local[:],target_world[:]))
    }
    local=target_body.rest
    source_world[4].position.x=cmath.inf_f32(1)
    testing.expect(t,!retarget_crotch_pose(target,crotch,source_world[:],local[:],target_world[:]))
}
