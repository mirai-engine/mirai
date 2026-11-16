package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

Root_Warp :: struct {translation,rotation:bool,axes:[3]bool,weight:f32}
ROOT_WARP_DEFAULT :: Root_Warp{translation=true,rotation=true,axes={true,true,true},weight=1}

// m below which the root motion left in a window counts as none.
ROOT_WARP_STILL :: 1e-3

// The root motion of a tick (delta) bent so that what is left of the window (remaining, from the
// actor) ends at target. The translation is skewed: the linear map that takes remaining to the
// target moves delta, so each tick carries the share of the correction that its motion is of what
// is left on the axes it warps, and a tick in which the clip stands still moves nothing. A window whose clip does not
// move spreads the correction by its share of the time left (fraction). The rotation is spread by
// fraction.
root_motion_warp :: proc "contextless" (actor,delta,remaining,target:math.Transform,fraction:f32,settings:Root_Warp=ROOT_WARP_DEFAULT) -> (out:math.Transform,ok:bool) {
    out=delta
    if !anim_transform_valid(actor) || !anim_transform_valid(delta) || !anim_transform_valid(remaining) || !anim_transform_valid(target) || !anim_finite(fraction) || fraction<0 || fraction>1 || !anim_finite(settings.weight) || settings.weight<0 || settings.weight>1 {return}
    for axis in actor.scale {if abs(axis)<1e-8 {return}}
    alpha:=fraction*settings.weight
    if alpha==0 {return delta,true}
    endpoint:=math.transform_compose(actor,remaining)
    if !anim_transform_valid(endpoint) {return}
    if settings.translation {
        correction:=math.transform_inverse_vector(actor,target.position-endpoint.position)
        moved,left_over:math.Vec3
        for enabled,i in settings.axes {if enabled {moved[i],left_over[i]=delta.position[i],remaining.position[i]}}
        left:=linalg.dot(left_over,left_over)
        share:=alpha
        if left>ROOT_WARP_STILL*ROOT_WARP_STILL {share=linalg.dot(moved,left_over)/left*settings.weight}
        if !anim_finite(share) {return}
        for enabled,i in settings.axes {if enabled {out.position[i]+=correction[i]*share}}
    }
    if settings.rotation {
        correction:=conj(endpoint.rotation)*target.rotation
        out.rotation=linalg.normalize0(delta.rotation*math.quat_slerp(1,correction,alpha))
    }
    return out,anim_transform_valid(out)
}

orientation_warp_angle :: proc "contextless" (source,desired,up:math.Vec3,max_angle:f32) -> (angle:f32,ok:bool) {
    if !anim_vec3_valid(source) || !anim_vec3_valid(desired) || !anim_finite(max_angle) || max_angle<0 {return}
    axis,valid:=anim_unit(up);if !valid {return}
    from,a:=anim_unit(source-axis*linalg.dot(source,axis))
    to,b:=anim_unit(desired-axis*linalg.dot(desired,axis));if !a || !b {return}
    angle=clamp(cmath.atan2(linalg.dot(axis,linalg.cross(from,to)),linalg.dot(from,to)),-max_angle,max_angle)
    return angle,anim_finite(angle)
}

stride_warp_scale :: proc "contextless" (source_speed,desired_speed,minimum,maximum:f32) -> (f32,bool) {
    if !anim_finite(source_speed) || source_speed<0 || !anim_finite(desired_speed) || desired_speed<0 || !anim_finite(minimum) || !anim_finite(maximum) || minimum<=0 || minimum>maximum {return 1,false}
    if source_speed<=1e-6 {return 1,true}
    return f32(clamp(f64(desired_speed)/f64(source_speed),f64(minimum),f64(maximum))),true
}

Pose_Warp_Limb :: struct {hip,knee,foot:i32}
Pose_Warp :: struct {pelvis:i32,spine:[]i32,legs:[]Pose_Warp_Limb,up,direction:math.Vec3,angle,stride,weight:f32}

pose_warp :: proc "contextless" (skeleton:Skeleton,local,world:[]math.Transform,settings:Pose_Warp,root_transform:math.Transform=math.TRANSFORM_IDENTITY) -> bool {
    count:=len(local)
    if !skeleton_validate(skeleton) || len(world)!=count || count!=len(skeleton.rest) || settings.pelvis<0 || int(settings.pelvis)>=count || len(settings.legs)>16 || !anim_finite(settings.angle) || !anim_finite(settings.stride) || settings.stride<=0 || !anim_finite(settings.weight) || settings.weight<0 || settings.weight>1 {return false}
    if inertial_buffers_overlap(local,world) {return false}
    up,up_ok:=anim_unit(settings.up);direction,direction_ok:=anim_unit(settings.direction)
    if !up_ok || !direction_ok {return false}
    for bone,i in settings.spine {
        if bone<0 || int(bone)>=count || bone==settings.pelvis {return false}
        for previous in settings.spine[:i] {if previous==bone {return false}}
    }
    for leg,i in settings.legs {
        if leg.hip<0 || leg.knee<0 || leg.foot<0 || int(leg.hip)>=count || int(leg.knee)>=count || int(leg.foot)>=count || skeleton.parents[leg.knee]!=leg.hip || skeleton.parents[leg.foot]!=leg.knee {return false}
        for previous in settings.legs[:i] {for bone in ([3]i32{leg.hip,leg.knee,leg.foot}) {if bone==previous.hip || bone==previous.knee || bone==previous.foot {return false}}}
    }
    if !pose_world(skeleton.parents,local,world,root_transform) {return false}
    if settings.weight==0 {return true}
    angle:=settings.angle*settings.weight
    stride:=1+(settings.stride-1)*settings.weight
    if angle==0 && stride==1 {return true}
    pelvis:=int(settings.pelvis)
    parent:=skeleton.parents[pelvis]
    parent_rotation:=world[parent].rotation if parent>=0 else root_transform.rotation
    local[pelvis].rotation=linalg.normalize0(conj(parent_rotation)*math.quat_axis_angle(up,angle)*world[pelvis].rotation)
    if !pose_world(skeleton.parents,local,world,root_transform) {return false}
    if len(settings.spine)>0 {
        turn:=math.quat_axis_angle(up,-angle/f32(len(settings.spine)))
        for bone in settings.spine {
            parent=skeleton.parents[bone]
            parent_rotation=world[parent].rotation if parent>=0 else root_transform.rotation
            local[bone].rotation=linalg.normalize0(conj(parent_rotation)*turn*world[bone].rotation)
            if !pose_world(skeleton.parents,local,world,root_transform) {return false}
        }
    }
    if stride==1 {return true}
    // The feet move along the stride; the pelvis drops by the least that keeps every leg no more
    // extended than the clip has it, and a foot still beyond that is pulled back to it.
    targets,poles:[16]math.Vec3;rotations:[16]math.Quat;extents:[16]f32
    drop:f32
    for leg,i in settings.legs {
        hip,foot:=world[leg.hip].position,world[leg.foot].position
        rotations[i]=world[leg.foot].rotation
        extents[i]=linalg.length(foot-hip)
        targets[i]=foot+direction*linalg.dot(foot-hip,direction)*(stride-1)
        if !anim_vec3_valid(targets[i]) {return false}
        if _,highest,reachable:=limb_height_range(hip,targets[i],up,extents[i]);reachable {drop=min(drop,highest)}
    }
    if drop<0 {
        moved:=world[pelvis];moved.position+=up*drop
        parent=skeleton.parents[pelvis]
        placed,placed_ok:=math.transform_relative(moved,world[parent] if parent>=0 else root_transform)
        if !placed_ok {return false}
        local[pelvis]=placed
        if !pose_world(skeleton.parents,local,world,root_transform) {return false}
    }
    for leg,i in settings.legs {
        hip:=world[leg.hip].position
        if reach:=targets[i]-hip;linalg.length(reach)>extents[i] {targets[i]=hip+linalg.normalize0(reach)*extents[i]}
        pole,valid:=two_bone_pole_from_pose(world[leg.hip],world[leg.knee],world[leg.foot],targets[i]);if !valid {return false}
        poles[i]=pole
    }
    for leg,i in settings.legs {
        if !skeleton_ik(skeleton,local,world,int(leg.hip),int(leg.knee),int(leg.foot),targets[i],poles[i],1,root_transform) {return false}
        local[leg.foot].rotation=linalg.normalize0(conj(world[leg.knee].rotation)*rotations[i])
        if !pose_world(skeleton.parents,local,world,root_transform) {return false}
    }
    return true
}

Distance_Key :: struct {time,distance:f32}

distance_track_validate :: proc "contextless" (keys:[]Distance_Key) -> bool {
    if len(keys)<2 {return false}
    direction:=1 if keys[len(keys)-1].distance>keys[0].distance else -1
    for key,i in keys {
        if !anim_finite(key.time) || key.time<0 || !anim_finite(key.distance) {return false}
        if i>0 && (key.time<=keys[i-1].time || (key.distance-keys[i-1].distance)*f32(direction)<=0) {return false}
    }
    return true
}

distance_to_time :: proc "contextless" (keys:[]Distance_Key,distance:f32) -> (time:f32,ok:bool) {
    if !anim_finite(distance) || !distance_track_validate(keys) {return}
    direction:=f32(1) if keys[len(keys)-1].distance>keys[0].distance else f32(-1)
    if distance*direction<=keys[0].distance*direction {return keys[0].time,true}
    if distance*direction>=keys[len(keys)-1].distance*direction {return keys[len(keys)-1].time,true}
    low,high:=0,len(keys)-1
    for high-low>1 {mid:=low+(high-low)/2;if distance*direction<keys[mid].distance*direction {high=mid} else {low=mid}}
    a,b:=keys[low],keys[high]
    ratio:=(f64(distance)-f64(a.distance))/(f64(b.distance)-f64(a.distance))
    return f32(f64(a.time)+(f64(b.time)-f64(a.time))*ratio),true
}
