package mirai_anim

import "core:math/linalg"
import math "mirai:std/math"

Chain_Retarget_Bone :: struct {target,source_a,source_b:i32,fraction:f32,rotation_offset:math.Quat}

skeleton_chain :: proc "contextless" (skeleton:Skeleton,root,end:i32,out:[]i32) -> (count:int,ok:bool) {
    if !skeleton_validate(skeleton) || root<0 || end<0 || int(root)>=len(skeleton.rest) || int(end)>=len(skeleton.rest) {return}
    bone:=end
    for bone>=0 && count<len(out) {
        out[count]=bone;count+=1
        if bone==root {break};bone=skeleton.parents[bone]
    }
    if count<2 || out[count-1]!=root {return count,false}
    for i in 0..<count/2 {out[i],out[count-1-i]=out[count-1-i],out[i]}
    return count,true
}

chain_retarget_prepare :: proc "contextless" (source,target:Skeleton,source_bones,target_bones:[]i32,source_rest,target_rest:[]math.Transform,out:[]Chain_Retarget_Bone) -> bool {
    if !skeleton_validate(source) || !skeleton_validate(target) || len(source_bones)<2 || len(target_bones)<2 || len(out)!=len(target_bones) || len(source_rest)!=len(source.rest) || len(target_rest)!=len(target.rest) {return false}
    for bone,i in source_bones {if bone<0 || int(bone)>=len(source.rest) || i>0 && source.parents[bone]!=source_bones[i-1] {return false}}
    for bone,i in target_bones {if bone<0 || int(bone)>=len(target.rest) || i>0 && target.parents[bone]!=target_bones[i-1] {return false}}
    if !pose_world(source.parents,source.rest,source_rest) || !pose_world(target.parents,target.rest,target_rest) {return false}
    source_length,target_length:f32
    for bone,i in source_bones[1:] {length:=linalg.length(source_rest[bone].position-source_rest[source_bones[i]].position);if !anim_finite(length) || length<=1e-6 {return false};source_length+=length}
    for bone,i in target_bones[1:] {length:=linalg.length(target_rest[bone].position-target_rest[target_bones[i]].position);if !anim_finite(length) || length<=1e-6 {return false};target_length+=length}
    if !anim_finite(source_length) || !anim_finite(target_length) {return false}
    target_distance:f32
    for bone,i in target_bones {
        if i>0 {target_distance+=linalg.length(target_rest[bone].position-target_rest[target_bones[i-1]].position)}
        wanted:=target_distance/target_length*source_length
        distance:f32
        a,b:=source_bones[0],source_bones[1]
        fraction:f32
        for source_bone,j in source_bones[1:] {
            a,b=source_bones[j],source_bone
            length:=linalg.length(source_rest[b].position-source_rest[a].position)
            if wanted<=distance+length || j==len(source_bones)-2 {fraction=math.saturate((wanted-distance)/length);break}
            distance+=length
        }
        rotation:=math.quat_slerp(source_rest[a].rotation,source_rest[b].rotation,fraction)
        out[i]={bone,a,b,fraction,linalg.normalize0(conj(rotation)*target_rest[bone].rotation)}
    }
    return true
}

chain_retarget_pose :: proc "contextless" (target:Skeleton,profile:[]Chain_Retarget_Bone,source_world:[]math.Transform,local,world:[]math.Transform,weight:f32=1,root_transform:math.Transform=math.TRANSFORM_IDENTITY) -> bool {
    if !skeleton_validate(target) || len(local)!=len(target.rest) || len(world)!=len(local) || len(profile)<2 || !anim_finite(weight) || !anim_pose_valid(source_world) {return false}
    for binding,i in profile {
        if binding.target<0 || int(binding.target)>=len(local) || binding.source_a<0 || binding.source_b<0 || int(binding.source_a)>=len(source_world) || int(binding.source_b)>=len(source_world) || !anim_rotation_valid(binding.rotation_offset) || !anim_finite(binding.fraction) || binding.fraction<0 || binding.fraction>1 || i>0 && target.parents[binding.target]!=profile[i-1].target {return false}
    }
    if !pose_world(target.parents,local,world,root_transform) {return false}
    for binding in profile {
        desired:=math.quat_slerp(source_world[binding.source_a].rotation,source_world[binding.source_b].rotation,binding.fraction)*binding.rotation_offset
        parent:=target.parents[binding.target]
        parent_rotation:=world[parent].rotation if parent>=0 else root_transform.rotation
        local[binding.target].rotation=math.quat_slerp(local[binding.target].rotation,linalg.normalize0(conj(parent_rotation)*desired),math.saturate(weight))
        if !pose_world(target.parents,local,world,root_transform) {return false}
    }
    return true
}
