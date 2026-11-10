package anim

import "core:math"
import "core:math/linalg"
import "mirai:core"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// What the end bone of an IK keeps once its two bones reach: its rotation in the world, its
// rotation relative to the joint as the pose had it (a hand in line with its forearm), or the
// rotation of the target.
IK_Hold :: enum u8 {World,Joint,Target}

// Two bones reach a target; the end bone keeps what hold says.
IK_Constraint :: struct {
    rig:core.Entity `mirai:"transient"`,
    root,joint,end:Bone_Ref,
    target:Spatial_Target `mirai:"optional"`,
    pole:mm.Vec3,
    hold:IK_Hold `mirai:"optional"`,
    weight:f32 `mirai:"min=0,max=1"`,
    enabled:bool,
}
IK_CONSTRAINT_DEFAULT :: IK_Constraint{target=SPATIAL_TARGET_DEFAULT,pole={0,0,-1},weight=1,enabled=true}

// A bone turns its forward axis toward a target, up to max_angle; with
// use_up, its up axis turns toward world_up around it.
Look_Constraint :: struct {
    rig:core.Entity `mirai:"transient"`,
    bone:Bone_Ref,
    target:Spatial_Target `mirai:"optional"`,
    forward:mm.Vec3,
    up,world_up:mm.Vec3 `mirai:"optional"`,
    use_up:bool `mirai:"optional"`,
    max_angle:f32 `mirai:"angle,min=0"`,
    weight:f32 `mirai:"min=0,max=1"`,
    enabled:bool,
}
LOOK_CONSTRAINT_DEFAULT :: Look_Constraint{target=SPATIAL_TARGET_DEFAULT,forward=mm.FORWARD,up={0,1,0},world_up={0,1,0},max_angle=1.5,weight=1,enabled=true}

Rotation_Constraint :: struct {
    rig:core.Entity `mirai:"transient"`,
    bone:Bone_Ref,
    axis:mm.Vec3,
    reference:mm.Quat,
    max_swing,min_twist,max_twist:f32 `mirai:"angle"`,
    weight:f32 `mirai:"min=0,max=1"`,
    enabled:bool,
}
ROTATION_CONSTRAINT_DEFAULT :: Rotation_Constraint{axis={0,1,0},reference=1,max_swing=mm.PI,min_twist=-mm.PI,max_twist=mm.PI,weight=1,enabled=true}

Bone_Binding :: struct {
    rig:core.Entity `mirai:"transient"`,
    bone:Bone_Ref,
    offset:mm.Transform,
    enabled:bool,
}
BONE_BINDING_DEFAULT :: Bone_Binding{offset=mm.TRANSFORM_IDENTITY,enabled=true}

Root_Motion :: struct {bone:Bone_Ref,translation,rotation,in_place:bool}
ROOT_MOTION_DEFAULT :: Root_Motion{translation=true,rotation=true,in_place=true}

Root_Delta :: struct {
    translation:mm.Vec3 `mirai:"readonly,transient"`,
    rotation:mm.Quat `mirai:"readonly,transient"`,
}
ROOT_DELTA_DEFAULT :: Root_Delta{rotation=1}

Constraint_Inputs :: struct {
    ik:^core.Table(IK_Constraint,.Read),
    look:^core.Table(Look_Constraint,.Read),
    limits:^core.Table(Rotation_Constraint,.Read),
    sockets:^core.Table(Bone_Binding,.Read),
    roots:^core.Table(Root_Motion,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
    geometry:u64,
    skeletons:^Skeleton_Assets, // the sockets targets name
    problems:^core.Problems,
}

Constraint_Rig :: struct {
    entity:core.Entity,
    rows:[4][dynamic]int,   // of ik, look, limits and sockets
    bones:[4][dynamic][3]int,
    targets:[2][dynamic]Spatial_Target_Binding, // of each IK and Look row
    diagnostics:[2][dynamic]Rig_Diagnostic, // of each IK and Look row
    bound:u64,
    generation:u32,
}

@(storage,free="constraints_free")
Animation_Constraints :: struct {
    rigs:[dynamic]Constraint_Rig,
    stamps:[4]u64,
    revision:u64,
}

root_motion_sample :: proc(library:^lib.Library,fader:lib.Fader,config:Root_Motion,dt:f32,target:u64=0,current_dt:f32=-1) -> Root_Delta {
    target:=target
    hash,valid:=bone_ref_hash(config.bone)
    if !valid {return ROOT_DELTA_DEFAULT}
    if target==0 {target=hash}
    position,rotation:=lib.fader_root_motion(library,fader,target,dt,current_dt)
    return {position if config.translation else mm.Vec3{},rotation if config.rotation else mm.Quat(1)}
}

@(private)
constraint_count :: proc "contextless" (rows:^core.Table($T,$A)) -> int {return core.count(rows) if rows!=nil else 0}
@(private)
constraint_stamp :: proc "contextless" (rows:^core.Table($T,$A)) -> u64 {return core.version(rows)+core.layout(rows)+1 if rows!=nil else 0}
@(private)
constraint_bone :: proc "contextless" (state:^Playing,target:u64) -> int {
    for name,i in state.targets {if name==target {return i}}
    return -1
}
@(private)
constraint_playing :: proc(playback:^Playback,entity:core.Entity) -> ^Playing {
    index:=core.entity_index(entity)
    if index>=len(playback.rows) || playback.rows[index]<=0 {return nil}
    row:=int(playback.rows[index])-1
    if row>=len(playback.states) || playback.states[row].entity!=entity {return nil}
    return &playback.states[row]
}

@(private)
constraints_index :: proc(cache:^Animation_Constraints,rows:^core.Table($T,$A),kind:int) -> bool {
    for i in 0..<constraint_count(rows) {
        config:=core.at(rows,i)
        rig:=config.rig
        if rig==core.NONE {rig=core.entity_at(rows,i)}
        index:=core.entity_index(rig)
        if index>=len(cache.rigs) && resize(&cache.rigs,index+1)!=nil {return false}
        record:=&cache.rigs[index]
        if record.entity!=rig {constraint_rig_free(record);record.entity=rig}
        if append(&record.rows[kind],i)!=1 {return false}
    }
    return true
}

@(private)
constraints_prepare :: proc(cache:^Animation_Constraints,inputs:Constraint_Inputs) -> bool {
    stamps:=[4]u64{constraint_stamp(inputs.ik),constraint_stamp(inputs.look),constraint_stamp(inputs.limits),constraint_stamp(inputs.sockets)}
    if inputs.geometry!=0 {for &stamp in stamps {stamp=inputs.geometry}}
    if cache.stamps==stamps {return true}
    for &rig in cache.rigs {for &rows in rig.rows {clear(&rows)};rig.bound=0}
    if !constraints_index(cache,inputs.ik,0) || !constraints_index(cache,inputs.look,1) || !constraints_index(cache,inputs.limits,2) || !constraints_index(cache,inputs.sockets,3) {memory_problem(inputs.problems,core.NONE,"the constraints of the animated rigs, so none applies");return false}
    cache.stamps=stamps;cache.revision+=1
    return true
}

@(private)
constraints_bind :: proc(state:^Playing,inputs:Constraint_Inputs,rig:^Constraint_Rig) -> bool {
    if rig.bound==state.bound && rig.generation==state.generation {return true}
    for rows,kind in rig.rows {
        if kind<2 {
            for &target in rig.targets[kind][min(len(rows),len(rig.targets[kind])):] {delete(target.path)}
            if resize(&rig.targets[kind],len(rows))!=nil || resize(&rig.diagnostics[kind],len(rows))!=nil {return false}
            for &diagnostic,i in rig.diagnostics[kind] {diagnostic={rig=state.entity,kind=.IK if kind==0 else .Look,slot=u16(i)}}
        }
        if resize(&rig.bones[kind],len(rows))!=nil {return false}
        for row,i in rows {
            names:[3]Bone_Ref
            switch kind {
            case 0: c:=core.at(inputs.ik,row);names={c.root,c.joint,c.end}
            case 1: c:=core.at(inputs.look,row);names={c.bone,{},{}}
            case 2: c:=core.at(inputs.limits,row);names={c.bone,{},{}}
            case 3: c:=core.at(inputs.sockets,row);names={c.bone,{},{}}
            }
            for target,j in names {rig.bones[kind][i][j]=bone_resolve(state,target)}
        }
    }
    rig.bound=state.bound;rig.generation=state.generation
    return true
}

@(private)
constraint_world :: proc(transforms:^core.Table(core.Transform,$A),parents:^core.Table(core.Parent,$B),worlds:^core.Table(core.World_Transform,.Read),entity:core.Entity) -> (mm.Transform,bool) {
    if transforms!=nil && parents!=nil {return core.world_of(transforms,parents,entity)}
    if worlds!=nil {if found,ok:=core.get(worlds,entity);ok {return found.transform,true}}
    return mm.TRANSFORM_IDENTITY,false
}

// Reports a constraint of the .character of a rig that did nothing in a tick.
@(private)
constraint_problem :: proc(problems:^core.Problems,e:core.Entity,kind:Modifier_Kind,index:int,failure:Rig_Failure,bone:Bone_Ref={}) {
    bone:=bone
    switch failure {
    case .Bind:
        core.report(problems,e,"animation.constraint_bone","%v %d of the .character of this rig names '%s', which its skeleton does not have; %s",kind,index,base.text_get(bone.path[:]),bone_fix(bone))
    case .Target:
        core.report(problems,e,"animation.constraint_target","%v %d of the .character of this rig has no target: its entity is gone or has no Transform, its rig is not animated in this tick, or its bone or socket is not in that skeleton; give it a target that exists",kind,index)
    case .Solve:
        core.report(problems,e,"animation.constraint_solve","%v %d of the .character of this rig could not be solved: its bones are not a chain of the skeleton (root above joint above end), or a value of it or of its target is not finite; fix it in the .character",kind,index)
    case .Source:
    }
}

constraints_apply :: proc(state:^Playing,playback:^Playback,inputs:Constraint_Inputs,cache:^Animation_Constraints,transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent,.Read),dt:f32,grounding:^Grounding_Runtime=nil,ground_inputs:Grounding_Inputs={},rig_runtime:^Modifier_Runtime=nil,motion:^Motion_Runtime=nil,characters:^Character_Assets=nil,final_poses:[]Pose_Request=nil) {
    if len(state.local)==0 || !constraints_prepare(cache,inputs) {return}
    skeleton:=playing_skeleton(state)
    index:=core.entity_index(state.entity)
    rig:^Constraint_Rig
    if index<len(cache.rigs) && cache.rigs[index].entity==state.entity {rig=&cache.rigs[index]}
    problems:=inputs.problems
    if rig!=nil && !constraints_bind(state,inputs,rig) {memory_problem(problems,state.entity,"the constraints of its .character");return}
    // A rig that takes the sampled pose of another takes it through the chains of its set, or by
    // the names of their bones.
    chained:=rig_runtime!=nil && rigs_retarget(state,playback,rig_runtime,problems)
    {
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        root:=state.base_root;ok:=state.has_base_root;sampled:=state.clips_in_place
        if inputs.roots!=nil {if supplied,exists:=core.get(inputs.roots,state.entity);exists {root=supplied;ok=true;sampled=false}}
        if state.program.ready && state.program.has_root {root=state.program.root;ok=true;sampled=false}
        if state.has_action_root {root=state.action_root;ok=true;sampled=false}
        if state.has_action_in_place {root=state.action_in_place_root;ok=true;sampled=false}
        if ok && !sampled && (root.in_place || state.has_action_in_place) {
            if bone,reference,valid:=animation_root_reference(state,root,state.local[:],transforms);valid {state.local[bone]=reference}
        }
    }
    parent_world:=mm.TRANSFORM_IDENTITY
    if parents!=nil {
        if parent,ok:=core.get(parents,state.entity);ok && parent.entity!=core.NONE {
            parent_world,ok=constraint_world(transforms,parents,inputs.worlds,parent.entity)
            if !ok {
                core.report(problems,state.entity,"animation.rig_parent","the constraints of this rig cannot place it: its parent 0x%016x or one above it has no Transform; give them one",u64(parent.entity))
                return
            }
        }
    }
    for axis in parent_world.scale {
        if abs(axis)<1e-8 {
            core.report(problems,state.entity,"animation.rig_scale","the constraints of this rig cannot place it: its parent has a scale of zero on an axis; give the parents of the rig a scale")
            return
        }
    }
    followed:=state.leader!=core.NONE && !chained && leader_follow(state,playback,inputs,transforms,parents,parent_world)
    curve_poses_apply(state,playback,rig_runtime,followed,problems)
    if !lib.pose_world(skeleton.parents,state.local[:],state.world[:],parent_world) {pose_problem(problems,state.entity);return}
    if motion!=nil {
        if instance:=motion_instance(motion,state.entity);instance!=nil {
            actor,ok:=constraint_world(transforms,parents,inputs.worlds,state.entity)
            if !ok {
                core.report(problems,state.entity,"animation.rig_parent","the warping of the .character of this rig cannot place it: it or one of its parents has no Transform; give them one")
            } else {
                motion_apply_pose(motion,state,instance.profile,actor,parent_world,characters,problems)
            }
        }
    }
    if grounding!=nil {grounding_apply(state,grounding,ground_inputs,dt)}
    if rig==nil {if rig_runtime!=nil {rigs_apply(state,rig_runtime,inputs,transforms,parents,parent_world,dt,playback)};final_pose_apply(state,playback,parent_world,final_poses,problems);return}
    for row,at in rig.rows[0] {
        config:=core.at(inputs.ik,row)
        diagnostic:=&rig.diagnostics[0][at];diagnostic.valid=false
        if !config.enabled || config.weight<=0 {continue}
        root,joint,end:=rig.bones[0][at][0],rig.bones[0][at][1],rig.bones[0][at][2]
        target,ok:=spatial_target_sample(config.target,&rig.targets[0][at],playback,inputs.skeletons,transforms,parents,inputs.worlds)
        if !ok {constraint_problem(problems,state.entity,.IK,at,.Target);if rig_runtime!=nil {modifier_request_rejected(rig_runtime,state.entity,.Missing_Target)};continue}
        held:=state.local[end].rotation if end>=0 && end<len(state.local) else 1
        if !lib.skeleton_ik(skeleton,state.local[:],state.world[:],root,joint,end,target.position,config.pole,config.weight,parent_world) {constraint_problem(problems,state.entity,.IK,at,.Solve);continue}
        if config.hold!=.World {
            if config.hold==.Joint {state.local[end].rotation=mm.quat_slerp(state.local[end].rotation,held,config.weight)} else {
                parent:=state.parents[end]
                rotation:=mm.quat_slerp(state.world[end].rotation,target.rotation,config.weight)
                state.local[end].rotation=conj(state.world[parent].rotation if parent>=0 else parent_world.rotation)*rotation
            }
            if !lib.pose_world(skeleton.parents,state.local[:],state.world[:],parent_world) {pose_problem(problems,state.entity);continue}
        }
        diagnostic.residual=linalg.length(state.world[end].position-target.position)
        diagnostic.angular_error=mm.quat_angle(state.world[end].rotation,target.rotation) if config.hold==.Target else 0
        diagnostic.reached=diagnostic.residual<=.001 && diagnostic.angular_error<=.001
        diagnostic.valid=true
    }
    for row,at in rig.rows[1] {
        config:=core.at(inputs.look,row)
        diagnostic:=&rig.diagnostics[1][at];diagnostic.valid=false
        if !config.enabled || config.weight<=0 {continue}
        bone:=rig.bones[1][at][0]
        if bone<0 {constraint_problem(problems,state.entity,.Look,at,.Bind,config.bone);continue}
        target,ok:=spatial_target_sample(config.target,&rig.targets[1][at],playback,inputs.skeletons,transforms,parents,inputs.worlds)
        if !ok {constraint_problem(problems,state.entity,.Look,at,.Target);if rig_runtime!=nil {modifier_request_rejected(rig_runtime,state.entity,.Missing_Target)};continue}
        direction:=target.position-state.world[bone].position
        rotation:mm.Quat;valid:bool
        if config.use_up {rotation,valid=lib.aim_at(state.world[bone].rotation,config.forward,direction,config.up,config.world_up,config.max_angle,config.weight)} else {rotation,valid=lib.look_at(state.world[bone].rotation,config.forward,direction,config.max_angle,config.weight)}
        if !valid {
            core.report(problems,state.entity,"animation.constraint_solve","Look %d of the .character of this rig cannot aim: its forward or up axis is zero or not finite, or its target is where the bone is; give it axes and a target apart from the bone",at)
            continue
        }
        parent:=state.parents[bone]
        state.local[bone].rotation=conj(state.world[parent].rotation if parent>=0 else parent_world.rotation)*rotation
        if !lib.pose_world(skeleton.parents,state.local[:],state.world[:],parent_world) {pose_problem(problems,state.entity);continue}
        // The residual is how far the aim passes from the target, at its distance.
        aim:=mm.quat_rotate(state.world[bone].rotation,linalg.normalize0(config.forward))
        diagnostic.angular_error=math.atan2(linalg.length(linalg.cross(aim,direction)),linalg.dot(aim,direction))
        diagnostic.residual=linalg.length(target.position-state.world[bone].position-aim*linalg.length(direction))
        diagnostic.reached=diagnostic.angular_error<=.001
        diagnostic.valid=true
    }
    if rig_runtime!=nil {rigs_apply(state,rig_runtime,inputs,transforms,parents,parent_world,dt,playback)}
    limited:=false
    for row,at in rig.rows[2] {
        config:=core.at(inputs.limits,row)
        if !config.enabled || config.weight<=0 {continue}
        bone:=rig.bones[2][at][0]
        if bone<0 {constraint_problem(problems,state.entity,.Limit,at,.Bind,config.bone);continue}
        rotation,ok:=lib.rotation_limit(state.local[bone].rotation,config.reference,{config.axis,config.max_swing,config.min_twist,config.max_twist})
        if ok {
            state.local[bone].rotation=mm.quat_slerp(state.local[bone].rotation,rotation,config.weight);limited=true
        } else {
            core.report(problems,state.entity,"animation.constraint_solve","Limit %d of the .character of this rig cannot limit bone '%s': its axis is zero or not finite, or min_twist is above max_twist; fix it in the .character",at,base.text_get(config.bone.path[:]))
        }
    }
    if limited && !lib.pose_world(skeleton.parents,state.local[:],state.world[:],parent_world) {pose_problem(problems,state.entity);return}
    final_pose_apply(state,playback,parent_world,final_poses,problems)
    for row,at in rig.rows[3] {
        config:=core.at(inputs.sockets,row)
        if !config.enabled {continue}
        entity:=core.entity_at(inputs.sockets,row)
        bone:=rig.bones[3][at][0]
        transform,ok:=lib.skeleton_socket(state.world[:],bone,config.offset)
        if !ok {
            core.report(problems,entity,"animation.socket_bone","this Bone_Attachment hangs from socket bone '%s', which the skeleton of rig 0x%016x does not have; name a socket of that skeleton",base.text_get(config.bone.path[:]),u64(state.entity))
            continue
        }
        if parents!=nil {
            if parent,found:=core.get(parents,entity);found && parent.entity!=core.NONE {
                socket_parent,parent_ok:=constraint_world(transforms,parents,inputs.worlds,parent.entity)
                for binding,j in state.bindings {if binding.entity==parent.entity {socket_parent=state.world[j];parent_ok=true;break}}
                if !parent_ok {
                    core.report(problems,entity,"animation.socket_parent","this Bone_Attachment cannot be placed: its parent 0x%016x or one above it has no Transform; give them one",u64(parent.entity))
                    continue
                }
                transform,ok=mm.transform_relative(transform,socket_parent)
                if !ok {
                    core.report(problems,entity,"animation.socket_parent","this Bone_Attachment cannot be placed: its parent has a scale of zero; give its parent a scale")
                    continue
                }
            }
        }
        current,exists:=core.get(transforms,entity)
        if exists && core.to_math(current)==transform {continue}
        output:=core.free(transforms,entity)
        if output==nil {
            core.report(problems,entity,"animation.socket_owner","this Bone_Attachment cannot move its entity: it has no Transform, or another component owns it (a body of the physics, another animation); attach an entity that only the attachment moves")
            continue
        }
        output^=core.from_math(transform)
        for binding,j in state.bindings {if binding.entity==entity {state.local[j]=transform;lib.pose_world(skeleton.parents,state.local[:],state.world[:],parent_world);break}}
    }
}

// The local transform of a root bone with the channels its root motion keeps
// in place pinned: to the retired pose of the actions that project that bone,
// or else, for an in-place root, to the rest (the entity's own transform for a
// root bound to it). The other channels are those of pose.
animation_root_reference :: proc(state:^Playing,root:Root_Motion,pose:[]mm.Transform,transforms:^core.Table(core.Transform,$A)) -> (bone:int,reference:mm.Transform,ok:bool) {
    if state==nil {return -1,mm.TRANSFORM_IDENTITY,false}
    bone=bone_resolve(state,root.bone)
    if bone<0 || bone>=len(pose) || bone>=len(state.rest) {return -1,mm.TRANSFORM_IDENTITY,false}
    reference=pose[bone]
    pinned:mm.Transform
    if state.has_action_in_place && bone_resolve(state,state.action_in_place_root.bone)==bone {pinned=state.action_in_place_local} else if root.in_place {
        pinned=state.rest[bone]
        if bone==0 && state.parents[bone]<0 && state.bindings[bone].entity==state.entity {
            if current,exists:=core.get(transforms,state.entity);exists {pinned=core.to_math(current)}
        }
    } else {return bone,reference,true}
    if root.translation {reference.position=pinned.position}
    if root.rotation {reference.rotation=pinned.rotation}
    return bone,reference,true
}

@(private)
constraint_rig_free :: proc(rig:^Constraint_Rig) {
    for targets in rig.targets {for target in targets {delete(target.path)};delete(targets)}
    for diagnostics in rig.diagnostics {delete(diagnostics)}
    for rows in rig.rows {delete(rows)}
    for bones in rig.bones {delete(bones)}
    rig^={}
}
constraints_free :: proc(cache:^Animation_Constraints) {
    for &rig in cache.rigs {constraint_rig_free(&rig)}
    delete(cache.rigs);cache^={}
}
