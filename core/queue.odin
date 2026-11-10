package core

import "base:runtime"
import "mirai:std/base"

// Requests: many push, the library that owns the queue takes them.
Queue :: struct($T:typeid) {
    items:[dynamic]T,
    waiting:[dynamic]Waiting(T), // pushed with later: each one is taken at its tick
    dropped:int, // offered with no room, since the owner last served it
    refused:int, // asked with values it cannot take, since the owner last served it
}

queue_push :: proc(q:^Queue($T),item:T) {append(&q.items,item)}
push :: proc{queue_push,events_push}

// A request that waits for its tick.
Waiting :: struct($T:typeid) {due:u64,item:T}

// Pushes what the owner takes `seconds` from now, with take_due: a request
// that waits as plain data, copied and rolled back with its queue. A queue is
// not saved: a wait a save must keep is a deadline in a component.
later :: proc(q:^Queue($T),time:Time,seconds:f32,item:T) {append(&q.waiting,Waiting(T){deadline(time,seconds),item})}

// Occurrences: the library that owns the log pushes what happened and never
// clears it. A function that receives its storage to read (S or core.Ref(S))
// finds in items what came since it last ran, whatever its cadence: the
// generated call keeps its cursor. Code outside the loops keeps one.
Events :: struct($T:typeid) {
    items:[dynamic]T,
    first:u64, // how many came before items[0]
    kept:int,  // of items, how many came before the last events_age
}

events_push :: proc(e:^Events($T),item:T) {append(&e.items,item)}

// What came since cursor, which it moves to now; valid until the next push.
// A cursor of another log, as after a World was copied over, gets what this
// one holds.
events_since :: proc "contextless" (e:Events($T),cursor:^u64) -> []T {
    end:=e.first+u64(len(e.items))
    from:=cursor^>end?end:max(cursor^,e.first)
    cursor^=end
    return e.items[from-e.first:]
}

// Leaves in view, the copy of a log a reader is handed, what came since cursor.
events_read :: proc "contextless" (view:^Events($T),cursor:^u64) {
    since:=events_since(view^,cursor)
    view.items=transmute([dynamic]T)runtime.Raw_Dynamic_Array{raw_data(since),len(since),len(since),{}}
}

// What came before the call before this one goes. Whoever runs a World calls
// it at the end of a frame, and for a log a fixed function reads only when the
// frame ran a tick: what runs once a frame or a tick has read what goes. True
// when the log changed.
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

// What was pushed since the last take. Valid until the next push. What was
// pushed for later is refused: the owner of a queue that takes it uses take_due.
take :: proc(q:^Queue($T)) -> []T {
    q.refused+=len(q.waiting)
    clear(&q.waiting)
    items:=q.items[:]
    clear(&q.items)
    return items
}

// What was pushed since the last take and what was pushed for later and is
// due, in the order it was pushed. Valid until the next push.
take_due :: proc(q:^Queue($T),time:Time) -> []T {
    kept:=0
    for waiting in q.waiting {
        if due(time,waiting.due) {
            append(&q.items,waiting.item)
        } else {
            q.waiting[kept]=waiting
            kept+=1
        }
    }
    base.truncate(&q.waiting,kept)
    items:=q.items[:]
    clear(&q.items)
    return items
}

queue_clear :: proc(q:^Queue($T)) {
    clear(&q.items)
    clear(&q.waiting)
}

// A storage read without copying it. Writing through it is a bug the
// generator cannot see: a function that writes a storage receives ^S.
Ref :: struct($S:typeid) {using ptr:^S}

ref :: #force_inline proc "contextless" (s:^$S) -> Ref(S) {return {s}}
