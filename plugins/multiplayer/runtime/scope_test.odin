package multiplayer

import "core:testing"
import "mirai:core"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/base"

@(test)
custom_relevance_replicates_an_entity_only_to_the_connections_the_game_names :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    worlds:[2]Net_Test_World
    apps:[2]host.App
    sessions:[2]Net_Session
    problems:core.Problems
    for &world,index in worlds {net_test_init(&world,&info);apps[index]={allocator=context.allocator,tick_dt=1.0/60}}
    defer for &world in worlds {info.destroy[.World](&world)}
    defer for &app in apps {host.app_world_scratch_free(&app);delete(app.worlds)}
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=5,endpoints=2,packets=1024}))
    defer wire.sim_network_destroy(&network)
    for &session,index in sessions {
        if !testing.expect(t,net_test_session(&session,&worlds[index],&info,&apps[index],&network,index,index==0?.Server:.Client)) {return}
    }
    defer for &session in sessions {session_destroy(&session)}
    sessions[0].problems=&problems
    testing.expect_value(t,wire.host_connect(&sessions[1].host,wire.address_memory(0)),wire.Error.None)
    world:=&worlds[0]
    secret:=net_test_body(world,&info,1,{0,0,0})
    hidden:=net_test_body(world,&info,2,{1,0,0})
    plain:=net_test_body(world,&info,3,{2,0,0})
    outbox:Net_Outbox;defer core.value_free(&outbox,type_info_of(Net_Outbox))
    connected:Connection
    secret_object,hidden_object:Object
    for tick in 1..<120 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        for command in wire.host_poll(&sessions[0].host) {
            if command.kind==.Connected {connected=command.connection}
        }
        wire.host_poll(&sessions[1].host)
        if tick==20 {
            testing.expect(t,connected!=0)
            // Named in the tick it becomes replicated, before the network made its object.
            core.add(&world.objects,secret,net_test_replicate(audience=.Custom))
            core.add(&world.objects,hidden,net_test_replicate(audience=.Custom))
            testing.expect(t,relevance_set(&sessions[0],secret,connected,true))
            testing.expect(t,relevance_set(&sessions[0],plain,connected,true))
            testing.expect(t,!relevance_set(&sessions[1],secret,connected,true))
        }
        if tick==80 {testing.expect(t,relevance_set(&sessions[0],secret,connected,false))}
        core.settle(&info,world,nil)
        server_publish(&sessions[0],core.world_ref(world,&info),&outbox,u32(tick))
        wire.host_update(&sessions[0].host,now)
        if tick==20 {
            secret_object=wire.object_of_user(&sessions[0].host,u64(secret))
            hidden_object=wire.object_of_user(&sessions[0].host,u64(hidden))
            testing.expect(t,secret_object!=0 && hidden_object!=0)
        }
        if tick==60 {
            testing.expect(t,wire.object_valid(&sessions[1].host,secret_object),"the connection it names receives it")
            testing.expect(t,!wire.object_valid(&sessions[1].host,hidden_object),"a connection it does not name never does")
        }
    }
    testing.expect(t,!wire.object_valid(&sessions[1].host,secret_object),"and loses it when the game says so")
    reported:=false
    for &problem in problems.entries[:problems.count] {reported||=problem.entity==plain && base.text_get(problem.code[:])=="net.relevance"}
    testing.expect(t,reported,"naming an entity that is not replicated is a problem")
    testing.expect_value(t,sessions[0].server.request_count,0)
}

@(test)
entities_of_the_same_frequency_take_turns_instead_of_publishing_together :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info);defer info.destroy[.World](&world)
    entities:[3]core.Entity
    for &e,i in entities {
        e=net_test_body(&world,&info,base.Entity_Id(i+1),{f32(i),0,0})
        core.add(&world.objects,e,net_test_replicate(audience=.Always,update_hz=20))
    }
    core.settle(&info,&world,nil)
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=3,endpoints=2,packets=64}))
    defer wire.sim_network_destroy(&network)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,0,.Server)) {return}
    defer session_destroy(&s)
    outbox:Net_Outbox
    defer core.value_free(&outbox,type_info_of(Net_Outbox))
    for tick in 1..<6 {server_publish(&s,core.world_ref(&world,&info),&outbox,u32(tick))}
    // Twenty times a second at 60 ticks: each once every three ticks, one of them in each tick.
    for tick in 6..<15 {
        for e in entities {core.get(&world.values,e).force=f32(tick)}
        before:=s.stats.fragments_published
        server_publish(&s,core.world_ref(&world,&info),&outbox,u32(tick))
        testing.expectf(t,s.stats.fragments_published-before==1,"tick %v published %v entities",tick,s.stats.fragments_published-before)
    }
}

// The parent on the network of child is its closest ancestor with Replicate:
// past middle while it does not replicate, middle while it does, and the
// root it is moved under after.
@(test)
the_parent_on_the_network_is_the_closest_replicated_ancestor :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer info.destroy[.World](&world)
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=9,endpoints=1,packets=64}))
    defer wire.sim_network_destroy(&network)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,0,.Server)) {return}
    defer session_destroy(&s)
    outbox:Net_Outbox
    defer core.value_free(&outbox,type_info_of(Net_Outbox))
    tick:u32
    publish :: proc(s:^Net_Session,w:^Net_Test_World,info:^core.World_Info,app:^host.App,outbox:^Net_Outbox,tick:^u32) {
        core.settle(info,w,nil)
        tick^+=1
        server_publish(s,core.world_ref(w,info),outbox,tick^)
        core.settle(info,w,nil)
    }
    object :: proc(s:^Net_Session,e:core.Entity) -> Object {return wire.object_of_user(&s.host,u64(e))}
    root:=net_test_body(&world,&info,1)
    middle:=net_test_body(&world,&info,2)
    child:=net_test_body(&world,&info,3)
    other:=net_test_body(&world,&info,4)
    core.add(&world.parents,middle,core.Parent{entity=root})
    core.add(&world.parents,child,core.Parent{entity=middle})
    // The child comes first in the rows: it is made in the publish after its ancestor's.
    core.add(&world.objects,child,net_test_replicate(audience=.Always))
    core.add(&world.objects,root,net_test_replicate(audience=.Custom))
    core.add(&world.objects,other,net_test_replicate(audience=.Always))
    publish(&s,&world,&info,&app,&outbox,&tick)
    testing.expect(t,object(&s,root)!=0 && object(&s,child)==0)
    publish(&s,&world,&info,&app,&outbox,&tick)
    child_object:=object(&s,child)
    if !testing.expect(t,child_object!=0) {return}
    slot:=&s.server.objects[object_index(child_object)]
    testing.expect_value(t,slot.parent,object(&s,root))
    testing.expect_value(t,slot.filter,wire.Filter.Always)
    ancestry:=s.server.ancestry
    publish(&s,&world,&info,&app,&outbox,&tick)
    testing.expect_value(t,s.server.ancestry,ancestry)

    core.add(&world.objects,middle,net_test_replicate(audience=.Always))
    publish(&s,&world,&info,&app,&outbox,&tick)
    testing.expect(t,object(&s,middle)!=0)
    testing.expect_value(t,slot.parent,object(&s,middle))
    testing.expect_value(t,slot.filter,wire.Filter.Always)

    core.remove(&world.objects,middle)
    publish(&s,&world,&info,&app,&outbox,&tick)
    testing.expect_value(t,object(&s,middle),Object(0))
    testing.expect_value(t,slot.parent,object(&s,root))

    core.add(&world.parents,middle,core.Parent{entity=other})
    publish(&s,&world,&info,&app,&outbox,&tick)
    testing.expect_value(t,slot.parent,object(&s,other))

    core.remove(&world.parents,child)
    publish(&s,&world,&info,&app,&outbox,&tick)
    testing.expect_value(t,slot.parent,Object(0))
    testing.expect_value(t,slot.filter,wire.Filter.Always)
    testing.expect_value(t,object(&s,child),child_object)
}
