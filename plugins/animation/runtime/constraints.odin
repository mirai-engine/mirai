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
    name:[64]u8 `mirai:"text,optional"`,
        root,joint,end:Bone_Ref,
    target:Spatial_Definition `mirai:"optional"`,
    pole:mm.Vec3,
    hold:IK_Hold `mirai:"optional"`,
    reach:lib.Chain_Reach `mirai:"optional"`, // a softened approach to full extension and how far the bones may stretch past it
    weight:f32 `mirai:"min=0,max=1"`,
    enabled:bool,
}
IK_CONSTRAINT_DEFAULT :: IK_Constraint{target=SPATIAL_DEFINITION_DEFAULT,pole={0,0,-1},weight=1,enabled=true}

// A bone turns so that the ray from offset along its forward axis passes through a target, up to
// max_angle; with use_up, its up axis turns toward world_up around it.
Look_Constraint :: struct {
    name:[64]u8 `mirai:"text,optional"`,
        bone:Bone_Ref,
    target:Spatial_Definition `mirai:"optional"`,
    forward:mm.Vec3,
    offset:mm.Vec3 `mirai:"optional"`, // where the ray starts in the frame of the bone: the eyes of a head, the muzzle of a held gun
    up,world_up:mm.Vec3 `mirai:"optional"`,
    use_up:bool `mirai:"optional"`,
    max_angle:f32 `mirai:"angle,min=0"`,
    weight:f32 `mirai:"min=0,max=1"`,
    enabled:bool,

}
LOOK_CONSTRAINT_DEFAULT :: Look_Constraint{target=SPATIAL_DEFINITION_DEFAULT,forward=mm.FORWARD,up={0,1,0},world_up={0,1,0},max_angle=1.5,weight=1,enabled=true}

Rotation_Constraint :: struct {
    name:[64]u8 `mirai:"text,optional"`,
        bone:Bone_Ref,
    axis:mm.Vec3,
    reference:mm.Quat,
    max_swing,min_twist,max_twist:f32 `mirai:"angle"`,
    weight:f32 `mirai:"min=0,max=1"`,
    enabled:bool,
}
ROTATION_CONSTRAINT_DEFAULT :: Rotation_Constraint{axis={0,1,0},reference=1,max_swing=mm.PI,min_twist=-mm.PI,max_twist=mm.PI,weight=1,enabled=true}

Root_Motion :: struct {bone:u64,translation,rotation,in_place:bool}
ROOT_MOTION_DEFAULT :: Root_Motion{translation=true,rotation=true,in_place=true}

Root_Delta :: struct {
    translation:mm.Vec3 `mirai:"readonly,transient"`,
    rotation:mm.Quat `mirai:"readonly,transient"`,
}
ROOT_DELTA_DEFAULT :: Root_Delta{rotation=1}

Constraint_Inputs :: struct {
    worlds:^core.Table(core.World_Transform,.Read),
    skeletons:^Skeleton_Assets,
    problems:^core.Problems,
}

IK_Binding :: struct {
    using binding:Rig_Binding,
    bones:[3]int,
    target:Spatial_Target_Binding,
}

Look_Binding :: struct {
    using binding:Rig_Binding,
    bone:int,
    target,previous:Spatial_Target_Binding,
    from:Spatial_Target,
}

Limit_Binding :: struct {
    bound:u64,
    generation:u32,
    bone:int,
}

root_motion_sample :: proc(library:^lib.Library,fader:lib.Fader,config:Root_Motion,dt:f32,target:u64=0,current_dt:f32=-1) -> Root_Delta {
    target:=target
    if target==0 {target=config.bone}
    position,rotation:=lib.fader_root_motion(library,fader,target,dt,current_dt)
    return {position if config.translation else mm.Vec3{},rotation if config.rotation else mm.Quat(1)}
}

@(private)
constraint_playing :: proc(playback:core.Ref(Playback),entity:core.Entity) -> ^Playing {
    if playback.ptr==nil {return nil}
    index:=core.entity_index(entity)
    if index>=len(playback.rows) || playback.rows[index]<=0 {return nil}
    row:=int(playback.rows[index])-1
    if row>=len(playback.states) || playback.states[row].entity!=entity {return nil}
    return &playback.states[row]
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

constraints_apply :: proc(state:^Playing,playback:^Playback,inputs:Constraint_Inputs,
    runtime:^Modifier_Runtime,transforms:^core.Table(core.Transform),
    parents:^core.Table(core.Parent,.Read),dt:f32,ground_inputs:Grounding_Inputs={},
    motion:^Motion_Runtime=nil,characters:^Character_Assets=nil,final_poses:[]Pose_Request=nil) {
    if len(playing_pose(state,.Local))==0 {return}
    skeleton:=playing_skeleton(state)
    rig:=modifier_rig(core.ref(runtime),state.entity)
    empty_pose:Pose_Profile
    pose:=modifier_pose(rig,characters)
    if pose==nil {pose=&empty_pose}
    problems:=inputs.problems
    // A rig that takes the sampled pose of another takes it through the chains of its set, or by
    // the names of their bones.
    chained:=rig!=nil && rigs_retarget(state,playback,runtime,rig,pose^,problems)
    // A root bound to the entity keeps, on the channels its base keeps in place, where the owner of
    // its Transform put it after the pose was sampled.
    if state.root.in_place {if bone,reference,ok:=animation_root_reference(state,state.root,playing_pose(state,.Local),transforms);ok && bone==0 {playing_pose(state,.Local)[0]=reference}}
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
    curve_poses_apply(state,playback,runtime,rig,pose^,followed,problems)
    if !lib.pose_world(skeleton.parents,playing_pose(state,.Local),playing_pose(state,.World),parent_world) {pose_problem(problems,state.entity);return}
    if motion!=nil {
        if instance:=motion_instance(motion,state.entity);instance!=nil {
            actor,ok:=constraint_world(transforms,parents,inputs.worlds,state.entity)
            if !ok {
                core.report(problems,state.entity,"animation.rig_parent","the warping of the .character of this rig cannot place it: it or one of its parents has no Transform; give them one")
            } else {
                motion_apply_pose(motion,state,instance.profile,actor,parent_world,characters,problems,dt)
            }
        }
    }
    if rig==nil {final_pose_apply(state,playback,parent_world,final_poses,problems);return}
    if len(pose.grounding.legs)>0 {
        config:=modifier_grounding(core.ref(runtime),rig,pose.grounding)
        grounding_apply(state,&rig.grounding[0],&config,ground_inputs,dt)
    }
    for &config,at in pose.ik {
        binding:=&rig.ik_states[at]
        diagnostic:=&binding.diagnostic;diagnostic.valid=false
        weight,enabled:=modifier_weight(&modifier_states(rig,.IK)[at],runtime.time)
        if !enabled || weight<=0 {continue}
        if !rig_binding_current(binding,state) {
            binding.bones={bone_resolve(state,config.root),bone_resolve(state,config.joint),bone_resolve(state,config.end)}
            rig_binding_publish(binding,state,.IK)
        }
        root,joint,end:=binding.bones[0],binding.bones[1],binding.bones[2]
        definition:=modifier_target(rig,.IK,at,&config.target)
        target,ok:=spatial_target_sample(definition,&binding.target,playback,inputs.skeletons,transforms,parents,inputs.worlds)
        if !ok {constraint_problem(problems,state.entity,.IK,at,.Target);modifier_request_rejected(runtime,state.entity,.Missing_Target);continue}
        held:=playing_pose(state,.Local)[end].rotation if end>=0 && end<len(playing_pose(state,.Local)) else 1
        if !lib.skeleton_ik(skeleton,playing_pose(state,.Local),playing_pose(state,.World),root,joint,end,target.position,config.pole,weight,parent_world,config.reach) {constraint_problem(problems,state.entity,.IK,at,.Solve);continue}
        if config.hold!=.World {
            if config.hold==.Joint {playing_pose(state,.Local)[end].rotation=mm.quat_slerp(playing_pose(state,.Local)[end].rotation,held,weight)} else {
                parent:=playing_topology(state).parents[end]
                rotation:=mm.quat_slerp(playing_pose(state,.World)[end].rotation,target.rotation,weight)
                playing_pose(state,.Local)[end].rotation=conj(playing_pose(state,.World)[parent].rotation if parent>=0 else parent_world.rotation)*rotation
            }
            if !lib.pose_world(skeleton.parents,playing_pose(state,.Local),playing_pose(state,.World),parent_world) {pose_problem(problems,state.entity);continue}
        }
        diagnostic.residual=linalg.length(playing_pose(state,.World)[end].position-target.position)
        diagnostic.angular_error=mm.quat_angle(playing_pose(state,.World)[end].rotation,target.rotation) if config.hold==.Target else 0
        diagnostic.reached=diagnostic.residual<=.001 && diagnostic.angular_error<=.001
        diagnostic.valid=true
    }
    for &config,at in pose.look {
        binding:=&rig.look_states[at]
        diagnostic:=&binding.diagnostic;diagnostic.valid=false
        control:=&modifier_states(rig,.Look)[at]
        weight,enabled:=modifier_weight(control,runtime.time)
        if !enabled || weight<=0 {continue}
        if !rig_binding_current(binding,state) {
            binding.bone=bone_resolve(state,config.bone)
            rig_binding_publish(binding,state,.Look)
        }
        bone:=binding.bone
        if bone<0 {constraint_problem(problems,state.entity,.Look,at,.Bind,config.bone);continue}
        definition:=modifier_target(rig,.Look,at,&config.target)
        target,ok:=spatial_target_sample(definition,&binding.target,playback,inputs.skeletons,transforms,parents,inputs.worlds)
        if !ok {constraint_problem(problems,state.entity,.Look,at,.Target);modifier_request_rejected(runtime,state.entity,.Missing_Target);continue}
        turning:=1-modifier_fade(control,runtime.time) if control.turning else 0
        if turning>0 {
            if from,found:=spatial_target_sample(binding.from,&binding.previous,playback,inputs.skeletons,transforms,parents,inputs.worlds);found {target.position=mm.lerp(target.position,from.position,turning)}
        }
        direction:=target.position-playing_pose(state,.World)[bone].position
        rotation:mm.Quat;valid:bool
        if config.use_up {rotation,valid=lib.aim_at(playing_pose(state,.World)[bone].rotation,config.forward,direction,config.up,config.world_up,config.max_angle,weight,config.offset)} else {rotation,valid=lib.look_at(playing_pose(state,.World)[bone].rotation,config.forward,direction,config.max_angle,weight,config.offset)}
        if !valid {
            core.report(problems,state.entity,"animation.constraint_solve","Look %d of the .character of this rig cannot aim: its forward or up axis is zero or not finite, or its target is where the bone is or nearer the bone than its offset; give it axes and a target beyond its offset",at)
            continue
        }
        parent:=playing_topology(state).parents[bone]
        playing_pose(state,.Local)[bone].rotation=conj(playing_pose(state,.World)[parent].rotation if parent>=0 else parent_world.rotation)*rotation
        if !lib.pose_world(skeleton.parents,playing_pose(state,.Local),playing_pose(state,.World),parent_world) {pose_problem(problems,state.entity);continue}
        // The residual is how far the aim passes from the target, at its distance.
        aim:=mm.quat_rotate(playing_pose(state,.World)[bone].rotation,linalg.normalize0(config.forward))
        sight:=target.position-mm.transform_point(playing_pose(state,.World)[bone],config.offset)
        diagnostic.angular_error=math.atan2(linalg.length(linalg.cross(aim,sight)),linalg.dot(aim,sight))
        diagnostic.residual=linalg.length(sight-aim*linalg.length(sight))
        diagnostic.reached=diagnostic.angular_error<=.001
        diagnostic.valid=true
    }
    rigs_apply(state,runtime,rig,pose^,inputs,transforms,parents,parent_world,dt,playback)
    limited:=false
    for &config,at in pose.limits {
        weight,enabled:=modifier_weight(&modifier_states(rig,.Limit)[at],runtime.time)
        if !enabled || weight<=0 {continue}
        binding:=&rig.limit_states[at]
        if binding.bound!=state.bound || binding.generation!=state.generation {
            binding^={state.bound,state.generation,bone_resolve(state,config.bone)}
        }
        bone:=binding.bone
        if bone<0 {constraint_problem(problems,state.entity,.Limit,at,.Bind,config.bone);continue}
        rotation,ok:=lib.rotation_limit(playing_pose(state,.Local)[bone].rotation,config.reference,{config.axis,config.max_swing,config.min_twist,config.max_twist})
        if ok {
            playing_pose(state,.Local)[bone].rotation=mm.quat_slerp(playing_pose(state,.Local)[bone].rotation,rotation,weight);limited=true
        } else {
            core.report(problems,state.entity,"animation.constraint_solve","Limit %d of the .character of this rig cannot limit bone '%s': its axis is zero or not finite, or min_twist is above max_twist; fix it in the .character",at,base.text_get(config.bone.path[:]))
        }
    }
    if limited && !lib.pose_world(skeleton.parents,playing_pose(state,.Local),playing_pose(state,.World),parent_world) {pose_problem(problems,state.entity);return}
    final_pose_apply(state,playback,parent_world,final_poses,problems)
    for &attachment in rig.attachments {
        entity:=attachment.entity
        if attachment.bound!=state.bound || attachment.generation!=state.generation {
            attachment.index=bone_find(state,attachment.bone)
            attachment.bound,attachment.generation=state.bound,state.generation
        }
        transform,ok:=lib.skeleton_socket(playing_pose(state,.World),attachment.index,attachment.offset)
        if !ok {
            core.report(problems,entity,"animation.socket_bone","this Bone_Attachment names a bone that the skeleton of its rig does not have; name a bone or socket of that skeleton")
            continue
        }
        if parents!=nil {
            if parent,found:=core.get(parents,entity);found && parent.entity!=core.NONE {
                socket_parent,parent_ok:=constraint_world(transforms,parents,inputs.worlds,parent.entity)
                for binding,j in state.bindings {if binding.entity==parent.entity {socket_parent=playing_pose(state,.World)[j];parent_ok=true;break}}
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
        for binding,j in state.bindings {if binding.entity==entity {playing_pose(state,.Local)[j]=transform;lib.pose_world(skeleton.parents,playing_pose(state,.Local),playing_pose(state,.World),parent_world);break}}
    }
}

// The local transform of a root bone in pose with the channels an in-place root motion keeps
// pinned to its reference (root_reference); the other channels are those of pose.
animation_root_reference :: proc(state:^Playing,root:Root_Motion,pose:[]mm.Transform,transforms:^core.Table(core.Transform,$A)) -> (bone:int,reference:mm.Transform,ok:bool) {
    if state==nil {return -1,mm.TRANSFORM_IDENTITY,false}
    bone=bone_find(state,root.bone)
    if bone<0 || bone>=len(pose) || bone>=len(playing_topology(state).rest) {return -1,mm.TRANSFORM_IDENTITY,false}
    reference=pose[bone]
    if !root.in_place {return bone,reference,true}
    pinned:=root_reference(state,bone,transforms)
    if root.translation {reference.position=pinned.position}
    if root.rotation {reference.rotation=pinned.rotation}
    return bone,reference,true
}
