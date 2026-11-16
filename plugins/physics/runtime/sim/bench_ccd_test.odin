package mirai_physics

import "core:testing"
import "core:time"
import "core:fmt"

// Asleep_3969: one bullet crossing the air above a grid of 63x63 sleeping boxes, which it never touches.
@(private) CCD_Bench_Scene :: enum {Discrete_512,Static_128,Dynamic_128,Asleep_3969}

@(private)
bench_ccd_run :: proc(t:^testing.T,scene:CCD_Bench_Scene,pool:^Test_Pool) -> (result:Bench_Result,events:int) {
    w:=new(World)
    defer free(w)
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity=1024,1024,4096
    if scene==.Asleep_3969 {desc.body_capacity,desc.shape_capacity=4096,4096}
    desc.event_capacity=512
    desc.gravity={}
    desc.sleep_disabled=true
    if pool!=nil {
        desc.worker_count=pool.workers
        desc.parallel_for=test_pool_parallel_for
        desc.parallel_user=pool
    }
    if !testing.expect(t,world_init(w,desc)) {return}
    defer world_destroy(w)
    count:=scene==.Discrete_512?512:scene==.Asleep_3969?1:128
    bodies,targets:[512]Body_Handle
    positions:[512]Vec3
    for i in 0..<count {
        positions[i]={-1,f32(i%16)*1.5,f32(i/16)*1.5}
        body_desc:=BODY_DESC_DEFAULT
        body_desc.position=positions[i]
        body_desc.bullet=scene!=.Discrete_512
        body_desc.linear_damping,body_desc.angular_damping=0,0
        bodies[i]=body_create(w,body_desc)
        shape:=SHAPE_DESC_DEFAULT
        shape.geometry=Sphere{0.15}
        shape.friction,shape.restitution=0.5,0.3
        shape_create(w,bodies[i],shape)
        if scene==.Asleep_3969 {
            positions[i]={-48,3,0}
            for k in 0..<63*63 {
                sleeper:=BODY_DESC_DEFAULT
                sleeper.position={f32(k%63)*1.5-47,0,f32(k/63)*1.5-47}
                sleeper.asleep=true
                box:=body_create(w,sleeper)
                piece:=SHAPE_DESC_DEFAULT
                piece.geometry=Box{{0.5,0.5,0.5}}
                shape_create(w,box,piece)
            }
            body_set_transform(w,bodies[i],positions[i],QUAT_IDENTITY)
        } else if scene==.Static_128 {
            targets[i]=test_body(w,Box{{0.025,0.3,0.3}},positions[i]+{1,0,0},.Static,0.5,0.3)
        } else if scene==.Dynamic_128 {
            body_desc.position=positions[i]+{1.6,0,0}
            body_desc.bullet=false
            targets[i]=body_create(w,body_desc)
            shape_create(w,targets[i],shape)
        }
    }
    times:=new(Bench_Times)
    defer free(times)
    for step in 0..<BENCH_STEPS+32 {
        for body,i in bodies[:count] {
            body_set_transform(w,body,positions[i],QUAT_IDENTITY)
            body_set_velocity(w,body,{180,0,0},{})
            if scene==.Dynamic_128 {
                body_set_transform(w,targets[i],positions[i]+{1.6,0,0},QUAT_IDENTITY)
                body_set_velocity(w,targets[i],{-30,0,0},{})
            }
        }
        lap:=time.tick_now()
        world_step(w,1.0/60)
        elapsed:=time.duration_milliseconds(time.tick_since(lap))
        if step>=32 {
            bench_record(times,elapsed,world_profile(w))
            events+=len(world_events(w).contact_begin)
        }
    }
    testing.expect_value(t,world_stats(w).body_capacity_exhausted,0)
    testing.expect_value(t,world_stats(w).shape_capacity_exhausted,0)
    testing.expect_value(t,world_stats(w).contact_capacity_exhausted,0)
    return bench_result(times),events
}

@(test)
bench_ccd :: proc(t:^testing.T) {
    if !PHYSICS_BENCH {return}
    pool:Test_Pool
    test_pool_init(&pool,4)
    defer test_pool_destroy(&pool)
    for scene in CCD_Bench_Scene {
        for workers in ([2]int{1,4}) {
            result,events:=bench_ccd_run(t,scene,workers==1?nil:&pool)
            fmt.printfln("CCD_BENCH scene=%v workers=%v median_ms=%.6f best_ms=%.6f mean_ms=%.6f begin_events=%v",
                scene,workers,result.median,result.best,result.mean,events)
        }
    }
}
