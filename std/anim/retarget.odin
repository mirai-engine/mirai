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

// Pairs each bone of target with a bone of source, as a rig retargets the clips of another
// skeleton: by name, or by path where a name repeats (follow_prepare), else by the part of the
// body both maps mark, and the spine between pelvis and neck by its share of the chain; a source
// bone pairs once. mapping receives the source bone of each bone of target, -1 for none; the
// aliases are the hashes of the names of the bones, Skeleton.names those of their paths. Gives how
// many pair; ok is false for skeletons or bodies that are not valid, or without memory.
retarget_map :: proc(source,target:Skeleton,source_aliases,target_aliases:[]u64,source_body,target_body:Body_Map,mapping:[]i32,allocator:=context.temp_allocator) -> (paired:int,ok:bool) {
    n,m:=len(target.parents),len(source.parents)
    if len(mapping)!=n || len(target_aliases)!=n || len(source_aliases)!=m {return}
    if !body_map_valid(source_body,m) || !body_map_valid(target_body,n) {return}
    follow,e1:=make([]Follow_Bone,n,allocator);defer delete(follow,allocator)
    used,e2:=make([]bool,m,allocator);defer delete(used,allocator)
    target_spine,e3:=make([]i32,n,allocator);defer delete(target_spine,allocator)
    source_spine,e4:=make([]i32,m,allocator);defer delete(source_spine,allocator)
    if e1!=nil || e2!=nil || e3!=nil || e4!=nil {return}
    if _,followed:=follow_prepare(target,source,target_aliases,source_aliases,follow);!followed {return}
    for bone,i in follow {
        mapping[i]=bone.leader
        if bone.leader>=0 {used[bone.leader]=true;paired+=1}
    }
    take :: proc "contextless" (mapping:[]i32,used:[]bool,to,from:i32) -> bool {
        if to<0 || from<0 || mapping[to]>=0 || used[from] {return false}
        mapping[to]=from;used[from]=true
        return true
    }
    for part in Body_Part {if take(mapping,used,target_body.bones[part],source_body.bones[part]) {paired+=1}}
    to_count,to_spine:=body_spine(target.parents,target_body,target_spine)
    from_count,from_spine:=body_spine(source.parents,source_body,source_spine)
    if to_spine && from_spine && to_count>0 && from_count>0 {
        for bone,i in target_spine[:to_count] {
            if take(mapping,used,bone,source_spine[(i*from_count)/to_count]) {paired+=1}
        }
    }
    return paired,true
}
