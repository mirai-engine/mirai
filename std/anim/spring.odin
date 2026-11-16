package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

Spring_Collision :: struct {position:math.Vec3,radius:f32}
Spring_Joint_State :: struct {position,previous:math.Vec3,ready:bool}
Spring_Chain :: struct {
    gravity,force:math.Vec3 `mirai:"optional"`,
    stiffness,damping,radius:f32 `mirai:"optional,min=0"`,
    max_step:f32 `mirai:"optional,min=0,unit=s"`,
    reset_distance:f32 `mirai:"optional,min=0"`,
    iterations:int `mirai:"optional,min=1,max=256"`,
}
SPRING_CHAIN_DEFAULT :: Spring_Chain{gravity={0,-9.81,0},stiffness=30,damping=4,max_step=1.0/120,reset_distance=2,iterations=8}
Spring_Result :: struct {residual:f32,substeps:int,reset:bool}

spring_chain_update :: proc "contextless" (animated:[]math.Vec3,lengths:[]f32,limits:[]Chain_Limit,collisions:[]Spring_Collision,settings:Spring_Chain,dt:f32,state:[]Spring_Joint_State,out:[]math.Vec3) -> (result:Spring_Result,ok:bool) {
    count:=len(animated)
    if count<2 || len(lengths)!=count-1 || len(state)!=count || len(out)!=count || len(limits)!=0 && len(limits)!=count-2 || !anim_vec3_valid(settings.gravity) || !anim_vec3_valid(settings.force) || !anim_finite(dt) || dt<0 || settings.iterations<1 || settings.iterations>256 || !anim_finite(settings.max_step) || settings.max_step<=0 || !anim_finite(settings.stiffness) || settings.stiffness<0 || !anim_finite(settings.damping) || settings.damping<0 || !anim_finite(settings.radius) || settings.radius<0 || !anim_finite(settings.reset_distance) || settings.reset_distance<0 {return}
    steps:=cmath.ceil(dt/settings.max_step)
    if !anim_finite(steps) || steps>256 {return}
    for point in animated {if !anim_vec3_valid(point) {return}}
    for length in lengths {if !anim_finite(length) || length<=1e-6 {return}}
    for limit in limits {if !anim_finite(limit.min_bend) || !anim_finite(limit.max_bend) || limit.min_bend<0 || limit.min_bend>limit.max_bend || limit.max_bend>math.PI {return}}
    for collision in collisions {if !anim_vec3_valid(collision.position) || !anim_finite(collision.radius) || collision.radius<0 {return}}
    reset:=!state[0].ready || linalg.length(state[0].position-animated[0])>settings.reset_distance
    for joint in state {if joint.ready && (!anim_vec3_valid(joint.position) || !anim_vec3_valid(joint.previous)) {return};reset ||= !joint.ready}
    if reset {for point,i in animated {state[i]={point,point,true}};result.reset=true}
    if dt==0 {for joint,i in state {out[i]=joint.position};return result,true}
    result.substeps=max(1,int(steps));step:=dt/f32(result.substeps)
    damping:=1/(1+settings.damping*step)
    stiffness:=min(settings.stiffness*step*step,1)
    for substep in 0..<result.substeps {
        state[0].position,state[0].previous=animated[0],animated[0]
        for &joint,i in state[1:] {
            previous:=joint.position
            joint.position+=(joint.position-joint.previous)*damping+(settings.gravity+settings.force)*(step*step)+(animated[i+1]-joint.position)*stiffness
            joint.previous=previous
        }
        for iteration in 0..<settings.iterations {
            for &joint,i in state[1:] {
                at:=i+1
                direction:=chain_direction(joint.position-state[at-1].position,animated[at]-animated[at-1])
                if at>1 && len(limits)>0 {direction=chain_limit_direction(chain_direction(state[at-1].position-state[at-2].position,direction),direction,{},limits[at-2])}
                joint.position=state[at-1].position+direction*lengths[at-1]
                for collision in collisions {
                    delta:=joint.position-collision.position;distance:=linalg.length(delta)
                    radius:=settings.radius+collision.radius
                    if distance<radius {joint.position=collision.position+chain_direction(delta,direction)*radius}
                }
            }
        }
    }
    for joint,i in state {
        if !anim_vec3_valid(joint.position) || !anim_vec3_valid(joint.previous) {return result,false}
        out[i]=joint.position
        if i>0 {result.residual=max(result.residual,abs(linalg.length(out[i]-out[i-1])-lengths[i-1]))}
    }
    return result,anim_finite(result.residual)
}

skeleton_chain_from_points :: proc "contextless" (skeleton:Skeleton,local,world:[]math.Transform,bones:[]i32,points:[]math.Vec3,weight:f32=1,root_transform:math.Transform=math.TRANSFORM_IDENTITY) -> bool {
    if !skeleton_validate(skeleton) || len(local)!=len(skeleton.rest) || len(world)!=len(local) || len(bones)<2 || len(points)!=len(bones) || !anim_finite(weight) {return false}
    for bone,i in bones {if bone<0 || int(bone)>=len(local) || i>0 && skeleton.parents[bone]!=bones[i-1] || !anim_vec3_valid(points[i]) {return false}}
    if !pose_world(skeleton.parents,local,world,root_transform) {return false}
    end_rotation:=world[bones[len(bones)-1]].rotation
    for bone,i in bones[:len(bones)-1] {
        old_direction,old_ok:=anim_unit(world[bones[i+1]].position-world[bone].position)
        new_direction,new_ok:=anim_unit(points[i+1]-points[i])
        if !old_ok || !new_ok {return false}
        parent:=skeleton.parents[bone]
        parent_rotation:=world[parent].rotation if parent>=0 else root_transform.rotation
        desired:=linalg.normalize0(conj(parent_rotation)*anim_between(old_direction,new_direction)*world[bone].rotation)
        local[bone].rotation=math.quat_slerp(local[bone].rotation,desired,math.saturate(weight))
        if !pose_world(skeleton.parents,local,world,root_transform) {return false}
    }
    end:=bones[len(bones)-1];parent:=skeleton.parents[end]
    local[end].rotation=math.quat_slerp(local[end].rotation,linalg.normalize0(conj(world[parent].rotation if parent>=0 else root_transform.rotation)*end_rotation),math.saturate(weight))
    return pose_world(skeleton.parents,local,world,root_transform)
}
