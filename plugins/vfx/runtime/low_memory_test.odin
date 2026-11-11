package vfx

import "base:runtime"
import "core:testing"
import "mirai:core"

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

// The births of a channel the GPU did not start yet, with the memory ending
// at each request in turn: a channel that finds none to be counted waits for
// the next frame with a problem and none of its births given, and with
// memory enough its births go.
@(test)
a_channel_without_memory_waits_with_its_births :: proc(t:^testing.T) {
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    clocks:Particle_Clocks
    defer delete(clocks.channels)
    if !testing.expect(t,resize(&clocks.channels,1)==nil) {return}
    ring:=&clocks.channels[0]
    ring.name,ring.count,ring.emitted=Particle_Channel_Name(CHANNEL_GAME),1,1
    problems:core.Problems
    given,waited:=false,false
    for served:=0;!given && served<8;served+=1 {
        sync:Particle_Sync
        limit.remaining=served
        context.allocator={memory_limit_proc,&limit}
        channels_sync(&sync,&clocks,0,&problems)
        context.allocator=owner
        limit.remaining=max(int)
        given=len(sync.births)==1 && len(sync.regions)==1
        if len(sync.started)==0 {
            waited=true
            testing.expectf(t,len(sync.births)==0 && core.problem_find(&problems,core.NONE,"vfx.memory")!=nil,"with %d requests served: %d births of a channel that was not counted, or no problem",served,len(sync.births))
        }
        delete(sync.births);delete(sync.regions);delete(sync.started)
    }
    testing.expect(t,given && waited,"it waits without memory, and with it its births go")
}
