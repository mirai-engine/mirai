package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

Chain_Reach :: struct {
    soft_distance:f32 `mirai:"optional,min=0"`,
    max_stretch:f32 `mirai:"optional,min=0"`,
}

aim_at :: proc "contextless" (rotation:math.Quat,forward,target_direction,up,world_up:math.Vec3,max_angle:f32,weight:f32=1,offset:math.Vec3={}) -> (math.Quat,bool) {
    local_up,up_ok:=anim_unit(up);wanted_up,wanted_ok:=anim_unit(world_up)
    axis,axis_ok:=anim_unit(forward)
    if !up_ok || !wanted_ok || !axis_ok || linalg.length(linalg.cross(axis,local_up))<1e-6 || !anim_finite(weight) {return rotation,false}
    desired,ok:=look_at(rotation,forward,target_direction,max_angle,1,offset)
    if !ok {return rotation,false}
    // It rolls around the line from the bone to where the ray passes, which keeps the ray on it.
    point,_:=look_point(rotation,forward,target_direction,offset)
    aimed,_:=anim_unit(math.quat_rotate(desired,point))
    current:=math.quat_rotate(desired,local_up)
    a,a_ok:=anim_unit(current-aimed*linalg.dot(current,aimed))
    b,b_ok:=anim_unit(wanted_up-aimed*linalg.dot(wanted_up,aimed))
    if a_ok && b_ok {desired=linalg.normalize0(math.quat_axis_angle(aimed,cmath.atan2(linalg.dot(aimed,linalg.cross(a,b)),linalg.dot(a,b)))*desired)}
    return math.quat_slerp(rotation,desired,math.saturate(weight)),true
}

chain_reach :: proc "contextless" (root,target:math.Vec3,length:f32,settings:Chain_Reach) -> (adjusted:math.Vec3,scale:f32,ok:bool) {
    if !anim_vec3_valid(root) || !anim_vec3_valid(target) || !anim_finite(length) || length<=1e-6 || !anim_finite(settings.soft_distance) || settings.soft_distance<0 || settings.soft_distance>length || !anim_finite(settings.max_stretch) || settings.max_stretch<0 {return}
    delta:=target-root;distance:=linalg.length(delta)
    if !anim_finite(distance) {return}
    scale=1
    if distance<=1e-6 {return target,scale,true}
    softened:=min(distance,length)
    if settings.soft_distance>0 && distance>length-settings.soft_distance {
        x:=(distance-length+settings.soft_distance)/settings.soft_distance
        softened=length-settings.soft_distance/(1+x+x*x*.5)
    }
    extra:=min(max(distance-softened,0),settings.max_stretch)
    scale=(length+extra)/length
    adjusted=root+delta*((softened+extra)/distance)
    return adjusted,scale,anim_vec3_valid(adjusted) && anim_finite(scale)
}

Spline_Chain :: struct {controls:[4]math.Vec3,up:math.Vec3,twist:f32}
SPLINE_CHAIN_DEFAULT :: Spline_Chain{up={0,1,0}}
SPLINE_SEGMENTS :: 64

spline_chain :: proc "contextless" (settings:Spline_Chain,lengths:[]f32,out:[]math.Vec3) -> bool {
    if len(out)<2 || len(lengths)!=len(out)-1 || !anim_vec3_valid(settings.up) || !anim_finite(settings.twist) {return false}
    for point in settings.controls {if !anim_vec3_valid(point) {return false}}
    for length in lengths {if !anim_finite(length) || length<=1e-6 {return false}}
    points:[SPLINE_SEGMENTS+1]math.Vec3
    total:f32
    for &point,i in points {
        t:=f32(i)/SPLINE_SEGMENTS;u:=1-t
        point=settings.controls[0]*(u*u*u)+settings.controls[1]*(3*u*u*t)+settings.controls[2]*(3*u*t*t)+settings.controls[3]*(t*t*t)
        if !anim_vec3_valid(point) {return false}
        if i>0 {total+=linalg.length(point-points[i-1])}
    }
    if !anim_finite(total) || total<=1e-6 {return false}
    out[0]=points[0];segment:=0;cursor:=points[0]
    for length,i in lengths {
        found:=false
        for segment<SPLINE_SEGMENTS {
            end:=points[segment+1];d:=end-cursor;v:=cursor-out[i]
            a:=linalg.dot(d,d);b:=linalg.dot(v,d);c:=linalg.dot(v,v)-length*length
            discriminant:=b*b-a*c
            if a>1e-12 && discriminant>=0 {
                t:=(-b+cmath.sqrt(discriminant))/a
                if t>=0 && t<=1 {cursor+=d*t;out[i+1]=cursor;found=true;break}
            }
            segment+=1;cursor=end
        }
        if !found {
            direction:=chain_direction(points[SPLINE_SEGMENTS]-points[SPLINE_SEGMENTS-1],settings.controls[3]-settings.controls[0])
            v:=cursor-out[i];b:=linalg.dot(v,direction);c:=linalg.dot(v,v)-length*length
            distance:=-b+cmath.sqrt(max(b*b-c,0))
            cursor+=direction*max(distance,0);out[i+1]=cursor
        }
        if !anim_vec3_valid(out[i+1]) {return false}
    }
    return true
}

skeleton_spline_ik :: proc "contextless" (skeleton:Skeleton,local,world:[]math.Transform,bones:[]i32,settings:Spline_Chain,points:[]math.Vec3,lengths:[]f32,weight:f32=1,root_transform:math.Transform=math.TRANSFORM_IDENTITY) -> bool {
    count:=len(bones)
    if count<2 || len(points)!=count || len(lengths)!=count-1 || !skeleton_validate(skeleton) || len(local)!=len(skeleton.rest) || len(world)!=len(local) || !anim_finite(weight) {return false}
    for bone,i in bones {if bone<0 || int(bone)>=len(local) || i>0 && skeleton.parents[bone]!=bones[i-1] {return false}}
    if !pose_world(skeleton.parents,local,world,root_transform) {return false}
    for bone,i in bones {if i>0 {lengths[i-1]=linalg.length(world[bone].position-world[bones[i-1]].position)}}
    if !spline_chain(settings,lengths,points) {return false}
    weight:=math.saturate(weight)
    up,up_ok:=anim_unit(settings.up);if !up_ok {return false}
    distance,total:f32;for length in lengths {total+=length}
    for bone,i in bones {
        parent:=skeleton.parents[bone];parent_world:=root_transform if parent<0 else world[parent]
        current:=math.transform_compose(parent_world,local[bone]);desired:=current
        desired.position=points[i]
        if i<count-1 {
            old_direction:=chain_direction(math.quat_rotate(current.rotation,local[bones[i+1]].position*current.scale),{1,0,0})
            direction:=chain_direction(points[i+1]-points[i],old_direction)
            rotation:=linalg.normalize0(anim_between(old_direction,direction)*current.rotation)
            local_up:=math.quat_rotate(conj(current.rotation),up)
            current_up:=math.quat_rotate(rotation,local_up)
            a,a_ok:=anim_unit(current_up-direction*linalg.dot(current_up,direction))
            b,b_ok:=anim_unit(up-direction*linalg.dot(up,direction))
            if a_ok && b_ok {rotation=math.quat_axis_angle(direction,cmath.atan2(linalg.dot(direction,linalg.cross(a,b)),linalg.dot(a,b)))*rotation}
            desired.rotation=linalg.normalize0(math.quat_axis_angle(direction,settings.twist*distance/total)*rotation)
        }
        local_position,position_ok:=math.transform_relative(desired,parent_world)
        if !position_ok {return false}
        local[bone]=math.transform_interpolate(local[bone],local_position,weight)
        world[bone]=math.transform_compose(parent_world,local[bone])
        if i<count-1 {distance+=lengths[i]}
    }
    return pose_world(skeleton.parents,local,world,root_transform)
}

@(private)
pose_sample_distance :: proc "contextless" (a,b:math.Quat) -> f32 {
    a,b:=linalg.normalize0(a),linalg.normalize0(b)
    if linalg.dot(a,b)<0 {b=-b}
    difference:=a-b
    chord:=cmath.sqrt(linalg.dot(difference,difference))
    return 4*cmath.asin(clamp(chord*.5,0,1))
}

pose_sample_weights :: proc "contextless" (rotation:math.Quat,samples:[]math.Quat,out:[]f32) -> bool {
    if len(samples)==0 || len(out)!=len(samples) || !anim_rotation_valid(rotation) {return false}
    minimum:=f32(math.PI)
    for sample,i in samples {
        if !anim_rotation_valid(sample) {return false}
        for previous in samples[:i] {if pose_sample_distance(previous,sample)<1e-3 {return false}}
        distance:=pose_sample_distance(rotation,sample)
        out[i]=distance;minimum=min(minimum,distance)
    }
    if minimum<=1e-5 {for &value in out {value=1 if value<=1e-5 else 0};return true}
    total:f32
    for &value in out {value=(minimum/value)*(minimum/value);total+=value}
    if !anim_finite(total) || total<=0 {return false}
    for &value in out {value/=total}
    return true
}
