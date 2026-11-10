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

// What a tick does for the pose of one rig: the clip of its component, or the program output is
// when given (the clip the locomotion picked), then the slots of its stack.
@(private)
program_bench_step :: proc(state:^Playing,playback:^Playback,content:^host.Content_Animation,animation:Animation,events:^Animation_Events,output:^Program_Output) -> bool {
    clear(&events.items)
    copy(state.local[:],state.rest[:])
    if output!=nil {
        if !program_buffers(state,content) || !program_players(state,output,content,animation,events,playback,1.0/60,-1,nil) || !program_pose(playback,state,content,animation,output) {return false}
        layers_advance(playback,state,content,animation,events,1.0/60,nil)
        pose_layers(playback,state,&content.lib,animation)
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
    animation_id:=base.Asset_Id{100,1}
    if !testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/source.anim",directory),&types,{id=animation_id,clips=clips[:]}),asset.Error.None) {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory,capacity=8})) {return};defer host.assets_destroy(&assets)
    allocation:=Runtime_Allocation_Failure{owner=context.allocator,remaining=100000}
    app:=host.App{assets=&assets,allocator={runtime_failure_allocator,&allocation}};defer host.app_content_destroy(&app)
    content:=host.content_animation(&app,animation_id);if !testing.expect(t,content!=nil) {return}
    // All cases sample identical clips, so their resulting poses are equal.
    Case :: enum {Direct,Program,Layer,Branch}
    labels:=[Case]string{.Direct="direct clip",.Program="program one clip",.Layer="clip + layer of a second clip by weight",.Branch="clip + layer over a branch"}
    results:[Case]f64
    sink:f32
    setup :: proc(state:^Playing,kind:Case) {
        #partial switch kind {
        case .Layer: test_layer(state,1,"second",weight=.5)
        case .Branch: test_layer(state,1,"second",over="bone32")
        }
    }
    built:=program_test_output(program_test_leaf("first",0,1,true))
    for kind in Case {
        state:=program_bench_state();defer playing_free(&state)
        playback:Playback;defer playback_free(&playback)
        if !testing.expect(t,tracks_bind(&playback,&state,content)) {return}
        events:Animation_Events;defer delete(events.items)
        animation:=ANIMATION_DEFAULT;animation.asset=animation_id
        output:=&built if kind==.Program else nil
        setup(&state,kind)
        for _ in 0..<4 {if !testing.expect(t,program_bench_step(&state,&playback,content,animation,&events,output)) {return}}
        allocations:=allocation.calls
        best:=max(time.Duration)
        stable:=true
        saved:=context;context.allocator={runtime_failure_allocator,&allocation};context.temp_allocator=context.allocator;allocation.remaining=0
        for _ in 0..<5 {
            start:=time.tick_now()
            for _ in 0..<REPEATS {
                stable &&=program_bench_step(&state,&playback,content,animation,&events,output)
                sink+=state.local[63].position.x+state.local[63].rotation.y
            }
            best=min(best,time.tick_since(start))
        }
        context=saved;allocation.remaining=100000
        testing.expect(t,stable && allocation.calls==allocations)
        results[kind]=f64(time.duration_nanoseconds(best))/REPEATS
        log.infof("animation pose, 64 bones / position+rotation, %s: %.2f ns/pose (check %v)",labels[kind],results[kind],sink)
    }
    log.infof("animation pose ratios vs direct: program %.3fx, layer %.3fx, branch layer %.3fx",results[.Program]/results[.Direct],results[.Layer]/results[.Direct],results[.Branch]/results[.Direct])
    for actor_count in ([2]int{1,128}) {
        for workload in 0..<2 {
            states:=make([]Playing,actor_count)
            playback:Playback;events:Animation_Events
            allocation.remaining=100000
            saved:=context;context.allocator={runtime_failure_allocator,&allocation};context.temp_allocator=context.allocator
            animation:=ANIMATION_DEFAULT;animation.asset=animation_id
            output:=&built if workload==0 else nil
            valid:=true
            for &state,i in states {
                state=program_bench_state();state.entity=core.Entity(i+1)
                valid &&=tracks_bind(&playback,&state,content)
                if workload==1 {test_layer(&state,1,"second",weight=.5)}
                for _ in 0..<128 {valid &&=program_bench_step(&state,&playback,content,animation,&events,output)}
            }
            context=saved
            allocations:=allocation.calls;allocation.remaining=0
            best:=max(time.Duration);check:f32
            context.allocator={runtime_failure_allocator,&allocation};context.temp_allocator=context.allocator
            for _ in 0..<5 {
                start:=time.tick_now()
                for frame in 0..<256 {
                    for &state in states {
                        if workload==1 {test_layer_weight(&state,1,f32(frame%61)/60)}
                        valid &&=program_bench_step(&state,&playback,content,animation,&events,output)
                        check+=state.local[63].position.x+state.local[63].rotation.y
                    }
                }
                best=min(best,time.tick_since(start))
            }
            context=saved;allocation.remaining=100000
            labels:=[2]string{"program one clip","clip + layer whose weight changes"}
            pose_hash:=program_bench_pose_hash(states[0].local[:])
            for state in states {testing.expect_value(t,program_bench_pose_hash(state.local[:]),pose_hash)}
            testing.expect(t,valid && finite(check) && allocation.calls==allocations)
            log.infof("animation pose multiactor, 64 bones, %s, actors %d: %.2f ns/actor/tick, Playing %d B, pose %x, check %.6f",labels[workload],actor_count,f64(time.duration_nanoseconds(best))/f64(256*actor_count),size_of(Playing),pose_hash,check)
            for &state in states {playing_free(&state)}
            delete(states);delete(events.items);playback_free(&playback)
        }
    }
    }
}
