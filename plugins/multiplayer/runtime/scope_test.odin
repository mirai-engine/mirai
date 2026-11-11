package multiplayer

import "core:testing"
import "mirai:core"
import inp "mirai:engine/input"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/base"

// Who sees what is data: the bits of an entity (Visibility.mask) against those
// of the seat of each connection (Visibility.sees), read when they change: a
// tick where neither changes reads no object, though input writes the seats.
@(test)
visibility_replicates_an_entity_only_to_the_connections_whose_seat_shares_a_bit :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    worlds:[2]Net_Test_World
    apps:[2]host.App
    sessions:[2]Net_Session
    for &world,index in worlds {net_test_init(&world,&info);apps[index]={allocator=context.allocator,tick_dt=1.0/60}}
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
    defer for &app in apps {host.app_world_scratch_free(&app);delete(app.worlds)}
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=5,endpoints=2,packets=1024}))
    defer wire.sim_network_destroy(&network)
    for &session,index in sessions {
        if !testing.expect(t,net_test_session(&session,&worlds[index],&info,&apps[index],&network,index,index==0?.Server:.Client)) {return}
    }
    defer for &session in sessions {session_destroy(&session)}
    testing.expect_value(t,wire.host_connect(&sessions[1].host,wire.address_memory(0)),wire.Error.None)
    world:=&worlds[0]
    entities:=[3]core.Entity{net_test_body(world,&info,1,{0,0,0}),net_test_body(world,&info,2,{1,0,0}),net_test_body(world,&info,3,{2,0,0})}
    masks:=[3]u32{0b01,0b10,0}
    // The bits of the seat from a tick on, and which of the entities its connection has 40 ticks later.
    Case :: struct {tick:int,sees:u32,has:[3]bool}
    cases:=[]Case{
        {20,0,{false,false,true}},   // no Visibility on the seat: what asks for no bit
        {60,0b01,{true,false,true}},
        {100,0b10,{false,true,true}},
        {140,0b11,{true,true,true}},
    }
    outbox:Net_Outbox;defer core.value_free(&outbox,type_info_of(Net_Outbox))
    connected:Connection
    seat:core.Entity
    objects:[3]Object
    reads:int
    for tick in 1..<180 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        commands:=wire.host_poll(&sessions[0].host)
        for command in commands {
            if command.kind==.Connected {connected=command.connection}
        }
        server_commands(&sessions[0],core.world_ref(world,&info),nil,commands,&world.remote)
        wire.host_poll(&sessions[1].host)
        for c,index in cases {
            if tick==c.tick+40 {
                for e,k in entities {
                    testing.expectf(t,wire.object_valid(&sessions[1].host,objects[k])==c.has[k],"case %d: entity %d of bits %b reached a seat of bits %b: %v",index,k,masks[k],c.sees,!c.has[k])
                }
            }
            if tick!=c.tick {continue}
            if index==0 {
                if !testing.expect(t,connected!=0) {return}
                // In the tick they become replicated, before the network made their objects.
                for e,k in entities {
                    core.add(&world.objects,e,net_test_replicate(audience=.Always))
                    if masks[k]!=0 {core.add(&world.visibility,e,Visibility{mask=masks[k]})}
                }
                seat=core.create(&world.entities)
                core.add(&world.seats,seat,inp.Seat{peer=u64(connected)})
            } else {
                core.add(&world.visibility,seat,Visibility{sees=c.sees})
            }
        }
        // As input writes the seats every tick.
        if seat!=core.NONE {_=core.edit(&world.seats,seat)}
        core.settle(&info,world,nil)
        server_publish(&sessions[0],core.world_ref(world,&info),&outbox,u32(tick))
        wire.host_update(&sessions[0].host,now)
        if tick==150 {reads=sessions[0].server.visibility_reads}
        if tick==20 {
            for e,k in entities {objects[k]=wire.object_of_user(&sessions[0].host,u64(e))}
            testing.expect(t,objects[0]!=0 && objects[1]!=0 && objects[2]!=0)
        }
    }
    testing.expectf(t,reads>0 && sessions[0].server.visibility_reads==reads,"the idle ticks after 150 read %d objects",sessions[0].server.visibility_reads-reads)
}

@(test)
entities_of_the_same_frequency_take_turns_instead_of_publishing_together :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info);defer core.world_destroy(&info,.World,&world)
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
        for e in entities {core.edit(&world.values,e).force=f32(tick)}
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
    defer test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
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
    core.add(&world.objects,root,net_test_replicate(audience=.Owner))
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
