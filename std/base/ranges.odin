package base

// A span (the bytes of a block of GPU memory, the slots of a pool) handed out
// in ranges, first fit: its free ranges by offset, and a range that comes back
// joins the free ranges beside it. Taking reserves room for the free range
// each range taken may leave, so giving back never asks for memory; reserved
// ahead (ranges_reset), taking does not either.
Range :: struct {offset,size:u64}

Ranges :: struct {
    size:u64, // of the span; 0: none
    used:u64,
    live:int, // ranges taken
    free:[dynamic]Range, // by offset, none touching
}

// The span whole and free, with room for the free ranges of live ranges taken
// at once. False without memory.
ranges_reset :: proc(r:^Ranges,size:u64,live:=0,allocator:=context.allocator) -> bool {
    if r.free.allocator.procedure==nil {r.free=make([dynamic]Range,allocator)}
    clear(&r.free)
    r.size,r.used,r.live=size,0,0
    if reserve(&r.free,live+1)!=nil {return false}
    if size>0 {append(&r.free,Range{0,size})}
    return true
}

ranges_free :: proc(r:^Ranges) {
    delete(r.free)
    r^={}
}

// A range of size aligned to align, a power of two, first fit. ok false: no
// room for it, or no memory to track one range more.
ranges_take :: proc(r:^Ranges,size:u64,align:u64=1) -> (offset:u64,ok:bool) {
    if size==0 || align==0 || align&(align-1)!=0 || r.size-r.used<size {return}
    for k in 0..<len(r.free) {
        f:=r.free[k]
        start:=(f.offset+align-1)&~(align-1)
        lead:=start-f.offset
        if start<f.offset || lead>f.size || f.size-lead<size {continue}
        // Ranges taken leave at most one free range more than they are.
        if reserve(&r.free,r.live+2)!=nil {return}
        tail:=Range{start+size,f.size-lead-size}
        switch {
        case lead>0:
            r.free[k].size=lead
            if tail.size>0 {inject_at(&r.free,k+1,tail)}
        case tail.size>0:
            r.free[k]=tail
        case:
            ordered_remove(&r.free,k)
        }
        r.used+=size
        r.live+=1
        return start,true
    }
    return
}

// Gives a range back, joined with the free ranges beside it, without asking
// for memory. False, and nothing changes, for a range the span did not give or
// one already back.
ranges_give :: proc(r:^Ranges,offset,size:u64) -> bool {
    if size==0 || r.live==0 || size>r.used || offset>r.size || size>r.size-offset {return false}
    at,end:=0,len(r.free)
    for at<end {
        middle:=(at+end)/2
        if r.free[middle].offset>offset {end=middle} else {at=middle+1}
    }
    before:=at>0
    after:=at<len(r.free)
    if before && r.free[at-1].offset+r.free[at-1].size>offset {return false}
    if after && offset+size>r.free[at].offset {return false}
    before&&=r.free[at-1].offset+r.free[at-1].size==offset
    after&&=offset+size==r.free[at].offset
    switch {
    case before && after:
        r.free[at-1].size+=size+r.free[at].size
        ordered_remove(&r.free,at)
    case before:
        r.free[at-1].size+=size
    case after:
        r.free[at]={offset,size+r.free[at].size}
    case:
        inject_at(&r.free,at,Range{offset,size})
    }
    r.used-=size
    r.live-=1
    return true
}
