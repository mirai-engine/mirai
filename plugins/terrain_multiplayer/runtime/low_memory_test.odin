package terrain_multiplayer

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:std/base"

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

// The first ask of a connection a server counts, with the memory ending at
// each request in turn: it is refused as Rate, and let in with memory enough.
@(test)
an_ask_without_memory_to_count_is_refused_as_rate :: proc(t:^testing.T) {
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    n:Terrain_Net
    defer net_free(&n)
    time:=core.Time{tick=10,dt=1.0/60}
    let_in,refused:=false,false
    for served:=0;!let_in && served<8;served+=1 {
        limit.remaining=served
        context.allocator={memory_limit_proc,&limit}
        answer:=rate_take(&n,7,time,{rate=4})
        context.allocator=owner
        limit.remaining=max(int)
        let_in=answer==.None
        if let_in {break}
        refused=true
        testing.expectf(t,answer==.Rate && len(n.rates)==0,"with %d requests served: %v, %d connections counted",served,answer,len(n.rates))
    }
    testing.expect(t,let_in && refused && len(n.rates)==1,"refused without memory, and let in with it")
}
