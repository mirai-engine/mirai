package mirai_anim

import "core:testing"
import "core:math/linalg"
import math "mirai:std/math"

@(test)
chain_ik_preserves_lengths_obeys_pole_and_clamps_unreachable_targets :: proc(t:^testing.T) {
    points:=[4]math.Vec3{{},{1,0,0},{2,0,0},{3,0,0}}
    lengths:=[3]f32{1,1,1}
    out:[4]math.Vec3
    settings:=CHAIN_IK_DEFAULT
    settings.target={1.5,0,0};settings.pole={0,2,0};settings.use_pole=true;settings.iterations=64
    result,ok:=chain_ik(points[:],lengths[:],nil,settings,out[:])
    testing.expect(t,ok && result.reached && out[0]==points[0] && out[1].y+out[2].y>0)
    for i in 1..<len(out) {testing.expect(t,abs(linalg.length(out[i]-out[i-1])-1)<0.0001)}
    settings.target={5,0,0}
    result,ok=chain_ik(points[:],lengths[:],nil,settings,out[:])
    testing.expect(t,ok && !result.reached && skel_near(out[3],{3,0,0}) && result.iterations==0)
    settings.target={};settings.pole={0,0,2}
    result,ok=chain_ik(points[:],lengths[:],nil,settings,out[:])
    testing.expect(t,ok && result.reached)
    for point in out {testing.expect(t,anim_vec3_valid(point))}
}

@(test)
chain_ik_respects_joint_bend_limits_and_reports_residual :: proc(t:^testing.T) {
    points:=[3]math.Vec3{{},{1,0,0},{2,0,0}}
    lengths:=[2]f32{1,1}
    limits:=[1]Chain_Limit{{0,0.4}}
    out:[3]math.Vec3
    settings:=CHAIN_IK_DEFAULT;settings.target={1,1,0};settings.use_pole=true;settings.pole={0,0,2}
    result,ok:=chain_ik(points[:],lengths[:],limits[:],settings,out[:])
    a:=linalg.normalize0(out[1]-out[0]);b:=linalg.normalize0(out[2]-out[1])
    testing.expect(t,ok && !result.reached && result.error>0.1 && linalg.dot(a,b)>=0.9210)
    for i in 1..<3 {testing.expect(t,abs(linalg.length(out[i]-out[i-1])-1)<0.0001)}
    limits[0]={1,0.4}
    _,ok=chain_ik(points[:],lengths[:],limits[:],settings,out[:])
    testing.expect(t,!ok)
    _,ok=chain_ik(nil,nil,nil,{},nil)
    testing.expect(t,!ok)
    lengths[0]=0
    _,ok=chain_ik(points[:],lengths[:],nil,settings,out[:])
    testing.expect(t,!ok)
}

@(test)
skeleton_chain_ik_operates_without_clips_and_keeps_local_lengths :: proc(t:^testing.T) {
    parents:=[5]i32{-1,0,1,2,0};names:=[5]u64{1,2,3,4,5}
    rest:=[5]math.Transform{math.TRANSFORM_IDENTITY,{{1,0,0},1,{1,1,1}},{{1,0,0},1,{1,1,1}},{{1,0,0},1,{1,1,1}},{{0,1,0},1,{1,1,1}}}
    skeleton:=Skeleton{parents[:],names[:],rest[:]}
    local:=rest;world:[5]math.Transform
    points,solved:[4]math.Vec3;lengths:[3]f32;bones:=[4]i32{0,1,2,3}
    settings:=CHAIN_IK_DEFAULT;settings.target={1.5,1,0};settings.pole={0,0,2};settings.use_pole=true
    result,ok:=skeleton_chain_ik(skeleton,local[:],world[:],bones[:],nil,settings,points[:],solved[:],lengths[:])
    testing.expect(t,ok && result.reached)
    for bone in bones {testing.expect_value(t,local[bone].position,rest[bone].position)}
    testing.expect(t,local[4]==rest[4] && world[4]==math.transform_compose(world[0],local[4]))
    local=rest
    _,ok=skeleton_chain_ik(skeleton,local[:],world[:],bones[:],nil,settings,points[:],solved[:],lengths[:],0)
    testing.expect(t,ok && local==rest)
    bones[1]=4
    _,ok=skeleton_chain_ik(skeleton,local[:],world[:],bones[:],nil,settings,points[:],solved[:],lengths[:])
    testing.expect(t,!ok)
}
