package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

twist_angle :: proc "contextless" (rotation,reference:math.Quat,axis:math.Vec3) -> (angle:f32,ok:bool) {
    if !anim_rotation_valid(rotation) || !anim_rotation_valid(reference) {return}
    direction,valid:=anim_unit(axis);if !valid {return}
    delta:=linalg.normalize0(conj(reference)*rotation);if delta.w<0 {delta=-delta}
    projected:=linalg.dot(math.Vec3{delta.x,delta.y,delta.z},direction)
    if abs(delta.w)+abs(projected)<1e-6 {return 0,true}
    angle=2*cmath.atan2(projected,delta.w)
    return angle,anim_finite(angle)
}

skeleton_twist :: proc "contextless" (skeleton:Skeleton,local,world:[]math.Transform,source:i32,bones:[]i32,amounts:[]f32,axis:math.Vec3,reference:math.Quat,original:[]math.Quat,weight:f32=1,root_transform:math.Transform=math.TRANSFORM_IDENTITY) -> bool {
    if !skeleton_validate(skeleton) || len(local)!=len(skeleton.rest) || len(world)!=len(local) || source<0 || int(source)>=len(local) || len(bones)==0 || len(amounts)!=len(bones) || len(original)!=len(bones) || !anim_finite(weight) {return false}
    total:f32
    for bone,i in bones {
        if bone<0 || int(bone)>=len(local) || bone==source || i>0 && skeleton.parents[bone]!=bones[i-1] || !anim_finite(amounts[i]) || amounts[i]<0 {return false}
        total+=amounts[i]
    }
    if !anim_finite(total) || total<=0 {return false}
    angle,ok:=twist_angle(local[source].rotation,reference,axis);if !ok {return false}
    if !pose_world(skeleton.parents,local,world,root_transform) {return false}
    world_axis,axis_ok:=anim_unit(math.quat_rotate(world[source].rotation,axis));if !axis_ok {return false}
    for bone,i in bones {original[i]=world[bone].rotation}
    accumulated:f32
    for bone,i in bones {
        accumulated+=amounts[i]/total
        desired:=math.quat_axis_angle(world_axis,angle*accumulated*math.saturate(weight))*original[i]
        parent:=skeleton.parents[bone]
        local[bone].rotation=linalg.normalize0(conj(world[parent].rotation if parent>=0 else root_transform.rotation)*desired)
        if !pose_world(skeleton.parents,local,world,root_transform) {return false}
    }
    return true
}
