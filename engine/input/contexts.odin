package input

import "mirai:core"

// Input contexts. Every action is in one context (the base one unless its
// default or input.mirai name another), and a seat takes the actions of a
// context only while it is in it. Every seat is always in the base context;
// something (a menu, a vehicle) puts seats in others until its owner takes
// them out, and the one entered last is on top. A context on top takes from
// those under it the keys, buttons and axes its actions read; a modal one
// leaves them nothing. So a menu binds South to its own confirm while jump,
// bound to South too, waits under it. Contexts are applied at the start of
// the tick, before any seat reads its devices.

CONTEXT_LAYERS :: 8          // contexts a seat is in at once, over the base one
CONTEXT_ENTRY_CAPACITY :: 32

// The contexts a seat is in, from the bottom up, over the base one.
Context_Stack :: struct {
    layers:[CONTEXT_LAYERS]Input_Context,
    count:u8,
    modal:u8, // bit i: layers[i] leaves nothing to the layers under it
}

Context_Entry :: struct {
    owner,seat:core.Entity, // seat none: every local seat
    input_context:Input_Context,
    modal:bool,
    order:u32,              // when it was entered: a later one is higher
    active:bool,
}

// The contexts something put seats in, until its owner takes them out.
// Loading a scene or a save starts it again: whoever entered one enters it again.
@(storage)
Input_Contexts :: struct {
    entries:[CONTEXT_ENTRY_CAPACITY]Context_Entry,
    order:u32,
}

Context_Request :: struct {
    owner,seat:core.Entity,
    input_context:Input_Context,
    modal:bool,
    leave:bool,
}

@(storage,queue)
Context_Requests :: struct {
    using queue:core.Queue(Context_Request),
}

// Puts a seat (none: every local seat) in a context until owner leaves it.
// An owner has one context: entering another replaces it.
input_context_enter :: proc(r:^Context_Requests,owner,seat:core.Entity,input_context:Input_Context,modal:=false) {
    core.push(&r.queue,Context_Request{owner=owner,seat=seat,input_context=input_context,modal=modal})
}
input_context_leave :: proc(r:^Context_Requests,owner:core.Entity) {
    core.push(&r.queue,Context_Request{owner=owner,leave=true})
}

// Whether an owner has seats in a context now.
in_context :: proc "contextless" (state:^Input_Contexts,owner:core.Entity) -> bool {
    for entry in state.entries {
        if entry.active && entry.owner==owner {return true}
    }
    return false
}

// The contexts of the local seat with the keyboard and the mouse; nil without one.
focused_contexts :: proc(state:^Seats,seats:core.Read(Seat)) -> ^Context_Stack {
    if state==nil || state.local_count==0 {return nil}
    row:=core.row_of(seats,local_seat(seats,state.focus))
    return row>=0?&seats.table.values[row].contexts:nil
}

// The contexts as they were asked, without what refers to what no longer
// exists, in the stack of each seat.
@(step="fixed",stage="begin")
input_contexts :: proc(es:core.Ref(core.Entities),seats:^core.Table(Seat),state:^Input_Contexts,requests:^Context_Requests,problems:^core.Problems) {
    for request in core.take(&requests.queue) {context_request_apply(es.ptr,seats,state,request,problems)}
    for &entry in state.entries {
        if !entry.active {continue}
        if entry.seat!=core.NONE && !core.alive(es.ptr,entry.seat) || entry.owner!=core.NONE && !core.alive(es.ptr,entry.owner) {entry.active=false}
    }
    for row in 0..<core.count(seats) {
        stack:=context_stack(state,core.entity_at(seats,row),seat_local(seats.values[row]))
        if seats.values[row].contexts!=stack {core.at(seats,row).contexts=stack}
    }
}

@(private)
context_request_apply :: proc(es:^core.Entities,seats:^core.Table(Seat),state:^Input_Contexts,r:Context_Request,problems:^core.Problems) {
    own:^Context_Entry
    for &entry in state.entries {
        if entry.active && entry.owner==r.owner {own=&entry;break}
    }
    if r.leave {
        if own!=nil {own.active=false}
        return
    }
    switch {
    case int(r.input_context)>=CONTEXT_CAPACITY:
        core.report(problems,r.owner,"input.context_value","a seat was asked to enter the input context of value %d; contexts take values below %d: declare it as a free one",r.input_context,CONTEXT_CAPACITY)
        return
    case r.input_context==CONTEXT_BASE || r.input_context==CONTEXT_ALWAYS:
        core.report(problems,r.owner,"input.context_base","a seat was asked to enter the %s input context, which every seat is always in; enter a context of the actions to take, or leave the one entered",r.input_context==CONTEXT_BASE?"base":"always")
        return
    case r.seat!=core.NONE && !(core.alive(es,r.seat) && core.has(seats,r.seat)):
        core.report(problems,r.owner,"input.context_seat","entity 0x%016x was asked to enter an input context and is not a live Seat; ask with the seat of a player (local_seat), or none for every local seat",u64(r.seat))
        return
    }
    if own!=nil && own.seat==r.seat && own.input_context==r.input_context && own.modal==r.modal {return}
    deep:=0
    free:=own
    for &entry in state.entries {
        if !entry.active {
            if free==nil {free=&entry}
            continue
        }
        if &entry!=own && (entry.seat==r.seat || entry.seat==core.NONE || r.seat==core.NONE) {deep+=1}
    }
    if free==nil || deep>=CONTEXT_LAYERS {
        core.report(problems,r.owner,"input.contexts_full","an input context was refused: its seats are in %d contexts already, as many as fit (or %d are entered); leave the ones no longer needed with input_context_leave",CONTEXT_LAYERS,CONTEXT_ENTRY_CAPACITY)
        return
    }
    state.order+=1
    free^={owner=r.owner,seat=r.seat,input_context=r.input_context,modal=r.modal,order=state.order,active=true}
}

// The contexts of a seat, the one entered last on top.
@(private)
context_stack :: proc "contextless" (state:^Input_Contexts,seat:core.Entity,local:bool) -> (stack:Context_Stack) {
    sorted:[CONTEXT_LAYERS]^Context_Entry
    count:=0
    for &entry in state.entries {
        if !entry.active || !(entry.seat==seat || entry.seat==core.NONE && local) || count>=CONTEXT_LAYERS {continue}
        at:=count
        for at>0 && sorted[at-1].order>entry.order {
            sorted[at]=sorted[at-1]
            at-=1
        }
        sorted[at]=&entry
        count+=1
    }
    for entry,i in sorted[:count] {
        stack.layers[i]=entry.input_context
        if entry.modal {stack.modal|=1<<u8(i)}
    }
    stack.count=u8(count)
    return
}
