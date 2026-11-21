package anim

import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

@(private)
test_modifier_profile :: proc(runtime:^Modifier_Runtime,cache:^Character_Assets,entity:core.Entity,pose:Pose_Profile) -> ^Modifier_Rig {
    rig:=modifier_rig_add(runtime,entity)
    if rig==nil {return nil}
    id:=base.Asset_Id{u64(entity),1}
    index:=int(rig.character)-1
    if index<0 {
        index=len(cache.contents)
        if append(&cache.contents,Character_Content{})!=1 {return nil}
    }
    content:=&cache.contents[index]
    if !modifier_rig_prepare(rig,pose,id,content.revision+1,i32(index+1)) {return nil}
    content.id,content.revision,content.valid=id,rig.revision,true
    content.set.pose=pose
    return rig
}

@(private)
test_modifier_weight :: proc(runtime:^Modifier_Runtime,entity:core.Entity,kind:Modifier_Kind,name:string) -> f32 {
    weight,_,_,_,_,_,_:=modifier_influence(core.ref(runtime),entity,kind,base.name_hash(name))
    return weight
}

@(private)
test_rigs_apply :: proc(state:^Playing,runtime:^Modifier_Runtime,characters:^Character_Assets,
    inputs:Constraint_Inputs,transforms:^core.Table(core.Transform),
    parents:^core.Table(core.Parent,.Read),root:mm.Transform,dt:f32,playback:^Playback=nil) -> bool {
    rig:=modifier_rig(core.ref(runtime),state.entity)
    empty:Pose_Profile
    pose:=modifier_pose(rig,characters)
    if pose==nil {pose=&empty}
    return rigs_apply(state,runtime,rig,pose^,inputs,transforms,parents,root,dt,playback)
}

@(private)
test_rigs_retarget :: proc(state:^Playing,playback:^Playback,runtime:^Modifier_Runtime,
    characters:^Character_Assets,problems:^core.Problems) -> bool {
    rig:=modifier_rig(core.ref(runtime),state.entity)
    empty:Pose_Profile
    pose:=modifier_pose(rig,characters)
    if pose==nil {pose=&empty}
    return rigs_retarget(state,playback,runtime,rig,pose^,problems)
}
