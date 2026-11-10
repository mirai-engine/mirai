package multiplayer

import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/ai"
import behavior "plugins:behavior/runtime"

// The test world with the agents of behavior: their minds and what they present.
@(private)
Mind_Net_World :: struct {
    using net:Net_Test_World,
    agents:core.Table(behavior.Mind_Agent),
    shows:core.Table(behavior.Mind_Presentation),
}

@(private)
mind_net_init :: proc(data:rawptr,allocator:mem.Allocator) -> bool {
    w:=cast(^Mind_Net_World)data
    core.table_init(&w.agents,"behavior.Mind_Agent")
    core.table_init(&w.shows,"behavior.Mind_Presentation")
    return net_test_init(data,allocator)
}
@(private)
mind_net_destroy :: proc(data:rawptr) {
    w:=cast(^Mind_Net_World)data
    core.table_destroy(&w.agents)
    core.table_destroy(&w.shows)
    net_test_destroy(data)
}
@(private)
mind_net_copy :: proc(dst,src:rawptr) -> bool {
    d,s:=cast(^Mind_Net_World)dst,cast(^Mind_Net_World)src
    return net_test_copy(dst,src) && core.table_copy(&d.agents,&s.agents) && core.table_copy(&d.shows,&s.shows)
}
@(private)
mind_net_copy_changed :: proc(dst,src:rawptr,marks:[]core.Copy_Mark) -> bool {
    d,s:=cast(^Mind_Net_World)dst,cast(^Mind_Net_World)src
    return net_test_copy_changed(dst,src,marks) && core.table_copy_changed(&d.agents,&s.agents,&marks[NET_TEST_TABLES]) && core.table_copy_changed(&d.shows,&s.shows,&marks[NET_TEST_TABLES+1])
}
@(private)
mind_net_swap :: proc(a,b:rawptr) {
    x,y:=cast(^Mind_Net_World)a,cast(^Mind_Net_World)b
    core.table_swap(&x.agents,&y.agents)
    core.table_swap(&x.shows,&y.shows)
    net_test_swap(a,b)
}
@(private)
mind_net_settle :: proc(world,shared,editor:rawptr) {
    w:=cast(^Mind_Net_World)world
    core.table_settle(&w.agents,&w.es)
    core.table_settle(&w.shows,&w.es)
    net_test_settle(world,shared,editor)
}

@(private)
mind_net_info :: proc() -> core.World_Info {
    info:=net_test_info()
    tables:=make([]core.Table_Info,len(info.tables)+2)
    copy(tables,info.tables)
    delete(info.tables)
    tables[NET_TEST_TABLES]={name="behavior.Mind_Agent",type=behavior.Mind_Agent,info=type_info_of(behavior.Mind_Agent),offset=offset_of(Mind_Net_World,agents)}
    tables[NET_TEST_TABLES+1]={name="behavior.Mind_Presentation",type=behavior.Mind_Presentation,info=type_info_of(behavior.Mind_Presentation),offset=offset_of(Mind_Net_World,shows),replicated=.All}
    info.tables=tables
    info.sizes[.World],info.aligns[.World]=size_of(Mind_Net_World),align_of(Mind_Net_World)
    info.init[.World],info.destroy[.World]=mind_net_init,mind_net_destroy
    info.copy,info.copy_changed,info.swap=mind_net_copy,mind_net_copy_changed,mind_net_swap
    return info
}

@(private)
Mind_Net_Tick :: struct {
    w:behavior.Act_World,
    tick:u64,
}

@(private)
Net_Act :: enum u8 {Round,Walk,Look}

@(private)
mind_net_think :: proc(t:^ai.Think(Net_Act)) {ai.propose(t,.Round,1)}

// A round walks 20 ticks, then looks 20 ticks and asks for its animation.
@(private)
mind_net_round :: proc(a:^ai.Act(Net_Act)) -> ai.Status {
    if a.phase==.Exit {return .Success}
    return ai.steps(a,.Walk,.Look)
}

@(private)
mind_net_step :: proc(a:^ai.Act(Net_Act)) -> ai.Status {
    c:=(^Mind_Net_Tick)(a.user)
    switch a.phase {
    case .Enter:
        a.memory[0]=c.tick
        if a.action==.Look {behavior.present_animation(&c.w,7)}
        return .Running
    case .Update:
        return .Success if c.tick-a.memory[0]>=20 else .Running
    case .Exit:
    }
    return .Success
}

@(private)
MIND_NET_ACTS := [Net_Act]proc(a:^ai.Act(Net_Act)) -> ai.Status{.Round=mind_net_round,.Walk=mind_net_step,.Look=mind_net_step}

// What the mind of the server's agent did in a tick.
@(private)
mind_net_decide :: proc(w:^Mind_Net_World,minds:^behavior.Minds,tick:u64) {
    c:=Mind_Net_Tick{w={presentations=&w.shows},tick=tick}
    ctx:=ai.Mind_Context{user=&c}
    problems:core.Problems
    behavior.minds_tick(minds,&w.agents,"walker",&MIND_NET_ACTS,mind_net_think,&ctx,&c.w,{tick=tick,dt=1.0/60,seconds=f64(tick)/60,playing=true},&problems)
    mind_net_settle(w,nil,nil)
}

// A mind decides on the server alone: the client, whose scene gave its
// entity the same Mind_Agent, sees what it does in the Mind_Presentation
// that comes from the server, and its own mind does not move. A copy of the
// server's world (a snapshot) decides from there the same as the world.
@(test)
a_mind_decides_on_the_server_and_the_client_sees_its_presentation :: proc(t:^testing.T) {
    info:=mind_net_info();defer delete(info.tables);defer delete(info.storages)
    worlds:[2]Mind_Net_World
    shares:[2]Net_Test_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    for &world,index in worlds {
        mind_net_init(&world,context.allocator)
        world.transforms.base,world.worlds.base,world.identities.base,world.parents.base,world.names.base=true,true,true,true,true
        shares[index].info=&info
        apps[index]={allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
    }
    defer for &world in worlds {mind_net_destroy(&world)}
    server,client:=&worlds[0],&worlds[1]
    minds:=new(behavior.Minds);defer free(minds)
    for w in ([]^Mind_Net_World{server,client}) {
        e:=core.create(&w.es)
        core.add(&w.identities,e,core.Id{5})
        core.add(&w.transforms,e,core.Transform{rotation=1,scale={1,1,1}})
        core.add(&w.agents,e,behavior.Mind_Agent{mind=behavior.mind_name("walker")})
        mind_net_settle(w,nil,nil)
    }
    agent:=server.agents.entities[0]
    mine:=client.agents.entities[0]
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=11,endpoints=2,packets=1024})) {return}
    defer wire.sim_network_destroy(&network)
    for &session,index in sessions {
        if !testing.expect(t,net_test_session(&session,&worlds[index],&info,&apps[index],&network,index,index==0?.Server:.Client)) {return}
    }
    defer for &session in sessions {session_destroy(&session)}
    problems:[2]core.Problems
    sessions[0].problems,sessions[1].problems=&problems[0],&problems[1]
    testing.expect_value(t,wire.host_connect(&sessions[1].host,wire.address_memory(0)),wire.Error.None)
    outbox:Net_Outbox;defer core.value_free(&outbox,type_info_of(Net_Outbox))
    server_events,client_events:Net_Events
    defer core.value_free(&server_events,type_info_of(Net_Events));defer core.value_free(&client_events,type_info_of(Net_Events))
    shown:[200]behavior.Mind_Presentation
    seen_steps:bit_set[Net_Act]
    snapshot:^Mind_Net_World
    defer if snapshot!=nil {mind_net_destroy(snapshot);free(snapshot)}
    for tick in 1..<200 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],core.world_ref(server,&info),nil,wire.host_poll(&sessions[0].host),&server_events,&server.remote)
        client_commands(&sessions[1],core.world_ref(client,&info),&apps[1],wire.host_poll(&sessions[1].host),&client_events)
        client_place(&sessions[1],core.world_ref(client,&info),wire.clock_interpolation_tick(&sessions[1].host,u32(tick)),nil)
        mind_net_settle(client,nil,nil)
        // The server decides; the client, a function `server` that does not run there, does not.
        mind_net_decide(server,minds,u64(tick))
        if tick==1 {core.add(&server.objects,agent,net_test_replicate(audience=.Always));mind_net_settle(server,nil,nil)}
        shown[tick],_=core.get(core.read(&server.shows),agent)
        if seen,ok:=core.get(core.read(&client.shows),mine);ok && tick>40 {
            // What it shows is what the server showed a few ticks before.
            recent:=false
            for back in 0..<12 {recent||=tick-back>0 && shown[tick-back]==seen}
            testing.expectf(t,recent,"the client shows %v at tick %d",seen,tick)
            testing.expect(t,seen.action==u16(Net_Act.Round))
            if seen.step<=u16(max(Net_Act)) {seen_steps+={Net_Act(seen.step)}}
        }
        if tick==100 {
            snapshot=new(Mind_Net_World)
            mind_net_init(snapshot,context.allocator)
            testing.expect(t,mind_net_copy(snapshot,server))
        }
        server_publish(&sessions[0],core.world_ref(server,&info),&outbox,u32(tick))
    }
    testing.expect_value(t,seen_steps,bit_set[Net_Act]{.Walk,.Look})
    last,_:=core.get(core.read(&client.shows),mine)
    testing.expect(t,last.animation==7 && last.animations>=3)
    testing.expect_value(t,client.agents.values[0].state.ticks,0)
    // The snapshot taken at tick 100 decides from there as the world did.
    if snapshot!=nil {
        for tick in 101..<200 {mind_net_decide(snapshot,minds,u64(tick))}
        testing.expect(t,mem.compare_ptrs(&snapshot.agents.values[0].state,&server.agents.values[0].state,size_of(ai.Mind))==0,"the copy decides as the world")
        copied,_:=core.get(core.read(&snapshot.shows),snapshot.agents.entities[0])
        testing.expect_value(t,copied,shown[199])
    }
    testing.expect_value(t,problems[0].count,0)
    testing.expect_value(t,problems[1].count,0)
}
