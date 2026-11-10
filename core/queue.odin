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

// An append-only log read by cursor: a reader keeps how far it read and
// asks log_since for what came after. Its owner trims it by a rule of its
// own (the gone of a table, the moved of the Hierarchy, Events).
Log :: struct($T:typeid) {
    items:[dynamic]T,
    first:u64, // how many came before items[0]
}

log_end :: #force_inline proc "contextless" (l:Log($T)) -> u64 {return l.first+u64(len(l.items))}

// What came since cursor, which it moves to now; valid until the next push.
// whole: the cursor is not of what the log holds, because the reader fell
// behind its trim or the cursor is of another log, as after a World was
// copied over; items are then what the log holds, or none past its end.
log_since :: proc "contextless" (l:Log($T),cursor:^u64) -> (items:[]T,whole:bool) {
    end:=log_end(l)
    whole=cursor^<l.first || cursor^>end
    if cursor^<=end {items=l.items[max(cursor^,l.first)-l.first:]}
    cursor^=end
    return
}

// Appends item. room: full with that many, it drops its older half first;
// 0: it grows. Without memory it forgets what it held (log_reset).
log_push :: proc(l:^Log($T),item:T,room:=0) {
    if room>0 && len(l.items)>=room {log_drop(l,(len(l.items)+1)/2)}
    if _,error:=append(&l.items,item);error!=nil {log_reset(l)}
}

// Its n oldest go.
log_drop :: proc "contextless" (l:^Log($T),n:int) {
    n:=clamp(n,0,len(l.items))
    copy(l.items[:],l.items[n:])
    (cast(^runtime.Raw_Dynamic_Array)&l.items).len-=n
    l.first+=u64(n)
}

// No reader has seen what it holds, nor a cursor up to past (of another log
// copied or swapped into its place): each reads it whole.
log_reset :: proc "contextless" (l:^Log($T),past:u64=0) {
    l.first=max(log_end(l^),past)+1
    clear(&l.items)
}

// Occurrences: the library that owns the log pushes what happened and never
// clears it. A function that receives its storage to read (S or core.Ref(S))
// finds in items what came since it last ran, whatever its cadence: the
// generated call keeps its cursor. Code outside the loops keeps one and asks
// log_since.
Events :: struct($T:typeid) {
    using log:Log(T),
    kept:int, // of items, how many came before the last events_age
}

events_push :: proc(e:^Events($T),item:T) {log_push(&e.log,item)}

// Leaves in view, the copy of a log a reader is handed, what came since cursor.
events_read :: proc "contextless" (view:^Events($T),cursor:^u64) {
    since,_:=log_since(view.log,cursor)
    view.items=transmute([dynamic]T)runtime.Raw_Dynamic_Array{raw_data(since),len(since),len(since),{}}
}

// What came before the call before this one goes. Whoever runs a World calls
// it at the end of a frame, and for a log a fixed function reads only when the
// frame ran a tick: what runs once a frame or a tick has read what goes. True
// when the log changed.
events_age :: proc "contextless" (e:^Events($T)) -> bool {
    dropped:=e.kept
    if dropped>0 {log_drop(&e.log,dropped)}
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
