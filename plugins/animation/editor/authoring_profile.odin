package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

Profile_Table :: enum u8 {IK,Look,Limit,Contact,Grounding,Retarget,Chain_IK,Twist,Spring,Multi_IK,Chain_Retarget,Spline_IK,Corrective,Follow,Curve_Pose,Curve_Drive,Curve_Material}
Profile_Counts :: struct {IK,Look,Limit,Contact,Grounding,Retarget,Chain_IK,Twist,Spring,Multi_IK,Chain_Retarget,Spline_IK,Corrective,Follow,Curve_Pose,Curve_Drive,Curve_Material:u32}
Profile_Inspect_Result :: struct {
    asset:base.Asset_Id,path:[1024]u8 `mirai:"text"`,table:Profile_Table,counts:Profile_Counts,
    ik:[256]Authoring_Page(anim.IK_Constraint),look:[256]Authoring_Page(anim.Look_Constraint),limits:[256]Authoring_Page(anim.Rotation_Constraint),contacts:[256]Authoring_Page(anim.Foot_Contact_Constraint),grounding:[1]Authoring_Page(Profile_Grounding_Params),retarget:[256]Authoring_Page(anim.Retarget_Mapping),
    chain_ik:[256]Authoring_Page(Profile_Chain_Params),twist:[256]Authoring_Page(Profile_Twist_Params),springs:[256]Authoring_Page(Profile_Spring_Params),multi_ik:[256]Authoring_Page(Profile_Multi_Params),retarget_chains:[256]Authoring_Page(anim.Chain_Retarget_Constraint),
    spline_ik:[256]Authoring_Page(Profile_Spline_Params),correctives:[256]Authoring_Page(Profile_Corrective_Params),follow:[256]Authoring_Page(Profile_Follow_Params),
    curve_poses:[256]Authoring_Page(anim.Curve_Pose),curve_drives:[256]Authoring_Page(anim.Curve_Drive),curve_materials:[256]Authoring_Page(anim.Curve_Material),
}
Profile_Inspect_Params :: struct {
    asset:base.Asset_Id,
    table:Profile_Table,
    offset:u32 `mirai:"optional"`,
    limit:u32 `mirai:"optional,min=1,max=256,clamp"`,
}
Profile_Set_Params :: struct {
    asset:base.Asset_Id,
    table:Profile_Table `mirai:"label=The table; the field named after it holds the value and the lengths of its arrays are its counts. A row with the key of that value is replaced or removed and otherwise appended: end for IK and Contact; bone for Look and Limit; name for the tables that name rows; target_bone and mode for Retarget; curve and bone for Curve_Pose; from with and to for Curve_Drive; curve parameter and slot for Curve_Material; Grounding is the one rig. A table holds 256 rows; Curve_Pose, Curve_Drive and Curve_Material 4096; Grounding one rig of up to 16 legs"`,
    ik:anim.IK_Constraint `mirai:"optional"`,
    look:anim.Look_Constraint `mirai:"optional"`,
    limit:anim.Rotation_Constraint `mirai:"optional"`,
    contact:anim.Foot_Contact_Constraint `mirai:"optional"`,
    grounding:Profile_Grounding_Params `mirai:"optional"`,
    retarget:anim.Retarget_Mapping `mirai:"optional"`,
    chain_ik:Profile_Chain_Params `mirai:"optional"`,
    twist:Profile_Twist_Params `mirai:"optional"`,
    spring:Profile_Spring_Params `mirai:"optional"`,
    multi_ik:Profile_Multi_Params `mirai:"optional"`,
    retarget_chain:anim.Chain_Retarget_Constraint `mirai:"optional"`,
    spline_ik:Profile_Spline_Params `mirai:"optional"`,
    corrective:Profile_Corrective_Params `mirai:"optional"`,
    follow:Profile_Follow_Params `mirai:"optional"`,
    curve_pose:anim.Curve_Pose `mirai:"optional,label=A bone that a Float curve moves by delta at its value; a pose of a face is a row per bone"`,
    curve_drive:anim.Curve_Drive `mirai:"optional,label=A Float curve that adds scale times its value to another; rows apply in order"`,
    curve_material:anim.Curve_Material `mirai:"optional,label=A material value of the meshes of the rig that a Float curve moves; step rounds it to frames"`,
    remove:bool `mirai:"optional"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}

@(private)
authoring_profile_register :: proc(s:^editor.Session) {
    inspect:=Profile_Inspect_Params{limit=128}
    set:=new(Profile_Set_Params,context.temp_allocator);if set==nil {return}
    set.ik,set.look,set.limit,set.contact=anim.IK_CONSTRAINT_DEFAULT,anim.LOOK_CONSTRAINT_DEFAULT,anim.ROTATION_CONSTRAINT_DEFAULT,anim.FOOT_CONTACT_CONSTRAINT_DEFAULT
    set.retarget,set.retarget_chain=anim.RETARGET_MAPPING_DEFAULT,anim.CHAIN_RETARGET_CONSTRAINT_DEFAULT;profile_constraints_defaults(set)
    set.curve_pose,set.curve_drive,set.curve_material=anim.CURVE_POSE_DEFAULT,anim.CURVE_DRIVE_DEFAULT,anim.CURVE_MATERIAL_DEFAULT
    poses:=new(Profile_Poses_Params,context.temp_allocator);if poses==nil {return}
    poses.tolerance=PROFILE_POSES_TOLERANCE
    editor.api_method_register(s,Authoring_Create_Params,Authoring_Write_Result,{name="pose.profile.create",summary="Creates an empty .pose profile of rig operations; pose.profile.set fills its tables.",run=authoring_profile_create})
    editor.api_method_register(s,Profile_Set_Params,Authoring_Write_Result,{name="pose.profile.set",summary="Replaces or appends the row of a table of a .pose profile that has the key of the value, or removes it.",defaults=set,run=authoring_profile_set})
    editor.api_method_register(s,Profile_Poses_Params,Profile_Poses_Result,{name="pose.profile.poses",summary="Makes the curve poses of a .pose from the frames of a clip, each a pose that a Float curve of its name brings, measured from the pose at base: the poses of a face from an animation of them. One step of undo.",defaults=poses,run=authoring_profile_poses})
}

@(private)
authoring_profile_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,result:^Authoring_File) -> (profile:anim.Pose_Profile,ok:bool) {
    if !authoring_open(s,call,id,anim.POSE_KIND,result) {return}
    error:asset.Error
    profile,error=anim.pose_profile_view(&result.file,&s.app.assets.types)
    if error!=.None {authoring_failure(call,"asset","Invalid_Asset","a valid .pose asset",fmt.tprintf("%v",error),"The pose profile is invalid");return}
    return profile,true
}

@(private)
authoring_profile_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Profile_Inspect_Params)
    file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=authoring_profile_open(s,call,p.asset,&file);if !ok {return}
    out:=call.out
    serial.text_write_raw(out,"{");authoring_result(call,p.asset,file.path)
    api.write_key(out,"counts");serial.text_write_raw(out,"{")
    api.write_uint(out,"IK",u64(len(profile.ik)),true);api.write_uint(out,"Look",u64(len(profile.look)));api.write_uint(out,"Limit",u64(len(profile.limits)));api.write_uint(out,"Contact",u64(len(profile.contacts)));api.write_uint(out,"Grounding",u64(len(profile.grounding)));api.write_uint(out,"Retarget",u64(len(profile.retarget)));api.write_uint(out,"Chain_IK",u64(len(profile.chain_ik)));api.write_uint(out,"Twist",u64(len(profile.twist)));api.write_uint(out,"Spring",u64(len(profile.springs)));api.write_uint(out,"Multi_IK",u64(len(profile.multi_ik)));api.write_uint(out,"Chain_Retarget",u64(len(profile.retarget_chains)));api.write_uint(out,"Spline_IK",u64(len(profile.spline_ik)));api.write_uint(out,"Corrective",u64(len(profile.correctives)));api.write_uint(out,"Follow",u64(len(profile.follow)));api.write_uint(out,"Curve_Pose",u64(len(profile.curve_poses)));api.write_uint(out,"Curve_Drive",u64(len(profile.curve_drives)));api.write_uint(out,"Curve_Material",u64(len(profile.curve_materials)));serial.text_write_raw(out,"}")
    api.write_key(out,"table");authoring_write_value(call,&p.table,type_info_of(Profile_Table))
    program_rows(call,"ik",profile.ik if p.table==.IK else nil,p.offset,p.limit)
    program_rows(call,"look",profile.look if p.table==.Look else nil,p.offset,p.limit)
    program_rows(call,"limits",profile.limits if p.table==.Limit else nil,p.offset,p.limit)
    program_rows(call,"contacts",profile.contacts if p.table==.Contact else nil,p.offset,p.limit)
    profile_constraint_rows(call,"grounding",profile.grounding if p.table==.Grounding else nil,p.offset,p.limit)
    program_rows(call,"retarget",profile.retarget if p.table==.Retarget else nil,p.offset,p.limit)
    profile_constraint_rows(call,"chain_ik",profile.chain_ik if p.table==.Chain_IK else nil,p.offset,p.limit)
    profile_constraint_rows(call,"twist",profile.twist if p.table==.Twist else nil,p.offset,p.limit)
    profile_constraint_rows(call,"springs",profile.springs if p.table==.Spring else nil,p.offset,p.limit)
    profile_constraint_rows(call,"multi_ik",profile.multi_ik if p.table==.Multi_IK else nil,p.offset,p.limit)
    program_rows(call,"retarget_chains",profile.retarget_chains if p.table==.Chain_Retarget else nil,p.offset,p.limit)
    profile_constraint_rows(call,"spline_ik",profile.spline_ik if p.table==.Spline_IK else nil,p.offset,p.limit)
    profile_constraint_rows(call,"correctives",profile.correctives if p.table==.Corrective else nil,p.offset,p.limit)
    profile_constraint_rows(call,"follow",profile.follow if p.table==.Follow else nil,p.offset,p.limit)
    program_rows(call,"curve_poses",profile.curve_poses if p.table==.Curve_Pose else nil,p.offset,p.limit)
    program_rows(call,"curve_drives",profile.curve_drives if p.table==.Curve_Drive else nil,p.offset,p.limit)
    program_rows(call,"curve_materials",profile.curve_materials if p.table==.Curve_Material else nil,p.offset,p.limit)
    serial.text_write_raw(out,"}")
}

// rows with value in the place of the row with its key, or after them; with
// remove, without that row. False with no such row to remove or no room.
@(private)
profile_row :: proc(rows:[]$T,value:T,same:proc(a,b:T) -> bool,remove:bool,capacity:int,allocator:=context.temp_allocator) -> (result:[]T,ok:bool) {
    at:=len(rows)
    for &row,i in rows {if same(row,value) {at=i;break}}
    return authoring_replace_row(rows,at,value,remove,capacity,allocator)
}

@(private)
authoring_profile_save :: proc(s:^editor.Session,call:^api.Call,target:Authoring_File,id:base.Asset_Id,profile:anim.Pose_Profile) {
    doc:asset.Document;defer asset.document_destroy(&doc)
    if error:=anim.pose_profile_document(&doc,&s.app.assets.types,id,profile,s.app.allocator);error!=.None {authoring_failure(call,"profile","Out_Of_Memory" if error==.Out_Of_Memory else "Invalid_Definition","valid constraints within profile capacities",fmt.tprintf("%v",error),"The pose profile edit could not be prepared",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS);return}
    _=authoring_publish(s,call,target,&doc,api.call_result(call,Authoring_Write_Result))
}

@(private)
authoring_profile_create :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Authoring_Create_Params)
    file,id,ok:=authoring_create_target(s,call,base.text_get(p.path[:]),".pose");if !ok {return}
    authoring_profile_save(s,call,file,id,{})
}

@(private)
authoring_profile_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Profile_Set_Params)
    if !authoring_editable(s,call) {return}
    fields:=[Profile_Table]string{.IK="ik",.Look="look",.Limit="limit",.Contact="contact",.Grounding="grounding",.Retarget="retarget",.Chain_IK="chain_ik",.Twist="twist",.Spring="spring",.Multi_IK="multi_ik",.Chain_Retarget="retarget_chain",.Spline_IK="spline_ik",.Corrective="corrective",.Follow="follow",.Curve_Pose="curve_pose",.Curve_Drive="curve_drive",.Curve_Material="curve_material"}
    if p.table>max(Profile_Table) || !(p.remove && p.table==.Grounding) && !authoring_field_present(call,fields[p.table]) {authoring_failure(call,"table","Required","the constraint field selected by table","missing or invalid table","Supply the constraint field selected by table");return}
    file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=authoring_profile_open(s,call,p.asset,&file);if !ok {return}
    replaced:=false
    capacity:=anim.POSE_CONSTRAINTS
    switch p.table {
    case .IK: profile.ik,replaced=profile_row(profile.ik,p.ik,proc(a,b:anim.IK_Constraint) -> bool {return a.end==b.end},p.remove,capacity,call.allocator)
    case .Look: profile.look,replaced=profile_row(profile.look,p.look,proc(a,b:anim.Look_Constraint) -> bool {return a.bone==b.bone},p.remove,capacity,call.allocator)
    case .Limit: profile.limits,replaced=profile_row(profile.limits,p.limit,proc(a,b:anim.Rotation_Constraint) -> bool {return a.bone==b.bone},p.remove,capacity,call.allocator)
    case .Contact: profile.contacts,replaced=profile_row(profile.contacts,p.contact,proc(a,b:anim.Foot_Contact_Constraint) -> bool {return a.end==b.end},p.remove,capacity,call.allocator)
    case .Grounding: profile.grounding,replaced=profile_row(profile.grounding,profile_grounding_value(call,p.grounding),proc(a,b:anim.Foot_Grounding) -> bool {return true},p.remove,1,call.allocator)
    case .Retarget: profile.retarget,replaced=profile_row(profile.retarget,p.retarget,proc(a,b:anim.Retarget_Mapping) -> bool {return a.mode==b.mode && a.target_bone==b.target_bone},p.remove,capacity,call.allocator)
    case .Chain_IK: profile.chain_ik,replaced=profile_row(profile.chain_ik,profile_chain_value(call,p.chain_ik),proc(a,b:anim.Chain_IK_Constraint) -> bool {return a.name==b.name},p.remove,capacity,call.allocator)
    case .Twist: profile.twist,replaced=profile_row(profile.twist,profile_twist_value(call,p.twist),proc(a,b:anim.Twist_Constraint) -> bool {return a.name==b.name},p.remove,capacity,call.allocator)
    case .Spring: profile.springs,replaced=profile_row(profile.springs,profile_spring_value(call,p.spring),proc(a,b:anim.Spring_Constraint) -> bool {return a.name==b.name},p.remove,capacity,call.allocator)
    case .Multi_IK: profile.multi_ik,replaced=profile_row(profile.multi_ik,profile_multi_value(call,p.multi_ik),proc(a,b:anim.Multi_IK_Constraint) -> bool {return a.name==b.name},p.remove,capacity,call.allocator)
    case .Chain_Retarget: profile.retarget_chains,replaced=profile_row(profile.retarget_chains,p.retarget_chain,proc(a,b:anim.Chain_Retarget_Constraint) -> bool {return a.name==b.name},p.remove,capacity,call.allocator)
    case .Spline_IK: profile.spline_ik,replaced=profile_row(profile.spline_ik,profile_spline_value(p.spline_ik),proc(a,b:anim.Spline_IK_Constraint) -> bool {return a.name==b.name},p.remove,capacity,call.allocator)
    case .Corrective: profile.correctives,replaced=profile_row(profile.correctives,profile_corrective_value(call,p.corrective),proc(a,b:anim.Pose_Corrective) -> bool {return a.name==b.name},p.remove,capacity,call.allocator)
    case .Follow: profile.follow,replaced=profile_row(profile.follow,profile_follow_value(p.follow),proc(a,b:anim.Follow_Constraint) -> bool {return a.name==b.name},p.remove,capacity,call.allocator)
    case .Curve_Pose: profile.curve_poses,replaced=profile_row(profile.curve_poses,p.curve_pose,proc(a,b:anim.Curve_Pose) -> bool {return a.curve==b.curve && a.bone==b.bone},p.remove,anim.POSE_CURVE_ROWS,call.allocator)
    case .Curve_Drive: profile.curve_drives,replaced=profile_row(profile.curve_drives,p.curve_drive,proc(a,b:anim.Curve_Drive) -> bool {return a.from==b.from && a.with==b.with && a.to==b.to},p.remove,anim.POSE_CURVE_ROWS,call.allocator)
    case .Curve_Material: profile.curve_materials,replaced=profile_row(profile.curve_materials,p.curve_material,proc(a,b:anim.Curve_Material) -> bool {return a.curve==b.curve && a.parameter==b.parameter && a.slot==b.slot && a.every==b.every},p.remove,anim.POSE_CURVE_ROWS,call.allocator)
    }
    if !replaced {authoring_failure(call,"table","Invalid_Edit","a row of that key to remove, or room for another row",fmt.tprintf("%v; remove=%t",p.table,p.remove),"The row is not in the table, or the table has no room for another",fix="animation.asset.inspect with the table lists its rows");return}
    authoring_profile_save(s,call,file,p.asset,profile)
}
