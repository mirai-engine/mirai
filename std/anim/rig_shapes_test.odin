package mirai_anim

import "base:runtime"
import "core:testing"
import "core:math/linalg"
import math "mirai:std/math"

@(test)
aim_up_keeps_secondary_axis_and_applies_influence_once :: proc(t:^testing.T) {
    tilted:=math.quat_axis_angle({0,0,1},1)
    solved,ok:=aim_at(tilted,{0,0,-1},{0,0,-1},{0,1,0},{0,1,0},math.PI,.5)
    testing.expect(t,ok && abs(math.quat_angle(solved,1)-.5)<1e-4)
    solved,ok=aim_at(1,{0,0,-1},{1,0,0},{0,1,0},{0,1,0},math.PI)
    testing.expect(t,ok && linalg.length(math.quat_forward(solved)-math.Vec3{1,0,0})<1e-4 && linalg.length(math.quat_rotate(solved,{0,1,0})-math.Vec3{0,1,0})<1e-4)
    _,ok=aim_at(1,{0,0,-1},{0,1,0},{0,1,0},{0,1,0},math.PI);testing.expect(t,ok)
    _,ok=aim_at(1,{0,0,-1},{1,0,0},{0,0,1},{0,1,0},math.PI);testing.expect(t,!ok)
}

@(test)
soft_reach_and_stretch_keep_a_bounded_continuous_reach :: proc(t:^testing.T) {
    at,scale,ok:=chain_reach({},{0,3,0},2,{max_stretch=.25})
    testing.expect(t,ok && abs(at.y-2.25)<1e-5 && abs(scale-1.125)<1e-5)
    previous:f32
    for i in 0..<102 {
        target:=math.Vec3{0,1.49+f32(i)*.01,0}
        at,scale,ok=chain_reach({},target,2,{soft_distance=.5})
        testing.expect(t,ok && scale==1 && at.y>=previous && at.y<=2 && at.y<=target.y+1e-6)
        previous=at.y
    }
    _,_,ok=chain_reach({},{},2,{soft_distance=3});testing.expect(t,!ok)
    parents:=[3]i32{-1,0,1};names:=[3]u64{1,2,3}
    rest:=[3]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}},{{0,1,0},1,{1,1,1}}}
    skeleton:=Skeleton{parents[:],names[:],rest[:]};local:=rest;world:[3]math.Transform
    bones:=[3]i32{0,1,2};points,solved:[3]math.Vec3;lengths:[2]f32
    result,valid:=skeleton_chain_ik(skeleton,local[:],world[:],bones[:],nil,{target={0,3,0},iterations=24,tolerance=.001},points[:],solved[:],lengths[:],reach={max_stretch=.25})
    testing.expect(t,valid && !result.reached && abs(result.error-.75)<1e-4)
    testing.expect(t,abs(local[1].position.y-1.125)<1e-5 && abs(local[2].position.y-1.125)<1e-5)
}

@(test)
spline_ik_follows_a_cubic_preserves_lengths_and_extends_a_short_curve :: proc(t:^testing.T) {
    settings:=Spline_Chain{controls={{0,0,0},{0,1,0},{1,1,0},{1,0,0}},up={0,0,1}}
    lengths:=[5]f32{.4,.4,.4,.4,.4};points:[6]math.Vec3
    testing.expect(t,spline_chain(settings,lengths[:],points[:]))
    for length,i in lengths {testing.expect(t,abs(linalg.length(points[i+1]-points[i])-length)<1e-4)}
    testing.expect(t,points[1].y>0 && points[3].x>.4)
    settings.controls={{0,0,0},{0,.1,0},{0,.2,0},{0,.3,0}}
    testing.expect(t,spline_chain(settings,lengths[:],points[:]) && abs(points[5].y-2)<1e-4)
    settings.controls={};testing.expect(t,!spline_chain(settings,lengths[:],points[:]))
    parents:=[3]i32{-1,0,1};names:=[3]u64{1,2,3}
    rest:=[3]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}},{{0,1,0},1,{1,1,1}}}
    skeleton:=Skeleton{parents[:],names[:],rest[:]};local:=rest;world:[3]math.Transform;bones:=[3]i32{0,1,2}
    settings.controls={{2,0,0},{3,0,0},{4,0,0},{5,0,0}}
    testing.expect(t,skeleton_spline_ik(skeleton,local[:],world[:],bones[:],settings,points[:3],lengths[:2]))
    testing.expect(t,linalg.length(world[0].position-math.Vec3{2,0,0})<1e-5 && linalg.length(world[2].position-math.Vec3{4,0,0})<1e-4)
    branch_parents:=[5]i32{-1,0,1,1,0};branch_names:=[5]u64{1,2,3,4,5}
    branch_rest:=[5]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},math.quat_axis_angle({0,0,1},.3),{1,1,1}},{{0,1,0},1,{1,1,1}},{{.4,0,0},1,{1,1,1}},{{-.4,0,0},1,{1,1,1}}}
    branch_skeleton:=Skeleton{branch_parents[:],branch_names[:],branch_rest[:]};branch_local:=branch_rest;branch_world:[5]math.Transform
    root:=math.Transform{{1,2,3},math.quat_axis_angle({0,1,0},.7),{1.2,.9,.8}}
    settings.controls={{1,2,3},{2,2,3},{2,3,3},{3,4,3}}
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for weight in ([3]f32{0,.5,1}) {
        branch_local=branch_rest
        stable &&=skeleton_spline_ik(branch_skeleton,branch_local[:],branch_world[:],bones[:],settings,points[:3],lengths[:2],weight,root)
        stable &&=branch_local[3]==branch_rest[3] && branch_local[4]==branch_rest[4]
        stable &&=branch_world[3]==math.transform_compose(branch_world[1],branch_rest[3]) && branch_world[4]==math.transform_compose(branch_world[0],branch_rest[4])
        if weight==0 {stable &&=branch_local==branch_rest}
        if weight==1 {for bone,i in bones {stable &&=linalg.length(branch_world[bone].position-points[i])<1e-4}}
    }
    context=saved;testing.expect(t,stable)
}

@(test)
pose_samples_are_exact_sign_invariant_and_convex_without_allocations :: proc(t:^testing.T) {
    samples:=[3]math.Quat{1,math.quat_axis_angle({0,0,1},math.PI*.5),math.quat_axis_angle({1,0,0},math.PI*.5)}
    weights:[3]f32
    testing.expect(t,pose_sample_weights(-samples[1],samples[:],weights[:]) && weights==[3]f32{0,1,0})
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for i in 0..<100 {
        stable &&=pose_sample_weights(math.quat_axis_angle({0,0,1},f32(i)*.03),samples[:],weights[:])
        sum:f32;for weight in weights {stable &&=weight>=0 && weight<=1;sum+=weight};stable &&=abs(sum-1)<1e-5
    }
    context=saved;testing.expect(t,stable)
    samples[2]=-samples[1];testing.expect(t,!pose_sample_weights(1,samples[:],weights[:]))
    testing.expect(t,!pose_sample_weights(0,samples[:],weights[:]) && !pose_sample_weights(1,nil,nil))
}
