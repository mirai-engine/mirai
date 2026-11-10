package anim

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"

@(private)
program_buffer_fixture :: proc(t:^testing.T,graphs:^Graph_Assets,id:base.Asset_Id) {
    nodes:=program_test_graph()
    profile:=Graph_Profile{info={animation={1,2},output=4}}
    profile.nodes=make([]Graph_Node,len(nodes));copy(profile.nodes,nodes[:])
    compiled:=Graph_Content{id=id,checked=1,revision=1,valid=true,profile=profile}
    testing.expect(t,graph_check(profile))
    for _,i in nodes {compiled.plans[i],_=graph_plan(profile,i)}
    append(&graphs.contents,compiled)
}

@(private)
program_buffer_step :: proc(f:^Program_Feature_Fixture,app:^host.App,graphs:^Graph_Assets,dt:f32) -> bool {
    clear(&f.events.items)
    output,programmed,ok:=program_resolve(&f.state,f.animation,app,nil,graphs,dt)
    if !ok || !programmed {return false}
    if !program_masks_prepare(&f.state,output,&f.content,graphs,app.assets,app.allocator) {return false}
    if !program_players(&f.state,output,&f.content,f.animation,&f.events,&f.playback,dt,-1,nil) || !program_pose(&f.playback,&f.state,&f.content,f.animation,output,{}) {return false}
    copy(f.state.sampled[:],f.state.local[:]);f.state.pose_ready=true
    return true
}

@(test)
graph_output_preparation_retries_allocation_failures_from_a_clean_start :: proc(t:^testing.T) {
    id:=base.Asset_Id{78,81}
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator}
    graphs:Graph_Assets;program_buffer_fixture(t,&graphs,id);defer graph_assets_free(&graphs)
    failure:=Runtime_Allocation_Failure{owner=context.allocator}
    succeeded:=false;failures:=0
    for budget in 0..<16 {
        state:=Playing{entity=core.entity_make(1,1)}
        state.program.asset,state.program.kind,state.program.checked=id,GRAPH_KIND,1
        animation:=ANIMATION_DEFAULT;animation.asset=id
        failure.remaining=budget
        saved:=context;context.allocator={runtime_failure_allocator,&failure};context.temp_allocator=context.allocator
        _,programmed,ok:=program_resolve(&state,animation,&app,nil,&graphs,0)
        context=saved
        testing.expect(t,programmed)
        if ok {succeeded=true;playing_free(&state);break}
        failures+=1
        testing.expect(t,state.program.error==.Out_Of_Memory && !state.program.ready && state.program.epoch==0)
        failure.remaining=1000
        output,_,retried:=program_resolve(&state,animation,&app,nil,&graphs,0)
        testing.expect(t,retried && state.program.ready && state.program.error==.None && output.count>0)
        playing_free(&state)
    }
    testing.expect(t,succeeded && failures>0)
}

@(test)
graph_output_compaction_preserves_merged_groups_reused_by_multiple_dag_edges :: proc(t:^testing.T) {
    expected,actual:Program_Feature_Fixture
    program_feature_init(&expected,t);program_feature_init(&actual,t)
    defer program_feature_free(&expected);defer program_feature_free(&actual)
    nodes:=program_test_graph();nodes[4].kind,nodes[4].left,nodes[4].right=.Blend,3,3;nodes[4].over={}
    if !testing.expect(t,program_feature_sample(&expected,nodes[:],3,.5) && program_feature_sample(&actual,nodes[:],4,.5)) {return}
    testing.expect_value(t,actual.output.count,u8(1));testing.expect_value(t,actual.output.groups[0].count,u8(2))
    for value,i in actual.state.local {testing.expect_value(t,value,expected.state.local[i])}
    for value,i in actual.state.curves {testing.expect_value(t,value,expected.state.curves[i])}
    testing.expect_value(t,actual.state.motion,expected.state.motion)
    testing.expect_value(t,len(actual.events.items),len(expected.events.items))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator
    stable:=true
    for _ in 0..<8 {
        stable &&=program_feature_sample(&actual,nodes[:],0,0) && program_feature_sample(&actual,nodes[:],4,0)
    }
    context=saved
    testing.expect(t,stable && actual.output.count==1 && actual.output.groups[0].count==2)
}

@(test)
graph_output_buffers_are_freed_after_reusing_a_snapshot_for_a_direct_clip :: proc(t:^testing.T) {
    f:Program_Feature_Fixture;program_feature_init(&f,t)
    id:=base.Asset_Id{78,83};f.animation.asset=id
    f.state.program.asset,f.state.program.kind,f.state.program.checked=id,GRAPH_KIND,1
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator}
    graphs:Graph_Assets;program_buffer_fixture(t,&graphs,id);defer graph_assets_free(&graphs)
    tracker:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
    saved:=context;context.allocator=mem.tracking_allocator(&tracker)
    valid:=program_buffer_step(&f,&app,&graphs,.1)
    copied:Playing
    if valid {
        core.value_copy(&copied,&f.state,type_info_of(Playing))
        f.animation.asset={78,84}
        _,programmed,ok:=program_resolve(&f.state,f.animation,&app,nil,&graphs,0,nil)
        valid=ok && !programmed
        core.value_copy(&copied,&f.state,type_info_of(Playing))
    }
    context=saved
    playing_free(&copied);program_feature_free(&f)
    testing.expect(t,valid && tracker.current_memory_allocated==0 && len(tracker.bad_free_array)==0)
}
