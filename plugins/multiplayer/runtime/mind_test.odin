package multiplayer

import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/ai"
import "mirai:std/base"
import anim "plugins:animation/runtime"
import behavior "plugins:behavior/runtime"

// The test world with the agents of behavior and the actions of their animation.
@(private="file")
Mind_Net_World :: struct {
    using world:core.Test_World,
    using net:Net_Test_Tables,
    agents:core.Table(behavior.Mind_Agent),
    animations:core.Table(anim.Animation),
    played:core.Table(anim.Animation_Played),
    animation_requests:anim.Animation_Requests,
    animation_events:anim.Animation_Events,
    playback:anim.Playback,
    actions:anim.Action_Runtime,
}

@(private="file")
mind_net_types :: proc(types:^[dynamic]core.Test_Type) {
    net_test_types(types)
    behavior.test_types(types)
    anim.test_types(types)
}

@(private)
Mind_Net_Tick :: struct {
    world:behavior.Mind_World,
    requests:^anim.Animation_Requests,
}

@(private)
Net_Act :: enum u8 {Round,Walk,Look}

@(private)
mind_net_think :: proc(t:^ai.Think(Net_Act)) {ai.propose(t,.Round,1)}

// A round walks 20 ticks, then looks 20 ticks and waves.
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
        if a.action==.Look {anim.play(c.requests,behavior.agent(a),"Wave")}
        return .Running
    case .Update:
        return .Success if c.world.time.tick-a.memory[0]>=20 else .Running
    case .Exit:
    }
    return .Success
}

@(private)
MIND_NET_ACTS := [Net_Act]proc(a:^ai.Act(Net_Act)) -> ai.Status{.Round=mind_net_round,.Walk=mind_net_step,.Look=mind_net_step}

@(private="file")
MIND_NET_CHARACTER :: base.Asset_Id{0x5e7,0xc4a}

// What the mind of the server's agent did in a tick, and the actions it asked its animation for.
@(private="file")
mind_net_decide :: proc(w:^Mind_Net_World,info:^core.World_Info,minds:^behavior.Minds,characters:^anim.Character_Assets,app:^host.App,tick:u64,problems:^core.Problems) {
    time:=core.Time{tick=tick,dt=1.0/60,seconds=f64(tick)/60,playing=true}
    c:=Mind_Net_Tick{world={minds=minds,agents=&w.agents,time=time},requests=&w.animation_requests}
    behavior.minds_tick(&c.world,"walker",&MIND_NET_ACTS,mind_net_think)
    mind_net_animate(w,info,characters,app,time,problems)
}

// The actions of the animation of a world in a tick: those its game asked, and on a client those
// the server started.
@(private="file")
mind_net_animate :: proc(w:^Mind_Net_World,info:^core.World_Info,characters:^anim.Character_Assets,app:^host.App,time:core.Time,problems:^core.Problems) {
    clear(&w.animation_events.items)
    anim.actions_prepare(&w.actions,&w.animation_requests,characters,core.read(&w.animations),&w.playback,&w.animation_events,app,core.read(&w.remotes),&w.played,time,problems)
    core.settle(info,w,nil)
}

// A mind decides on the server alone: the client, whose scene gave its entity the same Mind_Agent
// and Animation, plays the action the mind of the server played, from the tick it started, within
// the delay it shows the server by; its own mind does not move. A copy of the server's world (a
// snapshot) decides from there the same as the world.
@(test)
a_mind_decides_on_the_server_and_the_client_plays_what_it_plays :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Mind_Net_World,mind_net_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    info.loops[.Game][.Fixed]=net_test_fixed
    worlds:[2]Mind_Net_World
    shares:[2]Net_Test_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    assets:host.Assets;defer {delete(assets.registry.by_id);delete(assets.registry.files)}
    assets.registry.by_id=make(map[base.Asset_Id]u32);append(&assets.registry.files,asset.Registry_File{id=MIND_NET_CHARACTER,kind=anim.CHARACTER_KIND,state=.Asset});assets.registry.by_id[MIND_NET_CHARACTER]=0
    for &world,index in worlds {
        net_test_init(&world,&info)
        shares[index].info=&info
        apps[index]={allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
    }
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
    // The .character of the agents: one action, as a read set leaves it.
    wave:=[1]anim.Action_Definition{anim.ACTION_DEFINITION_DEFAULT};base.text_set(wave[0].name[:],"Wave");base.text_set(wave[0].clip[:],"wave")
    characters:anim.Character_Assets;defer delete(characters.contents)
    characters.allocator=context.allocator
    append(&characters.contents,anim.Character_Content{id=MIND_NET_CHARACTER,checked=1,revision=1,valid=true,set={info={animation={1,2}},match={info=anim.MATCH_INFO_DEFAULT},actions={actions=wave[:]}}})
    server,client:=&worlds[0],&worlds[1]
    minds:=new(behavior.Minds);defer free(minds)
    for w in ([]^Mind_Net_World{server,client}) {
        e:=core.create(&w.entities)
        core.add(&w.identities,e,core.Id{5})
        core.add(&w.transforms,e,core.Transform{rotation=1,scale={1,1,1}})
        core.add(&w.agents,e,behavior.Mind_Agent{mind=behavior.mind_name("walker")})
        animation:=anim.ANIMATION_DEFAULT;animation.asset=MIND_NET_CHARACTER;core.add(&w.animations,e,animation)
        core.settle(&info,w,nil)
    }
    agent:=server.agents.entities[0]
    mine:=client.agents.entities[0]
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=11,endpoints=2,packets=1024})) {return}
    defer wire.sim_network_destroy(&network)
    for &session,index in sessions {
        apps[index].assets=&assets
        if !testing.expect(t,net_test_session(&session,&worlds[index],&info,&apps[index],&network,index,index==0?.Server:.Client)) {return}
    }
    defer for &session in sessions {session_destroy(&session)}
    problems:[2]core.Problems
    sessions[0].problems,sessions[1].problems=&problems[0],&problems[1]
    testing.expect_value(t,wire.host_connect(&sessions[1].host,wire.address_memory(0)),wire.Error.None)
    outbox:Net_Outbox;defer core.value_free(&outbox,type_info_of(Net_Outbox))
    snapshot:^Mind_Net_World
    defer if snapshot!=nil {core.world_destroy(&info,.World,snapshot);free(snapshot)}
    waved:[dynamic]u64;defer delete(waved)
    heard:=0
    for tick in 1..<200 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],core.world_ref(server,&info),nil,wire.host_poll(&sessions[0].host),&server.remote)
        client_commands(&sessions[1],core.world_ref(client,&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host))
        client_place(&sessions[1],core.world_ref(client,&info),wire.clock_interpolation_tick(&sessions[1].host,u32(tick)),nil,false)
        core.settle(&info,client,nil)
        // The server decides; the client, a function `server` that does not run there, does not.
        mind_net_decide(server,&info,minds,&characters,&apps[0],u64(tick),&problems[0])
        mind_net_animate(client,&info,&characters,&apps[1],{tick=u64(tick),dt=1.0/60,playing=true},&problems[1])
        if tick==1 {core.add(&server.objects,agent,net_test_replicate(audience=.Always));core.settle(&info,server,nil)}
        if record,ok:=core.get(&server.played,agent);ok && (len(waved)==0 || waved[len(waved)-1]!=record.slots[0].tick) {append(&waved,record.slots[0].tick)}
        // It plays each wave once, from the tick the server started it, within the delay it shows the server by.
        if len(client.actions.states)>0 && client.actions.states[0].entity==mine {
            state:=&client.actions.states[0]
            if state.heard[0]!=0 && (heard==0 || state.heard[0]!=waved[heard-1]) {
                testing.expectf(t,heard<len(waved) && state.heard[0]==waved[heard] && u64(tick)-waved[heard]<12,"the client plays wave %d at tick %d: %v",heard,tick,waved[:])
                slot:=state.slots[0]
                testing.expect(t,slot.active && slot.entering && abs(slot.late-f32(u64(tick)-state.heard[0])/60)<1e-5,"it starts as far in as the server is")
                heard+=1
            }
        }
        if tick==100 {
            snapshot=new(Mind_Net_World)
            testing.expect(t,core.world_init(&info,.World,snapshot,context.allocator) && core.world_copy(&info,snapshot,server))
        }
        server_publish(&sessions[0],core.world_ref(server,&info),&outbox,u32(tick))
    }
    testing.expect(t,len(waved)>=3 && heard>=len(waved)-1,"each wave of the server is played on the client")
    testing.expect(t,core.has(&client.remotes,mine),"the client does not decide the agent")
    testing.expect_value(t,client.agents.values[0].state.ticks,0)
    // The snapshot taken at tick 100 decides from there as the world did.
    if snapshot!=nil {
        for tick in 101..<200 {mind_net_decide(snapshot,&info,minds,&characters,&apps[0],u64(tick),&problems[0])}
        testing.expect(t,mem.compare_ptrs(&snapshot.agents.values[0].state,&server.agents.values[0].state,size_of(ai.Mind))==0,"the copy decides as the world")
        copied,_:=core.get(&snapshot.played,snapshot.agents.entities[0])
        kept,_:=core.get(&server.played,agent)
        testing.expect_value(t,copied,kept)
    }
    testing.expect_value(t,problems[0].count,0)
    testing.expect_value(t,problems[1].count,0)
}
