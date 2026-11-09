package animation_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

Profile_Spline_Params :: struct {
    name:[64]u8 `mirai:"text"`,
    root,end:anim.Bone_Ref,
    controls:[4]anim.Spatial_Target `mirai:"optional,label=start; tangent_start; tangent_end and end"`,
    up:mm.Vec3 `mirai:"optional"`,
    twist:f32 `mirai:"optional,angle"`,
    weight:f32 `mirai:"optional,min=0,max=1"`,
    enabled:bool `mirai:"optional"`,
}
Profile_Corrective_Params :: struct {
    name:[64]u8 `mirai:"text"`,
    driver:anim.Bone_Ref,
    bone:anim.Bone_Ref `mirai:"optional"`,
    curve:[64]u8 `mirai:"optional,text,label=A Float curve it adds to (such as a morph target of the rig's mesh)"`,
    samples:[anim.RIG_POSE_SAMPLES]anim.Pose_Corrective_Sample,
    weight:f32 `mirai:"optional,min=0,max=1"`,
    apply_pose,enabled:bool `mirai:"optional"`,
}
Profile_Follow_Params :: struct {
    name:[64]u8 `mirai:"text"`,
    bone:anim.Bone_Ref,
    target:anim.Spatial_Target `mirai:"optional"`,
    position,rotation,scale,keep_world:bool `mirai:"optional"`,
    weight:f32 `mirai:"optional,min=0,max=1"`,
    enabled:bool `mirai:"optional"`,
}

// A target as an agent names it: an entity by id.
Spatial_Target_Params :: struct {
    kind:anim.Spatial_Target_Kind `mirai:"optional"`,
    entity:editor.Api_Entity_Text `mirai:"text,entity,optional,label=Entity: itself; Bone and Socket: the rig"`,
    bone:anim.Bone_Ref `mirai:"optional"`,
    socket:[64]u8 `mirai:"optional,text"`,
    position:mm.Vec3 `mirai:"optional,unit=m,label=World: in the world; the others: in the space of what they name"`,
    rotation:mm.Quat `mirai:"optional"`,
    scale:mm.Vec3 `mirai:"optional"`,
}
SPATIAL_TARGET_PARAMS_DEFAULT :: Spatial_Target_Params{rotation=1,scale={1,1,1}}

@(private)
profile_spline_value :: proc(p:Profile_Spline_Params) -> (value:anim.Spline_IK_Constraint) {authoring_struct_fields(&value,p);return}
@(private)
profile_follow_value :: proc(p:Profile_Follow_Params) -> (value:anim.Follow_Constraint) {authoring_struct_fields(&value,p);return}
@(private)
profile_corrective_value :: proc(call:^api.Call,p:Profile_Corrective_Params) -> (value:anim.Pose_Corrective) {
    authoring_struct_fields(&value,p)
    value.sample_count=u8(profile_array_count(call,"corrective","samples"))
    return
}

// The target of a goal in a world, or a failure that says what is wrong with it.
@(private)
spatial_target_value :: proc(call:^api.Call,world:core.World_Ref,p:Spatial_Target_Params,path:string) -> (target:anim.Spatial_Target,ok:bool) {
    p:=p
    target=anim.SPATIAL_TARGET_DEFAULT
    target.kind,target.bone,target.socket=p.kind,p.bone,p.socket
    target.position,target.rotation,target.scale=p.position,p.rotation,p.scale
    if p.kind!=.World {
        if p.entity[0]==0 {authoring_failure(call,fmt.tprintf("%s.entity",path),"Required","the entity, or of the rig of a bone or socket","zero","An Entity, Bone or Socket target names an entity");return}
        problem:string
        if target.entity,problem=editor.api_entity_select(world,base.text_get(p.entity[:]),"entity",false,call.allocator);problem!="" {
            authoring_failure(call,fmt.tprintf("%s.entity",path),"Missing_Reference","an entity in the selected world",base.text_get(p.entity[:]),"The target entity does not exist",fix=problem);return
        }
    }
    if !anim.spatial_target_valid(target) {authoring_failure(call,path,"Invalid_Target","a finite transform with a unit rotation, and the bone or socket its kind names",fmt.tprintf("%v",p.kind),"Fix the target's transform or name");return}
    return target,true
}
