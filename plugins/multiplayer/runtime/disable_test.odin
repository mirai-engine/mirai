package multiplayer

import "core:testing"
import "mirai:core"
import "mirai:engine/scene"
import "mirai:host"
import wire "mirai:net"

// A replicated component that the server turns off is off on the client,
// with its value, and on again when the server turns it on.
@(test)
components_turned_off_on_the_server_turn_off_on_the_client :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    worlds:[2]Net_Test_World
    shares:[2]Net_Test_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    entities:[2]core.Entity
    for &world,index in worlds {
        net_test_init(&world,&info)
        entities[index]=net_test_body(&world,&info,1)
        shares[index].info=&info
        apps[index]={allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
    }
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
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
    server,client:=&worlds[0],&worlds[1]
    client_state :: proc(client:^Net_Test_World,e:core.Entity) -> (on,turned_off,found:bool) {return core.raw_state(core.raw(&client.values),e)}
    for tick in 1..<120 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],core.world_ref(server,&info),nil,wire.host_poll(&sessions[0].host),&server.remote)
        client_commands(&sessions[1],core.world_ref(client,&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host))
        client_place(&sessions[1],core.world_ref(client,&info),wire.clock_interpolation_tick(&sessions[1].host,u32(tick)),nil,false)
        core.settle(&info,client,nil)
        switch tick {
        case 21: core.add(&server.objects,entities[0],net_test_replicate(audience=.Always))
        case 50:
            on,_,found:=client_state(client,entities[1])
            testing.expect(t,found && on,"on while the server has it on")
            core.disable(&server.values,entities[0])
        case 80:
            on,turned_off,found:=client_state(client,entities[1])
            testing.expect(t,found && !on && turned_off,"turned off as on the server")
            value:=client.values.values[core.raw_row(core.raw(&client.values),entities[1])]
            testing.expect_value(t,value.force,f32(1))
            core.enable(&server.values,entities[0])
        case 119:
            on,_,_:=client_state(client,entities[1])
            testing.expect(t,on,"on again")
        }
        core.settle(&info,server,nil)
        server_publish(&sessions[0],core.world_ref(server,&info),&outbox,u32(tick))
    }
    testing.expect_value(t,problems[0].count,0)
}

// A replica made from a prefab this client has not read is off until the
// prefab fills it (scene.Prefab_Pending), whatever the server says, and
// follows the server once it is filled.
@(test)
a_replica_that_waits_for_its_prefab_stays_off_until_it_is_filled :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    w:Net_Test_World
    net_test_init(&w,&info)
    defer core.world_destroy(&info,.World,&w)
    ref:=core.world_ref(&w,&info)
    e:=net_test_body(&w,&info,1)
    core.add(&w.disabled,e,core.Disabled{})
    core.add(&w.pendings,e,scene.Prefab_Pending{prefab={0x5a,9}})
    core.world_settle(ref)
    r:=Replica{entity=e}
    replica_turn(ref,&r)
    core.world_settle(ref)
    testing.expect(t,core.raw_row(core.raw(&w.disabled),e)>=0,"the server has it on, and it waits for its prefab")
    core.remove(&w.pendings,e)
    core.world_settle(ref)
    replica_turn(ref,&r)
    core.world_settle(ref)
    testing.expect(t,core.raw_row(core.raw(&w.disabled),e)<0,"filled, it follows the server")
}
