package animation_editor

import "base:runtime"
import "core:mem"
import "mirai:editor/api"
import lib "mirai:std/anim"
import "mirai:std/serial"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

Profile_Chain_Params :: struct {name:[64]u8 `mirai:"text"`,root,end:anim.Bone_Ref,target:anim.Spatial_Target `mirai:"optional"`,pole:mm.Vec3 `mirai:"optional"`,iterations:u16 `mirai:"optional"`,tolerance,weight:f32 `mirai:"optional"`,reach:lib.Chain_Reach `mirai:"optional"`,limits:[anim.RIG_CHAIN_BONES-2]lib.Chain_Limit `mirai:"optional"`,use_pole,enabled:bool `mirai:"optional"`}
Profile_Twist_Amount :: struct {value:f32}
Profile_Twist_Params :: struct {name:[64]u8 `mirai:"text"`,source,root,end:anim.Bone_Ref,axis:mm.Vec3 `mirai:"optional"`,reference:mm.Quat `mirai:"optional"`,amounts:[anim.RIG_CHAIN_BONES]Profile_Twist_Amount `mirai:"optional"`,weight:f32 `mirai:"optional"`,enabled:bool `mirai:"optional"`}
Profile_Spring_Params :: struct {name:[64]u8 `mirai:"text"`,root,end:anim.Bone_Ref,settings:lib.Spring_Chain `mirai:"optional"`,limits:[anim.RIG_CHAIN_BONES-2]lib.Chain_Limit `mirai:"optional"`,collisions:[anim.RIG_COLLISIONS]lib.Spring_Collision `mirai:"optional"`,weight:f32 `mirai:"optional"`,enabled:bool `mirai:"optional"`}
Profile_Multi_Settings :: struct {root_policy:lib.Multi_IK_Root_Policy `mirai:"optional"`,root_stiffness,max_root_translation,relaxation:f32 `mirai:"optional"`,iterations:int `mirai:"optional"`,tolerance,angular_tolerance:f32 `mirai:"optional"`}
Profile_Multi_Params :: struct {name:[64]u8 `mirai:"text"`,root:anim.Bone_Ref,joints:[anim.RIG_CHAIN_BONES]anim.Multi_IK_Joint `mirai:"optional"`,effectors:[anim.RIG_EFFECTORS]anim.Multi_IK_Effector,settings:Profile_Multi_Settings `mirai:"optional"`,weight:f32 `mirai:"optional"`,enabled:bool `mirai:"optional"`}
Profile_Grounded_Leg :: struct {
    hip,knee,foot:anim.Bone_Ref,contact_bone:anim.Bone_Ref `mirai:"optional"`,
    pole_offset,foot_up:mm.Vec3 `mirai:"optional"`,sole_height,contact_offset,contact_height,plant_speed,max_tilt:f32 `mirai:"optional"`,
    phase,step_distance,step_height,step_duration,max_distance,contact:f32 `mirai:"optional"`,
    reach:lib.Chain_Reach `mirai:"optional"`,
}
Profile_Grounding_Params :: struct {
    mode:anim.Grounding_Mode `mirai:"optional"`,legs:[anim.GROUNDING_LEGS]Profile_Grounded_Leg,body:anim.Bone_Ref `mirai:"optional"`,up:mm.Vec3 `mirai:"optional"`,
    trace_above,trace_below,minimum_ground_dot:f32 `mirai:"optional"`,collision_mask:u32 `mirai:"optional"`,global_contact,weight:f32 `mirai:"optional,min=0,max=1"`,
    blend_time,release_distance,replant_distance,cycle_duration,swing_fraction:f32 `mirai:"optional"`,max_swinging:i32 `mirai:"optional"`,
    body_height,max_drop,max_rise,max_tilt,prediction:f32 `mirai:"optional"`,adjust_body,enabled:bool `mirai:"optional"`,
}
Authoring_Array_Length :: struct {name:string,count:int}

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
@(private)
authoring_write_arrays :: proc(call:^api.Call,value:^$T,lengths:[]Authoring_Array_Length,omit:[]string=nil) {
    schema:serial.Schema;allocator:=call.server.allocator if call.server!=nil else context.allocator;serial.schema_init(&schema,allocator);defer serial.schema_destroy(&schema)
    index,ok:=serial.schema_add_type_info(&schema,type_info_of(T));if !ok {authoring_failure(call,"result","Out_Of_Memory","a result schema","allocation failed","The result could not be written",api.SERVER_ERROR);return}
    root:=schema.types[index];bytes:=mem.ptr_to_bytes(value);serial.text_write_raw(call.out,"{");first:=true
    for field in schema.fields[root.first:][:root.count] {
        if .Transient in field.flags {continue}
        skipped:=false;for name in omit {if field.name==name {skipped=true;break}};if skipped {continue}
        type:=schema.types[field.type];part:=bytes[field.offset:][:type.size]
        api.write_key(call.out,field.name,first);first=false
        if .Text in field.flags {serial.text_write_string(call.out,base_text(part));continue}
        count:=-1;for length in lengths {if field.name==length.name {count=length.count;break}}
        if count>=0 && type.kind==.Array {serial.text_write_raw(call.out,"[");elem:=schema.types[type.elem];for i in 0..<min(count,int(type.count)) {if i>0 {serial.write_u8(call.out,',')};serial.text_write(call.out,&schema,type.elem,part[i*int(elem.size):][:elem.size],.Line)};serial.text_write_raw(call.out,"]")} else {serial.text_write(call.out,&schema,field.type,part,.Line)}
    }
    serial.text_write_raw(call.out,"}")
}
@(private)
base_text :: proc(bytes:[]u8) -> string {for byte,i in bytes {if byte==0 {return string(bytes[:i])}};return string(bytes)}
@(private)
profile_constraint_rows :: proc(call:^api.Call,name:string,rows:[]$T,offset,limit:u32) {
    api.write_key(call.out,name);serial.text_write_raw(call.out,"[");first:=min(int(offset),len(rows));last:=min(first+int(limit),len(rows))
    for &row,i in rows[first:last] {
        if i>0 {serial.write_u8(call.out,',')};serial.text_write_raw(call.out,"{");api.write_uint(call.out,"index",u64(first+i),true);api.write_key(call.out,"value")
        when T==anim.Chain_IK_Constraint {value:Profile_Chain_Params;authoring_struct_fields(&value,row);lengths:=[1]Authoring_Array_Length{{"limits",int(row.limit_count)}};authoring_write_arrays(call,&value,lengths[:])}
        else when T==anim.Twist_Constraint {value:Profile_Twist_Params;authoring_struct_fields(&value,row);for amount,j in row.amounts[:row.amount_count] {value.amounts[j].value=amount};lengths:=[1]Authoring_Array_Length{{"amounts",int(row.amount_count)}};authoring_write_arrays(call,&value,lengths[:])}
        else when T==anim.Spring_Constraint {value:Profile_Spring_Params;authoring_struct_fields(&value,row);lengths:=[2]Authoring_Array_Length{{"limits",int(row.limit_count)},{"collisions",int(row.collision_count)}};authoring_write_arrays(call,&value,lengths[:])}
        else when T==anim.Multi_IK_Constraint {value:Profile_Multi_Params;authoring_struct_fields(&value,row);authoring_struct_fields(&value.settings,row.settings);lengths:=[2]Authoring_Array_Length{{"joints",int(row.joint_count)},{"effectors",int(row.effector_count)}};authoring_write_arrays(call,&value,lengths[:])}
        else when T==anim.Spline_IK_Constraint {value:Profile_Spline_Params;authoring_struct_fields(&value,row);authoring_write_arrays(call,&value,nil)}
        else when T==anim.Pose_Corrective {value:Profile_Corrective_Params;authoring_struct_fields(&value,row);lengths:=[1]Authoring_Array_Length{{"samples",int(row.sample_count)}};authoring_write_arrays(call,&value,lengths[:])}
        else when T==anim.Follow_Constraint {value:Profile_Follow_Params;authoring_struct_fields(&value,row);authoring_write_arrays(call,&value,nil)}
        else when T==anim.Foot_Grounding {value:Profile_Grounding_Params;authoring_struct_fields(&value,row);for j in 0..<int(row.count) {authoring_struct_fields(&value.legs[j],row.legs[j])};lengths:=[1]Authoring_Array_Length{{"legs",int(row.count)}};authoring_write_arrays(call,&value,lengths[:])}
        serial.text_write_raw(call.out,"}")
    }
    serial.text_write_raw(call.out,"]")
}
