package multiplayer

import "mirai:core"
import input "mirai:engine/input"
import wire "mirai:net"

// The players of the connections. A server seats each player that connects
// once its client says who it is (Net_Player, whose secret only that player
// has: the seat keeps its hash): an input.Seat with its peer,
// whose actions are the ones the connection sent for the tick, replicated to
// every client with what the game hangs from it, and kept across scenes. When
// the connection leaves, the seat waits for its player, off (Seat_Absent), for
// Net_Settings.absent_seconds, and goes after; that player connecting again
// gets it back, and so does the player of a seat of a saved game. What happens
// to its body is for whoever gave it (spawn.Seat_Body goes with its seat). A
// body is owned by the connection of its seat, and so is the seat: what makes
// the client of that connection predict it and its view follow it. A client
// drives with its first local seat the body the server lets it predict.

@(step="fixed",loops="game",stage="begin")
net_seats :: proc(
    es:^core.Entities,seats:^core.Table(input.Seat),absents:^core.Table(Seat_Absent),disabled:^core.Table(core.Disabled),
    objects:^core.Table(Replicate),transforms:^core.Table(core.Transform),keeps:^core.Table(core.Keep),links:core.Read(Net_Link),
    bindings:core.Ref(input.Input_Map),connections:core.Ref(Remote_Inputs),network:core.Ref(core.Network),
    hierarchy:core.Ref(core.Hierarchy),settings:core.Ref(Net_Settings),time:core.Time,
) {
    serving:=network.role==.Server
    if serving {
        // The connections with a seat, on or off, by the index of their connection.
        seated:[wire.MAX_CONNECTIONS/64]u64
        for value in seats.values {
            if peer:=Connection(value.peer);connected(connections,peer) {
                index:=object_index(Object(peer))
                seated[index/64]|=1<<uint(index%64)
            }
        }
        for entry in connections.entries {
            if entry.player==0 {continue}
            index:=object_index(Object(entry.connection))
            if seated[index/64]&(1<<uint(index%64))!=0 {continue}
            // The seat its player left; off only if the network turned it off.
            if seat:=seat_waiting(seats,connections,entry.player);seat!=core.NONE {
                value:=(^input.Seat)(core.raw_find(core.raw(seats),type_info_of(input.Seat),seat))^
                value.peer=u64(entry.connection)
                core.add(seats,seat,value)
                if core.raw_find(core.raw(absents),type_info_of(Seat_Absent),seat)!=nil {
                    core.remove(absents,seat)
                    core.remove(disabled,seat)
                }
                continue
            }
            seat:=core.create(es)
            core.add(seats,seat,input.Seat{peer=u64(entry.connection),player=entry.player})
            // Every client sees the players, and the player of a connection stays when the scene changes.
            replicate:=REPLICATE_DEFAULT
            replicate.audience=.Always
            core.add(objects,seat,replicate)
            core.add(transforms,seat,core.TRANSFORM_IDENTITY)
            if keeps!=nil {core.add(keeps,seat,core.Keep{})}
        }
    }
    waits:=absent_ticks(settings,time)
    for row in 0..<core.count(seats) {
        seat:=core.entity_at(seats,row)
        value:=core.staged(seats,seat)
        if value.peer==0 {
            // The seat of a player of a saved game waits for that player.
            if serving && value.player!=0 {absent(absents,disabled,seat,0)}
            continue
        }
        // A client has the seats of the server as replicas.
        if network.role==.Client && core.has(links,seat) {continue}
        connection:=Connection(value.peer)
        if serving && connected(connections,connection) {
            sent,_:=remote_input(connections,connection)
            input.seat_receive(value,bindings.ptr,sent,time.dt)
            continue
        }
        // A connection that left: its seat waits for its player, or goes.
        if serving && value.player!=0 && waits>=0 {
            value.peer=0
            absent(absents,disabled,seat,time.tick+u64(max(waits,1)))
            continue
        }
        core.destroy_tree(es,hierarchy,seat)
    }
    if serving {
        for at in 0..<len(absents.entities) {
            if until:=absents.values[at].until;until!=0 && time.tick>=until {core.destroy_tree(es,hierarchy,absents.entities[at])}
        }
    }
}

// The seat of a player that no connection has, on or off: only when a
// connection presents its player.
@(private)
seat_waiting :: proc(seats:^core.Table(input.Seat),connections:core.Ref(Remote_Inputs),player:u64) -> core.Entity {
    for e,row in seats.entities {
        value:=seats.values[row]
        if value.player==player && (value.peer==0 || !connected(connections,Connection(value.peer))) {return e}
    }
    return core.NONE
}

// The ticks the seat of a player who left waits for that player; negative: none.
@(private)
absent_ticks :: proc(settings:core.Ref(Net_Settings),time:core.Time) -> i64 {
    seconds:f64
    if settings.ptr!=nil {seconds=settings.absent_seconds}
    if seconds==0 {seconds=300}
    if seconds<0 || time.dt<=0 {return -1}
    return i64(seconds/f64(time.dt)+0.5)
}

@(private)
absent :: proc(absents:^core.Table(Seat_Absent),disabled:^core.Table(core.Disabled),seat:core.Entity,until:u64) {
    core.add(absents,seat,Seat_Absent{until})
    core.add(disabled,seat,core.Disabled{})
}

@(private)
connected :: proc(connections:core.Ref(Remote_Inputs),connection:Connection) -> bool {
    return remote_entry(connections.ptr,connection)!=nil
}

// The owner of a replicated entity on a server: the connection of a seat, or
// of the seat that drives a body; 0 for one no remote seat drives.
@(private)
owner_of :: proc(w:core.World_Ref,e:core.Entity) -> Connection {
    drivables,seats:=core.world_table_of(w,input.Drivable),core.world_table_of(w,input.Seat)
    if seats==nil {return 0}
    if seat,is:=core.get(seats,e);is {return Connection(seat.peer)}
    if drivables==nil {return 0}
    driven,_:=core.get(drivables,e)
    seat,_:=core.get(seats,driven.seat)
    return Connection(seat.peer)
}

// A client with Net_Settings.input_delay: the seat it drives with acts on what
// its devices gave that many ticks ago, with seat_receive, as the server will:
// both ends derive the same edges. It keeps two lines of what it held: the one
// the devices feed (outside the World: it moves only when a tick runs first),
// which net_input_take gives it before they do, and the one the game sees,
// which net_input_delay gives back before the delayed actions reach it.
@(step="fixed",loops="game",stage="input",before="input_seats")
net_input_take :: proc(session:^Net_Session,seats:^core.Table(input.Seat),time:core.Time) {
    seat:=delayed_seat(session,seats)
    if seat==nil {return}
    c:=&session.client
    c.delayed=seat^
    if !time.resimulating {seat.actions,seat.held,seat.rearm,seat.fed=c.fed_seat.actions,c.fed_seat.held,c.fed_seat.rearm,c.fed_seat.fed}
}

@(step="fixed",loops="game",stage="input",after="input_seats")
net_input_delay :: proc(session:^Net_Session,seats:^core.Table(input.Seat),bindings:core.Ref(input.Input_Map),time:core.Time) {
    seat:=delayed_seat(session,seats)
    if seat==nil {return}
    c:=&session.client
    tick:=u32(time.tick)
    if !time.resimulating {
        c.fed_seat=seat^
        sent,_:=input.seat_remote(core.read(seats),input.local_seat(core.read(seats),0),bindings.ptr)
        c.taken[int(tick)%len(c.taken)]={tick+1,sent}
    }
    seat.actions,seat.held,seat.rearm,seat.fed=c.delayed.actions,c.delayed.held,c.delayed.rearm,c.delayed.fed
    from:=tick-u32(session.desc.input_delay)
    taken:=c.taken[int(from)%len(c.taken)]
    input.seat_receive(seat,bindings.ptr,taken.tick==from+1?taken.actions:{})
}

// The seat a client drives with while its input is delayed; nil otherwise.
@(private)
delayed_seat :: proc(session:^Net_Session,seats:^core.Table(input.Seat)) -> ^input.Seat {
    if !session.host_ready || session.mode!=.Client || session.desc.input_delay==0 {return nil}
    return core.edit(seats,input.local_seat(core.read(seats),0))
}

// A client: its first local seat asks to drive the body the server lets it
// predict, and to let go of a replicated one it no longer predicts.
@(step="fixed",loops="game",stage="input")
net_driving :: proc(
    links:core.Read(Net_Link),replicas:core.Read(core.Pose_Target),elsewhere:core.Read(core.Remote),
    drivables:core.Read(input.Drivable),seats:core.Read(input.Seat),requests:^input.Seat_Requests,network:core.Ref(core.Network),
) {
    if network.role==.Client {
        seat:=input.local_seat(seats,0)
        if seat==core.NONE {return}
        predicted:=core.NONE
        for row in 0..<core.count(drivables) {
            body:=core.entity_at(drivables,row)
            if !core.has(links,body) {continue}
            // What this client predicts as its own: a replica the server simulates that no other end decides.
            own:=core.has(replicas,body) && core.owned(elsewhere,body)
            driver:=core.at(drivables,row).seat
            if !own && driver==seat {
                input.release(requests,seat)
            } else if own && driver==core.NONE && predicted==core.NONE {
                predicted=body
            }
        }
        if predicted!=core.NONE {input.drive(requests,seat,predicted)}
    }
}
