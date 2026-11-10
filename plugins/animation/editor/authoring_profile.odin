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
    set:=new(Profile_Set_Params,context.temp_allocator);if set==nil {return}
    set.ik,set.look,set.limit,set.contact=anim.IK_CONSTRAINT_DEFAULT,anim.LOOK_CONSTRAINT_DEFAULT,anim.ROTATION_CONSTRAINT_DEFAULT,anim.FOOT_CONTACT_CONSTRAINT_DEFAULT
    set.retarget,set.retarget_chain=anim.RETARGET_MAPPING_DEFAULT,anim.CHAIN_RETARGET_CONSTRAINT_DEFAULT;profile_constraints_defaults(set)
    set.curve_pose,set.curve_drive,set.curve_material=anim.CURVE_POSE_DEFAULT,anim.CURVE_DRIVE_DEFAULT,anim.CURVE_MATERIAL_DEFAULT
    poses:=new(Profile_Poses_Params,context.temp_allocator);if poses==nil {return}
    poses.tolerance=PROFILE_POSES_TOLERANCE
    editor.api_method_register(s,{params=type_info_of(Authoring_Create_Params),result=type_info_of(Authoring_Write_Result),name="pose.profile.create",summary="Creates an empty .pose profile of rig operations; pose.profile.set fills its tables.",run=authoring_profile_create})
    editor.api_method_register(s,{params=type_info_of(Profile_Set_Params),result=type_info_of(Authoring_Write_Result),name="pose.profile.set",summary="Replaces or appends the row of a table of a .pose profile that has the key of the value, or removes it.",defaults=set,run=authoring_profile_set})
    editor.api_method_register(s,{params=type_info_of(Profile_Poses_Params),result=type_info_of(Profile_Poses_Result),name="pose.profile.poses",summary="Makes the curve poses of a .pose from the frames of a clip, each a pose that a Float curve of its name brings, measured from the pose at base: the poses of a face from an animation of them. One step of undo.",defaults=poses,run=authoring_profile_poses})
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
authoring_profile_inspect :: proc(s:^editor.Session,call:^api.Call,p:^Asset_Inspect_Params,r:^Asset_Inspect_Result) {
    file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=authoring_profile_open(s,call,p.asset,&file);if !ok {return}
    base.text_set(r.path[:],file.path)
    r.table=p.table
    r.counts={u32(len(profile.ik)),u32(len(profile.look)),u32(len(profile.limits)),u32(len(profile.contacts)),u32(len(profile.grounding)),u32(len(profile.retarget)),u32(len(profile.chain_ik)),u32(len(profile.twist)),u32(len(profile.springs)),u32(len(profile.multi_ik)),u32(len(profile.retarget_chains)),u32(len(profile.spline_ik)),u32(len(profile.correctives)),u32(len(profile.follow)),u32(len(profile.curve_poses)),u32(len(profile.curve_drives)),u32(len(profile.curve_materials))}
    o,l:=p.offset,p.limit
    switch p.table {
    case .IK: r.ik=authoring_pages(call,profile.ik,o,l,anim.IK_Constraint)
    case .Look: r.look=authoring_pages(call,profile.look,o,l,anim.Look_Constraint)
    case .Limit: r.limits=authoring_pages(call,profile.limits,o,l,anim.Rotation_Constraint)
    case .Contact: r.contacts=authoring_pages(call,profile.contacts,o,l,anim.Foot_Contact_Constraint)
    case .Grounding: r.grounding=authoring_pages(call,profile.grounding,o,l,Profile_Grounding_Params)
    case .Retarget: r.retarget=authoring_pages(call,profile.retarget,o,l,anim.Retarget_Mapping)
    case .Chain_IK: r.chain_ik=authoring_pages(call,profile.chain_ik,o,l,Profile_Chain_Params)
    case .Twist: r.twist=authoring_pages(call,profile.twist,o,l,Profile_Twist_Params)
    case .Spring: r.springs=authoring_pages(call,profile.springs,o,l,Profile_Spring_Params)
    case .Multi_IK: r.multi_ik=authoring_pages(call,profile.multi_ik,o,l,Profile_Multi_Params)
    case .Chain_Retarget: r.retarget_chains=authoring_pages(call,profile.retarget_chains,o,l,anim.Chain_Retarget_Constraint)
    case .Spline_IK: r.spline_ik=authoring_pages(call,profile.spline_ik,o,l,Profile_Spline_Params)
    case .Corrective: r.correctives=authoring_pages(call,profile.correctives,o,l,Profile_Corrective_Params)
    case .Follow: r.follow=authoring_pages(call,profile.follow,o,l,Profile_Follow_Params)
    case .Curve_Pose: r.curve_poses=authoring_pages(call,profile.curve_poses,o,l,anim.Curve_Pose)
    case .Curve_Drive: r.curve_drives=authoring_pages(call,profile.curve_drives,o,l,anim.Curve_Drive)
    case .Curve_Material: r.curve_materials=authoring_pages(call,profile.curve_materials,o,l,anim.Curve_Material)
    }
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
