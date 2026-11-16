package mirai_net

import "core:testing"
import "mirai:std/base"

@(private="file")
Event_Log :: struct {
    s:^Scene,
    count:[3]int,
    damage:[3][64]i32,
    from:[3][64]u64,
    object:[3][64]Object,
    created_first:[3]bool, // every event about an object came after the object
    role:[3]Role,
    role_changes,updates:[3]int,
    position:[3][3]f32,
}
@(private="file")
event_visit :: proc(client:int,command:^Command,user:rawptr) {
    log:=(^Event_Log)(user)
    host:=log.s.clients[client]
    #partial switch command.kind {
    case .Object_Created:
        // The client's own id for the replica: a thousand more than the server's.
        object_bind(host,command.object,u64(base.handle_index(base.Handle(command.object)))+2000)
        if command.role!=.Shown {log.role[client]=command.role}
    case .Role_Changed:
        log.role[client]=command.role
        log.role_changes[client]+=1
    case .Object_Updated:
        out:Test_Transform
        if object_read(host,command,0,&out) {log.position[client]=out.position}
        log.updates[client]+=1
    case .Event:
        hit:Test_Hit
        if !event_read(host,command,&hit) {return}
        n:=log.count[client]
        log.damage[client][n],log.from[client][n],log.object[client][n]=hit.damage,u64(hit.from),command.object
        if command.object!=0 && !object_valid(host,command.object) {log.created_first[client]=false}
        log.count[client]+=1
    }
}

@(test)
events_reach_the_replicas_of_an_object_once_and_in_order :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,2,{max_objects=64,filter_interval=1},seed=5);defer scene_destroy(s)
    log:=new(Event_Log);defer free(log)
    log.s,log.created_first=s,{true,true,true}
    transform:=Test_Transform{rotation=quaternion(w=1,x=0,y=0,z=0)}
    shooter,_:=object_create(s.server,{type=s.tp.prop,user=900,sources={0=&transform}})
    actor,_:=object_create(s.server,{type=s.tp.prop,user=901,sources={0=&transform},owner=s.on_server[0]})
    hidden,_:=object_create(s.server,{type=s.tp.prop,user=902,sources={0=&transform},filter=.Owner,owner=s.on_server[0]})
    // Sent in the tick the objects are created: they wait on the client for the replicas.
    hit:=Test_Hit{damage=1,from=base.Entity(900),point={1,2,3}}
    testing.expect_value(t,event_send(s.server,s.tp.hit,actor,&hit),Error.None)
    hit.damage=2
    testing.expect_value(t,event_send(s.server,s.tp.hit,hidden,&hit),Error.None)
    tick:=u32(0)
    for _ in 0..<6 {scene_tick(s,&tick,event_visit,log)}
    testing.expect_value(t,log.count,[3]int{2,1,0})
    hit.damage=3
    event_send(s.server,s.tp.hit,actor,&hit)
    hit.damage=4
    event_send(s.server,s.tp.hit,hidden,&hit)
    hit.damage=5
    event_send(s.server,s.tp.hit,0,&hit)
    hit.damage=6
    event_send(s.server,s.tp.hit,actor,&hit,s.on_server[1])
    for _ in 0..<6 {scene_tick(s,&tick,event_visit,log)}
    testing.expect_value(t,log.count,[3]int{5,4,0})
    // Events that waited for different replicas arrive as the replicas do; about one object they keep their order.
    testing.expect_value(t,log.damage[0][0]+log.damage[0][1],i32(3))
    for n in 2..<5 {testing.expect_value(t,log.damage[0][n],i32(n+1))}
    testing.expect_value(t,[4]i32{log.damage[1][0],log.damage[1][1],log.damage[1][2],log.damage[1][3]},[4]i32{1,3,5,6})
    testing.expect_value(t,log.object[0][3],hidden)
    testing.expect_value(t,log.object[0][4],Object(0))
    // The Entity field arrives as the client's own id for the shooter.
    testing.expect_value(t,log.from[0][2],u64(base.handle_index(base.Handle(shooter)))+2000)
    testing.expect_value(t,object_of_user(s.clients[0],log.from[0][2]),shooter)

    // Under loss every reliable event still arrives once and in order, and an
    // event sent with the object that carries it waits for the replica.
    harsh:=Sim_Conditions{latency=0.03,jitter=0.02,loss=0.3,duplicate=0.2,reorder=0.2,reorder_delay=0.03}
    for endpoint in 0..=2 {sim_endpoint_conditions(&s.w.sim,endpoint,harsh)}
    log.count={}
    late:Object
    for i in 0..<40 {
        if i==20 {late,_=object_create(s.server,{type=s.tp.prop,user=903,sources={0=&transform}})}
        if i==20 {
            hit.damage=1000
            event_send(s.server,s.tp.hit,late,&hit)
        }
        hit.damage=i32(100+i)
        event_send(s.server,s.tp.hit,actor,&hit)
        scene_tick(s,&tick,event_visit,log)
    }
    for _ in 0..<200 {scene_tick(s,&tick,event_visit,log)}
    for client in 0..<2 {
        testing.expect_value(t,log.count[client],41)
        expected:=i32(100)
        for n in 0..<log.count[client] {
            if log.damage[client][n]==1000 {
                testing.expect_value(t,log.object[client][n],late)
                continue
            }
            testing.expect_value(t,log.damage[client][n],expected)
            expected+=1
        }
    }
    testing.expect_value(t,log.created_first,[3]bool{true,true,true})
    for endpoint in 0..=2 {sim_endpoint_conditions(&s.w.sim,endpoint,{})}
    for _ in 0..<30 {scene_tick(s,&tick,event_visit,log)}

    // Clients send only what the protocol lets them, and only about what they own when it says so.
    testing.expect_value(t,event_send(s.clients[0],s.tp.hit,actor,&hit),Error.Invalid)
    hit.damage=7
    hit.from=base.Entity(u64(base.handle_index(base.Handle(shooter)))+2000)
    testing.expect_value(t,event_send(s.clients[0],s.tp.use,actor,&hit),Error.None)
    testing.expect_value(t,event_send(s.clients[1],s.tp.use,actor,&hit),Error.None)
    testing.expect_value(t,event_send(s.clients[1],s.tp.ping,0,&hit),Error.None)
    received,pings:=0,0
    for _ in 0..<6 {
        tick+=1
        for client in s.clients[:2] {host_publish(client,tick)}
        host_publish(s.server,tick)
        test_step(&s.w)
        for &command in host_poll(s.server) {
            if command.kind!=.Event {continue}
            out:Test_Hit
            testing.expect(t,event_read(s.server,&command,&out))
            if command.event==s.tp.ping {
                pings+=1
                testing.expect_value(t,command.connection,s.on_server[1])
                continue
            }
            received+=1
            testing.expect_value(t,command.connection,s.on_server[0])
            testing.expect_value(t,command.object,actor)
            testing.expect_value(t,out.damage,i32(7))
            testing.expect_value(t,u64(out.from),u64(900))
        }
        for client in s.clients[:2] {host_poll(client)}
    }
    testing.expect_value(t,received,1)
    testing.expect_value(t,pings,1)
}

@(private="file")
Server_Log :: struct {requests,changes,updates:int,requester,holder:Connection,object:Object,position:[3]f32}
@(private="file")
authority_tick :: proc(s:^Scene,tick:^u32,log:^Event_Log,server:^Server_Log) {
    tick^+=1
    for client in s.clients[:s.count] {host_publish(client,tick^)}
    host_publish(s.server,tick^)
    test_step(&s.w)
    for &command in host_poll(s.server) {
        #partial switch command.kind {
        case .Authority_Requested:
            server.requests+=1
            server.requester,server.object=command.connection,command.object
        case .Authority_Changed:
            server.changes+=1
            server.holder=command.connection
        case .Object_Updated:
            out:Test_Transform
            object_read(s.server,&command,0,&out)
            server.position=out.position
            server.updates+=1
        }
    }
    for client,i in s.clients[:s.count] {
        for &command in host_poll(client) {event_visit(i,&command,log)}
    }
}

@(test)
delegated_authority_is_lent_handed_over_returned_and_expires :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,3,{max_objects=16,lease_ticks=30});defer scene_destroy(s)
    log:=new(Event_Log);defer free(log)
    log.s=s
    server:Server_Log
    transform:=Test_Transform{position={1,0,0},rotation=quaternion(w=1,x=0,y=0,z=0)}
    ball,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},simulation=.Lent})
    crate,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},simulation=.Lent,auto_authority=true})
    fixed,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform}})
    tick:=u32(0)
    for _ in 0..<10 {authority_tick(s,&tick,log,&server)}
    testing.expect_value(t,authority_request(s.clients[0],fixed),Error.Invalid)
    testing.expect_value(t,authority_release(s.clients[0],ball),Error.Invalid)
    testing.expect_value(t,authority_request(s.server,ball),Error.Invalid)

    // The game arbitrates: the request reaches it and nothing changes until it grants.
    testing.expect_value(t,authority_request(s.clients[0],ball),Error.None)
    for _ in 0..<5 {authority_tick(s,&tick,log,&server)}
    testing.expect(t,server.requests==1 && server.requester==s.on_server[0] && server.object==ball)
    testing.expect_value(t,object_role(s.clients[0],ball),Role.Shown)
    mine:=Test_Transform{position={5,0,0},rotation=quaternion(w=1,x=0,y=0,z=0)}
    testing.expect_value(t,object_write(s.clients[0],ball,0,&mine),Error.Invalid)
    testing.expect_value(t,authority_grant(s.server,ball,s.on_server[0]),Error.None)
    for _ in 0..<5 {authority_tick(s,&tick,log,&server)}
    testing.expect_value(t,object_role(s.clients[0],ball),Role.Held)
    testing.expect_value(t,log.role[0],Role.Held)
    testing.expect(t,server.changes==1 && server.holder==s.on_server[0],"a grant of the server is told as any other change")

    // The holder simulates: the server takes its state and passes it on to the others, not back.
    testing.expect_value(t,object_set_source(s.clients[0],ball,0,&mine),Error.None)
    testing.expect_value(t,object_set_poll(s.clients[0],ball,true),Error.None)
    log.updates={}
    for step in 0..<20 {
        mine.position.x+=0.5
        authority_tick(s,&tick,log,&server)
    }
    for _ in 0..<5 {authority_tick(s,&tick,log,&server)}
    testing.expect_value(t,server.position.x,f32(15))
    testing.expect(t,server.updates>=15)
    testing.expect_value(t,log.position[1].x,f32(15))
    testing.expect_value(t,log.position[2].x,f32(15))
    testing.expect_value(t,log.updates[0],0)
    testing.expect(t,test_replica_matches(s.server,s.clients[1],ball,false) && test_replica_matches(s.server,s.clients[0],ball,false))

    // Handed over: the new holder starts from the latest state and the old one is told.
    testing.expect_value(t,authority_request(s.clients[1],ball),Error.None)
    for _ in 0..<5 {
        mine.position.x+=0.5
        authority_tick(s,&tick,log,&server)
    }
    testing.expect(t,server.requests==2 && server.requester==s.on_server[1])
    authority_grant(s.server,ball,s.on_server[1])
    for _ in 0..<6 {
        mine.position.x+=100
        authority_tick(s,&tick,log,&server)
    }
    testing.expect_value(t,object_role(s.clients[0],ball),Role.Shown)
    testing.expect_value(t,object_role(s.clients[1],ball),Role.Held)
    testing.expect(t,server.position.x<20)
    testing.expect(t,test_replica_matches(s.server,s.clients[0],ball,false) && test_replica_matches(s.server,s.clients[1],ball,false))
    theirs:=Test_Transform{position={-3,0,0},rotation=quaternion(w=1,x=0,y=0,z=0)}
    testing.expect_value(t,object_write(s.clients[1],ball,0,&theirs),Error.None)
    for _ in 0..<6 {authority_tick(s,&tick,log,&server)}
    testing.expect_value(t,server.position.x,f32(-3))
    testing.expect_value(t,log.position[0].x,f32(-3))

    // A holder that stops sending loses the lease.
    testing.expect(t,server.changes==2 && server.holder==s.on_server[1])
    for _ in 0..<45 {authority_tick(s,&tick,log,&server)}
    testing.expect(t,server.changes==3 && server.holder==0)
    testing.expect_value(t,object_role(s.clients[1],ball),Role.Shown)

    // Arbitration left to the library: the first to ask holds it, the second has to wait for the game.
    authority_request(s.clients[2],crate)
    for _ in 0..<3 {authority_tick(s,&tick,log,&server)}
    authority_request(s.clients[0],crate)
    for _ in 0..<5 {authority_tick(s,&tick,log,&server)}
    testing.expect(t,server.changes==4 && server.holder==s.on_server[2])
    testing.expect(t,server.requests==3 && server.requester==s.on_server[0] && server.object==crate)
    testing.expect_value(t,object_role(s.clients[2],crate),Role.Held)
    testing.expect_value(t,object_role(s.clients[0],crate),Role.Shown)
    testing.expect_value(t,authority_release(s.clients[2],crate),Error.None)
    for _ in 0..<5 {authority_tick(s,&tick,log,&server)}
    testing.expect(t,server.changes==5 && server.holder==0)
    testing.expect_value(t,object_role(s.clients[2],crate),Role.Shown)

    // A holder that leaves gives it back; the server can also take it away.
    authority_grant(s.server,ball,s.on_server[2])
    authority_grant(s.server,crate,s.on_server[0])
    for _ in 0..<5 {authority_tick(s,&tick,log,&server)}
    testing.expect_value(t,object_role(s.clients[2],ball),Role.Held)
    host_disconnect(s.clients[2])
    authority_grant(s.server,crate,0)
    for _ in 0..<8 {authority_tick(s,&tick,log,&server)}
    testing.expect(t,server.changes==9 && server.holder==0)
    testing.expect_value(t,object_role(s.clients[0],crate),Role.Shown)
    testing.expect_value(t,s.server.back.repl.held,0)
}

@(test)
local_objects_send_their_creation_and_nothing_else :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=8,object_stats=true});defer scene_destroy(s)
    Seen :: struct {created,updated,destroyed:int,simulation:Simulation,position:[3]f32,s:^Scene,object:Object}
    seen:=Seen{s=s}
    visit :: proc(client:int,command:^Command,user:rawptr) {
        seen:=(^Seen)(user)
        #partial switch command.kind {
        case .Object_Created:
            out:Test_Transform
            object_read(seen.s.clients[client],command,0,&out)
            seen.created+=1
            seen.simulation,seen.position,seen.object=command.simulation,out.position,command.object
        case .Object_Updated:   seen.updated+=1
        case .Object_Destroyed: seen.destroyed+=1
        }
    }
    debris:=Test_Transform{position={4,5,6},velocity={1,9,0},rotation=quaternion(w=1,x=0,y=0,z=0)}
    // Created and destroyed in one go, as a spawn event would be.
    spark,_:=object_create(s.server,{type=s.tp.prop,sources={0=&debris},simulation=.Each})
    testing.expect_value(t,object_destroy(s.server,spark),Error.None)
    shard,_:=object_create(s.server,{type=s.tp.prop,sources={0=&debris},simulation=.Each,poll=true})
    tick:=u32(0)
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,seen.created,2)
    testing.expect_value(t,seen.simulation,Simulation.Each)
    testing.expect_value(t,seen.position,[3]f32{4,5,6})
    bits:=object_bits_sent(s.server,shard)
    testing.expect(t,bits>0)
    debris.position.x=100
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,object_destroy(s.server,shard),Error.None)
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,seen.updated,0)
    testing.expect_value(t,seen.destroyed,0)
    // The server forgot both; the client keeps its copies until it ends them itself.
    testing.expect(t,object_valid(s.clients[0],seen.object))
    for live in s.server.back.repl.live {testing.expect_value(t,live,u8(0))}
    testing.expect(t,s.server.back.repl.states.used==0 && s.server.back.repl.bases.used==0)
    // Whoever joins later was not there for the event.
    joined:=scene_join(s)
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    testing.expect(t,s.on_server[joined]!=0)
    testing.expect_value(t,seen.created,2)
}

@(private="file")
Order_Log :: struct {host:^Host,count,next:int,in_order:bool}

// A client that acknowledges nothing fills the reliable channel of the
// library: event_send refuses with Full, the connection stays, and what was
// accepted arrives once and in order when the client answers again.
@(test)
a_full_queue_of_reliable_events_refuses_them_and_keeps_the_connection :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=64},seed=9);defer scene_destroy(s)
    log:=Order_Log{host=s.clients[0],in_order=true}
    visit:=proc(client:int,command:^Command,user:rawptr) {
        log:=(^Order_Log)(user)
        if command.kind!=.Event {return}
        hit:Test_Hit
        if !event_read(log.host,command,&hit) {return}
        if int(hit.damage)!=log.next {log.in_order=false}
        log.next=int(hit.damage)+1
        log.count+=1
    }
    tick:=u32(0)
    for _ in 0..<4 {scene_tick(s,&tick,visit,&log)}
    sim_endpoint_conditions(&s.w.sim,1,{loss=1})
    sent,refused:=0,0
    for _ in 0..<60 {
        for _ in 0..<200 {
            hit:=Test_Hit{damage=i32(sent)}
            error:=event_send(s.server,s.tp.hit,0,&hit)
            if error==.None {sent+=1} else {refused+=1}
            testing.expect(t,error==.None || error==.Full,"only Full refuses it")
        }
        scene_tick(s,&tick,visit,&log)
    }
    testing.expect(t,refused>0,"the queue filled")
    testing.expect_value(t,host_stats(s.server).connections,1)
    sim_endpoint_conditions(&s.w.sim,1,{})
    for _ in 0..<600 {scene_tick(s,&tick,visit,&log)}
    testing.expect_value(t,host_stats(s.server).connections,1)
    testing.expect_value(t,log.count,sent)
    testing.expect(t,log.in_order)
}
