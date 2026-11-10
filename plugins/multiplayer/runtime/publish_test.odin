package multiplayer

import "core:log"
import "core:math"
import "core:strings"
import "core:testing"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:host"
import wire "mirai:net"

@(test)
references_wait_for_the_objects_interval_after_targets_register_or_are_replaced :: proc(t:^testing.T) {
    net_test_late_reference(t,false)
}

@(test)
replicated_joints_suspend_missing_targets_and_preserve_explicit_world_targets :: proc(t:^testing.T) {
    net_test_late_reference(t,true)
}

@(test)
state_and_owner_refused_by_a_full_frame_are_sent_on_the_next_interval :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    worlds:[2]Net_Test_World
    shares:[2]Net_Test_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    entities:[2][2]core.Entity // per world: the one moved and the one given an owner while the frame is full
    for &world,index in worlds {
        net_test_init(&world,&info)
        entities[index]={net_test_body(&world,&info,1),net_test_body(&world,&info,2,{1,0,0})}
        shares[index].info=&info
        apps[index]={allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
    }
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=73,endpoints=2,packets=1024})) {return}
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
    connected:Connection
    for tick in 1..<80 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],core.world_ref(server,&info),nil,wire.host_poll(&sessions[0].host),&server_events,&server.remote)
        for event in net_test_arrived(&sessions[0]) {if event.kind==.Connected {connected=event.connection}}
        client_commands(&sessions[1],core.world_ref(client,&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host),&client_events)
        switch tick {
        case 21:
            for e in entities[0] {core.add(&server.objects,e,net_test_replicate(audience=.Always))}
        case 40:
            testing.expect(t,connected!=0)
            core.edit(&server.transforms,entities[0][0]).position={5,0,0}
            net_test_own(server,entities[0][1],connected)
            core.settle(&info,server,nil)
            object:=wire.object_of_user(&sessions[0].host,u64(entities[0][0]))
            error:wire.Error
            for _ in 0..=sessions[0].host.desc.frame_ops {error=wire.object_set_priority(&sessions[0].host,object,1)}
            testing.expect_value(t,error,wire.Error.Full)
        case 79:
            moved,_:=core.get(&client.links,entities[1][0])
            r:=replica_of(&sessions[1],moved.object)
            testing.expect(t,r!=nil && abs(r.pose.position.x-5)<1e-3)
            link,_:=core.get(&client.links,entities[1][1])
            owned:=replica_of(&sessions[1],link.object)
            testing.expect(t,owned!=nil && owned.role==.Predicted)
        }
        core.settle(&info,server,nil)
        server_publish(&sessions[0],core.world_ref(server,&info),&outbox,u32(tick))
    }
    testing.expect_value(t,problems[0].count,0)
    testing.expect_value(t,problems[1].count,0)
}

@(private)
net_test_late_reference :: proc(t:^testing.T,body:bool) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    worlds:[2]Net_Test_World
    shares:[2]Net_Test_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    entities:[2][2]core.Entity
    for &world,index in worlds {
        net_test_init(&world,&info)
        entities[index][0]=net_test_body(&world,&info,1)
        entities[index][1]=net_test_body(&world,&info,2,{1,0,0})
        for e in entities[index] {core.edit(&world.values,e).force=0}
        shares[index].info=&info
        apps[index]={allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
        if body {net_test_physics(&world,&shares[index],&apps[index])}
    }
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
    defer for &share in shares {phys.collider_meshes_destroy(&share.colliders)}
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=72,endpoints=2,packets=1024})) {return}
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
    source,target:=entities[0][0],entities[0][1]
    replica,visitor:=entities[1][0],entities[1][1]
    connected:Connection
    for tick in 1..<90 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],core.world_ref(server,&info),nil,wire.host_poll(&sessions[0].host),&server_events,&server.remote)
        for event in net_test_arrived(&sessions[0]) {if event.kind==.Connected {connected=event.connection}}
        client_commands(&sessions[1],core.world_ref(client,&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host),&client_events)
        switch tick {
        case 21:
            core.edit(&server.values,source).target=target
            core.add(&server.objects,source,net_test_replicate(audience=.Always,update_hz=10,simulation=body?.Lent:.Server))
            if body {
                joint:=phys.joint_fixed(target)
                joint.a=source
                core.add(&server.joints,source,joint)
                core.settle(&info,server,nil)
                net_test_physics(server,&shares[0],&apps[0])
            }
        case 31:
            if body {testing.expect(t,authority_grant(&sessions[0],source,connected))}
        case 34:
            value,_:=core.get(&client.values,replica)
            testing.expect_value(t,value.target,core.NONE)
            if body {
                testing.expect(t,!core.has(&client.joints,replica))
                net_test_physics(client,&shares[1],&apps[1])
                testing.expect_value(t,client.state.world.joint_count,i32(0))
            }
        case 35,56:
            core.add(&server.objects,target,net_test_replicate(audience=.Always))
            if tick==56 {visitor=net_test_body(client,&info,2,{1,0,0})}
        case 39,75:
            if !body {
                object:=wire.object_of_user(&sessions[0].host,u64(target))
                error:wire.Error
                for _ in 0..=sessions[0].host.desc.frame_ops {error=wire.object_set_priority(&sessions[0].host,object,1)}
                testing.expect_value(t,error,wire.Error.Full)
            }
        case 41:
            if body {testing.expect(t,authority_grant(&sessions[0],source,0))}
        case 46,70:
            value,_:=core.get(&client.values,replica)
            testing.expect_value(t,value.target,visitor)
            if body {
                joint,has:=core.get(&client.joints,replica)
                testing.expect(t,has && joint.b==visitor)
                net_test_physics(client,&shares[1],&apps[1])
                testing.expect_value(t,client.state.world.joint_count,i32(1))
            }
        case 47:
            core.remove(&server.objects,target)
        case 55:
            value,_:=core.get(&client.values,replica)
            testing.expect_value(t,value.target,core.NONE)
            if body {
                testing.expect(t,!core.has(&client.joints,replica))
                net_test_physics(client,&shares[1],&apps[1])
                testing.expect_value(t,client.state.world.joint_count,i32(0))
            }
        case 71:
            if body {
                joint:=phys.joint_fixed(core.NONE)
                joint.a=source
                core.add(&server.joints,source,joint)
                core.settle(&info,server,nil)
                net_test_physics(server,&shares[0],&apps[0])
            } else {core.edit(&server.values,source).target=core.NONE}
        case 84:
            if body {
                joint,has:=core.get(&client.joints,replica)
                testing.expect(t,has && joint.b==core.NONE)
                net_test_physics(client,&shares[1],&apps[1])
                testing.expect_value(t,client.state.world.joint_count,i32(1))
            } else {
                value,_:=core.get(&client.values,replica)
                testing.expect_value(t,value.target,core.NONE)
            }
        }
        core.settle(&info,server,nil)
        server_publish(&sessions[0],core.world_ref(server,&info),&outbox,u32(tick))
    }
    testing.expect_value(t,problems[0].count,0)
    testing.expect_value(t,problems[1].count,0)
}

@(test)
a_body_replicates_the_collision_and_contact_rules_of_its_collider :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    worlds:[2]Net_Test_World
    shares:[2]Net_Test_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    entities:[2][2]core.Entity // per world: the body whose collider changes, and the one its group names
    for &world,index in worlds {
        net_test_init(&world,&info)
        entities[index]={net_test_body(&world,&info,1),net_test_body(&world,&info,2,{1,0,0})}
        shares[index].info=&info
        apps[index]={allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
    }
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
    defer for &share in shares {phys.collider_meshes_destroy(&share.colliders)}
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=74,endpoints=2,packets=1024})) {return}
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
    changed:=phys.collider_box({0.1,0.1,0.1})
    changed.preset,changed.surface_speed,changed.one_way,changed.dominance=1,{0,0,2},true,4
    changed.group=entities[0][1]
    for tick in 1..<70 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],core.world_ref(server,&info),nil,wire.host_poll(&sessions[0].host),&server_events,&server.remote)
        client_commands(&sessions[1],core.world_ref(client,&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host),&client_events)
        switch tick {
        case 21:
            for e in entities[0] {core.add(&server.objects,e,net_test_replicate(audience=.Always))}
        case 40:
            core.add(&server.colliders,entities[0][0],changed)
        case 69:
            collider,has:=core.get(&client.colliders,entities[1][0])
            expected:=changed
            expected.group=entities[1][1]
            testing.expectf(t,has && collider==expected,"the client holds %v",collider)
        }
        core.settle(&info,server,nil)
        server_publish(&sessions[0],core.world_ref(server,&info),&outbox,u32(tick))
    }
    testing.expect_value(t,problems[0].count,0)
    testing.expect_value(t,problems[1].count,0)
}

// An entity the server cannot replicate for lack of room names the capacity
// that ran out: the objects of max_objects, or the words of their states.
@(test)
an_object_the_host_has_no_room_for_names_the_capacity_to_raise :: proc(t:^testing.T) {
    full :: proc(t:^testing.T,settings:Net_Settings,entities:int) -> (problems:core.Problems,last:core.Entity) {
        info,described:=net_test_info(t)
        if !described {return}
        defer core.test_info_destroy(&info)
        world:Net_Test_World
        net_test_init(&world,&info);defer core.world_destroy(&info,.World,&world)
        for index in 0..<entities {
            last=core.create(&world.entities)
            core.add(&world.transforms,last,core.Transform{position={f32(index),0,0},rotation=1,scale={1,1,1}})
            core.add(&world.values,last,Net_Test_Value{})
            core.add(&world.objects,last,net_test_replicate(audience=.Always))
        }
        core.settle(&info,&world,nil)
        network:wire.Sim_Network
        testing.expect(t,wire.sim_network_init(&network,{seed=3,endpoints=2,packets=64}))
        defer wire.sim_network_destroy(&network)
        app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
        defer {host.app_world_scratch_free(&app);delete(app.worlds)}
        s:Net_Session
        if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,0,.Server,settings=settings)) {return}
        defer session_destroy(&s)
        s.problems=&problems
        outbox:Net_Outbox
        defer core.value_free(&outbox,type_info_of(Net_Outbox))
        server_publish(&s,core.world_ref(&world,&info),&outbox,1)
        return
    }
    named :: proc(t:^testing.T,problems:^core.Problems,e:core.Entity,code,field:string) {
        found:=core.problem_find(problems,e,code)
        if !testing.expectf(t,found!=nil,"no %s problem among %d",code,problems.count) {return}
        testing.expectf(t,strings.contains(core.problem_text(found),field),"%s",core.problem_text(found))
    }
    objects,last:=full(t,{max_objects=1,predicted_capacity=8,replication={history_seconds=0.25}},2)
    named(t,&objects,last,"net.objects_full","Net_Settings.max_objects")
    states,first:=full(t,{max_objects=8,predicted_capacity=8,replication={history_seconds=0.25,state_words=1}},1)
    named(t,&states,first,"net.states_full","Net_Settings.replication.state_words")
}

// Settings the host refuses name the field and the values it takes, not the host.
@(test)
settings_the_host_refuses_name_their_field_and_its_range :: proc(t:^testing.T) {
    refused :: proc(t:^testing.T,replication:wire.Replication_Desc,field,range:string) {
        info,described:=net_test_info(t)
        if !described {return}
        defer core.test_info_destroy(&info)
        world:Net_Test_World
        net_test_init(&world,&info);defer core.world_destroy(&info,.World,&world)
        app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
        defer {host.app_world_scratch_free(&app);delete(app.worlds)}
        s:Net_Session
        problems:core.Problems
        s.problems=&problems
        world.request={open={connect=text_of("127.0.0.1:9")}}
        settings:=Net_Settings{replication=replication}
        // The player is told with an error in the log, which would fail the test.
        logger:=context.logger
        context.logger=log.nil_logger()
        session_start(&s,core.world_ref(&world,&info),&app,&settings)
        context.logger=logger
        defer delete(s.reason_text,app.allocator)
        testing.expect(t,!s.host_ready && s.ended)
        found:=core.problem_find(&problems,core.NONE,"net.settings")
        if !testing.expect(t,found!=nil,"the session names what it refused") {return}
        text:=core.problem_text(found)
        testing.expectf(t,strings.contains(text,field) && strings.contains(text,range),"%s",text)
        testing.expectf(t,strings.contains(s.reason_text,field),"%s",s.reason_text)
    }
    text_of :: proc(s:string) -> (out:[96]u8) {
        copy(out[:],s)
        return
    }
    refused(t,{hysteresis=300},"Net_Settings.replication.hysteresis","256")
    refused(t,{cell_size=math.INF_F32},"Net_Settings.replication.cell_size","finite")
}

// The port of the game is a setting: 0 is DEFAULT_PORT, and one that is not a
// UDP port does not open the network and says so.
@(test)
the_port_of_the_game_is_a_setting_that_must_be_a_udp_port :: proc(t:^testing.T) {
    port,valid:=settings_port({})
    testing.expect(t,port==DEFAULT_PORT && valid)
    port,valid=settings_port({port=40000})
    testing.expect(t,port==40000 && valid)
    _,valid=settings_port({port=70000})
    testing.expect(t,!valid)
    testing.expect_value(t,settings_resolve({},1.0/60).port,DEFAULT_PORT)
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info);defer core.world_destroy(&info,.World,&world)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    s:Net_Session
    problems:core.Problems
    s.problems=&problems
    world.request={open={server=true}}
    settings:=Net_Settings{port=70000}
    logger:=context.logger
    context.logger=log.nil_logger()
    session_start(&s,core.world_ref(&world,&info),&app,&settings)
    context.logger=logger
    defer delete(s.reason_text,app.allocator)
    testing.expect(t,!s.host_ready && s.ended && !s.udp.open)
    found:=core.problem_find(&problems,core.NONE,"net.settings")
    if !testing.expect(t,found!=nil,"the session names the port it refused") {return}
    testing.expectf(t,strings.contains(core.problem_text(found),"Net_Settings.port"),"%s",core.problem_text(found))
}
