package multiplayer

import "core:fmt"
import "core:testing"
import "core:time"
import "mirai:core"
import "mirai:host"
import wire "mirai:net"

@(private) NET_PUBLISH_BENCH :: #config(NET_PUBLISH_BENCH,false)

@(private)
bench_publish_run :: proc(t:^testing.T,changed:bool,hz:f32) {
    OBJECTS :: 2000
    SAMPLES :: 600
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
    first:=core.NONE
    for i in 0..<OBJECTS {
        entity:=core.create(&world.entities)
        if i==0 {first=entity}
        core.add(&world.transforms,entity,core.TRANSFORM_IDENTITY)
        core.add(&world.values,entity,{force=1,target=first})
        core.add(&world.objects,entity,net_test_replicate(audience=.Always,update_hz=hz))
    }
    core.settle(&info,&world,nil)
    ref:=core.world_ref(&world,&info)
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=3,endpoints=2,packets=64})) {return}
    defer wire.sim_network_destroy(&network)
    app:=host.App{allocator=context.allocator,tick_dt=1.0/60}
    session:Net_Session
    session.allocator,session.info=context.allocator,&info
    session.desc=settings_resolve({max_objects=2048},app.tick_dt)
    defer session_destroy(&session)
    problems:core.Problems
    session.problems=&problems
    if !testing.expect(t,protocol_build(&session,ref)) {return}
    desc:=wire.Host_Desc{
        mode=.Server,protocol=&session.protocol,transport=wire.sim_endpoint_transport(&network,0),
        protocol_id=99,seed=1,tick_rate=60,replication=session.desc.replication,allocator=context.allocator,
        frame_ops=16384,frame_bytes=1<<20,
    }
    desc.replication.max_objects=2048
    if !testing.expect(t,wire.host_init(&session.host,desc)==.None) {return}
    session.host_ready,session.mode=true,.Server
    if !testing.expect(t,server_init(&session,context.allocator)) {return}
    outbox:Net_Outbox
    defer core.value_free(&outbox,type_info_of(Net_Outbox))
    samples:[SAMPLES]f64
    mean:f64
    for tick in 1..=SAMPLES+96 {
        if changed {
            for row in 0..<len(world.values.values) {core.edit_at(&world.values,row).force=f32(tick)}
        }
        started:=time.tick_now()
        server_publish(&session,ref,&outbox,u32(tick))
        elapsed:=time.duration_seconds(time.tick_diff(started,time.tick_now()))*1000
        core.settle(&info,&world,nil)
        wire.host_update(&session.host,f64(tick)/60)
        if tick>96 {samples[tick-97]=elapsed;mean+=elapsed}
    }
    if !testing.expect_value(t,session.stats.objects,OBJECTS) {return}
    if !testing.expect_value(t,problems.count,0) {return}
    for i in 1..<len(samples) {
        value:=samples[i]
        at:=i
        for at>0 && samples[at-1]>value {samples[at]=samples[at-1];at-=1}
        samples[at]=value
    }
    fmt.printfln("NET_PUBLISH_BENCH scene=%s objects=%d update_hz=%.0f median_ms=%.6f best_ms=%.6f mean_ms=%.6f",
        changed?"changed":"stable",OBJECTS,hz,(samples[SAMPLES/2-1]+samples[SAMPLES/2])*.5,samples[0],mean/SAMPLES)
}

@(test)
bench_publish :: proc(t:^testing.T) {
    if !NET_PUBLISH_BENCH {return}
    for changed in ([2]bool{false,true}) {
        for hz in ([2]f32{60,10}) {bench_publish_run(t,changed,hz)}
    }
}
