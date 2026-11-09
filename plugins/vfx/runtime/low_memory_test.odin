package vfx

import "base:runtime"
import "core:testing"

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private="file")
Memory_Limit :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
memory_limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    limit:=(^Memory_Limit)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if limit.remaining<=0 {return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// The tables of a pool, with the memory ending at each request in turn: the
// pool is refused and holds none of them, and with memory enough it is made.
@(test)
a_pool_without_memory_is_refused_and_holds_no_table :: proc(t:^testing.T) {
    limit:=Memory_Limit{owner=context.allocator}
    limited:=runtime.Allocator{memory_limit_proc,&limit}
    capacities:=[]u32{0,1024}
    for capacity in capacities {
        pool:Pool
        made,refused:=false,false
        for served in 0..<16 {
            limit.remaining=served
            made=pool_make(&pool,capacity,limited)
            limit.remaining=max(int)
            if made {break}
            refused=true
            testing.expectf(t,pool.slots==nil && pool.order==nil && pool.free==nil && pool.attribute_free==nil && pool.gpu==nil && pool.draws==nil,"a pool of %d with %d requests served keeps tables",capacity,served)
        }
        testing.expectf(t,made && refused && pool.capacity==capacity && len(pool.slots)==EMITTER_CAPACITY,"a pool of %d: refused without memory, and made with it",capacity)
        pool_free(&pool,limited)
    }
}
