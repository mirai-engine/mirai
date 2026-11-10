package anim

import "core:fmt"
import "core:log"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(private)
program_bench_state :: proc() -> Playing {
    state:=Playing{clip=-1}
    for i in 0..<64 {
        name:[32]u8
        target:=base.name_hash(fmt.bprintf(name[:],"bone%d",i))
        parent:=i32(i)-1
        append(&state.bindings,Binding{target=target,driven={.Position,.Rotation},rest=mm.TRANSFORM_IDENTITY,parent=parent})
        append(&state.parents,parent);append(&state.targets,target);append(&state.rest,mm.TRANSFORM_IDENTITY)
    }
    resize(&state.local,64);resize(&state.world,64);resize(&state.program.from,64)
    copy(state.local[:],state.rest[:])
    return state
}

@(private)
program_bench_pose_hash :: proc(pose:[]mm.Transform) -> u64 {
    result:u64
    for transform in pose {
        for value in transform.position {result=base.hash_combine(result,u64(transmute(u32)value))}
        for value in ([4]f32{transform.rotation.x,transform.rotation.y,transform.rotation.z,transform.rotation.w}) {result=base.hash_combine(result,u64(transmute(u32)value))}
        for value in transform.scale {result=base.hash_combine(result,u64(transmute(u32)value))}
    }
    return result
}

@(private)
program_bench_step :: proc(state:^Playing,playback:^Playback,content:^host.Content_Animation,animation:Animation,events:^Animation_Events,app:^host.App,blends:^Blend_Assets,graphs:^Graph_Assets) -> bool {
    clear(&events.items)
    copy(state.local[:],state.rest[:])
    output,programmed,ok:=program_resolve(state,animation,app,blends,graphs,1.0/60)
    if !ok {return false}
    if programmed {
        if !program_masks_prepare(state,output,content,graphs,app.assets,app.allocator) {return false}
        if !program_players(state,output,content,animation,events,playback,1.0/60,-1,nil) {return false}
        if !program_pose(playback,state,content,animation,output,{}) {return false}
        layers_advance(playback,state,content,animation,events,1.0/60,nil)
        pose_layers(playback,state,&content.lib,animation,nil)
    } else {
        advance(playback,state,content,animation,events,1.0/60,nil)
        layers_advance(playback,state,content,animation,events,1.0/60,nil)
        pose_sample(playback,state,&content.lib,animation,{},nil)
        sample_curves(state,content,animation.weight)
    }
    return true
}

when #config(MIRAI_BENCH,false) {
@(test)
bench_animation_programs_64_bones :: proc(t:^testing.T) {
    REPEATS :: 10000
    directory:=base.test_folder(t,"bench-animation-program")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    positions,rotations:[64][2]lib.Keyframe
    tracks:[128]asset.Animation_Track_Desc
    for i in 0..<64 {
        positions[i]={{time=0,value={0,.01,0,0}},{time=1,value={.01,.01,0,0}}}
        rotations[i]={{time=0,value={0,0,0,1}},{time=1,value=lib.quat_vec4(mm.quat_axis_angle({0,1,0},.2))}}
        target:=fmt.tprintf("bone%d",i)
        tracks[i*2]={target=target,property=.Position,keys=positions[i][:]}
        tracks[i*2+1]={target=target,property=.Rotation,keys=rotations[i][:]}
    }
    clips:=[2]asset.Animation_Clip_Desc{{name="first",tracks=tracks[:]},{name="second",tracks=tracks[:]}}
    animation_id:=base.Asset_Id{100,1};blend_id:=base.Asset_Id{100,2};graph_clip_id:=base.Asset_Id{100,3};graph_layer_id:=base.Asset_Id{100,4}
    if !testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/source.anim",directory),&types,{id=animation_id,clips=clips[:]}),asset.Error.None) {return}
    nodes:=[3]Graph_Node{GRAPH_NODE_DEFAULT,GRAPH_NODE_DEFAULT,GRAPH_NODE_DEFAULT}
    for &node,i in nodes {base.text_set(node.name[:],fmt.tprintf("node%d",i))}
    base.text_set(nodes[0].clip[:],"first");base.text_set(nodes[1].clip[:],"second")
    nodes[2].kind=.Layer;nodes[2].left,nodes[2].right=0,1;base.text_set(nodes[2].over[:],"bone32")
    graph:=Graph_Profile{info={animation=animation_id},nodes=nodes[:]}
    if !testing.expect_value(t,graph_save(fmt.tprintf("%s/one.agraph",directory),&types,graph_clip_id,graph),asset.Error.None) {return}
    graph.info.output=2
    if !testing.expect_value(t,graph_save(fmt.tprintf("%s/layer.agraph",directory),&types,graph_layer_id,graph),asset.Error.None) {return}
    blend_nodes:=[3]Graph_Node{nodes[0],nodes[1],GRAPH_NODE_DEFAULT}
    base.text_set(blend_nodes[2].name[:],"blend")
    blend_nodes[2].kind,blend_nodes[2].left,blend_nodes[2].right,blend_nodes[2].weight_param=.Blend,0,1,0
    parameters:=[1]Graph_Parameter{{value=.5,min=0,max=1}};base.text_set(parameters[0].name[:],"blend")
    blended:=Graph_Profile{info={animation=animation_id,output=2},nodes=blend_nodes[:],parameters=parameters[:]}
    if !testing.expect_value(t,graph_save(fmt.tprintf("%s/blend.agraph",directory),&types,blend_id,blended),asset.Error.None) {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory,capacity=8})) {return};defer host.assets_destroy(&assets)
    allocation:=Runtime_Allocation_Failure{owner=context.allocator,remaining=100000}
    app:=host.App{assets=&assets,allocator={runtime_failure_allocator,&allocation}};defer host.app_content_destroy(&app)
    content:=host.content_animation(&app,animation_id);if !testing.expect(t,content!=nil) {return}
    blends:Blend_Assets;graphs:Graph_Assets;defer blend_assets_free(&blends);defer graph_assets_free(&graphs)
    // All cases sample identical clips, so their resulting poses are equal.
    ids:=[4]base.Asset_Id{animation_id,graph_clip_id,blend_id,graph_layer_id}
    labels:=[4]string{"direct clip","graph one clip","graph blend two clips","graph two clips + branch layer"}
    results:[4]f64
    sink:f32
    for id,case_index in ids {
        state:=program_bench_state();defer playing_free(&state)
        playback:Playback;defer playback_free(&playback)
        if !testing.expect(t,lib.pose_init(&playback.pose,256)) {return}
        events:Animation_Events;defer delete(events.items)
        animation:=ANIMATION_DEFAULT;animation.asset=id
        if id==blend_id {animation_parameter(&animation,"blend",.5)}
        for _ in 0..<4 {if !testing.expect(t,program_bench_step(&state,&playback,content,animation,&events,&app,&blends,&graphs)) {return}}
        allocations:=allocation.calls
        best:=max(time.Duration)
        stable:=true
        saved:=context;context.allocator={runtime_failure_allocator,&allocation};context.temp_allocator=context.allocator;allocation.remaining=0
        for _ in 0..<5 {
            start:=time.tick_now()
            for _ in 0..<REPEATS {
                stable &&=program_bench_step(&state,&playback,content,animation,&events,&app,&blends,&graphs)
                sink+=state.local[63].position.x+state.local[63].rotation.y
            }
            best=min(best,time.tick_since(start))
        }
        context=saved;allocation.remaining=100000
        testing.expect(t,stable && playback.pose.failed==0 && allocation.calls==allocations)
        results[case_index]=f64(time.duration_nanoseconds(best))/REPEATS
        log.infof("animation program, 64 bones / position+rotation, %s: %.2f ns/pose (check %v)",labels[case_index],results[case_index],sink)
    }
    log.infof("animation program ratios vs direct: graph-one %.3fx, graph-blend %.3fx, graph-layer %.3fx",results[1]/results[0],results[2]/results[0],results[3]/results[0])
    for actor_count in ([2]int{1,128}) {
        for workload in 0..<2 {
            states:=make([]Playing,actor_count)
            playback:Playback;events:Animation_Events
            if !testing.expect(t,lib.pose_init(&playback.pose,256)) {delete(states);return}
            allocation.remaining=100000
            saved:=context;context.allocator={runtime_failure_allocator,&allocation};context.temp_allocator=context.allocator
            animation:=ANIMATION_DEFAULT
            animation.asset=graph_clip_id if workload==0 else blend_id
            if workload==1 {animation_parameter(&animation,"blend",.5)}
            valid:=true
            for &state,i in states {
                state=program_bench_state();state.entity=core.Entity(i+1)
                for _ in 0..<128 {valid &&=program_bench_step(&state,&playback,content,animation,&events,&app,&blends,&graphs)}
            }
            context=saved
            output:=states[0].program.output
            resident:=size_of(Program_Output)+cap(output.groups)*size_of(Program_Group)+cap(output.instructions)*size_of(Program_Instruction)
            allocations:=allocation.calls;allocation.remaining=0
            best:=max(time.Duration);check:f32
            context.allocator={runtime_failure_allocator,&allocation};context.temp_allocator=context.allocator
            for _ in 0..<5 {
                start:=time.tick_now()
                for frame in 0..<256 {
                    if workload==1 {animation_parameter(&animation,"blend",f32(frame%61)/60)}
                    for &state in states {
                        valid &&=program_bench_step(&state,&playback,content,animation,&events,&app,&blends,&graphs)
                        check+=state.local[63].position.x+state.local[63].rotation.y
                    }
                }
                best=min(best,time.tick_since(start))
            }
            context=saved;allocation.remaining=100000
            labels:=[2]string{"cached one clip","changing blend parameter"}
            pose_hash:=program_bench_pose_hash(states[0].local[:])
            for state in states {testing.expect_value(t,program_bench_pose_hash(state.local[:]),pose_hash)}
            testing.expect(t,valid && finite(check) && playback.pose.failed==0 && allocation.calls==allocations)
            log.infof("animation program multiactor, 64 bones, %s, actors %d: %.2f ns/actor/tick, output %d B/actor, Program_Output %d B, pose %x, check %.6f",labels[workload],actor_count,f64(time.duration_nanoseconds(best))/f64(256*actor_count),resident,size_of(Program_Output),pose_hash,check)
            for &state in states {playing_free(&state)}
            delete(states);delete(events.items);playback_free(&playback)
        }
    }
    }
}
