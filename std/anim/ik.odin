package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

IK_Result :: struct {root,joint,end:math.Transform,reached:bool}

two_bone_pole_from_pose :: proc "contextless" (root,joint,end:math.Transform,target:math.Vec3) -> (pole:math.Vec3,ok:bool) {
    if !anim_transform_valid(root) || !anim_transform_valid(joint) || !anim_transform_valid(end) || !anim_vec3_valid(target) {return}
    upper,lower:=joint.position-root.position,end.position-joint.position
    a,b:=linalg.length(upper),linalg.length(lower)
    if !(a>1e-6) || !(b>1e-6) || !anim_finite(a+b) {return}
    source,valid:=anim_unit(end.position-root.position)
    if !valid {source=upper/a}
    delta:=target-root.position
    if !anim_finite(linalg.length(delta)) {return}
    desired,desired_ok:=anim_unit(delta)
    if !desired_ok {desired=source}
    perpendicular:=upper-source*linalg.dot(upper,source)
    bend,has_bend:=anim_unit(perpendicular)
    has_bend &&=linalg.length(perpendicular)>a*1e-4
    if !has_bend {
        best:f32=-1
        for axis in ([3]math.Vec3{{1,0,0},{0,1,0},{0,0,1}}) {
            direction:=math.quat_rotate(joint.rotation,axis)
            perpendicular:=direction-source*linalg.dot(direction,source)
            squared:=linalg.dot(perpendicular,perpendicular)
            if squared>best+1e-5 {bend=perpendicular;best=squared}
        }
        bend,has_bend=anim_unit(bend)
        if !has_bend {return}
    }
    turn:=anim_between(source,desired)
    if linalg.dot(source,desired)<-.999999 {turn=math.quat_axis_angle(bend,cmath.PI)}
    bend=math.quat_rotate(turn,bend)
    pole=root.position+bend*(a+b)
    return pole,anim_vec3_valid(pole)
}

// With reach, the end eases in toward full extension and the two bones stretch past it, as a chain
// does (chain_reach): the joint keeps a bounded speed as the target leaves reach.
two_bone_ik :: proc "contextless" (root,joint,end:math.Transform,target,pole:math.Vec3,weight:f32=1,reach:Chain_Reach={}) -> (result:IK_Result,ok:bool) {
    result={root,joint,end,false}
    if !anim_transform_valid(root) || !anim_transform_valid(joint) || !anim_transform_valid(end) || !anim_vec3_valid(target) || !anim_vec3_valid(pole) || !anim_finite(weight) {return}
    upper,lower:=joint.position-root.position,end.position-joint.position
    a,b:=linalg.length(upper),linalg.length(lower)
    if !(a>1e-6) || !(b>1e-6) || !anim_finite(a+b) {return}
    delta:=target-root.position
    distance:=linalg.length(delta)
    if !anim_finite(distance) {return}
    goal,stretch:=distance,f32(1)
    if reach!={} {
        adjusted,scale,reach_ok:=chain_reach(root.position,target,a+b,reach)
        if !reach_ok {return}
        goal,stretch=linalg.length(adjusted-root.position),scale
    }
    direction,valid:=anim_unit(delta)
    if !valid {direction,_=anim_unit(end.position-root.position);if direction=={} {direction=upper/a}}
    long_a,long_b:=a*stretch,b*stretch
    minimum,maximum:=abs(long_a-long_b),long_a+long_b
    span:=clamp(goal,minimum,maximum)
    bend:=pole-root.position
    bend-=direction*linalg.dot(bend,direction)
    bend,valid=anim_unit(bend)
    if !valid {
        bend=upper-direction*linalg.dot(upper,direction)
        bend,valid=anim_unit(bend)
        if !valid {bend=anim_perpendicular(direction)}
    }
    along:f32
    if span>1e-6 {along=f32((f64(long_a)*f64(long_a)+f64(span)*f64(span)-f64(long_b)*f64(long_b))/(2*f64(span)))}
    height:=cmath.sqrt(max(long_a*long_a-along*along,0))
    solved_joint:=root.position+direction*along+bend*height
    solved_end:=root.position+direction*span
    upper_turn:=anim_between(upper/a,(solved_joint-root.position)/long_a)
    lower_turn:=anim_between(lower/b,(solved_end-solved_joint)/long_b)
    weight:=math.saturate(weight)
    upper_turn=math.quat_slerp(1,upper_turn,weight)
    lower_turn=math.quat_slerp(1,lower_turn,weight)
    shown:=1+(stretch-1)*weight
    result.root.rotation=linalg.normalize0(upper_turn*root.rotation)
    result.joint.rotation=linalg.normalize0(lower_turn*joint.rotation)
    result.joint.position=root.position+math.quat_rotate(upper_turn,upper*shown)
    result.end.position=result.joint.position+math.quat_rotate(lower_turn,lower*shown)
    result.reached=abs(distance-span)<=maximum*1e-5
    return result,true
}

skeleton_ik :: proc "contextless" (s:Skeleton,local,world:[]math.Transform,root,joint,end:int,target,pole:math.Vec3,weight:f32=1,root_transform:math.Transform=math.TRANSFORM_IDENTITY,reach:Chain_Reach={}) -> bool {
    if !skeleton_validate(s) || len(local)!=len(s.rest) || len(world)!=len(local) || root<0 || joint<0 || end<0 || root>=len(local) || joint>=len(local) || end>=len(local) || s.parents[joint]!=i32(root) || s.parents[end]!=i32(joint) {return false}
    if !pose_world(s.parents,local,world,root_transform) {return false}
    solved,ok:=two_bone_ik(world[root],world[joint],world[end],target,pole,weight,reach)
    if !ok {return false}
    if !pose_ik_local(s.parents,local,world,root,joint,end,solved,root_transform) {return false}
    return pose_world(s.parents,local,world,root_transform)
}

@(private)
pose_ik_local :: proc "contextless" (parents:[]i32,local,world:[]math.Transform,root,joint,end:int,solved:IK_Result,root_transform:math.Transform) -> bool {
    count:=len(parents)
    if len(local)!=count || len(world)!=count || root<0 || root>=count || joint<=root || joint>=count || end<=joint || end>=count || parents[joint]!=i32(root) || parents[end]!=i32(joint) || !anim_transform_valid(root_transform) || !anim_transform_valid(solved.root) || !anim_transform_valid(solved.joint) || !anim_transform_valid(solved.end) {return false}
    parent:=parents[root]
    if parent< -1 || int(parent)>=root || (parent>=0 && !anim_transform_valid(world[parent])) {return false}
    root_local,root_ok:=math.transform_relative(solved.root,world[parent] if parent>=0 else root_transform)
    if !root_ok {return false}
    joint_local,joint_ok:=math.transform_relative(solved.joint,solved.root)
    end_local,end_ok:=math.transform_relative(solved.end,solved.joint)
    if !joint_ok || !end_ok {return false}
    local[root],local[joint],local[end]=root_local,joint_local,end_local
    return true
}

pose_ik_apply :: proc "contextless" (hierarchy:Pose_Hierarchy,local,world:[]math.Transform,root,joint,end:int,solved:IK_Result,root_transform:math.Transform=math.TRANSFORM_IDENTITY) -> bool {
    if len(hierarchy.links)!=len(hierarchy.parents) {return false}
    if !pose_ik_local(hierarchy.parents,local,world,root,joint,end,solved,root_transform) {return false}
    return pose_world_branch(hierarchy,local,world,root,root_transform)
}

look_at :: proc "contextless" (rotation:math.Quat,forward,target_direction:math.Vec3,max_angle:f32,weight:f32=1) -> (math.Quat,bool) {
    if !anim_rotation_valid(rotation) || !anim_finite(max_angle) || max_angle<0 || !anim_finite(weight) {return rotation,false}
    from,from_ok:=anim_unit(forward)
    to,to_ok:=anim_unit(target_direction)
    if !from_ok || !to_ok {return rotation,false}
    change:=anim_between(math.quat_rotate(rotation,from),to)
    angle:=2*cmath.atan2(linalg.length(math.Vec3{change.x,change.y,change.z}),abs(change.w))
    fraction:=math.saturate(weight)
    if angle>max_angle {fraction*=max_angle/angle}
    return linalg.normalize0(math.quat_slerp(1,change,fraction)*rotation),true
}

Rotation_Limit :: struct {axis:math.Vec3,max_swing,min_twist,max_twist:f32}

rotation_limit :: proc "contextless" (rotation,reference:math.Quat,limit:Rotation_Limit) -> (math.Quat,bool) {
    axis,ok:=anim_unit(limit.axis)
    if !ok || !anim_rotation_valid(rotation) || !anim_rotation_valid(reference) || !anim_finite(limit.max_swing) || !anim_finite(limit.min_twist) || !anim_finite(limit.max_twist) || limit.max_swing<0 || limit.min_twist>limit.max_twist {return rotation,false}
    delta:=conj(reference)*rotation
    if delta.w<0 {delta=-delta}
    vector:=math.Vec3{delta.x,delta.y,delta.z}
    projected:=axis*linalg.dot(vector,axis)
    twist:=quaternion(w=delta.w,x=projected.x,y=projected.y,z=projected.z)
    twist=1 if linalg.dot(twist,twist)<1e-12 else linalg.normalize0(twist)
    swing:=delta*conj(twist)
    twist_angle:=2*cmath.atan2(linalg.dot(math.Vec3{twist.x,twist.y,twist.z},axis),twist.w)
    swing_angle:=2*cmath.atan2(linalg.length(math.Vec3{swing.x,swing.y,swing.z}),abs(swing.w))
    if swing_angle>limit.max_swing {swing=math.quat_slerp(1,swing,limit.max_swing/swing_angle)}
    twist=math.quat_axis_angle(axis,clamp(twist_angle,limit.min_twist,limit.max_twist))
    return linalg.normalize0(reference*swing*twist),true
}

Foot_Contact :: struct {anchor:math.Vec3,normal:math.Vec3,weight:f32,planted:bool}
Foot_Target :: struct {position,normal:math.Vec3,weight:f32}

foot_plant :: proc "contextless" (state:^Foot_Contact,animated,hit_position,hit_normal:math.Vec3,grounded:bool,contact,dt,blend_time,max_distance:f32) -> (Foot_Target,bool) {
    if !anim_vec3_valid(animated) || !anim_vec3_valid(hit_position) || !anim_vec3_valid(hit_normal) || !anim_finite(contact) || !anim_finite(dt) || dt<0 || !anim_finite(blend_time) || blend_time<0 || !anim_finite(max_distance) || max_distance<0 || !anim_finite(state.weight) {return {},false}
    active:=grounded && contact>0.5
    if state.planted && linalg.length(animated-state.anchor)>max_distance {active=false}
    normal,valid:=anim_unit(hit_normal)
    if active && !valid {return {},false}
    if active && !state.planted {state.anchor=hit_position;state.normal=normal}
    state.planted=active
    goal:=math.saturate(contact) if active else 0
    step:=dt/blend_time if blend_time>0 else 1
    state.weight+=clamp(goal-state.weight,-step,step)
    return {state.anchor if state.weight>0 else animated,state.normal,state.weight},true
}

pelvis_offset :: proc "contextless" (animated_feet:[]math.Vec3,targets:[]Foot_Target,up:math.Vec3,max_drop,max_rise:f32) -> (math.Vec3,bool) {
    direction,ok:=anim_unit(up)
    if !ok || len(animated_feet)!=len(targets) || !anim_finite(max_drop) || !anim_finite(max_rise) || max_drop<0 || max_rise<0 {return {},false}
    offset:f32
    first:=true
    for target,i in targets {
        if !anim_vec3_valid(animated_feet[i]) || !anim_vec3_valid(target.position) || !anim_finite(target.weight) {return {},false}
        if target.weight<=0 {continue}
        displacement:=linalg.dot(target.position-animated_feet[i],direction)*math.saturate(target.weight)
        if first || displacement<offset {offset=displacement;first=false}
    }
    return direction*clamp(offset,-max_drop,max_rise),true
}
