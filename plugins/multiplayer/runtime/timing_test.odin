package multiplayer

import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:time"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:engine/render"
import "mirai:host"
import wire "mirai:net"
import "mirai:platform"
import "mirai:std/base"

// A server that ticks 60 times a second and a client run by the game loop of
// host, with frames as long as the test says, over the network in memory.
// The client draws what the renderer would: World_Transform between its
// previous and its present by Frame_Time.alpha.

@(private)
Timing_Shared :: struct {
    using base:Net_Test_Shared,
    now:f64,
    ran:int,               // ticks the client simulated
    propagation:core.Propagation,
    jumps:core.Jumps,
    mover:core.Entity,     // of the client alone: it moves a fixed step each tick
    bare:bool,             // its ticks have no physics
}

@(private)
Timing :: struct {
    info:core.World_Info,
    worlds:[2]Net_Test_World, // server, client
    shares:[2]Timing_Shared,
    apps:[2]host.App,
    sessions:[2]Net_Session,
    problems:[2]core.Problems,
    network:wire.Sim_Network,
    platform:^platform.Platform,
    outbox:Net_Outbox,
    server_tick:u32,
    server_time:f64,
    moved:core.Entity, // of the server: it moves speed along x each tick
    speed:f32,
    client_seconds:f64, // the game loop of the client took, in the last frame
}

@(private) TIMING_STEP :: 0.25 // m the mover of the client goes each tick

@(private)
timing_propagate :: proc(w:^Net_Test_World,sh:^Timing_Shared) {
    core.transforms_propagate(core.read(&w.transforms),core.ref(&w.hierarchy),&w.worlds,&sh.propagation,&sh.jumps,w.frame)
    core.settle(sh.info,w,nil)
}

// The input phase of net_begin on a client, with the time of the test instead of the clock of the machine.
@(private)
timing_input :: proc(world,shared,editor,application:rawptr) {
    w:=cast(^Net_Test_World)world
    sh:=cast(^Timing_Shared)shared
    app:=cast(^host.App)application
    s:=sh.session
    ref:=core.world_ref(w,sh.info)
    s.now=sh.now
    client_commands(s,ref,app.assets,app.allocator,wire.host_poll(&s.host))
    client_reconcile(s,ref,app,w.frame.dt)
    client_clock(s,ref,app)
}

@(private)
timing_fixed :: proc(world,shared,editor,application:rawptr) {
    w:=cast(^Net_Test_World)world
    sh:=cast(^Timing_Shared)shared
    sh.ran+=1
    if local:=core.edit(&w.transforms,sh.mover);local!=nil {local.position.x=f32(w.time.tick)*TIMING_STEP}
    if sh.bare {
        app:=cast(^host.App)application
        ref:=core.world_ref(w,sh.info)
        core.revisions_moved(w.storage_revisions[:])
        net_tick_head(ref,app,sh.session,&w.remote,nil,nil,sh.session.problems)
        core.settle(sh.info,w,nil)
        core.pose_targets_place(core.read(&w.replicas),&w.transforms,&w.places)
        core.settle(sh.info,w,nil)
        outbox:Net_Outbox
        net_tick_tail(ref,sh.session,&outbox,&w.made,sh.session.problems)
        core.value_free(&outbox,type_info_of(Net_Outbox))
        core.settle(sh.info,w,nil)
    } else {net_test_fixed(world,shared,editor,application)}
    timing_propagate(w,sh)
}

@(private)
timing_frame :: proc(world,shared,editor,application:rawptr) {
    w:=cast(^Net_Test_World)world
    sh:=cast(^Timing_Shared)shared
    client_frame(sh.session,core.world_ref(w,sh.info),w.frame.dt)
}

@(private)
timing_late :: proc(world,shared,editor,application:rawptr) {
    timing_propagate(cast(^Net_Test_World)world,cast(^Timing_Shared)shared)
}

@(private)
timing_init :: proc(x:^Timing,t:^testing.T,conditions:wire.Sim_Conditions,update_hz:f32=0,seed:u64=5,objects:=1) -> bool {
    x.info=net_test_info(t) or_return
    x.info.loops[.Game][.Input]=timing_input
    x.info.loops[.Game][.Fixed]=timing_fixed
    x.info.loops[.Game][.Frame]=timing_frame
    x.info.loops[.Game][.Late]=timing_late
    p,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    if !testing.expect_value(t,error,platform.Error.None) {return false}
    x.platform=p
    for &world,index in x.worlds {
        net_test_init(&world,&x.info)
        x.shares[index].info=&x.info
        x.shares[index].mover=core.NONE
        x.apps[index]={info=&x.info,platform=p,allocator=context.allocator,tick_dt=1.0/60,max_ticks=8,shared=&x.shares[index]}
    }
    if !testing.expect(t,wire.sim_network_init(&x.network,{seed=seed,endpoints=2,packets=4096})) {return false}
    wire.sim_endpoint_conditions(&x.network,0,conditions)
    wire.sim_endpoint_conditions(&x.network,1,conditions)
    for &session,index in x.sessions {
        if !testing.expect(t,net_test_session(&session,&x.worlds[index],&x.info,&x.apps[index],&x.network,index,index==0?.Server:.Client,settings={max_objects=max(objects,8),predicted_capacity=8,replication={history_seconds=0.25},resimulate_budget=600})) {return false}
        session.problems=&x.problems[index]
        x.shares[index].session=&session
    }
    testing.expect_value(t,wire.host_connect(&x.sessions[1].host,wire.address_memory(0)),wire.Error.None)
    server:=&x.worlds[0]
    x.speed=0.1
    for index in 0..<objects {
        e:=core.create(&server.entities)
        if index==0 {x.moved=e}
        core.add(&server.identities,e,core.Id{base.Entity_Id(7+index)})
        core.add(&server.transforms,e,core.Transform{position={0,0,f32(index)},rotation=1,scale={1,1,1}})
        core.add(&server.values,e,Net_Test_Value{})
        core.add(&server.objects,e,net_test_replicate(audience=.Always,update_hz=update_hz))
    }
    core.settle(&x.info,server,nil)
    client:=&x.worlds[1]
    x.shares[1].mover=core.create(&client.entities)
    core.add(&client.transforms,x.shares[1].mover,core.Transform{rotation=1,scale={1,1,1}})
    core.settle(&x.info,client,nil)
    return true
}

@(private)
timing_destroy :: proc(x:^Timing) {
    for &session in x.sessions {if session.host_ready {session_destroy(&session)}}
    for &world in x.worlds {core.world_destroy(&x.info,.World,&world)}
    for &share in x.shares {
        core.value_free(&share.propagation,type_info_of(core.Propagation))
        core.value_free(&share.jumps,type_info_of(core.Jumps))
        phys.collider_meshes_destroy(&share.colliders)
    }
    for &app in x.apps {host.app_world_scratch_free(&app);delete(app.worlds)}
    core.value_free(&x.outbox,type_info_of(Net_Outbox))
    wire.sim_network_destroy(&x.network)
    if x.platform!=nil {platform.destroy(x.platform)}
    test_info_destroy(&x.info)
}

// One frame of the client of dt seconds, and the ticks of the server that time completes.
@(private)
timing_frame_run :: proc(x:^Timing,dt:f32) {
    now:=x.shares[1].now+f64(dt)
    x.shares[1].now=now
    wire.sim_network_advance(&x.network,now)
    server:=&x.worlds[0]
    s:=&x.sessions[0]
    for x.server_time+1.0/60<=now {
        x.server_time+=1.0/60
        x.server_tick+=1
        wire.host_update(&s.host,x.server_time)
        server_commands(s,core.world_ref(server,&x.info),nil,wire.host_poll(&s.host),&server.remote)
        for row in 0..<core.count(&server.transforms) {core.edit_at(&server.transforms,row).position.x+=x.speed}
        core.settle(&x.info,server,nil)
        server_publish(s,core.world_ref(server,&x.info),&x.outbox,x.server_tick)
    }
    wire.host_update(&x.sessions[1].host,now)
    x.platform.fixed_dt=dt
    platform.frame_begin(x.platform)
    started:=time.tick_now()
    host.app_game_frame(&x.apps[1],&x.worlds[1],host.ALL_PHASES-{.Render})
    x.client_seconds=time.duration_seconds(time.tick_since(started))
}

// The entity of the client that stands for the mover of the server, once it arrived.
@(private="file")
timing_replica :: proc(x:^Timing) -> core.Entity {
    c:=&x.sessions[1].client
    for &r in c.replicas[:c.replica_high] {
        if r.object!=0 && r.pose.id==7 {return r.entity}
    }
    return core.NONE
}

@(private="file")
timing_drawn :: proc(x:^Timing,e:core.Entity) -> (position:[3]f32,ok:bool) {
    client:=&x.worlds[1]
    world,found:=core.get(&client.worlds,e)
    if !found {return}
    return render.drawn_transform(world,client.frame).position,true
}

// Frames of a simple pseudo-random length around period, within spread seconds.
@(private)
timing_dt :: proc(state:^u64,period,spread:f32) -> f32 {
    state^=state^*6364136223846793005+1442695040888963407
    unit:=f32(state^>>40)/f32(1<<24)
    return period+(unit*2-1)*spread
}

@(private="file")
client_frames_run_the_ticks_of_the_clock :: proc(t:^testing.T,period,spread:f32) {
    x:=new(Timing);defer free(x)
    defer timing_destroy(x)
    if !timing_init(x,t,{latency=0.03,jitter=0.002}) {return}
    client:=&x.worlds[1]
    sh:=&x.shares[1]
    random:=u64(17)
    for _ in 0..<int(3/period) {timing_frame_run(x,timing_dt(&random,period,spread))}
    testing.expect(t,wire.clock_state(&x.sessions[1].host).synced)
    previous_drawn,_:=timing_drawn(x,sh.mover)
    previous_tick:=client.time.tick
    backward,outside,uneven:=0,0,0
    for _ in 0..<int(3/period) {
        ran:=sh.ran
        timing_frame_run(x,timing_dt(&random,period,spread))
        if client.frame.alpha<0 || client.frame.alpha>1 {outside+=1}
        if u64(sh.ran-ran)!=client.time.tick-previous_tick {uneven+=1}
        drawn,_:=timing_drawn(x,sh.mover)
        if drawn.x<previous_drawn.x {backward+=1}
        previous_drawn,previous_tick=drawn,client.time.tick
    }
    testing.expectf(t,outside==0,"alpha outside [0,1] in %d frames",outside)
    testing.expectf(t,uneven==0,"%d frames ran other ticks than the clock of the world counted",uneven)
    testing.expectf(t,backward==0,"what moves steadily went back in %d frames",backward)
}

@(test)
a_client_at_144_hz_draws_what_it_predicts_always_forward :: proc(t:^testing.T) {
    client_frames_run_the_ticks_of_the_clock(t,1.0/144,0)
}

@(test)
a_client_whose_frames_jitter_a_millisecond_draws_what_it_predicts_always_forward :: proc(t:^testing.T) {
    client_frames_run_the_ticks_of_the_clock(t,1.0/60,0.001)
    client_frames_run_the_ticks_of_the_clock(t,1.0/144,0.001)
}

// How evenly the replica of something that moves steadily on the server is
// drawn: the smallest and largest step of a frame relative to the steady one,
// and the longest run of frames it did not move.
@(private="file")
replica_steps :: proc(t:^testing.T,x:^Timing,period,spread:f32,seconds:f64) -> (smallest,largest:f32,stalled:int) {
    random:=u64(29)
    for _ in 0..<int(4/period) {timing_frame_run(x,timing_dt(&random,period,spread))}
    e:=timing_replica(x)
    if !testing.expect(t,e!=core.NONE,"the replica arrived") {return}
    previous,_:=timing_drawn(x,e)
    smallest,largest=max(f32),0
    still:=0
    for _ in 0..<int(seconds/f64(period)) {
        dt:=timing_dt(&random,period,spread)
        timing_frame_run(x,dt)
        drawn,_:=timing_drawn(x,e)
        steady:=x.speed*60*dt
        step:=(drawn.x-previous.x)/steady
        smallest,largest=min(smallest,step),max(largest,step)
        still=step<0.2?still+1:0
        stalled=max(stalled,still)
        previous=drawn
    }
    return
}

@(test)
an_interpolated_replica_that_moves_steadily_is_drawn_steadily_at_144_hz :: proc(t:^testing.T) {
    x:=new(Timing);defer free(x)
    defer timing_destroy(x)
    if !timing_init(x,t,{latency=0.03,jitter=0.002}) {return}
    smallest,largest,_:=replica_steps(t,x,1.0/144,0,3)
    testing.expectf(t,smallest>0.8 && largest<1.2,"steps between %v and %v of the steady one",smallest,largest)
}

@(test)
an_interpolated_replica_published_ten_times_a_second_keeps_moving :: proc(t:^testing.T) {
    x:=new(Timing);defer free(x)
    defer timing_destroy(x)
    if !timing_init(x,t,{latency=0.03,jitter=0.002},update_hz=10) {return}
    smallest,largest,stalled:=replica_steps(t,x,1.0/60,0,4)
    testing.expectf(t,stalled==0 && smallest>0.7 && largest<1.3,"steps between %v and %v of the steady one, still for %d frames",smallest,largest,stalled)
}

// The server goes from publishing every tick to ten times a second: the
// replica is shown further behind, a little each tick, and goes on moving.
@(test)
an_interpolated_replica_whose_states_come_further_apart_keeps_moving :: proc(t:^testing.T) {
    x:=new(Timing);defer free(x)
    defer timing_destroy(x)
    if !timing_init(x,t,{latency=0.03,jitter=0.002}) {return}
    random:=u64(31)
    for _ in 0..<240 {timing_frame_run(x,timing_dt(&random,1.0/60,0))}
    core.edit(&x.worlds[0].objects,x.moved).update_hz=10
    smallest,largest,stalled:=replica_steps(t,x,1.0/60,0,4)
    testing.expectf(t,stalled==0 && smallest>0.7 && largest<1.3,"steps between %v and %v of the steady one, still for %d frames",smallest,largest,stalled)
    c:=&x.sessions[1].client
    for &r in c.replicas[:c.replica_high] {
        if r.object!=0 {testing.expectf(t,r.delay>4.5 && r.delay<5.5,"shown %v ticks further behind for states 6 ticks apart",r.delay)}
    }
}

@(test)
an_interpolated_replica_over_a_jittery_link_keeps_moving :: proc(t:^testing.T) {
    x:=new(Timing);defer free(x)
    defer timing_destroy(x)
    if !timing_init(x,t,{latency=0.05,jitter=0.03},seed=41) {return}
    smallest,largest,stalled:=replica_steps(t,x,1.0/60,0,6)
    testing.expectf(t,stalled==0 && smallest>0.7 && largest<1.3,"steps between %v and %v of the steady one, still for %d frames",smallest,largest,stalled)
}

// The body of a replica someone else simulates is moved to where the
// interpolation has it as a kinematic body, and has its own type again when
// this client takes it over.
@(test)
an_interpolated_body_is_kinematic_until_this_client_simulates_it :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
    e:=net_test_body(&world,&info,1)
    world.values.values[0].force=0
    shared:=Net_Test_Shared{info=&info}
    defer phys.collider_meshes_destroy(&shared.colliders)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shared}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    net_test_physics(&world,&shared,&app)
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=3,endpoints=2,packets=64}))
    defer wire.sim_network_destroy(&network)
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,1,.Client)) {return}
    defer session_destroy(&s)
    problems:core.Problems
    defer core.value_free(&problems,type_info_of(core.Problems))
    s.problems=&problems
    shared.session=&s
    ref:=core.world_ref(&world,&info)
    r:=net_test_replica(&s,ref,e,.Shown,.Lent)
    testing.expect_value(t,r.mode,Mode.Interpolated)
    // The server has it going along x at 3 m/s.
    for tick in u32(1)..=40 {
        r.tick=tick
        r.pose.position={f32(tick)*0.05,0,0}
        r.motion.linear={3,0,0}
        replica_sample(&s,r,0)
    }
    body_type :: proc(w:^Net_Test_World,e:core.Entity) -> phys.Body_Type {
        info,_:=phys.body_info(core.ref(&w.state),phys.body_of(core.ref(&w.state),e))
        return info.type
    }
    for tick in 1..<30 {
        world.time.tick=u64(tick)
        net_test_fixed(&world,&shared,nil,&app)
    }
    testing.expect_value(t,body_type(&world,e),phys.Body_Type.Kinematic)
    motion,_:=core.get(&world.bodies,e)
    testing.expectf(t,math.abs(motion.linear.x-3)<0.2 && math.abs(motion.linear.y)<0.2,"it goes as the interpolation does: %v",motion.linear)
    r.role=.Held
    replica_classify(&s,ref,r)
    core.settle(&info,&world,nil)
    for tick in 30..<32 {
        world.time.tick=u64(tick)
        net_test_fixed(&world,&shared,nil,&app)
    }
    testing.expect_value(t,r.mode,Mode.Here)
    testing.expect_value(t,body_type(&world,e),phys.Body_Type.Dynamic)
}

// The game manipulates every tick a body the network interpolates (an
// animated ragdoll): the replica goes where the server has it, and the
// manipulation holds the body again when this client takes it over.
@(test)
an_interpolated_body_follows_the_server_over_a_manipulation_of_the_game_and_gives_it_back :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
    e:=net_test_body(&world,&info,1)
    world.values.values[0].force=0
    shared:=Net_Test_Shared{info=&info}
    defer phys.collider_meshes_destroy(&shared.colliders)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shared}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    net_test_physics(&world,&shared,&app)
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=3,endpoints=2,packets=64}))
    defer wire.sim_network_destroy(&network)
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,1,.Client)) {return}
    defer session_destroy(&s)
    problems:core.Problems
    defer core.value_free(&problems,type_info_of(core.Problems))
    s.problems=&problems
    shared.session=&s
    ref:=core.world_ref(&world,&info)
    r:=net_test_replica(&s,ref,e,.Shown,.Lent)
    for tick in u32(1)..=40 {
        r.tick=tick
        r.pose.position={f32(tick)*0.05,0,0}
        r.motion.linear={3,0,0}
        replica_sample(&s,r,0)
    }
    held:=[3]f32{0,2,0}
    for tick in 1..<30 {
        world.time.tick=u64(tick)
        phys.manipulation_target(&world.requests,e,held)
        net_test_fixed(&world,&shared,nil,&app)
    }
    local,_:=core.get(&world.transforms,e)
    motion,_:=core.get(&world.bodies,e)
    testing.expectf(t,abs(local.position.x-1.5)<0.1 && abs(local.position.y)<0.05,"it is where the server has it: %v",local.position)
    testing.expectf(t,abs(motion.linear.x-3)<0.2 && abs(motion.linear.y)<0.2,"it goes as the interpolation does: %v",motion.linear)
    r.role=.Held
    replica_classify(&s,ref,r)
    core.settle(&info,&world,nil)
    body:=phys.body_of(core.ref(&world.state),e)
    taken,_:=phys.body_info(core.ref(&world.state),body)
    testing.expect_value(t,taken.type,phys.Body_Type.Kinematic)
    for tick in 30..<90 {
        world.time.tick=u64(tick)
        net_test_fixed(&world,&shared,nil,&app)
    }
    local,_=core.get(&world.transforms,e)
    testing.expectf(t,linalg.length(local.position-held)<0.01,"the manipulation of the game holds it again: %v",local.position)
    phys.manipulation_end(&world.requests,e)
    net_test_fixed(&world,&shared,nil,&app)
    given,_:=phys.body_info(core.ref(&world.state),body)
    testing.expect_value(t,given.type,phys.Body_Type.Dynamic)
    testing.expect_value(t,problems.count,0)
}
