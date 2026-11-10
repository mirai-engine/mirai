package anim

import "base:runtime"
import "core:log"
import "core:testing"
import "core:time"
import "mirai:core"
import "mirai:host"

when #config(MIRAI_BENCH,false) {
@(private="file")
Discovery_Bench_World :: struct {
    using world:core.Test_World,
    descriptions:core.Table(Animation),
}

@(test)
bench_animation_optional_feature_discovery :: proc(t:^testing.T) {
    COUNT :: 4096
    REPEATS :: 500
    for feature_count,case_index in ([4]int{0,16,256,16}) {
        w:Discovery_Bench_World
        if !core.test_world_init(t,&w,test_types) {return}
        defer core.test_world_destroy(&w)
        for i in 0..<COUNT {
            entity:=core.create(&w.entities);description:=ANIMATION_DEFAULT
            if i<feature_count {description.actions={3,4};description.motion={5,6}}
            core.add(&w.descriptions,entity,description)
        }
        core.test_world_settle(&w)
        host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
        action_assets:=Actions_Assets{allocator=context.allocator};defer actions_assets_free(&action_assets)
        append(&action_assets.contents,Action_Content{id={3,4},checked=1,revision=1,profile=action_test_profile(),valid=true})
        motion_assets:=Motion_Assets{allocator=context.allocator};defer motion_assets_free(&motion_assets)
        append(&motion_assets.contents,Motion_Content{id={5,6},checked=1,revision=1,profile=motion_test_profile(),valid=true})
        actions:Action_Runtime;defer actions_runtime_free(&actions)
        motion:Motion_Runtime;defer motion_runtime_free(&motion)
        requests:Action_Requests;defer delete(requests.queue.items)
        targets:Motion_Requests;defer {delete(targets.targets.items);delete(targets.locomotion.items)}
        playback:Playback;defer playback_free(&playback)
        problems:core.Problems
        for _ in 0..<2 {
            if !testing.expect(t,actions_prepare(&actions,&requests,&action_assets,core.read(&w.descriptions),&playback,app.assets,app.allocator,&problems) && motion_prepare(&motion,&targets,core.read(&w.descriptions),&playback,&motion_assets,app.assets,app.allocator,&problems)) {return}
        }
        best:=max(time.Duration);valid:=true
        saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
        for _ in 0..<5 {
            start:=time.tick_now()
            for tick in 0..<REPEATS {
                if case_index==3 {core.edit_at(&w.descriptions,COUNT-1).weight=f32(tick&1)}
                valid &&=actions_prepare(&actions,&requests,&action_assets,core.read(&w.descriptions),&playback,app.assets,app.allocator,&problems)
                valid &&=motion_prepare(&motion,&targets,core.read(&w.descriptions),&playback,&motion_assets,app.assets,app.allocator,&problems)
            }
            best=min(best,time.tick_since(start))
        }
        context=saved;app.allocator=saved.allocator;actions.allocator=saved.allocator;action_assets.allocator=saved.allocator;motion_assets.allocator=saved.allocator
        testing.expect(t,valid && len(actions.states)==feature_count && len(motion.instances)==feature_count && problems.count==0 && len(actions.events.items)==0)
        log.infof("animation feature preparation, %d components / %d configured, changed unrelated row %v: %.2f ns/tick",COUNT,feature_count,case_index==3,f64(time.duration_nanoseconds(best))/REPEATS)
    }
}
}
