package core

import "base:runtime"

// Requests: many push, the library that owns the queue takes them.
Queue :: struct($T:typeid) {
    items:[dynamic]T,
    dropped:int, // offered with no room, since the owner last served it
    refused:int, // asked with values it cannot take, since the owner last served it
}

queue_push :: proc(q:^Queue($T),item:T) {append(&q.items,item)}
push :: proc{queue_push,events_push}

// Occurrences: the library that owns the log pushes what happened and never
// clears it; whoever reads gets what came since it last looked, whatever its
// cadence. A function that receives the storage of the log to read (S or
// core.Ref(S)) finds in items what came since it last ran: the generated call
// keeps its cursor. Code outside the loops keeps one and asks events_since.
// What every function has had a frame and a tick to read goes (events_age).
Events :: struct($T:typeid) {
    items:[dynamic]T,
    first:u64, // how many came before items[0]
    kept:int,  // of items, how many came before the last events_age
}

events_push :: proc(e:^Events($T),item:T) {append(&e.items,item)}

// What came since cursor, which it moves to now. Valid until the next push.
// A cursor outside the log is of another one, as after a World was copied
// over, or of a reader slower than events_age: it gets what the log holds.
events_since :: proc "contextless" (e:Events($T),cursor:^u64) -> []T {
    end:=e.first+u64(len(e.items))
    from:=clamp(cursor^,e.first,end)
    if cursor^>end {from=end}
    cursor^=end
    return e.items[from-e.first:]
}

// Leaves in view, the copy of a log a reader is handed, what came since cursor.
events_read :: proc "contextless" (view:^Events($T),cursor:^u64) {
    since:=events_since(view^,cursor)
    view.items=transmute([dynamic]T)runtime.Raw_Dynamic_Array{raw_data(since),len(since),len(since),{}}
}

// What came before the call before this one goes: the loop that runs a World
// calls it for each of its logs at the end of a frame, and for a log a fixed
// function reads only when the frame ran a tick, so whatever runs once a
// frame or once a tick has read by then what goes. True when the log changed.
events_age :: proc "contextless" (e:^Events($T)) -> bool {
    dropped:=e.kept
    if dropped>0 {
        copy(e.items[:],e.items[dropped:])
        (cast(^runtime.Raw_Dynamic_Array)&e.items).len-=dropped
        e.first+=u64(dropped)
    }
    e.kept=len(e.items)
    return dropped>0 || e.kept>0
}

QUEUE_FIRST_ROOM :: 64 // of a queue asked for before its owner served it

// Pushes within the room the owner reserved: a queue of requests never grows
// in a stable frame. What does not fit is counted for queue_serve.
offer :: proc(q:^Queue($T),item:T) {
    if cap(q.items)==0 && reserve(&q.items,QUEUE_FIRST_ROOM)!=nil || len(q.items)>=cap(q.items) {q.dropped+=1;return}
    append(&q.items,item)
}

// What a request proc calls for values no request can take.
refuse :: proc(q:^Queue($T)) {q.refused+=1}

// What the library that owns a queue of requests runs before anyone asks:
// keeps room for capacity items and reports, once, what was dropped or refused
// since the last time. what names the items; setting, what raises the room;
// valid, what a request must hold not to be refused.
queue_serve :: proc(q:^Queue($T),capacity:int,problems:^Problems,code,what,setting:string,valid:string="") {
    if cap(q.items)<capacity && reserve(&q.items,capacity)!=nil {
        report(problems,NONE,code,"out of memory for room for %d %s; free memory, or lower %s",capacity,what,setting)
    }
    if q.dropped>0 {
        report(problems,NONE,code,"%d %s did not fit in a queue of %d and were dropped; raise %s, or ask for fewer in a tick",q.dropped,what,cap(q.items),setting)
        q.dropped=0
    }
    if q.refused>0 {
        report(problems,NONE,code,"%d %s were refused; %s",q.refused,what,valid)
        q.refused=0
    }
}

// What was pushed since the last take. Valid until the next push.
take :: proc(q:^Queue($T)) -> []T {
    items:=q.items[:]
    clear(&q.items)
    return items
}

queue_clear :: proc(q:^Queue($T)) {clear(&q.items)}

// A storage read without copying it. Writing through it is a bug the
// generator cannot see: a function that writes a storage receives ^S.
Ref :: struct($S:typeid) {using ptr:^S}

ref :: #force_inline proc "contextless" (s:^$S) -> Ref(S) {return {s}}
