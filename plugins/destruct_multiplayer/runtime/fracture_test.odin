package destruct_multiplayer

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import destruct "plugins:destruct/runtime"
import multiplayer "plugins:multiplayer/runtime"
import render "mirai:engine/render"
import "mirai:engine/scene"
import "mirai:host"
import sim "plugins:physics/runtime/sim"
import fr "plugins:destruct/runtime/fracture"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/jobs"

// One end of a session with one destructible: its tables, its simulation and
// what this library keeps, stepped as the fixed loop does.
@(private="file")
End_World :: struct {
    using world:core.Test_World,
    using rows:destruct.Test_Destruct,
    objects:core.Table(multiplayer.Replicate),
    adoptions:multiplayer.Net_Adoptions,
    outbox:multiplayer.Net_Outbox,
    connections:multiplayer.Net_Connections,
    root:scene.Scene_Root,
}

@(private="file")
End :: struct {
    using w:End_World,
    using application:destruct.Test_Destruct_Host,
    net:Destruct_Net,
    session:multiplayer.Net_Session,
    tick:u64,
}

@(private="file")
end_init :: proc(t:^testing.T,f:^End,name:string,role:core.Network_Role) -> bool {
    folder:=base.test_folder(t,fmt.tprintf("destruct-net-%s",name))
    if folder=="" {return false}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    b:asset.Fracture_Builder;asset.fracture_builder_init(&b);defer asset.fracture_builder_destroy(&b)
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube);geom.cube_build(&cube)
    for part in 0..<2 {asset.fracture_piece_add(&b,geom.mesh_buffer_view(&cube),{{f32(part)*1.02-.51,0,0},1,{1,1,1}},anchor=part==0)}
    if asset.fracture_connect_proximity(&b,.03,.5,10)!=.None {return false}
    if asset.fracture_save(fmt.tprintf("%s/source.fracture",folder),&types,asset.fracture_builder_desc(&b,{1,2}))!=.None {return false}
    if !core.test_world_init(t,&f.w,test_types) {return false}
    f.app.assets,f.app.allocator=&f.assets,context.allocator
    if !jobs.system_init(&f.app.jobs,{threads=0}) {return false}
    if !host.assets_init(&f.assets,{root=folder,capacity=32}) {return false}
    desc:=sim.world_desc_default();desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=16,32,64,4
    desc.hull_capacity=8
    f.settings={destructibles=2,pieces=32,connections=64}
    desc.character_capacity,desc.mesh_capacity,desc.heightfield_capacity=0,0,0
    if !sim.world_init(&f.physics.world,desc) {return false}
    f.physics.ready=true
    f.authority.role=role
    return true
}

@(private="file")
end_destroy :: proc(f:^End) {
    destruct.cache_destroy(f.app.assets,&f.app.jobs,&f.cache);jobs.system_destroy(&f.app.jobs)
    core.test_world_destroy(&f.w)
    host.assets_destroy(&f.assets)
    net_free(&f.net)
}

// A tick: the simulation, what this library asks of destruct, destruct, and what it sends.
@(private="file")
end_tick :: proc(f:^End,resimulating:=false) {
    sim.world_step(&f.physics.world,1.0/60)
    core.test_world_settle(&f.w)
    f.tick+=1
    time:=core.Time{dt=1.0/60,playing=true,tick=f.tick,resimulating=resimulating}
    commands:=core.commands_of(core.test_world_ref(&f.w))
    destruct_net_follow(core.ref(&f.authority),&f.net,time,&f.requests,core.ref(&f.fractures),core.read(&f.configs),core.read(&f.states),core.read(&f.ids),core.ref(&f.root))
    destruct.test_step(&f.rows,&f.application,commands,time)
    core.test_world_settle(&f.w)
    destruct_net_send(core.ref(&f.authority),&f.net,time,&f.outbox,&f.adoptions,core.ref(&f.session),core.ref(&f.connections),core.ref(&f.events),core.ref(&f.physics),core.ref(&f.fractures),commands,
        core.read(&f.states),core.read(&f.ids),core.read(&f.objects),core.ref(&f.entities),core.ref(&f.root),&f.problems)
    core.test_world_settle(&f.w)
}

// What a correction brings back of an end: its World, at the tick it was saved.
@(private="file")
Saved :: struct {
    w:End_World,
    tick:u64,
}

@(private="file")
end_save :: proc(t:^testing.T,saved:^Saved,f:^End) -> bool {
    if !core.test_world_init(t,&saved.w,test_types) {return false}
    core.test_world_settle(&f.w)
    saved.tick=f.tick
    return core.test_world_copy(&saved.w,&f.w)
}

@(private="file")
end_restore :: proc(f:^End,saved:^Saved) -> bool {
    f.tick=saved.tick
    return core.test_world_copy(&f.w,&saved.w)
}

@(private="file")
saved_destroy :: proc(saved:^Saved) {core.test_world_destroy(&saved.w)}

// The destructible of an end, whole, with the Id both ends give it.
@(private="file")
end_whole :: proc(f:^End) -> core.Entity {
    config:=destruct.destructible();config.fracture={1,2};config.debris_volume=0
    e:=core.create(&f.entities)
    core.add(&f.configs,e,config);core.add(&f.colliders,e,destruct.collider_fracture());core.add(&f.transforms,e,core.TRANSFORM_IDENTITY)
    core.add(&f.meshes,e,render.Mesh_Renderer{shape=.Cube});core.add(&f.ids,e,core.Id{42})
    return e
}

// A server and a client of one destructible that falls apart when the server strains it at tick 3.
@(private="file")
end_pair :: proc(t:^testing.T,a,b:^End,name:string) -> (server,client:core.Entity,ok:bool) {
    if !testing.expect(t,end_init(t,a,fmt.tprintf("%s-server",name),.Server)) {return}
    if !testing.expect(t,end_init(t,b,fmt.tprintf("%s-client",name),.Client)) {return}
    server,client=end_whole(a),end_whole(b)
    for _ in 0..<2 {end_tick(a);end_tick(b)}
    destruct.strain(&a.requests,server,{},4,1000)
    end_tick(a)
    return server,client,true
}

// What the server sent, as the client receives it.
@(private="file")
end_received :: proc(a:^End) -> (events:multiplayer.Net_Events) {
    for item in core.take(&a.outbox.queue) {
        core.push(&events.received,multiplayer.Received{type=item.type,size=item.size,data=item.data})
    }
    return
}

@(test)
a_fracture_of_the_server_breaks_the_client_alike :: proc(t:^testing.T) {
    a,b:End
    defer end_destroy(&a)
    defer end_destroy(&b)
    server,client,ok:=end_pair(t,&a,&b,"alike")
    if !ok {return}
    events:=end_received(&a)
    defer core.value_free(&events,type_info_of(multiplayer.Net_Events))
    rewinds:multiplayer.Net_Rewinds
    defer delete(rewinds.queue.items)
    destruct_net_receive(core.ref(&events),core.ref(&b.authority),&b.net,{tick=b.tick+1},&rewinds,core.ref(&b.root),&b.problems)
    testing.expect_value(t,len(rewinds.queue.items),0)
    end_tick(&b)
    testing.expect_value(t,core.at(&b.states,core.row_of(&b.states,client)).sequence,u32(1))
    testing.expect_value(t,fr.destructible_check(&b.fractures.fracture,core.at(&b.states,core.row_of(&b.states,client)).handle),fr.destructible_check(&a.fractures.fracture,core.at(&a.states,core.row_of(&a.states,server)).handle))
    testing.expect_value(t,b.net.stats.desyncs,u64(0))
    testing.expect_value(t,a.net.stats.sent,u64(1))
}

@(test)
a_correction_that_goes_back_before_a_fracture_applies_it_where_it_was_first_applied :: proc(t:^testing.T) {
    a,b:End
    defer end_destroy(&a)
    defer end_destroy(&b)
    _,client,ok:=end_pair(t,&a,&b,"present")
    if !ok {return}
    saved:Saved
    defer saved_destroy(&saved)
    testing.expect(t,end_save(t,&saved,&b))
    for _ in 3..=7 {end_tick(&b)}
    events:=end_received(&a)
    defer core.value_free(&events,type_info_of(multiplayer.Net_Events))
    rewinds:multiplayer.Net_Rewinds
    defer delete(rewinds.queue.items)
    destruct_net_receive(core.ref(&events),core.ref(&b.authority),&b.net,{tick=b.tick+1},&rewinds,core.ref(&b.root),&b.problems)
    for _ in 8..=12 {end_tick(&b)}
    testing.expect_value(t,core.at(&b.states,core.row_of(&b.states,client)).sequence,u32(1))
    hash:=sim.world_hash(&b.physics.world)~fr.fracture_hash(&b.fractures.fracture)
    testing.expect(t,end_restore(&b,&saved))
    for _ in 3..=12 {end_tick(&b,true)}
    testing.expect_value(t,core.at(&b.states,core.row_of(&b.states,client)).sequence,u32(1))
    testing.expect_value(t,sim.world_hash(&b.physics.world)~fr.fracture_hash(&b.fractures.fracture),hash)
}

@(test)
a_fracture_of_a_tick_the_client_simulated_asks_to_go_back_and_is_applied_at_its_tick :: proc(t:^testing.T) {
    a,b:End
    defer end_destroy(&a)
    defer end_destroy(&b)
    _,client,ok:=end_pair(t,&a,&b,"rewind")
    if !ok {return}
    saved:Saved
    defer saved_destroy(&saved)
    testing.expect(t,end_save(t,&saved,&b))
    for _ in 3..=7 {end_tick(&b)}
    events:=end_received(&a)
    defer core.value_free(&events,type_info_of(multiplayer.Net_Events))
    rewinds:multiplayer.Net_Rewinds
    defer delete(rewinds.queue.items)
    destruct_net_receive(core.ref(&events),core.ref(&b.authority),&b.net,{tick=b.tick+1},&rewinds,core.ref(&b.root),&b.problems)
    asked:=core.take(&rewinds.queue)
    if !testing.expect_value(t,len(asked),1) || !testing.expect_value(t,asked[0],u32(3)) {return}
    // The correction it asked for: from the world as tick 3 found it.
    testing.expect(t,end_restore(&b,&saved))
    end_tick(&b,true)
    testing.expect_value(t,core.at(&b.states,core.row_of(&b.states,client)).sequence,u32(1))
    for _ in 4..=7 {end_tick(&b,true)}
    for _ in 8..=12 {end_tick(&b)}
    hash:=sim.world_hash(&b.physics.world)~fr.fracture_hash(&b.fractures.fracture)
    testing.expect(t,end_restore(&b,&saved))
    for _ in 3..=12 {end_tick(&b,true)}
    testing.expect_value(t,sim.world_hash(&b.physics.world)~fr.fracture_hash(&b.fractures.fracture),hash)
}

// A connection that enters the world of the server, as the fixed functions
// read it in the tick, gets the state of the broken destructibles.
@(test)
a_connection_that_enters_the_world_gets_the_state_of_what_is_broken :: proc(t:^testing.T) {
    a,b:End
    defer end_destroy(&a)
    defer end_destroy(&b)
    _,_,ok:=end_pair(t,&a,&b,"arrives")
    if !ok {return}
    clear(&a.outbox.queue.items)
    connection:=multiplayer.Connection(7)
    core.push(&a.connections.events,multiplayer.Connection_Event{kind=.Connected,connection=connection})
    end_tick(&a)
    testing.expect_value(t,len(a.outbox.queue.items),0)
    core.queue_clear(&a.connections.events)
    core.push(&a.connections.events,multiplayer.Connection_Event{kind=.Entered,connection=connection})
    end_tick(&a)
    states:=0
    for item in a.outbox.queue.items {
        if chunk,is:=multiplayer.event_read(multiplayer.Received{type=item.type,size=item.size,data=item.data},Net_State);is && item.to==connection {
            states+=1
            testing.expect_value(t,chunk.sequence,u32(1))
        }
    }
    testing.expect(t,states>0,"the state of what is broken goes to the connection that entered the world")
    clear(&a.outbox.queue.items)
    core.queue_clear(&a.connections.events)
    end_tick(&a)
    testing.expect_value(t,len(a.outbox.queue.items),0)
}

// A scene that replaces the world of a client takes what this library knew of
// the world before: the log of a destructible does not break the one of the
// new world with its Id. A server that loads a game where it is broken sends
// its state to each connection that enters its world.
@(test)
a_scene_that_replaces_the_world_forgets_its_logs_and_the_server_sends_what_is_broken :: proc(t:^testing.T) {
    a,b,c:End
    defer end_destroy(&a)
    defer end_destroy(&b)
    defer end_destroy(&c)
    server,client,ok:=end_pair(t,&a,&b,"scene")
    if !ok {return}
    events:=end_received(&a)
    defer core.value_free(&events,type_info_of(multiplayer.Net_Events))
    rewinds:multiplayer.Net_Rewinds
    defer delete(rewinds.queue.items)
    destruct_net_receive(core.ref(&events),core.ref(&b.authority),&b.net,{tick=b.tick+1},&rewinds,core.ref(&b.root),&b.problems)
    end_tick(&b)
    if !testing.expect_value(t,core.at(&b.states,core.row_of(&b.states,client)).sequence,u32(1)) {return}

    // The same scene again on the client: a new World, and what the application keeps for it goes on.
    if !testing.expect(t,end_init(t,&c,"scene-again",.Client)) {return}
    again:=end_whole(&c)
    c.net,b.net=b.net,{}
    c.root.changes=b.root.changes+1
    c.tick=b.tick
    for _ in 0..<4 {end_tick(&c)}
    testing.expect_value(t,core.at(&c.states,core.row_of(&c.states,again)).sequence,u32(0))
    testing.expect_value(t,len(c.net.links),0)

    // The server loads a game where it is broken: a scene that replaces its world.
    a.root.changes+=1
    clear(&a.outbox.queue.items)
    connection:=multiplayer.Connection(7)
    core.push(&a.connections.events,multiplayer.Connection_Event{kind=.Entered,connection=connection})
    end_tick(&a)
    core.queue_clear(&a.connections.events)
    for item in a.outbox.queue.items {testing.expect_value(t,item.to,connection)}
    chunks:=end_received(&a)
    defer core.value_free(&chunks,type_info_of(multiplayer.Net_Events))
    destruct_net_receive(core.ref(&chunks),core.ref(&c.authority),&c.net,{tick=c.tick+1},&rewinds,core.ref(&c.root),&c.problems)
    for _ in 0..<2 {end_tick(&c)}
    testing.expect_value(t,core.at(&c.states,core.row_of(&c.states,again)).sequence,u32(1))
    testing.expect_value(t,fr.destructible_check(&c.fractures.fracture,core.at(&c.states,core.row_of(&c.states,again)).handle),fr.destructible_check(&a.fractures.fracture,core.at(&a.states,core.row_of(&a.states,server)).handle))
}
