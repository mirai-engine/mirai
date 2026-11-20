package anim

import "base:runtime"
import "core:log"
import "core:testing"
import "core:time"
import "mirai:core"
import "mirai:std/base"

when #config(MIRAI_BENCH,false) {
@(test)
bench_modifier_controls_idle_and_sparse_fades :: proc(t:^testing.T) {
    problems:core.Problems
    for count in ([?]int{64,512,4096}) {
        for active in ([?]int{0,4}) {
            modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
            characters:Character_Assets;defer character_assets_free(&characters)
            ik:=IK_CONSTRAINT_DEFAULT;ik.end=bone_ref("hand")
            profile:=Pose_Profile{ik={ik}}
            requests:Animation_Requests;defer delete(requests.modifiers.items)
            for i in 0..<count {
                entity:=core.entity_make(i+1,1)
                if !testing.expect(t,test_modifier_profile(&modifiers,&characters,entity,profile)!=nil) {return}
            }
            for i in 0..<active {modifier(&requests,{rig=core.entity_make(i+1,1),kind=.IK,weight=.5,enabled=true,fade=1000000},"hand")}
            modifier_take(&modifiers,&characters,&requests,&problems,1.0/60)
            best:=max(time.Duration);sink:f32
            saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
            for _ in 0..<5 {
                start:=time.tick_now()
                for _ in 0..<4096 {
                    modifier_take(&modifiers,&characters,&requests,&problems,1.0/60)
                    weight,_,_,_,_,_,_:=modifier_influence(&modifiers,core.entity_make(count,1),.IK,base.name_hash("hand"))
                    sink+=weight
                }
                best=min(best,time.tick_since(start))
            }
            context=saved
            log.infof("modifier controls: controls=%d active=%d %.2f ns/tick sink=%f",count,active,f64(best)/4096,sink)
            testing.expect_value(t,problems.count,0)
        }
    }
}
}
