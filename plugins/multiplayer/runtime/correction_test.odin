package multiplayer

import "core:fmt"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "mirai:core"
import inp "mirai:engine/input"
import phys "plugins:physics/runtime"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/base"

// A client pushes a row of boxes with its own body over a conditioned link,
// while the server pushes another body the client only learns of late: what
// the corrections of its prediction cost and how far what it shows strays.

@(private) CORRECTION_TICKS :: 900
@(private) CORRECTION_PUSH :: 14
@(private) CORRECTION_BODIES :: 9

@(private)
Correction_Shared :: struct {
    using net:Net_Test_Shared,
    player:core.Entity,
    connection:Connection,
    server:bool,
}

@(private)
Correction_Link :: struct {latency,jitter:f64,loss:f32}

@(private)
Correction_Result :: struct {
    stats:Net_Stats,
    frame_resimulated:int, // most ticks simulated again in one frame
    shown_mean,shown_p95,shown_max:f32, // meters the client showed its bodies away from where the server had them at the same tick
    teleports:u64,
    converged:f32,
    problems:int,
}

@(private)
correction_fixed :: proc(world,shared,editor,application:rawptr) {
    w:=cast(^Net_Test_World)world
    sh:=cast(^Correction_Shared)shared
    app:=cast(^host.App)application
    ref:=core.world_ref(w,sh.info)
    if sh.session!=nil {
        net_tick_head(ref,app,sh.session,&w.remote,nil,nil,sh.session.problems)
        core.settle(sh.info,w,nil)
    }
    net_test_feed(w)
    push:f32
    if sh.server {
        sent,_:=remote_input(core.ref(&w.remote),sh.connection)
        push=net_test_axis(sent,NET_TEST_PUSH)
    } else {
        push=inp.seat_action(core.read(&w.seats),inp.local_seat(&w.seats,0),NET_TEST_PUSH).value
    }
    if push!=0 {phys.apply_force(&w.requests,sh.player,{push*CORRECTION_PUSH,0,0})}
    net_test_physics(w,sh,app)
    if sh.session!=nil {
        outbox:Net_Outbox
        net_tick_tail(ref,sh.session,&outbox,&w.made,sh.session.problems)
        core.value_free(&outbox,type_info_of(Net_Outbox))
    }
}

@(private)
correction_body :: proc(w:^Net_Test_World,id:base.Entity_Id,position:[3]f32) -> core.Entity {
    e:=core.create(&w.entities)
    core.add(&w.identities,e,core.Id{id})
    core.add(&w.transforms,e,core.Transform{position=position,rotation=1,scale={1,1,1}})
    rigid:=phys.RIGID_BODY_DYNAMIC
    rigid.mass=1
    core.add(&w.rigids,e,rigid)
    core.add(&w.colliders,e,phys.collider_box({0.25,0.25,0.25}))
    core.add(&w.values,e,Net_Test_Value{})
    return e
}

@(private)
correction_world :: proc(w:^Net_Test_World,info:^core.World_Info) -> (bodies:[CORRECTION_BODIES]core.Entity) {
    net_test_init(w,info)
    w.settings.bodies,w.settings.shapes,w.settings.contacts=32,32,256
    core.edit_at(&w.gravities,0).acceleration=9.81
    ground:=core.create(&w.entities)
    core.add(&w.transforms,ground,core.Transform{position={0,-0.5,0},rotation=1,scale={1,1,1}})
    core.add(&w.rigids,ground,phys.RIGID_BODY_STATIC)
    core.add(&w.colliders,ground,phys.collider_box({40,0.5,10}))
    bodies[0]=correction_body(w,1,{0,0.25,0})
    for k in 0..<4 {bodies[1+k]=correction_body(w,base.Entity_Id(2+k),{1+0.55*f32(k),0.25,0})}
    for k in 0..<3 {bodies[5+k]=correction_body(w,base.Entity_Id(6+k),{1.275+0.55*f32(k),0.75,0})}
    bodies[8]=correction_body(w,9,{5,0.25,0})
    core.settle(info,w,nil)
    return
}

// The keys the client holds at a tick.
@(private)
correction_keys :: proc(tick:int) -> core.Keys {
    switch phase:=tick%300; {
    case phase>=40 && phase<130: return {.Right}
    case phase>=160 && phase<230: return {.Left}
    case phase>=250 && phase<270: return {.Right}
    }
    return {}
}

// The force the server gives its own body, which the client learns of a round trip late.
@(private)
correction_force :: proc(tick:int) -> f32 {
    switch (tick/45)%4 {
    case 1: return -10
    case 3: return 10
    }
    return 0
}

@(private)
correction_run :: proc(t:^testing.T,settings:Net_Settings,link:Correction_Link,seed:u64) -> (result:Correction_Result) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    info.loops[.Game][.Fixed]=correction_fixed
    worlds:[2]Net_Test_World
    shares:[2]Correction_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    bodies:[2][CORRECTION_BODIES]core.Entity
    for &world,index in worlds {
        bodies[index]=correction_world(&world,&info)
        shares[index]={net={info=&info},player=bodies[index][0],server=index==0}
        apps[index]={info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
        net_test_physics(&world,&shares[index],&apps[index])
    }
    net_test_player(&worlds[1],&info)
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
    defer for &app in apps {host.app_world_scratch_free(&app);delete(app.worlds)}
    defer for &share in shares {phys.collider_meshes_destroy(&share.colliders)}
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=seed,endpoints=2,packets=4096})) {return}
    defer wire.sim_network_destroy(&network)
    now:f64
    clock :: proc(data:rawptr) -> f64 {return (cast(^f64)data)^}
    conditioner:wire.Conditioner
    if !testing.expect(t,wire.conditioner_init(&conditioner,wire.sim_endpoint_transport(&network,1),{latency=link.latency,jitter=link.jitter,loss=link.loss},{seed=seed+1,clock=clock,clock_data=&now,packets=4096})) {return}
    defer wire.conditioner_destroy(&conditioner)
    settings:=settings
    settings.max_objects,settings.predicted_capacity=64,16
    if !testing.expect(t,net_test_session(&sessions[0],&worlds[0],&info,&apps[0],&network,0,.Server,settings=settings)) {return}
    if !testing.expect(t,net_test_session(&sessions[1],&worlds[1],&info,&apps[1],&network,1,.Client,wire.conditioner_transport(&conditioner),settings)) {return}
    defer for &session in sessions {session_destroy(&session)}
    for &session,index in sessions {shares[index].session=&session}
    problems:[2]core.Problems
    sessions[0].problems,sessions[1].problems=&problems[0],&problems[1]
    testing.expect_value(t,wire.host_connect(&sessions[1].host,wire.address_memory(0)),wire.Error.None)
    // Its input reaches the server before the server simulates its tick.
    lead:=int((link.latency+link.jitter)*60)+3
    shown:[64][CORRECTION_BODIES][3]f32
    errors:[dynamic]f32
    defer delete(errors)
    for tick in 1..<CORRECTION_TICKS {
        now=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],core.world_ref(&worlds[0],&info),nil,wire.host_poll(&sessions[0].host),&worlds[0].remote)
        for event in net_test_arrived(&sessions[0]) {
            if event.kind!=.Connected {continue}
            shares[0].connection=event.connection
            core.add(&worlds[0].objects,bodies[0][0],net_test_replicate(audience=.Always))
            net_test_own(&worlds[0],bodies[0][0],event.connection)
            for e in bodies[0][1:] {core.add(&worlds[0].objects,e,net_test_replicate(audience=.Always))}
            core.settle(&info,&worlds[0],nil)
        }
        client_commands(&sessions[1],core.world_ref(&worlds[1],&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host))
        before:=sessions[1].stats.resimulated
        client_reconcile(&sessions[1],core.world_ref(&worlds[1],&info),&apps[1],1.0/60)
        result.frame_resimulated=max(result.frame_resimulated,int(sessions[1].stats.resimulated-before))
        core.edit(&worlds[0].values,bodies[0][CORRECTION_BODIES-1]).force=correction_force(tick)
        client_tick:=tick+lead
        worlds[1].input.keys_down=correction_keys(client_tick)
        for &world,index in worlds {
            core.settle(&info,&world,nil)
            world.time.tick=u64(index==1?client_tick:tick)
            net_test_fixed_with(&world,&shares[index],&apps[index])
        }
        for e,k in bodies[1] {
            local,_:=core.get(&worlds[1].transforms,e)
            // What it shows in the past (the interpolated) is not where the server has it at the same tick.
            link,_:=core.get(&worlds[1].links,e)
            r:=replica_of(&sessions[1],link.object)
            shown[client_tick%len(shown)][k]=r!=nil && r.mode==.Predicted?local.position:{max(f32),0,0}
        }
        if tick>lead+120 && sessions[1].status==.Connected {
            for e,k in bodies[0] {
                local,_:=core.get(&worlds[0].transforms,e)
                if was:=shown[tick%len(shown)][k];was.x!=max(f32) {append(&errors,linalg.length(local.position-was))}
            }
        }
        for &session in sessions {wire.host_update(&session.host,now)}
    }
    testing.expectf(t,sessions[1].status==.Connected,"client %v %v; joined %d",sessions[1].status,sessions[1].reason,sessions[1].joined)
    result.stats=sessions[1].stats
    result.teleports=sessions[1].stats.placed
    result.problems=problems[0].count+problems[1].count
    if len(errors)>0 {
        sum:f32
        for e in errors {sum+=e}
        result.shown_mean=sum/f32(len(errors))
        slice.sort(errors[:])
        result.shown_p95=errors[len(errors)*95/100]
        result.shown_max=errors[len(errors)-1]
    }
    for k in 0..<CORRECTION_BODIES {
        server_pose,_:=core.get(&worlds[0].transforms,bodies[0][k])
        client_pose,_:=core.get(&worlds[1].transforms,bodies[1][k])
        result.converged=max(result.converged,linalg.length(server_pose.position-client_pose.position))
    }
    return
}

@(private)
net_test_fixed_with :: proc(w:^Net_Test_World,shared:^Correction_Shared,app:^host.App) {
    correction_fixed(w,shared,nil,app)
}

@(private)
correction_print :: proc(name:string,link:Correction_Link,r:Correction_Result) {
    fmt.printf("| %s | %.0f ms ±%.0f, %.0f %% | %d | %d | %d | %d | %d | %d | %d | %d | %.1f / %.1f / %.1f cm |\n",
        name,link.latency*1000,link.jitter*1000,link.loss*100,r.stats.corrected,r.stats.deferred,r.stats.switched,r.stats.placed,r.stats.resimulated,
        r.stats.largest_resimulation,r.frame_resimulated,r.stats.confirmed,r.shown_mean*100,r.shown_p95*100,r.shown_max*100)
}

@(test)
corrections_on_a_damaged_link_fit_the_frame_and_go_back_instead_of_placing :: proc(t:^testing.T) {
    link:=Correction_Link{0.1,0.02,0.05}
    r:=correction_run(t,{},link,4242)
    resolved:=settings_resolve({},1.0/60)
    testing.expectf(t,r.frame_resimulated<=resolved.max_resimulate,"a frame simulated %d ticks again, and max_resimulate is %d",r.frame_resimulated,resolved.max_resimulate)
    testing.expectf(t,r.stats.corrected>0 && r.stats.switched>0,"%d corrections and %d changes of timeline",r.stats.corrected,r.stats.switched)
    testing.expectf(t,r.stats.placed<=r.stats.deferred*3,"%d replicas took a state in the present for %d corrections that did not go back",r.stats.placed,r.stats.deferred)
    testing.expectf(t,r.shown_p95<0.2,"95 %% of what the client showed was within %.3f m of the server",r.shown_p95)
    testing.expect_value(t,r.problems,0)
}

@(private) NET_CORRECTION_SWEEP :: #config(NET_CORRECTION_SWEEP,false)

// Opt-in: mirai test plugins/multiplayer/runtime corrections_on_a_conditioned_link_by_tolerance -define:NET_CORRECTION_SWEEP=true
@(test)
corrections_on_a_conditioned_link_by_tolerance :: proc(t:^testing.T) {
    when !NET_CORRECTION_SWEEP {return}
    links:=[]Correction_Link{{0.05,0.01,0.02},{0.1,0.02,0.05}}
    Case :: struct {name:string,settings:Net_Settings}
    cases:=[]Case{
        {"1 cm, 0.1 m/s, 0.02 rad",{position_tolerance=0.01,velocity_tolerance=0.1,rotation_tolerance=0.02}},
        {"2 cm, 0.25 m/s, 0.035 rad",{position_tolerance=0.02,velocity_tolerance=0.25,rotation_tolerance=0.035}},
        {"5 cm, 0.5 m/s, 0.07 rad",{position_tolerance=0.05,velocity_tolerance=0.5,rotation_tolerance=0.07}},
        {"5 cm, no velocity, 0.07 rad",{position_tolerance=0.05,velocity_tolerance=1e9,rotation_tolerance=0.07}},
        {"10 cm, no velocity, 0.07 rad",{position_tolerance=0.1,velocity_tolerance=1e9,rotation_tolerance=0.07}},
        {"defaults, input_delay 2",{input_delay=2}},
        {"defaults, max_resimulate 8",{max_resimulate=8}},
        {"defaults, max_resimulate 31",{max_resimulate=31}},
    }
    fmt.println("| Tolerances | Link | Rollbacks | Deferred | Switches | Placed | Replayed ticks | Largest | Largest per frame | Confirmed | Shown error mean / p95 / max |")
    for link in links {
        for c in cases {correction_print(c.name,link,correction_run(t,c.settings,link,4242))}
    }
}

// A client with one predicted body, ten ticks into its history.
@(private)
Correction_Fixture :: struct {
    info:core.World_Info,
    world:Net_Test_World,
    shared:Net_Test_Shared,
    app:host.App,
    network:wire.Sim_Network,
    session:Net_Session,
    e:core.Entity,
    words:[]u32,
}

@(private)
correction_fixture_init :: proc(t:^testing.T,f:^Correction_Fixture,role:Role,settings:Net_Settings,rate:=60) -> bool {
    f.info=net_test_info(t) or_return
    net_test_init(&f.world,&f.info)
    f.e=net_test_body(&f.world,&f.info,1)
    f.shared={info=&f.info}
    f.app={info=&f.info,allocator=context.allocator,tick_dt=1/f32(rate),shared=&f.shared}
    net_test_physics(&f.world,&f.shared,&f.app)
    if !testing.expect(t,wire.sim_network_init(&f.network,{seed=31,endpoints=2,packets=64})) {return false}
    if !testing.expect(t,net_test_session(&f.session,&f.world,&f.info,&f.app,&f.network,1,.Client,settings=settings)) {return false}
    f.shared.session=&f.session
    s:=&f.session
    if !testing.expect_value(t,net_test_replica(s,core.world_ref(&f.world,&f.info),f.e,role,.Server).mode,role==.Predicted?Mode.Predicted:Mode.Interpolated) {return false}
    for tick in 1..=10 {correction_fixture_tick(f,u32(tick))}
    f.words=make([]u32,s.client.words_per)
    return true
}

@(private)
correction_fixture_tick :: proc(f:^Correction_Fixture,tick:u32) {
    f.world.time.tick=u64(tick)
    net_test_fixed(&f.world,&f.shared,nil,&f.app)
}

@(private)
correction_fixture_destroy :: proc(f:^Correction_Fixture) {
    delete(f.words)
    session_destroy(&f.session)
    wire.sim_network_destroy(&f.network)
    host.app_world_scratch_free(&f.app);delete(f.app.worlds)
    phys.collider_meshes_destroy(&f.shared.colliders)
    if f.info.sizes[.World]<=0 {return}
    core.world_destroy(&f.info,.World,&f.world)
    core.test_info_destroy(&f.info)
}

// What the server had after tick: what was predicted for it, offset meters away.
@(private)
correction_fixture_state :: proc(f:^Correction_Fixture,tick:u32,offset:[3]f32) {
    s:=&f.session
    record,_:=record_of(&s.client,&s.desc,&s.client.replicas[1],tick)
    correction_fixture_send(f,tick,{id=1,position=record.position+offset,rotation=record.rotation,scale=record.scale},{record.linear,record.angular})
}

@(private)
correction_fixture_send :: proc(f:^Correction_Fixture,tick:u32,pose:Pose,motion:Motion_State) {
    s:=&f.session
    command:=net_test_pack(s,&f.world,&s.client.replicas[1],tick,pose,motion,1,f.words)
    replica_update(s,core.world_ref(&f.world,&f.info),f.app.assets,&command)
}

@(private)
correction_fixture_position :: proc(f:^Correction_Fixture) -> [3]f32 {
    local,_:=core.get(&f.world.transforms,f.e)
    return local.position
}

// The history is in seconds: at every tick rate a state as old as max_resimulate (0.3 s) runs
// again in one frame, and the whole history (0.5 s) is still compared.
@(test)
a_correction_holds_its_window_at_every_tick_rate :: proc(t:^testing.T) {
    for rate in ([]int{60,240,480}) {
        f:Correction_Fixture
        defer correction_fixture_destroy(&f)
        if !correction_fixture_init(t,&f,.Predicted,{max_objects=8,predicted_capacity=8},rate) {return}
        s:=&f.session
        c:=&s.client
        depth:=int(wire.HISTORY_SECONDS*f32(rate))
        window:=int(0.3*f32(rate)+0.5)
        testing.expectf(t,c.history==depth+1,"%d Hz: a history of %d slots, not %d",rate,c.history,depth+1)
        for tick in 11..=depth+10 {correction_fixture_tick(&f,u32(tick))}
        newest:=c.newest
        _,kept:=record_of(c,&s.desc,&c.replicas[1],newest-u32(depth))
        _,gone:=record_of(c,&s.desc,&c.replicas[1],newest-u32(depth)-1)
        testing.expectf(t,kept && !gone,"%d Hz: the history reaches %d ticks back",rate,depth)
        correction_fixture_state(&f,newest-u32(window),{0,0.1,0})
        client_reconcile(s,core.world_ref(&f.world,&f.info),&f.app,1/f32(rate))
        testing.expectf(t,s.stats.corrected==1 && s.stats.deferred==0,"%d Hz: a state %d ticks old runs again (corrected %d, deferred %d)",rate,window,s.stats.corrected,s.stats.deferred)
    }
}

// A client takes the history its server announces when it accepts, in place of its own.
@(test)
a_client_keeps_the_history_of_its_server :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    worlds:[2]Net_Test_World
    apps:[2]host.App
    sessions:[2]Net_Session
    for &world,index in worlds {net_test_init(&world,&info);apps[index]={info=&info,allocator=context.allocator,tick_dt=1.0/240}}
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
    defer for &app in apps {host.app_world_scratch_free(&app);delete(app.worlds)}
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=5,endpoints=2,packets=256}))
    defer wire.sim_network_destroy(&network)
    seconds:=[2]f32{0.5,0.1}
    for &session,index in sessions {
        settings:=Net_Settings{max_objects=8,predicted_capacity=8,replication={history_seconds=seconds[index]}}
        if !testing.expect(t,net_test_session(&session,&worlds[index],&info,&apps[index],&network,index,index==0?.Server:.Client,settings=settings)) {return}
    }
    defer for &session in sessions {session_destroy(&session);delete(session.arrived)}
    client:=&sessions[1]
    testing.expect_value(t,client.client.history,25)
    testing.expect_value(t,wire.host_connect(&client.host,wire.address_memory(0)),wire.Error.None)
    for frame in 1..=60 {
        now:=f64(frame)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        wire.host_poll(&sessions[0].host)
        client_commands(client,core.world_ref(&worlds[1],&info),apps[1].assets,apps[1].allocator,wire.host_poll(&client.host))
        if client.status==.Connected {break}
    }
    testing.expect_value(t,client.status,Status.Connected)
    testing.expect_value(t,session_history(core.ref(client)),120)
    testing.expect_value(t,client.client.history,121)
    testing.expect_value(t,len(client.client.frames),121)
}

// An error the world cannot go back for (here the frame may run four ticks
// again, and the state is seven old) puts the replica where the server had
// it, carried to the present; what is drawn stays where it was and closes in,
// and the ticks predicted before are not compared again.
@(test)
an_error_too_deep_for_the_frame_puts_the_replica_where_the_server_carries_it :: proc(t:^testing.T) {
    f:Correction_Fixture
    defer correction_fixture_destroy(&f)
    if !correction_fixture_init(t,&f,.Predicted,{max_objects=8,predicted_capacity=8,replication={history_seconds=0.5},max_resimulate=4}) {return}
    s:=&f.session
    r:=&s.client.replicas[1]
    ref:=core.world_ref(&f.world,&f.info)
    third,_:=record_of(&s.client,&s.desc,r,3)
    before,_:=replica_now(s,ref,r)
    wanted:=before.position+{0,0.1,0}
    correction_fixture_state(&f,3,{0,0.1,0})
    client_reconcile(s,ref,&f.app,1.0/60)
    testing.expect(t,s.stats.corrected==0 && s.stats.deferred==1 && s.stats.placed==1)
    now,_:=replica_now(s,ref,r)
    testing.expectf(t,linalg.length(now.position-wanted)<0.002,"the replica is at %v, and the server carries it to %v",now.position,wanted)
    testing.expectf(t,linalg.length(now.position+r.smoothing.offset-before.position)<1e-4,"it is drawn at %v, and was at %v",now.position+r.smoothing.offset,before.position)
    correction_fixture_send(&f,8,{id=1,position=wanted+{0,0.3,0},rotation=1,scale={1,1,1}},{})
    client_reconcile(s,ref,&f.app,1.0/60)
    testing.expect(t,s.stats.corrected==0 && s.stats.placed==1,"a tick predicted before it was placed is not compared")
    for _ in 0..<60 {client_frame(s,ref,1.0/60)}
    testing.expectf(t,linalg.length(r.smoothing.offset)<0.001,"after a second it is drawn %v off",r.smoothing.offset)
}

// A client far ahead of the server, as after the server stopped and dropped
// ticks, gets states older than its history: there is nothing to compare them
// with, and the replica goes where the server had it, carried to the present.
@(test)
a_state_older_than_the_history_puts_the_replica_where_the_server_had_it :: proc(t:^testing.T) {
    f:Correction_Fixture
    defer correction_fixture_destroy(&f)
    if !correction_fixture_init(t,&f,.Predicted,{max_objects=8,predicted_capacity=8,replication={history_seconds=7.0/60}}) {return}
    c:=&f.session.client
    _,kept:=record_of(c,&f.session.desc,&c.replicas[1],1)
    testing.expect(t,!kept,"tick 1 is out of a history of 8 ticks at tick 10")
    before:=correction_fixture_position(&f)
    unverified:=f.session.stats.unverified
    there:=before+{0,0,2}
    velocity:=[3]f32{1,0,0}
    correction_fixture_send(&f,1,{id=1,position=there,rotation=quaternion(w=1,x=0,y=0,z=0),scale={1,1,1}},{linear=velocity})
    client_reconcile(&f.session,core.world_ref(&f.world,&f.info),&f.app,1.0/60)
    // The state the replica was made with is older still: both go uncompared, and only the newest places it.
    testing.expectf(t,f.session.stats.unverified-unverified>=1,"%d states uncompared",f.session.stats.unverified-unverified)
    testing.expect_value(t,f.session.stats.placed,u64(1))
    wanted:=there+velocity*(f32(c.newest-1)/60)
    // A body takes the place with the next tick: for the network it is there already.
    now,_:=replica_now(&f.session,core.world_ref(&f.world,&f.info),&c.replicas[1])
    got:=now.position
    testing.expectf(t,linalg.length(got-wanted)<0.002,"the replica is at %v, and the server had it at %v nine ticks ago",got,wanted)
}

// The states of the server of a predicted replica are kept at the slot of
// their tick: that of a tick is found there, the newest at or before a tick
// going back from it, and one a whole history newer takes the slot of the
// older. A replica that takes the record slot starts without them.
@(test)
authoritative_states_are_found_by_their_tick_and_the_newest_before_it :: proc(t:^testing.T) {
    HISTORY :: 8
    s:Net_Session
    c:=&s.client
    c.history,c.words_per=HISTORY,1
    records:[2*HISTORY]Authoritative
    words:[2*HISTORY]u32
    c.authoritative,c.authoritative_words=records[:],words[:]
    r:=Replica{object=3,mode=.Predicted,slot=1}
    state :: proc(s:^Net_Session,r:^Replica,tick,word:u32) {
        held:=[1]u32{word}
        command:=wire.Command{tick=tick,mask=1,words=held[:]}
        authoritative_capture(s,r,&command)
    }
    for tick in ([]u32{10,12,13}) {state(&s,&r,tick,tick*2)}
    Case :: struct {tick:u32,exact:bool,found:u32} // found: the tick of the state; 0: none
    check :: proc(t:^testing.T,s:^Net_Session,r:^Replica,cases:[]Case,word:proc(tick:u32) -> u32) {
        for k in cases {
            command,found:=authoritative_command(s,r,k.tick,k.exact)
            testing.expectf(t,found==(k.found!=0) && (!found || command.tick==k.found && command.words[0]==word(k.found)),"tick %d, exact %v: found %v, of tick %d",k.tick,k.exact,found,command.tick)
        }
    }
    check(t,&s,&r,{{12,true,12},{11,true,0},{11,false,10},{13,false,13},{17,false,13},{9,false,0}},proc(tick:u32) -> u32 {return tick*2})
    state(&s,&r,10+HISTORY,7)
    check(t,&s,&r,{{10,true,0},{17,false,13},{10+HISTORY,false,10+HISTORY},{25,false,10+HISTORY},{60,false,10+HISTORY}},proc(tick:u32) -> u32 {return tick==10+HISTORY?7:tick*2})
    // A replica that is not predicted has no states here.
    shown:=Replica{object=3,mode=.Interpolated,slot=-1}
    check(t,&s,&shown,{{13,false,0}},proc(tick:u32) -> u32 {return 0})
    other:=Replica{object=3,mode=.Predicted,slot=1}
    authority_clear(&s,&other)
    check(t,&s,&other,{{60,false,0}},proc(tick:u32) -> u32 {return 0})
}
