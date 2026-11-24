package anim

import "core:math/linalg"
import "mirai:core"
import lib "mirai:std/anim"
import mm "mirai:std/math"

SPLINE_CONTROLS :: [4]string{"start","tangent_start","tangent_end","end"}

// Lays a chain along a cubic Bézier: start, the two tangent points and end,
// each a target, with the chain's up kept toward up and twist spread along it.
Spline_IK_Constraint :: struct {
    name:[64]u8 `mirai:"text"`,
    root,end:Bone_Ref,
    controls:[4]Spatial_Definition,
    up:mm.Vec3,
    twist:f32 `mirai:"angle"`,
    weight:f32 `mirai:"min=0,max=1"`,
    enabled:bool,
}
SPLINE_IK_CONSTRAINT_DEFAULT :: Spline_IK_Constraint{up={0,1,0},weight=1,enabled=true,controls={SPATIAL_DEFINITION_DEFAULT,SPATIAL_DEFINITION_DEFAULT,SPATIAL_DEFINITION_DEFAULT,SPATIAL_DEFINITION_DEFAULT}}

Spline_IK_Binding :: struct {
    using binding:Rig_Binding,
    targets:[4]Spatial_Target_Binding,
    bones:[RIG_CHAIN_BONES]i32,
    count:u8,
    points:[RIG_CHAIN_BONES]mm.Vec3,
    lengths:[RIG_CHAIN_BONES-1]f32,
}

// Drives a procedural helper bone from a driver bone's rotation relative to its rest pose:
// twist, swing or directional cone angle maps to a clamped [0, 1] weight scaling an additive
// local position/rotation/scale offset on the driven bone.
Pose_Corrective :: struct {
    name:[64]u8 `mirai:"text"`,
    driver,bone:Bone_Ref,
    mode:lib.Corrective_Mode `mirai:"optional"`,
    axis:mm.Vec3 `mirai:"optional"`,
    cone_axis:mm.Vec3 `mirai:"optional"`,
    min_angle,max_angle:f32 `mirai:"optional,angle"`,
    smooth:bool `mirai:"optional"`,
    position:mm.Vec3 `mirai:"optional,unit=m"`,
    rotation:mm.Quat `mirai:"optional"`,
    scale:mm.Vec3 `mirai:"optional"`,
    weight:f32 `mirai:"optional,min=0,max=1"`,
    enabled:bool `mirai:"optional"`,
}
POSE_CORRECTIVE_DEFAULT :: Pose_Corrective{
    mode=.Swing,
    axis={0,1,0},
    cone_axis={0,0,-1},
    min_angle=0,
    max_angle=mm.PI*0.5,
    rotation=1,
    scale={1,1,1},
    weight=1,
    enabled=true,
}

Corrective_Binding :: struct {
    using binding:Rig_Binding,
    driver,bone:i32,
    cyclic:bool,
}

@(private)
corrective_driver :: proc "contextless" (config:Pose_Corrective) -> lib.Corrective_Driver {
    return {
        mode=config.mode,
        axis=config.axis,
        cone_axis=config.cone_axis,
        min_angle=config.min_angle,
        max_angle=config.max_angle,
        smooth=config.smooth,
    }
}

@(private)
corrective_delta :: proc "contextless" (config:Pose_Corrective) -> mm.Transform {
    return {position=config.position,rotation=config.rotation,scale=config.scale}
}

@(private)
corrective_config :: proc "contextless" (config:Pose_Corrective) -> lib.Corrective {
    return {driver=corrective_driver(config),delta=corrective_delta(config)}
}

@(private)
rig_shapes_check :: proc(profile:Pose_Profile) -> bool {
    if len(profile.spline_ik)>POSE_CONSTRAINTS || len(profile.follow)>POSE_CONSTRAINTS || len(profile.correctives)>POSE_CONSTRAINTS {return false}
    for &value,i in profile.follow {
        if !rig_named_valid(value.name[:]) || !profile_bone(value.bone) || !spatial_target_valid(spatial_compile(&value.target),false) || !profile_weight(value.weight) || !value.position && !value.rotation && !value.scale {return false}
        for &other in profile.follow[:i] {if value.name==other.name {return false}}
    }
    for &value,i in profile.spline_ik {
        if !rig_named_valid(value.name[:]) || !profile_bone(value.root) || !profile_bone(value.end) || !profile_vector(value.up) || linalg.length(value.up)<1e-6 || !finite(value.twist) || !profile_weight(value.weight) {return false}
        settings:=lib.Spline_Chain{up=value.up,twist=value.twist}
        fixed:=true
        for &control,j in value.controls {
            if !spatial_target_valid(spatial_compile(&control),false) {return false}
            fixed &&=control.kind==.World
            settings.controls[j]=control.position
        }
        points:[2]mm.Vec3;lengths:=[1]f32{1}
        if fixed && !lib.spline_chain(settings,lengths[:],points[:]) {return false}
        for &other in profile.spline_ik[:i] {if value.name==other.name {return false}}
    }
    if len(profile.correctives)>0 {
        drivers,drivens:[POSE_CONSTRAINTS]u64
        for &value,i in profile.correctives {
            driver_hash,driver_ok:=bone_ref_hash(value.driver)
            bone_hash,bone_ok:=bone_ref_hash(value.bone)
            if !rig_named_valid(value.name[:]) || !driver_ok || !bone_ok || !profile_weight(value.weight) || !lib.corrective_valid(corrective_config(value)) {return false}
            for &other in profile.correctives[:i] {if value.name==other.name {return false}}
            drivers[i],drivens[i]=driver_hash,bone_hash
        }
        if !lib.corrective_acyclic(drivers[:len(profile.correctives)],drivens[:len(profile.correctives)]) {return false}
    }
    return true
}

@(private)
rig_shapes_apply :: proc(state:^Playing,runtime:^Modifier_Runtime,rig:^Modifier_Rig,pose:Pose_Profile,inputs:Constraint_Inputs,transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent,$A),root_transform:mm.Transform,playback:^Playback) -> bool {
    valid:=true
    skeleton:=playing_skeleton(state)
    for &config,slot in pose.spline_ik {
        weight,enabled:=modifier_weight(&modifier_states(rig,.Spline_IK)[slot],runtime.time)
        binding:=&rig.spline_states[slot]
        binding.diagnostic.valid,binding.diagnostic.reached=false,false
        if !rig_binding_current(binding,state) {
            binding.ready=false
            count,ok:=rig_chain_bind(state,config.root,config.end,binding.bones[:])
            if !ok {rig_problem(inputs.problems,state.entity,.Spline_IK,&config,.Bind);valid=false;continue}
            binding.count=u8(count);rig_binding_publish(binding,state,.Spline_IK)
        }
        if !enabled || weight<=0 {continue}
        settings:=lib.Spline_Chain{up=config.up,twist=config.twist}
        found:=true
        for &control,i in config.controls {
            target,ok:=spatial_target_sample(modifier_target(rig,.Spline_IK,slot,&control,i),&binding.targets[i],playback,inputs.skeletons,transforms,parents,inputs.worlds)
            settings.controls[i]=target.position;found &&=ok
        }
        if !found {modifier_request_rejected(runtime,state.entity,.Missing_Target);rig_problem(inputs.problems,state.entity,.Spline_IK,&config,.Target);valid=false;continue}
        count:=int(binding.count)
        solved:=lib.skeleton_spline_ik(skeleton,playing_pose(state,.Local),playing_pose(state,.World),binding.bones[:count],settings,binding.points[:count],binding.lengths[:count-1],weight,root_transform)
        binding.diagnostic.valid=solved
        if !solved {rig_problem(inputs.problems,state.entity,.Spline_IK,&config,.Solve)}
        if solved {
            binding.diagnostic.residual=linalg.length(playing_pose(state,.World)[binding.bones[count-1]].position-settings.controls[3])
            binding.diagnostic.reached=binding.diagnostic.residual<=.001
        }
        valid &&=solved
    }
    if len(pose.correctives)>0 {
        rebind:=false
        for _,slot in pose.correctives {
            if !rig_binding_current(&rig.corrective_states[slot],state) {rebind=true;break}
        }
        if rebind {
            drivers,drivens:[POSE_CONSTRAINTS]i32
            slots:[POSE_CONSTRAINTS]u16
            order:[POSE_CONSTRAINTS]u16
            peeled:[POSE_CONSTRAINTS]bool
            edges:=0
            for &config,slot in pose.correctives {
                binding:=&rig.corrective_states[slot]
                binding.ready=false
                binding.cyclic=false
                binding.driver=i32(bone_resolve(state,config.driver))
                binding.bone=i32(bone_resolve(state,config.bone))
                if binding.driver<0 || binding.bone<0 || binding.driver==binding.bone {continue}
                if edges<POSE_CONSTRAINTS {
                    drivers[edges],drivens[edges],slots[edges]=binding.driver,binding.bone,u16(slot)
                    edges+=1
                }
            }
            ordered,_:=lib.corrective_order(drivers[:edges],drivens[:edges],order[:edges],peeled[:edges])
            for e in 0..<edges {
                binding:=&rig.corrective_states[slots[e]]
                binding.cyclic=!peeled[e]
                rig_binding_publish(binding,state,.Corrective)
            }
            count:=min(ordered,len(rig.corrective_order))
            for k in 0..<count {
                rig.corrective_order[k]=slots[order[k]]
            }
            rig.corrective_order_count=u16(count)
        }
        changed:=false
        local:=playing_pose(state,.Local)
        for &config,slot in pose.correctives {
            binding:=&rig.corrective_states[slot]
            binding.diagnostic.valid,binding.diagnostic.reached=false,false
            if !binding.ready || binding.cyclic {
                rig_problem(inputs.problems,state.entity,.Corrective,&config,.Bind)
                valid=false
            }
        }
        if !state.lod.plain {
            for k in 0..<int(rig.corrective_order_count) {
                slot:=int(rig.corrective_order[k])
                config:=&pose.correctives[slot]
                weight,enabled:=modifier_weight(&modifier_states(rig,.Corrective)[slot],runtime.time)
                binding:=&rig.corrective_states[slot]
                if !enabled || weight<=0 {continue}
                if _,ok:=lib.corrective_solve(skeleton.rest,local,binding.driver,binding.bone,corrective_config(config^),weight);!ok {
                    rig_problem(inputs.problems,state.entity,.Corrective,config,.Solve)
                    valid=false
                    continue
                }
                binding.diagnostic.valid,binding.diagnostic.reached=true,true
                changed=true
            }
        }
        if changed && !lib.pose_world(skeleton.parents,local,playing_pose(state,.World),root_transform) {
            pose_problem(inputs.problems,state.entity)
            valid=false
        }
    }
    return valid
}
