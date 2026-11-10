package animation_editor

import "base:runtime"
import "core:mem"
import "mirai:editor/api"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

Profile_Chain_Params :: struct {name:[64]u8 `mirai:"text"`,root,end:anim.Bone_Ref,target:anim.Spatial_Target `mirai:"optional"`,pole:mm.Vec3 `mirai:"optional"`,iterations:u16 `mirai:"optional"`,tolerance,weight:f32 `mirai:"optional"`,reach:lib.Chain_Reach `mirai:"optional"`,limits:[anim.RIG_CHAIN_BONES-2]lib.Chain_Limit `mirai:"optional,trim"`,use_pole,enabled:bool `mirai:"optional"`}
Profile_Twist_Amount :: struct {value:f32}
Profile_Twist_Params :: struct {name:[64]u8 `mirai:"text"`,source,root,end:anim.Bone_Ref,axis:mm.Vec3 `mirai:"optional"`,reference:mm.Quat `mirai:"optional"`,amounts:[anim.RIG_CHAIN_BONES]Profile_Twist_Amount `mirai:"optional,trim"`,weight:f32 `mirai:"optional"`,enabled:bool `mirai:"optional"`}
Profile_Spring_Params :: struct {name:[64]u8 `mirai:"text"`,root,end:anim.Bone_Ref,settings:lib.Spring_Chain `mirai:"optional"`,limits:[anim.RIG_CHAIN_BONES-2]lib.Chain_Limit `mirai:"optional,trim"`,collisions:[anim.RIG_COLLISIONS]lib.Spring_Collision `mirai:"optional,trim"`,weight:f32 `mirai:"optional"`,enabled:bool `mirai:"optional"`}
Profile_Multi_Settings :: struct {root_policy:lib.Multi_IK_Root_Policy `mirai:"optional"`,root_stiffness,max_root_translation,relaxation:f32 `mirai:"optional"`,iterations:int `mirai:"optional"`,tolerance,angular_tolerance:f32 `mirai:"optional"`}
Profile_Multi_Params :: struct {name:[64]u8 `mirai:"text"`,root:anim.Bone_Ref,joints:[anim.RIG_CHAIN_BONES]anim.Multi_IK_Joint `mirai:"optional,trim"`,effectors:[anim.RIG_EFFECTORS]anim.Multi_IK_Effector `mirai:"trim"`,settings:Profile_Multi_Settings `mirai:"optional"`,weight:f32 `mirai:"optional"`,enabled:bool `mirai:"optional"`}
Profile_Grounded_Leg :: struct {
    hip,knee,foot:anim.Bone_Ref,contact_bone:anim.Bone_Ref `mirai:"optional"`,
    pole_offset,foot_up:mm.Vec3 `mirai:"optional"`,sole_height,contact_offset,contact_height,plant_speed,max_tilt:f32 `mirai:"optional"`,
    phase,step_distance,step_height,step_duration,max_distance,contact:f32 `mirai:"optional"`,
}
Profile_Grounding_Params :: struct {
    mode:anim.Grounding_Mode `mirai:"optional"`,legs:[anim.GROUNDING_LEGS]Profile_Grounded_Leg `mirai:"trim"`,body:anim.Bone_Ref `mirai:"optional"`,up:mm.Vec3 `mirai:"optional"`,
    trace_above,trace_below,minimum_ground_dot:f32 `mirai:"optional"`,collision_mask:u32 `mirai:"optional"`,global_contact,weight:f32 `mirai:"optional,min=0,max=1"`,
    blend_time,release_distance,replant_distance,cycle_duration,swing_fraction:f32 `mirai:"optional"`,max_swinging:i32 `mirai:"optional"`,
    body_height,max_drop,max_rise,max_tilt,prediction:f32 `mirai:"optional"`,adjust_body,enabled:bool `mirai:"optional"`,
}

@(private)
authoring_struct_fields :: proc(out:^$T,source:$S) {
    destination:=runtime.type_info_base(type_info_of(T)).variant.(runtime.Type_Info_Struct);input:=runtime.type_info_base(type_info_of(S)).variant.(runtime.Type_Info_Struct)
    source:=source
    dst,src:=mem.ptr_to_bytes(out),mem.ptr_to_bytes(&source)
    for name,i in destination.names[:destination.field_count] {for candidate,j in input.names[:input.field_count] {if candidate==name && destination.types[i]==input.types[j] {size:=destination.types[i].size;copy(dst[destination.offsets[i]:][:size],src[input.offsets[j]:][:size]);break}}}
}
@(private)
profile_constraints_defaults :: proc(p:^Profile_Set_Params) {
    authoring_struct_fields(&p.spline_ik,anim.SPLINE_IK_CONSTRAINT_DEFAULT);authoring_struct_fields(&p.follow,anim.FOLLOW_CONSTRAINT_DEFAULT)
    authoring_struct_fields(&p.corrective,anim.POSE_CORRECTIVE_DEFAULT);for &sample in p.corrective.samples {sample=anim.POSE_CORRECTIVE_SAMPLE_DEFAULT}
    authoring_struct_fields(&p.chain_ik,anim.CHAIN_IK_CONSTRAINT_DEFAULT);authoring_struct_fields(&p.twist,anim.TWIST_CONSTRAINT_DEFAULT);authoring_struct_fields(&p.spring,anim.SPRING_CONSTRAINT_DEFAULT);authoring_struct_fields(&p.multi_ik,anim.MULTI_IK_CONSTRAINT_DEFAULT);authoring_struct_fields(&p.multi_ik.settings,lib.MULTI_IK_DEFAULT)
    for &joint in p.multi_ik.joints {joint=anim.MULTI_IK_JOINT_DEFAULT};for &effector in p.multi_ik.effectors {effector=anim.MULTI_IK_EFFECTOR_DEFAULT}
    authoring_struct_fields(&p.grounding,anim.FOOT_GROUNDING_DEFAULT);for &leg in p.grounding.legs {authoring_struct_fields(&leg,anim.GROUNDED_LEG_DEFAULT)}
}
@(private)
profile_array_count :: proc(call:^api.Call,field,array:string) -> int {text:=api.json_member(call.raw,field);nested:=api.Call{raw=text,allocator=call.allocator};count,_:=api.params_array_count(&nested,array);return count}
@(private)
profile_chain_value :: proc(call:^api.Call,p:Profile_Chain_Params) -> (value:anim.Chain_IK_Constraint) {authoring_struct_fields(&value,p);value.limit_count=u8(profile_array_count(call,"chain_ik","limits"));return}
@(private)
profile_twist_value :: proc(call:^api.Call,p:Profile_Twist_Params) -> (value:anim.Twist_Constraint) {authoring_struct_fields(&value,p);value.amount_count=u8(profile_array_count(call,"twist","amounts"));for i in 0..<int(value.amount_count) {value.amounts[i]=p.amounts[i].value};return}
@(private)
profile_spring_value :: proc(call:^api.Call,p:Profile_Spring_Params) -> (value:anim.Spring_Constraint) {authoring_struct_fields(&value,p);value.limit_count=u8(profile_array_count(call,"spring","limits"));value.collision_count=u8(profile_array_count(call,"spring","collisions"));return}
@(private)
profile_multi_value :: proc(call:^api.Call,p:Profile_Multi_Params) -> (value:anim.Multi_IK_Constraint) {authoring_struct_fields(&value,p);authoring_struct_fields(&value.settings,p.settings);value.joint_count=u8(profile_array_count(call,"multi_ik","joints"));value.effector_count=u8(profile_array_count(call,"multi_ik","effectors"));return}
@(private)
profile_grounding_value :: proc(call:^api.Call,p:Profile_Grounding_Params) -> (value:anim.Foot_Grounding) {authoring_struct_fields(&value,p);value.count=i32(profile_array_count(call,"grounding","legs"));for i in 0..<int(value.count) {authoring_struct_fields(&value.legs[i],p.legs[i])};return}
