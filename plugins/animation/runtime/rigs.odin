package anim

import "core:math/linalg"
import "mirai:core"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

RIG_CHAIN_BONES :: 64
RIG_EFFECTORS :: 16
RIG_COLLISIONS :: 16

Chain_IK_Constraint :: struct {
    name:[64]u8 `mirai:"text"`,
    root,end:Bone_Ref,
    target:Spatial_Definition,
    pole:mm.Vec3,
    iterations:u16,
    tolerance,weight:f32,
    reach:lib.Chain_Reach, // a softened approach to full extension and how far the chain may stretch past it
    limit_count:u8,
    limits:[RIG_CHAIN_BONES-2]lib.Chain_Limit,
    use_pole,enabled:bool,
}
CHAIN_IK_CONSTRAINT_DEFAULT :: Chain_IK_Constraint{target=SPATIAL_DEFINITION_DEFAULT,iterations=24,tolerance=.001,weight=1,enabled=true}

Twist_Constraint :: struct {
    name:[64]u8 `mirai:"text"`,
    source,root,end:Bone_Ref,
    axis:mm.Vec3,
    reference:mm.Quat,
    amount_count:u8,
    amounts:[RIG_CHAIN_BONES]f32,
    weight:f32,
    enabled:bool,
}
TWIST_CONSTRAINT_DEFAULT :: Twist_Constraint{axis={0,1,0},reference=1,weight=1,enabled=true}

Spring_Constraint :: struct {
    name:[64]u8 `mirai:"text"`,
    root,end:Bone_Ref,
    settings:lib.Spring_Chain,
    limit_count,collision_count:u8,
    limits:[RIG_CHAIN_BONES-2]lib.Chain_Limit,
    collisions:[RIG_COLLISIONS]lib.Spring_Collision,
    weight:f32,
    enabled:bool,
}
SPRING_CONSTRAINT_DEFAULT :: Spring_Constraint{settings=lib.SPRING_CHAIN_DEFAULT,weight=1,enabled=true}

Multi_IK_Joint :: struct {
    bone:Bone_Ref,
    stiffness:f32 `mirai:"optional,min=0,max=1"`,
    preferred:mm.Quat `mirai:"optional"`,
    preferred_weight:f32 `mirai:"optional,min=0,max=1"`,
    frame:mm.Quat `mirai:"optional"`, // the limit axes X, Y and Z in the frame of the bone at rest
    limits:[3]lib.Multi_IK_Limit `mirai:"optional"`, // from rest, about each axis: two Locked make a hinge
}
MULTI_IK_JOINT_DEFAULT :: Multi_IK_Joint{preferred=1,frame=1}
// A bone that reaches the position of its target by position_weight and its
// rotation by rotation_weight.
Multi_IK_Effector :: struct {
    name:[64]u8 `mirai:"text"`,
    bone:Bone_Ref,
    target:Spatial_Definition `mirai:"optional"`,
    position_weight,rotation_weight:f32 `mirai:"optional,min=0,max=1"`,
}
MULTI_IK_EFFECTOR_DEFAULT :: Multi_IK_Effector{target=SPATIAL_DEFINITION_DEFAULT,position_weight=1}
Multi_IK_Constraint :: struct {
    using definition:Multi_IK_Definition,
    joints:[]Multi_IK_Joint,
    effectors:[]Multi_IK_Effector,
}
Multi_IK_Definition :: struct {
    name:[64]u8 `mirai:"text"`,
    root:Bone_Ref,
    settings:lib.Multi_IK,
    weight:f32,
    enabled:bool,
}
MULTI_IK_CONSTRAINT_DEFAULT :: Multi_IK_Constraint{definition={settings=lib.MULTI_IK_DEFAULT,weight=1,enabled=true}}

Chain_Retarget_Constraint :: struct {
    name:[64]u8 `mirai:"text"`,
    source_root,source_end,target_root,target_end:Bone_Ref,
    weight:f32,
    enabled:bool,
}
CHAIN_RETARGET_CONSTRAINT_DEFAULT :: Chain_Retarget_Constraint{weight=1,enabled=true}

Rig_Diagnostic :: struct {rig:core.Entity,kind:Modifier_Kind,residual,angular_error:f32,iterations:int,reached,valid:bool}
Rig_Binding :: struct {
    rig:core.Entity,
    bound:u64,
    generation:u32,
    diagnostic:Rig_Diagnostic,
    ready:bool,
}
Chain_IK_Binding :: struct {
    using binding:Rig_Binding,
    target:Spatial_Target_Binding,
    bones:[RIG_CHAIN_BONES]i32,
    count:u8,
    points,solved:[RIG_CHAIN_BONES]mm.Vec3,
    lengths:[RIG_CHAIN_BONES-1]f32,
}
Twist_Binding :: struct {
    using binding:Rig_Binding,
    bones:[RIG_CHAIN_BONES]i32,
    count:u8,
    source_index:i32,
    amounts:[RIG_CHAIN_BONES]f32,
    original:[RIG_CHAIN_BONES]mm.Quat,
}
Spring_Binding :: struct {
    using binding:Rig_Binding,
    bones:[RIG_CHAIN_BONES]i32,
    count:u8,
    points,solved:[RIG_CHAIN_BONES]mm.Vec3,
    lengths:[RIG_CHAIN_BONES-1]f32,
    springs:[RIG_CHAIN_BONES]lib.Spring_Joint_State,
}
Multi_IK_Binding :: struct {
    using binding:Rig_Binding,
    root:i32,
    joints:[RIG_CHAIN_BONES]lib.Multi_IK_Joint,
    effectors:[RIG_EFFECTORS]lib.Multi_IK_Effector,
    targets:[RIG_EFFECTORS]Spatial_Target_Binding,
    residuals:[RIG_EFFECTORS]f32,
    backup:[dynamic]mm.Transform,
    links:[dynamic]lib.Pose_Link,
}
Chain_Retarget_Binding :: struct {
    using binding:Rig_Binding,
    source:core.Entity,
    source_bound:u64,
    source_generation:u32,
    bones,source_bones:[RIG_CHAIN_BONES]i32,
    count,source_count:u8,
    mappings:[RIG_CHAIN_BONES]lib.Chain_Retarget_Bone,
    source_rest,source_pose,target_rest:[dynamic]mm.Transform,
    source_world,target_world:[dynamic]mm.Transform,
    source_wrapper,target_wrapper:bool,
}

@(private)
rig_binding_free :: proc(binding:^$T) {
    when T==Chain_IK_Binding || T==Follow_Binding || T==IK_Binding || T==Look_Binding {delete(binding.target.path)}
    when T==Look_Binding {delete(binding.previous.path)}
    when T==Spline_IK_Binding {for target in binding.targets {delete(target.path)}}
    when T==Multi_IK_Binding {for target in binding.targets {delete(target.path)};delete(binding.backup);delete(binding.links)}
    when T==Chain_Retarget_Binding {
        delete(binding.source_rest);delete(binding.source_pose);delete(binding.target_rest)
        delete(binding.source_world);delete(binding.target_world)
    }
    binding^={}
}
@(private)
rig_chain_bind :: proc(state:^Playing,root,end:Bone_Ref,out:[]i32) -> (count:int,ok:bool) {
    first,last:=bone_resolve(state,root),bone_resolve(state,end)
    return lib.skeleton_chain(playing_skeleton(state),i32(first),i32(last),out)
}

@(private)
rig_named_valid :: proc(name:[]u8) -> bool {return blend_text_valid(name,false)}
@(private)
rig_limits_valid :: proc(limits:[]lib.Chain_Limit) -> bool {
    for value in limits {if !finite(value.min_bend) || !finite(value.max_bend) || value.min_bend<0 || value.min_bend>value.max_bend || value.max_bend>mm.PI {return false}}
    return true
}

rig_profiles_check :: proc(profile:Pose_Profile) -> bool {
    if len(profile.chain_ik)>POSE_CONSTRAINTS || len(profile.twist)>POSE_CONSTRAINTS || len(profile.springs)>POSE_CONSTRAINTS || len(profile.multi_ik)>POSE_CONSTRAINTS || len(profile.retarget_chains)>POSE_CONSTRAINTS {return false}
    for &value,i in profile.chain_ik {
        if !spatial_target_valid(spatial_compile(&value.target),false) || !finite(value.reach.soft_distance) || value.reach.soft_distance<0 || !finite(value.reach.max_stretch) || value.reach.max_stretch<0 {return false}
        if !rig_named_valid(value.name[:]) || !profile_bone(value.root) || !profile_bone(value.end) || !profile_vector(value.pole) || !profile_weight(value.weight) || value.iterations<1 || value.iterations>256 || !finite(value.tolerance) || value.tolerance<0 || int(value.limit_count)>RIG_CHAIN_BONES-2 || !rig_limits_valid(value.limits[:value.limit_count]) {return false}
        for &other in profile.chain_ik[:i] {if value.name==other.name {return false}}
    }
    for &value,i in profile.twist {
        if !rig_named_valid(value.name[:]) || !profile_bone(value.source) || !profile_bone(value.root) || !profile_bone(value.end) || !profile_vector(value.axis) || linalg.length(value.axis)<1e-6 || !profile_rotation(value.reference) || !profile_weight(value.weight) || int(value.amount_count)>RIG_CHAIN_BONES {return false}
        total:f32;for amount in value.amounts[:value.amount_count] {if !finite(amount) || amount<0 {return false};total+=amount}
        if value.amount_count>0 && (!finite(total) || total<=0) {return false}
        for &other in profile.twist[:i] {if value.name==other.name {return false}}
    }
    for &value,i in profile.springs {
        s:=value.settings
        if !rig_named_valid(value.name[:]) || !profile_bone(value.root) || !profile_bone(value.end) || !profile_weight(value.weight) || int(value.limit_count)>RIG_CHAIN_BONES-2 || int(value.collision_count)>RIG_COLLISIONS || !rig_limits_valid(value.limits[:value.limit_count]) || !profile_vector(s.gravity) || !profile_vector(s.force) || s.iterations<1 || s.iterations>256 || !finite(s.max_step) || s.max_step<=0 {return false}
        for number in ([?]f32{s.stiffness,s.damping,s.radius,s.reset_distance}) {if !finite(number) || number<0 {return false}}
        for collision in value.collisions[:value.collision_count] {if !profile_vector(collision.position) || !finite(collision.radius) || collision.radius<0 {return false}}
        for &other in profile.springs[:i] {if value.name==other.name {return false}}
    }
    for &value,i in profile.multi_ik {
        s:=value.settings
        if !rig_named_valid(value.name[:]) || !profile_bone(value.root) || len(value.joints)==0 || len(value.joints)>RIG_CHAIN_BONES || len(value.effectors)==0 || len(value.effectors)>RIG_EFFECTORS || !profile_weight(value.weight) || s.root_policy>max(lib.Multi_IK_Root_Policy) || s.iterations<1 || s.iterations>256 || !finite(s.tolerance) || s.tolerance<0 || !profile_weight(s.root_stiffness) || !finite(s.max_root_translation) || s.max_root_translation<0 || !profile_weight(s.relaxation) || s.relaxation==0 {return false}
        if !finite(s.angular_tolerance) || s.angular_tolerance<0 {return false}
        for &joint,j in value.joints {
            if !profile_bone(joint.bone) || !profile_weight(joint.stiffness) || !profile_weight(joint.preferred_weight) || !profile_rotation(joint.preferred) {return false}
            if _,ok:=lib.joint_limit_axes(1,1,1,joint.limits);!ok || !profile_rotation(joint.frame) {return false}
            for other in value.joints[:j] {if joint.bone==other.bone {return false}}
        }
        for &effector,j in value.effectors {
            if !rig_named_valid(effector.name[:]) || !profile_bone(effector.bone) || !spatial_target_valid(spatial_compile(&effector.target),false) || !profile_weight(effector.position_weight) || !profile_weight(effector.rotation_weight) {return false}
            for other in value.effectors[:j] {if effector.name==other.name {return false}}
        }
        for &other in profile.multi_ik[:i] {if value.name==other.name {return false}}
    }
    for &value,i in profile.retarget_chains {
        if !rig_named_valid(value.name[:]) || !profile_bone(value.source_root) || !profile_bone(value.source_end) || !profile_bone(value.target_root) || !profile_bone(value.target_end) || !profile_weight(value.weight) {return false}
        for &other in profile.retarget_chains[:i] {if value.name==other.name {return false}}
    }
    return rig_shapes_check(profile)
}

@(private)
rig_binding_current :: proc(binding:^$T,state:^Playing) -> bool {return binding.ready && binding.rig==state.entity && binding.bound==state.bound && binding.generation==state.generation}
@(private)
rig_binding_publish :: proc(binding:^$T,state:^Playing,kind:Modifier_Kind) {
    binding.rig,binding.bound,binding.generation=state.entity,state.bound,state.generation
    binding.ready=true;binding.diagnostic={rig=state.entity,kind=kind}
}

rigs_apply :: proc(state:^Playing,runtime:^Modifier_Runtime,rig:^Modifier_Rig,pose:Pose_Profile,inputs:Constraint_Inputs,transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent,.Read),root_transform:mm.Transform,dt:f32,playback:^Playback=nil) -> bool {
    if state==nil || runtime==nil || !finite(dt) || dt<0 {return false}
    valid:=rigs_chains_apply(state,runtime,rig,pose,inputs,transforms,parents,root_transform,dt,playback)
    shaped:=rig_shapes_apply(state,runtime,rig,pose,inputs,transforms,parents,root_transform,playback)
    followed:=follow_apply(state,runtime,rig,pose,inputs,transforms,parents,root_transform,playback)
    return valid && shaped && followed
}

// Why an operation of the .character of a rig did nothing in a tick.
@(private)
Rig_Failure :: enum u8 {Bind,Target,Solve,Source}

@(private)
rig_problem :: proc(problems:^core.Problems,rig:core.Entity,kind:Modifier_Kind,value:^$T,failure:Rig_Failure,source:=core.NONE) {
    name:=modifier_operation_name(value)
    switch failure {
    case .Bind:
        core.report(problems,rig,"animation.rig_bind","%v '%s' of the .character of this rig cannot bind: its bones are not in this skeleton or not a chain from root to end, or its limits, amounts or samples do not match them; fix it in the .character",kind,name)
    case .Target:
        core.report(problems,rig,"animation.rig_target","%v '%s' of this rig has no target: its entity is gone or has no Transform, its rig is not animated in this tick, or its bone or socket is not in that skeleton; give it a target that exists",kind,name)
    case .Solve:
        core.report(problems,rig,"animation.rig_solve","%v '%s' of this rig could not be solved: a value of it, of its targets or of the pose is not finite or is out of range; check them (animation.inspect shows its diagnostic)",kind,name)
    case .Source:
        core.report(problems,rig,"animation.rig_source","%v '%s' of this rig maps the sampled pose of another rig, and its Pose_Source names entity 0x%016x, which is not another rig animated in this tick, or not with stage Sampled; give it a Pose_Source of stage Sampled that names one",kind,name,u64(source))
    }
}

@(private)
rigs_chains_apply :: proc(state:^Playing,runtime:^Modifier_Runtime,rig:^Modifier_Rig,pose:Pose_Profile,inputs:Constraint_Inputs,transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent,.Read),root_transform:mm.Transform,dt:f32,playback:^Playback) -> bool {
    if len(pose.chain_ik)+len(pose.multi_ik)+len(pose.twist)+len(pose.springs)==0 {return true}
    skeleton:=playing_skeleton(state);valid:=true
    for &config,slot in pose.chain_ik {
        weight,enabled:=modifier_weight(&modifier_states(rig,.Chain_IK)[slot],runtime.time)
        binding:=&rig.chain_states[slot]
        binding.diagnostic.valid=false
        if int(config.limit_count)>RIG_CHAIN_BONES-2 {rig_problem(inputs.problems,state.entity,.Chain_IK,&config,.Bind);valid=false;continue}
        if !rig_binding_current(binding,state) {
            binding.ready=false
            count,ok:=rig_chain_bind(state,config.root,config.end,binding.bones[:])
            if !ok || config.limit_count>0 && int(config.limit_count)!=count-2 {rig_problem(inputs.problems,state.entity,.Chain_IK,&config,.Bind);valid=false;continue}
            binding.count=u8(count);rig_binding_publish(binding,state,.Chain_IK)
        }
        if !enabled || weight<=0 {continue}
        target,ok:=spatial_target_sample(modifier_target(rig,.Chain_IK,slot,&config.target),&binding.target,playback,inputs.skeletons,transforms,parents,inputs.worlds)
        if !ok {modifier_request_rejected(runtime,state.entity,.Missing_Target);rig_problem(inputs.problems,state.entity,.Chain_IK,&config,.Target);valid=false;continue}
        count:=int(binding.count)
        result,solved:=lib.skeleton_chain_ik(skeleton,playing_pose(state,.Local),playing_pose(state,.World),binding.bones[:count],config.limits[:config.limit_count],{target=target.position,pole=config.pole,use_pole=config.use_pole,iterations=int(config.iterations),tolerance=config.tolerance},binding.points[:count],binding.solved[:count],binding.lengths[:count-1],weight,root_transform,config.reach)
        binding.diagnostic.residual,binding.diagnostic.iterations,binding.diagnostic.reached,binding.diagnostic.valid=result.error,result.iterations,result.reached,solved
        if !solved {rig_problem(inputs.problems,state.entity,.Chain_IK,&config,.Solve)}
        valid &&=solved
    }
    for &config,slot in pose.multi_ik {
        weight,enabled:=modifier_weight(&modifier_states(rig,.Multi_IK)[slot],runtime.time)
        binding:=&rig.multi_states[slot]
        binding.diagnostic.valid=false
        if len(config.joints)==0 || len(config.joints)>RIG_CHAIN_BONES || len(config.effectors)==0 || len(config.effectors)>RIG_EFFECTORS {rig_problem(inputs.problems,state.entity,.Multi_IK,&config,.Bind);valid=false;continue}
        if !rig_binding_current(binding,state) {
            binding.ready=false;binding.root=i32(bone_resolve(state,config.root));bound:=binding.root>=0
            for joint,i in config.joints {
                bone:=bone_resolve(state,joint.bone);bound &&=bone>=0
                binding.joints[i]={bone=i32(bone),stiffness=joint.stiffness,preferred=joint.preferred,preferred_weight=joint.preferred_weight,frame=joint.frame,limits=joint.limits}
            }
            for effector,i in config.effectors {bone:=bone_resolve(state,effector.bone);bound &&=bone>=0;binding.effectors[i].bone=i32(bone)}
            if !bound {rig_problem(inputs.problems,state.entity,.Multi_IK,&config,.Bind);valid=false;continue}
            if resize(&binding.backup,len(playing_pose(state,.Local)))!=nil || resize(&binding.links,len(playing_pose(state,.Local)))!=nil {memory_problem(inputs.problems,state.entity,"a Multi IK of its .character");valid=false;continue}
            if _,linked:=lib.pose_hierarchy_prepare(skeleton.parents,binding.links[:]);!linked {rig_problem(inputs.problems,state.entity,.Multi_IK,&config,.Bind);valid=false;continue}
            rig_binding_publish(binding,state,.Multi_IK)
        }
        if !enabled || weight<=0 {continue}
        targets_valid:=true
        for &effector,i in config.effectors {
            target,ok:=spatial_target_sample(modifier_target(rig,.Multi_IK,slot,&effector.target,i),&binding.targets[i],playback,inputs.skeletons,transforms,parents,inputs.worlds);targets_valid &&=ok
            bone:=binding.effectors[i].bone
            binding.effectors[i]={bone=bone,position=target.position,rotation=target.rotation,position_weight=effector.position_weight,rotation_weight=effector.rotation_weight}
        }
        if !targets_valid {modifier_request_rejected(runtime,state.entity,.Missing_Target);rig_problem(inputs.problems,state.entity,.Multi_IK,&config,.Target);valid=false;continue}
        copy(binding.backup[:],playing_pose(state,.Local));settings:=config.settings;settings.root=binding.root
        result,solved:=lib.multi_ik(skeleton,{skeleton.parents,binding.links[:]},playing_pose(state,.Local),playing_pose(state,.World),binding.joints[:len(config.joints)],binding.effectors[:len(config.effectors)],settings,binding.residuals[:len(config.effectors)],root_transform)
        if solved && weight!=1 {
            for &local,i in playing_pose(state,.Local) {local=mm.transform_interpolate(binding.backup[i],local,weight)}
            solved=lib.pose_world(skeleton.parents,playing_pose(state,.Local),playing_pose(state,.World),root_transform)
            result.residual,result.angular_error=0,0
            for effector in binding.effectors[:len(config.effectors)] {
                result.residual=max(result.residual,linalg.length(playing_pose(state,.World)[effector.bone].position-effector.position)*effector.position_weight)
                result.angular_error=max(result.angular_error,mm.quat_angle(playing_pose(state,.World)[effector.bone].rotation,effector.rotation)*effector.rotation_weight)
            }
            result.reached=result.residual<=settings.tolerance && result.angular_error<=settings.angular_tolerance
        } else if !solved {copy(playing_pose(state,.Local),binding.backup[:]);lib.skeleton_world(skeleton,playing_pose(state,.Local),playing_pose(state,.World),root_transform)}
        binding.diagnostic.residual,binding.diagnostic.iterations,binding.diagnostic.reached,binding.diagnostic.valid=result.residual,result.iterations,result.reached,solved
        binding.diagnostic.angular_error=result.angular_error
        if !solved {rig_problem(inputs.problems,state.entity,.Multi_IK,&config,.Solve)}
        valid &&=solved
    }
    for &config,slot in pose.twist {
        weight,enabled:=modifier_weight(&modifier_states(rig,.Twist)[slot],runtime.time)
        binding:=&rig.twist_states[slot]
        binding.diagnostic.valid=false
        if int(config.amount_count)>RIG_CHAIN_BONES {rig_problem(inputs.problems,state.entity,.Twist,&config,.Bind);valid=false;continue}
        if !rig_binding_current(binding,state) {
            binding.ready=false;count,ok:=rig_chain_bind(state,config.root,config.end,binding.bones[:]);binding.source_index=i32(bone_resolve(state,config.source))
            if !ok || binding.source_index<0 || config.amount_count>0 && int(config.amount_count)!=count {rig_problem(inputs.problems,state.entity,.Twist,&config,.Bind);valid=false;continue}
            binding.count=u8(count)
            for &amount,i in binding.amounts[:count] {amount=config.amounts[i] if config.amount_count>0 else 1}
            rig_binding_publish(binding,state,.Twist)
        }
        if !enabled || weight<=0 || state.lod.plain {continue}
        count:=int(binding.count)
        solved:=lib.skeleton_twist(skeleton,playing_pose(state,.Local),playing_pose(state,.World),binding.source_index,binding.bones[:count],binding.amounts[:count],config.axis,config.reference,binding.original[:count],weight,root_transform)
        if !solved {rig_problem(inputs.problems,state.entity,.Twist,&config,.Solve)}
        binding.diagnostic.valid=solved;valid &&=solved
    }
    for &config,slot in pose.springs {
        weight,enabled:=modifier_weight(&modifier_states(rig,.Spring)[slot],runtime.time)
        binding:=&rig.spring_states[slot]
        binding.diagnostic.valid=false
        if int(config.limit_count)>RIG_CHAIN_BONES-2 || int(config.collision_count)>RIG_COLLISIONS {rig_problem(inputs.problems,state.entity,.Spring,&config,.Bind);valid=false;continue}
        if !rig_binding_current(binding,state) {
            binding.ready=false;count,ok:=rig_chain_bind(state,config.root,config.end,binding.bones[:])
            if !ok || config.limit_count>0 && int(config.limit_count)!=count-2 {rig_problem(inputs.problems,state.entity,.Spring,&config,.Bind);valid=false;continue}
            binding.count=u8(count);binding.springs={};rig_binding_publish(binding,state,.Spring)
        }
        if !enabled || weight<=0 {if binding.springs[0].ready {binding.springs={}};continue}
        if state.lod.plain {continue}
        if !lib.skeleton_world(skeleton,playing_pose(state,.Local),playing_pose(state,.World),root_transform) {rig_problem(inputs.problems,state.entity,.Spring,&config,.Solve);valid=false;continue}
        count:=int(binding.count)
        for bone,i in binding.bones[:count] {binding.points[i]=playing_pose(state,.World)[bone].position;if i>0 {binding.lengths[i-1]=linalg.length(binding.points[i]-binding.points[i-1])}}
        settings:=config.settings
        if override:=modifier_override(rig,.Spring,slot);override!=nil {settings.force=override.position}
        result,solved:=lib.spring_chain_update(binding.points[:count],binding.lengths[:count-1],config.limits[:config.limit_count],config.collisions[:config.collision_count],settings,dt,binding.springs[:count],binding.solved[:count])
        if solved {solved=lib.skeleton_chain_from_points(skeleton,playing_pose(state,.Local),playing_pose(state,.World),binding.bones[:count],binding.solved[:count],weight,root_transform)}
        binding.diagnostic.residual,binding.diagnostic.iterations,binding.diagnostic.valid=result.residual,result.substeps,solved
        if !solved {rig_problem(inputs.problems,state.entity,.Spring,&config,.Solve)}
        valid &&=solved
    }
    return valid
}

// Gives a rig that takes the sampled pose of another (Pose_Source of stage Sampled) that pose
// through the Chain Retarget rows of its .character: true when it has any.
rigs_retarget :: proc(state:^Playing,playback:^Playback,runtime:^Modifier_Runtime,rig:^Modifier_Rig,pose:Pose_Profile,problems:^core.Problems) -> bool {
    if state==nil || playback==nil || runtime==nil {return false}
    if len(pose.retarget_chains)==0 {return false}
    for &config,slot in pose.retarget_chains {
        weight,enabled:=modifier_weight(&modifier_states(rig,.Chain_Retarget)[slot],runtime.time)
        binding:=&rig.retarget_chain_states[slot]
        binding.diagnostic.valid=false
        if !enabled || weight<=0 {continue}
        source:=constraint_playing(core.ref(playback),state.leader) if state.stage==.Sampled else nil
        if source==nil || source==state || len(playing_pose(source,.Sampled))!=len(playing_topology(source).rest) {rig_problem(problems,state.entity,.Chain_Retarget,&config,.Source,state.leader);continue}
        if !rig_binding_current(binding,state) || binding.source!=source.entity || binding.source_bound!=source.bound || binding.source_generation!=source.generation {
            binding.ready=false
            count,ok:=rig_chain_bind(state,config.target_root,config.target_end,binding.bones[:]);source_count,source_ok:=rig_chain_bind(source,config.source_root,config.source_end,binding.source_bones[:])
            if !ok || !source_ok {rig_problem(problems,state.entity,.Chain_Retarget,&config,.Bind);continue}
            if resize(&binding.source_rest,len(playing_topology(source).rest))!=nil || resize(&binding.source_pose,len(playing_topology(source).rest))!=nil || resize(&binding.source_world,len(playing_topology(source).rest))!=nil || resize(&binding.target_rest,len(playing_topology(state).rest))!=nil || resize(&binding.target_world,len(playing_topology(state).rest))!=nil {memory_problem(problems,state.entity,"a Chain Retarget of its .character");continue}
            copy(binding.source_rest[:],playing_topology(source).rest[:]);copy(binding.target_rest[:],playing_topology(state).rest[:])
            binding.source_wrapper=source.bindings[0].target==0 && playing_topology(source).parents[0]<0 && binding.source_bones[0]!=0
            binding.target_wrapper=state.bindings[0].target==0 && playing_topology(state).parents[0]<0 && binding.bones[0]!=0
            if binding.source_wrapper {binding.source_rest[0]=mm.TRANSFORM_IDENTITY}
            if binding.target_wrapper {binding.target_rest[0]=mm.TRANSFORM_IDENTITY}
            source_skeleton,target_skeleton:=playing_skeleton(source),playing_skeleton(state)
            source_skeleton.rest,target_skeleton.rest=binding.source_rest[:],binding.target_rest[:]
            if !lib.chain_retarget_prepare(source_skeleton,target_skeleton,binding.source_bones[:source_count],binding.bones[:count],binding.source_world[:],binding.target_world[:],binding.mappings[:count]) {rig_problem(problems,state.entity,.Chain_Retarget,&config,.Solve);continue}
            binding.count,binding.source_count=u8(count),u8(source_count);binding.source,binding.source_bound,binding.source_generation=source.entity,source.bound,source.generation
            rig_binding_publish(binding,state,.Chain_Retarget)
        }
        copy(binding.source_pose[:],playing_pose(source,.Sampled));if binding.source_wrapper {binding.source_pose[0]=mm.TRANSFORM_IDENTITY}
        source_skeleton:=playing_skeleton(source);source_skeleton.rest=binding.source_rest[:]
        if !lib.skeleton_world(source_skeleton,binding.source_pose[:],binding.source_world[:]) {rig_problem(problems,state.entity,.Chain_Retarget,&config,.Solve);continue}
        actor:=playing_pose(state,.Local)[0];if binding.target_wrapper {playing_pose(state,.Local)[0]=mm.TRANSFORM_IDENTITY}
        solved:=lib.chain_retarget_pose(playing_skeleton(state),binding.mappings[:binding.count],binding.source_world[:],playing_pose(state,.Local),playing_pose(state,.World),weight)
        if binding.target_wrapper {playing_pose(state,.Local)[0]=actor}
        if !solved {rig_problem(problems,state.entity,.Chain_Retarget,&config,.Solve)}
        binding.diagnostic.valid=solved
    }
    return true
}

modifier_operation_name :: proc(value:^$T) -> string {
    if value==nil {return ""}
    if value.name[0]!=0 {return base.text_get(value.name[:])}
    when T==IK_Constraint {return base.text_get(value.end.path[:])}
    else when T==Look_Constraint || T==Rotation_Constraint {return base.text_get(value.bone.path[:])}
    else when T==Foot_Grounding {name:=base.text_get(value.body.path[:]);return name if name!="" else "grounding"}
    else {return base.text_get(value.name[:])}
}

multi_ik_effector_named :: proc(config:^Multi_IK_Constraint,name:string) -> (u8,bool) {
    if config==nil || name=="" || len(config.effectors)>RIG_EFFECTORS {return 0,false}
    for &effector,i in config.effectors {if base.text_get(effector.name[:])==name {return u8(i),true}}
    return 0,false
}
