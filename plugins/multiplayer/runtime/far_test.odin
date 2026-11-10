package multiplayer

import "core:testing"
import "mirai:core"
import "mirai:engine/render"
import "mirai:engine/scene"
import "mirai:host"
import wire "mirai:net"

// What navigation does on the server to an agent far from the players: off
// with core.Disabled, moved while off, and on again where it got. Its object
// stays while it is off, so the client keeps the entity it took for it, with
// what only the client gave it (its Mesh_Renderer), off while the server's is
// off. What navigation keeps of it (Nav_Far, Nav_Path) is not replicated:
// navigation runs on the server. What a section turns off (Section_Held) ends
// its object instead.
@(test)
an_entity_off_on_the_server_stays_off_on_the_clients_and_comes_back_where_it_got :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    worlds:[2]Net_Test_World
    shares:[2]Net_Test_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    for &world,index in worlds {
        net_test_init(&world,&info)
        // The base of every entity, as the generator makes it: it stays on with its entity off.
        world.transforms.base,world.worlds.base,world.identities.base,world.parents.base,world.names.base=true,true,true,true,true
        shares[index].info=&info
        apps[index]={allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
    }
    defer for &world in worlds {info.destroy[.World](&world)}
    server,client:=&worlds[0],&worlds[1]
    // Both ends loaded the agent with their scene; only the client draws it.
    agent:=core.create(&server.entities)
    core.add(&server.identities,agent,core.Id{5})
    core.add(&server.transforms,agent,core.Transform{rotation=1,scale={1,1,1}})
    core.add(&server.values,agent,Net_Test_Value{force=2})
    // Off by its section on the server.
    held:=core.create(&server.entities)
    core.add(&server.identities,held,core.Id{6})
    core.add(&server.transforms,held,core.Transform{rotation=1,scale={1,1,1}})
    core.add(&server.values,held,Net_Test_Value{force=3})
    core.settle(&info,server,nil)
    mine:=core.create(&client.entities)
    core.add(&client.identities,mine,core.Id{5})
    core.add(&client.transforms,mine,core.Transform{rotation=1,scale={1,1,1}})
    core.add(&client.statics,mine,render.Mesh_Renderer{})
    core.settle(&info,client,nil)
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=5,endpoints=2,packets=1024})) {return}
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
    // The entity the client has for an Id and where the server last put it.
    replica :: proc(s:^Net_Session,id:u64) -> (e:core.Entity,position:[3]f32,found:bool) {
        for r in s.client.replicas[:s.client.replica_high] {
            if r.object!=0 && u64(r.pose.id)==id {return r.entity,r.pose.position,true}
        }
        return
    }
    published:u64
    for tick in 1..<150 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],core.world_ref(server,&info),nil,wire.host_poll(&sessions[0].host),&server_events,&server.remote)
        client_commands(&sessions[1],core.world_ref(client,&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host),&client_events)
        client_place(&sessions[1],core.world_ref(client,&info),wire.clock_interpolation_tick(&sessions[1].host,u32(tick)),nil)
        core.settle(&info,client,nil)
        switch tick {
        case 21:
            core.add(&server.objects,agent,net_test_replicate(audience=.Always))
            core.add(&server.objects,held,net_test_replicate(audience=.Always))
        case 50:
            e,_,found:=replica(&sessions[1],5)
            testing.expect(t,found && e==mine,"the client took its own entity for the agent")
            _,_,found=replica(&sessions[1],6)
            testing.expect(t,found)
            core.add(&server.disabled,agent,core.Disabled{})
            core.add(&server.disabled,held,core.Disabled{})
            core.add(&server.held,held,scene.Section_Held{})
        case 60:
            published=sessions[0].stats.fragments_published
        case 70, 80:
            // Moved while off: nothing goes until it turns on.
            core.get(&server.transforms,agent).position={f32(tick-60),0,0}
        case 90:
            testing.expect_value(t,sessions[0].stats.fragments_published,published)
            e,_,found:=replica(&sessions[1],5)
            testing.expect(t,found && e==mine,"the replica stays while the server's is off")
            testing.expect(t,core.entity_off(&client.entities,mine),"off on the client while off on the server")
            testing.expect(t,core.raw_row(core.raw(&client.statics),mine)>=0,"its Mesh_Renderer stays, off")
            _,_,found=replica(&sessions[1],6)
            testing.expect(t,!found,"what its section turned off leaves the clients")
            testing.expect_value(t,sessions[0].stats.objects,1)
            core.get(&server.transforms,agent).position={20,0,0}
            core.remove(&server.disabled,agent)
        case 149:
            e,position,found:=replica(&sessions[1],5)
            testing.expect(t,found && e==mine,"the same entity comes back")
            testing.expect(t,core.alive(&client.entities,mine) && !core.entity_off(&client.entities,mine),"on again")
            testing.expect(t,core.has(&client.statics,mine),"with its own Mesh_Renderer")
            testing.expectf(t,abs(position.x-20)<0.01,"the client has it at %v",position)
            value,has:=core.get(core.read(&client.values),mine)
            testing.expect(t,has && value.force==2)
        }
        core.settle(&info,server,nil)
        server_publish(&sessions[0],core.world_ref(server,&info),&outbox,u32(tick))
    }
    testing.expect_value(t,problems[0].count,0)
    testing.expect_value(t,problems[1].count,0)
}
