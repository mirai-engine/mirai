package anim

import "base:runtime"
import "core:fmt"
import "core:testing"
import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(test)
rigs_without_operations_evaluate_with_null_allocators_and_leave_solver_scratch_empty :: proc(t:^testing.T) {
    problems:core.Problems
    state:=rig_test_state(core.entity_make(1,1),4,1);defer playing_free(&state)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    playback:Playback
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<64 {
        stable &&=rigs_apply(&state,&modifiers,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)
        stable &&=!rigs_retarget(&state,&playback,&modifiers,&problems)
    }
    context=saved
    testing.expect(t,stable && problems.count==0)
    testing.expect(t,len(modifiers.chain_states)==0 && len(modifiers.twist_states)==0 && len(modifiers.spring_states)==0 && len(modifiers.multi_states)==0 && len(modifiers.retarget_chain_states)==0)
    for value,i in state.local {testing.expect_value(t,value,state.rest[i])}
}

@(test)
rig_operations_preserve_local_slots_generations_and_copied_state_with_dense_ranges :: proc(t:^testing.T) {
    problems:core.Problems
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    states:[dynamic]Playing;defer {for &state in states {playing_free(&state)};delete(states)}
    playback:Playback;defer playback_free(&playback)
    source_entity:=core.entity_make(7,1)
    append(&playback.states,rig_test_state(source_entity,3,1));resize(&playback.rows,8);playback.rows[7]=1
    playback.states[0].sampled[2].rotation=mm.quat_axis_angle({0,0,1},.2)
    kinds:=[?]Modifier_Kind{.Chain_IK,.Twist,.Spring,.Multi_IK,.Chain_Retarget}
    for i in 0..<3 {
        entity:=core.entity_make(i+1,1);append(&states,rig_test_state(entity,5,.5))
        // It takes the sampled pose of the source, chain by chain.
        states[len(states)-1].leader,states[len(states)-1].stage=source_entity,.Sampled
        for slot in 0..<2 {
            name:="first" if slot==0 else "second"
            chain:=CHAIN_IK_CONSTRAINT_DEFAULT
            chain.rig,chain.root,chain.end,chain.enabled=entity,bone_ref("joint1"),bone_ref("joint4"),false
            base.text_set(chain.name[:],name)
            twist:=TWIST_CONSTRAINT_DEFAULT
            twist.rig,twist.source,twist.root,twist.end,twist.enabled=entity,bone_ref("joint5"),chain.root,chain.end,false
            base.text_set(twist.name[:],name)
            spring:=SPRING_CONSTRAINT_DEFAULT
            spring.rig,spring.root,spring.end,spring.enabled=entity,chain.root,chain.end,false
            base.text_set(spring.name[:],name)
            multi:=MULTI_IK_CONSTRAINT_DEFAULT
            multi.rig,multi.root,multi.enabled=entity,chain.root,false;multi.joint_count,multi.effector_count=1,1
            multi.joints[0]=MULTI_IK_JOINT_DEFAULT;multi.joints[0].bone=chain.root
            multi.effectors[0]=MULTI_IK_EFFECTOR_DEFAULT;multi.effectors[0].bone=chain.end
            base.text_set(multi.name[:],name)
            retarget:=CHAIN_RETARGET_CONSTRAINT_DEFAULT
            retarget.rig=entity
            retarget.source_root,retarget.source_end,retarget.target_root,retarget.target_end=bone_ref("joint1"),bone_ref("joint3"),bone_ref("joint1"),bone_ref("joint5")
            base.text_set(retarget.name[:],name)
            if !testing.expect(t,modifier_append(&modifiers.chain_ik,entity,chain) && modifier_append(&modifiers.twist,entity,twist) && modifier_append(&modifiers.springs,entity,spring) && modifier_append(&modifiers.multi_ik,entity,multi) && modifier_append(&modifiers.retarget_chains,entity,retarget)) {return}
        }
    }
    for &state in states {
        if !testing.expect(t,rigs_apply(&state,&modifiers,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,1.0/60) && rigs_retarget(&state,&playback,&modifiers,&problems)) {return}
        for kind in kinds {
            slot,named:=modifier_named_slot(&modifiers,state.entity,kind,"second")
            testing.expect(t,named && slot==1)
            for wanted in 0..<2 {
                diagnostic,found:=animation_rig_diagnostic(&modifiers,state.entity,kind,u16(wanted))
                testing.expect(t,found && diagnostic.rig==state.entity && diagnostic.kind==kind && diagnostic.slot==u16(wanted))
            }
            _,found:=animation_rig_diagnostic(&modifiers,state.entity,kind,2);testing.expect(t,!found)
        }
    }
    rig:=states[1].entity
    rigs_apply_goal(&modifiers,{rig=rig,kind=.Chain_IK,slot=1,target=spatial_point({.3,1,0})},.75,true,&problems)
    testing.expect_value(t,modifiers.chain_ik.values[3].target.position,mm.Vec3{.3,1,0})
    testing.expect_value(t,modifiers.chain_ik.values[3].weight,f32(.75))
    for value,i in modifiers.chain_ik.values {if i!=3 {testing.expect(t,!value.enabled && value.target.position=={})}}
    rigs_apply_goal(&modifiers,{rig=rig,kind=.Multi_IK,slot=1,target=spatial_point({.4,1,0})},.5,true,&problems)
    testing.expect_value(t,modifiers.multi_ik.values[3].effectors[0].target.position,mm.Vec3{.4,1,0})
    rigs_apply_goal(&modifiers,{rig=rig,kind=.Spring,slot=1,position={1,0,0}},.5,true,&problems)
    testing.expect(t,rigs_apply(&states[1],&modifiers,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    copied_state:Playing;core.value_copy(&copied_state,&states[1],type_info_of(Playing));defer playing_free(&copied_state)
    testing.expect(t,raw_data(copied.multi_ik.rows)!=raw_data(modifiers.multi_ik.rows))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<16 {
        copy(states[1].local[:],states[1].rest[:]);copy(copied_state.local[:],copied_state.rest[:])
        stable &&=rigs_retarget(&states[1],&playback,&modifiers,&problems) && rigs_retarget(&copied_state,&playback,&copied,&problems)
        stable &&=rigs_apply(&states[1],&modifiers,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,1.0/60) && rigs_apply(&copied_state,&copied,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)
    }
    context=saved;testing.expect(t,stable && problems.count==0)
    for local,i in states[1].local {testing.expect_value(t,local,copied_state.local[i])}
    count,version,layout:=len(modifiers.chain_ik.values),modifiers.chain_ik.version,modifiers.chain_ik.layout
    testing.expect(t,!modifier_append(&modifiers.chain_ik,states[0].entity,modifiers.chain_ik.values[0]))
    testing.expect(t,len(modifiers.chain_ik.values)==count && modifiers.chain_ik.version==version && modifiers.chain_ik.layout==layout)
    core.edit_at(&modifiers.springs,3).enabled=false
    testing.expect(t,modifiers.spring_states[3].springs[0].ready)
    testing.expect(t,rigs_apply(&states[1],&modifiers,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,0))
    testing.expect_value(t,modifiers.spring_states[3].springs,([RIG_CHAIN_BONES]lib.Spring_Joint_State{}))
    replacement:=core.entity_make(1,2);new_state:=rig_test_state(replacement,5,.5);defer playing_free(&new_state)
    chain:=CHAIN_IK_CONSTRAINT_DEFAULT;chain.rig,chain.root,chain.end,chain.enabled=replacement,bone_ref("joint1"),bone_ref("joint4"),false;base.text_set(chain.name[:],"new")
    testing.expect(t,modifier_append(&modifiers.chain_ik,replacement,chain))
    testing.expect(t,rigs_apply(&new_state,&modifiers,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,0))
    _,old_named:=modifier_named_slot(&modifiers,states[0].entity,.Chain_IK,"first");testing.expect(t,!old_named)
    _,old_diagnostic:=animation_rig_diagnostic(&modifiers,states[0].entity,.Chain_IK,0);testing.expect(t,!old_diagnostic)
    slot,new_named:=modifier_named_slot(&modifiers,replacement,.Chain_IK,"new");testing.expect(t,new_named && slot==0)
    diagnostic,new_diagnostic:=animation_rig_diagnostic(&modifiers,replacement,.Chain_IK,0);testing.expect(t,new_diagnostic && diagnostic.rig==replacement)
}

@(test)
multi_ik_full_and_partial_weights_preserve_solver_pose_and_diagnostics :: proc(t:^testing.T) {
    for weight in ([?]f32{1,.35}) {
        rig:=core.entity_make(1,1);state:=rig_test_state(rig,63,.25);defer playing_free(&state)
        state.local[6].rotation=mm.quat_axis_angle({1,0,0},.1)
        copy(state.sampled[:],state.local[:])
        reference:Playing;core.value_copy(&reference,&state,type_info_of(Playing));defer playing_free(&reference)
        modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
        multi:=MULTI_IK_CONSTRAINT_DEFAULT;multi.rig,multi.root,multi.weight=rig,bone_ref("joint1"),weight
        multi.joint_count,multi.effector_count=3,1;multi.settings.iterations=4
        for &joint,i in multi.joints[:3] {joint=MULTI_IK_JOINT_DEFAULT;joint.bone=bone_ref(fmt.tprintf("joint%d",i+1))}
        multi.effectors[0]=MULTI_IK_EFFECTOR_DEFAULT;multi.effectors[0].bone=bone_ref("joint4");multi.effectors[0].target=spatial_point({.3,.5,0})
        testing.expect(t,modifier_append(&modifiers.multi_ik,rig,multi))
        joints:[3]lib.Multi_IK_Joint;effectors:[1]lib.Multi_IK_Effector;residuals:[1]f32
        for joint,i in multi.joints[:3] {joints[i]={bone=i32(i+1),stiffness=joint.stiffness,preferred=joint.preferred,preferred_weight=joint.preferred_weight,limit=joint.limit,use_limit=joint.use_limit}}
        effectors[0]={bone=4,position=multi.effectors[0].target.position,rotation=1,position_weight=1}
        settings:=multi.settings;settings.root=1
        result,valid:=lib.multi_ik(playing_skeleton(&reference),reference.local[:],reference.world[:],joints[:],effectors[:],settings,residuals[:])
        if !testing.expect(t,valid && rigs_apply(&state,&modifiers,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)) {return}
        if weight!=1 {
            for &local,i in reference.local {local=mm.transform_interpolate(reference.sampled[i],local,weight)}
            testing.expect(t,lib.skeleton_world(playing_skeleton(&reference),reference.local[:],reference.world[:]))
            result.residual=linalg.length(reference.world[4].position-effectors[0].position)
            result.angular_error=0
            result.reached=result.residual<=settings.tolerance
        }
        for local,i in state.local {testing.expect_value(t,local,reference.local[i]);testing.expect_value(t,state.world[i],reference.world[i])}
        diagnostic,found:=animation_rig_diagnostic(&modifiers,rig,.Multi_IK,0)
        testing.expect(t,found && diagnostic.valid && diagnostic.residual==result.residual && diagnostic.angular_error==result.angular_error && diagnostic.iterations==result.iterations && diagnostic.reached==result.reached)
    }
}

@(private="file")
Rigs_World :: struct {
    using world:core.Test_World,
    animations:core.Table(Animation),
    attachments:core.Table(Bone_Attachment),
    playback:Playback,
    modifiers:Modifier_Runtime,
    requests:Animation_Requests,
}

@(test)
profile_reload_allocation_failure_preserves_spring_state_controls_and_recovers_after_retry :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"rigs-oom")
    spring:=SPRING_CONSTRAINT_DEFAULT;base.text_set(spring.name[:],"tail");spring.root,spring.end=bone_ref("joint1"),bone_ref("joint3")
    id:=base.Asset_Id{91,92}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    if !test_character_save(t,directory,"rig",&types,id,{pose={springs={spring}}}) {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Rigs_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    entity:=core.create(&w.entities)
    player:=ANIMATION_DEFAULT;player.asset=id;core.add(&w.animations,entity,player);core.test_world_settle(&w)
    append(&w.playback.states,rig_test_state(entity,3,1))
    profiles:Character_Assets;defer character_assets_free(&profiles)
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    if !testing.expect(t,modifier_prepare(&w.modifiers,core.read(&w.animations),core.read(&w.attachments),&profiles,&skeletons,&w.playback,app.assets,app.allocator,nil)) {return}
    if !testing.expect(t,rigs_apply(&w.playback.states[0],&w.modifiers,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)) {return}
    modifier_control(&w.requests,{rig=entity,kind=.Spring,weight=.4,enabled=true,fade=0})
    modifier_take(&w.modifiers,&w.requests,nil,.1)
    geometry,inputs:=w.modifiers.geometry,w.modifiers.inputs
    control,joint:=w.modifiers.controls[0],w.modifiers.spring_states[0].springs[2]
    buffer:=raw_data(w.modifiers.spring_states)
    assets.revision+=1
    record,found:=asset.registry_find(&assets.registry,id);if !testing.expect(t,found) {return};record.time+=1
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();app.allocator=runtime.nil_allocator()
    prepared:=modifier_prepare(&w.modifiers,core.read(&w.animations),core.read(&w.attachments),&profiles,&skeletons,&w.playback,app.assets,app.allocator,nil)
    context=saved;app.allocator=saved.allocator;profiles.allocator=saved.allocator
    testing.expect(t,!prepared)
    testing.expect(t,w.modifiers.geometry==geometry && w.modifiers.inputs==inputs && len(w.modifiers.springs.values)==1 && len(w.modifiers.controls)==1 && len(w.modifiers.spring_states)==1)
    if len(w.modifiers.controls)>0 {testing.expect_value(t,w.modifiers.controls[0],control)}
    if len(w.modifiers.spring_states)>0 {testing.expect(t,raw_data(w.modifiers.spring_states)==buffer);testing.expect_value(t,w.modifiers.spring_states[0].springs[2],joint)}
    if !testing.expect(t,modifier_prepare(&w.modifiers,core.read(&w.animations),core.read(&w.attachments),&profiles,&skeletons,&w.playback,app.assets,app.allocator,nil)) {return}
    testing.expect_value(t,w.modifiers.controls[0],control)
    testing.expect_value(t,w.modifiers.springs.values[0].weight,f32(.4))
    testing.expect(t,rigs_apply(&w.playback.states[0],&w.modifiers,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
}

@(private)
rig_test_state :: proc(entity:core.Entity,count:int,step:f32) -> Playing {
    state:=Playing{entity=entity,bound=1,generation=1}
    for i in 0..<count+1 {
        parent:=i32(i-1)
        target:=base.name_hash(fmt.tprintf("joint%d",i)) if i>0 else 0
        rest:=mm.TRANSFORM_IDENTITY;if i>1 {rest.position.y=step}
        append(&state.parents,parent);append(&state.targets,target);append(&state.aliases,target)
        append(&state.rest,rest);append(&state.local,rest);append(&state.sampled,rest);append(&state.previous,rest);append(&state.world,rest)
        append(&state.bindings,Binding{target=target,rest=rest,parent=parent})
    }
    return state
}

@(test)
rig_profiles_roundtrip_typed_operations_and_reject_invalid_capacities :: proc(t:^testing.T) {
    chain:=CHAIN_IK_CONSTRAINT_DEFAULT;base.text_set(chain.name[:],"arm");chain.root,chain.end=bone_ref("joint1"),bone_ref("joint4")
    twist:=TWIST_CONSTRAINT_DEFAULT;base.text_set(twist.name[:],"roll");twist.source,twist.root,twist.end=bone_ref("joint5"),bone_ref("joint1"),bone_ref("joint4")
    spring:=SPRING_CONSTRAINT_DEFAULT;base.text_set(spring.name[:],"tail");spring.root,spring.end=chain.root,chain.end
    multi:=MULTI_IK_CONSTRAINT_DEFAULT;base.text_set(multi.name[:],"body");multi.root=chain.root;multi.joint_count,multi.effector_count=1,1
    multi.joints[0]=MULTI_IK_JOINT_DEFAULT;multi.joints[0].bone=chain.root
    multi.effectors[0]=MULTI_IK_EFFECTOR_DEFAULT;base.text_set(multi.effectors[0].name[:],"hand");multi.effectors[0].bone=chain.end
    retarget:=CHAIN_RETARGET_CONSTRAINT_DEFAULT;base.text_set(retarget.name[:],"arm_transfer");retarget.source_root,retarget.source_end,retarget.target_root,retarget.target_end=chain.root,chain.end,chain.root,chain.end
    profile:=Pose_Profile{chain_ik={chain},twist={twist},springs={spring},multi_ik={multi},retarget_chains={retarget}}
    testing.expect(t,pose_profile_check(profile))
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    directory:=base.test_folder(t,"rigs")
    if !test_character_save(t,directory,"rig",&types,{42,43},{pose=profile}) {return}
    file:asset.Asset;testing.expect_value(t,asset.asset_load(&file,fmt.tprintf("%s/rig.character",directory)),asset.Error.None);defer asset.asset_close(&file)
    set,error:=character_view(&file,&types);testing.expect_value(t,error,asset.Error.None);view:=set.pose
    testing.expect(t,len(view.chain_ik)==1 && len(view.multi_ik)==1 && len(view.retarget_chains)==1)
    testing.expect_value(t,view.springs[0],spring)
    invalid:=multi;invalid.effector_count=RIG_EFFECTORS+1
    testing.expect(t,!pose_profile_check({multi_ik={invalid}}))
    invalid=multi;invalid.joints[0].preferred=0;testing.expect(t,!pose_profile_check({multi_ik={invalid}}))
    spring.collision_count=RIG_COLLISIONS+1;testing.expect(t,!pose_profile_check({springs={spring}}))
}

@(test)
named_modifier_controls_preserve_full_bone_paths_and_reject_ambiguous_references_without_allocations :: proc(t:^testing.T) {
    rig:=core.entity_make(1,1)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    prefix:="character/skeleton/torso/spine/chest/shoulder/arm/forearm/wrist/attachment/"
    left,right:=LOOK_CONSTRAINT_DEFAULT,LOOK_CONSTRAINT_DEFAULT
    left.bone,right.bone=bone_ref(fmt.tprintf("%sleft",prefix)),bone_ref(fmt.tprintf("%sright",prefix))
    left.rig,right.rig=rig,rig
    testing.expect(t,modifier_append(&modifiers.look,rig,right) && modifier_append(&modifiers.look,rig,left))
    ground:=FOOT_GROUNDING_DEFAULT;testing.expect(t,modifier_append(&modifiers.grounding,rig,ground))
    requests:Animation_Requests;defer delete(requests.controls.items)
    modifier_control_named(&requests,&modifiers,{rig=rig,kind=.Look,weight=.5,enabled=true},modifier_operation_name(&left))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    slot,ok:=modifier_named_slot(&modifiers,rig,.Look,modifier_operation_name(&left))
    ground_slot,ground_ok:=modifier_named_slot(&modifiers,rig,.Grounding,"grounding")
    modifier_control_named(&requests,&modifiers,{rig=rig,kind=.Look,weight=.8,enabled=true},modifier_operation_name(&right))
    queued:=len(requests.controls.items)==2
    context=saved
    testing.expect(t,ok && slot==1 && ground_ok && ground_slot==0 && queued)
    testing.expect(t,len(requests.controls.items)==2 && requests.controls.items[0].slot==1 && requests.controls.items[1].slot==0)
    testing.expect(t,modifier_append(&modifiers.look,rig,left))
    modifier_control_named(&requests,&modifiers,{rig=rig,kind=.Look,weight=1,enabled=true},modifier_operation_name(&left))
    testing.expect_value(t,len(requests.controls.items),2)
    testing.expect_value(t,requests.controls.refused,1)
}

@(test)
chain_and_spring_modifiers_reuse_bind_buffers_copy_snapshots_and_retire_controls :: proc(t:^testing.T) {
    problems:core.Problems
    rig:=core.entity_make(1,1);state:=rig_test_state(rig,4,1);defer playing_free(&state)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    chain:=CHAIN_IK_CONSTRAINT_DEFAULT;base.text_set(chain.name[:],"arm");chain.rig,chain.root,chain.end=rig,bone_ref("joint1"),bone_ref("joint4")
    chain.target=spatial_point({1.5,1,0});chain.pole,chain.use_pole={0,0,2},true
    testing.expect(t,modifier_append(&modifiers.chain_ik,rig,chain))
    testing.expect(t,rigs_apply(&state,&modifiers,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
    diagnostic,found:=animation_rig_diagnostic(&modifiers,rig,.Chain_IK,0)
    testing.expect(t,found && diagnostic.valid && diagnostic.reached && diagnostic.residual<.001)
    core.edit_at(&modifiers.chain_ik,0).enabled=false
    spring:=SPRING_CONSTRAINT_DEFAULT;base.text_set(spring.name[:],"tail");spring.rig,spring.root,spring.end=rig,chain.root,chain.end;spring.settings.gravity={};spring.settings.force={2,0,0}
    testing.expect(t,modifier_append(&modifiers.springs,rig,spring))
    copy(state.local[:],state.rest[:]);testing.expect(t,rigs_apply(&state,&modifiers,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    copied_state:Playing;core.value_copy(&copied_state,&state,type_info_of(Playing));defer playing_free(&copied_state)
    empty:Modifier_Runtime;testing.expect(t,modifier_controls_prepare(&modifiers,&empty))
    requests:Animation_Requests;defer delete(requests.goals.items);defer delete(requests.controls.items)
    modifier_control_named(&requests,&modifiers,{rig=rig,kind=.Chain_IK,weight=.2,enabled=true},"arm")
    modifier_controls_take(&modifiers,&requests,&problems,0)
    testing.expect_value(t,modifiers.chain_ik.values[0].weight,f32(.2))
    core.edit_at(&modifiers.chain_ik,0).enabled=false
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<120 {
        copy(state.local[:],state.rest[:]);copy(copied_state.local[:],copied_state.rest[:])
        stable &&=rigs_apply(&state,&modifiers,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)
        stable &&=rigs_apply(&copied_state,&copied,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)
    }
    context=saved
    testing.expect(t,stable && problems.count==0)
    for value,i in state.local {testing.expect_value(t,value,copied_state.local[i])}
    testing.expect_value(t,modifiers.spring_states[0].springs,copied.spring_states[0].springs)
    state.bound+=1;state.targets[4]=base.name_hash("replaced")
    testing.expect(t,rigs_apply(&state,&modifiers,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,0))
    state.bound+=1;state.aliases[4]=state.targets[4]
    testing.expect(t,!rigs_apply(&state,&modifiers,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,0))
    diagnostic,found=animation_rig_diagnostic(&modifiers,rig,.Spring,0);testing.expect(t,found && !diagnostic.valid)
}

@(test)
semantic_retarget_bindings_ignore_actor_placement_and_replay_without_allocations :: proc(t:^testing.T) {
    problems:core.Problems
    source_id,target_id:=core.entity_make(1,1),core.entity_make(2,1)
    playback:Playback;defer playback_free(&playback)
    append(&playback.states,rig_test_state(source_id,3,1));append(&playback.states,rig_test_state(target_id,5,.5));resize(&playback.rows,3);playback.rows[1],playback.rows[2]=1,2
    source,target:=&playback.states[0],&playback.states[1]
    source.local[0].position={100,0,0};source.sampled[0]=source.local[0];source.sampled[2].rotation=mm.quat_axis_angle({0,0,1},.8)
    target.local[0].position={-20,3,0};actor:=target.local[0]
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    target.leader,target.stage=source_id,.Sampled
    chain:=CHAIN_RETARGET_CONSTRAINT_DEFAULT;base.text_set(chain.name[:],"arm");chain.rig=target_id
    chain.source_root,chain.source_end,chain.target_root,chain.target_end=bone_ref("joint1"),bone_ref("joint3"),bone_ref("joint1"),bone_ref("joint5")
    testing.expect(t,modifier_append(&modifiers.retarget_chains,target_id,chain))
    testing.expect(t,rigs_retarget(target,&playback,&modifiers,&problems))
    testing.expect_value(t,target.local[0],actor)
    for value,i in target.local {if i>0 {testing.expect_value(t,value.position,target.rest[i].position)}}
    testing.expect(t,linalg.dot(target.local[2].rotation,mm.Quat(1))<.9999)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<120 {copy(target.local[:],target.rest[:]);target.local[0]=actor;stable &&=rigs_retarget(target,&playback,&modifiers,&problems)}
    context=saved
    testing.expect(t,stable && problems.count==0 && target.local[0]==actor)
}

@(test)
rig_goal_persistence_keeps_independent_effectors_and_accepts_chain_retarget_goals :: proc(t:^testing.T) {
    problems:core.Problems
    w:Rigs_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    body,transfer:=core.create(&w.entities),core.create(&w.entities)
    multi:=MULTI_IK_CONSTRAINT_DEFAULT;multi.rig=body;multi.effector_count=2
    multi.effectors[0],multi.effectors[1]=MULTI_IK_EFFECTOR_DEFAULT,MULTI_IK_EFFECTOR_DEFAULT
    testing.expect(t,modifier_append(&w.modifiers.multi_ik,body,multi))
    chain:=CHAIN_RETARGET_CONSTRAINT_DEFAULT;chain.rig=transfer
    testing.expect(t,modifier_append(&w.modifiers.retarget_chains,transfer,chain))
    empty:Modifier_Runtime;testing.expect(t,modifier_controls_prepare(&w.modifiers,&empty))
    modifier_goal(&w.requests,{rig=body,kind=.Multi_IK,effector=0,target=spatial_point({1,2,3}),weight=1,enabled=true})
    modifier_goal(&w.requests,{rig=body,kind=.Multi_IK,effector=1,target=spatial_point({4,5,6}),weight=1,enabled=true})
    modifier_goal(&w.requests,{rig=transfer,kind=.Chain_Retarget,weight=.4,enabled=true})
    modifier_take(&w.modifiers,&w.requests,&problems,0)
    testing.expect_value(t,len(w.modifiers.goals),3)
    testing.expect_value(t,w.modifiers.multi_ik.values[0].effectors[0].target.position,mm.Vec3{1,2,3})
    testing.expect_value(t,w.modifiers.multi_ik.values[0].effectors[1].target.position,mm.Vec3{4,5,6})
    testing.expect_value(t,w.modifiers.multi_ik.values[0].weight,f32(1))
    testing.expect_value(t,w.modifiers.retarget_chains.values[0].weight,f32(.4))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<64 {
        modifier_goal(&w.requests,{rig=body,kind=.Multi_IK,effector=0,target=spatial_point({7,8,9}),weight=1,enabled=true})
        modifier_take(&w.modifiers,&w.requests,&problems,0)
        stable &&=len(w.modifiers.goals)==3 && w.modifiers.multi_ik.values[0].effectors[1].target.position==mm.Vec3{4,5,6} && w.modifiers.retarget_chains.values[0].enabled
    }
    context=saved;testing.expect(t,stable && problems.count==0)
}

@(test)
multi_ik_modifiers_accept_named_goals_keep_effectors_independent_and_clone_solver_scratch :: proc(t:^testing.T) {
    rig:=core.entity_make(1,1);state:=rig_test_state(rig,4,1);defer playing_free(&state)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    multi:=MULTI_IK_CONSTRAINT_DEFAULT;base.text_set(multi.name[:],"body");multi.rig,multi.root=rig,bone_ref("joint1");multi.joint_count,multi.effector_count=3,1;multi.settings.iterations=128
    for &joint,i in multi.joints[:3] {joint=MULTI_IK_JOINT_DEFAULT;joint.bone=bone_ref(fmt.tprintf("joint%d",i+1))}
    multi.effectors[0]=MULTI_IK_EFFECTOR_DEFAULT;base.text_set(multi.effectors[0].name[:],"hand");multi.effectors[0].bone=bone_ref("joint4");multi.effectors[0].target=spatial_point({1.2,1.7,0})
    testing.expect(t,modifier_append(&modifiers.multi_ik,rig,multi))
    testing.expect(t,rigs_apply(&state,&modifiers,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
    diagnostic,found:=animation_rig_diagnostic(&modifiers,rig,.Multi_IK,0);testing.expect(t,found && diagnostic.valid && diagnostic.reached)
    empty:Modifier_Runtime;testing.expect(t,modifier_controls_prepare(&modifiers,&empty))
    requests:Animation_Requests;defer delete(requests.goals.items);defer delete(requests.controls.items)
    modifier_goal_named(&requests,&modifiers,{rig=rig,kind=.Multi_IK,target=spatial_point({.5,1.8,0}),weight=1,enabled=true},"body")
    for goal in core.take(&requests.goals) {modifier_apply_goal(&modifiers,goal,nil)}
    testing.expect_value(t,modifiers.multi_ik.values[0].effectors[0].target.position,mm.Vec3{.5,1.8,0})
    copy(state.local[:],state.rest[:]);testing.expect(t,rigs_apply(&state,&modifiers,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    copied_state:Playing;core.value_copy(&copied_state,&state,type_info_of(Playing));defer playing_free(&copied_state)
    testing.expect(t,raw_data(copied.multi_states[0].backup)!=raw_data(modifiers.multi_states[0].backup))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<60 {
        copy(state.local[:],state.rest[:]);copy(copied_state.local[:],copied_state.rest[:])
        stable &&=rigs_apply(&state,&modifiers,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)
        stable &&=rigs_apply(&copied_state,&copied,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)
    }
    context=saved
    testing.expect(t,stable)
    for pose,i in state.local {testing.expect_value(t,pose,copied_state.local[i])}
    testing.expect_value(t,modifiers.multi_states[0].diagnostic,copied.multi_states[0].diagnostic)
}

@(test)
look_and_ik_publish_their_residual_and_whether_they_reach_in_the_constraints_of_the_rig :: proc(t:^testing.T) {
    problems:core.Problems
    rig:=core.entity_make(1,1)
    state:=rig_test_state(rig,3,.5);defer playing_free(&state)
    iks:core.Table(IK_Constraint);looks:core.Table(Look_Constraint)
    defer {core.table_destroy(&iks);core.table_destroy(&looks)}
    near:=IK_CONSTRAINT_DEFAULT;near.rig=rig;near.root,near.joint,near.end=bone_ref("joint1"),bone_ref("joint2"),bone_ref("joint3");near.target=spatial_point({.4,.6,0})
    far:=near;far.target=spatial_point({0,3,0})
    look:=LOOK_CONSTRAINT_DEFAULT;look.rig=rig;look.bone=bone_ref("joint3");look.target=spatial_point({0,1,-5});look.max_angle=mm.PI
    testing.expect(t,modifier_append(&iks,rig,near) && modifier_append(&iks,rig,far) && modifier_append(&looks,rig,look))
    cache:Animation_Constraints;defer constraints_free(&cache)
    playback:Playback;defer playback_free(&playback)
    transforms:core.Table(core.Transform);defer core.table_destroy(&transforms)
    inputs:=Constraint_Inputs{ik=core.read(&iks),look=core.read(&looks),problems=&problems}
    constraints_apply(&state,&playback,inputs,&cache,&transforms,{},0)
    testing.expect_value(t,problems.count,0)
    reached,found:=animation_rig_diagnostic(nil,rig,.IK,0,&cache)
    testing.expect(t,found && reached.rig==rig && reached.kind==.IK && reached.valid && reached.reached && reached.residual<.001)
    missed,missed_found:=animation_rig_diagnostic(nil,rig,.IK,1,&cache)
    testing.expect(t,missed_found && missed.valid && !missed.reached && abs(missed.residual-2)<1e-3,"an unreachable target is a residual, not an invalid solve")
    aimed,aimed_found:=animation_rig_diagnostic(nil,rig,.Look,0,&cache)
    testing.expect(t,aimed_found && aimed.valid && aimed.reached && aimed.residual<1e-3 && aimed.angular_error<1e-3)
    _,beyond:=animation_rig_diagnostic(nil,rig,.Look,1,&cache);_,elsewhere:=animation_rig_diagnostic(nil,rig,.IK,0)
    testing.expect(t,!beyond && !elsewhere)
    core.edit_at(&looks,0).target=spatial_point({5,1,0});core.edit_at(&looks,0).max_angle=.2
    copy(state.local[:],state.rest[:]);constraints_apply(&state,&playback,inputs,&cache,&transforms,{},0)
    aimed,_=animation_rig_diagnostic(nil,rig,.Look,0,&cache)
    testing.expect(t,problems.count==0 && aimed.valid && !aimed.reached && aimed.angular_error>1 && aimed.residual>1,"a look held by max_angle says how far it misses")
    core.edit_at(&looks,0).enabled=false
    copy(state.local[:],state.rest[:]);constraints_apply(&state,&playback,inputs,&cache,&transforms,{},0)
    aimed,_=animation_rig_diagnostic(nil,rig,.Look,0,&cache)
    testing.expect(t,!aimed.valid)
}
