package streaming

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

// What moves is followed by its entity index, one near the start and one far
// in the table, with the memory ending at each request in turn: the entity is
// left where it hangs with a problem, and with memory enough it is followed.
@(test)
what_moves_without_memory_to_follow_it_stays_where_it_hangs_with_a_problem :: proc(t:^testing.T) {
    w:Streaming_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    movers:[2]core.Entity
    for &mover,at in movers {
        // The second has a far index: other entities come before it.
        if at==1 {for _ in 0..<40 {core.create(&w.entities)}}
        mover=core.create(&w.entities)
        core.add(&w.motions,mover,core.Motion{awake=true})
        core.add(&w.transforms,mover,core.Transform{{f32(at),0,0},1,{1,1,1}})
        core.add(&w.worlds,mover,core.World_Transform{transform={position={f32(at),0,0},rotation=1,scale=1}})
    }
    core.test_world_settle(&w)
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    for mover,at in movers {
        crossings:Streaming_Crossings
        // Only this one moves.
        for other in movers {core.free(&w.motions,other).awake=other==mover}
        core.test_world_settle(&w)
        index:=int(core.entity_index(mover))
        followed,refused:=false,false
        for served in 0..<4 {
            problems:core.Problems
            crossings.worlds={}
            limit.remaining=served
            context.allocator={memory_limit_proc,&limit}
            streaming_crossings(core.read(&w.motions),core.read(&w.references),core.read(&w.worlds),core.read(&w.roaming),core.ref(&w.hierarchy),&w.parents,&w.transforms,&w.members,&crossings,&problems)
            context.allocator=owner
            limit.remaining=max(int)
            if followed=index<len(crossings.homes) && crossings.homes[index].entity==mover;followed {
                testing.expectf(t,problems.count==0,"mover %d with %d requests served is followed with a problem",at,served)
                break
            }
            refused=true
            testing.expectf(t,problems.count==1 && len(crossings.homes)==0,"mover %d with %d requests served: %d problems, %d followed",at,served,problems.count,len(crossings.homes))
        }
        testing.expectf(t,followed && refused,"mover %d: left with a problem without memory, and followed with it",at)
        delete(crossings.homes)
    }
}
