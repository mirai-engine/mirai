package multiplayer

import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:host"
import wire "mirai:net"

// A server (0) and two clients of worlds the generator would make, without
// ticks: what arrives, the seats of the server and what each client says.
@(private="file")
Party :: struct {
    info:core.World_Info,
    worlds:[3]Net_Test_World,
    apps:[3]host.App,
    sessions:[3]Net_Session,
    problems:[3]core.Problems,
    network:wire.Sim_Network,
    bindings:input.Input_Map,
    now:f64,
}

@(private="file")
party_init :: proc(t:^testing.T,p:^Party) -> bool {
    p.info=net_test_info(t,follows=true) or_return
    if !testing.expect(t,wire.sim_network_init(&p.network,{seed=7,endpoints=3,packets=512})) {return false}
    for &world,index in p.worlds {
        net_test_init(&world,&p.info)
        world.root={changes=1}
        world.network.role=index==0?.Server:.Client
        p.apps[index]={info=&p.info,allocator=context.allocator,tick_dt=1.0/60}
        if !testing.expect(t,net_test_session(&p.sessions[index],&world,&p.info,&p.apps[index],&p.network,index,index==0?.Server:.Client)) {return false}
        p.sessions[index].problems=&p.problems[index]
    }
    return true
}

@(private="file")
party_destroy :: proc(p:^Party) {
    for &session in p.sessions {session_destroy(&session);delete(session.reason_text)}
    wire.sim_network_destroy(&p.network)
    for &world in p.worlds {core.world_destroy(&p.info,.World,&world)}
    delete(p.info.messages)
    core.test_info_destroy(&p.info)
}

// A client connects to the server.
@(private="file")
party_join :: proc(t:^testing.T,p:^Party,index:int) -> bool {
    return testing.expect_value(t,wire.host_connect(&p.sessions[index].host,wire.address_memory(0)),wire.Error.None)
}

// Another run of the client of a world: a session of its own, which connects.
@(private="file")
party_rejoin :: proc(t:^testing.T,p:^Party,index:int,new_player:=false) -> bool {
    session_destroy(&p.sessions[index])
    delete(p.sessions[index].reason_text)
    p.sessions[index]={}
    if !testing.expect(t,net_test_session(&p.sessions[index],&p.worlds[index],&p.info,&p.apps[index],&p.network,index,.Client)) {return false}
    p.sessions[index].problems=&p.problems[index]
    p.sessions[index].wanted.new_player=new_player
    return party_join(t,p,index)
}

@(private="file")
party_frames :: proc(p:^Party,frames:int) {
    for _ in 0..<frames {
        p.now+=1.0/60
        wire.sim_network_advance(&p.network,p.now)
        for &session in p.sessions {
            if session.host_ready && !session.ended {wire.host_update(&session.host,p.now)}
        }
        server:=&p.worlds[0]
        p.sessions[0].now=p.now
        server_commands(&p.sessions[0],core.world_ref(server,&p.info),nil,wire.host_poll(&p.sessions[0].host),&server.received,&server.remote)
        for index in 1..<len(p.sessions) {
            session:=&p.sessions[index]
            if !session.host_ready || session.ended {continue}
            session.now=p.now
            client_commands(session,core.world_ref(&p.worlds[index],&p.info),p.apps[index].assets,p.apps[index].allocator,wire.host_poll(&session.host),&p.worlds[index].received)
        }
        net_seats(&server.entities,&server.seats,&server.absents,&server.disabled,&server.objects,&server.transforms,nil,core.read(&server.links),
            core.ref(&p.bindings),core.ref(&server.remote),core.ref(&server.network),core.ref(&server.hierarchy),{},server.time)
        core.settle(&p.info,server,nil)
        server.time.tick+=1
        server_world_update(&p.sessions[0])
        for &session in p.sessions {
            if session.host_ready && !session.ended {wire.host_update(&session.host,p.now)}
        }
    }
}

// The seat of a player on the server, on or off.
@(private="file")
seat_of_player :: proc(p:^Party,player:u64) -> (seat:core.Entity,value:input.Seat) {
    seats:=&p.worlds[0].seats
    for e,row in seats.entities {
        if seats.values[row].player==player {return e,seats.values[row]}
    }
    return core.NONE,{}
}

// The connection of a client as its server names it.
@(private="file")
connection_of :: proc(p:^Party,index:int) -> Connection {return p.sessions[index].client.connection}

// A player is the hash of a secret only its client has: presenting the id of
// another, which is not its secret, gets a seat of its own, and leaves the
// other connected in its seat.
@(test)
a_client_that_presents_the_id_of_another_player_does_not_take_its_seat :: proc(t:^testing.T) {
    p:=new(Party)
    defer free(p)
    if !party_init(t,p) {return}
    defer party_destroy(p)
    p.worlds[1].identity.secret={0x1111,0x2222}
    // What an impostor that read the id of the first player could present.
    p.worlds[2].identity.secret={player_id({0x1111,0x2222}),0}
    if !party_join(t,p,1) {return}
    party_frames(p,30)
    if !party_join(t,p,2) {return}
    party_frames(p,30)
    first,impostor:=player_id({0x1111,0x2222}),player_id(p.worlds[2].identity.secret)
    testing.expect(t,first!=impostor)
    seat,value:=seat_of_player(p,first)
    testing.expect(t,seat!=core.NONE && value.peer==u64(connection_of(p,1)),"the first player keeps its seat")
    testing.expect(t,p.sessions[1].status==.Connected && !p.sessions[1].ended,"and its connection")
    other,_:=seat_of_player(p,impostor)
    testing.expect(t,other!=core.NONE && other!=seat)
    testing.expect_value(t,core.count(&p.worlds[0].seats),2)
}

// A player that comes back with its secret gets its seat back, the same
// entity, on; the secret a client made the first time is the one of its
// profile. Coming back while its old connection lives replaces that one. A
// client asked for a player of its own run is another player, whatever its profile.
@(test)
a_player_that_comes_back_with_its_secret_gets_its_seat_back :: proc(t:^testing.T) {
    p:=new(Party)
    defer free(p)
    if !party_init(t,p) {return}
    defer party_destroy(p)
    if !party_join(t,p,1) {return}
    party_frames(p,30)
    secret:=p.worlds[1].identity.secret
    if !testing.expect(t,secret!={},"a client without a secret makes one for its profile") {return}
    seat,_:=seat_of_player(p,player_id(secret))
    if !testing.expect(t,seat!=core.NONE) {return}

    // It leaves: its seat waits for it, off.
    session_destroy(&p.sessions[1])
    party_frames(p,30)
    testing.expect(t,core.alive(&p.worlds[0].entities,seat) && core.count(&p.worlds[0].seats)==0)

    // Another run of the same machine, with the same profile.
    p.worlds[2].identity.secret=secret
    if !party_join(t,p,2) {return}
    party_frames(p,30)
    again,value:=seat_of_player(p,player_id(secret))
    testing.expect_value(t,again,seat)
    testing.expect_value(t,value.peer,u64(connection_of(p,2)))
    testing.expect(t,!core.has(&p.worlds[0].disabled,seat) && core.raw_find(core.raw(&p.worlds[0].absents),type_info_of(Seat_Absent),seat)==nil,"on again")

    // The same player again while it is connected: the newer connection takes the seat.
    if !party_rejoin(t,p,1) {return}
    party_frames(p,30)
    testing.expect(t,p.sessions[2].ended && p.sessions[2].reason==.Replaced)
    _,value=seat_of_player(p,player_id(secret))
    testing.expect_value(t,value.peer,u64(connection_of(p,1)))

    // A player of its own run: the same profile, another player.
    if !party_rejoin(t,p,2,new_player=true) {return}
    party_frames(p,30)
    testing.expect(t,p.sessions[1].status==.Connected && !p.sessions[1].ended,"the player of the profile stays")
    testing.expect(t,p.sessions[2].secret!={} && p.sessions[2].secret!=secret && p.worlds[2].identity.secret==secret)
    own,_:=seat_of_player(p,player_id(p.sessions[2].secret))
    testing.expect(t,own!=core.NONE && own!=seat)
}

// A connection is one player, and someone: a client that presents no secret,
// or a second player on the same connection, is not one of this engine and
// leaves with Denied_Player; the player it presented first keeps its seat.
@(test)
a_connection_that_presents_no_player_or_two_is_closed :: proc(t:^testing.T) {
    p:=new(Party)
    defer free(p)
    if !party_init(t,p) {return}
    defer party_destroy(p)
    // Nobody.
    p.sessions[1].client.player_told=true
    if !party_join(t,p,1) {return}
    party_frames(p,20)
    nobody:=Net_Player{}
    testing.expect_value(t,wire.event_send(&p.sessions[1].host,wire.Event_Id(p.sessions[1].own.player),0,&nobody),wire.Error.None)
    party_frames(p,30)
    testing.expect(t,p.sessions[1].ended && p.sessions[1].reason==.Denied_Player,"a player of id 0 is refused")
    testing.expect_value(t,len(p.worlds[0].seats.entities),0)

    // Two players on one connection.
    p.worlds[2].identity.secret={5,6}
    if !party_join(t,p,2) {return}
    party_frames(p,30)
    first,_:=seat_of_player(p,player_id({5,6}))
    if !testing.expect(t,first!=core.NONE) {return}
    second:=Net_Player{{7,8}}
    testing.expect_value(t,wire.event_send(&p.sessions[2].host,wire.Event_Id(p.sessions[2].own.player),0,&second),wire.Error.None)
    party_frames(p,30)
    testing.expect(t,p.sessions[2].ended && p.sessions[2].reason==.Denied_Player)
    other,_:=seat_of_player(p,player_id({7,8}))
    testing.expect_value(t,other,core.NONE)
    _,value:=seat_of_player(p,player_id({5,6}))
    testing.expect(t,value.peer==0 && value.player==player_id({5,6}),"the seat of the first waits for its player")
}
