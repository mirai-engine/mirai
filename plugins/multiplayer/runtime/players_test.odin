package multiplayer

import "core:testing"
import "mirai:core"
import input "mirai:engine/input"

// The tables of the players of a server and of what a client drives.
@(private="file")
Seated :: struct {
    using world:core.Test_World,
    seats:core.Table(input.Seat),
    drivables:core.Table(input.Drivable),
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
    core.test_world_init(t,w,test_types) or_return
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
    net_seats({entities=&w.entities},&w.seats,&w.absents,&w.disabled,&w.objects,&w.transforms,&w.keeps,core.read(&w.links),
        core.ref(&w.bindings),core.ref(&w.connections),core.ref(&w.network),core.ref(&w.hierarchy),core.ref(settings),w.time)
    core.test_world_settle(w)
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
    defer core.test_world_destroy(&w)
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
    testing.expect_value(t,core.at(&w.seats,0),input.Seat{peer=u64(first),player=42})
    replicate,replicated:=core.get(&w.objects,seat)
    testing.expect(t,replicated && replicate.audience==.Always && core.has(&w.transforms,seat) && core.has(&w.keeps,seat))
    body:=core.create(&w.entities)
    core.add(&w.drivables,body,input.Drivable{seat=seat})
    core.test_world_settle(&w)

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
    testing.expect_value(t,core.at(&w.seats,0).peer,u64(second))
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
    defer core.test_world_destroy(&w)
    settings:Net_Settings
    saved,other:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,saved,input.Seat{player=42})
    core.add(&w.seats,other,input.Seat{player=7})
    core.test_world_settle(&w)
    connection:=Connection(u64(1)<<32|2)
    seated_connect(&w,connection,42)
    seated_tick(&w,&settings)
    if !testing.expect_value(t,core.count(&w.seats),1) {return}
    testing.expect_value(t,core.at(&w.seats,0),input.Seat{peer=u64(connection),player=42})
    testing.expect(t,core.alive(&w.entities,other) && core.raw_find(core.raw(&w.absents),type_info_of(Seat_Absent),other)!=nil)
    for _ in 0..<600 {seated_tick(&w,&settings)}
    testing.expect(t,core.alive(&w.entities,other),"a seat of a saved game waits without limit")
}

// A client keeps the seats the server replicates, and none of them is its own.
@(test)
a_client_keeps_the_seats_of_the_server :: proc(t:^testing.T) {
    w:Seated
    if !seated_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    settings:Net_Settings
    w.network.role=.Client
    replica:=core.create(&w.entities)
    core.add(&w.seats,replica,input.Seat{peer=5})
    core.add(&w.links,replica,Net_Link{object=1})
    core.test_world_settle(&w)
    seated_tick(&w,&settings)
    testing.expect(t,core.alive(&w.entities,replica))
    testing.expect_value(t,input.local_seat(&w.seats,0),core.NONE)
}

// On a server, a replicated body is owned by the connection of the seat that
// drives it, and so is that seat; one no remote seat drives has no owner.
@(test)
a_server_owns_each_body_to_the_connection_of_its_seat :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
    connection:=Connection(u64(3)<<32|7)
    body,free:=net_test_body(&world,&info,1),net_test_body(&world,&info,2)
    net_test_own(&world,body,connection)
    core.add(&world.drivables,free,input.Drivable{})
    core.settle(&info,&world,nil)
    ref:=core.world_ref(&world,&info)
    testing.expect_value(t,owner_of(ref,body),connection)
    driven,_:=core.get(&world.drivables,body)
    testing.expect_value(t,owner_of(ref,driven.seat),connection)
    testing.expect_value(t,owner_of(ref,free),Connection(0))
}

// On a client, the first local seat drives the replica it predicts and lets
// go of one it no longer predicts.
@(test)
a_client_drives_what_it_predicts :: proc(t:^testing.T) {
    w:Seated
    if !seated_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    requests:input.Seat_Requests
    defer delete(requests.queue.items)
    w.network={role=.Client}
    local:=core.create(&w.entities)
    core.add(&w.seats,local,input.Seat{slot=0})
    predicted,shown:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.links,predicted,Net_Link{object=1})
    core.add(&w.replicas,predicted,core.Pose_Target{})
    core.add(&w.drivables,predicted,input.Drivable{})
    core.add(&w.links,shown,Net_Link{object=2})
    core.add(&w.replicas,shown,core.Pose_Target{follow=true})
    core.add(&w.remotes,shown,core.Remote{})
    core.add(&w.drivables,shown,input.Drivable{seat=local})
    core.test_world_settle(&w)
    net_driving(core.read(&w.links),core.read(&w.replicas),core.read(&w.remotes),core.read(&w.drivables),core.read(&w.seats),&requests,core.ref(&w.network))
    asked:=core.take(&requests.queue)
    if !testing.expect_value(t,len(asked),2) {return}
    testing.expect_value(t,asked[0],input.Seat_Request{kind=.Release,seat=local})
    testing.expect_value(t,asked[1],input.Seat_Request{kind=.Drive,seat=local,entity=predicted})
}

// A seat the game turned off stays off when its player comes back: the network
// turns on only what it turned off. While it is off, its connection still has it.
@(test)
a_seat_the_game_turned_off_stays_off_when_its_player_comes_back :: proc(t:^testing.T) {
    w:Seated
    if !seated_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    settings:Net_Settings
    first:=Connection(u64(1)<<32|3)
    seated_connect(&w,first,42)
    seated_tick(&w,&settings)
    if !testing.expect_value(t,core.count(&w.seats),1) {return}
    seat:=core.entity_at(&w.seats,0)
    core.add(&w.disabled,seat,core.Disabled{})
    core.test_world_settle(&w)
    seated_tick(&w,&settings)
    testing.expect_value(t,len(w.seats.entities),1)

    clear(&w.connections.entries)
    seated_tick(&w,&settings)
    second:=Connection(u64(2)<<32|4)
    seated_connect(&w,second,42)
    seated_tick(&w,&settings)
    testing.expect_value(t,len(w.seats.entities),1)
    value:=(^input.Seat)(core.raw_find(core.raw(&w.seats),type_info_of(input.Seat),seat))
    testing.expect(t,value!=nil && value.peer==u64(second))
    testing.expect(t,core.has(&w.disabled,seat),"what the game turned off stays off")
}
