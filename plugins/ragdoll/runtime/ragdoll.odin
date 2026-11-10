package ragdoll

import "core:math/linalg"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

Ragdoll_Mode :: enum u8 {Animated,Simulated,Driven,Disabled}
Ragdoll_Error :: enum u8 {None,Invalid_Settings,Missing_Rig,Missing_Bone,Missing_Body,Unsupported_Joint,Pose_Capacity,Request_Capacity}

@(component,replicated,description="Controls skeletal rigid bodies: animated kinematics, free simulation or physical animation through joint motors.")
Ragdoll :: struct {
    mode:Ragdoll_Mode,
    weight:f32 `mirai:"min=0,max=1"`,
    hertz:f32 `mirai:"min=0,unit=Hz"`,
    damping_ratio:f32 `mirai:"min=0"`,
    max_torque:f32 `mirai:"min=0"`,
}
RAGDOLL_DEFAULT :: Ragdoll{mode=.Simulated,weight=1,hertz=5,damping_ratio=1,max_torque=100}

@(component,description="Binds a rigid body to a skeleton bone. The body offset is expressed in the bone frame; joints and colliders use the normal physics components.")
Ragdoll_Bone :: struct {rig:core.Entity,bone:anim.Bone_Ref,offset:mm.Transform}
RAGDOLL_BONE_DEFAULT :: Ragdoll_Bone{offset=mm.TRANSFORM_IDENTITY}

@(component)
Ragdoll_State :: struct {
    binding:anim.Bone_Handle `mirai:"transient,readonly"`,
    reference:u64 `mirai:"transient"`,
    mode:Ragdoll_Mode `mirai:"transient"`,
    active:bool `mirai:"transient"`,
    error:Ragdoll_Error `mirai:"transient,readonly"`,
}

@(storage)
Ragdoll_Runtime :: struct {pose:[dynamic]mm.Transform}
@(storage,setting)
Ragdoll_Settings :: struct {max_bones:int `mirai:"advanced"`}
RAGDOLL_SETTINGS_DEFAULT :: Ragdoll_Settings{max_bones=512}

ragdoll_valid :: proc(config:Ragdoll) -> bool {
    return config.mode<=.Disabled && config.weight>=0 && config.weight<=1 &&
        config.hertz>=0 && config.hertz<=max(f32) && config.damping_ratio>=0 && config.damping_ratio<=max(f32) &&
        config.max_torque>=0 && config.max_torque<=max(f32)
}

ragdoll_bone_valid :: proc(bone:Ragdoll_Bone) -> bool {
    if bone.rig==core.NONE {return false}
    if _,ok:=anim.bone_ref_hash(bone.bone);!ok {return false}
    if bone.offset.scale!=([3]f32{1,1,1}) {return false}
    if !(abs(linalg.dot(bone.offset.rotation,bone.offset.rotation)-1)<0.002) {return false}
    for p in bone.offset.position {if !(abs(p)<=max(f32)) {return false}}
    return true
}

// Transactional binding of bodies already created by a scene or prefab.
ragdoll_bind :: proc(world:core.World_Ref,rig:core.Entity,bodies:[]core.Entity,bones:[]Ragdoll_Bone,config:=RAGDOLL_DEFAULT) -> Ragdoll_Error {
    if world.data==nil || world.info==nil || world.place!=.World || len(bodies)==0 || len(bodies)!=len(bones) || !ragdoll_valid(config) {return .Invalid_Settings}
    configs:=core.world_table_of(world,Ragdoll)
    bindings:=core.world_table_of(world,Ragdoll_Bone)
    rigids:=core.world_table_of(world,phys.Rigid_Body)
    transforms:=core.world_table_of(world,core.Transform)
    if configs==nil || bindings==nil || transforms==nil || !core.has(core.read(transforms),rig) {return .Missing_Rig}
    if rigids==nil {return .Missing_Body}
    for bone,i in bones {
        value:=bone;value.rig=rig
        if !ragdoll_bone_valid(value) {return .Invalid_Settings}
        body,ok:=core.get(core.read(rigids),bodies[i])
        if !ok || body.type!=.Dynamic || !core.has(core.read(transforms),bodies[i]) {return .Missing_Body}
        for previous in bodies[:i] {if previous==bodies[i] {return .Invalid_Settings}}
    }
    core.add(configs,rig,config)
    for bone,i in bones {value:=bone;value.rig=rig;core.add(bindings,bodies[i],value)}
    return .None
}

@(private)
ragdoll_release :: proc(state:^Ragdoll_State,entity:core.Entity,bodies:^phys.Body_Requests,joints:^phys.Joint_Requests,joint_rows:core.Read(phys.Joint)) {
    if state.active && state.mode==.Animated {phys.manipulation_end(bodies,entity,true)}
    if state.active && state.mode==.Driven && core.has(joint_rows,entity) {phys.set_joint_drive_enabled(joints,entity,false)}
    state.active=false
}

@(step="fixed",loops="game editor",stage="simulate",before="physics_prepare")
ragdoll_prepare :: proc(configs:core.Read(Ragdoll),bones:core.Read(Ragdoll_Bone),states:^core.Table(Ragdoll_State),rigids:core.Read(phys.Rigid_Body),joint_rows:core.Read(phys.Joint),transforms:core.Read(core.Transform),parents:core.Read(core.Parent),playback:core.Ref(anim.Playback),runtime:^Ragdoll_Runtime,settings:core.Ref(Ragdoll_Settings),bodies:^phys.Body_Requests,joints:^phys.Joint_Requests,time:core.Time,poses:^anim.Animation_Requests,problems:^core.Problems) {
    for row in 0..<core.count(core.read(states)) {
        entity:=core.entity_at(core.read(states),row)
        state:=core.at(states,row)
        bone,exists:=core.get(bones,entity)
        if !exists || !core.has(configs,bone.rig) {ragdoll_release(state,entity,bodies,joints,joint_rows);core.remove(states,entity)}
    }
    if time.dt<=0 || !time.playing || core.count(configs)==0 {return}
    if !anim.animation_requests_reserve(poses,core.count(bones)) {
        core.report(problems,core.NONE,"ragdoll.memory","out of memory for the poses ragdolls send to animation, for %d bones: some bodies may not move their bones; free memory",core.count(bones))
    }
    // .ptr spelled out: a field reached through using in a ternary is loaded before its nil check (see ODIN_WORKAROUNDS).
    capacity:=settings.ptr.max_bones if settings.ptr!=nil else 512
    if capacity<=0 || capacity>65536 || len(runtime.pose)<capacity && resize(&runtime.pose,capacity)!=nil {
        if capacity<=0 || capacity>65536 {
            core.report(problems,core.NONE,"ragdoll.max_bones","Ragdoll_Settings.max_bones is %d, so no ragdoll works; give it 1 to 65536",capacity)
        } else {
            core.report(problems,core.NONE,"ragdoll.memory","out of memory for the pose of %d bones (Ragdoll_Settings.max_bones), so no ragdoll works; free memory, or lower max_bones",capacity)
        }
        for row in 0..<core.count(core.read(states)) {
            entity:=core.entity_at(core.read(states),row);state:=core.at(states,row)
            ragdoll_release(state,entity,bodies,joints,joint_rows);state.error=.Pose_Capacity
        }
        return
    }
    for root_row in 0..<core.count(configs) {
        rig:=core.entity_at(configs,root_row)
        config:=core.at(configs,root_row)
        parent_world:=mm.TRANSFORM_IDENTITY
        if parent,ok:=core.get(parents,rig);ok && parent.entity!=core.NONE {parent_world,_=core.world_of(transforms,parents,parent.entity)}
        count,revision,sampled:=anim.animation_sample_pose(playback.ptr,rig,runtime.pose[:capacity],parent_world)
        for row in 0..<core.count(bones) {
            entity:=core.entity_at(bones,row)
            bone:=core.at(bones,row)
            if bone.rig!=rig {continue}
            held,present_state:=core.get(core.read(states),entity)
            next_state:=held;state:=&next_state
            defer {
                if !present_state {core.add(states,entity,next_state)}
                else if next_state!=held {core.get(states,entity)^=next_state}
            }
            state.error=.None
            if !ragdoll_valid(config) || !ragdoll_bone_valid(bone) {state.error=.Invalid_Settings}
            body,present:=core.get(rigids,entity)
            if !present || body.type!=.Dynamic {state.error=.Missing_Body}
            if !sampled {state.error=.Pose_Capacity if count>0 else .Missing_Rig}
            reference,_:=anim.bone_ref_hash(bone.bone)
            if state.error==.None && (state.binding.rig!=rig || state.binding.revision!=revision || state.reference!=reference) {
                binding,ok:=anim.animation_bone_bind(playback.ptr,rig,bone.bone)
                if ok {state.binding=binding;state.reference=reference} else {state.error=.Missing_Bone}
            }
            if state.error==.None && (state.binding.index<0 || int(state.binding.index)>=count) {state.error=.Missing_Bone}
            if state.error!=.None {bone_problem(problems,entity,bone,state.error,capacity)}
            if state.error!=.None || config.mode==.Disabled {ragdoll_release(state,entity,bodies,joints,joint_rows);continue}
            if state.active && state.mode!=config.mode {ragdoll_release(state,entity,bodies,joints,joint_rows)}
            target:=mm.transform_compose(runtime.pose[state.binding.index],bone.offset)
            if config.mode==.Animated {phys.manipulation_target(bodies,entity,target.position,target.rotation)}
            if config.mode==.Driven {
                joint,exists:=core.get(joint_rows,entity)
                if exists {
                    if joint.kind!=.SixDOF && joint.kind!=.Spherical {
                        state.error=.Unsupported_Joint
                        core.report(problems,entity,"ragdoll.joint","its Joint is %v, and a Driven Ragdoll drives only SixDOF and Spherical joints, so this body is not driven; change the kind of the Joint, or make the Ragdoll Simulated",joint.kind)
                        ragdoll_release(state,entity,bodies,joints,joint_rows);continue
                    }
                    if config.hertz==0 || config.max_torque==0 {
                        phys.set_joint_drive_enabled(joints,entity,false)
                        state.mode,state.active=config.mode,true
                        continue
                    }
                    frame_a:=mm.TRANSFORM_IDENTITY
                    if joint.target!=core.NONE {
                        parent_bone,bound:=core.get(bones,joint.target)
                        if !bound || parent_bone.rig!=rig {
                            state.error=.Missing_Bone
                            core.report(problems,entity,"ragdoll.joint_target","Joint.target 0x%016x of this Driven ragdoll body is not a Ragdoll_Bone of the same rig, so it is not driven; target the body of its parent bone",u64(joint.target))
                            ragdoll_release(state,entity,bodies,joints,joint_rows);continue
                        }
                        if !ragdoll_bone_valid(parent_bone) {
                            state.error=.Invalid_Settings
                            bone_problem(problems,joint.target,parent_bone,.Invalid_Settings,capacity)
                            ragdoll_release(state,entity,bodies,joints,joint_rows);continue
                        }
                        parent_state,present_parent:=core.get(core.read(states),joint.target)
                        parent_binding:=parent_state.binding
                        parent_reference,_:=anim.bone_ref_hash(parent_bone.bone)
                        resolved:=present_parent && parent_binding.rig==rig && parent_binding.revision==revision && parent_state.reference==parent_reference
                        if !resolved {
                            parent_binding,resolved=anim.animation_bone_bind(playback.ptr,rig,parent_bone.bone)
                        }
                        if !resolved || parent_binding.index<0 || int(parent_binding.index)>=count {
                            state.error=.Missing_Bone
                            bone_problem(problems,joint.target,parent_bone,.Missing_Bone,capacity)
                            ragdoll_release(state,entity,bodies,joints,joint_rows);continue
                        }
                        frame_a=mm.transform_compose(runtime.pose[parent_binding.index],parent_bone.offset)
                    }
                    phys.set_joint_world_rotation(joints,entity,target.rotation,frame_a.rotation,config.hertz,config.damping_ratio,config.max_torque)
                }
            }
            state.mode,state.active=config.mode,true
        }
    }
}

@(step="fixed",loops="game editor",stage="react")
ragdoll_pose :: proc(configs:core.Read(Ragdoll),bones:core.Read(Ragdoll_Bone),states:core.Read(Ragdoll_State),transforms:core.Read(core.Transform),parents:core.Read(core.Parent),requests:^anim.Animation_Requests,time:core.Time,problems:^core.Problems) {
    if time.dt<=0 || !time.playing {return}
    for row in 0..<core.count(bones) {
        entity:=core.entity_at(bones,row)
        bone:=core.at(bones,row)
        config,exists:=core.get(configs,bone.rig)
        state,active:=core.get(states,entity)
        if !exists || !active || !state.active || state.error!=.None || config.mode==.Animated || config.mode==.Disabled || config.weight<=0 {continue}
        body,ok:=core.world_of(transforms,parents,entity)
        if !ok {
            core.report(problems,entity,"ragdoll.pose","the pose of this body was not sent to animation: it or a parent of it has no Transform; give them one")
            continue
        }
        world:=body
        world.rotation=body.rotation*mm.quat_inverse(bone.offset.rotation)
        world.position=body.position-mm.quat_rotate(world.rotation,body.scale*bone.offset.position)
        anim.animation_pose_final(requests,state.binding,world,config.weight)
    }
}

// Why a body of a ragdoll does not follow or drive its bone.
@(private)
bone_problem :: proc(problems:^core.Problems,e:core.Entity,bone:Ragdoll_Bone,error:Ragdoll_Error,capacity:int) {
    bone:=bone
    path:=base.text_get(bone.bone.path[:])
    switch error {
    case .None,.Unsupported_Joint,.Request_Capacity:
    case .Invalid_Settings:
        core.report(problems,e,"ragdoll.settings","its Ragdoll_Bone or the Ragdoll of rig 0x%016x is not valid: no rig or bone, an offset with scale or not finite, or a weight, hertz, damping or torque out of range; fix them",u64(bone.rig))
    case .Missing_Body:
        core.report(problems,e,"ragdoll.body","this Ragdoll_Bone has no dynamic Rigid_Body to move with bone '%s'; give it a Rigid_Body of type Dynamic",path)
    case .Missing_Rig:
        core.report(problems,e,"ragdoll.rig","rig 0x%016x of this Ragdoll_Bone has no animated pose: it has no Animation, or its skeleton is not bound; give the rig an Animation with a skeleton",u64(bone.rig))
    case .Missing_Bone:
        core.report(problems,e,"ragdoll.bone","bone '%s' of this Ragdoll_Bone is not in the skeleton of rig 0x%016x; name a bone of that skeleton (skeleton.inspect lists them)",path,u64(bone.rig))
    case .Pose_Capacity:
        core.report(problems,e,"ragdoll.max_bones","rig 0x%016x has more bones than Ragdoll_Settings.max_bones (%d), so this body does not follow it; raise max_bones",u64(bone.rig),capacity)
    }
}
