package mirai_physics

import "core:testing"
import "core:thread"
import "core:sync"
import "core:time"
import "core:fmt"
import "core:slice"
import cmath "core:math"

// Minimal fork-join pool behind the World_Desc.parallel_for interface, for tests and measurements.
// Workers spin for a moment between jobs before they sleep, as a job system does while a step runs.
@(private)
Test_Pool :: struct {
    threads:[MAX_WORKERS]^thread.Thread,
    infos:[MAX_WORKERS]Test_Pool_Worker,
    workers:int,
    generation:sync.Futex,
    running:int,
    quit:bool,
    next:int,
    count,grain:int,
    data:rawptr,
    body:proc(data:rawptr,first,last,worker:int),
}

@(private) Test_Pool_Worker :: struct {pool:^Test_Pool,index:int}

@(private)
test_pool_run :: proc(pool:^Test_Pool,worker:int) {
    for {
        chunk:=sync.atomic_add(&pool.next,1)
        first:=chunk*pool.grain
        if first>=pool.count {return}
        pool.body(pool.data,first,min(first+pool.grain,pool.count),worker)
    }
}

@(private)
test_pool_init :: proc(pool:^Test_Pool,workers:int) {
    pool.workers=workers
    for i in 1..<workers {
        pool.infos[i]={pool,i}
        pool.threads[i]=thread.create_and_start_with_data(&pool.infos[i],proc(data:rawptr) {
            info:=(^Test_Pool_Worker)(data)
            pool:=info.pool
            seen:=u32(0)
            for {
                spins:=0
                for u32(sync.atomic_load(&pool.generation))==seen {
                    if spins<20000 {
                        spins+=1
                        sync.cpu_relax()
                    } else {
                        sync.futex_wait(&pool.generation,seen)
                    }
                }
                seen+=1
                if pool.quit {break}
                test_pool_run(pool,info.index)
                sync.atomic_sub(&pool.running,1)
            }
        })
    }
}

@(private)
test_pool_wake :: proc(pool:^Test_Pool) {
    sync.atomic_store(&pool.running,pool.workers-1)
    sync.atomic_add(&pool.generation,sync.Futex(1))
    sync.futex_broadcast(&pool.generation)
}

@(private)
test_pool_destroy :: proc(pool:^Test_Pool) {
    pool.quit=true
    test_pool_wake(pool)
    for i in 1..<pool.workers {
        thread.join(pool.threads[i])
        thread.destroy(pool.threads[i])
    }
}

// Every worker takes part in every job, so a job never overlaps the next one.
@(private)
test_pool_parallel_for :: proc(count,grain:int,data:rawptr,body:proc(data:rawptr,first,last,worker:int)) {
    pool:=(^Test_Pool)(context.user_ptr)
    pool.count,pool.grain,pool.data,pool.body=count,max(grain,1),data,body
    sync.atomic_store(&pool.next,0)
    test_pool_wake(pool)
    test_pool_run(pool,0)
    for sync.atomic_load(&pool.running)>0 {sync.cpu_relax()}
}

@(private)
test_world_threaded :: proc(w:^World,pool:^Test_Pool,bodies,contacts,joints:int) -> bool {
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=bodies,bodies,contacts,joints
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=8,4,2,256
    if pool!=nil {
        desc.worker_count=pool.workers
        desc.parallel_for=test_pool_parallel_for
        desc.parallel_user=pool
    }
    return world_init(w,desc)
}

@(test)
worker_threads_give_the_same_result_as_one_thread :: proc(t:^testing.T) {
    pool:Test_Pool
    test_pool_init(&pool,4)
    defer test_pool_destroy(&pool)
    a,b:World
    testing.expect(t,test_world_threaded(&a,nil,512,4096,64))
    testing.expect(t,test_world_threaded(&b,&pool,512,4096,64))
    defer world_destroy(&a)
    defer world_destroy(&b)
    for w in ([2]^World{&a,&b}) {
        test_scene(w)
        for i in 0..<200 {test_body(w,Box{{0.3,0.3,0.3}},{f32(i%10)*0.7-3,5+f32(i/10)*0.7,f32(i%7)*0.7+3})}
        for i in 0..<60 {test_body(w,Sphere{0.3},{f32(i%6)*0.7-2,4+f32(i/6)*0.7,-4})}
    }
    for step in 0..<150 {
        test_scene_edit(&a,step)
        test_scene_edit(&b,step)
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        if world_hash(&a)!=world_hash(&b) {
            testing.expectf(t,false,"threads changed the result at step %v",step)
            return
        }
    }
    testing.expect(t,world_stats(&b).active_contacts>200)
}

PHYSICS_BENCH :: #config(PHYSICS_BENCH,false)

@(private)
bench_pyramid :: proc(w:^World,base:int) {
    test_ground(w,{200,1,50})
    for row in 0..<base {
        for column in 0..<base-row {
            test_body(w,Box{{0.5,0.5,0.5}},{(f32(column)+0.5*f32(row)-0.5*f32(base))*1.02,0.5+f32(row),0})
        }
    }
}

@(private)
bench_spheres :: proc(w:^World,count:int) {
    mesh,_:=test_grid_mesh(w,96,120,proc(x,z:f32)->f32 {return 1.5*cmath.sin(0.15*x)*cmath.cos(0.12*z)+0.02*(x*x+z*z)})
    test_static_shape(w,mesh)
    side:=int(cmath.ceil(cmath.pow(f64(count),1.0/3)))
    for i in 0..<count {
        x,y,z:=i%side,i/side%side,i/(side*side)
        test_body(w,Sphere{0.25},{(f32(x)-0.5*f32(side))*0.9,12+f32(y)*0.9,(f32(z)-0.5*f32(side))*0.9})
    }
}

@(private)
bench_chains :: proc(w:^World,chains,links:int) {
    for chain in 0..<chains {
        origin:=Vec3{f32(chain%10)*1.5,30,f32(chain/10)*1.5}
        previous:=body_create(w,{type=.Static,position=origin})
        for link in 0..<links {
            body:=test_body(w,Capsule{0.08,0.17},origin+{0.25+f32(link)*0.5,0,0})
            body_set_transform(w,body,origin+{0.25+f32(link)*0.5,0,0},q_axis_angle({0,0,1},cmath.PI/2))
            desc:=test_joint(w,.Spherical,previous,body,origin+{f32(link)*0.5,0,0})
            joint_create(w,desc)
            previous=body
        }
    }
}

@(private) Bench_Scene :: enum {Pyramid_500,Pyramid_2000,Spheres_5000,Chains_2000,Ragdolls_100,Sleep_Piles}

// Step times of a measurement, with the stages of each step. The machine is shared: the median says what
// a step costs and the mean how much the neighbors took.
@(private) BENCH_STEPS :: 240
@(private) Bench_Times :: struct {count:int,step:[BENCH_STEPS]f64,stages:[6][BENCH_STEPS]f64}
@(private) Bench_Result :: struct {median,best,mean:f64,stages:[6]f64}

@(private)
bench_record :: proc(times:^Bench_Times,ms:f64,p:Profile) {
    if times.count>=BENCH_STEPS {return}
    times.step[times.count]=ms
    for value,i in ([6]f32{p.pairs,p.narrow_phase,p.prepare,p.solve,p.finalize,p.sleep}) {times.stages[i][times.count]=f64(value)}
    times.count+=1
}

@(private)
bench_result :: proc(times:^Bench_Times) -> (r:Bench_Result) {
    n:=times.count
    if n==0 {return}
    for value in times.step[:n] {r.mean+=value/f64(n)}
    slice.sort(times.step[:n])
    r.median,r.best=times.step[n/2],times.step[0]
    for &stage,i in times.stages {
        slice.sort(stage[:n])
        r.stages[i]=stage[n/2]
    }
    return
}

@(private)
bench_run :: proc(scene:Bench_Scene,pool:^Test_Pool,settle,measure:int) -> (result:Bench_Result,stats:Stats) {
    w:=new(World)
    defer free(w)
    if !test_world_threaded(w,pool,8192,65536,4096) {return}
    defer world_destroy(w)
    w.desc.sleep_disabled=scene!=.Sleep_Piles
    switch scene {
    case .Pyramid_500: bench_pyramid(w,31)
    case .Pyramid_2000: bench_pyramid(w,63)
    case .Spheres_5000: bench_spheres(w,5000)
    case .Chains_2000: bench_chains(w,100,20)
    case .Ragdolls_100: bench_ragdolls(w,100)
    case .Sleep_Piles: bench_sleep_piles(w)
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
bench_steps :: proc(t:^testing.T) {
    if !PHYSICS_BENCH {return}
    pool:Test_Pool
    test_pool_init(&pool,4)
    defer test_pool_destroy(&pool)
    for scene in Bench_Scene {
        settle:=scene==.Spheres_5000?120:60
        single,stats:=bench_run(scene,nil,settle,BENCH_STEPS)
        multi,_:=bench_run(scene,&pool,settle,BENCH_STEPS)
        fmt.printfln("BENCH %v: 1 thread median %.3f ms (best %.3f, mean %.3f), 4 threads median %.3f (best %.3f, mean %.3f); bodies %v awake %v islands %v contacts %v (carried %v) constraints %v joints %v colors %v overflow %v",
            scene,single.median,single.best,single.mean,multi.median,multi.best,multi.mean,stats.bodies,stats.awake_bodies,stats.islands,stats.active_contacts,stats.carried_contacts,stats.constraints,stats.joints,stats.colors,stats.overflow_constraints)
        fmt.printfln("BENCH   median stages on 1 thread: pairs %.3f narrow %.3f prepare %.3f solve %.3f finalize %.3f sleep %.3f; on 4: narrow %.3f prepare %.3f solve %.3f",
            single.stages[0],single.stages[1],single.stages[2],single.stages[3],single.stages[4],single.stages[5],multi.stages[1],multi.stages[2],multi.stages[3])
    }
}

@(test)
bench_snapshot :: proc(t:^testing.T) {
    if !PHYSICS_BENCH {return}
    w,kept:=new(World),new(World)
    defer free(w)
    defer free(kept)
    testing.expect(t,test_world_threaded(w,nil,8192,65536,4096))
    defer world_destroy(w)
    defer world_destroy(kept)
    w.desc.sleep_disabled=true
    bench_pyramid(w,63)
    for _ in 0..<60 {world_step(w,1.0/60)}
    testing.expect(t,world_kept_init(kept,w,context.allocator))
    ROUNDS :: 200
    size:int
    whole,ticked,back:time.Duration
    for _ in 0..<ROUNDS {
        kept.lineage=0
        start:=time.tick_now()
        size,_=world_state_copy(kept,w)
        whole+=time.tick_since(start)
        world_step(w,1.0/60)
        start=time.tick_now()
        world_state_copy(kept,w)
        ticked+=time.tick_since(start)
        world_step(w,1.0/60)
        start=time.tick_now()
        world_state_copy(w,kept)
        back+=time.tick_since(start)
    }
    start:=time.tick_now()
    hash:u64
    for _ in 0..<ROUNDS {hash~=world_hash(w)}
    hashing:=time.duration_milliseconds(time.tick_since(start))/ROUNDS
    stats:=world_stats(w)
    fmt.printfln("BENCH state copy of %v bodies, %v contacts, all awake: whole %v bytes %.4f ms, after a step %.4f ms, back %.4f ms, hash %.4f ms",
        stats.bodies,stats.contacts,size,time.duration_milliseconds(whole)/ROUNDS,time.duration_milliseconds(ticked)/ROUNDS,time.duration_milliseconds(back)/ROUNDS,hashing)
    // 1000 bodies asleep and 10 falling: what a predicted tick copies.
    sleepers,copy:World
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=1100,1100,4096,0
    testing.expect(t,world_init(&sleepers,desc))
    defer world_destroy(&sleepers)
    defer world_destroy(&copy)
    full,moving,still:=test_sleepers(&sleepers,&copy)
    fmt.printfln("BENCH state copy of 1000 bodies asleep: whole %v bytes, a tick with 10 falling %v bytes, a tick with all at rest %v bytes",full,moving,still)
}
