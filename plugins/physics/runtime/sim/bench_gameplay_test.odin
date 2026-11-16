package mirai_physics

import "core:testing"
import "core:time"
import "core:fmt"
import cmath "core:math"

@(private)
bench_world :: proc(w:^World,pool:^Test_Pool) -> bool {
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity=1024,1024,16384
    desc.hull_capacity,desc.character_capacity=512,64
    desc.sleep_disabled=true
    if pool!=nil {
        desc.worker_count=pool.workers
        desc.parallel_for=test_pool_parallel_for
        desc.parallel_user=pool
    }
    return world_init(w,desc)
}

// 64 characters walking in circles over rolling ground made of 2 x 4,096 triangles.
@(private)
bench_characters_run :: proc(pool:^Test_Pool,settle,measure:int) -> (ms,best:f64) {
    w:=new(World)
    defer free(w)
    if !bench_world(w,pool) {return}
    defer world_destroy(w)
    mesh,_:=test_grid_mesh(w,64,64,proc(x,z:f32)->f32 {return 0.6*cmath.sin(0.4*x)*cmath.cos(0.35*z)})
    test_static_shape(w,mesh)
    chs:[64]Character_Handle
    for &ch,i in chs {ch=character_create(w,CHARACTER_DESC_DEFAULT,{f32(i%8)*5-17.5,1.5,f32(i/8)*5-17.5})}
    best=max(f64)
    start:time.Tick
    for step in 0..<settle+measure {
        if step==settle {start=time.tick_now()}
        for ch,i in chs {
            angle:=0.02*f32(step)+f32(i)
            character_set_move(w,ch,test_move(w,ch,{cmath.cos(angle),0,cmath.sin(angle)}))
        }
        mark:=time.tick_now()
        world_step(w,1.0/60)
        if step>=settle {best=min(best,time.duration_milliseconds(time.tick_since(mark)))}
    }
    grounded:=0
    for ch in chs {
        if .Standing in character_state(w,ch).ground {grounded+=1}
    }
    fmt.printfln("BENCH   characters on %v: %v of 64 on the ground, contacts %v",pool==nil?1:pool.workers,grounded,world_stats(w).active_contacts)
    return time.duration_milliseconds(time.tick_since(start))/f64(measure),best
}

@(test)
bench_characters :: proc(t:^testing.T) {
    if !PHYSICS_BENCH {return}
    pool:Test_Pool
    test_pool_init(&pool,4)
    defer test_pool_destroy(&pool)
    single,single_best:=bench_characters_run(nil,60,240)
    multi,multi_best:=bench_characters_run(&pool,60,240)
    fmt.printfln("BENCH 64 characters on a mesh: %.3f ms/step on 1 thread (best %.3f), %.3f on 4 threads (best %.3f)",single,single_best,multi,multi_best)
}
