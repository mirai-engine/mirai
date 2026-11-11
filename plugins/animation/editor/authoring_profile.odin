package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import anim "plugins:animation/runtime"

// The tables of the modifiers of a .character.
Profile_Table :: enum u8 {IK,Look,Limit,Grounding,Chain_IK,Twist,Spring,Multi_IK,Chain_Retarget,Spline_IK,Corrective,Follow,Curve_Pose,Curve_Drive,Curve_Material}
Profile_Counts :: struct {IK,Look,Limit,Grounding,Chain_IK,Twist,Spring,Multi_IK,Chain_Retarget,Spline_IK,Corrective,Follow,Curve_Pose,Curve_Drive,Curve_Material:u32}
Profile_Set_Params :: struct {
    path:[1024]u8 `mirai:"text,label=Ending in .character: its other tables are kept"`,
    animation:base.Asset_Id `mirai:"optional,label=The .anim of the clips of a new .character; none for one of only modifiers"`,
    table:Profile_Table `mirai:"label=The table; the field named after it holds the value and the lengths of its arrays are its counts. A row with the key of that value is replaced or removed and otherwise appended: end for IK; bone for Look and Limit; name for the tables that name rows; curve and bone for Curve_Pose; from with and to for Curve_Drive; curve parameter and slot for Curve_Material; Grounding is the one rig. A table holds 256 rows; Curve_Pose, Curve_Drive and Curve_Material 4096; Grounding one rig of up to 16 legs"`,
    ik:anim.IK_Constraint `mirai:"optional"`,
    look:anim.Look_Constraint `mirai:"optional"`,
    limit:anim.Rotation_Constraint `mirai:"optional"`,
    grounding:Profile_Grounding_Params `mirai:"optional"`,
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
    set.ik,set.look,set.limit=anim.IK_CONSTRAINT_DEFAULT,anim.LOOK_CONSTRAINT_DEFAULT,anim.ROTATION_CONSTRAINT_DEFAULT
    set.retarget_chain=anim.CHAIN_RETARGET_CONSTRAINT_DEFAULT;profile_constraints_defaults(set)
    set.curve_pose,set.curve_drive,set.curve_material=anim.CURVE_POSE_DEFAULT,anim.CURVE_DRIVE_DEFAULT,anim.CURVE_MATERIAL_DEFAULT
    poses:=new(Profile_Poses_Params,context.temp_allocator);if poses==nil {return}
    poses.tolerance=PROFILE_POSES_TOLERANCE
    editor.api_method_register(s,{params=type_info_of(Profile_Set_Params),result=type_info_of(Authoring_Write_Result),name="animation.modifier.set",summary="Replaces or appends the row of a table of the modifiers of a .character (IK, look, limits, grounding, rigs, curve poses) that has the key of the value, or removes it; a new .character at path is made of animation.",defaults=set,run=authoring_profile_set})
    editor.api_method_register(s,{params=type_info_of(Profile_Poses_Params),result=type_info_of(Profile_Poses_Result),name="animation.modifier.poses",summary="Makes the curve poses of a .character from the frames of a clip, each a pose that a Float curve of its name brings, measured from the pose at base: the poses of a face from an animation of them. One step of undo.",defaults=poses,run=authoring_profile_poses})
}

// The counts of the tables of the modifiers of a set, and a page of the rows of table.
@(private)
// The modifiers of a .character: the rows of each table and a page of the rows of one.
character_modifiers :: proc(call:^api.Call,profile:anim.Pose_Profile,table:Profile_Table,offset,limit:u32,r:^Asset_Inspect_Result) {
    r.counts={u32(len(profile.ik)),u32(len(profile.look)),u32(len(profile.limits)),u32(1 if profile.grounding.count>0 else 0),u32(len(profile.chain_ik)),u32(len(profile.twist)),u32(len(profile.springs)),u32(len(profile.multi_ik)),u32(len(profile.retarget_chains)),u32(len(profile.spline_ik)),u32(len(profile.correctives)),u32(len(profile.follow)),u32(len(profile.curve_poses)),u32(len(profile.curve_drives)),u32(len(profile.curve_materials))}
    r.table=table
    o,l:=offset,limit
    grounding:=[1]anim.Foot_Grounding{profile.grounding}
    switch table {
    case .IK: r.ik=authoring_pages(call,profile.ik,o,l,anim.IK_Constraint)
    case .Look: r.look=authoring_pages(call,profile.look,o,l,anim.Look_Constraint)
    case .Limit: r.limits=authoring_pages(call,profile.limits,o,l,anim.Rotation_Constraint)
    case .Grounding: r.grounding=authoring_pages(call,grounding[:1 if profile.grounding.count>0 else 0],o,l,Profile_Grounding_Params)
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
authoring_profile_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Profile_Set_Params)
    if !authoring_editable(s,call) {return}
    fields:=[Profile_Table]string{.IK="ik",.Look="look",.Limit="limit",.Grounding="grounding",.Chain_IK="chain_ik",.Twist="twist",.Spring="spring",.Multi_IK="multi_ik",.Chain_Retarget="retarget_chain",.Spline_IK="spline_ik",.Corrective="corrective",.Follow="follow",.Curve_Pose="curve_pose",.Curve_Drive="curve_drive",.Curve_Material="curve_material"}
    if p.table>max(Profile_Table) || !(p.remove && p.table==.Grounding) && !authoring_field_present(call,fields[p.table]) {authoring_failure(call,"table","Required","the constraint field selected by table","missing or invalid table","Supply the constraint field selected by table");return}
    file:Authoring_File;defer asset.asset_close(&file.file)
    set,id,ok:=character_target(s,call,base.text_get(p.path[:]),p.animation,&file,clips=false);if !ok {return}
    profile:=&set.pose
    replaced:=false
    capacity:=anim.POSE_CONSTRAINTS
    switch p.table {
    case .IK: profile.ik,replaced=profile_row(profile.ik,p.ik,proc(a,b:anim.IK_Constraint) -> bool {return a.end==b.end},p.remove,capacity,call.allocator)
    case .Look: profile.look,replaced=profile_row(profile.look,p.look,proc(a,b:anim.Look_Constraint) -> bool {return a.bone==b.bone},p.remove,capacity,call.allocator)
    case .Limit: profile.limits,replaced=profile_row(profile.limits,p.limit,proc(a,b:anim.Rotation_Constraint) -> bool {return a.bone==b.bone},p.remove,capacity,call.allocator)
    case .Grounding:
        replaced=true
        if p.remove {profile.grounding.count=0} else {profile.grounding=profile_grounding_value(call,p.grounding)}
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
    _=character_publish(s,call,file,id,set)
}
