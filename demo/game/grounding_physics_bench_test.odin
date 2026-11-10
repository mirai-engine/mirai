package game

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:testing"
import "core:time"
import "mirai:core"
import anim "plugins:animation/runtime"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

when #config(MIRAI_BENCH,false) {
@(private="file")
grounding_bench_fixture :: proc(f:^Grounding_Fixture,t:^testing.T,bones,legs:int,mode:anim.Grounding_Mode) -> bool {
    grounding_fixture_init(f,t,.12 if legs==2 else f32(0))
    if legs==8 {grounding_spider_step_fixture(f,t);f.state.local[0].position={-.8,-.05,0}}
    count:=len(f.state.parents)
    parents:[26]i32;targets:[26]u64;poses:[26]mm.Transform
    order,inverse:[26]int
    copy(parents[:],f.state.parents[:]);copy(targets[:],f.state.targets[:]);copy(poses[:],f.state.local[:])
    order[0],order[1]=0,1
    for leg in 0..<legs {for joint in 0..<3 {order[2+joint*legs+leg]=2+leg*3+joint}}
    for old,i in order[:count] {inverse[old]=i}
    for old,i in order[:count] {
        parent:=parents[old]
        f.state.parents[i]=i32(inverse[parent]) if parent>=0 else -1
        f.state.targets[i]=targets[old]
        f.state.rest[i],f.state.local[i]=poses[old],poses[old]
    }
    for bone in count..<bones {
        parent:=(bone-count)%count
        pose:=mm.Transform{{.013,f32(bone%3)*.009,-.007},mm.quat_axis_angle({0,1,0},f32(bone%5)*.03),{1.01,.97,1.02}}
        append(&f.state.parents,i32(parent));append(&f.state.targets,base.name_hash(fmt.tprintf("detail.%d",bone)))
        append(&f.state.rest,pose);append(&f.state.local,pose);append(&f.state.world,pose)
    }
    core.edit(&f.configs,f.rig).mode=mode
    return lib.pose_world(f.state.parents[:],f.state.local[:],f.state.world[:])
}

@(private="file")
grounding_bench_pose_hash :: proc(pose:[]mm.Transform) -> u64 {
    result:u64=0
    for transform in pose {
        for value in transform.position {result=base.hash_combine(result,u64(transmute(u32)value))}
        for value in ([4]f32{transform.rotation.x,transform.rotation.y,transform.rotation.z,transform.rotation.w}) {result=base.hash_combine(result,u64(transmute(u32)value))}
        for value in transform.scale {result=base.hash_combine(result,u64(transmute(u32)value))}
    }
    return result
}

@(test)
bench_grounding_pose_recomposition_scaling :: proc(t:^testing.T) {
    REPEATS :: 4096
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator);defer mem.tracking_allocator_destroy(&track)
    outer:=context;context.allocator=mem.tracking_allocator(&track)
    defer context=outer
    for bones in ([3]int{8,64,256}) {
        for legs in ([2]int{2,8}) {
            if bones<2+legs*3 {continue}
            for mode in ([2]anim.Grounding_Mode{.Animated,.Procedural}) {
                if legs==8 && mode==.Animated {continue}
                f:Grounding_Fixture
                if !testing.expect(t,grounding_bench_fixture(&f,t,bones,legs,mode)) {grounding_fixture_free(&f);return}
                defer grounding_fixture_free(&f)
                source_local,source_world:[256]mm.Transform
                copy(source_local[:],f.state.local[:]);copy(source_world[:],f.state.world[:])
                inputs:=grounding_fixture_inputs(&f)
                for _ in 0..<32 {
                    copy(f.state.local[:],source_local[:bones]);copy(f.state.world[:],source_world[:bones])
                    if !testing.expect(t,anim.grounding_apply(&f.state,&f.cache,inputs,1.0/60)) {return}
                }
                copy(f.state.local[:],source_local[:bones]);copy(f.state.world[:],source_world[:bones])
                if !testing.expect(t,anim.grounding_apply(&f.state,&f.cache,inputs,0)) {return}
                expected_local:=grounding_bench_pose_hash(f.state.local[:])
                expected_world:=grounding_bench_pose_hash(f.state.world[:])
                allocations:=track.total_allocation_count
                best:=max(time.Duration);stable:=true;sink:f32
                saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
                for _ in 0..<5 {
                    start:=time.tick_now()
                    for _ in 0..<REPEATS {
                        copy(f.state.local[:],source_local[:bones]);copy(f.state.world[:],source_world[:bones])
                        stable &&=anim.grounding_apply(&f.state,&f.cache,inputs,0)
                        sink+=f.state.world[bones-1].position.y
                    }
                    best=min(best,time.tick_since(start))
                }
                context=saved
                testing.expect(t,stable && f.problems.count==0)
                testing.expect_value(t,track.total_allocation_count,allocations)
                testing.expect_value(t,grounding_bench_pose_hash(f.state.local[:]),expected_local)
                testing.expect_value(t,grounding_bench_pose_hash(f.state.world[:]),expected_world)
                log.infof("grounding: %d bones / %d legs / %v: %.2f ns/tick, local=%x world=%x check=%v",bones,legs,mode,f64(time.duration_nanoseconds(best))/REPEATS,expected_local,expected_world,sink)
            }
        }
    }
}
}
