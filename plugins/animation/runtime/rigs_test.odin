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
    characters:Character_Assets;defer character_assets_free(&characters)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<64 {
        stable &&=test_rigs_apply(&state,&modifiers,&characters,{},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60)
    }
    context=saved
    testing.expect(t,stable && problems.count==0)
    testing.expect(t,len(modifiers.rigs)==0)
    for value,i in playing_pose(&state,.Local) {testing.expect_value(t,value,state.rest[i])}
}

@(test)
rig_operations_preserve_named_operations_generations_and_copied_per_rig_state :: proc(t:^testing.T) {
    problems:core.Problems
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    characters:Character_Assets;defer character_assets_free(&characters)
    states:[dynamic]Playing;defer {for &state in states {playing_free(&state)};delete(states)}
    playback:Playback;defer playback_free(&playback)
    source_entity:=core.entity_make(7,1)
    append(&playback.states,rig_test_state(source_entity,3,1));resize(&playback.rows,8);playback.rows[7]=1
    playing_pose(&playback.states[0],.Sampled)[2].rotation=mm.quat_axis_angle({0,0,1},.2)
    kinds:=[?]Modifier_Kind{.Twist,.Spring,.Multi_IK}
    for i in 0..<3 {
        entity:=core.entity_make(i+1,1);append(&states,rig_test_state(entity,5,.5))
        twists:=make([]Twist_Constraint,2,context.temp_allocator)
        springs:=make([]Spring_Constraint,2,context.temp_allocator)
        multis:=make([]Multi_IK_Constraint,2,context.temp_allocator)
        for slot in 0..<2 {
            name:="first" if slot==0 else "second"
            chain:=struct {root,end:Bone_Ref}{bone_ref("joint1"),bone_ref("joint4")}
            twist:=TWIST_CONSTRAINT_DEFAULT
            twist.source,twist.root,twist.end,twist.enabled=bone_ref("joint5"),chain.root,chain.end,false
            base.text_set(twist.name[:],name)
            spring:=SPRING_CONSTRAINT_DEFAULT
            spring.root,spring.end,spring.enabled=chain.root,chain.end,false
            base.text_set(spring.name[:],name)
            multi:=MULTI_IK_CONSTRAINT_DEFAULT
            multi.root,multi.enabled=chain.root,false;multi.joints=make([]Multi_IK_Joint,1,context.temp_allocator);multi.effectors=make([]Multi_IK_Effector,1,context.temp_allocator)
            multi.joints[0]=MULTI_IK_JOINT_DEFAULT;multi.joints[0].bone=chain.root
            multi.effectors[0]=MULTI_IK_EFFECTOR_DEFAULT;multi.effectors[0].bone=chain.end
            base.text_set(multi.name[:],name)
            base.text_set(multi.effectors[0].name[:],"hand")
            twists[slot]=twist;springs[slot]=spring
            multis[slot]=multi
        }
        if !testing.expect(t,test_modifier_profile(&modifiers,&characters,entity,
            {twist=twists,springs=springs,multi_ik=multis})!=nil) {return}
    }
    for &state in states {
        if !testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,{problems=&problems},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60)) {return}
        for kind in kinds {
            for name in ([2]string{"first","second"}) {
                diagnostic,found:=animation_rig_diagnostic(core.ref(&modifiers),state.entity,kind,base.name_hash(name))
                testing.expect(t,found && diagnostic.rig==state.entity && diagnostic.kind==kind)
            }
            _,found:=animation_rig_diagnostic(core.ref(&modifiers),state.entity,kind,base.name_hash("missing"))
            testing.expect(t,!found)
        }
    }
    rig:=states[1].entity
    requests:Animation_Requests;defer delete(requests.modifiers.items)
    modifier(&requests,{rig=rig,kind=.Multi_IK,target=spatial_point({.3,1,0}),weight=.75,enabled=true,goal=true},"first")
    modifier(&requests,{rig=rig,kind=.Multi_IK,target=spatial_point({.4,1,0}),weight=.5,enabled=true,goal=true},"second","hand")
    modifier(&requests,{rig=rig,kind=.Spring,position={1,0,0},weight=.5,enabled=true,goal=true},"second")
    modifier_take(&modifiers,&characters,&requests,&problems,0)
    prepared:=modifier_rig(core.ref(&modifiers),rig)
    // A goal that names no effector is for the one effector of its operation.
    testing.expect_value(t,modifier_override(prepared,.Multi_IK,0).target.position,mm.Vec3{.3,1,0})
    testing.expect_value(t,test_modifier_weight(&modifiers,rig,.Multi_IK,"first"),f32(.75))
    testing.expect_value(t,modifier_override(prepared,.Multi_IK,1).target.position,mm.Vec3{.4,1,0})
    testing.expect(t,test_rigs_apply(&states[1],&modifiers,&characters,{problems=&problems},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60))
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    copied_state:Playing;core.value_copy(&copied_state,&states[1],type_info_of(Playing));defer playing_free(&copied_state)
    testing.expect(t,raw_data(modifier_rig(core.ref(&copied),rig).multi_states)!=raw_data(prepared.multi_states))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<16 {
        copy(playing_pose(&states[1],.Local),states[1].rest[:]);copy(playing_pose(&copied_state,.Local),copied_state.rest[:])
        stable &&=test_rigs_apply(&states[1],&modifiers,&characters,{problems=&problems},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60) && test_rigs_apply(&copied_state,&copied,&characters,{problems=&problems},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60)
    }
    context=saved;testing.expect(t,stable && problems.count==0)
    for local,i in playing_pose(&states[1],.Local) {testing.expect_value(t,local,playing_pose(&copied_state,.Local)[i])}
    modifier(&requests,{rig=rig,kind=.Spring,enabled=false},"second")
    modifier_take(&modifiers,&characters,&requests,&problems,0)
    testing.expect(t,prepared.spring_states[1].springs[0].ready)
    testing.expect(t,test_rigs_apply(&states[1],&modifiers,&characters,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,0))
    testing.expect_value(t,prepared.spring_states[1].springs,([RIG_CHAIN_BONES]lib.Spring_Joint_State{}))
    replacement:=core.entity_make(1,2);new_state:=rig_test_state(replacement,5,.5);defer playing_free(&new_state)
    modifier_rig_remove(&modifiers,int(modifiers.rows[1])-1)
    twist:=TWIST_CONSTRAINT_DEFAULT;twist.source,twist.root,twist.end,twist.enabled=bone_ref("joint5"),bone_ref("joint1"),bone_ref("joint4"),false
    base.text_set(twist.name[:],"new")
    test_modifier_profile(&modifiers,&characters,replacement,{twist={twist}})
    testing.expect(t,test_rigs_apply(&new_state,&modifiers,&characters,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,0))
    _,old_diagnostic:=animation_rig_diagnostic(core.ref(&modifiers),states[0].entity,.Twist,base.name_hash("first"))
    testing.expect(t,!old_diagnostic)
    diagnostic,found:=animation_rig_diagnostic(core.ref(&modifiers),replacement,.Twist,base.name_hash("new"))
    testing.expect(t,found && diagnostic.rig==replacement)
}

@(test)
multi_ik_full_and_partial_weights_preserve_solver_pose_and_diagnostics :: proc(t:^testing.T) {
    for weight in ([?]f32{1,.35}) {
        rig:=core.entity_make(1,1);state:=rig_test_state(rig,63,.25);defer playing_free(&state)
        playing_pose(&state,.Local)[6].rotation=mm.quat_axis_angle({1,0,0},.1)
        copy(playing_pose(&state,.Sampled),playing_pose(&state,.Local))
        reference:Playing;core.value_copy(&reference,&state,type_info_of(Playing));defer playing_free(&reference)
        modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    characters:Character_Assets;defer character_assets_free(&characters)
        multi:=MULTI_IK_CONSTRAINT_DEFAULT;multi.root,multi.weight=bone_ref("joint1"),weight
        multi.joints=make([]Multi_IK_Joint,3,context.temp_allocator);multi.effectors=make([]Multi_IK_Effector,1,context.temp_allocator);multi.settings.iterations=4
        for &joint,i in multi.joints[:3] {joint=MULTI_IK_JOINT_DEFAULT;joint.bone=bone_ref(fmt.tprintf("joint%d",i+1))}
        multi.effectors[0]=MULTI_IK_EFFECTOR_DEFAULT;multi.effectors[0].bone=bone_ref("joint4");multi.effectors[0].target=spatial_definition_point({.3,.5,0})
        base.text_set(multi.name[:],"body")
        test_modifier_profile(&modifiers,&characters,rig,{multi_ik={multi}})
        joints:[3]lib.Multi_IK_Joint;effectors:[1]lib.Multi_IK_Effector;residuals:[1]f32
        for joint,i in multi.joints[:3] {joints[i]={bone=i32(i+1),stiffness=joint.stiffness,preferred=joint.preferred,preferred_weight=joint.preferred_weight,frame=joint.frame,limits=joint.limits}}
        effectors[0]={bone=4,position=multi.effectors[0].target.position,rotation=1,position_weight=1}
        settings:=multi.settings;settings.root=1
        links:[64]lib.Pose_Link;hierarchy,_:=lib.pose_hierarchy_prepare(reference.parents[:],links[:])
        result,valid:=lib.multi_ik(playing_skeleton(&reference),hierarchy,playing_pose(&reference,.Local),playing_pose(&reference,.World),joints[:],effectors[:],settings,residuals[:])
        if !testing.expect(t,valid && test_rigs_apply(&state,&modifiers,&characters,{},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60)) {return}
        if weight!=1 {
            for &local,i in playing_pose(&reference,.Local) {local=mm.transform_interpolate(playing_pose(&reference,.Sampled)[i],local,weight)}
            testing.expect(t,lib.skeleton_world(playing_skeleton(&reference),playing_pose(&reference,.Local),playing_pose(&reference,.World)))
            result.residual=linalg.length(playing_pose(&reference,.World)[4].position-effectors[0].position)
            result.angular_error=0
            result.reached=result.residual<=settings.tolerance
        }
        for local,i in playing_pose(&state,.Local) {testing.expect_value(t,local,playing_pose(&reference,.Local)[i]);testing.expect_value(t,playing_pose(&state,.World)[i],playing_pose(&reference,.World)[i])}
        diagnostic,found:=animation_rig_diagnostic(core.ref(&modifiers),rig,.Multi_IK,base.name_hash("body"))
        testing.expect(t,found && diagnostic.valid && diagnostic.residual==result.residual && diagnostic.angular_error==result.angular_error && diagnostic.iterations==result.iterations && diagnostic.reached==result.reached)
    }
}

@(private)
@(test_world)
Rigs_World :: struct {
    using world:Test_World,
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
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    entity:=core.create(&w.entities)
    player:=ANIMATION_DEFAULT;player.asset=id;core.add(&w.animations,entity,player);test_world_settle(&w)
    append(&w.playback.states,rig_test_state(entity,3,1))
    profiles:Character_Assets;defer character_assets_free(&profiles)
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    if !testing.expect(t,modifier_prepare(&w.modifiers,core.read(&w.animations),core.read(&w.attachments),&profiles,&skeletons,&w.playback,app.assets,app.allocator,nil)) {return}
    if !testing.expect(t,test_rigs_apply(&w.playback.states[0],&w.modifiers,&profiles,{},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60)) {return}
    modifier(&w.requests,{rig=entity,kind=.Spring,weight=.4,enabled=true},"tail")
    modifier_take(&w.modifiers,&profiles,&w.requests,nil,.1)
    current:=modifier_rig(core.ref(&w.modifiers),entity)
    revision,inputs:=current.revision,w.modifiers.inputs
    control,joint:=modifier_states(current,.Spring)[0],current.spring_states[0].springs[2]
    buffer:=raw_data(current.spring_states)
    assets.revision+=1
    record,found:=asset.registry_find(&assets.registry,id);if !testing.expect(t,found) {return};record.time+=1
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();app.allocator=runtime.nil_allocator()
    prepared:=modifier_prepare(&w.modifiers,core.read(&w.animations),&w.attachments,&profiles,&skeletons,&w.playback,app.assets,app.allocator,nil)
    context=saved;app.allocator=saved.allocator;profiles.allocator=saved.allocator
    testing.expect(t,!prepared)
    testing.expect(t,current.revision==revision && w.modifiers.inputs==inputs &&
        raw_data(current.spring_states)==buffer)
    testing.expect_value(t,modifier_states(current,.Spring)[0],control)
    testing.expect_value(t,current.spring_states[0].springs[2],joint)
    if !testing.expect(t,modifier_prepare(&w.modifiers,&w.animations,&w.attachments,&profiles,&skeletons,&w.playback,app.assets,app.allocator,nil)) {return}
    testing.expect_value(t,test_modifier_weight(&w.modifiers,entity,.Spring,"tail"),f32(.4))
    testing.expect(t,test_rigs_apply(&w.playback.states[0],&w.modifiers,&profiles,{},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60))
}

@(private)
rig_test_state :: proc(entity:core.Entity,count:int,step:f32) -> Playing {
    state:=Playing{entity=entity,bound=1,generation=1}
    for i in 0..<count+1 {
        parent:=i32(i-1)
        target:=base.name_hash(fmt.tprintf("joint%d",i)) if i>0 else 0
        rest:=mm.TRANSFORM_IDENTITY;if i>1 {rest.position.y=step}
        append(&state.parents,parent);append(&state.targets,target);append(&state.aliases,target)
        index:=state.pose_count
        playing_pose_resize(&state,index+1)
        append(&state.rest,rest);playing_pose(&state,.Local)[index]=rest;playing_pose(&state,.Sampled)[index]=rest;playing_pose(&state,.Previous)[index]=rest;playing_pose(&state,.World)[index]=rest;
        append(&state.bindings,Binding{target=target,parent=parent})
    }
    return state
}

@(test)
rig_profiles_roundtrip_typed_operations_and_reject_invalid_capacities :: proc(t:^testing.T) {
    chain:=struct {root,end:Bone_Ref}{bone_ref("joint1"),bone_ref("joint4")}
    twist:=TWIST_CONSTRAINT_DEFAULT;base.text_set(twist.name[:],"roll");twist.source,twist.root,twist.end=bone_ref("joint5"),bone_ref("joint1"),bone_ref("joint4")
    spring:=SPRING_CONSTRAINT_DEFAULT;base.text_set(spring.name[:],"tail");spring.root,spring.end=chain.root,chain.end
    multi:=MULTI_IK_CONSTRAINT_DEFAULT;base.text_set(multi.name[:],"body");multi.root=chain.root;multi.joints=make([]Multi_IK_Joint,1,context.temp_allocator);multi.effectors=make([]Multi_IK_Effector,1,context.temp_allocator)
    multi.joints[0]=MULTI_IK_JOINT_DEFAULT;multi.joints[0].bone=chain.root
    multi.effectors[0]=MULTI_IK_EFFECTOR_DEFAULT;base.text_set(multi.effectors[0].name[:],"hand");multi.effectors[0].bone=chain.end
    multi.effectors[0].pole,multi.effectors[0].use_pole,multi.effectors[0].reach={0,0,2},true,{soft_distance=.2,max_stretch=.3}
    profile:=Pose_Profile{twist={twist},springs={spring},multi_ik={multi}}
    testing.expect(t,pose_profile_check(profile))
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    directory:=base.test_folder(t,"rigs")
    if !test_character_save(t,directory,"rig",&types,{42,43},{pose=profile}) {return}
    file:asset.Asset;testing.expect_value(t,asset.asset_load(&file,fmt.tprintf("%s/rig.character",directory)),asset.Error.None);defer asset.asset_close(&file)
    set,error:=character_view(&file,&types);testing.expect_value(t,error,asset.Error.None);view:=set.pose
    testing.expect(t,len(view.multi_ik)==1 && view.multi_ik[0].effectors[0]==multi.effectors[0])
    testing.expect_value(t,view.springs[0],spring)
    invalid:=multi;invalid.effectors=make([]Multi_IK_Effector,RIG_EFFECTORS+1,context.temp_allocator)
    testing.expect(t,!pose_profile_check({multi_ik={invalid}}))
    invalid=multi;invalid.joints[0].preferred=0;testing.expect(t,!pose_profile_check({multi_ik={invalid}}))
    nan:=f32(0);nan/=nan
    for hostile,i in ([4]Multi_IK_Effector{{pole={nan,0,0}},{reach={soft_distance=-1}},{reach={max_stretch=-.1}},{reach={max_stretch=nan}}}) {
        effector:=multi.effectors[0];effector.pole,effector.reach=hostile.pole,hostile.reach
        effectors:=[1]Multi_IK_Effector{effector};invalid=multi;invalid.effectors=effectors[:]
        testing.expectf(t,!pose_profile_check({multi_ik={invalid}}),"hostile effector %d is refused",i)
    }
    invalid=multi;invalid.joints=nil;testing.expect(t,pose_profile_check({multi_ik={invalid}}),"a Multi IK without joints chains its effectors")
    spring.collision_count=RIG_COLLISIONS+1;testing.expect(t,!pose_profile_check({springs={spring}}))
}

@(test)
named_modifier_controls_preserve_full_bone_paths_and_reject_ambiguous_references_without_allocations :: proc(t:^testing.T) {
    rig:=core.entity_make(1,1)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    characters:Character_Assets;defer character_assets_free(&characters)
    prefix:="character/skeleton/torso/spine/chest/shoulder/arm/forearm/wrist/attachment/"
    left,right:=LOOK_CONSTRAINT_DEFAULT,LOOK_CONSTRAINT_DEFAULT
    left.bone,right.bone=bone_ref(fmt.tprintf("%sleft",prefix)),bone_ref(fmt.tprintf("%sright",prefix))

    prepared:=test_modifier_profile(&modifiers,&characters,rig,{look={right,left}})
    requests:Animation_Requests;defer delete(requests.modifiers.items)
    modifier(&requests,{rig=rig,kind=.Look,weight=.5,enabled=true},modifier_operation_name(&left))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    modifier(&requests,{rig=rig,kind=.Look,weight=.8,enabled=true},modifier_operation_name(&right))
    modifier_take(&modifiers,&characters,&requests,nil,0)
    context=saved
    testing.expect_value(t,modifier_states(prepared,.Look)[1].target,f32(.5))
    testing.expect_value(t,modifier_states(prepared,.Look)[0].target,f32(.8))
    test_modifier_profile(&modifiers,&characters,rig,{look={right,left,left}})
    modifier(&requests,{rig=rig,kind=.Look,weight=1,enabled=true},modifier_operation_name(&left))
    modifier_take(&modifiers,&characters,&requests,nil,0)
    testing.expect_value(t,modifier_request_error(&modifiers,rig),Modifier_Request_Error.Missing_Operation)
}

@(test)
multi_ik_and_spring_modifiers_reuse_bind_buffers_copy_snapshots_and_retire_controls :: proc(t:^testing.T) {
    problems:core.Problems
    rig:=core.entity_make(1,1);state:=rig_test_state(rig,4,1);defer playing_free(&state)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    characters:Character_Assets;defer character_assets_free(&characters)
    // Without joints every bone from the effector up to the root is one.
    effectors:=[1]Multi_IK_Effector{MULTI_IK_EFFECTOR_DEFAULT}
    effectors[0].bone,effectors[0].target=bone_ref("joint4"),spatial_definition_point({1.5,1,0});effectors[0].pole,effectors[0].use_pole={0,0,2},true
    chain:=MULTI_IK_CONSTRAINT_DEFAULT;base.text_set(chain.name[:],"arm");chain.root,chain.effectors=bone_ref("joint1"),effectors[:]
    prepared:=test_modifier_profile(&modifiers,&characters,rig,{multi_ik={chain}})
    testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,{problems=&problems},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60))
    diagnostic,found:=animation_rig_diagnostic(core.ref(&modifiers),rig,.Multi_IK,base.name_hash("arm"))
    testing.expect(t,found && diagnostic.valid && diagnostic.reached && diagnostic.residual<.001 && prepared.multi_states[0].joint_count==4)
    testing.expect(t,playing_pose(&state,.World)[2].position.z+playing_pose(&state,.World)[3].position.z>0,"the chain bends toward its pole")
    modifier_states(prepared,.Multi_IK)[0].base_enabled=false
    spring:=SPRING_CONSTRAINT_DEFAULT;base.text_set(spring.name[:],"tail");spring.root,spring.end=bone_ref("joint1"),bone_ref("joint4");spring.settings.gravity={};spring.settings.force={2,0,0}
    chain.enabled=false
    prepared=test_modifier_profile(&modifiers,&characters,rig,{multi_ik={chain},springs={spring}})
    copy(playing_pose(&state,.Local),state.rest[:]);testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,{problems=&problems},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60))
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    copied_state:Playing;core.value_copy(&copied_state,&state,type_info_of(Playing));defer playing_free(&copied_state)
    requests:Animation_Requests;defer delete(requests.modifiers.items)
    modifier(&requests,{rig=rig,kind=.Multi_IK,weight=.2,enabled=true},"arm")
    modifier_take(&modifiers,&characters,&requests,&problems,0)
    testing.expect_value(t,modifier_states(prepared,.Multi_IK)[0].target,f32(.2))
    modifier_states(prepared,.Multi_IK)[0].base_enabled=false
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<120 {
        copy(playing_pose(&state,.Local),state.rest[:]);copy(playing_pose(&copied_state,.Local),copied_state.rest[:])
        stable &&=test_rigs_apply(&state,&modifiers,&characters,{problems=&problems},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60)
        stable &&=test_rigs_apply(&copied_state,&copied,&characters,{problems=&problems},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60)
    }
    context=saved
    testing.expect(t,stable && problems.count==0)
    for value,i in playing_pose(&state,.Local) {testing.expect_value(t,value,playing_pose(&copied_state,.Local)[i])}
    testing.expect_value(t,prepared.spring_states[0].springs,modifier_rig(core.ref(&copied),rig).spring_states[0].springs)
    state.bound+=1;state.targets[4]=base.name_hash("replaced")
    testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,0))
    state.bound+=1;state.aliases[4]=state.targets[4]
    testing.expect(t,!test_rigs_apply(&state,&modifiers,&characters,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,0))
    diagnostic,found=animation_rig_diagnostic(core.ref(&modifiers),rig,.Spring,base.name_hash("tail"));testing.expect(t,found && !diagnostic.valid)
}

@(test)
rig_goal_persistence_keeps_independent_effectors :: proc(t:^testing.T) {
    problems:core.Problems
    w:Rigs_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    body:=core.create(&w.entities)
    multi:=MULTI_IK_CONSTRAINT_DEFAULT;multi.effectors=make([]Multi_IK_Effector,int(2),context.temp_allocator)
    multi.effectors[0],multi.effectors[1]=MULTI_IK_EFFECTOR_DEFAULT,MULTI_IK_EFFECTOR_DEFAULT
    base.text_set(multi.name[:],"hands")
    base.text_set(multi.effectors[0].name[:],"left")
    base.text_set(multi.effectors[1].name[:],"right")
    characters:Character_Assets;defer character_assets_free(&characters)
    test_modifier_profile(&w.modifiers,&characters,body,{multi_ik={multi}})
    prepared:=modifier_rig(core.ref(&w.modifiers),body)
    modifier(&w.requests,{rig=body,kind=.Multi_IK,target=spatial_point({1,2,3}),weight=1,enabled=true,goal=true},"hands","left")
    modifier(&w.requests,{rig=body,kind=.Multi_IK,target=spatial_point({4,5,6}),weight=1,enabled=true,goal=true},"hands","right")
    modifier_take(&w.modifiers,&characters,&w.requests,&problems,0)
    testing.expect_value(t,len(prepared.overrides),2)
    testing.expect_value(t,modifier_override(prepared,.Multi_IK,0,0).target.position,mm.Vec3{1,2,3})
    testing.expect_value(t,modifier_override(prepared,.Multi_IK,0,1).target.position,mm.Vec3{4,5,6})
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<64 {
        modifier(&w.requests,{rig=body,kind=.Multi_IK,target=spatial_point({7,8,9}),weight=1,enabled=true,goal=true},"hands","left")
        modifier_take(&w.modifiers,&characters,&w.requests,&problems,0)
        stable &&=len(prepared.overrides)==2 && modifier_override(prepared,.Multi_IK,0,1).target.position==mm.Vec3{4,5,6}
    }
    context=saved;testing.expect(t,stable && problems.count==0)
}

@(test)
multi_ik_modifiers_accept_named_goals_keep_effectors_independent_and_clone_solver_scratch :: proc(t:^testing.T) {
    rig:=core.entity_make(1,1);state:=rig_test_state(rig,4,1);defer playing_free(&state)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    characters:Character_Assets;defer character_assets_free(&characters)
    multi:=MULTI_IK_CONSTRAINT_DEFAULT;base.text_set(multi.name[:],"body");multi.root=bone_ref("joint1");multi.joints=make([]Multi_IK_Joint,3,context.temp_allocator);multi.effectors=make([]Multi_IK_Effector,1,context.temp_allocator);multi.settings.iterations=128
    for &joint,i in multi.joints[:3] {joint=MULTI_IK_JOINT_DEFAULT;joint.bone=bone_ref(fmt.tprintf("joint%d",i+1))}
    multi.effectors[0]=MULTI_IK_EFFECTOR_DEFAULT;base.text_set(multi.effectors[0].name[:],"hand");multi.effectors[0].bone=bone_ref("joint4");multi.effectors[0].target=spatial_definition_point({1.2,1.7,0})
    base.text_set(multi.name[:],"body")
        test_modifier_profile(&modifiers,&characters,rig,{multi_ik={multi}})
    testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,{},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60))
    diagnostic,found:=animation_rig_diagnostic(core.ref(&modifiers),rig,.Multi_IK,base.name_hash("body"));testing.expect(t,found && diagnostic.valid && diagnostic.reached)
    requests:Animation_Requests;defer delete(requests.modifiers.items)
    modifier(&requests,{rig=rig,kind=.Multi_IK,target=spatial_point({.5,1.8,0}),weight=1,enabled=true,goal=true},"body","hand")
    modifier_take(&modifiers,&characters,&requests,nil,0)
    testing.expect_value(t,modifier_override(modifier_rig(core.ref(&modifiers),rig),.Multi_IK,0).target.position,mm.Vec3{.5,1.8,0})
    copy(playing_pose(&state,.Local),state.rest[:]);testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,{},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60))
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    copied_state:Playing;core.value_copy(&copied_state,&state,type_info_of(Playing));defer playing_free(&copied_state)
    testing.expect(t,raw_data(modifier_rig(core.ref(&copied),rig).multi_states[0].backup)!=raw_data(modifier_rig(core.ref(&modifiers),rig).multi_states[0].backup))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<60 {
        copy(playing_pose(&state,.Local),state.rest[:]);copy(playing_pose(&copied_state,.Local),copied_state.rest[:])
        stable &&=test_rigs_apply(&state,&modifiers,&characters,{},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60)
        stable &&=test_rigs_apply(&copied_state,&copied,&characters,{},nil,nil,mm.TRANSFORM_IDENTITY,1.0/60)
    }
    context=saved
    testing.expect(t,stable)
    for pose,i in playing_pose(&state,.Local) {testing.expect_value(t,pose,playing_pose(&copied_state,.Local)[i])}
    testing.expect_value(t,modifier_rig(core.ref(&modifiers),rig).multi_states[0].diagnostic,modifier_rig(core.ref(&copied),rig).multi_states[0].diagnostic)
}

@(test)
look_and_ik_publish_their_residual_and_whether_they_reach_in_the_constraints_of_the_rig :: proc(t:^testing.T) {
    problems:core.Problems
    rig:=core.entity_make(1,1)
    state:=rig_test_state(rig,3,.5);defer playing_free(&state)
    near:=IK_CONSTRAINT_DEFAULT;near.root,near.joint,near.end=bone_ref("joint1"),bone_ref("joint2"),bone_ref("joint3");near.target=spatial_definition_point({.4,.6,0})
    far:=near;far.target=spatial_definition_point({0,3,0})
    look:=LOOK_CONSTRAINT_DEFAULT;look.bone=bone_ref("joint3");look.target=spatial_definition_point({0,1,-5});look.max_angle=mm.PI
    base.text_set(near.name[:],"near");base.text_set(far.name[:],"far")
    looks:=[1]Look_Constraint{look}
    cache:Modifier_Runtime;defer modifier_runtime_free(&cache)
    playback:Playback;defer playback_free(&playback)
    transforms:core.Table(core.Transform);defer core.table_destroy(&transforms)
    characters:Character_Assets;defer character_assets_free(&characters)
    prepared:=test_modifier_profile(&cache,&characters,rig,{ik={near,far},look=looks[:]})
    inputs:=Constraint_Inputs{problems=&problems}
    constraints_apply(&state,&playback,inputs,&cache,&transforms,{},0,characters=&characters)
    testing.expect_value(t,problems.count,0)
    reached,found:=animation_rig_diagnostic(core.ref(&cache),rig,.IK,base.name_hash("near"))
    testing.expect(t,found && reached.rig==rig && reached.kind==.IK && reached.valid && reached.reached && reached.residual<.001)
    missed,missed_found:=animation_rig_diagnostic(core.ref(&cache),rig,.IK,base.name_hash("far"))
    testing.expect(t,missed_found && missed.valid && !missed.reached && abs(missed.residual-2)<1e-3,"an unreachable target is a residual, not an invalid solve")
    aimed,aimed_found:=animation_rig_diagnostic(core.ref(&cache),rig,.Look,base.name_hash("joint3"))
    testing.expect(t,aimed_found && aimed.valid && aimed.reached && aimed.residual<1e-3 && aimed.angular_error<1e-3)
    _,beyond:=animation_rig_diagnostic(core.ref(&cache),rig,.Look,base.name_hash("missing"));_,elsewhere:=animation_rig_diagnostic({},rig,.IK,base.name_hash("near"))
    testing.expect(t,!beyond && !elsewhere)
    // With an offset (eyes above the bone) the ray from the offset passes through the target.
    looks[0].offset={0,.2,-.1}
    copy(playing_pose(&state,.Local),state.rest[:]);constraints_apply(&state,&playback,inputs,&cache,&transforms,{},0,characters=&characters)
    aimed,_=animation_rig_diagnostic(core.ref(&cache),rig,.Look,base.name_hash("joint3"))
    testing.expect(t,problems.count==0 && aimed.valid && aimed.reached && aimed.residual<1e-3,"the eyes aim at the target")
    looks[0].target=spatial_definition_point({5,1,0});looks[0].max_angle=.2
    copy(playing_pose(&state,.Local),state.rest[:]);constraints_apply(&state,&playback,inputs,&cache,&transforms,{},0,characters=&characters)
    aimed,_=animation_rig_diagnostic(core.ref(&cache),rig,.Look,base.name_hash("joint3"))
    testing.expect(t,problems.count==0 && aimed.valid && !aimed.reached && aimed.angular_error>1 && aimed.residual>1,"a look held by max_angle says how far it misses")
    modifier_states(prepared,.Look)[0].base_enabled=false
    copy(playing_pose(&state,.Local),state.rest[:]);constraints_apply(&state,&playback,inputs,&cache,&transforms,{},0,characters=&characters)
    aimed,_=animation_rig_diagnostic(core.ref(&cache),rig,.Look,base.name_hash("joint3"))
    testing.expect(t,!aimed.valid)
}

@(test)
the_sampled_pose_of_a_rig_is_the_one_before_its_rig_operations :: proc(t:^testing.T) {
    problems:core.Problems
    rig:=core.entity_make(1,1)
    playback:Playback;defer playback_free(&playback)
    append(&playback.states,rig_test_state(rig,3,.5))
    resize(&playback.rows,core.entity_index(rig)+1);playback.rows[core.entity_index(rig)]=1
    state:=&playback.states[0]
    transforms:core.Table(core.Transform);defer core.table_destroy(&transforms)
    inputs:=Constraint_Inputs{problems=&problems}
    reaching,still:Modifier_Runtime;defer {modifier_runtime_free(&reaching);modifier_runtime_free(&still)}
    multi:=MULTI_IK_CONSTRAINT_DEFAULT;multi.root=bone_ref("joint1")
    multi.joints=make([]Multi_IK_Joint,3,context.temp_allocator);multi.effectors=make([]Multi_IK_Effector,1,context.temp_allocator);multi.settings.iterations=4
    for &joint,i in multi.joints[:3] {joint=MULTI_IK_JOINT_DEFAULT;joint.bone=bone_ref(fmt.tprintf("joint%d",i+1))}
    multi.effectors[0]=MULTI_IK_EFFECTOR_DEFAULT;multi.effectors[0].bone=bone_ref("joint3");multi.effectors[0].target=spatial_definition_point({.4,.5,0})
    characters:Character_Assets;defer character_assets_free(&characters)
    test_modifier_profile(&reaching,&characters,rig,{multi_ik={multi}})
    // The end of a tick of this rig: the sampled pose, then its modifiers.
    tick :: proc(playback:^Playback,state:^Playing,inputs:Constraint_Inputs,characters:^Character_Assets,transforms:^core.Table(core.Transform),modifiers:^Modifier_Runtime) {
        playing_pose(state,.Sampled)[2].rotation=mm.quat_axis_angle({0,0,1},.3)
        copy(playing_pose(state,.Local),playing_pose(state,.Sampled))
        constraints_apply(state,playback,inputs,modifiers,transforms,{},1.0/60,characters=characters)
        state.pose_ready=true
    }
    same :: proc(a,b:[]mm.Transform) -> bool {
        if len(a)!=len(b) {return false}
        for x,i in a {if linalg.length(x.position-b[i].position)>1e-5 || mm.quat_angle(x.rotation,b[i].rotation)>1e-4 {return false}}
        return true
    }
    tick(&playback,state,inputs,&characters,&transforms,&reaching)
    sampled,sampled_ok:=pose_space(core.ref(&playback),rig,context.temp_allocator,.Sampled)
    finished,finished_ok:=pose_space(core.ref(&playback),rig,context.temp_allocator)
    testing.expect(t,sampled_ok && finished_ok && problems.count==0)
    testing.expect(t,!same(sampled,finished),"the Multi IK row moves the chain after the sampled pose")
    tick(&playback,state,inputs,&characters,&transforms,&still)
    sampled,_=pose_space(core.ref(&playback),rig,context.temp_allocator,.Sampled)
    finished,_=pose_space(core.ref(&playback),rig,context.temp_allocator)
    testing.expect(t,same(sampled,finished),"no row moves a bone")
    _,posed:=pose_space(core.ref(&playback),core.entity_make(9,1),context.temp_allocator,.Sampled)
    testing.expect(t,!posed)
}
