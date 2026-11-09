package core

// Requests: many push, the library that owns the queue takes them.
// Events: the library that owns the queue clears it and pushes; the others read items.
Queue :: struct($T:typeid) {
    items:[dynamic]T,
    dropped:int, // offered with no room, since the owner last served it
    refused:int, // asked with values it cannot take, since the owner last served it
}

push :: proc(q:^Queue($T),item:T) {append(&q.items,item)}

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
