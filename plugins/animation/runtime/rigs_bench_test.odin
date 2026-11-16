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
    log.infof("rig binding bytes/operation: chain %d, twist %d, spring %d, Multi IK %d, chain retarget %d",size_of(Chain_IK_Binding),size_of(Twist_Binding),size_of(Spring_Binding),size_of(Multi_IK_Binding),size_of(Chain_Retarget_Binding))
    labels:=[?]string{"no rig operations","two disabled operations per kind","one active Multi IK"}
    for count in COUNTS {
        for label,variant in labels {
            modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
            states:[dynamic]Playing
            defer {for &state in states {playing_free(&state)};delete(states)}
            for i in 0..<count {
                entity:=core.entity_make(i+1,1)
                append(&states,rig_test_state(entity,63,.25))
                if variant==0 {continue}
                for operation in 0..<(2 if variant==1 else 1) {
                    multi:=MULTI_IK_CONSTRAINT_DEFAULT
                    multi.rig,multi.root=entity,bone_ref("joint1")
                    multi.joint_count,multi.effector_count=3,1;multi.settings.iterations=4
                    multi.enabled=variant==2
                    for &joint,j in multi.joints[:multi.joint_count] {joint=MULTI_IK_JOINT_DEFAULT;joint.bone=bone_ref(fmt.tprintf("joint%d",j+1))}
                    multi.effectors[0]=MULTI_IK_EFFECTOR_DEFAULT
                    multi.effectors[0].bone,multi.effectors[0].target=bone_ref("joint4"),spatial_point({.3,.5,0})
                    base.text_set(multi.name[:],fmt.tprintf("body%d",operation))
                    if !testing.expect(t,modifier_append(&modifiers.multi_ik,entity,multi)) {return}
                    if variant==2 {continue}
                    chain:=CHAIN_IK_CONSTRAINT_DEFAULT
                    chain.rig,chain.root,chain.end,chain.enabled=entity,bone_ref("joint1"),bone_ref("joint4"),false
                    base.text_set(chain.name[:],fmt.tprintf("arm%d",operation))
                    twist:=TWIST_CONSTRAINT_DEFAULT
                    twist.rig,twist.source,twist.root,twist.end,twist.enabled=entity,bone_ref("joint5"),chain.root,chain.end,false
                    base.text_set(twist.name[:],fmt.tprintf("roll%d",operation))
                    spring:=SPRING_CONSTRAINT_DEFAULT
                    spring.rig,spring.root,spring.end,spring.enabled=entity,chain.root,chain.end,false
                    base.text_set(spring.name[:],fmt.tprintf("tail%d",operation))
                    retarget:=CHAIN_RETARGET_CONSTRAINT_DEFAULT;retarget.rig,retarget.enabled=entity,false
                    base.text_set(retarget.name[:],fmt.tprintf("transfer%d",operation))
                    if !testing.expect(t,modifier_append(&modifiers.chain_ik,entity,chain) && modifier_append(&modifiers.twist,entity,twist) && modifier_append(&modifiers.springs,entity,spring) && modifier_append(&modifiers.retarget_chains,entity,retarget)) {return}
                }
            }
            playback:Playback
            for &state in states {
                if !testing.expect(t,rigs_retarget(&state,&playback,&modifiers,&problems) && rigs_apply(&state,&modifiers,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)) {return}
            }
            state_bytes:=cap(modifiers.chain_states)*size_of(Chain_IK_Binding)+cap(modifiers.twist_states)*size_of(Twist_Binding)+cap(modifiers.spring_states)*size_of(Spring_Binding)+cap(modifiers.multi_states)*size_of(Multi_IK_Binding)+cap(modifiers.retarget_chain_states)*size_of(Chain_Retarget_Binding)
            for binding in modifiers.multi_states {state_bytes+=cap(binding.backup)*size_of(mm.Transform)}
            for binding in modifiers.retarget_chain_states {state_bytes+=(cap(binding.source_rest)+cap(binding.source_pose)+cap(binding.target_rest)+cap(binding.source_world)+cap(binding.target_world))*size_of(mm.Transform)}
            log.infof("rig dispatch, %d rigs, %s: %d capacity bytes for solver state and pose scratch",count,label,state_bytes)
            stable:=true;sink:f32
            repeats:=max(8,2048/count)
            best:=max(time.Duration)
            saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
            for _ in 0..<5 {
                start:=time.tick_now()
                for _ in 0..<repeats {
                    for &state in states {
                        if variant==2 {copy(state.local[:],state.rest[:])}
                        stable &&=rigs_retarget(&state,&playback,&modifiers,&problems)
                        stable &&=rigs_apply(&state,&modifiers,{problems=&problems},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)
                        sink+=state.local[4].rotation.z
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
