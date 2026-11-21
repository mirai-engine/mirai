package input

import "mirai:core"

// Actions a seat is given besides its devices, as if its player held them:
// what a test or an agent that plays asks, by action and never by key, so
// the bindings do not matter. The seat takes them as one more binding of the
// action, in its contexts, with its blocks and its re-arming. Like the
// devices, they are of a seat of this machine: on a client, the actions they
// give reach the server with the others of the seat (Remote_Actions), and the
// seat of a connection on a server takes none, which its client would not
// predict. They live in the seat and last whole fixed ticks, so the same
// requests on the same World give the same ticks.

HOLD_CAPACITY :: 8

Action_Hold :: struct {
    action:Action,
    value:[2]f32, // Button: x not 0; Axis: x; Axis2: x and y
    until:u64,    // the first Time.tick it no longer acts in; 0: until it is let go
}

Hold_Request :: struct {
    seat:core.Entity,
    action:Action,
    value:[2]f32, // as Action_Hold; zero lets go
    ticks:u32,    // it acts in from the next tick on; 0: until it is let go
}

@(storage,queue)
Hold_Requests :: struct {
    using queue:core.Queue(Hold_Request),
}

// Holds an action of a seat at a value for some ticks (0: until let_go),
// replacing what it held of that action.
hold :: proc(r:^Hold_Requests,seat:core.Entity,action:Action,value:[2]f32,ticks:=u32(0)) -> bool {
    dropped:=r.dropped
    core.offer(&r.queue,Hold_Request{seat=seat,action=action,value=value,ticks=ticks})
    return dropped==r.dropped
}
let_go :: proc(r:^Hold_Requests,seat:core.Entity,action:Action) -> bool {return hold(r,seat,action,{})}

// Applies the requests at the start of the tick, before any seat reads its
// devices, and drops what was held for ticks that already ran.
@(step="fixed",stage="begin")
input_holds :: proc(seats:^core.Table(Seat,.Read),states:^Seat_States,requests:^Hold_Requests,time:core.Time,problems:^core.Problems) {
    core.queue_serve(&requests.queue,LOCAL_CAPACITY*HOLD_CAPACITY*2,problems,"input.holds_requests",
        "hold requests","the input request capacity")
    for r in core.take(&requests.queue) {
        if !core.has(seats,r.seat) {
            core.report(problems,core.NONE,"input.hold_seat","holding action %d was refused: entity 0x%016x is not a live Seat; ask with the seat of a player",r.action,u64(r.seat))
            continue
        }
        if !seat_local(core.at(seats,core.row_of(seats,r.seat))) {
            core.report(problems,r.seat,"input.hold_remote_seat","holding action %d was refused: this is the seat of a player at another end, which takes the actions its client sends; hold the local seat in the run of that client",r.action)
            continue
        }
        if int(r.action)>=ACTION_CAPACITY {
            core.report(problems,r.seat,"input.hold_action","holding action %d was refused: actions are below %d",r.action,ACTION_CAPACITY)
            continue
        }
        source:=seat_runtime_edit(states,r.seat)
        if source==nil {
            core.report(problems,r.seat,"input.seat_state","out of memory for this seat's input state; free memory")
            continue
        }
        if !hold_set(&source.holds,&source.hold_count,r,time.tick) {
            core.report(problems,r.seat,"input.holds_full","holding action %d was refused: the seat holds %d actions, as many as fit; let go of one first",r.action,HOLD_CAPACITY)
        }
    }
    for &seat in states.entries.values {
        kept:u8
        for hold in seat.holds[:seat.hold_count] {
            if hold.until!=0 && hold.until<=time.tick {continue}
            seat.holds[kept]=hold
            kept+=1
        }
        seat.hold_count=kept
    }
}

// What a seat holds in the tick that runs at tick: its holds with the
// requests waiting for that tick applied, as input_holds applies them.
holds_at :: proc(seat:^Seat_State,e:core.Entity,requests:core.Ref(Hold_Requests),tick:u64) -> (holds:[HOLD_CAPACITY]Action_Hold,count:int) {
    ahead:[HOLD_CAPACITY]Action_Hold
    used:u8
    if seat!=nil {ahead,used=seat.holds,seat.hold_count}
    if requests.ptr!=nil {
        for r in requests.items {
            if r.seat==e && int(r.action)<ACTION_CAPACITY {_=hold_set(&ahead,&used,r,tick)}
        }
    }
    for hold in ahead[:used] {
        if hold.until!=0 && hold.until<=tick {continue}
        holds[count]=hold
        count+=1
    }
    return
}

@(private)
hold_set :: proc(holds:^[HOLD_CAPACITY]Action_Hold,count:^u8,r:Hold_Request,tick:u64) -> bool {
    at:=-1
    for hold,i in holds[:count^] {
        if hold.action==r.action {at=i;break}
    }
    if r.value=={} {
        if at>=0 {
            count^-=1
            holds[at]=holds[count^]
        }
        return true
    }
    if at<0 {
        if int(count^)>=HOLD_CAPACITY {return false}
        at=int(count^)
        count^+=1
    }
    holds[at]=Action_Hold{action=r.action,value=r.value,until=r.ticks>0?tick+u64(r.ticks):0}
    return true
}
