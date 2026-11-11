package mirai_anim

import "base:runtime"
import "core:fmt"
import "core:testing"
import "core:math/linalg"
import math "mirai:std/math"

@(test)
root_warp_reaches_rotated_scaled_targets_and_preserves_disabled_axes :: proc(t:^testing.T) {
    actor:=math.Transform{{3,1,5},math.quat_axis_angle({0,1,0},.8),{2,1,3}}
    delta:=math.TRANSFORM_IDENTITY;delta.position={1,.5,0}
    target:=math.transform_compose(actor,{position={3,2,1},rotation=math.quat_axis_angle({0,1,0},.4),scale={1,1,1}})
    out,ok:=root_motion_warp(actor,delta,delta,target,1)
    endpoint:=math.transform_compose(actor,out)
    testing.expect(t,ok && linalg.length(endpoint.position-target.position)<1e-5 && math.quat_angle(endpoint.rotation,target.rotation)<1e-5)
    settings:=ROOT_WARP_DEFAULT;settings.axes[1]=false
    out,ok=root_motion_warp(actor,delta,delta,target,1,settings)
    testing.expect(t,ok && out.position.y==delta.position.y)
    out,ok=root_motion_warp(actor,delta,delta,target,0);testing.expect(t,ok && out==delta)
    // The correction goes with the motion of the clip, not with the time: a tick that stands still
    // moves nothing, and one that covers half of what is left carries half of the correction.
    stride:=math.Transform{position={0,0,2},rotation=1,scale={1,1,1}}
    goal:=math.transform_compose(actor,{position={0,0,3},rotation=1,scale={1,1,1}})
    still:=math.TRANSFORM_IDENTITY
    out,ok=root_motion_warp(actor,still,stride,goal,.5,{translation=true,axes={true,true,true},weight=1})
    testing.expectf(t,ok && linalg.length(out.position)<1e-6,"a still tick stays still, not %v",out.position)
    half:=math.Transform{position={0,0,1},rotation=1,scale={1,1,1}}
    out,ok=root_motion_warp(actor,half,stride,goal,.1,{translation=true,axes={true,true,true},weight=1})
    testing.expectf(t,ok && linalg.length(out.position-math.Vec3{0,0,1.5})<1e-5,"half of the motion carries half of the correction, not %v",out.position)
    actor.scale.y=0;_,ok=root_motion_warp(actor,delta,delta,target,1);testing.expect(t,!ok)
}


@(test)
pose_warp_compensates_spine_preserves_limb_lengths_and_runs_without_allocations :: proc(t:^testing.T) {
    parents:=[5]i32{-1,0,1,2,0};names:=[5]u64{1,2,3,4,5}
    rest:=[5]math.Transform{math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY}
    rest[0].position={0,2,0};rest[2].position={0,-.8,.3};rest[3].position={0,-.7,.4};rest[4].position={0,1,0}
    skeleton:=Skeleton{parents[:],names[:],rest[:]};local:=rest;world:[5]math.Transform
    spine:=[1]i32{4};legs:=[1]Pose_Warp_Limb{{hip=1,knee=2,foot=3}}
    settings:=Pose_Warp{pelvis=0,spine=spine[:],legs=legs[:],up={0,1,0},direction={0,0,1},angle=.5,stride=1.2,weight=1}
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    ok:=pose_warp(skeleton,local[:],world[:],settings)
    final:=local;settings.weight=0;ok &&=pose_warp(skeleton,local[:],world[:],settings)
    angle,angle_ok:=orientation_warp_angle({0,0,1},{1,0,0},{0,1,0},1)
    scale,scale_ok:=stride_warp_scale(2,10,.5,2)
    context=saved
    testing.expect(t,ok && local==final && angle_ok && angle==1 && scale_ok && scale==2)
    testing.expect(t,math.quat_angle(world[4].rotation,1)<1e-5)
    testing.expect(t,math.quat_angle(world[3].rotation,math.quat_axis_angle({0,1,0},.5))<1e-5)
    testing.expect(t,abs(linalg.length(world[2].position-world[1].position)-linalg.length(rest[2].position))<1e-5)
    testing.expect(t,abs(linalg.length(world[3].position-world[2].position)-linalg.length(rest[3].position))<1e-5)
    legs[0].knee=4;testing.expect(t,!pose_warp(skeleton,local[:],world[:],settings))
}

@(test)
pose_warp_preserves_identity_and_rotates_the_source_knee_planes_without_ik :: proc(t:^testing.T) {
    parents:=[8]i32{-1,0,1,2,3,1,5,6};names:=[8]u64{1,2,3,4,5,6,7,8}
    rest:[8]math.Transform
    for &bone in rest {bone=math.TRANSFORM_IDENTITY}
    rest[0]={{4,.2,-3},math.quat_axis_angle({0,1,0},.4),{1,1,1}}
    rest[1].position={0,1.7,0}
    rest[2].position={-.2,0,.18};rest[3].position={-.12,-.75,.3};rest[4].position={.08,-.75,-.4}
    rest[5].position={.2,0,.18};rest[6].position={.14,-.75,.3};rest[7].position={-.08,-.75,-.4}
    skeleton:=Skeleton{parents[:],names[:],rest[:]}
    legs:=[2]Pose_Warp_Limb{{hip=2,knee=3,foot=4},{hip=5,knee=6,foot=7}}
    settings:=Pose_Warp{pelvis=1,legs=legs[:],up={0,1,0},direction={0,0,1},stride=1,weight=1}
    local:=rest;source:[8]math.Transform;world:[8]math.Transform
    testing.expect(t,pose_world(parents[:],rest[:],source[:]))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    valid:=pose_warp(skeleton,local[:],world[:],settings)
    identity:=local==rest && world==source
    rotated:=true
    for angle in ([2]f32{1.1,-.9}) {
        local=rest;settings.angle=angle
        valid &&=pose_warp(skeleton,local[:],world[:],settings)
        turn:=math.quat_axis_angle(settings.up,angle)
        for leg in legs {for bone in ([3]i32{leg.hip,leg.knee,leg.foot}) {
            position:=source[1].position+math.quat_rotate(turn,source[bone].position-source[1].position)
            rotated &&=linalg.length(world[bone].position-position)<1e-5
            rotated &&=math.quat_angle(world[bone].rotation,turn*source[bone].rotation)<1e-5
            rotated &&=local[bone]==rest[bone]
        }}
    }
    context=saved
    testing.expect(t,valid && identity && rotated)
}

@(test)
pose_stride_warp_scales_each_foot_from_its_hip_and_preserves_the_source_knee_side :: proc(t:^testing.T) {
    parents:=[8]i32{-1,0,1,2,3,1,5,6};names:=[8]u64{1,2,3,4,5,6,7,8}
    rest:[8]math.Transform
    for &bone in rest {bone=math.TRANSFORM_IDENTITY}
    rest[0]={{-3,.2,4},math.quat_axis_angle({0,1,0},.4),{1,1,1}}
    rest[1].position={0,1.7,0}
    rest[2].position={-.2,0,.18};rest[3].position={-.12,-.75,.3};rest[4].position={.08,-.75,-.4}
    rest[5].position={.2,0,.18};rest[6].position={.14,-.75,.3};rest[7].position={-.08,-.75,-.4}
    skeleton:=Skeleton{parents[:],names[:],rest[:]}
    legs:=[2]Pose_Warp_Limb{{hip=2,knee=3,foot=4},{hip=5,knee=6,foot=7}}
    direction:=linalg.normalize0(math.Vec3{.7,0,1})
    settings:=Pose_Warp{pelvis=1,legs=legs[:],up={0,1,0},direction=direction,angle=.65,stride=.1,weight=1}
    oriented:=rest;oriented[1].rotation=math.quat_axis_angle(settings.up,settings.angle)
    source:[8]math.Transform;world:[8]math.Transform;local:=rest
    testing.expect(t,pose_world(parents[:],oriented[:],source[:]))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    valid:=pose_warp(skeleton,local[:],world[:],settings)
    contact,plane,lengths:=true,true,true
    for leg in legs {
        hip,knee,foot:=int(leg.hip),int(leg.knee),int(leg.foot)
        target:=source[foot].position+direction*linalg.dot(source[foot].position-source[hip].position,direction)*(settings.stride-1)
        contact &&=linalg.length(world[foot].position-target)<1e-5
        axis:=linalg.normalize0(target-source[hip].position)
        source_axis:=linalg.normalize0(source[foot].position-source[hip].position)
        bend:=source[knee].position-source[hip].position;bend-=source_axis*linalg.dot(bend,source_axis)
        crossed:=linalg.cross(source_axis,axis)
        bend+=linalg.cross(crossed,bend)+linalg.cross(crossed,linalg.cross(crossed,bend))/(1+linalg.dot(source_axis,axis))
        solved:=world[knee].position-world[hip].position;solved-=axis*linalg.dot(solved,axis)
        plane &&=linalg.dot(linalg.normalize0(bend),linalg.normalize0(solved))>0.9999
        lengths &&=abs(linalg.length(world[knee].position-world[hip].position)-linalg.length(source[knee].position-source[hip].position))<1e-5
        lengths &&=abs(linalg.length(world[foot].position-world[knee].position)-linalg.length(source[foot].position-source[knee].position))<1e-5
    }
    context=saved
    testing.expect(t,valid,"warp accepted")
    testing.expect(t,contact,"hip targets reached")
    testing.expect(t,plane,"source knee side preserved")
    testing.expect(t,lengths,"segment lengths preserved")
}

// A long stride of legs nearly straight in the clip lowers the pelvis so that every foot reaches
// where the stride puts it, with no leg more extended than the clip has it.
@(test)
pose_stride_warp_lowers_the_pelvis_so_every_foot_reaches_its_target :: proc(t:^testing.T) {
    parents:=[7]i32{-1,0,1,2,0,4,5};names:=[7]u64{1,2,3,4,5,6,7}
    rest:[7]math.Transform
    for &bone in rest {bone=math.TRANSFORM_IDENTITY}
    rest[0].position={0,1,0}
    rest[1].position={.1,0,0};rest[2].position={0,-.42,.12};rest[3].position={0,-.42,.08}
    rest[4].position={-.1,0,0};rest[5].position={0,-.42,-.05};rest[6].position={0,-.42,-.15}
    skeleton:=Skeleton{parents[:],names[:],rest[:]}
    legs:=[2]Pose_Warp_Limb{{hip=1,knee=2,foot=3},{hip=4,knee=5,foot=6}}
    source:[7]math.Transform
    testing.expect(t,pose_world(parents[:],rest[:],source[:]))
    Case :: struct {stride:f32,lowered:bool}
    for c in ([]Case{{stride=2,lowered=true},{stride=1.5,lowered=true},{stride=.6,lowered=false}}) {
        local:=rest;world:[7]math.Transform
        settings:=Pose_Warp{pelvis=0,legs=legs[:],up={0,1,0},direction={0,0,1},stride=c.stride,weight=1}
        valid:=pose_warp(skeleton,local[:],world[:],settings)
        worst,extension:f32
        for leg in legs {
            hip,foot:=source[leg.hip].position,source[leg.foot].position
            target:=foot+math.Vec3{0,0,1}*linalg.dot(foot-hip,math.Vec3{0,0,1})*(c.stride-1)
            worst=max(worst,linalg.length(world[leg.foot].position-target))
            extension=max(extension,linalg.length(world[leg.foot].position-world[leg.hip].position)-linalg.length(foot-hip))
        }
        lowered:=world[0].position.y<source[0].position.y-1e-3
        testing.expectf(t,valid && worst<1e-3 && extension<1e-4 && lowered==c.lowered,"stride %.1f: a foot misses by %.4f m, a leg extends %.4f m more, the pelvis at %.3f m",c.stride,worst,extension,world[0].position.y)
    }
    nan:=f32(0h7fc00000)
    local:=rest;world:[7]math.Transform
    testing.expect(t,!pose_warp(skeleton,local[:],world[:],{pelvis=0,legs=legs[:],up={0,1,0},direction={0,0,1},stride=nan,weight=1}),"a NaN stride")
    testing.expect(t,!pose_warp(skeleton,local[:],world[:],{pelvis=0,legs=legs[:],up={0,1,0},direction={nan,0,1},stride=2,weight=1}),"a NaN direction")
}

@(test)
pose_stride_warp_keeps_nearly_straight_knees_on_the_source_side_when_shortening_the_step :: proc(t:^testing.T) {
    parents:=[4]i32{-1,0,1,2};names:=[4]u64{1,2,3,4}
    rest:=[4]math.Transform{math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY}
    rest[0].position={3,1,-2};rest[2].position={-.002,-.5,.02};rest[3].position={.002,-.5,.08}
    legs:=[1]Pose_Warp_Limb{{hip=1,knee=2,foot=3}}
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator
    valid,front:=true,true
    sides,errors:[2]f32
    for angle,i in ([2]f32{1.3,-.9}) {
        rest[0].rotation=math.quat_axis_angle({0,1,0},angle)
        skeleton:=Skeleton{parents[:],names[:],rest[:]};local:=rest;world:[4]math.Transform
        forward:=math.quat_forward(rest[0].rotation)
        valid &&=pose_warp(skeleton,local[:],world[:],{pelvis=0,legs=legs[:],up={0,1,0},direction=forward,stride=.05,weight=1})
        sides[i]=linalg.dot(world[2].position-world[1].position,forward)
        front &&=sides[i]>.02
        target:=world[1].position+math.Vec3{0,-1,0}-forward*.005
        errors[i]=linalg.length(world[3].position-target)
        front &&=errors[i]<1e-5
    }
    context=saved
    testing.expect(t,valid,"warp accepted")
    testing.expect(t,front,fmt.tprintf("near-straight knee sides=%v target errors=%v",sides,errors))
}

@(test)
distance_matching_inverts_increasing_and_decreasing_curves_and_rejects_ambiguous_keys :: proc(t:^testing.T) {
    keys:=[3]Distance_Key{{0,0},{.5,2},{1,3}}
    time,ok:=distance_to_time(keys[:],1);testing.expect(t,ok && time==.25)
    time,ok=distance_to_time(keys[:],4);testing.expect(t,ok && time==1)
    keys[0].distance=3;keys[1].distance=1;keys[2].distance=0
    time,ok=distance_to_time(keys[:],2);testing.expect(t,ok && time==.25)
    keys[1].distance=3;testing.expect(t,!distance_track_validate(keys[:]))
    keys[1].distance=2;keys[1].time=0;testing.expect(t,!distance_track_validate(keys[:]))
    _,ok=distance_to_time(nil,0);testing.expect(t,!ok)
}

@(test)
hostile_warp_and_distance_inputs_return_without_nonfinite_successes :: proc(t:^testing.T) {
    values:=[10]f32{0,1,-1,1e30,-1e30,1e-30,f32(0h7fc00000),f32(0h7f800000),f32(0hff800000),.25}
    for iteration in 0..<#config(ANIM_WARP_HOSTILE_ROUNDS,400) {
        value:=values[iteration%len(values)]
        actor:=math.TRANSFORM_IDENTITY;target:=actor;target.position.x=value
        warped,ok:=root_motion_warp(actor,actor,actor,target,values[(iteration/3)%len(values)])
        if ok {testing.expect(t,anim_transform_valid(warped))}
        angle,angle_ok:=orientation_warp_angle({value,0,1},{1,value,0},{0,1,value},values[(iteration/7)%len(values)])
        if angle_ok {testing.expect(t,anim_finite(angle))}
        scale,scale_ok:=stride_warp_scale(value,values[(iteration/11)%len(values)],.5,2)
        if scale_ok {testing.expect(t,anim_finite(scale) && scale>0)}
        keys:=[2]Distance_Key{{0,value},{1,values[(iteration/13)%len(values)]}}
        time,time_ok:=distance_to_time(keys[:],value);if time_ok {testing.expect(t,anim_finite(time))}
    }
}
