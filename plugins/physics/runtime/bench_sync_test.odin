package physics

import "core:fmt"
import "core:slice"
import "core:testing"
import "core:time"
import "mirai:core"

PHYSICS_BENCH :: #config(PHYSICS_BENCH,false)

@(private="file")
Bench_Write :: enum {Nothing,Free_Transform,Parent_Of_Colliders}

// 2,025 dynamic boxes asleep on a floor and 2,025 static boxes, while another
// function writes nothing, one Transform without a body, or the parent of 64
// colliders: what physics_step costs per tick, the settle of the rows apart.
// whole: every sync goes through every body, as without the sealed rows.
@(private="file")
bench_sync_run :: proc(t:^testing.T,write:Bench_Write,whole:bool) -> (mean,median:f64,teleports:u64) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.whole=whole
    f.settings={bodies=4200,shapes=4200,contacts=8192,characters=2}
    f.gravity={0,-9.81,0}
    physics_test_box(&f,{0,-0.5,0},{100,0.5,100},RIGID_BODY_STATIC)
    for i in 0..<45*45 {
        x,z:=f32(i%45)*2-45,f32(i/45)*2-45
        physics_test_box(&f,{x,0.5,z},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
        physics_test_box(&f,{x+1,0.25,z+200},{0.25,0.25,0.25})
    }
    free_entity:=core.create(&f.entities)
    core.add(&f.transforms,free_entity,core.Transform{{0,10,0},1,{1,1,1}})
    holder:=core.create(&f.entities)
    core.add(&f.transforms,holder,core.Transform{{0,0,-200},1,{1,1,1}})
    for i in 0..<64 {
        child:=physics_test_box(&f,{f32(i%8)*2,0.25,f32(i/8)*2},{0.25,0.25,0.25})
        core.add(&f.parents,child,core.Parent{holder,0})
    }
    for _ in 0..<180 {physics_test_step(&f)}
    MEASURED :: 240
    times:[MEASURED]f64
    before:=f.state.stats.teleports
    for tick in 0..<MEASURED {
        switch write {
        case .Nothing:
        case .Free_Transform:      core.edit(&f.transforms,free_entity).position.x=f32(tick)*0.01
        case .Parent_Of_Colliders: core.edit(&f.transforms,holder).position.x=f32(tick)*0.01
        }
        physics_test_settle(&f)
        mark:=time.tick_now()
        physics_test_run(&f,1.0/60)
        times[tick]=time.duration_milliseconds(time.tick_since(mark))
        physics_test_settle(&f)
        mean+=times[tick]
    }
    slice.sort(times[:])
    return mean/MEASURED,times[MEASURED/2],f.state.stats.teleports-before
}

// Pairs of runs that alternate both syncs.
@(test)
bench_sync :: proc(t:^testing.T) {
    if !PHYSICS_BENCH {return}
    for write in Bench_Write {
        for pair in 0..<3 {
            for whole in ([2]bool{true,false}) {
                mean,median,teleports:=bench_sync_run(t,write,whole)
                fmt.printfln("BENCH physics_step, 4,115 bodies, %v written, %s sync, pair %v: %.4f ms mean, %.4f median, %v teleports",write,whole?"whole":"sealed",pair,mean,median,teleports)
            }
        }
    }
}
