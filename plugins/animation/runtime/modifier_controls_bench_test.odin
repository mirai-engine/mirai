package anim

import "base:runtime"
import "core:log"
import "core:testing"
import "core:time"
import "mirai:core"

when #config(MIRAI_BENCH,false) {
@(test)
bench_modifier_controls_idle_and_sparse_fades :: proc(t:^testing.T) {
    problems:core.Problems
    for count in ([?]int{64,512,4096}) {
        for active in ([?]int{0,4}) {
            modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
            previous:Modifier_Runtime
            requests:Animation_Requests;defer delete(requests.controls.items)
            for i in 0..<count {
                entity:=core.entity_make(i+1,1)
                if !testing.expect(t,modifier_append(&modifiers.ik,entity,IK_Constraint{rig=entity,weight=1,enabled=true})) {return}
            }
            if !testing.expect(t,modifier_controls_prepare(&modifiers,&previous)) {return}
            for i in 0..<active {modifier_control(&requests,{rig=core.entity_make(i+1,1),kind=.IK,weight=.5,enabled=true,fade=1000000})}
            modifier_controls_take(&modifiers,&requests,&problems,1.0/60)
            best:=max(time.Duration);sink:f32
            saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
            for _ in 0..<5 {
                start:=time.tick_now()
                for _ in 0..<4096 {
                    modifier_controls_take(&modifiers,&requests,&problems,1.0/60)
                    state:=modifier_control_state(&modifiers,core.entity_make(count,1),.IK,0)
                    if state!=nil {sink+=state.weight}
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
