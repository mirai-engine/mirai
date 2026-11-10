package multiplayer

import "core:strings"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:engine/scene"
import "mirai:host"
import wire "mirai:net"
import phys "plugins:physics/runtime"
import "mirai:std/base"

@(private="file") LEVEL_A :: base.Asset_Id{0xa,1}
@(private="file") LEVEL_B :: base.Asset_Id{0xb,1}
@(private="file") LEAD :: 8 // ticks the client runs ahead of the server

// A server (0) and a client (1) of worlds the generator would make: the
// messages of the session in the protocol, replicated seats, the scene of
// each and what its loads would do.
@(private="file")
Pair :: struct {
    info:core.World_Info,
    worlds:[2]Net_Test_World,
    shares:[2]Net_Test_Shared,
    apps:[2]host.App,
    sessions:[2]Net_Session,
    problems:[2]core.Problems,
    network:wire.Sim_Network,
    bindings:input.Input_Map,
    now:f64,
    tick:u64,
}

@(private="file")
pair_init :: proc(t:^testing.T,p:^Pair,server_scene,client_scene:base.Asset_Id,follows:=true) -> bool {
    p.info=net_test_info(t,follows=follows) or_return
    for &world,index in p.worlds {
        net_test_init(&world,&p.info)
        p.shares[index].info=&p.info
        p.apps[index]={info=&p.info,allocator=context.allocator,tick_dt=1.0/60,shared=&p.shares[index]}
        net_test_physics(&world,&p.shares[index],&p.apps[index])
        world.root={scene=index==0?server_scene:client_scene,changes=1}
    }
    if !testing.expect(t,wire.sim_network_init(&p.network,{seed=31,endpoints=2,packets=512})) {return false}
    for &session,index in p.sessions {
        if !testing.expect(t,net_test_session(&session,&p.worlds[index],&p.info,&p.apps[index],&p.network,index,index==0?.Server:.Client)) {return false}
        if !testing.expect_value(t,session.follows,follows) {return false}
        session.problems=&p.problems[index]
        p.shares[index].session=&session
    }
    p.worlds[1].identity.secret={42,0}
    return testing.expect_value(t,wire.host_connect(&p.sessions[1].host,wire.address_memory(0)),wire.Error.None)
}

@(private="file")
pair_destroy :: proc(p:^Pair) {
    for &session in p.sessions {session_destroy(&session);delete(session.reason_text)}
    wire.sim_network_destroy(&p.network)
    for &world in p.worlds {core.world_destroy(&p.info,.World,&world)}
    for &app in p.apps {host.app_world_scratch_free(&app);delete(app.worlds)}
    for &share in p.shares {phys.collider_meshes_destroy(&share.colliders)}
    delete(p.info.messages)
    core.test_info_destroy(&p.info)
}

// A frame of both ends as the loop runs it: what arrived, the seats of the
// server and, unless paused, a tick each.
@(private="file")
pair_frame :: proc(p:^Pair,ticks:=true) {
    p.now+=1.0/60
    wire.sim_network_advance(&p.network,p.now)
    for &session in p.sessions {
        if session.host_ready {wire.host_update(&session.host,p.now)}
    }
    server,client:=&p.worlds[0],&p.worlds[1]
    refs:=[2]core.World_Ref{core.world_ref(server,&p.info),core.world_ref(client,&p.info)}
    for &session,index in p.sessions {
        session.now=p.now
        world_follow(&session,refs[index])
    }
    server_commands(&p.sessions[0],refs[0],p.apps[0].assets,wire.host_poll(&p.sessions[0].host),&server.received,&server.remote)
    if p.sessions[1].host_ready {
        client_commands(&p.sessions[1],refs[1],p.apps[1].assets,p.apps[1].allocator,wire.host_poll(&p.sessions[1].host),&client.received)
        if !p.sessions[1].ended {client_clock(&p.sessions[1],refs[1],&p.apps[1])}
        core.clock_requests(&client.clock_requests,&client.clock,core.ref(&client.network),&p.problems[1])
    }
    net_seats({entities=&server.entities},&server.seats,&server.absents,&server.disabled,&server.objects,&server.transforms,nil,core.read(&server.links),
        core.ref(&p.bindings),core.ref(&server.remote),core.ref(&server.network),core.ref(&server.hierarchy),{},server.time)
    core.settle(&p.info,server,nil)
    if ticks {
        p.tick+=1
        server.time.tick=p.tick
        net_test_fixed(server,&p.shares[0],nil,&p.apps[0])
        if p.sessions[1].host_ready && !p.sessions[1].ended {
            client.time.tick=p.tick+LEAD
            net_test_fixed(client,&p.shares[1],nil,&p.apps[1])
        }
    }
    server_world_update(&p.sessions[0])
    server_clock(&p.sessions[0],refs[0],false)
    for &session in p.sessions {
        if session.host_ready {wire.host_update(&session.host,p.now)}
    }
}

// An entity of the scene that replicates to every connection.
@(private="file")
pair_thing :: proc(w:^Net_Test_World,info:^core.World_Info,id:base.Entity_Id,replicated:bool) -> core.Entity {
    e:=core.create(&w.entities)
    core.add(&w.identities,e,core.Id{id})
    core.add(&w.transforms,e,core.Transform{position={f32(id),0,0},rotation=1,scale={1,1,1}})
    if replicated {core.add(&w.objects,e,net_test_replicate(audience=.Always))}
    core.settle(info,w,nil)
    return e
}

// What a load of the scene does to the world of an end: a World of its own
// with the scene, the run and the entities kept from the world it replaces
// (scene.load_end), and then the one in the other's place.
@(private="file")
pair_load :: proc(p:^Pair,index:int,id:base.Asset_Id,thing:base.Entity_Id) {
    w:=&p.worlds[index]
    loaded:=new(Net_Test_World)
    defer free(loaded)
    net_test_init(loaded,&p.info)
    defer core.world_destroy(&p.info,.World,loaded)
    pair_thing(loaded,&p.info,thing,index==0)
    to,from:=core.world_ref(loaded,&p.info),core.world_ref(w,&p.info)
    core.world_run_copy(to,from)
    kept:=make([dynamic]core.Entity,context.temp_allocator)
    if index==0 {append(&kept,..w.seats.entities[:])}
    if len(kept)>0 {core.world_union(to,from,core.NONE,nil,kept[:])}
    core.settle(&p.info,loaded,nil)
    loaded.root={scene=id,changes=w.root.changes+1}
    core.world_swap(&p.info,w,loaded)
}

// The entities of a world the network links to objects.
@(private="file")
linked :: proc(w:^Net_Test_World) -> int {return core.count(&w.links)}

// The scene of the server replaces its world while a client is connected: the
// connection and its replicated seat stay, nothing of the old world names an
// entity of the new one, the client loads the scene, and only once it says so
// does the new world reach it.
@(test)
a_scene_change_keeps_the_players_and_replicates_the_new_world_once_the_client_loaded_it :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    p:=new(Pair)
    defer free(p)
    if !pair_init(t,p,LEVEL_A,LEVEL_A) {return}
    defer pair_destroy(p)
    server,client:=&p.worlds[0],&p.worlds[1]
    pair_thing(server,&p.info,1,true)
    adopted:=pair_thing(client,&p.info,1,false)
    for _ in 0..<60 {pair_frame(p)}
    if !testing.expect(t,p.sessions[1].client.answered,"a client already in the scene of its server says so") {return}
    connection:Connection
    for &peer in p.sessions[0].server.peers {if peer.connection!=0 {connection=peer.connection}}
    testing.expect_value(t,own_connection(core.ref(&p.sessions[1])),connection)
    testing.expect(t,core.has(&client.links,adopted),"the replica takes the entity of the scene with its Id")
    if !testing.expect_value(t,core.count(&server.seats),1) {return}
    testing.expect_value(t,core.at(&server.seats,0).player,player_id({42,0}))
    mirrored:=false
    for row in 0..<core.count(&client.seats) {
        value:=core.at(&client.seats,row)
        mirrored ||= value.peer==u64(connection) && value.player==0 && core.has(&client.links,core.entity_at(&client.seats,row))
    }
    testing.expect(t,mirrored,"the seat of the player reaches the client with its peer, without its id")

    pair_load(p,0,LEVEL_B,2)
    // The client is still loading: the new world does not reach it.
    for _ in 0..<20 {pair_frame(p)}
    testing.expect_value(t,len(client.scene_requests.queue.items),1)
    testing.expect_value(t,linked(client),0)
    testing.expect_value(t,core.count(&server.seats),1)
    testing.expect_value(t,core.at(&server.seats,0).peer,u64(connection))
    testing.expect_value(t,len(server.remote.entries),1)
    for &slot in p.sessions[0].server.objects {
        if slot.object!=0 {testing.expect(t,slot.entity==core.NONE || core.has(&server.objects,slot.entity),"no object of the old world names an entity of the new one")}
    }

    core.queue_clear(&client.scene_requests.queue)
    pair_load(p,1,LEVEL_B,2)
    for _ in 0..<60 {pair_frame(p)}
    testing.expect(t,p.sessions[1].client.answered)
    thing:=core.entity_of(&client.entities,2)
    testing.expect(t,thing!=core.NONE && core.has(&client.links,thing),"the new world reaches the client, on the entities of its scene")
    testing.expect_value(t,linked(client),2)
    testing.expect_value(t,p.problems[0].count,0)
    testing.expect_value(t,p.problems[1].count,0)
}

// A client that cannot load the scene of its server leaves, saying which scene
// it lacked and that it needs the assets of its server.
@(test)
a_client_without_the_scene_of_its_server_leaves_saying_so :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    p:=new(Pair)
    defer free(p)
    if !pair_init(t,p,LEVEL_B,LEVEL_A) {return}
    defer pair_destroy(p)
    client:=&p.worlds[1]
    asked:=false
    for _ in 0..<60 {
        pair_frame(p)
        if r:=client.scene_requests.queue.items;len(r)>0 {
            asked=r[0].scene==LEVEL_B
            core.queue_clear(&client.scene_requests.queue)
            core.push(&client.scene_results.queue,scene.Scene_Result{scene=LEVEL_B,error=.Not_Found})
        }
        if p.sessions[1].ended {break}
    }
    testing.expect(t,asked,"a client in another scene asks for that of its server")
    s:=&p.sessions[1]
    testing.expect(t,s.ended && s.reason==.Scene_Missing)
    testing.expect(t,strings.contains(s.reason_text,"000000000000000b") && strings.contains(s.reason_text,"assets of its server"),s.reason_text)
    left:=false
    for _ in 0..<30 {
        pair_frame(p,false)
        for event in net_test_arrived(&p.sessions[0]) {left ||= event.kind==.Disconnected && event.reason==.Scene_Missing}
    }
    testing.expect(t,left,"the server hears why")
}

// The server pauses and scales the time of the session: the clients follow it,
// and the tick a client estimates of the server stands still while it pauses.
@(test)
a_client_follows_the_pause_and_the_time_scale_of_its_server :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    p:=new(Pair)
    defer free(p)
    if !pair_init(t,p,{},{}) {return}
    defer pair_destroy(p)
    for _ in 0..<60 {pair_frame(p)}
    client:=&p.worlds[1]
    if !testing.expect(t,wire.clock_state(&p.sessions[1].host).synced) {return}
    p.worlds[0].clock.paused=true
    for _ in 0..<10 {pair_frame(p,false)}
    testing.expect(t,client.clock.paused,"the client pauses with its server")
    estimated:=wire.clock_state(&p.sessions[1].host).server
    for _ in 0..<60 {pair_frame(p,false)}
    testing.expectf(t,wire.clock_state(&p.sessions[1].host).server<=estimated+1,"the server stands at its tick: estimated %v, then %v",estimated,wire.clock_state(&p.sessions[1].host).server)
    p.worlds[0].clock={scale=0.5}
    for _ in 0..<10 {pair_frame(p)}
    testing.expect(t,!client.clock.paused && client.clock.scale==0.5)
    // A client asking for its own clock is refused.
    requests:core.Clock_Requests
    defer delete(requests.queue.items)
    core.pause(&requests)
    core.clock_requests(&requests,&client.clock,core.ref(&client.network),&p.problems[1])
    testing.expect(t,!client.clock.paused && p.problems[1].count==1)
}

// Who arrives and who leaves reaches the fixed functions in the first tick
// after it, once, however many frames go without a tick; a tick run again has
// those it had.
@(test)
the_connections_that_come_and_go_reach_the_first_tick_after_them :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
    s:Net_Session
    defer delete(s.arrived)
    ref:=core.world_ref(&world,&info)
    tick :: proc(ref:core.World_Ref,app:^host.App,s:^Net_Session,w:^Net_Test_World) -> int {
        net_tick_head(ref,app,s,&w.remote,&w.connections,nil)
        return len(w.connections.events.items)
    }
    append(&s.arrived,Connection_Event{kind=.Connected,connection=1})
    testing.expect_value(t,tick(ref,&app,&s,&world),1)
    testing.expect_value(t,tick(ref,&app,&s,&world),0)
    // Two frames without a tick.
    append(&s.arrived,Connection_Event{kind=.Connected,connection=2})
    append(&s.arrived,Connection_Event{kind=.Disconnected,connection=1,reason=.Timeout})
    testing.expect_value(t,tick(ref,&app,&s,&world),2)
    testing.expect_value(t,world.connections.events.items[1],Connection_Event{kind=.Disconnected,connection=1,reason=.Timeout})
    world.time.resimulating=true
    append(&s.arrived,Connection_Event{kind=.Connected,connection=3})
    testing.expect_value(t,tick(ref,&app,&s,&world),2)
    world.time.resimulating=false
    testing.expect_value(t,tick(ref,&app,&s,&world),1)
}

// The reference of a section, loaded or not.
@(private="file")
pair_section :: proc(w:^Net_Test_World,info:^core.World_Info,id:base.Entity_Id,loaded:bool) -> core.Entity {
    e:=core.create(&w.entities)
    core.add(&w.identities,e,core.Id{id})
    core.add(&w.transforms,e,core.TRANSFORM_IDENTITY)
    core.add(&w.references,e,scene.Scene_Reference{scene=LEVEL_A,loaded=loaded?LEVEL_A:{}})
    core.settle(info,w,nil)
    return e
}

// An entity of the scene of a section, which hangs from its reference.
@(private="file")
pair_member :: proc(w:^Net_Test_World,info:^core.World_Info,id:base.Entity_Id,section:core.Entity,replicated:bool) -> core.Entity {
    e:=pair_thing(w,info,id,replicated)
    core.add(&w.parents,e,core.Parent{section,0})
    core.settle(info,w,nil)
    return e
}

// A section of a client loads, with what it brings, or drops it.
@(private="file")
pair_load_section :: proc(w:^Net_Test_World,info:^core.World_Info,section:core.Entity,loaded:bool,member:=core.NONE) {
    core.edit(&w.references,section).loaded=loaded?LEVEL_A:{}
    if !loaded {core.destroy_tree(&w.entities,core.ref(&w.hierarchy),member)}
    core.settle(info,w,nil)
}

// The replica of a client whose pose has an Id, waiting or not.
@(private="file")
replica_with :: proc(s:^Net_Session,id:base.Entity_Id) -> ^Replica {
    for &r in s.client.replicas[:s.client.replica_high] {
        if r.object!=0 && r.pose.id==id {return &r}
    }
    return nil
}

// What hangs from a section reaches a client only while the client has that
// section loaded, as the client tells its server; what is of the root reaches it as always.
@(test)
what_is_in_a_section_reaches_a_client_while_it_has_the_section_loaded :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    p:=new(Pair)
    defer free(p)
    if !pair_init(t,p,LEVEL_A,LEVEL_A) {return}
    defer pair_destroy(p)
    server,client:=&p.worlds[0],&p.worlds[1]
    pair_thing(server,&p.info,1,true)
    pair_thing(client,&p.info,1,false)
    pair_member(server,&p.info,101,pair_section(server,&p.info,100,true),true)
    mirror:=pair_section(client,&p.info,100,false)
    for _ in 0..<60 {pair_frame(p)}
    testing.expect(t,replica_with(&p.sessions[1],1)!=nil)
    testing.expect(t,replica_with(&p.sessions[1],101)==nil,"what is in a section the client has not loaded does not reach it")

    member:=pair_member(client,&p.info,101,mirror,false)
    pair_load_section(client,&p.info,mirror,true)
    for _ in 0..<60 {pair_frame(p)}
    r:=replica_with(&p.sessions[1],101)
    testing.expect(t,r!=nil && !r.waits && r.entity==member && core.has(&client.links,member),"once loaded, its replica takes the entity of the section with its Id")

    pair_load_section(client,&p.info,mirror,false,member)
    for _ in 0..<60 {pair_frame(p)}
    testing.expect(t,replica_with(&p.sessions[1],101)==nil,"dropped, it leaves the client")
    testing.expect(t,replica_with(&p.sessions[1],1)!=nil)
    testing.expect_value(t,p.problems[0].count,0)
    testing.expect_value(t,p.problems[1].count,0)
}

// A replica of a section the client has not loaded, which reaches it anyway
// (a server that does not know what the client has), waits without an entity
// until the section loads, takes its entity then, and waits again when the
// section drops it.
@(test)
a_replica_of_a_section_that_is_not_loaded_waits_for_it :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    p:=new(Pair)
    defer free(p)
    if !pair_init(t,p,{},{},follows=false) {return}
    defer pair_destroy(p)
    server,client:=&p.worlds[0],&p.worlds[1]
    pair_member(server,&p.info,101,pair_section(server,&p.info,100,true),true)
    mirror:=pair_section(client,&p.info,100,false)
    for _ in 0..<60 {pair_frame(p)}
    c:=&p.sessions[1].client
    r:=replica_with(&p.sessions[1],101)
    if !testing.expect(t,r!=nil) {return}
    testing.expect(t,r.waits && r.entity==core.NONE && c.waiting==1)
    testing.expect_value(t,core.entity_of(&client.entities,101),core.NONE)

    member:=pair_member(client,&p.info,101,mirror,false)
    pair_load_section(client,&p.info,mirror,true)
    for _ in 0..<10 {pair_frame(p)}
    testing.expect(t,!r.waits && r.entity==member && core.has(&client.links,member) && c.waiting==0)

    pair_load_section(client,&p.info,mirror,false,member)
    for _ in 0..<10 {pair_frame(p)}
    testing.expect(t,r.object!=0 && r.waits && r.entity==core.NONE && c.waiting==1,"dropped by its section, it waits again")

    again:=pair_member(client,&p.info,101,mirror,false)
    pair_load_section(client,&p.info,mirror,true)
    for _ in 0..<10 {pair_frame(p)}
    testing.expect(t,!r.waits && r.entity==again && core.has(&client.links,again))
    testing.expect_value(t,p.problems[1].count,0)
}

// The reference of a section with a box, where it is in the world.
@(private="file")
pair_box :: proc(w:^Net_Test_World,info:^core.World_Info,id:base.Entity_Id,loaded:bool,position,extents:[3]f32) -> core.Entity {
    e:=pair_section(w,info,id,loaded)
    core.edit(&w.references,e).extents=extents
    core.edit(&w.transforms,e).position=position
    core.add(&w.worlds,e,core.World_Transform{transform={position=position,rotation=1,scale={1,1,1}}})
    core.settle(info,w,nil)
    return e
}

// An entity of the scene of a section, where it is in the world: the section
// is at the origin.
@(private="file")
pair_placed :: proc(w:^Net_Test_World,info:^core.World_Info,id:base.Entity_Id,section:core.Entity,position:[3]f32,replicated:bool) -> core.Entity {
    e:=pair_member(w,info,id,section,replicated)
    core.edit(&w.transforms,e).position=position
    core.add(&w.worlds,e,core.World_Transform{transform={position=position,rotation=1,scale={1,1,1}}})
    core.settle(info,w,nil)
    return e
}

// How many replicas of a client have a pose with an Id.
@(private="file")
replicas_with :: proc(s:^Net_Session,id:base.Entity_Id) -> (count:int) {
    for &r in s.client.replicas[:s.client.replica_high] {
        if r.object!=0 && r.pose.id==id {count+=1}
    }
    return
}

// What hangs from a section and is also in the box of another that overlaps
// it reaches a client that has either: once, with an entity of its own while
// the client has only the other, and with the entity of its section with its
// Id once that one loads. What is only in its own does not reach the client
// that lacks it.
@(test)
what_is_in_sections_that_overlap_reaches_a_client_that_has_either :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    p:=new(Pair)
    defer free(p)
    if !pair_init(t,p,LEVEL_A,LEVEL_A) {return}
    defer pair_destroy(p)
    server,client:=&p.worlds[0],&p.worlds[1]
    west:=pair_box(server,&p.info,100,true,{0,0,0},{10,10,10})
    pair_box(server,&p.info,200,true,{15,0,0},{10,10,10})
    pair_placed(server,&p.info,101,west,{8,0,0},true)
    pair_placed(server,&p.info,102,west,{-5,0,0},true)
    mirror_west:=pair_box(client,&p.info,100,false,{0,0,0},{10,10,10})
    pair_box(client,&p.info,200,true,{15,0,0},{10,10,10})
    for _ in 0..<60 {pair_frame(p)}
    c:=&p.sessions[1]
    r:=replica_with(c,101)
    if !testing.expect(t,r!=nil,"in the box of a section the client has, it reaches the client") {return}
    testing.expect_value(t,replicas_with(c,101),1)
    testing.expect_value(t,r.pose.sections,[wire.OBJECT_GROUPS]base.Entity_Id{100,200,0,0})
    own:=r.entity
    testing.expect(t,!r.waits && !r.adopted && core.alive(&client.entities,own) && core.has(&client.links,own),"without the section it hangs from, it has an entity of its own")
    testing.expect(t,replica_with(c,102)==nil,"what is only in a section the client lacks does not reach it")

    member:=pair_placed(client,&p.info,101,mirror_west,{8,0,0},false)
    pair_load_section(client,&p.info,mirror_west,true)
    for _ in 0..<60 {pair_frame(p)}
    testing.expect_value(t,replicas_with(c,101),1)
    testing.expect(t,r.object!=0 && r.adopted && r.entity==member && core.has(&client.links,member),"its section loaded, it takes the entity of the section with its Id")
    testing.expect(t,!core.alive(&client.entities,own),"and its own goes")
    testing.expect(t,replica_with(c,102)!=nil)
    testing.expect_value(t,p.problems[0].count,0)
    testing.expect_value(t,p.problems[1].count,0)
}

// What the server keeps of a section wins over what a client kept of it: as
// the client loads it, a replica takes the entity of the section with the
// state of the server, and what the server left a tombstone of goes; while
// the client has it, what the server destroys in it goes too, though the
// client never saw it.
@(test)
what_the_server_keeps_of_a_section_wins_over_what_a_client_kept :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    p:=new(Pair)
    defer free(p)
    if !pair_init(t,p,LEVEL_A,LEVEL_A) {return}
    defer pair_destroy(p)
    server,client:=&p.worlds[0],&p.worlds[1]
    room:=pair_section(server,&p.info,100,true)
    chest:=pair_member(server,&p.info,101,room,true)
    core.add(&server.values,chest,Net_Test_Value{force=5})
    hidden:=pair_member(server,&p.info,103,room,true)
    core.edit(&server.objects,hidden).audience=.Custom
    // A section the server dropped after a crate in it was destroyed.
    yard:=pair_section(server,&p.info,300,false)
    stone:=core.create(&server.entities)
    core.add(&server.identities,stone,core.Id{900})
    core.add(&server.parents,stone,core.Parent{yard,0})
    core.add(&server.tombstones,stone,scene.Tombstone{302})
    core.settle(&p.info,server,nil)
    mirror_room,mirror_yard:=pair_section(client,&p.info,100,false),pair_section(client,&p.info,300,false)
    for _ in 0..<60 {pair_frame(p)}

    // The client loads them as it kept them: the chest closed, the crate whole.
    kept_chest:=pair_member(client,&p.info,101,mirror_room,false)
    core.add(&client.values,kept_chest,Net_Test_Value{force=1})
    kept_hidden:=pair_member(client,&p.info,103,mirror_room,false)
    well:=pair_member(client,&p.info,301,mirror_yard,false)
    crate:=pair_member(client,&p.info,302,mirror_yard,false)
    pair_load_section(client,&p.info,mirror_room,true)
    pair_load_section(client,&p.info,mirror_yard,true)
    for _ in 0..<60 {pair_frame(p)}
    r:=replica_with(&p.sessions[1],101)
    testing.expect(t,r!=nil && r.entity==kept_chest,"the chest takes the entity it kept")
    value,_:=core.get(&client.values,kept_chest)
    testing.expect_value(t,value.force,5)
    testing.expect(t,!core.alive(&client.entities,crate),"what the server left a tombstone of goes")
    testing.expect(t,core.alive(&client.entities,well))
    testing.expect(t,replica_with(&p.sessions[1],103)==nil && core.alive(&client.entities,kept_hidden))

    core.destroy(&server.entities,hidden)
    core.settle(&p.info,server,nil)
    for _ in 0..<30 {pair_frame(p)}
    testing.expect(t,!core.alive(&client.entities,kept_hidden),"what the server destroys in it goes, seen or not")
    testing.expect(t,core.alive(&client.entities,kept_chest))
    testing.expect_value(t,p.problems[0].count,0)
    testing.expect_value(t,p.problems[1].count,0)
}
