package anim

import "core:mem"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"

POSE_CONSTRAINTS :: 256

@(component,description="Attaches this entity to a named bone or socket in another entity's skeleton, with an additional local offset.")
Bone_Attachment :: struct {
    rig:core.Entity,
    socket:[64]u8 `mirai:"text"`,
    offset:mm.Transform,
    enabled:bool,
    bone:Bone_Ref `mirai:"optional"`,
}
BONE_ATTACHMENT_DEFAULT :: Bone_Attachment{offset=mm.TRANSFORM_IDENTITY,enabled=true}

// The modifiers of the pose of a .character, applied in this order after it samples: IK and look
// toward their targets, limits, grounding, the rigs and the curves of faces. retarget_chains map
// the pose the rig takes from another (Pose_Source, stage Sampled) chain by chain.
Pose_Profile :: struct {
    ik:[]IK_Constraint,
    look:[]Look_Constraint,
    limits:[]Rotation_Constraint,
    grounding:Foot_Grounding,
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
    if len(profile.ik)>POSE_CONSTRAINTS || len(profile.look)>POSE_CONSTRAINTS || len(profile.limits)>POSE_CONSTRAINTS {return false}
    for &value in profile.ik {
        if !profile_bone(value.root) || !profile_bone(value.joint) || !profile_bone(value.end) || !spatial_target_valid(spatial_compile(&value.target),false) || !profile_vector(value.pole) || !profile_weight(value.weight) {return false}
        if !finite(value.reach.soft_distance) || value.reach.soft_distance<0 || !finite(value.reach.max_stretch) || value.reach.max_stretch<0 {return false}
    }
    for &value in profile.look {
        if !profile_bone(value.bone) || !spatial_target_valid(spatial_compile(&value.target),false) || !profile_vector(value.forward) || !profile_vector(value.offset) || !finite(value.max_angle) || value.max_angle<0 || !profile_weight(value.weight) {return false}
        if value.use_up {_,ok:=lib.aim_at(1,value.forward,{0,0,-1},value.up,value.world_up,value.max_angle);if !ok {return false}}
    }
    for value in profile.limits {
        if !profile_bone(value.bone) || !profile_vector(value.axis) || !finite(value.max_swing) || !finite(value.min_twist) || !finite(value.max_twist) || value.min_twist>value.max_twist || !profile_weight(value.weight) {return false}
        if !profile_rotation(value.reference) {return false}
    }
    if value:=profile.grounding;len(value.legs)>0 {
        if !grounding_config_valid(value) || !profile_bone(value.body) {return false}
        for leg in value.legs {if !profile_bone(leg.hip) || !profile_bone(leg.knee) || !profile_bone(leg.foot) || !profile_bone(leg.contact_bone) {return false}}
    }
    return rig_profiles_check(profile) && curve_poses_check(profile)
}
@(private) profile_bone :: proc(value:Bone_Ref) -> bool {_,ok:=bone_ref_hash(value);return ok}
@(private) profile_weight :: proc "contextless" (value:f32) -> bool {return finite(value) && value>=0 && value<=1}
@(private) profile_vector :: proc "contextless" (value:mm.Vec3) -> bool {for number in value {if !finite(number) {return false}};return true}
@(private) profile_rotation :: proc "contextless" (value:mm.Quat) -> bool {return abs(value.x*value.x+value.y*value.y+value.z*value.z+value.w*value.w-1)<1e-3}

Modifier_Kind :: enum u8 {IK,Look,Grounding,Limit,Chain_IK,Twist,Spring,Multi_IK,Chain_Retarget,Spline_IK,Corrective,Follow}
MODIFIER_TARGETED :: bit_set[Modifier_Kind]{.IK,.Look,.Chain_IK,.Multi_IK,.Spline_IK,.Follow}

@(storage,free="modifier_runtime_free")
Modifier_Runtime :: struct {
    rigs:[dynamic]Modifier_Rig,
    rows:[dynamic]i32,
    curve_full:[dynamic]lib.Pose_Accumulator,
    inputs:[7]u64,
    time:f64,
    request_error:Modifier_Request_Error,
    request_error_rig:core.Entity,
}

Modifier_Rig :: struct {
    entity:core.Entity,
    asset:base.Asset_Id,
    revision:u64,
    character:i32,
    controls:[dynamic]Modifier_Control_State,
    first:[len(Modifier_Kind)+1]u16,
    overrides:[dynamic]Modifier_Request,
    ik_states:[dynamic]IK_Binding,
    look_states:[dynamic]Look_Binding,
    limit_states:[dynamic]Limit_Binding,
    attachments:[dynamic]Attachment_Binding,
    grounding:[dynamic]Grounding_Binding,
    chain_states:[dynamic]Chain_IK_Binding,
    twist_states:[dynamic]Twist_Binding,
    spring_states:[dynamic]Spring_Binding,
    multi_states:[dynamic]Multi_IK_Binding,
    retarget_chain_states:[dynamic]Chain_Retarget_Binding,
    spline_states:[dynamic]Spline_IK_Binding,
    corrective_states:[dynamic]Pose_Corrective_Binding,
    follow_states:[dynamic]Follow_Binding,
    curve_pose_states,curve_drive_states,curve_material_states:[dynamic]Curve_Binding,
}

modifier_runtime_free :: proc(runtime:^Modifier_Runtime) {
    for &rig in runtime.rigs {modifier_rig_free(&rig)}
    delete(runtime.rigs);delete(runtime.rows);delete(runtime.curve_full)
    runtime^={}
}

@(private)
modifier_rig_free :: proc(rig:^Modifier_Rig) {
    free_states :: proc(states:[dynamic]$T) {
        for &state in states {rig_binding_free(&state)}
        delete(states)
    }
    delete(rig.controls);delete(rig.overrides);delete(rig.attachments)
    free_states(rig.ik_states);free_states(rig.look_states);delete(rig.limit_states)
    for &record in rig.grounding {delete(record.links)}
    delete(rig.grounding)
    free_states(rig.chain_states);free_states(rig.twist_states);free_states(rig.spring_states)
    free_states(rig.multi_states);free_states(rig.retarget_chain_states)
    free_states(rig.spline_states);delete(rig.corrective_states);free_states(rig.follow_states)
    delete(rig.curve_pose_states);delete(rig.curve_drive_states);delete(rig.curve_material_states)
    rig^={}
}

modifier_rig :: proc(runtime:core.Ref(Modifier_Runtime),entity:core.Entity) -> ^Modifier_Rig {
    if runtime.ptr==nil {return nil}
    index:=core.entity_index(entity)
    if index>=len(runtime.rows) || runtime.rows[index]<=0 {return nil}
    row:=int(runtime.rows[index])-1
    if row>=len(runtime.rigs) {return nil}
    rig:=&runtime.rigs[row]
    return rig if rig.entity==entity else nil
}

@(private)
modifier_rig_add :: proc(runtime:^Modifier_Runtime,entity:core.Entity) -> ^Modifier_Rig {
    if rig:=modifier_rig(core.ref(runtime),entity);rig!=nil {return rig}
    index:=core.entity_index(entity)
    if index>=len(runtime.rows) && !program_array_resize(&runtime.rows,index+1) {return nil}
    if append(&runtime.rigs,Modifier_Rig{entity=entity})!=1 {return nil}
    runtime.rows[index]=i32(len(runtime.rigs))
    return &runtime.rigs[len(runtime.rigs)-1]
}

@(private)
modifier_rig_remove :: proc(runtime:^Modifier_Runtime,row:int) {
    rig:=&runtime.rigs[row]
    index:=core.entity_index(rig.entity)
    if runtime.rows[index]==i32(row+1) {runtime.rows[index]=0}
    modifier_rig_free(rig)
    unordered_remove(&runtime.rigs,row)
    if row<len(runtime.rigs) {runtime.rows[core.entity_index(rig.entity)]=i32(row+1)}
}

@(private)
modifier_pose :: proc(rig:^Modifier_Rig,characters:^Character_Assets) -> ^Pose_Profile {
    if rig==nil || characters==nil || rig.character<=0 ||
        int(rig.character)>len(characters.contents) {return nil}
    content:=&characters.contents[rig.character-1]
    if content.valid && content.id==rig.asset && content.revision==rig.revision {
        return &content.set.pose
    }
    return nil
}

@(private)
modifier_rig_prepare :: proc(rig:^Modifier_Rig,pose:Pose_Profile,id:base.Asset_Id,revision:u64,character:i32) -> bool {
    next:=Modifier_Rig{entity=rig.entity,asset=id,revision=revision,character=character}
    defer modifier_rig_free(&next)
    ground:=1 if len(pose.grounding.legs)>0 else 0
    if resize(&next.ik_states,len(pose.ik))!=nil || resize(&next.look_states,len(pose.look))!=nil ||
        resize(&next.limit_states,len(pose.limits))!=nil || resize(&next.grounding,ground)!=nil ||
        resize(&next.chain_states,len(pose.chain_ik))!=nil ||
        resize(&next.twist_states,len(pose.twist))!=nil ||
        resize(&next.spring_states,len(pose.springs))!=nil ||
        resize(&next.multi_states,len(pose.multi_ik))!=nil ||
        resize(&next.retarget_chain_states,len(pose.retarget_chains))!=nil ||
        resize(&next.spline_states,len(pose.spline_ik))!=nil ||
        resize(&next.corrective_states,len(pose.correctives))!=nil ||
        resize(&next.follow_states,len(pose.follow))!=nil ||
        resize(&next.curve_pose_states,len(pose.curve_poses))!=nil ||
        resize(&next.curve_drive_states,len(pose.curve_drives))!=nil ||
        resize(&next.curve_material_states,len(pose.curve_materials))!=nil {return false}
    if !modifier_controls_prepare(&next,rig,pose) {return false}
    next.attachments=rig.attachments;rig.attachments=nil
    modifier_rig_free(rig)
    rig^=next;next={}
    return true
}

modifier_prepare :: proc(runtime:^Modifier_Runtime,animations:^core.Table(Animation,$A),
    attachments:^core.Table(Bone_Attachment,$B),characters:^Character_Assets,
    skeletons:^Skeleton_Assets,playback:^Playback,loaded:^host.Assets,allocator:mem.Allocator,
    problems:^core.Problems,meshes:^core.Table(erender.Mesh_Renderer,.Read)=nil) -> bool {
    if loaded==nil {return false}
    context.allocator=allocator
    revision:=assets_stamp(loaded)
    headers:=[7]u64{core.layout(animations),core.version(animations),revision,
        core.layout(attachments),core.version(attachments),playback.rigs_stamp,loaded.structure}
    if runtime.inputs==headers {return true}
    pending:=false
    if runtime.inputs[0]!=headers[0] || runtime.inputs[1]!=headers[1] || runtime.inputs[2]!=headers[2] {
        if characters==nil {return false}
        for row in 0..<core.count(animations) {
            entity:=core.entity_at(animations,row)
            id:=animation_character(loaded,core.at(animations,row))
            if id=={} {continue}
            rig:=modifier_rig(core.ref(runtime),entity)
            hint:=rig.character if rig!=nil else 0
            content:=character_content(characters,loaded,allocator,id,&hint)
            if content==nil {
                error:=content_error(characters.contents[:],id)
                if hint==0 || error==.Out_Of_Memory {
                    memory_problem(problems,entity,"its .character modifiers");return false
                }
                if error==.Not_Here {pending=true;continue}
                asset_problem(problems,entity,loaded,"animation.character","Animation.asset",id,error)
                if rig!=nil && rig.asset!={} && !modifier_rig_prepare(rig,{},{},0,0) {return false}
                continue
            }
            if rig!=nil && rig.asset==id && rig.revision==content.revision {continue}
            pose:=content.set.pose
            if !has_modifiers(pose) {
                if rig!=nil && rig.asset!={} && !modifier_rig_prepare(rig,{},{},0,0) {return false}
                continue
            }
            if rig==nil {
                rig=modifier_rig_add(runtime,entity)
                if rig==nil {memory_problem(problems,entity,"its .character modifiers");return false}
            }
            if rig!=nil && !modifier_rig_prepare(rig,pose,id,content.revision,hint) {
                memory_problem(problems,entity,"its .character modifiers");return false
            }
        }
        for &rig in runtime.rigs {
            value,found:=core.get(animations,rig.entity)
            if rig.asset!={} && (!found || animation_character(loaded,value)=={}) {
                if !modifier_rig_prepare(&rig,{},{},0,0) {return false}
            }
        }
    }
    if runtime.inputs[2]!=headers[2] || runtime.inputs[3]!=headers[3] ||
        runtime.inputs[4]!=headers[4] || runtime.inputs[5]!=headers[5] ||
        runtime.inputs[6]!=headers[6] {
        if !modifier_attachments_prepare(runtime,attachments,skeletons,playback,loaded,allocator,problems,meshes) {
            memory_problem(problems,core.NONE,"the bone attachments")
            return false
        }
    }
    #reverse for &rig,row in runtime.rigs {
        if rig.asset=={} && len(rig.attachments)==0 {modifier_rig_remove(runtime,row)}
    }
    runtime.inputs=headers
    if pending {runtime.inputs[2]=0}
    return true
}

modifier_grounding :: proc(runtime:core.Ref(Modifier_Runtime),rig:^Modifier_Rig,profile:Foot_Grounding) -> Foot_Grounding {
    config:=profile
    if runtime.ptr==nil || rig==nil || len(modifier_states(rig,.Grounding))==0 {return config}
    config.weight,config.enabled=modifier_weight(&modifier_states(rig,.Grounding)[0],runtime.time)
    if override:=modifier_override(rig,.Grounding,0);override!=nil {
        config.global_contact=override.weight
    }
    return config
}

modifier_profile :: proc(runtime:core.Ref(Modifier_Runtime),characters:core.Ref(Character_Assets),entity:core.Entity) -> ^Pose_Profile {
    return modifier_pose(modifier_rig(runtime,entity),characters.ptr)
}

@(private)
has_modifiers :: proc(pose:Pose_Profile) -> bool {
    return len(pose.ik)+len(pose.look)+len(pose.limits)+len(pose.grounding.legs)+
        len(pose.chain_ik)+len(pose.twist)+len(pose.springs)+len(pose.multi_ik)+
        len(pose.retarget_chains)+len(pose.spline_ik)+len(pose.correctives)+len(pose.follow)+
        len(pose.curve_poses)+len(pose.curve_drives)+len(pose.curve_materials)>0
}

@(step="fixed",loops="game editor",stage="apply")
animation_prepare :: proc(animations:^core.Table(Animation,.Read),
    attachments:^core.Table(Bone_Attachment,.Read),meshes:^core.Table(erender.Mesh_Renderer,.Read),
    sources:^core.Table(Pose_Source,.Read),runtime:^Modifier_Runtime,playback:^Playback,
    characters:^Character_Assets,skeletons:^Skeleton_Assets,app:^host.App,problems:^core.Problems) {
    playback.prepared=false
    if app.assets==nil {return}
    if !rigs_update(playback,meshes,sources,app.assets,attachments) {
        memory_problem(problems,core.NONE,"the list of rigs, so nothing is animated in this tick")
        return
    }
    playback.prepared=modifier_prepare(runtime,animations,attachments,characters,skeletons,playback,
        app.assets,app.allocator,problems,meshes)
}

@(step="fixed",loops="game editor",stage="simulate")
animation_sample :: proc(animations:^core.Table(Animation,.Read),progress:^core.Table(Animation_Progress,.Read),
    played:^core.Table(Animation_Played),transforms:^core.Table(core.Transform),
    parents:^core.Table(core.Parent,.Read),hierarchy:core.Ref(core.Hierarchy),
    names:^core.Table(core.Name,.Read),targets:^core.Table(Animation_Target,.Read),
    remotes:^core.Table(core.Remote,.Read),requests:^Animation_Requests,events:^Animation_Events,
    runtime:^Modifier_Runtime,playback:^Playback,characters:^Character_Assets,
    skeletons:^Skeleton_Assets,app:^host.App,time:core.Time,frame:core.Frame_Time,
    problems:^core.Problems,actions:^Action_Runtime,motion:^Motion_Runtime,
    content_sources:^Source_Assets,paces:^core.Table(core.Own_Pace,.Read),clock:core.Clock,
    budget:Animation_Budget_Config) {
    if !playback.prepared {playback.frame+=1;return}
    modifier_take(runtime,characters,requests,problems,0)
    animation_tick(animations,transforms,parents,hierarchy,names,requests,events,targets,playback,app,time,frame,skeletons,problems,characters,actions,motion,content_sources,remotes,played,paces,clock,budget,progress)
}

playback_save_prepare :: proc(playback:^Playback,world:core.World_Ref) -> bool {
    if playback.previewed {return true}
    progress:=core.world_table_of(world,Animation_Progress)
    animations:=core.world_table_of(world,Animation)
    return progress==nil || animations==nil || progress_write(progress,animations,playback)
}

// Where each clip is, for a saved game; an entity that lost its Animation loses it.
@(private)
progress_write :: proc(progress:^core.Table(Animation_Progress),animations:^core.Table(Animation,$A),playback:^Playback) -> bool {
    for row in 0..<core.count(progress) {
        if e:=core.entity_at(progress,row);!core.has(animations,e) {core.remove(progress,e)}
    }
    for row in 0..<core.count(animations) {
        e:=core.entity_at(animations,row)
        clip_time,_,_,ok:=animation_progress(core.ref(playback),e)
        if !ok {continue}
        state:=constraint_playing(core.ref(playback),e)
        now:=Animation_Progress{time=clip_time,selection=state.selection,speed=state.speed,playing=state.playing}
        if at:=core.row_of(progress,e);at<0 {
            if !core.add(progress,e,now) {return false}
        } else if core.at(progress,at)!=now {
            core.edit_at(progress,at)^=now
        }
    }
    return true
}

@(step="fixed",loops="game editor",stage="react",after="animation_sample animation_fields")
animation_advance :: proc(transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent,.Read),worlds:^core.Table(core.World_Transform,.Read),requests:^Animation_Requests,runtime:^Modifier_Runtime,playback:^Playback,world:core.World_Read,queries:core.Ref(core.World_Queries),time:core.Time,skeletons:core.Ref(Skeleton_Assets),problems:^core.Problems,motion:^Motion_Runtime,characters:^Character_Assets,verticals:^core.Table(core.Vertical,.Read),paces:^core.Table(core.Own_Pace,.Read),clock:core.Clock,places:^core.Places) {
    if !playback.prepared {return}
    modifier_take(runtime,characters,requests,problems,time.dt)
    inputs:=Constraint_Inputs{worlds,skeletons.ptr,problems}
    ground_inputs:=Grounding_Inputs{core.world_query_read(world,queries),core.read(transforms),parents,problems,verticals}
    animation_finish(playback,inputs,runtime,transforms,parents,time.dt,ground_inputs,motion,characters,core.take(&requests.final_poses),paces,clock,places)
}
