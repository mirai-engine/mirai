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

POSE_CONSTRAINTS :: 256

@(component,description="Attaches this entity to a named socket in another entity's skeleton, with an additional local offset.")
Bone_Attachment :: struct {
    rig:core.Entity,
    socket:[64]u8 `mirai:"text"`,
    offset:mm.Transform,
    enabled:bool,
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
    if value:=profile.grounding;value.count>0 {
        if !grounding_config_valid(value) || !profile_bone(value.body) {return false}
        for leg in value.legs[:value.count] {if !profile_bone(leg.hip) || !profile_bone(leg.knee) || !profile_bone(leg.foot) || !profile_bone(leg.contact_bone) {return false}}
    }
    return rig_profiles_check(profile) && curve_poses_check(profile)
}
@(private) profile_bone :: proc(value:Bone_Ref) -> bool {_,ok:=bone_ref_hash(value);return ok}
@(private) profile_weight :: proc "contextless" (value:f32) -> bool {return finite(value) && value>=0 && value<=1}
@(private) profile_vector :: proc "contextless" (value:mm.Vec3) -> bool {for number in value {if !finite(number) {return false}};return true}
@(private) profile_rotation :: proc "contextless" (value:mm.Quat) -> bool {return abs(value.x*value.x+value.y*value.y+value.z*value.z+value.w*value.w-1)<1e-3}

Modifier_Kind :: enum u8 {IK,Look,Grounding,Limit,Chain_IK,Twist,Spring,Multi_IK,Chain_Retarget,Spline_IK,Corrective,Follow}
MODIFIER_TARGETED :: bit_set[Modifier_Kind]{.IK,.Look,.Chain_IK,.Multi_IK,.Spline_IK,.Follow}

// What gameplay gives an operation of a rig's profile, by slot or by name
// (name, and effector_name for Multi IK, are found again when the .character is
// read again). target: where IK, Look, Chain IK, a Multi IK effector, a Spline
// IK control (effector) or Follow aim. position: the external force of Spring. fade: seconds the
// operation takes to reach its weight from the one it has (none while it is off); one that lets go
// keeps its target while it fades out.
Modifier_Goal :: struct {
    rig:core.Entity,
    kind:Modifier_Kind,
    slot:u16,
    effector:u8,
    name:[256]u8,
    effector_name:[64]u8,
    target:Spatial_Target,
    position:mm.Vec3,
    weight,fade:f32,
    enabled:bool,
}
modifier_goal :: proc(requests:^Animation_Requests,goal:Modifier_Goal) {
    if requests==nil {return}
    goal:=goal
    if !blend_text_valid(goal.name[:],true) || !blend_text_valid(goal.effector_name[:],true) || goal.kind in MODIFIER_TARGETED && !spatial_target_valid(goal.target) ||
        goal.rig==core.NONE || goal.slot>=POSE_CONSTRAINTS || goal.kind==.Grounding && goal.slot!=0 || goal.kind==.Multi_IK && int(goal.effector)>=RIG_EFFECTORS || goal.kind==.Spline_IK && int(goal.effector)>=len(SPLINE_CONTROLS) || goal.kind>max(Modifier_Kind) || !profile_vector(goal.position) || !profile_weight(goal.weight) || !finite(goal.fade) || goal.fade<0 {
        core.refuse(&requests.goals)
        return
    }
    core.offer(&requests.goals,goal)
}

@(storage,free="modifier_runtime_free")
Modifier_Runtime :: struct {
    ik:core.Table(IK_Constraint),
    look:core.Table(Look_Constraint),
    limits:core.Table(Rotation_Constraint),
    grounding:core.Table(Foot_Grounding),
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
    inputs:[6]u64,
    revisions:[dynamic]u64,
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
    core.table_destroy(&runtime.ik);core.table_destroy(&runtime.look);core.table_destroy(&runtime.limits)
    core.table_destroy(&runtime.grounding);core.table_destroy(&runtime.sockets)
    delete(runtime.goals);delete(runtime.revisions);delete(runtime.controls);delete(runtime.fades);runtime^={}
}

@(private)
modifier_append :: proc(table:^core.Table($T),entity:core.Entity,value:T) -> bool {
    count:=len(table.values)
    if existing:=core.row_of(table,entity);existing>=0 && existing!=count-1 {return false}
    return core.table_append(table,entity,value)
}

// The modifiers of the .character of each animated entity, laid out again when an Animation, an
// attachment, a rig or an asset changes.
modifier_prepare :: proc(runtime:^Modifier_Runtime,animations:^core.Table(Animation,$A),attachments:^core.Table(Bone_Attachment,$B),characters:^Character_Assets,skeletons:^Skeleton_Assets,playback:^Playback,loaded:^host.Assets,allocator:mem.Allocator,problems:^core.Problems) -> bool {
    allocation_failed :: proc(cache:^$T,id:base.Asset_Id) -> bool {
        if cache==nil || id=={} {return false}
        for content in cache.contents {if content.id==id {return content.checked==0}}
        return true
    }
    // The sets the animations name are found by their ids, entities and revisions, so a change of
    // another field of an Animation lays nothing out again.
    headers:=[6]u64{core.layout(animations),core.version(attachments),core.layout(attachments),playback.rigs_stamp,assets_stamp(loaded),core.version(animations)}
    if runtime.inputs==headers {return true}
    revisions_changed:=false;revision_row:=0
    compare_revision :: proc(runtime:^Modifier_Runtime,row:^int,revision:u64,changed:^bool) {
        if row^>=len(runtime.revisions) || runtime.revisions[row^]!=revision {changed^=true}
        row^+=1
    }
    for row in 0..<core.count(animations) {
        id:=animation_character(loaded,animations.values[row]);revision:u64
        if id=={} {continue}
        if content:=character_content(characters,loaded,allocator,id);content!=nil {revision=character_key(core.entity_at(animations,row),id,content.revision)} else if allocation_failed(characters,id) {memory_problem(problems,core.entity_at(animations,row),"its .character");return false}
        compare_revision(runtime,&revision_row,revision,&revisions_changed)
    }
    for &rig in playback.rigs {
        revision:u64
        if content:=skeleton_content(skeletons,loaded,allocator,rig.skeleton);content!=nil {revision=content.revision} else if allocation_failed(skeletons,rig.skeleton) {memory_problem(problems,rig.entity,"its skeleton");return false}
        compare_revision(runtime,&revision_row,revision,&revisions_changed)
    }
    revisions_changed ||= revision_row!=len(runtime.revisions)
    if !revisions_changed && runtime.inputs.xyzw==headers.xyzw {runtime.inputs=headers;return true}
    next:=Modifier_Runtime{geometry=runtime.geometry+1,inputs=headers};defer modifier_runtime_free(&next)
    if reserve(&next.revisions,revision_row)!=nil {memory_problem(problems,core.NONE,"the modifiers of the rigs, so none applies");return false}
    next.ik.version,next.look.version,next.limits.version=runtime.ik.version+1,runtime.look.version+1,runtime.limits.version+1
    next.grounding.version,next.sockets.version=runtime.grounding.version+1,runtime.sockets.version+1
    next.ik.layout,next.look.layout,next.limits.layout=runtime.ik.layout+1,runtime.look.layout+1,runtime.limits.layout+1
    next.grounding.layout,next.sockets.layout=runtime.grounding.layout+1,runtime.sockets.layout+1
    for row in 0..<core.count(animations) {
        id:=animation_character(loaded,animations.values[row])
        if id=={} {continue}
        entity:=core.entity_at(animations,row)
        content:=character_content(characters,loaded,allocator,id);append(&next.revisions,character_key(entity,id,content.revision) if content!=nil else 0)
        if content==nil {
            if allocation_failed(characters,id) {memory_problem(problems,entity,"its .character");return false}
            asset_problem(problems,entity,loaded,"animation.character","Animation.asset",id,content_error(characters.contents[:],id))
            continue
        }
        pose:=content.set.pose
        add :: proc(table:^core.Table($T),entity:core.Entity,rows:[]T) -> bool {
            for value in rows {value:=value;value.rig=entity;if !modifier_append(table,entity,value) {return false}}
            return true
        }
        appended:=add(&next.ik,entity,pose.ik) && add(&next.look,entity,pose.look) && add(&next.limits,entity,pose.limits) && (pose.grounding.count==0 || modifier_append(&next.grounding,entity,pose.grounding)) &&
            add(&next.chain_ik,entity,pose.chain_ik) && add(&next.twist,entity,pose.twist) && add(&next.springs,entity,pose.springs) && add(&next.multi_ik,entity,pose.multi_ik) &&
            add(&next.retarget_chains,entity,pose.retarget_chains) && add(&next.spline_ik,entity,pose.spline_ik) && add(&next.correctives,entity,pose.correctives) && add(&next.follow,entity,pose.follow) &&
            add(&next.curve_poses,entity,pose.curve_poses) && add(&next.curve_drives,entity,pose.curve_drives) && add(&next.curve_materials,entity,pose.curve_materials)
        if !appended {memory_problem(problems,entity,"its .character");return false}
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
    if !modifier_controls_prepare(&next,runtime) || reserve(&runtime.goals,len(next.controls))!=nil {memory_problem(problems,core.NONE,"the controls of the modifiers, so none applies");return false}
    // A goal stays with its operation; one whose slot now names another goes.
    #reverse for goal,i in runtime.goals {if !modifier_same_goal(runtime,&next,goal) {unordered_remove(&runtime.goals,i)}}
    next.goals=runtime.goals;runtime.goals=nil
    request_error,request_error_rig:=runtime.request_error,runtime.request_error_rig
    modifier_runtime_free(runtime);runtime^=next;next={}
    runtime.request_error,runtime.request_error_rig=request_error,request_error_rig
    #reverse for goal,i in runtime.goals {
        if modifier_control_state(runtime,goal.rig,goal.kind,goal.slot)==nil {unordered_remove(&runtime.goals,i);continue}
        // Laid out again, a look aims where it aimed: it does not turn there from the row's target.
        if goal.kind==.Look {if row:=rig_slot_row(&runtime.look,goal.rig,goal.slot);row>=0 {runtime.look.values[row].target=goal.target}}
        modifier_apply_goal(runtime,goal,problems)
    }
    for &control in runtime.controls {modifier_control_apply(runtime,&control)}
    return true
}

@(private)
character_key :: proc "contextless" (entity:core.Entity,id:base.Asset_Id,revision:u64) -> u64 {return base.hash_combine(u64(entity),base.hash_combine(id[0]~id[1],revision))}

modifier_apply_goal :: proc(runtime:^Modifier_Runtime,goal:Modifier_Goal,problems:^core.Problems) {
    scaled:=goal.weight
    control:=modifier_control_state(runtime,goal.rig,goal.kind,goal.slot)
    active:=goal.enabled
    if control!=nil && goal.fade>0 && goal.kind!=.Grounding {
        // The weight that applies now fades to the one asked: the goal hands it to its control.
        now:=control.base_weight*control.weight if control.base_enabled && (control.enabled || control.weight>0) else 0
        control.base_weight,control.base_enabled,control.weight=1,true,now
        // A look that applies and is given another target turns to it over the same fade.
        turn:=false
        if goal.kind==.Look && goal.enabled && now>0 {if row:=rig_slot_row(&runtime.look,goal.rig,goal.slot);row>=0 && runtime.look.values[row].target!=goal.target {turn=true;core.edit_at(&runtime.look,row).from=runtime.look.values[row].target}}
        if !modifier_fade_to(runtime,control,goal.weight if goal.enabled else 0,goal.enabled,goal.fade,turn) {memory_problem(problems,goal.rig,"the fade of a goal of its .character")}
        scaled,active=control.weight,control.enabled || control.weight>0
    } else if control!=nil {
        control.base_enabled=active
        if goal.kind!=.Grounding {control.base_weight=scaled}
        scaled*=control.weight
        active &&=control.enabled || control.weight>0
    }
    #partial switch goal.kind {
    case .IK:
        if row:=rig_slot_row(&runtime.ik,goal.rig,goal.slot);row>=0 {
            value:=&runtime.ik.values[row]
            if value.target!=goal.target || value.weight!=scaled || value.enabled!=active {
                out:=core.edit_at(&runtime.ik,row)
                out.target=goal.target
                out.weight,out.enabled=scaled,active
            }
        }
    case .Look:
        if row:=rig_slot_row(&runtime.look,goal.rig,goal.slot);row>=0 {
            value:=&runtime.look.values[row]
            if value.target!=goal.target || value.weight!=scaled || value.enabled!=active {
                out:=core.edit_at(&runtime.look,row)
                out.target=goal.target
                out.weight,out.enabled=scaled,active
            }
        }
    case .Grounding:
        if row:=rig_slot_row(&runtime.grounding,goal.rig,goal.slot);row>=0 {value:=&runtime.grounding.values[row];if value.global_contact!=goal.weight || value.enabled!=active {out:=core.edit_at(&runtime.grounding,row);out.global_contact,out.enabled=goal.weight,active}}
    case .Limit:
        if row:=rig_slot_row(&runtime.limits,goal.rig,goal.slot);row>=0 {value:=&runtime.limits.values[row];if value.enabled!=active || value.weight!=scaled {out:=core.edit_at(&runtime.limits,row);out.enabled,out.weight=active,scaled}}
    case .Chain_IK,.Twist,.Spring,.Multi_IK,.Chain_Retarget,.Spline_IK,.Corrective,.Follow:
        rigs_apply_goal(runtime,goal,scaled,active,problems)
    }
}
modifier_take :: proc(runtime:^Modifier_Runtime,requests:^Animation_Requests,problems:^core.Problems,dt:f32) {
    for goal in core.take(&requests.goals) {
        goal:=goal
        if error:=modifier_goal_resolve(runtime,&goal);error!=.None {
            modifier_request_rejected(runtime,goal.rig,error)
            modifier_name_problem(problems,goal.rig,goal.kind,goal.name[:],goal.effector_name[:],error)
            continue
        }
        if modifier_control_state(runtime,goal.rig,goal.kind,goal.slot)==nil {
            core.report(problems,goal.rig,"animation.modifier_slot","a goal for %v %d was refused: this entity plays no .character with such an operation; name one its set has (animation.inspect lists them), or give the goal to the rig that has it",goal.kind,goal.slot)
            continue
        }
        index:=-1
        for known,i in runtime.goals {if known.rig==goal.rig && known.kind==goal.kind && known.slot==goal.slot && known.effector==goal.effector {index=i;break}}
        if index>=0 && !goal.enabled && goal.fade>0 {goal.target=runtime.goals[index].target}
        if index>=0 {runtime.goals[index]=goal} else if append(&runtime.goals,goal)!=1 {memory_problem(problems,goal.rig,"a goal of its .character");continue}
        modifier_apply_goal(runtime,goal,problems)
    }
    modifier_controls_take(runtime,requests,problems,dt)
}

@(step="fixed",loops="game editor",stage="apply")
animation_sample :: proc(animations:^core.Table(Animation,.Read),progress:^core.Table(Animation_Progress),played:^core.Table(Animation_Played),attachments:^core.Table(Bone_Attachment,.Read),transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent,.Read),hierarchy:core.Ref(core.Hierarchy),names:^core.Table(core.Name,.Read),targets:^core.Table(Animation_Target,.Read),meshes:^core.Table(erender.Mesh_Renderer,.Read),sources:^core.Table(Pose_Source,.Read),remotes:^core.Table(core.Remote,.Read),requests:^Animation_Requests,events:^Animation_Events,runtime:^Modifier_Runtime,playback:^Playback,characters:^Character_Assets,skeletons:^Skeleton_Assets,app:^host.App,time:core.Time,frame:core.Frame_Time,problems:^core.Problems,actions:^Action_Runtime,motion:^Motion_Runtime,content_sources:^Source_Assets,paces:^core.Table(core.Own_Pace,.Read),clock:core.Clock,budget:Animation_Budget_Config) {
    if app.assets==nil {playback.frame+=1;return}
    if !rigs_update(playback,meshes,sources,app.assets) {memory_problem(problems,core.NONE,"the list of rigs, so nothing is animated in this tick");playback.frame+=1;return}
    if !modifier_prepare(runtime,animations,attachments,characters,skeletons,playback,app.assets,app.allocator,problems) {playback.frame+=1;return}
    modifier_take(runtime,requests,problems,0)
    if time.playing {progress_resume(progress,playback,requests)}
    animation_tick(animations,transforms,parents,hierarchy,names,requests,events,targets,playback,app,time,frame,skeletons,problems,characters,actions,motion,content_sources,remotes,played,paces,clock,budget)
    if time.playing {progress_write(progress,animations,playback)}
}

// A clip that a loaded game left somewhere starts there: Playback starts
// again with the World, and an entity it has no state for seeks its progress.
@(private)
progress_resume :: proc(progress:^core.Table(Animation_Progress),playback:^Playback,requests:^Animation_Requests) {
    for row in 0..<core.count(progress) {
        e:=core.entity_at(progress,row)
        if constraint_playing(playback,e)!=nil {continue}
        kept:=core.at(progress,row)
        if kept.playing {animation_command(requests,e,.Resume,speed=kept.speed)} else {animation_command(requests,e,.Pause)}
        animation_seek(requests,e,kept.time)
    }
}

// Where each clip is, for a saved game; an entity that lost its Animation loses it.
@(private)
progress_write :: proc(progress:^core.Table(Animation_Progress),animations:^core.Table(Animation,$A),playback:^Playback) {
    for row in 0..<core.count(progress) {
        if e:=core.entity_at(progress,row);!core.has(animations,e) {core.remove(progress,e)}
    }
    for row in 0..<core.count(animations) {
        e:=core.entity_at(animations,row)
        clip_time,_,_,ok:=animation_progress(playback,e)
        if !ok {continue}
        state:=constraint_playing(playback,e)
        now:=Animation_Progress{time=clip_time,speed=state.speed,playing=state.playing}
        if at:=core.row_of(progress,e);at<0 {
            core.add(progress,e,now)
        } else if core.at(progress,at)!=now {
            core.edit_at(progress,at)^=now
        }
    }
}

@(step="fixed",loops="game editor",stage="react")
animation_advance :: proc(transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent,.Read),worlds:^core.Table(core.World_Transform,.Read),requests:^Animation_Requests,runtime:^Modifier_Runtime,playback:^Playback,constraints:^Animation_Constraints,grounding:^Grounding_Runtime,world:core.World_Ref,queries:core.Ref(core.World_Queries),time:core.Time,skeletons:core.Ref(Skeleton_Assets),problems:^core.Problems,motion:^Motion_Runtime,characters:^Character_Assets,verticals:^core.Table(core.Vertical,.Read),paces:^core.Table(core.Own_Pace,.Read),clock:core.Clock,places:^core.Places) {
    modifier_take(runtime,requests,problems,time.dt)
    inputs:=Constraint_Inputs{core.read(&runtime.ik),core.read(&runtime.look),core.read(&runtime.limits),core.read(&runtime.sockets),worlds,runtime.geometry,skeletons.ptr,problems}
    ground_inputs:=Grounding_Inputs{core.read(&runtime.grounding),core.world_query(world,queries),core.read(transforms),parents,runtime.geometry,problems,verticals}
    animation_finish(playback,inputs,constraints,transforms,parents,time.dt,grounding,ground_inputs,runtime,motion,characters,core.take(&requests.final_poses),paces,clock,places)
}
