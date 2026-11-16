package mirai_physics

import "core:fmt"
import "core:testing"
import "core:time"

// 200 hulls of 12 sides lying on their side, floating in the sea, against the same hulls lying on a floor
// with no fluid. Nothing sleeps, so both pay for every body in every step.
@(private="file")
bench_fluid_run :: proc(water:bool,pool:^Test_Pool,settle,measure:int) -> (result:Bench_Result,stats:Stats) {
    w:=new(World)
    defer free(w)
    if !test_world_threaded(w,pool,1024,8192,16) {return}
    defer world_destroy(w)
    w.desc.sleep_disabled=true
    if water {
        fluid_create(w,{shape=.Plane,density=1000})
    } else {
        test_static_box(w,{30,1,30},{0,-1.25,0})
    }
    hull,_:=test_prism(w,12,0.4,1)
    lying:=q_axis_angle({0,0,1},0.5*PI)
    for i in 0..<200 {
        desc:=BODY_DESC_DEFAULT
        desc.position,desc.rotation={f32(i%10)*2.4-12,0.2,f32(i/10)*1.0-10},lying
        body:=body_create(w,desc)
        shape:=SHAPE_DESC_DEFAULT
        shape.geometry=hull
        shape.density=400
        shape_create(w,body,shape)
    }
    for _ in 0..<settle {world_step(w,1.0/60)}
    times:=new(Bench_Times)
    defer free(times)
    for _ in 0..<measure {
        lap:=time.tick_now()
        world_step(w,1.0/60)
        bench_record(times,time.duration_milliseconds(time.tick_since(lap)),world_profile(w))
    }
    return bench_result(times),world_stats(w)
}

@(test)
bench_fluids :: proc(t:^testing.T) {
    if !PHYSICS_BENCH {return}
    pool:Test_Pool
    test_pool_init(&pool,4)
    defer test_pool_destroy(&pool)
    for water in ([2]bool{false,true}) {
        single,stats:=bench_fluid_run(water,nil,300,BENCH_STEPS)
        multi,_:=bench_fluid_run(water,&pool,300,BENCH_STEPS)
        fmt.printfln("BENCH 200 hulls %s: 1 thread median %.3f ms (best %.3f, mean %.3f, solve %.3f), 4 threads median %.3f (best %.3f, mean %.3f, solve %.3f); awake %v contacts %v",
            water?"floating":"on a floor",single.median,single.best,single.mean,single.stages[3],multi.median,multi.best,multi.mean,multi.stages[3],stats.awake_bodies,stats.active_contacts)
    }
}
