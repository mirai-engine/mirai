package anim

import "core:math/linalg"
import "mirai:core"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

RIG_POSE_SAMPLES :: 16
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

// A pose of the driver bone and what it brings at it: a delta of a bone and a
// value of a curve, both blended by how near the driver is to each sample.
Pose_Corrective_Sample :: struct {
    rotation:mm.Quat,
    delta:mm.Transform,
    curve_value:f32,
}
POSE_CORRECTIVE_SAMPLE_DEFAULT :: Pose_Corrective_Sample{rotation=1,delta=mm.TRANSFORM_IDENTITY}
// curve: the name of a Float curve it adds to, such as a morph target the
// mesh of the rig has.
Pose_Corrective :: struct {
    name:[64]u8 `mirai:"text"`,
    driver,bone:Bone_Ref,
    curve:[64]u8 `mirai:"text"`,
    sample_count:u8,
    samples:[RIG_POSE_SAMPLES]Pose_Corrective_Sample,
    weight:f32 `mirai:"min=0,max=1"`,
    apply_pose,enabled:bool,
}
POSE_CORRECTIVE_DEFAULT :: Pose_Corrective{weight=1,apply_pose=true,enabled=true}

Spline_IK_Binding :: struct {
    using binding:Rig_Binding,
    targets:[4]Spatial_Target_Binding,
    bones:[RIG_CHAIN_BONES]i32,
    count:u8,
    points:[RIG_CHAIN_BONES]mm.Vec3,
    lengths:[RIG_CHAIN_BONES-1]f32,
}
Pose_Corrective_Binding :: struct {
    using binding:Rig_Binding,
    driver,bone:i32,
    curve:u64,
    value:f32,
    rotations:[RIG_POSE_SAMPLES]mm.Quat,
    weights:[RIG_POSE_SAMPLES]f32,
}

@(private)
rig_shapes_check :: proc(profile:Pose_Profile) -> bool {
    if len(profile.spline_ik)>POSE_CONSTRAINTS || len(profile.correctives)>POSE_CONSTRAINTS || len(profile.follow)>POSE_CONSTRAINTS {return false}
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
    for &value,i in profile.correctives {
        if !rig_named_valid(value.name[:]) || !profile_bone(value.driver) || value.apply_pose && !profile_bone(value.bone) || !blend_text_valid(value.curve[:],true) || !value.apply_pose && base.text_get(value.curve[:])=="" || value.sample_count==0 || int(value.sample_count)>RIG_POSE_SAMPLES || !profile_weight(value.weight) {return false}
        rotations:[RIG_POSE_SAMPLES]mm.Quat;weights:[RIG_POSE_SAMPLES]f32
        for sample,j in value.samples[:value.sample_count] {
            if !profile_rotation(sample.rotation) || !spatial_transform_valid(sample.delta) || !finite(sample.curve_value) {return false}
            rotations[j]=sample.rotation
        }
        if !lib.pose_sample_weights(rotations[0],rotations[:value.sample_count],weights[:value.sample_count]) {return false}
        for &other in profile.correctives[:i] {if value.name==other.name {return false}}
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
    for &config,slot in pose.correctives {
        weight,enabled:=modifier_weight(&modifier_states(rig,.Corrective)[slot],runtime.time)
        binding:=&rig.corrective_states[slot]
        binding.diagnostic.valid=false;binding.value=0
        if config.sample_count==0 || int(config.sample_count)>RIG_POSE_SAMPLES {rig_problem(inputs.problems,state.entity,.Corrective,&config,.Bind);valid=false;continue}
        if !rig_binding_current(binding,state) {
            binding.ready=false
            binding.driver,binding.bone=i32(bone_resolve(state,config.driver)),i32(bone_resolve(state,config.bone))
            if binding.driver<0 || config.apply_pose && binding.bone<0 {rig_problem(inputs.problems,state.entity,.Corrective,&config,.Bind);valid=false;continue}
            binding.curve=base.name_hash(base.text_get(config.curve[:]))
            for sample,i in config.samples[:config.sample_count] {binding.rotations[i]=sample.rotation}
            rig_binding_publish(binding,state,.Corrective)
        }
        if !enabled || weight<=0 {continue}
        // The driver as the animation posed it, before other operations moved it.
        rotation:=playing_pose(state,.Sampled)[binding.driver].rotation if len(playing_pose(state,.Sampled))==len(playing_pose(state,.Local)) else playing_pose(state,.Local)[binding.driver].rotation
        solved:=lib.pose_sample_weights(rotation,binding.rotations[:config.sample_count],binding.weights[:config.sample_count])
        if !solved {rig_problem(inputs.problems,state.entity,.Corrective,&config,.Solve);valid=false;continue}
        delta:mm.Transform
        anchor:=config.samples[0].delta.rotation
        for sample,i in config.samples[:config.sample_count] {
            influence:=binding.weights[i]
            turn:=sample.delta.rotation
            if linalg.dot(anchor,turn)<0 {turn=-turn}
            delta.position+=sample.delta.position*influence
            delta.scale+=sample.delta.scale*influence
            delta.rotation.x+=turn.x*influence;delta.rotation.y+=turn.y*influence;delta.rotation.z+=turn.z*influence;delta.rotation.w+=turn.w*influence
            binding.value+=sample.curve_value*influence*weight
        }
        if !finite(binding.value) {rig_problem(inputs.problems,state.entity,.Corrective,&config,.Solve);valid=false;binding.value=0;continue}
        if config.apply_pose {
            delta.rotation=linalg.normalize0(delta.rotation)
            local:=&playing_pose(state,.Local)[binding.bone]
            local.position+=delta.position*weight
            local.rotation=linalg.normalize0(local.rotation*mm.quat_slerp(1,delta.rotation,weight))
            local.scale*=mm.Vec3{1,1,1}+(delta.scale-mm.Vec3{1,1,1})*weight
            solved=lib.pose_world(skeleton.parents,playing_pose(state,.Local),playing_pose(state,.World),root_transform)
            if !solved {rig_problem(inputs.problems,state.entity,.Corrective,&config,.Solve)}
        }
        binding.diagnostic.valid,binding.diagnostic.reached=solved,solved
        valid &&=solved
    }
    return valid
}

// What the correctives of a rig add to the curve of this name hash in this tick.
animation_corrective_curve :: proc(runtime:core.Ref(Modifier_Runtime),entity:core.Entity,target:u64) -> f32 {
    rig:=modifier_rig(runtime,entity)
    if rig==nil {return 0}
    result:f32
    for &binding in rig.corrective_states {
        if binding.ready && binding.rig==entity && binding.curve==target && binding.diagnostic.valid {result+=binding.value}
    }
    return result
}
