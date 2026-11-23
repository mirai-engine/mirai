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
@(private)
rig_shapes_check :: proc(profile:Pose_Profile) -> bool {
    if len(profile.spline_ik)>POSE_CONSTRAINTS || len(profile.follow)>POSE_CONSTRAINTS {return false}
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
    return valid
}
