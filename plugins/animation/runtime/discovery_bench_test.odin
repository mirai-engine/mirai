package anim

import "base:runtime"
import "core:log"
import "core:testing"
import "core:time"
import "mirai:core"
import "mirai:host"

when #config(MIRAI_BENCH,false) {
@(private)
@(test_world)
Discovery_Bench_World :: struct {
    using world:Test_World,
    descriptions:core.Table(Animation),
}

@(test)
bench_animation_optional_feature_discovery :: proc(t:^testing.T) {
    COUNT :: 4096
    REPEATS :: 500
    for feature_count,case_index in ([4]int{0,16,256,16}) {
        w:Discovery_Bench_World
        if !test_world_init(t,&w) {return}
        defer test_world_destroy(&w)
        for i in 0..<COUNT {
            entity:=core.create(&w.entities);description:=ANIMATION_DEFAULT
            if i<feature_count {description.asset={3,4}}
            core.add(&w.descriptions,entity,description)
        }
        test_world_settle(&w)
        host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
        characters:=Character_Assets{allocator=context.allocator};defer character_assets_free(&characters)
        test_character_register(&host_assets,{3,4});defer test_registry_free(&host_assets)
        profile,motion_profile:=action_test_profile(),motion_test_profile();defer {action_profile_free(&profile);motion_test_free(&motion_profile)}
        test_character_seed(&characters,{3,4},{info={animation={1,2}},actions=profile,motion=motion_profile})
        actions:Action_Runtime;defer actions_runtime_free(&actions)
        motion:Motion_Runtime;defer motion_runtime_free(&motion)
        requests:Animation_Requests;defer {delete(requests.plays.items);delete(requests.values.items);delete(requests.warps.items);delete(requests.locomotion.items)}
        events:Animation_Events;defer delete(events.items)
        played:core.Table(Animation_Played);defer core.table_destroy(&played)
        remotes:core.Table(core.Remote);defer core.table_destroy(&remotes)
        playback:Playback;defer playback_free(&playback)
        problems:core.Problems
        for _ in 0..<2 {
            if !testing.expect(t,actions_prepare(&actions,&requests,&characters,core.read(&w.descriptions),&playback,&events,&app,core.read(&remotes),&played,{dt=1.0/60,playing=true},&problems) && motion_prepare(&motion,&requests,core.read(&w.descriptions),&playback,&characters,app.assets,app.allocator,&problems)) {return}
        }
        best:=max(time.Duration);valid:=true
        saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
        for _ in 0..<5 {
            start:=time.tick_now()
            for tick in 0..<REPEATS {
                if case_index==3 {core.edit_at(&w.descriptions,COUNT-1).weight=f32(tick&1)}
                valid &&=actions_prepare(&actions,&requests,&characters,core.read(&w.descriptions),&playback,&events,&app,core.read(&remotes),&played,{dt=1.0/60,playing=true},&problems)
                valid &&=motion_prepare(&motion,&requests,core.read(&w.descriptions),&playback,&characters,app.assets,app.allocator,&problems)
            }
            best=min(best,time.tick_since(start))
        }
        context=saved;app.allocator=saved.allocator;actions.allocator=saved.allocator;characters.allocator=saved.allocator
        testing.expect(t,valid && len(actions.states)==feature_count && len(motion.instances)==feature_count && problems.count==0 && len(events.items)==0)
        log.infof("animation feature preparation, %d components / %d configured, changed unrelated row %v: %.2f ns/tick",COUNT,feature_count,case_index==3,f64(time.duration_nanoseconds(best))/REPEATS)
    }
}
}
