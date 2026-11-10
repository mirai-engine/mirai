package anim

import "core:mem"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import "base:runtime"

POSE_KIND :: asset.Fourcc(u32('P')|u32('O')<<8|u32('S')<<16|u32('E')<<24)
POSE_VERSION :: 6
POSE_CONSTRAINTS :: 256

@(component,description="Applies a pose profile with IK, aiming, joint limits or foot grounding. Gameplay supplies the dynamic targets.")
Pose_Modifiers :: struct {
    profile:base.Asset_Id `mirai:"kind=.pose"`,
    weight:f32 `mirai:"min=0,max=1"`,
    enabled:bool,
}
POSE_MODIFIERS_DEFAULT :: Pose_Modifiers{weight=1,enabled=true}

@(component,description="Attaches this entity to a named socket in another entity's skeleton, with an additional local offset.")
Bone_Attachment :: struct {
    rig:core.Entity,
    socket:[64]u8 `mirai:"text"`,
    offset:mm.Transform,
    enabled:bool,
}
BONE_ATTACHMENT_DEFAULT :: Bone_Attachment{offset=mm.TRANSFORM_IDENTITY,enabled=true}

Pose_Profile :: struct {
    ik:[]IK_Constraint,
    look:[]Look_Constraint,
    limits:[]Rotation_Constraint,
    contacts:[]Foot_Contact_Constraint,
    grounding:[]Foot_Grounding,
    retarget:[]Retarget_Mapping,
    chain_ik:[]Chain_IK_Constraint,
    twist:[]Twist_Constraint,
    springs:[]Spring_Constraint,
    multi_ik:[]Multi_IK_Constraint,
    retarget_chains:[]Chain_Retarget_Constraint,
    spline_ik:[]Spline_IK_Constraint,
    correctives:[]Pose_Corrective,
    follow:[]Follow_Constraint,
    curve_poses:[]Curve_Pose,
    curve_drives:[]Curve_Drive,
    curve_materials:[]Curve_Material,
}

pose_profile_check :: proc(profile:Pose_Profile) -> bool {
    if len(profile.ik)>POSE_CONSTRAINTS || len(profile.look)>POSE_CONSTRAINTS || len(profile.limits)>POSE_CONSTRAINTS || len(profile.contacts)>POSE_CONSTRAINTS || len(profile.grounding)>1 || len(profile.retarget)>POSE_CONSTRAINTS {return false}
    for value in profile.ik {
        if !profile_bone(value.root) || !profile_bone(value.joint) || !profile_bone(value.end) || !spatial_target_valid(value.target,false) || !profile_vector(value.pole) || !profile_weight(value.weight) {return false}
    }
    for value in profile.look {
        if !profile_bone(value.bone) || !spatial_target_valid(value.target,false) || !profile_vector(value.forward) || !finite(value.max_angle) || value.max_angle<0 || !profile_weight(value.weight) {return false}
        if value.use_up {_,ok:=lib.aim_at(1,value.forward,{0,0,-1},value.up,value.world_up,value.max_angle);if !ok {return false}}
    }
    for value in profile.limits {
        if !profile_bone(value.bone) || !profile_vector(value.axis) || !finite(value.max_swing) || !finite(value.min_twist) || !finite(value.max_twist) || value.min_twist>value.max_twist || !profile_weight(value.weight) {return false}
        if !profile_rotation(value.reference) {return false}
    }
    for value in profile.contacts {
        if !profile_bone(value.root) || !profile_bone(value.joint) || !profile_bone(value.end) || !profile_bone(value.pelvis) || !profile_vector(value.hit_position) || !profile_vector(value.hit_normal) || !profile_vector(value.pole) || !profile_vector(value.up) || !profile_weight(value.weight) || !profile_weight(value.contact) {return false}
        for number in ([?]f32{value.blend_time,value.max_distance,value.max_drop,value.max_rise}) {if !finite(number) || number<0 {return false}}
    }
    for &value in profile.grounding {
        if !grounding_config_valid(value) || !profile_bone(value.body) {return false}
        for leg in value.legs[:value.count] {if !profile_bone(leg.hip) || !profile_bone(leg.knee) || !profile_bone(leg.foot) || !profile_bone(leg.contact_bone) {return false}}
    }
    paths:=false
    for value in profile.retarget {
        if value.mode>.Paths || value.translation>max(type_of(value.translation)) || !profile_bone(value.source_bone) || !profile_bone(value.target_bone) {return false}
        if value.mode==.Paths {if paths {return false};paths=true}
    }
    return rig_profiles_check(profile) && curve_poses_check(profile)
}
@(private) profile_bone :: proc(value:Bone_Ref) -> bool {_,ok:=bone_ref_hash(value);return ok}
@(private) profile_weight :: proc "contextless" (value:f32) -> bool {return finite(value) && value>=0 && value<=1}
@(private) profile_vector :: proc "contextless" (value:mm.Vec3) -> bool {for number in value {if !finite(number) {return false}};return true}
@(private) profile_rotation :: proc "contextless" (value:mm.Quat) -> bool {return abs(value.x*value.x+value.y*value.y+value.z*value.z+value.w*value.w-1)<1e-3}

pose_profile_document :: proc(doc:^asset.Document,types:^asset.Types,id:base.Asset_Id,profile:Pose_Profile,allocator:=context.allocator) -> asset.Error {
    if !pose_profile_check(profile) {return .Invalid}
    asset.document_init(doc,POSE_KIND,id,allocator);doc.kind_version=POSE_VERSION
    error:=pose_profile_tables(doc,types,profile)
    if error!=.None {asset.document_destroy(doc)}
    return error
}
@(private)
pose_profile_tables :: proc(doc:^asset.Document,types:^asset.Types,profile:Pose_Profile) -> asset.Error {
    asset.document_put(doc,types,"ik",profile.ik) or_return
    asset.document_put(doc,types,"look",profile.look) or_return
    asset.document_put(doc,types,"limits",profile.limits) or_return
    asset.document_put(doc,types,"contacts",profile.contacts) or_return
    asset.document_put(doc,types,"grounding",profile.grounding) or_return
    asset.document_put(doc,types,"retarget",profile.retarget) or_return
    asset.document_put(doc,types,"chain_ik",profile.chain_ik) or_return
    asset.document_put(doc,types,"twist",profile.twist) or_return
    asset.document_put(doc,types,"springs",profile.springs) or_return
    asset.document_put(doc,types,"multi_ik",profile.multi_ik) or_return
    asset.document_put(doc,types,"retarget_chains",profile.retarget_chains) or_return
    asset.document_put(doc,types,"spline_ik",profile.spline_ik) or_return
    asset.document_put(doc,types,"correctives",profile.correctives) or_return
    asset.document_put(doc,types,"follow",profile.follow) or_return
    asset.document_put(doc,types,"curve_poses",profile.curve_poses) or_return
    asset.document_put(doc,types,"curve_drives",profile.curve_drives) or_return
    asset.document_put(doc,types,"curve_materials",profile.curve_materials) or_return
    return .None
}
pose_profile_save :: proc(path:string,types:^asset.Types,id:base.Asset_Id,profile:Pose_Profile,allocator:=context.allocator) -> asset.Error {
    doc:asset.Document
    pose_profile_document(&doc,types,id,profile,allocator) or_return
    defer asset.document_destroy(&doc)
    return asset.document_save(&doc,path)
}
pose_profile_view :: proc(file:^asset.Asset,types:^asset.Types) -> (profile:Pose_Profile,error:asset.Error) {
    asset.kind_check(file,POSE_KIND,POSE_VERSION) or_return
    profile.ik=asset.asset_rows(file,types,"ik","",IK_Constraint) or_return
    profile.look=asset.asset_rows(file,types,"look","",Look_Constraint) or_return
    profile.limits=asset.asset_rows(file,types,"limits","",Rotation_Constraint) or_return
    profile.contacts=asset.asset_rows(file,types,"contacts","",Foot_Contact_Constraint) or_return
    profile.grounding=asset.asset_rows(file,types,"grounding","",Foot_Grounding) or_return
    profile.retarget=asset.asset_rows(file,types,"retarget","",Retarget_Mapping) or_return
    profile.chain_ik=asset.asset_rows(file,types,"chain_ik","",Chain_IK_Constraint) or_return
    profile.twist=asset.asset_rows(file,types,"twist","",Twist_Constraint) or_return
    profile.springs=asset.asset_rows(file,types,"springs","",Spring_Constraint) or_return
    profile.multi_ik=asset.asset_rows(file,types,"multi_ik","",Multi_IK_Constraint) or_return
    profile.retarget_chains=asset.asset_rows(file,types,"retarget_chains","",Chain_Retarget_Constraint) or_return
    profile.spline_ik=asset.asset_rows(file,types,"spline_ik","",Spline_IK_Constraint) or_return
    profile.correctives=asset.asset_rows(file,types,"correctives","",Pose_Corrective) or_return
    profile.follow=asset.asset_rows(file,types,"follow","",Follow_Constraint) or_return
    profile.curve_poses=asset.asset_rows(file,types,"curve_poses","",Curve_Pose) or_return
    profile.curve_drives=asset.asset_rows(file,types,"curve_drives","",Curve_Drive) or_return
    profile.curve_materials=asset.asset_rows(file,types,"curve_materials","",Curve_Material) or_return
    if !pose_profile_check(profile) {return {},.Corrupt}
    return profile,.None
}

Pose_Content :: struct {id:base.Asset_Id,checked,revision:u64,stamp:[2]i64,profile:Pose_Profile,valid:bool,error:asset.Error}
@(storage,host,free="pose_assets_free")
Pose_Assets :: struct {allocator:mem.Allocator,contents:[dynamic]Pose_Content}

pose_profile_free :: proc(profile:^Pose_Profile) {
    delete(profile.chain_ik);delete(profile.twist);delete(profile.springs);delete(profile.multi_ik);delete(profile.retarget_chains)
    delete(profile.spline_ik);delete(profile.correctives);delete(profile.follow);delete(profile.curve_poses);delete(profile.curve_drives);delete(profile.curve_materials)
    delete(profile.ik);delete(profile.look);delete(profile.limits);delete(profile.contacts);delete(profile.grounding);delete(profile.retarget);profile^={}
}
pose_assets_free :: proc(cache:^Pose_Assets) {
    if cache.allocator.procedure!=nil {context.allocator=cache.allocator}
    for &content in cache.contents {pose_profile_free(&content.profile)}
    delete(cache.contents);cache^={}
}
pose_content :: proc(cache:^Pose_Assets,assets:^host.Assets,allocator:runtime.Allocator,id:base.Asset_Id) -> ^Pose_Content {
    if cache==nil || assets==nil || id=={} {return nil}
    context.allocator=allocator;cache.allocator=allocator
    row:=-1
    for content,i in cache.contents {if content.id==id {row=i;break}}
    if row<0 {row=len(cache.contents);if append(&cache.contents,Pose_Content{id=id})!=1 {return nil}}
    content:=&cache.contents[row]
    if content.checked==assets_stamp(assets) {return content if content.valid else nil}
    record,found:=asset.registry_find(&assets.registry,id)
    stamp:=[2]i64{}
    if found {stamp={record.size,record.time}}
    if content.checked!=0 && stamp==content.stamp {content.checked=assets_stamp(assets);return content if content.valid else nil}
    profile:Pose_Profile
    error:=asset.Error.Not_Found
    if found {profile,error=pose_profile_read(assets,allocator,id)}
    content.error=error
    if error==.Out_Of_Memory {content.checked=0;return nil}
    pose_profile_free(&content.profile);content.profile=profile;content.valid=error==.None
    content.stamp,content.checked=stamp,assets_stamp(assets);content.revision+=1
    return content if content.valid else nil
}
@(private)
pose_profile_read :: proc(assets:^host.Assets,allocator:runtime.Allocator,id:base.Asset_Id) -> (profile:Pose_Profile,error:asset.Error) {
    file:asset.Asset
    if error:=host.assets_file(assets,id,POSE_KIND,&file);error!=.None {return {},error};defer asset.asset_close(&file)
    view,read:=pose_profile_view(&file,&assets.types)
    if read!=.None {return {},read}
    clone :: proc(source:[]$T,allocator:mem.Allocator) -> ([]T,bool) {
        out,error:=make([]T,len(source),allocator);if error!=nil {return nil,false};copy(out,source);return out,true
    }
    ok:bool
    profile.ik,ok=clone(view.ik,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.look,ok=clone(view.look,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.limits,ok=clone(view.limits,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.contacts,ok=clone(view.contacts,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.grounding,ok=clone(view.grounding,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.retarget,ok=clone(view.retarget,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.chain_ik,ok=clone(view.chain_ik,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.twist,ok=clone(view.twist,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.springs,ok=clone(view.springs,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.multi_ik,ok=clone(view.multi_ik,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.retarget_chains,ok=clone(view.retarget_chains,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.spline_ik,ok=clone(view.spline_ik,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.correctives,ok=clone(view.correctives,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.follow,ok=clone(view.follow,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.curve_poses,ok=clone(view.curve_poses,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.curve_drives,ok=clone(view.curve_drives,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    profile.curve_materials,ok=clone(view.curve_materials,allocator);if !ok {pose_profile_free(&profile);return {},.Out_Of_Memory}
    return profile,.None
}

Modifier_Kind :: enum u8 {IK,Look,Contact,Grounding,Limit,Chain_IK,Twist,Spring,Multi_IK,Chain_Retarget,Spline_IK,Corrective,Follow}
MODIFIER_TARGETED :: bit_set[Modifier_Kind]{.IK,.Look,.Chain_IK,.Multi_IK,.Spline_IK,.Follow}

// What gameplay gives an operation of a rig's profile, by slot or by name
// (name, and effector_name for Multi IK, are found again when the profile is
// read again). target: where IK, Look, Chain IK, a Multi IK effector, a Spline
// IK control (effector) or Follow aim. position and normal: the hit of
// Contact; position: the external force of Spring.
Modifier_Goal :: struct {
    rig:core.Entity,
    kind:Modifier_Kind,
    slot:u16,
    effector:u8,
    name:[256]u8,
    effector_name:[64]u8,
    target:Spatial_Target,
    position,normal:mm.Vec3,
    weight:f32,
    enabled:bool,
}
@(storage,queue)
Modifier_Requests :: struct {queue:core.Queue(Modifier_Goal),controls:core.Queue(Modifier_Control)}
modifier_goal :: proc(requests:^Modifier_Requests,goal:Modifier_Goal) {
    if requests==nil {return}
    goal:=goal
    if !blend_text_valid(goal.name[:],true) || !blend_text_valid(goal.effector_name[:],true) || goal.kind in MODIFIER_TARGETED && !spatial_target_valid(goal.target) ||
        goal.rig==core.NONE || goal.slot>=POSE_CONSTRAINTS || goal.kind==.Grounding && goal.slot!=0 || goal.kind==.Multi_IK && int(goal.effector)>=RIG_EFFECTORS || goal.kind==.Spline_IK && int(goal.effector)>=len(SPLINE_CONTROLS) || goal.kind>max(Modifier_Kind) || !profile_vector(goal.position) || !profile_vector(goal.normal) || !profile_weight(goal.weight) {
        core.refuse(&requests.queue)
        return
    }
    core.offer(&requests.queue,goal)
}

Retarget_Link :: struct {entity,source:core.Entity,profile:base.Asset_Id}

@(storage,free="modifier_runtime_free")
Modifier_Runtime :: struct {
    ik:core.Table(IK_Constraint),
    look:core.Table(Look_Constraint),
    limits:core.Table(Rotation_Constraint),
    feet:core.Table(Foot_Contact_Constraint),
    grounding:core.Table(Foot_Grounding),
    retargets:core.Table(Retarget_Mapping),
    sockets:core.Table(Bone_Binding),
    chain_ik:core.Table(Chain_IK_Constraint),
    twist:core.Table(Twist_Constraint),
    springs:core.Table(Spring_Constraint),
    multi_ik:core.Table(Multi_IK_Constraint),
    retarget_chains:core.Table(Chain_Retarget_Constraint),
    spline_ik:core.Table(Spline_IK_Constraint),
    correctives:core.Table(Pose_Corrective),
    follow:core.Table(Follow_Constraint),
    curve_poses:core.Table(Curve_Pose),
    curve_drives:core.Table(Curve_Drive),
    curve_materials:core.Table(Curve_Material),
    spline_states:[dynamic]Spline_IK_Binding,
    corrective_states:[dynamic]Pose_Corrective_Binding,
    follow_states:[dynamic]Follow_Binding,
    curve_pose_states,curve_drive_states,curve_material_states:[dynamic]Curve_Binding,
    curve_full:[dynamic]lib.Pose_Accumulator, // by bone of the rig being evaluated: the full poses of its curves
    chain_states:[dynamic]Chain_IK_Binding,
    twist_states:[dynamic]Twist_Binding,
    spring_states:[dynamic]Spring_Binding,
    multi_states:[dynamic]Multi_IK_Binding,
    retarget_chain_states:[dynamic]Chain_Retarget_Binding,
    geometry:u64,
    inputs:[8]u64,
    revisions:[dynamic]u64,
    sources:[dynamic]Retarget_Link,
    source_rows:[dynamic]i32,
    goals:[dynamic]Modifier_Goal,
    controls:[dynamic]Modifier_Control_State,
    fades:[dynamic]u32,
    request_error:Modifier_Request_Error, // of the last refused goal or control, and its rig
    request_error_rig:core.Entity,
}
modifier_runtime_free :: proc(runtime:^Modifier_Runtime) {
    core.table_destroy(&runtime.spline_ik);core.table_destroy(&runtime.correctives);core.table_destroy(&runtime.follow)
    core.table_destroy(&runtime.curve_poses);core.table_destroy(&runtime.curve_drives);core.table_destroy(&runtime.curve_materials);delete(runtime.curve_pose_states);delete(runtime.curve_drive_states);delete(runtime.curve_material_states);delete(runtime.curve_full)
    for &binding in runtime.spline_states {rig_binding_free(&binding)};delete(runtime.spline_states)
    for &binding in runtime.follow_states {rig_binding_free(&binding)};delete(runtime.follow_states)
    delete(runtime.corrective_states)
    core.table_destroy(&runtime.chain_ik);core.table_destroy(&runtime.twist);core.table_destroy(&runtime.springs);core.table_destroy(&runtime.multi_ik);core.table_destroy(&runtime.retarget_chains)
    for &binding in runtime.chain_states {rig_binding_free(&binding)};delete(runtime.chain_states)
    for &binding in runtime.twist_states {rig_binding_free(&binding)};delete(runtime.twist_states)
    for &binding in runtime.spring_states {rig_binding_free(&binding)};delete(runtime.spring_states)
    for &binding in runtime.multi_states {rig_binding_free(&binding)};delete(runtime.multi_states)
    for &binding in runtime.retarget_chain_states {rig_binding_free(&binding)};delete(runtime.retarget_chain_states)
    core.table_destroy(&runtime.ik);core.table_destroy(&runtime.look);core.table_destroy(&runtime.limits);core.table_destroy(&runtime.feet)
    core.table_destroy(&runtime.grounding);core.table_destroy(&runtime.retargets);core.table_destroy(&runtime.sockets)
    delete(runtime.goals);delete(runtime.sources);delete(runtime.source_rows);delete(runtime.revisions);delete(runtime.controls);delete(runtime.fades);runtime^={}
}

@(private)
modifier_append :: proc(table:^core.Table($T),entity:core.Entity,value:T) -> bool {
    count:=len(table.values)
    if existing:=core.row_of(table,entity);existing>=0 && existing!=count-1 {return false}
    return core.table_append(table,entity,value)
}

@(private)
modifier_sources_changed :: proc(runtime:^Modifier_Runtime,animations:core.Read(Animation),version,layout:u64) -> bool {
    if layout!=runtime.inputs[5] {
        count:=0
        for &value,row in animations.table.values[:core.count(animations)] {
            if value.source==core.NONE || value.retarget=={} {continue}
            if count>=len(runtime.sources) || runtime.sources[count]!=(Retarget_Link{core.entity_at(animations,row),value.source,value.retarget}) {return true}
            count+=1
        }
        return count!=len(runtime.sources)
    }
    if version==runtime.inputs[4] {return false}
    for &value,row in animations.table.values[:core.count(animations)] {
        if core.stamp(animations,row)<=runtime.inputs[4] {continue}
        entity:=core.entity_at(animations,row);index:=core.entity_index(entity)
        slot:=int(runtime.source_rows[index])-1 if index<len(runtime.source_rows) else -1
        found:=slot>=0 && slot<len(runtime.sources) && runtime.sources[slot].entity==entity
        if value.source==core.NONE || value.retarget=={} {if found {return true};continue}
        if !found || runtime.sources[slot].source!=value.source || runtime.sources[slot].profile!=value.retarget {return true}
    }
    return false
}

modifier_prepare :: proc(runtime:^Modifier_Runtime,configs:core.Read(Pose_Modifiers),animations:core.Read(Animation),attachments:core.Read(Bone_Attachment),assets:^Pose_Assets,skeletons:^Skeleton_Assets,playback:^Playback,loaded:^host.Assets,allocator:mem.Allocator,problems:^core.Problems) -> bool {
    allocation_failed :: proc(cache:^$T,id:base.Asset_Id) -> bool {
        if cache==nil || id=={} {return false}
        for content in cache.contents {if content.id==id {return content.checked==0}}
        return true
    }
    headers:=[8]u64{core.version(configs),core.layout(configs),core.version(attachments),core.layout(attachments),core.version(animations),core.layout(animations),playback.rigs_stamp,assets_stamp(loaded)}
    if runtime.inputs==headers {return true}
    definitions_changed:=runtime.inputs[0]!=headers[0] || runtime.inputs[1]!=headers[1] || runtime.inputs[2]!=headers[2] || runtime.inputs[3]!=headers[3] || runtime.inputs[6]!=headers[6]
    sources_changed:=modifier_sources_changed(runtime,animations,headers[4],headers[5])
    if !definitions_changed && !sources_changed && runtime.inputs[7]==headers[7] {runtime.inputs=headers;return true}
    revisions_changed:=false;revision_row:=0
    compare_revision :: proc(runtime:^Modifier_Runtime,row:^int,revision:u64,changed:^bool) {
        if row^>=len(runtime.revisions) || runtime.revisions[row^]!=revision {changed^=true}
        row^+=1
    }
    for row in 0..<core.count(configs) {
        id:=configs.table.values[row].profile;revision:u64
        if content:=pose_content(assets,loaded,allocator,id);content!=nil {revision=content.revision} else if allocation_failed(assets,id) {memory_problem(problems,core.entity_at(configs,row),"its pose profile");return false}
        compare_revision(runtime,&revision_row,revision,&revisions_changed)
    }
    for row in 0..<(core.count(animations) if sources_changed else len(runtime.sources)) {
        id:base.Asset_Id;entity:core.Entity
        if sources_changed {value:=&animations.table.values[row];if value.source==core.NONE || value.retarget=={} {continue};id,entity=value.retarget,core.entity_at(animations,row)} else {id,entity=runtime.sources[row].profile,runtime.sources[row].entity}
        revision:u64
        if content:=pose_content(assets,loaded,allocator,id);content!=nil {revision=content.revision} else if allocation_failed(assets,id) {memory_problem(problems,entity,"its retarget profile");return false}
        compare_revision(runtime,&revision_row,revision,&revisions_changed)
    }
    for &rig in playback.rigs {
        revision:u64
        if content:=skeleton_content(skeletons,loaded,allocator,rig.skeleton);content!=nil {revision=content.revision} else if allocation_failed(skeletons,rig.skeleton) {memory_problem(problems,rig.entity,"its skeleton");return false}
        compare_revision(runtime,&revision_row,revision,&revisions_changed)
    }
    revisions_changed ||= revision_row!=len(runtime.revisions)
    if !definitions_changed && !sources_changed && !revisions_changed {runtime.inputs=headers;return true}
    next:=Modifier_Runtime{geometry=runtime.geometry+1,inputs=headers};defer modifier_runtime_free(&next)
    if reserve(&next.revisions,revision_row)!=nil {memory_problem(problems,core.NONE,"the pose profiles of the rigs, so none applies");return false}
    next.ik.version,next.look.version,next.limits.version,next.feet.version=runtime.ik.version+1,runtime.look.version+1,runtime.limits.version+1,runtime.feet.version+1
    next.grounding.version,next.retargets.version,next.sockets.version=runtime.grounding.version+1,runtime.retargets.version+1,runtime.sockets.version+1
    next.ik.layout,next.look.layout,next.limits.layout,next.feet.layout=runtime.ik.layout+1,runtime.look.layout+1,runtime.limits.layout+1,runtime.feet.layout+1
    next.grounding.layout,next.retargets.layout,next.sockets.layout=runtime.grounding.layout+1,runtime.retargets.layout+1,runtime.sockets.layout+1
    for row in 0..<core.count(configs) {
        entity:=core.entity_at(configs,row);config:=core.at(configs,row)
        content:=pose_content(assets,loaded,allocator,config.profile);append(&next.revisions,content.revision if content!=nil else 0)
        if content==nil {
            if allocation_failed(assets,config.profile) {memory_problem(problems,entity,"its pose profile");return false}
            if config.profile!={} {asset_problem(problems,entity,loaded,"animation.pose_profile","Pose_Modifiers.profile",config.profile,content_error(assets.contents[:],config.profile))}
            continue
        }
        if !profile_weight(config.weight) {
            core.report(problems,entity,"animation.pose_weight","Pose_Modifiers.weight of this rig is %f, so its pose profile does nothing; give it 0 to 1",config.weight)
            continue
        }
        appended:=true
        for value in content.profile.ik {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.ik,entity,value)}
        for value in content.profile.look {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.look,entity,value)}
        for value in content.profile.limits {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.limits,entity,value)}
        for value in content.profile.contacts {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.feet,entity,value)}
        for value in content.profile.grounding {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.grounding,entity,value)}
        for value in content.profile.chain_ik {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.chain_ik,entity,value)}
        for value in content.profile.twist {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.twist,entity,value)}
        for value in content.profile.springs {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.springs,entity,value)}
        for value in content.profile.multi_ik {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.multi_ik,entity,value)}
        for value in content.profile.spline_ik {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.spline_ik,entity,value)}
        for value in content.profile.correctives {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.correctives,entity,value)}
        for value in content.profile.follow {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.follow,entity,value)}
        for value in content.profile.curve_poses {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.curve_poses,entity,value)}
        for value in content.profile.curve_drives {value:=value;value.rig=entity;value.weight*=config.weight;value.enabled &&=config.enabled;appended &&=modifier_append(&next.curve_drives,entity,value)}
        for value in content.profile.curve_materials {value:=value;value.rig=entity;value.enabled &&=config.enabled;appended &&=modifier_append(&next.curve_materials,entity,value)}
        if !appended {memory_problem(problems,entity,"its pose profile");return false}
    }
    for row in 0..<core.count(animations) {
        entity:=core.entity_at(animations,row);config:=&animations.table.values[row]
        if config.source==core.NONE || config.retarget=={} {continue}
        if append(&next.sources,Retarget_Link{entity,config.source,config.retarget})!=1 {memory_problem(problems,entity,"its retarget profile");return false}
        index:=core.entity_index(entity);if index>=len(next.source_rows) && resize(&next.source_rows,index+1)!=nil {memory_problem(problems,entity,"its retarget profile");return false};next.source_rows[index]=i32(len(next.sources))
        content:=pose_content(assets,loaded,allocator,config.retarget);append(&next.revisions,content.revision if content!=nil else 0)
        if content==nil {
            if allocation_failed(assets,config.retarget) {memory_problem(problems,entity,"its retarget profile");return false}
            asset_problem(problems,entity,loaded,"animation.retarget_profile","Animation.retarget",config.retarget,content_error(assets.contents[:],config.retarget))
            continue
        }
        appended:=true
        for value in content.profile.retarget {value:=value;value.rig,value.source=entity,config.source;appended &&=modifier_append(&next.retargets,entity,value)}
        for value in content.profile.retarget_chains {value:=value;value.rig,value.source=entity,config.source;appended &&=modifier_append(&next.retarget_chains,entity,value)}
        if !appended {memory_problem(problems,entity,"its retarget profile");return false}
    }
    for &rig in playback.rigs {
        content:=skeleton_content(skeletons,loaded,allocator,rig.skeleton);append(&next.revisions,content.revision if content!=nil else 0)
        if content==nil && allocation_failed(skeletons,rig.skeleton) {memory_problem(problems,rig.entity,"its skeleton");return false}
    }
    for row in 0..<core.count(attachments) {
        entity:=core.entity_at(attachments,row);config:=core.at(attachments,row)
        if !config.enabled {continue}
        definition:^Skeleton_Content
        rigged:=false
        for rig in playback.rigs {if rig.entity==config.rig {rigged=true;definition=skeleton_content(skeletons,loaded,allocator,rig.skeleton);if definition==nil && allocation_failed(skeletons,rig.skeleton) {memory_problem(problems,rig.entity,"its skeleton");return false};break}}
        if !rigged {
            core.report(problems,entity,"animation.attachment_rig","this Bone_Attachment hangs from entity 0x%016x, which shows no mesh with a skeleton; name an entity whose Mesh_Renderer shows a skinned mesh",u64(config.rig))
            continue
        }
        if definition==nil {continue}
        attached:=false
        for socket in definition.sockets {
            if socket.name!=config.socket {continue}
            value:=Bone_Binding{rig=config.rig,bone={socket.bone},offset=mm.transform_compose(socket.offset,config.offset),enabled=true}
            if !modifier_append(&next.sockets,entity,value) {memory_problem(problems,entity,"its attachment");return false}
            attached=true
            break
        }
        if !attached {
            name:[base.ASSET_ID_TEXT]u8
            core.report(problems,entity,"animation.attachment_socket","this Bone_Attachment names socket '%s', which skeleton %s of its rig does not have; name one of its sockets (animation.asset.inspect lists them)",base.text_get(config.socket[:]),host.assets_name(loaded,definition.id,&name))
        }
    }
    if !modifier_controls_prepare(&next,runtime) || reserve(&runtime.goals,len(next.controls))!=nil {memory_problem(problems,core.NONE,"the controls of the pose profiles, so none applies");return false}
    // A goal stays with its operation; one whose slot now names another goes.
    #reverse for goal,i in runtime.goals {if !modifier_same_goal(runtime,&next,goal) {unordered_remove(&runtime.goals,i)}}
    next.goals=runtime.goals;runtime.goals=nil
    request_error,request_error_rig:=runtime.request_error,runtime.request_error_rig
    modifier_runtime_free(runtime);runtime^=next;next={}
    runtime.request_error,runtime.request_error_rig=request_error,request_error_rig
    #reverse for goal,i in runtime.goals {
        config,ok:=core.get(configs,goal.rig)
        if !ok && goal.kind!=.Chain_Retarget || modifier_control_state(runtime,goal.rig,goal.kind,goal.slot)==nil {unordered_remove(&runtime.goals,i);continue}
        modifier_apply_goal(runtime,goal,problems,config.weight if ok else 1,config.enabled if ok else true)
    }
    for &control in runtime.controls {modifier_control_apply(runtime,&control)}
    return true
}

modifier_apply_goal :: proc(runtime:^Modifier_Runtime,goal:Modifier_Goal,problems:^core.Problems,weight:f32=1,enabled:bool=true) {
    scaled:=goal.weight*weight
    control:=modifier_control_state(runtime,goal.rig,goal.kind,goal.slot)
    active:=goal.enabled && enabled
    if control!=nil {
        control.base_enabled=active
        if goal.kind!=.Contact && goal.kind!=.Grounding {control.base_weight=scaled}
        scaled*=control.weight
        active &&=control.enabled || control.weight>0
    }
    #partial switch goal.kind {
    case .IK:
        if row:=rig_slot_row(&runtime.ik,goal.rig,goal.slot);row>=0 {
            value:=&runtime.ik.values[row]
            if value.target!=goal.target || value.weight!=scaled || value.enabled!=active {
                out:=core.at(&runtime.ik,row)
                out.target=goal.target
                out.weight,out.enabled=scaled,active
            }
        }
    case .Look:
        if row:=rig_slot_row(&runtime.look,goal.rig,goal.slot);row>=0 {
            value:=&runtime.look.values[row]
            if value.target!=goal.target || value.weight!=scaled || value.enabled!=active {
                out:=core.at(&runtime.look,row)
                out.target=goal.target
                out.weight,out.enabled=scaled,active
            }
        }
    case .Contact:
        if row:=rig_slot_row(&runtime.feet,goal.rig,goal.slot);row>=0 {
                value:=&runtime.feet.values[row]
                if value.hit_position!=goal.position || value.hit_normal!=goal.normal || value.contact!=goal.weight || value.grounded!=goal.enabled || value.enabled!=active {
                    out:=core.at(&runtime.feet,row);out.hit_position,out.hit_normal,out.contact,out.grounded,out.enabled=goal.position,goal.normal,goal.weight,goal.enabled,active
                }
        }
    case .Grounding:
        if row:=rig_slot_row(&runtime.grounding,goal.rig,goal.slot);row>=0 {value:=&runtime.grounding.values[row];if value.global_contact!=goal.weight || value.enabled!=active {out:=core.at(&runtime.grounding,row);out.global_contact,out.enabled=goal.weight,active}}
    case .Limit:
        if row:=rig_slot_row(&runtime.limits,goal.rig,goal.slot);row>=0 {value:=&runtime.limits.values[row];if value.enabled!=active || value.weight!=scaled {out:=core.at(&runtime.limits,row);out.enabled,out.weight=active,scaled}}
    case .Chain_IK,.Twist,.Spring,.Multi_IK,.Chain_Retarget,.Spline_IK,.Corrective,.Follow:
        rigs_apply_goal(runtime,goal,scaled,active,problems)
    }
}
modifier_take :: proc(runtime:^Modifier_Runtime,requests:^Modifier_Requests,configs:core.Read(Pose_Modifiers),problems:^core.Problems,dt:f32=0) {
    #reverse for goal,i in runtime.goals {if !core.has(configs,goal.rig) && goal.kind!=.Chain_Retarget {unordered_remove(&runtime.goals,i)}}
    for goal in core.take(&requests.queue) {
        goal:=goal
        if error:=modifier_goal_resolve(runtime,&goal);error!=.None {
            modifier_request_rejected(runtime,goal.rig,error)
            modifier_name_problem(problems,goal.rig,goal.kind,goal.name[:],goal.effector_name[:],error)
            continue
        }
        if !core.has(configs,goal.rig) && goal.kind!=.Chain_Retarget {
            core.report(problems,goal.rig,"animation.modifier_owner","a goal for %v %d was given for this entity, and it has no Pose_Modifiers; give it one with a pose profile, or give the goal to the rig that has it",goal.kind,goal.slot)
            continue
        }
        if modifier_control_state(runtime,goal.rig,goal.kind,goal.slot)==nil {
            core.report(problems,goal.rig,"animation.modifier_slot","a goal for %v %d was refused: the pose profile of this rig has no such operation; name one it has (animation.inspect lists them)",goal.kind,goal.slot)
            continue
        }
        index:=-1
        for known,i in runtime.goals {if known.rig==goal.rig && known.kind==goal.kind && known.slot==goal.slot && known.effector==goal.effector {index=i;break}}
        if index>=0 {runtime.goals[index]=goal} else if append(&runtime.goals,goal)!=1 {memory_problem(problems,goal.rig,"a goal of its pose profile");continue}
        config,ok:=core.get(configs,goal.rig)
        modifier_apply_goal(runtime,goal,problems,config.weight if ok else 1,config.enabled if ok else true)
    }
    modifier_controls_take(runtime,requests,problems,dt)
}

@(step="fixed",loops="game editor",stage="apply")
animation_sample :: proc(animations:core.Read(Animation),progress:^core.Table(Animation_Progress),configs:core.Read(Pose_Modifiers),attachments:core.Read(Bone_Attachment),transforms:^core.Table(core.Transform),parents:core.Read(core.Parent),hierarchy:core.Ref(core.Hierarchy),names:core.Read(core.Name),targets:core.Read(Animation_Target),meshes:core.Read(erender.Mesh_Renderer),sources:core.Read(Pose_Source),requests:^Animation_Requests,events:^Animation_Events,goals:^Modifier_Requests,runtime:^Modifier_Runtime,playback:^Playback,assets:^Pose_Assets,skeletons:^Skeleton_Assets,app:^host.App,time:core.Time,frame:core.Frame_Time,problems:^core.Problems,blends:^Blend_Assets,matches:^Match_Assets,actions:^Action_Runtime,action_assets:^Actions_Assets,motion:^Motion_Runtime,motion_requests:^Motion_Requests,motion_assets:^Motion_Assets,content_sources:^Source_Assets,paces:core.Read(core.Own_Pace),clock:core.Clock,budget:Animation_Budget_Config) {
    if app.assets==nil {playback.frame+=1;clear(&events.items);return}
    if !rigs_update(playback,meshes,sources,app.assets) {memory_problem(problems,core.NONE,"the list of rigs, so nothing is animated in this tick");playback.frame+=1;clear(&events.items);return}
    if !modifier_prepare(runtime,configs,animations,attachments,assets,skeletons,playback,app.assets,app.allocator,problems) {playback.frame+=1;clear(&events.items);return}
    // A look is a goal of the first Look of the pose profile.
    for goal in core.take(&requests.looks) {modifier_goal(goals,goal)}
    modifier_take(runtime,goals,configs,problems)
    if time.playing {progress_resume(progress,playback,requests)}
    animation_tick(animations,transforms,parents,hierarchy,names,requests,events,targets,{},playback,app,time,frame,skeletons,problems,blends,matches,actions,action_assets,motion,motion_requests,motion_assets,content_sources,paces,clock,budget)
    if time.playing {progress_write(progress,animations,playback)}
}

// A clip that a loaded game left somewhere starts there: Playback starts
// again with the World, and an entity it has no state for seeks its progress.
@(private)
progress_resume :: proc(progress:^core.Table(Animation_Progress),playback:^Playback,requests:^Animation_Requests) {
    for row in 0..<core.count(progress) {
        e:=core.entity_at(progress,row)
        if constraint_playing(playback,e)!=nil {continue}
        kept:=core.at(core.read(progress),row)
        #partial switch kept.transport {
        case .Play: animation_command(requests,e,.Resume)
        case .Pause: animation_command(requests,e,.Pause)
        }
        animation_seek(requests,e,kept.time)
    }
}

// Where each clip is, for a saved game; an entity that lost its Animation loses it.
@(private)
progress_write :: proc(progress:^core.Table(Animation_Progress),animations:core.Read(Animation),playback:^Playback) {
    for row in 0..<core.count(progress) {
        if e:=core.entity_at(progress,row);!core.has(animations,e) {core.remove(progress,e)}
    }
    for row in 0..<core.count(animations) {
        e:=core.entity_at(animations,row)
        clip_time,_,_,ok:=animation_progress(playback,e)
        if !ok {continue}
        now:=Animation_Progress{clip_time,constraint_playing(playback,e).transport}
        if at:=core.row_of(progress,e);at<0 {
            core.add(progress,e,now)
        } else if core.at(core.read(progress),at)!=now {
            core.at(progress,at)^=now
        }
    }
}

@(step="fixed",loops="game editor",stage="react")
animation_advance :: proc(configs:core.Read(Pose_Modifiers),transforms:^core.Table(core.Transform),parents:core.Read(core.Parent),worlds:core.Read(core.World_Transform),requests:^Modifier_Requests,runtime:^Modifier_Runtime,playback:^Playback,constraints:^Animation_Constraints,grounding:^Grounding_Runtime,world:core.World_Ref,queries:core.Ref(core.World_Queries),time:core.Time,poses:^Animation_Requests,skeletons:core.Ref(Skeleton_Assets),problems:^core.Problems,motion:^Motion_Runtime,motion_assets:^Motion_Assets,verticals:core.Read(core.Vertical),paces:core.Read(core.Own_Pace),clock:core.Clock,places:^core.Places) {
    modifier_take(runtime,requests,configs,problems,time.dt)
    inputs:=Constraint_Inputs{core.read(&runtime.ik),core.read(&runtime.look),core.read(&runtime.limits),core.read(&runtime.feet),core.read(&runtime.sockets),core.read(&runtime.retargets),{},worlds,runtime.geometry,skeletons.ptr,problems}
    ground_inputs:=Grounding_Inputs{core.read(&runtime.grounding),core.world_query(world,queries),core.read(transforms),parents,runtime.geometry,problems,verticals}
    animation_finish(playback,inputs,constraints,transforms,parents,time.dt,grounding,ground_inputs,runtime,motion,motion_assets,core.take(&poses.final_poses),paces,clock,places)
}
