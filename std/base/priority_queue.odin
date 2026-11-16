package base

import "base:intrinsics"
import "base:runtime"

// Binary min-heap of fixed capacity: the entry with the smallest key leaves
// first; entries with equal keys leave in no particular order. Keys and values
// are separate arrays, so reordering compares keys only.
Priority_Queue :: struct($K:typeid,$V:typeid) where intrinsics.type_is_ordered_numeric(K) {
    keys:[]K,
    values:[]V,
    using usage:Usage,
    owner:runtime.Allocator,
}

priority_queue_init :: proc(q:^$Q/Priority_Queue($K,$V),capacity:int,allocator:=context.allocator) -> bool {
    q^={}
    if capacity<=0 {return false}
    keys,first:=slice_make([]K,capacity,allocator)
    values,second:=slice_make([]V,capacity,allocator)
    if !first || !second {delete(keys,allocator);delete(values,allocator);return false}
    priority_queue_init_buffer(q,keys,values)
    q.owner=allocator
    return true
}
// The capacity is the length of the shorter slice.
priority_queue_init_buffer :: proc(q:^$Q/Priority_Queue($K,$V),keys:[]K,values:[]V) {
    capacity:=min(len(keys),len(values))
    q^={keys=keys[:capacity],values=values[:capacity]}
    q.capacity=capacity
}
priority_queue_destroy :: proc(q:^$Q/Priority_Queue($K,$V)) {
    if q.owner.procedure!=nil {delete(q.keys,q.owner);delete(q.values,q.owner)}
    q^={}
}
// False when the queue is full.
priority_queue_push :: proc(q:^$Q/Priority_Queue($K,$V),key:K,value:V) -> bool {
    if q.count>=len(q.keys) {q.failed+=1;return false}
    index:=q.count
    usage_add(&q.usage)
    #no_bounds_check for index>0 {
        parent:=(index-1)>>1
        if !(key<q.keys[parent]) {break}
        q.keys[index]=q.keys[parent];q.values[index]=q.values[parent]
        index=parent
    }
    q.keys[index]=key;q.values[index]=value
    return true
}
priority_queue_pop :: proc(q:^$Q/Priority_Queue($K,$V)) -> (key:K,value:V,ok:bool) {
    if q.count==0 {return}
    key,value=q.keys[0],q.values[0]
    q.count-=1
    count:=q.count
    if count==0 {return key,value,true}
    last_key,last_value:=q.keys[count],q.values[count]
    index:=0
    #no_bounds_check for {
        child:=index*2+1
        if child>=count {break}
        // Which child is smaller is a coin toss: picking it without a branch is faster.
        if child+1<count {child+=int(q.keys[child+1]<q.keys[child])}
        if !(q.keys[child]<last_key) {break}
        q.keys[index]=q.keys[child];q.values[index]=q.values[child]
        index=child
    }
    q.keys[index]=last_key;q.values[index]=last_value
    return key,value,true
}
priority_queue_peek :: proc "contextless" (q:^$Q/Priority_Queue($K,$V)) -> (key:K,value:V,ok:bool) {
    if q.count==0 {return}
    return q.keys[0],q.values[0],true
}
priority_queue_clear :: proc "contextless" (q:^$Q/Priority_Queue($K,$V)) {q.count=0}
