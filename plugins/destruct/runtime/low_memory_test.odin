package destruct

import "base:runtime"
import "core:testing"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:std/geom"

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

// The scratch of the cache for the capacities of a simulation, with the memory
// ending at each request in turn: it is refused and holds nothing, so the
// step leaves the tick, and with memory enough it is made.
@(test)
the_scratch_of_the_cache_without_memory_is_refused_and_holds_nothing :: proc(t:^testing.T) {
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    capacities:=[][2]int{{64,32},{1,1}}
    for capacity in capacities {
        cache:Destruct_Cache
        made,refused:=false,false
        for served in 0..<16 {
            limit.remaining=served
            context.allocator={memory_limit_proc,&limit}
            made=cache_make(&cache,{pieces=capacity[0],bodies=capacity[1]})
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

// The geometry of the pieces of an entry, with the memory ending at each
// request in turn: a piece of the cut that finds none is not noted and its
// entity is told, a half that finds none has no geometry, and with memory
// enough both have theirs.
@(test)
the_geometry_of_a_piece_without_memory_is_not_noted :: proc(t:^testing.T) {
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner,remaining=max(int)}
    limited:=runtime.Allocator{memory_limit_proc,&limit}
    cache:Destruct_Cache
    if !testing.expect(t,cache_make(&cache,{pieces=4,bodies=4})) {return}
    defer cache_free(&cache)
    entry:Entry
    entry.slots=2
    defer {
        for &visual in entry.visuals {geom.mesh_buffer_destroy(&visual.geometry)}
        delete(entry.visuals)
    }
    problems:core.Problems
    noted,told:=false,false
    for served:=0;!noted && served<8;served+=1 {
        limit.remaining=served
        context.allocator=limited
        visuals_source(&problems,core.NONE,&entry,{{id=1,source=0,parent=-1,volume=1}})
        context.allocator=owner
        limit.remaining=max(int)
        noted=visual_find(&entry,1)!=nil
        if noted {break}
        told=true
        testing.expectf(t,len(entry.visuals)==0 && core.problem_find(&problems,core.NONE,"destruct.memory")!=nil,"with %d requests served: %d visuals, and no problem says the memory",served,len(entry.visuals))
    }
    if !testing.expect(t,noted && told,"refused without memory, and noted with it") {return}
    if !testing.expect(t,geom.cube_build(&visual_find(&entry,1).geometry)) {return}
    half:=phys.Piece_Info{id=2,source=-1,parent=1,volume=0.5,cut_normal={0,1,0},front=true}
    cut,refused:=false,false
    for served:=0;!cut && served<64;served+=1 {
        limit.remaining=served
        context.allocator=limited
        cut=visual_cut(&cache,&entry,half)
        context.allocator=owner
        limit.remaining=max(int)
        made:=visual_find(&entry,2)
        if cut {
            testing.expect(t,made!=nil && len(made.geometry.indices)>0 && len(made.geometry.normals)==len(made.geometry.positions),"the half has its geometry")
            break
        }
        refused=true
        testing.expectf(t,made==nil || len(made.geometry.positions)+len(made.geometry.indices)==0,"with %d requests served: a half that was refused kept a part of its geometry",served)
    }
    testing.expect(t,cut && refused,"refused without memory, and cut with it")
}
