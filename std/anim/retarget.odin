package mirai_anim

import "core:math/linalg"
import math "mirai:std/math"

Retarget_Bone :: struct {
    source:i32,
    rotation_offset:math.Quat,
    translation_basis:math.Quat,
    translation_scale:f32,
}

retarget_prepare :: proc "contextless" (source,target:Skeleton,mapping:[]i32,source_world,target_world:[]math.Transform,out:[]Retarget_Bone) -> bool {
    if !skeleton_validate(source) || !skeleton_validate(target) || len(mapping)!=len(target.rest) || len(out)!=len(mapping) {return false}
    for bone in mapping {if bone< -1 || int(bone)>=len(source.rest) {return false}}
    if !pose_world(source.parents,source.rest,source_world) || !pose_world(target.parents,target.rest,target_world) {return false}
    for source_index,i in mapping {
        out[i]={source=source_index,rotation_offset=1,translation_basis=1,translation_scale=1}
        if source_index<0 {continue}
        out[i].rotation_offset=conj(source_world[source_index].rotation)*target_world[i].rotation
        source_parent,target_parent:=source.parents[source_index],target.parents[i]
        source_rotation:=source_world[source_parent].rotation if source_parent>=0 else math.Quat(1)
        target_rotation:=target_world[target_parent].rotation if target_parent>=0 else math.Quat(1)
        out[i].translation_basis=conj(target_rotation)*source_rotation
        source_length:=linalg.length(source.rest[source_index].position)
        target_length:=linalg.length(target.rest[i].position)
        if source_length>1e-6 {out[i].translation_scale=target_length/source_length}
    }
    return true
}

retarget_pose :: proc "contextless" (source,target:Skeleton,profile:[]Retarget_Bone,source_local,source_world,target_world,out:[]math.Transform) -> bool {
    if !skeleton_validate(source) || !skeleton_validate(target) || len(profile)!=len(target.rest) || len(out)!=len(target.rest) || len(target_world)!=len(target.rest) {return false}
    for bone in profile {
        if bone.source< -1 || int(bone.source)>=len(source.rest) || !anim_rotation_valid(bone.rotation_offset) || !anim_rotation_valid(bone.translation_basis) || !anim_finite(bone.translation_scale) {return false}
    }
    if !pose_world(source.parents,source_local,source_world) {return false}
    for binding,i in profile {
        local:=target.rest[i]
        parent:=target.parents[i]
        if binding.source>=0 {
            rotation:=source_world[binding.source].rotation*binding.rotation_offset
            local.rotation=linalg.normalize0(conj(target_world[parent].rotation)*rotation if parent>=0 else rotation)
            delta:=source_local[binding.source].position-source.rest[binding.source].position
            local.position+=math.quat_rotate(binding.translation_basis,delta)*binding.translation_scale
        }
        out[i]=local
        target_world[i]=math.transform_compose(target_world[parent],local) if parent>=0 else local
        if !anim_transform_valid(target_world[i]) {return false}
    }
    return true
}
