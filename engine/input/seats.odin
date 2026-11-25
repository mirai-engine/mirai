package input

import "mirai:core"
import "mirai:host"

// Who drives what. A seat is someone who plays: at this machine (a slot), or
// at another end of the network (core.Remote on a client; on a server, a seat
// the network made for a connection). Each seat carries the actions of the
// input map for the tick, where it looks (Seat_View) and the body it drives
// (Seat.body), whose Move_Input those actions become (engine/camera: forward
// is where its camera looks). A body no seat drives takes its Move_Input from
// its AI or a script (move_set). This library owns Seat.body. Other libraries
// request changes through Seat_Requests.
//
// A request is applied at the start of the next fixed tick. A seat drives
// one body at most and a body has one seat. Held buttons wait for their
// release when the body or the blocks of a seat change, so a jump held before
// the change does not happen in the new body, and the body a seat lets go of
// stops: its move and buttons are cleared. In a network session the server
// decides who drives what: the network replicates Seat.body, a client takes
// only the bodies it owns (core.owned), and lets go of any.

LOCAL_CAPACITY :: 4
BLOCK_CAPACITY :: 64

// The axes move is in. A body that walks takes it in the world, toward the
// view of its seat; one that steers itself (a boat, a turret: the vehicles
// plugin) takes it in its own axes, and its seat gives it only where it looks
// and its buttons: what moves it reads the actions of its own context.
Move_Frame :: enum u8 {
    View, // move is in the world, across or along the up of the body
    Body, // move is in the axes of the body: right, up and back (+Z; it faces -Z), each -1 to 1
}

// The movement and actions asked of a body: by the seat that drives it, and
// without one by its AI or a script (move_set).
@(component,shared,description="What the body is asked this tick: where to go and where to look, from the seat that drives it or else from its AI or a script.")
Move_Input :: struct {
    move:[3]f32 `mirai:"readonly"`,                // View: in the world, across the up of the body (core.Vertical) it walks and along it modes that fly, a share of the top speed up to 1 long, with world_velocity m/s. Body: right, up and back of the body, each -1 to 1
    look_yaw,look_pitch:f32 `mirai:"readonly,angle"`, // where it looks and faces: yaw turns left about the up of the body, pitch looks up; at 0 it looks along -Z, as everything does. Ground that turns adds to it (core.Vertical.turn) through whoever writes it
    world_velocity:bool `mirai:"readonly"`,        // View: move is a velocity in m/s, as AI and scripts ask, bounded by the top speed of the mode; a seat asks a share
    frame:Move_Frame,                              // the axes of move, as its prefab says: what writes the input keeps it
    buttons:Action_Mask `mirai:"readonly"`,        // the button actions held
}
#assert(size_of(Move_Input)==32)

// The Move_Input of a body no seat drives, as its AI or a script asks it:
// false, and nothing written, while a seat drives it, whose actions are its
// Move_Input then. A body that has one keeps its frame.
move_set :: proc(moves:^core.Table(Move_Input),state:core.Ref(Seats),body:core.Entity,value:Move_Input) -> bool {
    if seat_of(state,body)!=core.NONE {return false}
    if row:=core.staged(moves,body);row!=nil {
        frame:=row.frame
        row^=value
        row.frame=frame
    } else if !core.add(moves,body,value) {return false}
    return true
}

// A body no seat drives is asked nothing more by its AI or a script: its
// Move_Input goes, and it keeps facing where it faces. Nothing while a seat
// drives it.
move_release :: proc(moves:^core.Table(Move_Input),state:core.Ref(Seats),body:core.Entity) {
    if seat_of(state,body)==core.NONE {core.remove(moves,body)}
}

// Someone who plays: at this machine, the seat of a slot, made at runtime for
// every slot below the number of local players when the scene has none (a
// network client makes none: it plays at the seat its server gives it); at
// another end, the seat of a player that connected, which the network makes
// on a server, replicates to every client with the body it drives and what
// the game hangs from it, and marks remote on each end but the one of its
// player. Its actions come from the devices of its slot, or from the network
// for another end.
@(component,shared,replicated,description="Someone who plays: at this machine (slot 0 is the first one; the keyboard and the mouse go to the focused slot, gamepad i to slot i), or at another end of the network.")
Seat :: struct {
    slot:u8 `mirai:"max=3"`,
    remote:bool `mirai:"transient,readonly,local"`, // its actions come from another end of the network (seat_receive), not from the devices of its slot: the network sets it
    body:core.Entity,                               // the body it drives: a seat of a scene drives it from the start; none: none
}

// Where a seat looks in a tick: through the camera it saw the game through
// when the tick began. It is of the tick as its actions are: this machine takes
// it from the view it drew (Slot_Views), the network from the end of the
// player, so every end moves the body toward the same forward (engine/camera)
// and aims from the same ray (aim) whatever its own cameras did.
Seat_View :: struct {
    yaw:f32 `mirai:"min=-3.1416,max=3.1416,precision=0.0001"`, // radians in the frame of the vertical of its body (core.Vertical): left about its up, 0 along -Z
    pitch:f32 `mirai:"min=-1.6,max=1.6,precision=0.0001"`,     // radians up from across its up
    eye:[3]f32 `mirai:"min=-16,max=16,precision=0.01,unit=m"`, // where the camera was from the body, in the frame of its vertical; 0 for a camera farther than VIEW_EYE_REACH
    kind:View_Kind `mirai:"bits=2"`,
}

VIEW_EYE_REACH :: 16 // m

View_Kind :: enum u8 {
    None,  // it saw through no camera
    Apart, // a camera that turns apart from its body: it walks where the camera looks
    Body,  // a camera that looks with its body (Eyes, an Orbit that aims, one on the body): the look of its Move_Input
}

// Where each local slot looked as the last frame was drawn, by slot: the
// camera library writes it as it draws, and input_seats gives it to the seat
// of the slot for the tick, as it gives the devices.
@(storage)
Slot_Views :: struct {
    views:[LOCAL_CAPACITY]Seat_View,
}

Seat_Sample :: struct {
    actions:Actions,
    held:Action_Mask,
    rearm:Action_Mask, // held buttons that wait for their release
    fed:Context_Stack, // contexts where the actions were last computed
    view:Seat_View,
}

Seat_State :: struct {
    using sample:Seat_Sample,
    blocked:Action_Mask,
    contexts:Context_Stack,
    holds:[HOLD_CAPACITY]Action_Hold, // actions given besides its devices (holds.odin)
    hold_count:u8,
}

@(storage,shared)
Seat_States :: struct {
    entries:core.Entity_Map(Seat_State),
    seen:core.Seen,
}

seat_runtime :: proc "contextless" (states:core.Ref(Seat_States),seat:core.Entity) -> ^Seat_State {
    return states.ptr==nil?nil:core.entity_map_get(&states.entries,seat)
}

seat_runtime_edit :: proc(states:^Seat_States,seat:core.Entity) -> ^Seat_State {
    if states==nil {return nil}
    if value:=core.entity_map_get(&states.entries,seat);value!=nil {return value}
    value,_:=core.entity_map_put(&states.entries,seat,Seat_State{})
    return value
}

// A seat of this machine: not one of another end.
seat_local :: #force_inline proc "contextless" (seat:Seat) -> bool {return !seat.remote}

// How many players share this machine, each with a part of the screen: of
// the run, which the editor sets before the first tick of its runs and a
// player takes from --players (app.launch.players); 0: one, none on a server.
// It stays when the world loads another scene or a save.
@(storage,keep)
Run_Players :: struct {
    count:int,
}

// Actions of a seat, or of every seat of this machine (seat none), that
// something took away, until its owner gives them back.
Block :: struct {
    owner,seat:core.Entity,
    mask:Action_Mask,
    active:bool,
}

// What this library derives and is asked while the world runs. Loading a
// scene or a save starts it again: the libraries that asked for blocks ask again.
@(storage)
Seats :: struct {
    local_count:int,      // players at this machine
    focus:int,            // the local slot the keyboard and the mouse go to
    keyboard:int,         // the slot that had them last tick, plus one; 0: none
    blocks:[BLOCK_CAPACITY]Block,
    drivers:core.Entity_Map(core.Entity),
    riders:core.Entity_Map(Rider), // the seat of each rider of a Mount (mounts.odin)
    seen:core.Seen,
}

Request_Kind :: enum u8 {
    Drive,        // seat takes entity; none releases
    Release,      // seat lets go of its body
    Focus,        // the keyboard and the mouse go to the local seat of slot
    Block_Add,    // owner takes the actions in mask from seat; none: from every local seat
    Block_Remove,
    Mount,        // the body of seat rides entity, a Mount, and seat drives what the mount drives
    Dismount,     // the rider of the mount seat drives from gets off, and seat drives it again
}

Seat_Request :: struct {
    kind:Request_Kind,
    seat:core.Entity,
    entity:core.Entity,
    owner:core.Entity,
    slot:int,
    mask:Action_Mask,
}

@(storage,queue)
Seat_Requests :: struct {
    using queue:core.Queue(Seat_Request),
}

drive :: proc(r:^Seat_Requests,seat,body:core.Entity) {
    core.offer(&r.queue,Seat_Request{kind=.Drive,seat=seat,entity=body})
}
release :: proc(r:^Seat_Requests,seat:core.Entity) {
    core.offer(&r.queue,Seat_Request{kind=.Release,seat=seat})
}
focus :: proc(r:^Seat_Requests,slot:int) {
    core.offer(&r.queue,Seat_Request{kind=.Focus,slot=slot})
}
input_block :: proc(r:^Seat_Requests,owner,seat:core.Entity,mask:=ALL_ACTIONS) {
    core.offer(&r.queue,Seat_Request{kind=.Block_Add,owner=owner,seat=seat,mask=mask})
}
input_unblock :: proc(r:^Seat_Requests,owner:core.Entity) {
    core.offer(&r.queue,Seat_Request{kind=.Block_Remove,owner=owner})
}

// The body a seat drives; none without one.
body_of :: proc(seats:^core.Table(Seat,$A),seat:core.Entity) -> core.Entity {
    value,_:=core.get(seats,seat)
    return value.body
}

// The seat that drives a body, or whose actions a rider that keeps its input
// reads (Mount.keep_input); none without one.
seat_of :: proc "contextless" (state:core.Ref(Seats),body:core.Entity) -> core.Entity {
    if state.ptr!=nil {
        if seat:=core.entity_map_get(&state.drivers,body);seat!=nil {return seat^}
        if rider:=core.entity_map_get(&state.riders,body);rider!=nil && rider.keep_input {return rider.seat}
    }
    return core.NONE
}

// The seat that drives a body; none without one, as for a rider.
driver_of :: proc "contextless" (state:core.Ref(Seats),body:core.Entity) -> core.Entity {
    if state.ptr!=nil {
        if seat:=core.entity_map_get(&state.drivers,body);seat!=nil {return seat^}
    }
    return core.NONE
}

@(step="fixed",stage="input",before="input_seats")
input_seat_index :: proc(es:core.Ref(core.Entities),seats:^core.Table(Seat,.Read),state:^Seats,problems:^core.Problems) {
    seat_index_sync(es,seats,state,problems)
}

@(private)
seat_index_sync :: proc(es:core.Ref(core.Entities),seats:^core.Table(Seat,.Read),state:^Seats,problems:^core.Problems) -> bool {
    seen:=state.seen
    if !core.touched(seats,&seen) {return true}
    index:=&state.drivers
    indices:=len(index.rows)
    for &slot in seats.values[:core.count(seats)] {
        if core.alive(es.ptr,slot.body) {indices=max(indices,core.entity_index(slot.body)+1)}
    }
    if !core.entity_map_reserve(index,core.count(seats),indices) {
        core.report(problems,core.NONE,"input.seat_index","out of memory for the body-to-seat index; free memory")
        return false
    }
    core.entity_map_clear(index)
    for &slot,row in seats.values[:core.count(seats)] {
        if !core.alive(es.ptr,slot.body) || core.entity_map_get(index,slot.body)!=nil {continue}
        core.entity_map_put(index,slot.body,core.entity_at(seats,row))
    }
    state.seen=seen
    return true
}

// The seat of a local slot; none without one.
local_seat :: proc(seats:^core.Table(Seat,$A),slot:int) -> core.Entity {
    for &seat,row in seats.values[:core.count(seats)] {
        if seat_local(seat) && int(seat.slot)==slot {return core.entity_at(seats,row)}
    }
    return core.NONE
}

// The local seat with the keyboard and the mouse.
focused :: proc(state:core.Ref(Seats),seats:^core.Table(Seat,$A)) -> core.Entity {
    return state.ptr!=nil && state.local_count>0?local_seat(seats,state.focus):core.NONE
}

// Where a seat looks this tick (Seat_View); none for what is not a seat.
seat_view :: proc "contextless" (states:core.Ref(Seat_States),seat:core.Entity) -> Seat_View {
    source:=seat_runtime(states,seat)
    return source!=nil?source.view:{}
}

// The state of an action of a seat this tick: released while it is blocked
// or waits for its release, and for what is not a seat. Code reads its own
// actions with seat_state and Input_Of.
seat_action :: proc(states:core.Ref(Seat_States),seat:core.Entity,a:Action) -> Action_State {
    source:=seat_runtime(states,seat)
    if source==nil {return {}}
    if (source.blocked|source.rearm)&action_bit(a)!=0 {return {}}
    return action(&source.actions,a)
}

// The state of an action of a seat as the owner of blocks sees it: past its
// own blocks, so that what takes the actions of a seat (a modal screen) still
// gets them; released while a block of another owner takes it or it waits
// for its release.
seat_action_for :: proc(state:core.Ref(Seats),states:core.Ref(Seat_States),seats:^core.Table(Seat,$A),seat:core.Entity,a:Action,owner:core.Entity) -> Action_State {
    if !core.has(seats,seat) {return {}}
    source:=seat_runtime(states,seat)
    if source==nil {return {}}
    bit:=action_bit(a)
    if source.rearm&bit!=0 {return {}}
    if source.blocked&bit!=0 {
        if state.ptr==nil || owner==core.NONE {return {}}
        local:=seat_local(core.get(seats,seat) or_else Seat{})
        for block in state.blocks {
            if block.active && block.owner!=owner && block.mask&bit!=0 && (block.seat==seat || block.seat==core.NONE && local) {return {}}
        }
    }
    return action(&source.actions,a)
}

// The button actions of a seat that are down this tick, as seat_down sees them.
seat_buttons :: proc(states:core.Ref(Seat_States),seat:core.Entity,bindings:core.Ref(Input_Map)) -> (mask:Action_Mask) {
    source:=seat_runtime(states,seat)
    if source==nil {return}
    for state,i in source.actions.states[:source.actions.count] {
        if state.down && bindings.actions[i].kind==.Button {mask|=action_bit(Action(i))}
    }
    return mask&~(source.blocked|source.rearm)
}

// The state of an action of the seat that drives a body this tick; released
// while nobody drives it.
body_action :: proc(state:core.Ref(Seats),states:core.Ref(Seat_States),body:core.Entity,a:Action) -> Action_State {
    return seat_action(states,seat_of(state,body),a)
}

// The seats of this machine: how many there are, and the actions of each for
// the tick. The keyboard and the mouse go to the focused one; with several,
// gamepad i goes to slot i, and with one, every gamepad to it. The seats of
// other ends get their actions from the network.
@(step="fixed",stage="input")
input_seats :: proc(
    es:core.Commands,app:^host.App,seats:^core.Table(Seat),state:^Seats,run:^Run_Players,
    states:^Seat_States,device:core.Input,views:core.Ref(Slot_Views),bindings:core.Ref(Input_Map),network:core.Ref(core.Network),keeps:^core.Table(core.Keep),time:core.Time,
) {
    if run.count==0 {run.count=app.launch.players}
    // A server has players of its own only when the run asks for them: one
    // that is also a player, as the Play of an editor that serves.
    count:=clamp(run.count,1,LOCAL_CAPACITY)
    if run.count==0 && network.role==.Server {count=0}
    state.local_count=count
    state.focus=clamp(state.focus,0,max(count-1,0))
    // A client makes none: its server gives it the seat of its player.
    for slot in 0..<(network.role==.Client?0:count) {
        if local_seat(seats,slot)==core.NONE {
            seat:=core.create(es)
            core.add(seats,seat,Seat{slot=u8(slot)})
            // A player stays at the machine when the scene changes.
            if keeps!=nil {core.add(keeps,seat,core.Keep{})}
        }
    }
    for &seat,row in seats.values[:core.count(seats)] {
        if !seat_local(seat) {continue}
        slot:=int(seat.slot)
        own:=slot<count?slot_input(device,slot,count,state.focus):core.Input{}
        fed:=seat_runtime_edit(states,core.entity_at(seats,row))
        seat_feed(fed,&own,bindings.ptr,slot<count && slot==state.focus && state.keyboard!=0 && state.keyboard!=slot+1,time.dt)
        if fed!=nil {fed.view=slot<count && views.ptr!=nil?views.views[slot]:{}}
    }
    state.keyboard=count>0?state.focus+1:0
}

// The actions of a seat from a device and its holds for the tick, in its contexts. One that
// got the device from another (gained) waits for the release of what it
// holds; one whose contexts changed, for the release of the buttons that went
// down with the change, as jump on the button that closed a menu.
seat_feed :: proc(seat:^Seat_State,device:^core.Input,bindings:^Input_Map,gained:bool,dt:f32) {
    if seat==nil {return}
    before:=seat.held
    actions_update(&seat.actions,bindings,device,dt,&seat.contexts,seat.holds[:seat.hold_count])
    seat.held=held_buttons(&seat.actions,bindings)
    if gained {seat.rearm|=seat.held}
    if seat.fed!=seat.contexts {
        seat.rearm|=seat.held&~before
        seat.fed=seat.contexts
    }
    seat.rearm&=seat.held
}

// The devices of a local slot: the keyboard and the mouse when it has the
// focus, and its gamepad when the machine has several players.
slot_input :: proc "contextless" (device:core.Input,slot,count,focus:int) -> (own:core.Input) {
    own=device
    if slot!=focus {
        own.keys_down,own.keys_pressed,own.keys_released={},{},{}
        own.mouse_down,own.mouse_pressed,own.mouse_released={},{},{}
        own.mouse_delta,own.wheel={},{}
    }
    if count>1 {
        for &pad,index in own.gamepads {
            if index!=slot {pad={}}
        }
    }
    return
}

@(private)
held_buttons :: proc "contextless" (actions:^Actions,bindings:^Input_Map) -> (mask:Action_Mask) {
    for state,i in actions.states[:actions.count] {
        if state.down && !state.released && bindings.actions[i].kind==.Button {mask|=action_bit(Action(i))}
    }
    return
}

@(private)
Apply :: struct {
    es:^core.Entities,
    moves:^core.Table(Move_Input),
    seats:^core.Table(Seat),
    state:^Seats,
    states:^Seat_States,
    role:core.Network_Role,
    elsewhere:^core.Table(core.Remote,.Read),
    mounts:^core.Table(Mount),
    carried:^core.Table(core.Carried,.Read),
    parents:^core.Table(core.Parent,.Read),
    exits:Mount_Exits,
    problems:^core.Problems,
}

// Who drives what, focus and blocks as they were asked, then the references
// to what no longer exists are dropped and each seat takes the actions its
// blocks take.
@(step="fixed",stage="input")
input_drive :: proc(
    es:core.Ref(core.Entities),moves:^core.Table(Move_Input),seats:^core.Table(Seat),state:^Seats,states:^Seat_States,requests:^Seat_Requests,
    network:core.Ref(core.Network),elsewhere:^core.Table(core.Remote,.Read),mounts:^core.Table(Mount),carried:^core.Table(core.Carried,.Read),exits:Mount_Exits,problems:^core.Problems,
) {
    a:=Apply{es=es.ptr,moves=moves,seats=seats,state=state,states=states,role=network.role,elsewhere=elsewhere,mounts=mounts,carried=carried,parents=exits.parents,exits=exits,problems=problems}
    core.queue_serve(&requests.queue,BLOCK_CAPACITY*2,problems,"input.seats_requests",
        "seat requests","the input request capacity")
    if !seat_index_sync(es,core.read(seats),state,problems) {return}
    for request in core.take(&requests.queue) {request_apply(&a,request)}
    upkeep(&a)
    mounts_upkeep(&a)
    blocks_apply(seats,state,states)
}

// Each seat takes the actions its active blocks take.
@(private)
blocks_apply :: proc(seats:^core.Table(Seat),state:^Seats,states:^Seat_States) {
    for row in 0..<core.count(seats) {
        e:=core.entity_at(seats,row)
        mask:Action_Mask
        local:=seat_local(seats.values[row])
        for block in state.blocks {
            if block.active && (block.seat==e || block.seat==core.NONE && local) {mask|=block.mask}
        }
        if source:=seat_runtime(core.ref(states),e);source!=nil {source.blocked=mask}
    }
}

@(private)
request_apply :: proc(a:^Apply,r:Seat_Request) {
    state:=a.state
    switch r.kind {
    case .Drive:
        refusal_report(a,r,body_assign(a,r.seat,r.entity))
    case .Release:
        refusal_report(a,r,body_assign(a,r.seat,core.NONE))
    case .Mount:
        refusal_report(a,r,mount_apply(a,r))
    case .Dismount:
        refusal_report(a,r,dismount_apply(a,r))
    case .Focus:
        if r.slot<0 || r.slot>=LOCAL_CAPACITY {
            core.report(a.problems,core.NONE,"input.focus_slot","the keyboard and the mouse were asked to go to the local seat of slot %d; the slots of local seats are 0 to %d",r.slot,LOCAL_CAPACITY-1)
            return
        }
        state.focus=r.slot
    case .Block_Add:
        switch {
        case r.mask==0:
            core.report(a.problems,r.owner,"input.block_mask","an input block that takes no action (mask 0) was refused; pass the bits of the actions to take, or ALL_ACTIONS")
        case r.seat!=core.NONE && !core.alive(a.es,r.seat):
            core.report(a.problems,r.owner,"input.block_seat","an input block of seat 0x%016x was refused: that seat is not alive; block a live seat",u64(r.seat))
        case !block_set(state,a.seats,a.states,r):
            core.report(a.problems,r.owner,"input.blocks_full","an input block was refused: %d input blocks are active, as many as fit; remove the ones no longer needed with input_unblock",BLOCK_CAPACITY)
        }
    case .Block_Remove:
        block_clear(state,a.seats,a.states,r.owner)
    }
}

// Why a request to drive a body was refused.
@(private)
Refusal :: enum u8 {None,Not_A_Seat,Not_Alive,Taken,Server_Decides,Capacity,Not_A_Mount,No_Body,Mount_Taken,Riding,Rides_Itself,Not_Riding,Exits_Blocked}

@(private)
refusal_report :: proc(a:^Apply,r:Seat_Request,refusal:Refusal) {
    request:="releasing its body"
    #partial switch r.kind {
    case .Drive:    request="driving a body"
    case .Mount:    request="riding a mount"
    case .Dismount: request="getting off a mount"
    }
    switch refusal {
    case .None:
    case .Not_A_Seat:
        core.report(a.problems,core.alive(a.es,r.entity)?r.entity:core.NONE,"input.not_a_seat","%s was refused: entity 0x%016x is not a live Seat; ask with the seat of a player (local_seat, or the seat of a connection)",request,u64(r.seat))
    case .Not_Alive:
        core.report(a.problems,r.seat,"input.body_gone","driving entity 0x%016x was refused: it is not alive; drive a live body",u64(r.entity))
    case .Taken:
        core.report(a.problems,r.seat,"input.body_taken","driving entity 0x%016x was refused: another seat drives it; release it first",u64(r.entity))
    case .Capacity:
        core.report(a.problems,r.seat,"input.seat_index","out of memory for the body-to-seat index; free memory and ask to drive again")
    case .Server_Decides:
        core.report(a.problems,r.seat,"input.server_decides","%s was refused: a client takes only the bodies it owns and rides no mount; in a network game ask the server, which decides who drives each body",request)
    case .Not_A_Mount:
        core.report(a.problems,r.seat,"input.not_a_mount","riding entity 0x%016x was refused: it is not a live Mount; give it a Mount, or ride another",u64(r.entity))
    case .No_Body:
        core.report(a.problems,r.seat,"input.mount_no_body","riding a mount was refused: the seat drives no body to ride it; drive a body first")
    case .Mount_Taken:
        core.report(a.problems,r.seat,"input.mount_taken","riding entity 0x%016x was refused: another body rides it; ride another, or wait until it gets off",u64(r.entity))
    case .Riding:
        core.report(a.problems,r.seat,"input.mount_riding","riding a mount was refused: the body of the seat rides one already; dismount first")
    case .Rides_Itself:
        core.report(a.problems,r.seat,"input.mount_itself","riding entity 0x%016x was refused: that mount hangs from the body that would ride it",u64(r.entity))
    case .Not_Riding:
        core.report(a.problems,r.seat,"input.not_riding","getting off a mount was refused: the seat drives from no mount; ask it of the seat whose body rides")
    case .Exits_Blocked:
        core.report(a.problems,r.seat,"input.mount_blocked","getting off a mount was refused: something stands at every exit of the mount; move the mount, or give it an exit with room (Mount.exits)")
    }
}

// Whether this end decides who drives a body: a server or a game alone
// always; a client, only the bodies it owns or does not replicate.
@(private)
decides :: proc(a:^Apply,body:core.Entity) -> bool {
    return body==core.NONE || a.role!=.Client || core.owned(a.elsewhere,body)
}

@(private)
seated :: proc(a:^Apply,seat:core.Entity) -> bool {
    return core.alive(a.es,seat) && core.has(a.seats,seat)
}

@(private)
body_assign :: proc(a:^Apply,seat,body:core.Entity) -> Refusal {
    if !seated(a,seat) {return .Not_A_Seat}
    if body!=core.NONE {
        if !core.alive(a.es,body) {return .Not_Alive}
        if driver:=driver_of(core.ref(a.state),body);driver!=core.NONE && driver!=seat {return .Taken}
    }
    // Letting go decides nothing of a body: a client lets go of what the server gave someone else.
    if !decides(a,body) {return .Server_Decides}
    previous:=body_of(a.seats,seat)
    if previous==body {return .None}
    if body!=core.NONE {
        if _,ok:=core.entity_map_put(&a.state.drivers,body,seat);!ok {return .Capacity}
    }
    core.edit(a.seats,seat).body=body
    if driver_of(core.ref(a.state),previous)==seat {core.entity_map_remove(&a.state.drivers,previous)}
    if left:=core.edit(a.moves,previous);left!=nil {left.move,left.buttons={},{}}
    if source:=seat_runtime(core.ref(a.states),seat);source!=nil {source.rearm|=source.held}
    return .None
}

@(private)
block_set :: proc(state:^Seats,seats:^core.Table(Seat),states:^Seat_States,r:Seat_Request) -> bool {
    free:^Block
    for &item in state.blocks {
        if item.active && item.owner==r.owner {
            free=&item
            break
        }
        if !item.active && free==nil {free=&item}
    }
    if free==nil {return false}
    if free.active && free.seat!=r.seat {block_release(seats,states,free)}
    free^={owner=r.owner,seat=r.seat,mask=r.mask,active=true}
    return true
}

// What the block held back and is still held waits for its release.
@(private)
block_release :: proc(seats:^core.Table(Seat),states:^Seat_States,block:^Block) {
    if !block.active {return}
    for row in 0..<core.count(seats) {
        e,source:=core.entity_at(seats,row),&seats.values[row]
        if e!=block.seat && !(block.seat==core.NONE && seat_local(source^)) {continue}
        if runtime:=seat_runtime(core.ref(states),e);runtime!=nil {runtime.rearm|=runtime.held&block.mask}
    }
    block.active=false
}

@(private)
block_clear :: proc(state:^Seats,seats:^core.Table(Seat),states:^Seat_States,owner:core.Entity) {
    for &item in state.blocks {
        if item.active && item.owner==owner {block_release(seats,states,&item)}
    }
}

// Whether an owner blocks input now.
blocking :: proc "contextless" (state:core.Ref(Seats),owner:core.Entity) -> bool {
    for item in state.blocks {
        if item.active && item.owner==owner {return true}
    }
    return false
}

// References to what no longer exists are dropped.
@(private)
upkeep :: proc(a:^Apply) {
    es:=a.es
    for &value,row in a.seats.values[:core.count(a.seats)] {
        if value.body==core.NONE || core.alive(es,value.body) {continue}
        core.entity_map_remove(&a.state.drivers,value.body)
        core.edit_at(a.seats,row).body=core.NONE
    }
    for &item in a.state.blocks {
        if !item.active {continue}
        if item.seat!=core.NONE && !core.alive(es,item.seat) {
            item.active=false
        } else if item.owner!=core.NONE && !core.alive(es,item.owner) {
            block_release(a.seats,a.states,&item)
        }
    }
}
