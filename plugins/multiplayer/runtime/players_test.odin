package multiplayer

import "core:testing"
import "mirai:core"
import input "mirai:engine/input"

// The tables of the players of a server and of what a client drives.
@(private)
@(test_world)
Seated :: struct {
    using world:Test_World,
    seats:core.Table(input.Seat),
    nets:core.Table(Net_Seat),
    seat_state:input.Seats,
    seat_runtime:input.Seat_States,
    moves:core.Table(input.Move_Input),
    absents:core.Table(Seat_Absent),
    disabled:core.Table(core.Disabled),
    parents:core.Table(core.Parent),
    objects:core.Table(Replicate),
    transforms:core.Table(core.Transform),
    keeps:core.Table(core.Keep),
    links:core.Table(Net_Link),
    replicas:core.Table(core.Pose_Target),
    remotes:core.Table(core.Remote),
    hierarchy:core.Hierarchy,
    bindings:input.Input_Map,
    connections:Remote_Inputs,
    network:core.Network,
    time:core.Time,
}

@(private="file")
seated_init :: proc(t:^testing.T,w:^Seated) -> bool {
    test_world_init(t,w) or_return
    w.network={role=.Server}
    w.time={dt=1.0/60}
    return true
}

// A connection of the server, by its index as the host gives it, with the player it presented.
@(private="file")
seated_connect :: proc(w:^Seated,connection:Connection,player:u64) {
    index:=object_index(Object(connection))
    if index>=len(w.connections.entries) {resize(&w.connections.entries,index+1)}
    w.connections.entries[index]={connection=connection,player=player}
}

@(private="file")
seated_tick :: proc(w:^Seated,settings:^Net_Settings) {
    net_seats({entities=&w.entities},&w.seats,&w.nets,&w.seat_runtime,&w.absents,&w.disabled,&w.objects,&w.transforms,&w.keeps,core.read(&w.links),core.read(&w.remotes),
        core.ref(&w.bindings),core.ref(&w.connections),core.ref(&w.network),core.ref(settings),w.time)
    test_world_settle(w)
    w.time.tick+=1
}

// A server seats the player of each connection once it says who it is, for
// every client to see and across scenes; when it leaves, the seat waits for
// that player, off, and the player gets it back when it connects again. A
// seat whose player does not come back in time goes, and leaves its body to
// whoever gave it.
@(test)
a_seat_waits_for_its_player_and_is_given_back_when_it_connects_again :: proc(t:^testing.T) {
    w:Seated
    if !seated_init(t,&w) {return}
    defer test_world_destroy(&w)
    settings:Net_Settings
    settings.absent_seconds=1
    // A handle with its generation above the low 32 bits.
    first:=Connection(u64(3)<<32|7)
    seated_connect(&w,first,0)
    seated_tick(&w,&settings)
    testing.expect_value(t,core.count(&w.seats),0)
    remote_entry(&w.connections,first).player=42
    seated_tick(&w,&settings)
    if !testing.expect_value(t,core.count(&w.seats),1) {return}
    seat:=core.entity_at(&w.seats,0)
    testing.expect_value(t,core.at(&w.seats,0),input.Seat{remote=true})
    testing.expect_value(t,core.at(&w.nets,0),Net_Seat{connection=first,player=42})
    replicate,replicated:=core.get(&w.objects,seat)
    testing.expect(t,replicated && replicate.audience==.Always && core.has(&w.transforms,seat) && core.has(&w.keeps,seat))
    body:=core.create(&w.entities)
    core.edit(&w.seats,seat).body=body
    test_world_settle(&w)

    clear(&w.connections.entries)
    left:=w.time.tick
    seated_tick(&w,&settings)
    testing.expect(t,core.alive(&w.entities,seat) && core.count(&w.seats)==0,"the seat of a player who left waits, off")
    absent:=(^Seat_Absent)(core.raw_find(core.raw(&w.absents),type_info_of(Seat_Absent),seat))
    testing.expect(t,absent!=nil && absent.until==left+60)
    testing.expect(t,core.alive(&w.entities,body),"and leaves its body to whoever gave it")

    second:=Connection(u64(4)<<32|9)
    seated_connect(&w,second,42)
    seated_tick(&w,&settings)
    if !testing.expect_value(t,core.count(&w.seats),1) {return}
    testing.expect_value(t,core.entity_at(&w.seats,0),seat)
    testing.expect_value(t,core.at(&w.nets,0).connection,second)
    testing.expect(t,!core.has(&w.disabled,seat) && len(w.absents.entities)==0)

    clear(&w.connections.entries)
    for _ in 0..<62 {seated_tick(&w,&settings)}
    testing.expect(t,!core.alive(&w.entities,seat),"a seat whose player does not come back in time goes")
    testing.expect(t,core.alive(&w.entities,body))

    // Without waiting, the seat goes with its connection.
    settings.absent_seconds=-1
    seated_connect(&w,first,7)
    seated_tick(&w,&settings)
    if !testing.expect_value(t,core.count(&w.seats),1) {return}
    again:=core.entity_at(&w.seats,0)
    clear(&w.connections.entries)
    seated_tick(&w,&settings)
    testing.expect(t,!core.alive(&w.entities,again))
}

// The seats of a saved game wait, off, for their players, without limit.
@(test)
the_seats_of_a_saved_game_wait_for_their_players :: proc(t:^testing.T) {
    w:Seated
    if !seated_init(t,&w) {return}
    defer test_world_destroy(&w)
    settings:Net_Settings
    saved,other:=core.create(&w.entities),core.create(&w.entities)
    for e,player in ([2]core.Entity{saved,other}) {
        core.add(&w.seats,e,input.Seat{})
        core.add(&w.nets,e,Net_Seat{player=u64(42 if player==0 else 7)})
    }
    test_world_settle(&w)
    connection:=Connection(u64(1)<<32|2)
    seated_connect(&w,connection,42)
    seated_tick(&w,&settings)
    if !testing.expect_value(t,core.count(&w.seats),1) {return}
    testing.expect_value(t,core.at(&w.seats,0),input.Seat{remote=true})
    testing.expect_value(t,core.at(&w.nets,0),Net_Seat{connection=connection,player=42})
    testing.expect(t,core.alive(&w.entities,other) && core.raw_find(core.raw(&w.absents),type_info_of(Seat_Absent),other)!=nil)
    for _ in 0..<600 {seated_tick(&w,&settings)}
    testing.expect(t,core.alive(&w.entities,other),"a seat of a saved game waits without limit")
}

// A client plays at the replica of the seat of its player, the one it owns:
// its one local seat, slot 0, with the body the server gave it; the replicas of
// the seats of the other players are remote. Once it has its own, the seat this
// machine made before goes.
@(test)
a_client_plays_at_the_replica_of_the_seat_of_its_player :: proc(t:^testing.T) {
    w:Seated
    if !seated_init(t,&w) {return}
    defer test_world_destroy(&w)
    w.network.role=.Client
    made,own,other,body,theirs:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,made,input.Seat{})
    core.add(&w.seats,other,input.Seat{body=theirs})
    core.add(&w.links,other,Net_Link{object=2})
    core.add(&w.remotes,other,core.Remote{})
    test_world_settle(&w)
    seated_tick(&w,&Net_Settings{})
    testing.expect(t,core.alive(&w.entities,made),"without its own seat, the one it made stays")
    testing.expect(t,!input.seat_local(core.get(&w.seats,other) or_else {}),"the seat of another player is remote")
    core.add(&w.seats,own,input.Seat{body=body})
    core.add(&w.links,own,Net_Link{object=1})
    test_world_settle(&w)
    seated_tick(&w,&Net_Settings{})
    seats:=core.read(&w.seats)
    testing.expect(t,!core.alive(&w.entities,made),"the seat made before the replica goes")
    testing.expect_value(t,input.local_seat(seats,0),own)
    testing.expect_value(t,input.body_of(seats,own),body)
    testing.expect_value(t,input.body_of(seats,other),theirs)
    testing.expect_value(t,core.count(&w.seats),2)
}

// On a server, a replicated body is owned by the connection of the seat that
// drives it, and so is that seat; one no remote seat drives has no owner.
@(test)
a_server_owns_each_body_to_the_connection_of_its_seat :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
    connection:=Connection(u64(3)<<32|7)
    body,free:=net_test_body(&world,&info,1),net_test_body(&world,&info,2)
    net_test_own(&world,body,connection)
    core.settle(&info,&world,nil)
    input.input_seat_index(core.ref(&world.entities),core.read(&world.seats),&world.seat_state,nil)
    owners:=owners_of(core.world_ref(&world,&info))
    testing.expect_value(t,owner_of(owners,body),connection)
    testing.expect_value(t,owner_of(owners,input.seat_of(core.ref(&world.seat_state),body)),connection)
    testing.expect_value(t,owner_of(owners,free),Connection(0))
}

// A seat the game turned off stays off when its player comes back: the network
// turns on only what it turned off. While it is off, its connection still has it.
@(test)
a_seat_the_game_turned_off_stays_off_when_its_player_comes_back :: proc(t:^testing.T) {
    w:Seated
    if !seated_init(t,&w) {return}
    defer test_world_destroy(&w)
    settings:Net_Settings
    first:=Connection(u64(1)<<32|3)
    seated_connect(&w,first,42)
    seated_tick(&w,&settings)
    if !testing.expect_value(t,core.count(&w.seats),1) {return}
    seat:=core.entity_at(&w.seats,0)
    core.add(&w.disabled,seat,core.Disabled{})
    test_world_settle(&w)
    seated_tick(&w,&settings)
    testing.expect_value(t,len(w.seats.entities),1)

    clear(&w.connections.entries)
    seated_tick(&w,&settings)
    second:=Connection(u64(2)<<32|4)
    seated_connect(&w,second,42)
    seated_tick(&w,&settings)
    testing.expect_value(t,len(w.seats.entities),1)
    value:=(^Net_Seat)(core.raw_find(core.raw(&w.nets),type_info_of(Net_Seat),seat))
    testing.expect(t,value!=nil && value.connection==second)
    testing.expect(t,core.has(&w.disabled,seat),"what the game turned off stays off")
}
