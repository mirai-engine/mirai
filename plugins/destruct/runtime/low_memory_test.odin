package destruct

import "base:runtime"
import "core:testing"
import fr "plugins:destruct/runtime/fracture"

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

// The scratch of the cache for the capacities of a fracture, with the memory
// ending at each request in turn: it is refused and holds nothing, so the
// step leaves the tick, and with memory enough it is made.
@(test)
the_scratch_of_the_cache_without_memory_is_refused_and_holds_nothing :: proc(t:^testing.T) {
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    capacities:=[][2]int{{64,32},{1,1}}
    for capacity in capacities {
        f:fr.Fracture
        f.desc.pieces,f.desc.bodies=capacity[0],capacity[1]
        cache:Destruct_Cache
        made,refused:=false,false
        for served in 0..<16 {
            limit.remaining=served
            context.allocator={memory_limit_proc,&limit}
            made=cache_make(&cache,&f)
            context.allocator=owner
            limit.remaining=max(int)
            if made {break}
            refused=true
            testing.expectf(t,!cache.ready && cache.infos==nil && cache.marks==nil && cache.group_of==nil && cache.firsts==nil && cache.flat==nil,"%v with %d requests served keeps scratch",capacity,served)
        }
        testing.expectf(t,made && refused && cache.ready && len(cache.infos)==capacity[0] && len(cache.marks)==capacity[1],"%v: refused without memory, and made with it",capacity)
        cache_free(&cache)
    }
}
