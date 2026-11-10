package multiplayer

import "mirai:core"
import input "mirai:engine/input"
import "mirai:std/base"
import mm "mirai:std/math"
import wire "mirai:net"

// Replication as a game declares it. An entity with Replicate exists on the
// server and on every client that should see it: the client makes it from
// the prefab it was spawned from, takes it from the scene by its Id, or makes
// it bare. What travels is what the entity has: its pose; its motion, when a
// simulation moves it (core.Motion); its driver, the input of the connection
// that owns it and its Move_Input, when it has a Move_Input; and each of its
// components declared @(component,replicated), whose fields tagged local stay
// on each end (precision, bits, min and max choose the serializer as
// std/serial describes). What it has when it is first replicated is what it
// replicates. Each different set is a type of the protocol that both ends
// compose from the list its creation carries: nothing is registered, and the
// order of the libraries does not matter. The structures declared
// @(net_message) are the messages: send them with send, read them with
// event_read.
//
// On a client, what the server simulates is a core.Pose_Target: whoever owns the
// Transform of the entity takes the pose the network writes there.

Simulation :: wire.Simulation
Role :: wire.Role
Connection :: wire.Connection
Object :: wire.Object
Disconnect_Reason :: wire.Disconnect_Reason
Net_Error :: wire.Error
Collection :: wire.Collection
Collection_Item :: wire.Collection_Item
collection_set :: wire.collection_set
collection_get :: wire.collection_get
collection_remove :: wire.collection_remove
collection_count :: wire.collection_count

// Which connections receive an entity; of them, those Visibility lets.
Audience :: enum u8 {
    Near,   // connections whose view reaches it
    Always, // every connection
    Owner,  // only the owner
}

// Who sees what, as data, like collision layers. On a replicated entity, mask
// is the bits of who may see it: of the connections its audience reaches,
// only those whose seat has one of them in sees; 0, or no Visibility, asks for
// none. On the seat of a player (input.Seat), sees is the bits its connection
// has; a seat without it has none, and sees what asks for none. A team is a
// bit; what a player alone sees is a bit of that player. The server reads it
// when it changes; it does not travel.
@(component,description="Who sees this entity on the network (mask), and, on the seat of a player, what that player sees (sees): a connection receives it when they share a bit.")
Visibility :: struct {
    mask:u32,
    sees:u32,
}

NET_PROTOCOL_ID :: 0x4d495241
DEFAULT_PORT :: 27500 // of Net_Settings.port
PLAYER_NET :: 5 // the exit code of a player whose client could not join its server, or lost it with nobody watching
COMPONENTS :: wire.MAX_FRAGMENTS-3 // replicated components of an entity, besides its pose, motion and driver
EVENT_BYTES :: 256
PENDING_EVENTS :: 1024 // messages that wait for the next tick (a paused game runs none); later ones are dropped and reported

// An entity the network replicates. The game gives it with the entity (in its
// prefab or its scene), and the network reads it. Its owner, the connection
// that predicts it, is that of the seat that drives it (input.Drivable). Its
// closest ancestor in the hierarchy with Replicate is its parent on the
// network: it is seen by whoever sees that one, and made after it.
@(component,description="The network replicates this entity: the server sends it to the clients that should see it.")
Replicate :: struct {
    simulation:Simulation,
    audience:Audience,
    priority:f32 `mirai:"min=0"`,
    update_hz:f32 `mirai:"min=0"`, // 0: publish every tick
    radius:f32 `mirai:"min=0,unit=m"`,
}

REPLICATE_DEFAULT :: Replicate{priority=1,radius=1}

// What the network knows of an entity it replicates: its object. Only this library writes it.
@(component)
Net_Link :: struct {
    object:Object `mirai:"transient,readonly,local"`,
}

// First fragment of every object. id is the Id of the entity in the scene both
// ends loaded: a client that has that entity takes it instead of making one;
// otherwise it makes it of prefab, the one it was spawned from. sections are
// the Ids of the references of the sections it is in: first the one it hangs
// from, 0 for the root, then each other whose box holds it. A client takes
// the entity of the first while it has it loaded, and makes its own while it
// has only another; with none, it waits. disabled: the entity is off on the
// server, by a Disabled that is not its section's; its replica is off while
// it says so.
Pose :: struct {
    id:base.Entity_Id,
    prefab:base.Asset_Id,
    sections:[wire.OBJECT_GROUPS]base.Entity_Id,
    position:[3]f32 `mirai:"precision=0.001"`,
    rotation:mm.Quat `mirai:"bits=15"`,
    scale:[3]f32,
    off:u16 `mirai:"bits=13"`, // a bit by replicated component of its type: turned off by itself
    disabled:bool,
}
#assert(COMPONENTS<=13)

// The velocities of a replica a simulation moves, after its pose.
Motion_State :: struct {
    linear:[3]f32 `mirai:"precision=0.001"`,
    angular:[3]f32 `mirai:"precision=0.001"`,
}

// What a client sends the server every tick: the actions of the seat that
// drives its body (input.Remote_Actions), where that body looks after it,
// and the tick of the server it showed the others at when it took them
// (Clock.display), for the server to see the world as that player saw it
// (rewind.odin). The devices, their bindings and the input contexts stay on
// the client: the server takes the actions as they were there.
//
// The look goes whole, not only as the mouse that turned it: an input that
// arrives late is repeated, and one that arrives after its tick is dropped,
// so the server summing mouse deltas drifts away from where the player looks
// and never comes back.
Input_Packet :: struct {
    actions:input.Remote_Actions,
    // The look of the Move_Input of the body it drives, radians: the yaw
    // wrapped to a turn (the server keeps its whole turns), the pitch as is.
    look_yaw:f32 `mirai:"min=-3.1416,max=3.1416,precision=0.0001"`,
    look_pitch:f32 `mirai:"min=-1.6,max=1.6,precision=0.0001"`,
    has_look:bool,
    // How many ticks before the one of this input the others were shown at,
    // with fraction; has_view false while the clock has not placed it.
    view_behind:f32 `mirai:"min=0,max=255,precision=0.00390625"`,
    has_view:bool,
}

// What drives a replicated body: its Move_Input, which every end that has it
// sees. The actions of a player go only to the server (input_submit).
@(private)
Driver_State :: struct {
    has_move:bool,
    move:input.Move_Input,
}

// Tuning of the session; 0 takes the default. Read when the network opens.
@(storage,host,setting)
Net_Settings :: struct {
    protocol_id:u32,
    version:u32,
    seed:u64,
    port:int `mirai:"min=0,max=65535"`, // UDP: the one a server opens without --server <port>, and a client joins at an address without one. DEFAULT_PORT
    max_clients:int,         // server. 32
    timeout:f64,             // seconds of silence after which the other end is given up. 10
    connect_timeout:f64,     // client. 5
    max_objects:int,         // replicated entities; a client needs as many as its server. 1024
    max_resimulate:int,      // client: ticks it may simulate again in one frame; what does not fit is closed by correction_time. 0.3 s of ticks, at most the history (replication.history_seconds)
    resimulate_budget:int,   // client: ticks it may simulate again per second. The tick rate
    critical_ticks:int,      // client: ticks a replica stays critical after it last shared an island of the simulation with what the client drives. Half a second
    predicted_capacity:int,  // client: replicas simulated ahead of the server at once. 256
    // client: what the server simulates and this client does not drive is shown interpolated,
    // behind the server by Clock.display, instead of simulated ahead: where it was, not where it
    // may be. Hits are then judged in that past (rewind.odin).
    interpolate_others:bool,
    view_radius:f32,         // server: meters around what a connection owns that count as near. 128
    position_tolerance:f32,  // client: meters a prediction may be off before it is corrected. 0.05
    velocity_tolerance:f32,  // m/s and rad/s. 0.5
    rotation_tolerance:f32,  // radians. 0.07
    scale_tolerance:f32,     // 0.001
    correction_time:f32,     // client: seconds in which an error that is not simulated again is closed by two thirds. 0.1
    sync_test:int,           // client, to debug: ticks it goes back before each frame to run each again and compare with the first time (net.sync_test); 0: none. At most the history
    // server: seconds the view a client says it saw (Input_Packet.view_behind) may be off from
    // the one its round trip, jitter, input lead and interpolation delay give, before the server
    // takes the latter instead. 0.2; negative: the client is believed, within REWIND_SECONDS and the history
    rewind_tolerance:f32,
    absent_seconds:f64,      // server: seconds the seat of a player who left waits off for that player to come back. 300; negative: it goes when they leave
    replication:wire.Replication_Desc,
}

Connection_Event_Kind :: enum u8 {
    Connected,
    Disconnected,
    Entered, // server: the connection is in the world of the server, once it arrives and after each scene that replaces it; only then does what the game sends reach it
}

// Event: who arrived, entered the world or left (server), or the server itself (client).
Connection_Event :: struct {
    kind:Connection_Event_Kind,
    connection:Connection,
    reason:Disconnect_Reason,
}

// Who arrived and who left, for the fixed functions: at the start of each tick
// the network leaves here what happened since the tick before. A frame
// without ticks keeps it for the next tick, and of a frame with several only
// the first has it.
@(storage)
Net_Connections :: struct {events:core.Queue(Connection_Event)}

// An event of the protocol that arrived: read it with event_read.
Received :: struct {
    type:typeid,
    sender:Connection, // server: the client that sent it
    about:core.Entity,
    size:u16,
    data:[EVENT_BYTES]u8,
}

// The messages that arrived, for the fixed functions, like Net_Connections: at
// the start of each tick the network leaves here what arrived since the tick
// before. A frame without ticks keeps them for the next tick, of a frame with
// several only the first has them, and a tick that runs again has those it had.
@(storage)
Net_Events :: struct {
    received:core.Queue(Received),
}

// An event to send. Requests: the games push, this library takes them.
Outgoing :: struct {
    type:typeid,
    about:core.Entity,
    to:Connection,
    size:u16,
    data:[EVENT_BYTES]u8,
}

// Not copied with the world: a correction that brings back an older copy
// keeps what waits to be sent.
@(storage,queue,copy=false)
Net_Outbox :: struct {
    queue:core.Queue(Outgoing),
    replaying:bool `mirai:"readonly"`, // the tick under way runs again: it sent the first time
}

// Client: ticks the client already simulated that a library learned were
// different, from a reason the network does not compare, as a fracture of
// the server: the earliest goes back and runs again in the same frame
// (net_rewind), when the history and the budget allow it. Not copied with the
// world: a correction does not take back what was asked.
@(storage,queue,copy=false)
Net_Rewinds :: struct {queue:core.Queue(u32)}

rewind :: proc(rewinds:^Net_Rewinds,tick:u32) {core.push(&rewinds.queue,tick)}

// Client: entities a library made here for what a replica of the server
// stands for, by the Id both ends give it. At the end of the tick each takes
// the place of the entity of its replica.
Adoption :: struct {
    id:base.Entity_Id,
    entity:core.Entity,
}

@(storage,queue)
Net_Adoptions :: struct {queue:core.Queue(Adoption)}

adopt :: proc(adoptions:^Net_Adoptions,id:base.Entity_Id,e:core.Entity) {core.push(&adoptions.queue,Adoption{id,e})}

// The actions a connection sent for the tick being simulated, on a server.
// Updated at the start of every tick; status says whether they arrived in time.
// player is the hash of the secret its client presented, 0 until it did: then
// it is seated.
Remote_Input :: struct {
    connection:Connection,
    player:u64,
    actions:input.Remote_Actions,
    status:wire.Input_Status,
    tick:u32,
    view:f64, // the tick of the server, with fraction, its client showed the others at when it sent this input; 0: unknown
    look:[2]f32, // yaw and pitch of the body it drives, as its client left them
    has_look:bool,
}

// The connections stay when a scene replaces the world, and so do their seats.
// An entry by the index of its connection, as the host numbers them; a free
// one has no connection.
@(storage,keep)
Remote_Inputs :: struct {entries:[dynamic]Remote_Input}

// Server: the seat of a player who left, off (core.Disabled) until that player
// connects again, or until the tick past which it goes; 0: until the game
// destroys it, as the seats of a saved game.
@(component,description="The seat of a player who left: it waits, off, for that player to come back.")
Seat_Absent :: struct {
    until:u64 `mirai:"readonly"`,
}

// What a session says of itself, besides what the game sends. The server
// tells a client that arrives, and every client when a scene replaces the
// world, the scene it is and the number of that change (scene.Scene_Root),
// and the connection of that client; the client loads that scene and says it
// did, and only then does the server replicate the world to it.
@(net_message,reliable)
Net_World :: struct {
    scene:base.Asset_Id,
    changes:u32,
    connection:Connection,
}

@(net_message,from="client",reliable)
Net_World_Ready :: struct {changes:u32}

// A client, as it connects, once: the secret of the player it is. The server
// keeps only its hash, the id that gets back the seat that player left, and
// nobody else hears either: no client can be another player without its secret.
@(net_message,from="client",reliable)
Net_Player :: struct {secret:[2]u64}

// A client: a section of the world it has loaded, or no longer has, in the
// world of a change (Net_World). The server replicates what is in a section
// only to the clients that have it.
@(net_message,from="client",reliable)
Net_Section :: struct {
    id:base.Entity_Id, // of the entity of its reference
    changes:u32,
    loaded:bool,
}

GONE_IDS :: 16

// The server: entities of the scene of a section that are not in it any
// more, destroyed or gone elsewhere, by their Ids in the world, in the world
// of a change (Net_World). A client that has the section loaded takes them out
// of it, but what a replica of it holds: what the server keeps of a section
// wins over what a client kept. A client hears those of a section as it
// loads it, and each one that goes while it has it, whether it sees it or not.
@(net_message,reliable)
Net_Gone :: struct {
    section:base.Entity_Id, // of the entity of its reference
    changes:u32,
    count:u8,
    ids:[GONE_IDS]base.Entity_Id,
}

// The player of this machine to the servers it joins: a secret that the
// network makes the first time a client of this world connects and keeps in
// the profile of the player (the save library writes it), so that the player
// gets its seat back after the game closes. Only the network writes it.
@(storage,persist)
Net_Identity :: struct {secret:[2]u64}

// Sends a message, a @(net_message): from a server to one connection, or to every one
// that has the entity it is about (to all when it is about none); from a
// client, to the server. False in a tick that runs again: it sent the first time.
send :: proc(outbox:^Net_Outbox,value:$T,about:=core.NONE,to:Connection=0) -> bool {
    #assert(size_of(T)<=EVENT_BYTES)
    if outbox.replaying {return false}
    value:=value
    item:=Outgoing{type=T,about=about,to=to,size=size_of(T)}
    copy(item.data[:],([^]u8)(&value)[:size_of(T)])
    core.push(&outbox.queue,item)
    return true
}

// The value of a received event, when it is a T.
event_read :: proc(item:Received,$T:typeid) -> (value:T,ok:bool) {
    if item.type!=T || int(item.size)!=size_of(T) {return}
    item:=item
    copy(([^]u8)(&value)[:size_of(T)],item.data[:size_of(T)])
    return value,true
}
