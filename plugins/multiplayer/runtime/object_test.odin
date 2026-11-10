package multiplayer

import "core:testing"
import "mirai:core"
import "mirai:host"
import wire "mirai:net"

// What a plugin that does not know the network writes, as foliage writes the
// instances taken out of a cell.
@(component,replicated="object")
Net_Test_Object :: struct {count:u32}

@(private="file")
Object_World :: struct {
    using world:core.Test_World,
    using net:Net_Test_Tables,
    taken:core.Table(Net_Test_Object),
}

// An entity with a component declared replicated="object" and no Replicate
// is an object of the server to every connection, and a client gets it with
// its component and what changes in it later.
@(test)
an_entity_with_a_replicated_object_component_reaches_a_client :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Object_World,net_test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    info.loops[.Game][.Fixed]=net_test_fixed
    worlds:[2]Object_World
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
    cell:=core.create(&server.entities)
    core.add(&server.identities,cell,core.Id{9})
    core.add(&server.transforms,cell,core.TRANSFORM_IDENTITY)
    core.add(&server.taken,cell,Net_Test_Object{count=2})
    core.settle(&info,server,nil)
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=9,endpoints=2,packets=1024})) {return}
    defer wire.sim_network_destroy(&network)
    for &session,index in sessions {
        if !testing.expect(t,net_test_session(&session,&worlds[index],&info,&apps[index],&network,index,index==0?.Server:.Client)) {return}
    }
    defer for &session in sessions {session_destroy(&session)}
    problems:[2]core.Problems
    sessions[0].problems,sessions[1].problems=&problems[0],&problems[1]
    testing.expect_value(t,wire.host_connect(&sessions[1].host,wire.address_memory(0)),wire.Error.None)
    outbox:Net_Outbox;defer core.value_free(&outbox,type_info_of(Net_Outbox))
    taken :: proc(client:^Object_World) -> (count:u32,found:bool) {
        if core.count(&client.taken)==0 {return}
        return core.at(&client.taken,0).count,true
    }
    for tick in 1..<90 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],core.world_ref(server,&info),nil,wire.host_poll(&sessions[0].host),&server.remote)
        client_commands(&sessions[1],core.world_ref(client,&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host))
        client_place(&sessions[1],core.world_ref(client,&info),wire.clock_interpolation_tick(&sessions[1].host,u32(tick)),nil,false)
        core.settle(&info,client,nil)
        switch tick {
        case 45:
            count,found:=taken(client)
            testing.expect(t,found && count==2,"the client has the entity with its component")
            config,replicated:=core.get(&server.objects,cell)
            testing.expect(t,replicated && config.audience==.Always && config.simulation==.Server)
            core.edit(&server.taken,cell).count=3
        case 89:
            count,_:=taken(client)
            testing.expect_value(t,count,u32(3))
        }
        core.settle(&info,server,nil)
        server_publish(&sessions[0],core.world_ref(server,&info),&outbox,u32(tick))
    }
    testing.expect_value(t,problems[0].count,0)
    testing.expect_value(t,problems[1].count,0)
}
