package base

import "base:runtime"
import "core:mem/virtual"

// Address space for a table that may grow to the size reserved, of which only
// the first `committed` bytes take memory. Committing more never moves the
// table, so pointers into it stay valid, and goes to the system, not to an
// allocator. Committed pages are zero and stay until the region is released.
Region :: struct {
    data:[]u8,
    committed:int,
    tail:int, // bytes committed at the end, for a table that also grows down from there
}

// Bytes a region commits at least when it grows, so a table that takes one
// element at a time asks the system rarely.
REGION_STEP :: 64<<10

// Reserves address space for bytes, committing nothing. False when the system refuses.
region_reserve :: proc(r:^Region,bytes:int) -> bool {
    r^={}
    if bytes<=0 {return false}
    data,error:=virtual.reserve(uint(bytes))
    if error!=nil {return false}
    r.data=data
    return true
}

// Makes the first bytes usable. False, committing nothing, when they are more
// than were reserved or the system has no memory for them.
region_commit :: proc(r:^Region,bytes:int) -> bool {
    if bytes<=r.committed {return true}
    if bytes>len(r.data) {return false}
    target:=min(max(bytes,r.committed+REGION_STEP),len(r.data))
    if virtual.commit(&r.data[r.committed],uint(target-r.committed))!=nil {return false}
    r.committed=target
    return true
}

// Makes the last bytes usable, as region_commit does the first ones.
region_commit_tail :: proc(r:^Region,bytes:int) -> bool {
    if bytes<=r.tail {return true}
    if bytes>len(r.data) {return false}
    target:=min(max(bytes,r.tail+REGION_STEP),len(r.data))
    if virtual.commit(&r.data[len(r.data)-target],uint(target-r.tail))!=nil {return false}
    r.tail=target
    return true
}

region_release :: proc(r:^Region) {
    if r.data!=nil {virtual.release(raw_data(r.data),uint(len(r.data)))}
    r^={}
}

// A [dynamic]T over the region, empty, with room for capacity elements: it
// never moves, so pointers to its elements stay valid, and region_grow commits
// room before an append past what is committed. Its allocator refuses, so an
// append without room fails instead of moving it.
region_dynamic :: proc(r:^Region,$T:typeid,capacity:int) -> (list:[dynamic]T,ok:bool) {
    if capacity>max(int)/max(size_of(T),1) || !region_reserve(r,capacity*size_of(T)) {return}
    raw:=runtime.Raw_Dynamic_Array{data=raw_data(r.data),len=0,cap=capacity,allocator=runtime.nil_allocator()}
    return transmute([dynamic]T)raw,true
}

// Commits room for count more elements of a list region_dynamic made. False when it is full.
region_grow :: proc(r:^Region,list:^[dynamic]$T,count:=1) -> bool {
    return count<=cap(list)-len(list) && region_commit(r,(len(list)+count)*size_of(T))
}

// The region as count elements of T, no more than fit in what was reserved,
// of which only the committed ones may be touched.
region_slice :: proc "contextless" (r:^Region,$T:typeid,count:int) -> []T {
    return ([^]T)(raw_data(r.data))[:clamp(count,0,len(r.data)/max(size_of(T),1))]
}
