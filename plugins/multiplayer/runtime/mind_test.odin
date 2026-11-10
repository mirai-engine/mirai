package multiplayer

import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/ai"
import behavior "plugins:behavior/runtime"

// The test world with the agents of behavior: their minds and what they present.
@(private="file")
Mind_Net_World :: struct {
    using world:core.Test_World,
    using net:Net_Test_Tables,
    agents:core.Table(behavior.Mind_Agent),
    shows:core.Table(behavior.Mind_Presentation),
}

@(private="file")
mind_net_types :: proc(types:^[dynamic]core.Test_Type) {
    net_test_types(types)
    behavior.test_types(types)
}

@(private)
Mind_Net_Tick :: struct {
    world:behavior.Mind_World,
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
        a.memory[0]=c.world.time.tick
        if a.action==.Look {behavior.present_animation(a,7)}
        return .Running
    case .Update:
        return .Success if c.world.time.tick-a.memory[0]>=20 else .Running
    case .Exit:
    }
    return .Success
}

@(private)
MIND_NET_ACTS := [Net_Act]proc(a:^ai.Act(Net_Act)) -> ai.Status{.Round=mind_net_round,.Walk=mind_net_step,.Look=mind_net_step}

// What the mind of the server's agent did in a tick.
@(private)
mind_net_decide :: proc(w:^Mind_Net_World,info:^core.World_Info,minds:^behavior.Minds,tick:u64) {
    c:=Mind_Net_Tick{world={minds=minds,agents=&w.agents,presentations=&w.shows,time={tick=tick,dt=1.0/60,seconds=f64(tick)/60,playing=true}}}
    behavior.minds_tick(&c.world,"walker",&MIND_NET_ACTS,mind_net_think)
    core.settle(info,w,nil)
}

// A mind decides on the server alone: the client, whose scene gave its
// entity the same Mind_Agent, sees what it does in the Mind_Presentation
// that comes from the server, and its own mind does not move. A copy of the
// server's world (a snapshot) decides from there the same as the world.
@(test)
a_mind_decides_on_the_server_and_the_client_sees_its_presentation :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Mind_Net_World,mind_net_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    info.loops[.Game][.Fixed]=net_test_fixed
    worlds:[2]Mind_Net_World
    shares:[2]Net_Test_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    for &world,index in worlds {
        net_test_init(&world,&info)
        shares[index].info=&info
        apps[index]={allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
    }
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
    server,client:=&worlds[0],&worlds[1]
    minds:=new(behavior.Minds);defer free(minds)
    for w in ([]^Mind_Net_World{server,client}) {
        e:=core.create(&w.entities)
        core.add(&w.identities,e,core.Id{5})
        core.add(&w.transforms,e,core.Transform{rotation=1,scale={1,1,1}})
        core.add(&w.agents,e,behavior.Mind_Agent{mind=behavior.mind_name("walker")})
        core.settle(&info,w,nil)
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
    defer if snapshot!=nil {core.world_destroy(&info,.World,snapshot);free(snapshot)}
    for tick in 1..<200 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],core.world_ref(server,&info),nil,wire.host_poll(&sessions[0].host),&server.remote)
        client_commands(&sessions[1],core.world_ref(client,&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host))
        client_place(&sessions[1],core.world_ref(client,&info),wire.clock_interpolation_tick(&sessions[1].host,u32(tick)),nil,false)
        core.settle(&info,client,nil)
        // The server decides; the client, a function `server` that does not run there, does not.
        mind_net_decide(server,&info,minds,u64(tick))
        if tick==1 {core.add(&server.objects,agent,net_test_replicate(audience=.Always));core.settle(&info,server,nil)}
        shown[tick],_=core.get(&server.shows,agent)
        if seen,ok:=core.get(&client.shows,mine);ok && tick>40 {
            // What it shows is what the server showed a few ticks before.
            recent:=false
            for back in 0..<12 {recent||=tick-back>0 && shown[tick-back]==seen}
            testing.expectf(t,recent,"the client shows %v at tick %d",seen,tick)
            testing.expect(t,seen.action==u16(Net_Act.Round))
            if seen.step<=u16(max(Net_Act)) {seen_steps+={Net_Act(seen.step)}}
        }
        if tick==100 {
            snapshot=new(Mind_Net_World)
            testing.expect(t,core.world_init(&info,.World,snapshot,context.allocator) && core.world_copy(&info,snapshot,server))
        }
        server_publish(&sessions[0],core.world_ref(server,&info),&outbox,u32(tick))
    }
    testing.expect_value(t,seen_steps,bit_set[Net_Act]{.Walk,.Look})
    last,_:=core.get(&client.shows,mine)
    testing.expect(t,last.animation==7 && last.animations>=3)
    testing.expect_value(t,client.agents.values[0].state.ticks,0)
    // The snapshot taken at tick 100 decides from there as the world did.
    if snapshot!=nil {
        for tick in 101..<200 {mind_net_decide(snapshot,&info,minds,u64(tick))}
        testing.expect(t,mem.compare_ptrs(&snapshot.agents.values[0].state,&server.agents.values[0].state,size_of(ai.Mind))==0,"the copy decides as the world")
        copied,_:=core.get(&snapshot.shows,snapshot.agents.entities[0])
        testing.expect_value(t,copied,shown[199])
    }
    testing.expect_value(t,problems[0].count,0)
    testing.expect_value(t,problems[1].count,0)
}
