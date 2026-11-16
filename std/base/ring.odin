package base

import "base:intrinsics"
import "base:runtime"

// Double-ended queue over a circular buffer of fixed capacity. Index 0 is the front.
Ring :: struct($T:typeid) {
    items:[]T,
    head:int, // position of the front
    using usage:Usage,
    owner:runtime.Allocator,
}

ring_init :: proc(r:^$R/Ring($T),capacity:int,allocator:=context.allocator) -> bool {
    r^={}
    if capacity<=0 {return false}
    items,ok:=slice_make([]T,capacity,allocator)
    if !ok {return false}
    ring_init_buffer(r,items)
    r.owner=allocator
    return true
}
ring_init_buffer :: proc(r:^$R/Ring($T),items:[]T) {
    r^={items=items}
    r.capacity=len(items)
}
ring_destroy :: proc(r:^$R/Ring($T)) {
    if r.owner.procedure!=nil {delete(r.items,r.owner)}
    r^={}
}
@(private)
ring_position :: #force_inline proc "contextless" (r:^$R/Ring($T),index:int) -> int {
    position:=r.head+index
    return position-len(r.items) if position>=len(r.items) else position
}
// False when the ring is full.
ring_push_back :: proc(r:^$R/Ring($T),value:T) -> bool {
    if r.count>=len(r.items) {r.failed+=1;return false}
    r.items[ring_position(r,r.count)]=value
    usage_add(&r.usage)
    return true
}
ring_push_front :: proc(r:^$R/Ring($T),value:T) -> bool {
    if r.count>=len(r.items) {r.failed+=1;return false}
    r.head=len(r.items)-1 if r.head==0 else r.head-1
    r.items[r.head]=value
    usage_add(&r.usage)
    return true
}
// Adds at the back; a full ring drops its front to make room and returns it.
ring_push_overwrite :: proc(r:^$R/Ring($T),value:T) -> (dropped:T,overwrote:bool) {
    if len(r.items)==0 {r.failed+=1;return}
    if r.count>=len(r.items) {dropped,overwrote=ring_pop_front(r)}
    ring_push_back(r,value)
    return
}
ring_pop_front :: proc(r:^$R/Ring($T)) -> (value:T,ok:bool) {
    if r.count==0 {return}
    value=r.items[r.head]
    r.head=ring_position(r,1);r.count-=1
    return value,true
}
ring_pop_back :: proc(r:^$R/Ring($T)) -> (value:T,ok:bool) {
    if r.count==0 {return}
    r.count-=1
    return r.items[ring_position(r,r.count)],true
}
// nil when the index is not below the count.
ring_get :: #force_inline proc "contextless" (r:^$R/Ring($T),index:int) -> ^T {
    if index<0 || index>=r.count {return nil}
    return &r.items[ring_position(r,index)]
}
ring_front :: #force_inline proc "contextless" (r:^$R/Ring($T)) -> ^T {return ring_get(r,0)}
ring_back :: #force_inline proc "contextless" (r:^$R/Ring($T)) -> ^T {return ring_get(r,r.count-1)}
ring_space :: #force_inline proc "contextless" (r:^$R/Ring($T)) -> int {return len(r.items)-r.count}
ring_clear :: proc "contextless" (r:^$R/Ring($T)) {r.head=0;r.count=0}

@(private)
Spsc_Producer :: struct #align(64) {
    tail:u64,        // items pushed so far
    cached_head:u64, // last head seen, to read the consumer's line only when the queue looks full
    failed:u64,      // pushes refused because the queue was full
}
@(private)
Spsc_Consumer :: struct #align(64) {
    head:u64,        // items popped so far
    cached_tail:u64,
}

// Queue between exactly one producer thread and one consumer thread, without
// locks or waiting. spsc_push belongs to the producer and spsc_pop to the consumer.
Spsc_Queue :: struct($T:typeid) {
    items:[]T, // a power of two, at least the capacity
    capacity:u64,
    mask:u64,
    producer:Spsc_Producer,
    consumer:Spsc_Consumer,
    owner:runtime.Allocator,
}

spsc_init :: proc(q:^$Q/Spsc_Queue($T),capacity:int,allocator:=context.allocator) -> bool {
    q^={}
    if capacity<=0 || capacity>max(int)/2 {return false}
    slots:=1
    for slots<capacity {slots<<=1}
    items,ok:=slice_make([]T,slots,allocator)
    if !ok {return false}
    q.items=items;q.capacity=u64(capacity);q.mask=u64(slots-1);q.owner=allocator
    return true
}
spsc_destroy :: proc(q:^$Q/Spsc_Queue($T)) {
    if q.owner.procedure!=nil {delete(q.items,q.owner)}
    q^={}
}
// Producer thread only. False when the queue is full.
spsc_push :: proc "contextless" (q:^$Q/Spsc_Queue($T),value:T) -> bool {
    tail:=q.producer.tail
    if tail-q.producer.cached_head>=q.capacity {
        q.producer.cached_head=intrinsics.atomic_load_explicit(&q.consumer.head,.Acquire)
        if tail-q.producer.cached_head>=q.capacity {q.producer.failed+=1;return false}
    }
    #no_bounds_check q.items[tail&q.mask]=value
    intrinsics.atomic_store_explicit(&q.producer.tail,tail+1,.Release)
    return true
}
// Consumer thread only. ok is false when the queue is empty.
spsc_pop :: proc "contextless" (q:^$Q/Spsc_Queue($T)) -> (value:T,ok:bool) {
    head:=q.consumer.head
    if head==q.consumer.cached_tail {
        q.consumer.cached_tail=intrinsics.atomic_load_explicit(&q.producer.tail,.Acquire)
        if head==q.consumer.cached_tail {return}
    }
    #no_bounds_check value=q.items[head&q.mask]
    intrinsics.atomic_store_explicit(&q.consumer.head,head+1,.Release)
    return value,true
}
// Items waiting; exact only when neither thread is inside a push or a pop.
spsc_len :: proc "contextless" (q:^$Q/Spsc_Queue($T)) -> int {
    tail:=intrinsics.atomic_load_explicit(&q.producer.tail,.Acquire)
    head:=intrinsics.atomic_load_explicit(&q.consumer.head,.Acquire)
    return int(tail-head)
}
