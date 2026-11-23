package anim

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:testing"
import "core:time"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

when #config(MIRAI_BENCH,false) {
@(test)
bench_rig_dispatch_and_multi_ik_scaling :: proc(t:^testing.T) {
    problems:core.Problems
    COUNTS :: [?]int{8,64,256}
    log.infof("rig binding bytes/operation: twist %d, spring %d, Multi IK %d, chain retarget %d",size_of(Twist_Binding),size_of(Spring_Binding),size_of(Multi_IK_Binding),size_of(Chain_Retarget_Binding))
    labels:=[?]string{"no rig operations","two disabled operations per kind","one active Multi IK"}
    for count in COUNTS {
        for label,variant in labels {
            modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
            characters:Character_Assets;defer character_assets_free(&characters)
            states:[dynamic]Playing
            defer {for &state in states {playing_free(&state)};delete(states)}
            for i in 0..<count {
                entity:=core.entity_make(i+1,1)
                append(&states,rig_test_state(entity,63,.25))
                if variant==0 {continue}
                operations:=2 if variant==1 else 1
                multis:=make([]Multi_IK_Constraint,operations,context.temp_allocator)
                others:=operations if variant==1 else 0
                twists:=make([]Twist_Constraint,others,context.temp_allocator)
                springs:=make([]Spring_Constraint,others,context.temp_allocator)
                retargets:=make([]Chain_Retarget_Constraint,others,context.temp_allocator)
                for operation in 0..<operations {
                    multi:=MULTI_IK_CONSTRAINT_DEFAULT
                    multi.root=bone_ref("joint1")
                    multi.joints=make([]Multi_IK_Joint,3,context.temp_allocator);multi.effectors=make([]Multi_IK_Effector,1,context.temp_allocator);multi.settings.iterations=4
                    multi.enabled=variant==2
                    for &joint,j in multi.joints {joint=MULTI_IK_JOINT_DEFAULT;joint.bone=bone_ref(fmt.tprintf("joint%d",j+1))}
                    multi.effectors[0]=MULTI_IK_EFFECTOR_DEFAULT
                    multi.effectors[0].bone,multi.effectors[0].target=bone_ref("joint4"),spatial_definition_point({.3,.5,0})
                    base.text_set(multi.name[:],fmt.tprintf("body%d",operation))
                    multis[operation]=multi
                    if variant==2 {continue}
                    chain:=struct {root,end:Bone_Ref}{bone_ref("joint1"),bone_ref("joint4")}
                    twist:=TWIST_CONSTRAINT_DEFAULT
                    twist.source,twist.root,twist.end,twist.enabled=bone_ref("joint5"),chain.root,chain.end,false
                    base.text_set(twist.name[:],fmt.tprintf("roll%d",operation))
                    spring:=SPRING_CONSTRAINT_DEFAULT
                    spring.root,spring.end,spring.enabled=chain.root,chain.end,false
                    base.text_set(spring.name[:],fmt.tprintf("tail%d",operation))
                    retarget:=CHAIN_RETARGET_CONSTRAINT_DEFAULT;retarget.enabled=false
                    base.text_set(retarget.name[:],fmt.tprintf("transfer%d",operation))
                    twists[operation]=twist
                    springs[operation]=spring;retargets[operation]=retarget
                }
                test_modifier_profile(&modifiers,&characters,entity,{twist=twists,
                    springs=springs,multi_ik=multis,retarget_chains=retargets})
            }
            playback:Playback
            for &state in states {
                if !testing.expect(t,(variant!=1 || test_rigs_retarget(&state,&playback,&modifiers,&characters,&problems)) && test_rigs_apply(&state,&modifiers,&characters,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)) {return}
            }
            state_bytes:=0
            for &rig in modifiers.rigs {
                state_bytes+=cap(rig.twist_states)*size_of(Twist_Binding)+cap(rig.spring_states)*size_of(Spring_Binding)+cap(rig.multi_states)*size_of(Multi_IK_Binding)+cap(rig.retarget_chain_states)*size_of(Chain_Retarget_Binding)
                for &binding in rig.multi_states {state_bytes+=cap(binding.backup)*size_of(mm.Transform)}
                for &binding in rig.retarget_chain_states {state_bytes+=(cap(binding.source_rest)+cap(binding.source_pose)+cap(binding.target_rest)+cap(binding.source_world)+cap(binding.target_world))*size_of(mm.Transform)}
            }
            log.infof("rig dispatch, %d rigs, %s: %d capacity bytes for solver state and pose scratch",count,label,state_bytes)
            stable:=true;sink:f32
            repeats:=max(8,2048/count)
            best:=max(time.Duration)
            saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
            for _ in 0..<5 {
                start:=time.tick_now()
                for _ in 0..<repeats {
                    for &state in states {
                        if variant==2 {copy(playing_pose(&state,.Local),state.rest[:])}
                        if variant==1 {stable &&=test_rigs_retarget(&state,&playback,&modifiers,&characters,&problems)}
                        stable &&=test_rigs_apply(&state,&modifiers,&characters,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)
                        sink+=playing_pose(&state,.Local)[4].rotation.z
                    }
                }
                best=min(best,time.tick_since(start))
            }
            context=saved
            testing.expect(t,stable && problems.count==0)
            log.infof("rig dispatch, %d rigs / 64 bones, %s: %.2f us/batch, %.2f ns/rig (check %v)",count,label,f64(time.duration_nanoseconds(best))/f64(repeats)/1000,f64(time.duration_nanoseconds(best))/f64(repeats*count),sink)
        }
    }
}
}
