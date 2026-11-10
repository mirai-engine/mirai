package input

import "mirai:core"
import "mirai:host"
import mm "mirai:std/math"

// Who drives what. A seat is someone who plays: at this machine (a slot), or
// at another end of the network (a peer, which the network seats on a
// server). Each seat carries the actions of the input map for the tick, which
// become the Move_Input of the body it drives: what it asks of the body this
// tick. The body carries a Drivable with its seat and,
// optionally, the camera that sees through it. Whatever else drives a body
// (an AI, a replay) writes its Move_Input itself. This library is the only
// writer of Drivable; the rest of the engine asks through Seat_Requests.
//
// A request is applied at the start of the next fixed tick. A seat drives
// one body at most and a body has one seat. Held buttons wait for their
// release when the body or the blocks of a seat change, so a jump held before
// the swap does not happen in the new body. In a network session the server
// decides who drives what: a client takes only the bodies it owns (core.owned),
// and lets go of any.

LOCAL_CAPACITY :: 4
BLOCK_CAPACITY :: 64

// One tick of what a body is asked to do, whoever asks: the seat that drives
// it, the game, an AI, the network or a replay, each for the bodies it
// drives. A character of physics moves by it, and adds it while it plays.
@(component,shared,description="What the body is asked this tick: from the seat that drives it, an AI, the network or a replay.")
Move_Input :: struct {
    move:[3]f32 `mirai:"readonly"`,                // in the axes of the look yaw: +X right, +Y up (modes that fly), -Z forward; up to 1 long
    look_yaw,look_pitch:f32 `mirai:"readonly,angle"`, // yaw turns left about the up of the body (core.Vertical), pitch looks up; at 0 it looks along -Z, as everything does. Ground that turns adds to it through whoever writes it
    buttons:Action_Mask `mirai:"readonly"`,        // the button actions held
}
#assert(size_of(Move_Input)==32)

@(component,description="A seat can drive this body, and the camera that sees through it. A seat can drive a different body during play.")
Drivable :: struct {
    seat:core.Entity,   // none: nobody drives it
    camera:core.Entity, // an entity with a render.Camera; may be shared and outside the body
}

// Someone who plays: at this machine, the seat of a slot, made at runtime for
// every slot below the number of local players when the scene has none; at
// another end, the seat of a player that connected, which the network makes
// on a server, replicates to every client with what the game hangs from it,
// and keeps while that player is away. Its actions come from the devices of
// its slot, or from the network for another end.
@(component,shared,replicated,description="Someone who plays: at this machine (slot 0 is the first one; the keyboard and the mouse go to the focused slot, gamepad i to slot i), or at the other end of a connection.")
Seat :: struct {
    slot:u8 `mirai:"max=3"`,
    peer:u64 `mirai:"transient,readonly"`,                // the connection of another end; 0: this machine, or a player away
    player:u64 `mirai:"readonly,hidden,local"`,           // server: the hash of the secret the player of another end presents, which gets the seat back; 0: this machine
    actions:Actions `mirai:"transient,hidden,local"`,
    held:Action_Mask `mirai:"transient,hidden,local"`,    // buttons its source holds
    rearm:Action_Mask `mirai:"transient,hidden,local"`,   // held buttons that wait for their release
    blocked:Action_Mask `mirai:"transient,hidden,local"`, // actions an input block takes
    contexts:Context_Stack `mirai:"transient,hidden,local"`, // the input contexts it is in
    fed:Context_Stack `mirai:"transient,hidden,local"`,      // those its actions were computed in last
    holds:[HOLD_CAPACITY]Action_Hold `mirai:"transient,hidden,local"`, // actions given besides its devices (holds.odin)
    hold_count:u8 `mirai:"transient,hidden,local"`,
}

// A seat of this machine: not one of another end, nor of a player away.
seat_local :: #force_inline proc "contextless" (seat:Seat) -> bool {return seat.peer==0 && seat.player==0}

// How many players share this machine, on an entity of the scene. Without
// one, a single player. The players asked for (Run_Players, which the editor
// sets for its runs, or app.launch.players: --players) take its place; a
// server has none unless they are asked for.
@(component,single,description="Players at this machine, each with a part of the screen.")
Local_Multiplayer :: struct {
    players:int `mirai:"min=1,max=4"`,
}

LOCAL_MULTIPLAYER_DEFAULT :: Local_Multiplayer{players=2}

// How many local players whoever runs this world asks for before its first
// tick (the editor, for a run); 0: app.launch.players, else the scene. Of the
// run: it stays when the world loads another scene or a save.
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
}

Request_Kind :: enum u8 {
    Drive,        // seat takes entity; none releases
    Release,      // seat lets go of its body
    Swap,         // seat and entity (another seat) exchange bodies
    Focus,        // the keyboard and the mouse go to the local seat of slot
    Block_Add,    // owner takes the actions in mask from seat; none: from every local seat
    Block_Remove,
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
    core.push(&r.queue,Seat_Request{kind=.Drive,seat=seat,entity=body})
}
release :: proc(r:^Seat_Requests,seat:core.Entity) {
    core.push(&r.queue,Seat_Request{kind=.Release,seat=seat})
}
swap :: proc(r:^Seat_Requests,first,second:core.Entity) {
    core.push(&r.queue,Seat_Request{kind=.Swap,seat=first,entity=second})
}
focus :: proc(r:^Seat_Requests,slot:int) {
    core.push(&r.queue,Seat_Request{kind=.Focus,slot=slot})
}
input_block :: proc(r:^Seat_Requests,owner,seat:core.Entity,mask:=ALL_ACTIONS) {
    core.push(&r.queue,Seat_Request{kind=.Block_Add,owner=owner,seat=seat,mask=mask})
}
input_unblock :: proc(r:^Seat_Requests,owner:core.Entity) {
    core.push(&r.queue,Seat_Request{kind=.Block_Remove,owner=owner})
}

// The body a seat drives; none when it has none or the table holds it twice.
body_of :: proc(drivables:core.Read(Drivable),seat:core.Entity) -> core.Entity {
    if seat==core.NONE {return core.NONE}
    body,valid:=body_find(drivables.table,seat)
    return valid?body:core.NONE
}

// The seat that drives a body.
seat_of :: proc(drivables:core.Read(Drivable),body:core.Entity) -> core.Entity {
    value,ok:=core.get(drivables,body)
    return ok?value.seat:core.NONE
}

// The ray of the view of a body: from its Drivable.camera, where it looks, as
// the player sees it, whatever the mode of the camera. False without a camera.
aim :: proc(drivables:core.Read(Drivable),worlds:core.Read(core.World_Transform),body:core.Entity) -> (origin,direction:[3]f32,ok:bool) {
    drivable:=core.get(drivables,body) or_return
    placed:=core.get(worlds,drivable.camera) or_return
    return placed.position,mm.quat_forward(placed.rotation),true
}

// The seat of a local slot; none without one.
local_seat :: proc(seats:core.Read(Seat),slot:int) -> core.Entity {
    for &seat,row in seats.table.values[:core.count(seats)] {
        if seat_local(seat) && int(seat.slot)==slot {return core.entity_at(seats,row)}
    }
    return core.NONE
}

// The local seat with the keyboard and the mouse.
focused :: proc(state:^Seats,seats:core.Read(Seat)) -> core.Entity {
    return state.local_count>0?local_seat(seats,state.focus):core.NONE
}

// The state of an action of a seat this tick: released while it is blocked
// or waits for its release, and for what is not a seat. Code reads its own
// actions with seat_state and Input_Of.
seat_action :: proc(seats:core.Read(Seat),seat:core.Entity,a:Action) -> Action_State {
    row:=core.row_of(seats,seat)
    if row<0 {return {}}
    source:=&seats.table.values[row]
    if (source.blocked|source.rearm)&action_bit(a)!=0 {return {}}
    return action(&source.actions,a)
}

// The state of an action of a seat as the owner of blocks sees it: past its
// own blocks, so that what takes the actions of a seat (a modal screen) still
// gets them; released while a block of another owner takes it or it waits
// for its release.
seat_action_for :: proc(state:^Seats,seats:core.Read(Seat),seat:core.Entity,a:Action,owner:core.Entity) -> Action_State {
    row:=core.row_of(seats,seat)
    if row<0 {return {}}
    source:=&seats.table.values[row]
    bit:=action_bit(a)
    if source.rearm&bit!=0 {return {}}
    if source.blocked&bit!=0 {
        if state==nil || owner==core.NONE {return {}}
        local:=seat_local(source^)
        for block in state.blocks {
            if block.active && block.owner!=owner && block.mask&bit!=0 && (block.seat==seat || block.seat==core.NONE && local) {return {}}
        }
    }
    return action(&source.actions,a)
}

// The button actions of a seat that are down this tick, as seat_down sees them.
seat_buttons :: proc(seats:core.Read(Seat),seat:core.Entity,bindings:^Input_Map) -> (mask:Action_Mask) {
    row:=core.row_of(seats,seat)
    if row<0 {return}
    source:=&seats.table.values[row]
    for state,i in source.actions.states[:source.actions.count] {
        if state.down && bindings.kinds[i]==.Button {mask|=action_bit(Action(i))}
    }
    return mask&~(source.blocked|source.rearm)
}

// Who plays and what each drives, for a step to receive in one parameter.
@(params)
Players :: struct {
    seats:core.Read(Seat),
    drivables:core.Read(Drivable),
}

// The state of an action of the seat that drives a body this tick; released
// while nobody drives it.
body_action :: proc(p:Players,body:core.Entity,a:Action) -> Action_State {
    return seat_action(p.seats,seat_of(p.drivables,body),a)
}

// The seats of this machine: how many there are, and the actions of each for
// the tick. The keyboard and the mouse go to the focused one; with several,
// gamepad i goes to slot i, and with one, every gamepad to it. The seats of
// other ends get their actions from the network.
@(step="fixed",stage="input")
input_seats :: proc(
    es:^core.Entities,app:^host.App,seats:^core.Table(Seat),
    multiplayer:core.Read(Local_Multiplayer),state:^Seats,run:core.Ref(Run_Players),
    device:core.Input,bindings:core.Ref(Input_Map),network:core.Ref(core.Network),keeps:^core.Table(core.Keep),
) {
    // A server has players of its own only when someone asks for them: one
    // that is also a player, as the Play of an editor that serves.
    asked:=run.count>0?run.count:app.launch.players
    count:=1
    if core.count(multiplayer)>0 {count=clamp(core.at(multiplayer,0).players,1,LOCAL_CAPACITY)}
    if asked>0 {count=clamp(asked,1,LOCAL_CAPACITY)} else if network.role==.Server {count=0}
    state.local_count=count
    state.focus=clamp(state.focus,0,max(count-1,0))
    for slot in 0..<count {
        if local_seat(core.read(seats),slot)==core.NONE {
            seat:=core.create(es)
            core.add(seats,seat,Seat{slot=u8(slot)})
            // A player stays at the machine when the scene changes.
            if keeps!=nil {core.add(keeps,seat,core.Keep{})}
        }
    }
    for row in 0..<core.count(seats) {
        if !seat_local(seats.values[row]) {continue}
        slot:=int(seats.values[row].slot)
        own:=slot<count?slot_input(device,slot,count,state.focus):core.Input{}
        seat_feed(core.edit_at(seats,row),&own,bindings.ptr,slot<count && slot==state.focus && state.keyboard!=0 && state.keyboard!=slot+1)
    }
    state.keyboard=count>0?state.focus+1:0
}

// The actions of a seat from a device and its holds for the tick, in its contexts. One that
// got the device from another (gained) waits for the release of what it
// holds; one whose contexts changed, for the release of the buttons that went
// down with the change, as jump on the button that closed a menu.
seat_feed :: proc(seat:^Seat,device:^core.Input,bindings:^Input_Map,gained:bool) {
    before:=seat.held
    actions_update(&seat.actions,bindings,device,&seat.contexts,seat.holds[:seat.hold_count])
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
        if state.down && !state.released && bindings.kinds[i]==.Button {mask|=action_bit(Action(i))}
    }
    return
}

@(private)
Apply :: struct {
    es:^core.Entities,
    drivables:^core.Table(Drivable),
    seats:^core.Table(Seat),
    state:^Seats,
    role:core.Network_Role,
    elsewhere:core.Read(core.Remote),
    problems:^core.Problems,
}

// Who drives what, focus and blocks as they were asked, then the references
// to what no longer exists are dropped and each seat takes the actions its
// blocks take.
@(step="fixed",stage="input")
input_drive :: proc(
    es:core.Ref(core.Entities),drivables:^core.Table(Drivable),seats:^core.Table(Seat),state:^Seats,requests:^Seat_Requests,
    network:core.Ref(core.Network),elsewhere:core.Read(core.Remote),problems:^core.Problems,
) {
    a:=Apply{es=es.ptr,drivables=drivables,seats=seats,state=state,role=network.role,elsewhere=elsewhere,problems=problems}
    for request in core.take(&requests.queue) {request_apply(&a,request)}
    upkeep(&a)
    blocks_apply(seats,state)
}

// Each seat takes the actions its active blocks take.
@(private)
blocks_apply :: proc(seats:^core.Table(Seat),state:^Seats) {
    for row in 0..<core.count(seats) {
        e:=core.entity_at(seats,row)
        mask:Action_Mask
        local:=seat_local(seats.values[row])
        for block in state.blocks {
            if block.active && (block.seat==e || block.seat==core.NONE && local) {mask|=block.mask}
        }
        if seats.values[row].blocked!=mask {core.edit_at(seats,row).blocked=mask}
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
    case .Swap:
        refusal_report(a,r,body_swap(a,r.seat,r.entity))
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
        case !block_set(state,a.seats,r):
            core.report(a.problems,r.owner,"input.blocks_full","an input block was refused: %d input blocks are active, as many as fit; remove the ones no longer needed with input_unblock",BLOCK_CAPACITY)
        }
    case .Block_Remove:
        block_clear(state,a.seats,r.owner)
    }
}

// Why a request to drive a body was refused.
@(private)
Refusal :: enum u8 {None,Not_A_Seat,Seat_Twice,Not_Drivable,Taken,Server_Decides,Same,No_Body}

@(private)
refusal_report :: proc(a:^Apply,r:Seat_Request,refusal:Refusal) {
    request:=r.kind==.Drive?"driving a body":r.kind==.Release?"releasing its body":"swapping bodies"
    switch refusal {
    case .None:
    case .Not_A_Seat:
        gone,subject:=r.seat,r.entity
        if core.has(a.seats,gone) {gone,subject=r.entity,r.seat}
        if !core.alive(a.es,subject) {subject=core.NONE}
        core.report(a.problems,subject,"input.not_a_seat","%s was refused: entity 0x%016x is not a live Seat; ask with the seat of a player (local_seat, or the seat of a connection)",request,u64(gone))
    case .Seat_Twice:
        core.report(a.problems,r.seat,"input.seat_twice","%s was refused: this seat is the seat of more than one Drivable; leave it in Drivable.seat of one body only",request)
    case .Not_Drivable:
        core.report(a.problems,r.seat,"input.not_drivable","driving entity 0x%016x was refused: it has no Drivable; add one to the body first",u64(r.entity))
    case .Taken:
        core.report(a.problems,r.seat,"input.body_taken","driving entity 0x%016x was refused: another seat drives it; release it first, or swap bodies with that seat",u64(r.entity))
    case .Server_Decides:
        core.report(a.problems,r.seat,"input.server_decides","%s was refused: a client takes only the bodies it owns; in a network game ask the server, which decides who drives each body",request)
    case .Same:
        core.report(a.problems,r.seat,"input.swap_same","swapping bodies with itself was refused; swap two different seats")
    case .No_Body:
        core.report(a.problems,r.seat,"input.swap_no_body","swapping bodies with seat 0x%016x was refused: both need a body; drive one first",u64(r.entity))
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
body_find :: proc(drivables:^core.Table(Drivable),seat:core.Entity) -> (body:core.Entity,valid:bool) {
    for value,row in drivables.values[:core.count(drivables)] {
        if value.seat!=seat {continue}
        if body!=core.NONE {return core.NONE,false}
        body=drivables.entities[row]
    }
    return body,true
}

@(private)
body_assign :: proc(a:^Apply,seat,body:core.Entity) -> Refusal {
    if !seated(a,seat) {return .Not_A_Seat}
    previous,valid:=body_find(a.drivables,seat)
    if !valid {return .Seat_Twice}
    target:^Drivable
    if body!=core.NONE {
        target=core.edit(a.drivables,body)
        if target==nil {return .Not_Drivable}
        if target.seat!=core.NONE && target.seat!=seat {return .Taken}
    }
    // Letting go decides nothing of a body: a client lets go of what the server gave someone else.
    if !decides(a,body) {return .Server_Decides}
    if previous==body {return .None}
    if previous!=core.NONE {core.edit(a.drivables,previous).seat=core.NONE}
    if target!=nil {target.seat=seat}
    rearm(a,seat)
    return .None
}

@(private)
body_swap :: proc(a:^Apply,first,second:core.Entity) -> Refusal {
    if first==second {return .Same}
    if !seated(a,first) || !seated(a,second) {return .Not_A_Seat}
    left,valid_left:=body_find(a.drivables,first)
    right,valid_right:=body_find(a.drivables,second)
    if !valid_left || !valid_right {return .Seat_Twice}
    if left==core.NONE || right==core.NONE {return .No_Body}
    if !decides(a,left) || !decides(a,right) {return .Server_Decides}
    core.edit(a.drivables,left).seat=second
    core.edit(a.drivables,right).seat=first
    rearm(a,first)
    rearm(a,second)
    return .None
}

// The buttons a seat holds now wait for their release before it can use them.
@(private)
rearm :: proc(a:^Apply,seat:core.Entity) {
    if source:=core.edit(a.seats,seat);source!=nil && source.held!=0 {source.rearm|=source.held}
}

@(private)
block_set :: proc(state:^Seats,seats:^core.Table(Seat),r:Seat_Request) -> bool {
    free:^Block
    for &item in state.blocks {
        if item.active && item.owner==r.owner {
            free=&item
            break
        }
        if !item.active && free==nil {free=&item}
    }
    if free==nil {return false}
    if free.active && free.seat!=r.seat {block_release(seats,free)}
    free^={owner=r.owner,seat=r.seat,mask=r.mask,active=true}
    return true
}

// What the block held back and is still held waits for its release.
@(private)
block_release :: proc(seats:^core.Table(Seat),block:^Block) {
    if !block.active {return}
    for row in 0..<core.count(seats) {
        e,source:=core.entity_at(seats,row),&seats.values[row]
        if (e==block.seat || block.seat==core.NONE && seat_local(source^)) && source.held&block.mask!=0 {core.edit_at(seats,row).rearm|=source.held&block.mask}
    }
    block.active=false
}

@(private)
block_clear :: proc(state:^Seats,seats:^core.Table(Seat),owner:core.Entity) {
    for &item in state.blocks {
        if item.active && item.owner==owner {block_release(seats,&item)}
    }
}

// Whether an owner blocks input now.
blocking :: proc "contextless" (state:^Seats,owner:core.Entity) -> bool {
    for item in state.blocks {
        if item.active && item.owner==owner {return true}
    }
    return false
}

// References to what no longer exists are dropped.
@(private)
upkeep :: proc(a:^Apply) {
    es:=a.es
    for value,row in a.drivables.values[:core.count(a.drivables)] {
        if value.seat==core.NONE || core.alive(es,value.seat) {continue}
        core.edit_at(a.drivables,row).seat=core.NONE
    }
    for &item in a.state.blocks {
        if !item.active {continue}
        if item.seat!=core.NONE && !core.alive(es,item.seat) {
            item.active=false
        } else if item.owner!=core.NONE && !core.alive(es,item.owner) {
            block_release(a.seats,&item)
        }
    }
}
