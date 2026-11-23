package multiplayer

import "mirai:core"
import input "mirai:engine/input"
import wire "mirai:net"

// The players of the connections. A server seats each player that connects
// once its client says who it is (Net_Player, whose secret only that player
// has): an input.Seat, remote, with a Net_Seat that names its connection and
// keeps the hash of that secret, whose actions and view are the ones the
// connection sent for the tick, replicated to every client with the body it
// drives and what the game hangs from it, and kept across scenes. When the
// connection leaves, the seat waits for its player, off (Seat_Absent), for
// Net_Settings.absent_seconds, and goes after; that player connecting again
// gets it back, and so does the player of a seat of a saved game. What
// happens to its body is for whoever gave it (spawn.Seat_Body goes with its
// seat). A body is owned by the connection of its seat, and so is the seat:
// what makes the client of that connection predict it and its view follow
// it. A client plays at the replica of the seat of its player, which it owns:
// its local seat 0, which drives the body the server gave it; the replicas
// of the seats of the other players are remote.

// Server: the connection of the player of another end who plays at a seat,
// and that player. input.Seat knows only that its actions come from another end.
@(component,description="Server: the connection of the player of another end who plays at this seat, and that player, whose seat it is again when it connects again.")
Net_Seat :: struct {
    connection:Connection `mirai:"transient,readonly"`, // 0 while its player is away
    player:u64 `mirai:"readonly,hidden"`,              // the hash of the secret its player presents
}

@(step="fixed",loops="game",stage="begin")
net_seats :: proc(
    es:core.Commands,seats:^core.Table(input.Seat),nets:^core.Table(Net_Seat),states:^input.Seat_States,absents:^core.Table(Seat_Absent),disabled:^core.Table(core.Disabled),
    objects:^core.Table(Replicate),transforms:^core.Table(core.Transform),keeps:^core.Table(core.Keep),links:^core.Table(Net_Link,.Read),remotes:^core.Table(core.Remote,.Read),
    bindings:core.Ref(input.Input_Map),connections:core.Ref(Remote_Inputs),network:core.Ref(core.Network),
    settings:core.Ref(Net_Settings),time:core.Time,
) {
    #partial switch network.role {
    case .Client: client_seats(es,seats,links,remotes)
    case .Server: server_seats(es,seats,nets,states,absents,disabled,objects,transforms,keeps,bindings,connections,settings,time)
    }
}

@(private)
server_seats :: proc(
    es:core.Commands,seats:^core.Table(input.Seat),nets:^core.Table(Net_Seat),states:^input.Seat_States,absents:^core.Table(Seat_Absent),disabled:^core.Table(core.Disabled),
    objects:^core.Table(Replicate),transforms:^core.Table(core.Transform),keeps:^core.Table(core.Keep),
    bindings:core.Ref(input.Input_Map),connections:core.Ref(Remote_Inputs),settings:core.Ref(Net_Settings),time:core.Time,
) {
    // The connections with a seat, on or off, by the index of their connection.
    seated:[wire.MAX_CONNECTIONS/64]u64
    for value in nets.values {
        if connected(connections,value.connection) {
            index:=object_index(Object(value.connection))
            seated[index/64]|=1<<uint(index%64)
        }
    }
    for entry in connections.entries {
        if entry.player==0 {continue}
        index:=object_index(Object(entry.connection))
        if seated[index/64]&(1<<uint(index%64))!=0 {continue}
        // The seat its player left; off only if the network turned it off.
        if seat:=seat_waiting(nets,connections,entry.player);seat!=core.NONE {
            net:=(^Net_Seat)(core.raw_find(core.raw(nets),type_info_of(Net_Seat),seat))^
            net.connection=entry.connection
            core.add(nets,seat,net)
            // Loaded from a save, it knows again that its player is at another end.
            if value:=(^input.Seat)(core.raw_find(core.raw(seats),type_info_of(input.Seat),seat));value!=nil && !value.remote {
                remote:=value^
                remote.remote=true
                core.add(seats,seat,remote)
            }
            if core.raw_find(core.raw(absents),type_info_of(Seat_Absent),seat)!=nil {
                core.remove(absents,seat)
                core.remove(disabled,seat)
            }
            continue
        }
        seat:=core.create(es)
        core.add(seats,seat,input.Seat{remote=true})
        core.add(nets,seat,Net_Seat{connection=entry.connection,player=entry.player})
        // Every client sees the players, and the player of a connection stays when the scene changes.
        replicate:=REPLICATE_DEFAULT
        replicate.audience=.Always
        core.add(objects,seat,replicate)
        core.add(transforms,seat,core.TRANSFORM_IDENTITY)
        if keeps!=nil {core.add(keeps,seat,core.Keep{})}
    }
    waits:=absent_ticks(settings,time)
    for row in 0..<core.count(nets) {
        seat:=core.entity_at(nets,row)
        value:=&nets.values[row]
        if staged:=(^Net_Seat)(core.raw_added(core.raw(nets),type_info_of(Net_Seat),seat));staged!=nil {value=staged}
        if value.connection==0 {
            // The seat of a player of a saved game waits for that player.
            if value.player!=0 {absent(absents,disabled,seat,0)}
            continue
        }
        if connected(connections,value.connection) {
            sent,_:=remote_input(connections,value.connection)
            input.seat_receive(input.seat_runtime_edit(states,seat),bindings.ptr,sent,time.dt)
            continue
        }
        // A connection that left: its seat waits for its player, or goes.
        if value.player!=0 && waits>=0 {
            core.staged(nets,seat).connection=0
            absent(absents,disabled,seat,time.tick+u64(max(waits,1)))
            continue
        }
        core.destroy(es,seat)
    }
    for at in 0..<len(absents.entities) {
        if until:=absents.values[at].until;until!=0 && time.tick>=until {core.destroy(es,absents.entities[at])}
    }
}

// A client plays at the seat its server gives its player: the seats of the
// server are replicas, the one it owns (core.owned) is its own and the others
// are remote. Once it has its own, the seats this machine made before go.
@(private)
client_seats :: proc(es:core.Commands,seats:^core.Table(input.Seat),links:^core.Table(Net_Link,.Read),remotes:^core.Table(core.Remote,.Read)) {
    own:=false
    for row in 0..<core.count(seats) {
        e:=core.entity_at(seats,row)
        if !core.has(links,e) {continue}
        remote:=core.has(remotes,e)
        own||=!remote
        if seats.values[row].remote!=remote {core.edit_at(seats,row).remote=remote}
    }
    if !own {return}
    for row in 0..<core.count(seats) {
        e:=core.entity_at(seats,row)
        if !core.has(links,e) && input.seat_local(seats.values[row]) {core.destroy(es,e)}
    }
}

// The seat of a player that no connection has, on or off: only when a
// connection presents its player.
@(private)
seat_waiting :: proc(nets:^core.Table(Net_Seat),connections:core.Ref(Remote_Inputs),player:u64) -> core.Entity {
    for e,row in nets.entities {
        value:=nets.values[row]
        if value.player==player && (value.connection==0 || !connected(connections,value.connection)) {return e}
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
    return connection!=0 && remote_entry(connections.ptr,connection)!=nil
}

// What tells the owner of a replicated entity on a server, resolved once for
// a pass over the objects: never kept across ticks, which may replace the tables.
@(private)
Owners :: struct {
    nets:^core.Table(Net_Seat),
    state:core.Ref(input.Seats),
}

@(private)
owners_of :: proc(w:core.World_Ref) -> Owners {
    return {core.world_table_of(w,Net_Seat),core.ref(core.world_storage_of(w,input.Seats))}
}

// The owner of a replicated entity on a server: the connection of a seat, or
// of the seat that drives a body; 0 for one no remote seat drives.
@(private)
owner_of :: proc(o:Owners,e:core.Entity) -> Connection {
    if o.nets==nil {return 0}
    if net,is:=core.get(o.nets,e);is {return net.connection}
    net,_:=core.get(o.nets,input.seat_of(o.state,e))
    return net.connection
}

// A client: the seat it drives with acts on what its devices gave as many
// ticks ago as its input delay (wire.Input_Delay, by the round trip), with
// seat_receive, as the server will: both ends derive the same edges. It keeps
// two lines of what it held: the one the devices feed (outside the World: it
// moves only when a tick runs first), which net_input_take gives it before
// they do, and the one the game sees, which net_input_delay gives back before
// the delayed actions reach it. A tick that runs again keeps its delay.
@(step="fixed",loops="game",stage="input",before="input_seats")
net_input_take :: proc(session:^Net_Session,seats:^core.Table(input.Seat,.Read),states:^input.Seat_States,time:core.Time) {
    seat:=delayed_seat(session,seats,states)
    if seat==nil {return}
    c:=&session.client
    c.delayed=seat.sample
    if !time.resimulating {
        seat.sample=c.fed_seat
    }
}

@(step="fixed",loops="game",stage="input",after="input_seats")
net_input_delay :: proc(session:^Net_Session,seats:^core.Table(input.Seat,.Read),states:^input.Seat_States,bindings:core.Ref(input.Input_Map),time:core.Time,problems:^core.Problems) {
    seat:=delayed_seat(session,seats,states)
    if seat==nil {return}
    c:=&session.client
    tick:=u32(time.tick)
    if !time.resimulating {
        c.fed_seat=seat.sample
        sent,ok:=input.seat_remote(core.ref(states),input.local_seat(seats,0),bindings)
        if !ok {core.report(problems,core.NONE,"net.input_axes","more than %d axis actions of the seat that drives were away from zero in one tick, and the server got only the first %d; give the actions that move together fewer axes, or make some of them buttons",input.REMOTE_AXES,input.REMOTE_AXES)}
        c.taken[int(tick)%len(c.taken)]={tick+1,sent,u8(wire.clock_state(&session.host).input_delay)}
    }
    seat.sample=c.delayed
    now:=c.taken[int(tick)%len(c.taken)]
    from:=tick-u32(now.tick==tick+1?now.delay:0)
    taken:=c.taken[int(from)%len(c.taken)]
    input.seat_receive(seat,bindings.ptr,taken.tick==from+1?taken.actions:{},time.dt)
}

// The seat a client drives with; nil on a server.
@(private)
delayed_seat :: proc(session:^Net_Session,seats:^core.Table(input.Seat,.Read),states:^input.Seat_States) -> ^input.Seat_State {
    if !session.host_ready || session.mode!=.Client {return nil}
    return input.seat_runtime_edit(states,input.local_seat(seats,0))
}
