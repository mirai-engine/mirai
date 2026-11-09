package streaming

import "base:runtime"
import "core:testing"
import "mirai:core"
import scene "mirai:engine/scene"

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
    es:core.Entities;core.entities_init(&es);defer core.entities_destroy(&es)
    references:core.Table(scene.Scene_Reference);core.table_init(&references,"Scene_Reference");defer core.table_destroy(&references)
    worlds:core.Table(core.World_Transform);core.table_init(&worlds,"World_Transform");defer core.table_destroy(&worlds)
    motions:core.Table(core.Motion);core.table_init(&motions,"Motion");defer core.table_destroy(&motions)
    parents:core.Table(core.Parent);core.table_init(&parents,"Parent");defer core.table_destroy(&parents)
    transforms:core.Table(core.Transform);core.table_init(&transforms,"Transform");defer core.table_destroy(&transforms)
    members:core.Table(scene.Section_Member);core.table_init(&members,"Section_Member");defer core.table_destroy(&members)
    roaming:core.Table(scene.Roaming);core.table_init(&roaming,"Roaming");defer core.table_destroy(&roaming)
    hierarchy:core.Hierarchy;defer core.value_free(&hierarchy,type_info_of(core.Hierarchy))
    movers:[2]core.Entity
    for &mover,at in movers {
        // The second has a far index: other entities come before it.
        if at==1 {for _ in 0..<40 {core.create(&es)}}
        mover=core.create(&es)
        core.add(&motions,mover,core.Motion{awake=true})
        core.add(&transforms,mover,core.Transform{{f32(at),0,0},1,{1,1,1}})
        core.add(&worlds,mover,core.World_Transform{transform={position={f32(at),0,0},rotation=1,scale=1}})
    }
    core.table_settle(&worlds,&es);core.table_settle(&motions,&es);core.table_settle(&transforms,&es)
    core.hierarchy_settle(&hierarchy,core.read(&parents),&es)
    core.entities_settle(&es)
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    for mover,at in movers {
        crossings:Streaming_Crossings
        // Only this one moves.
        for other in movers {core.free(&motions,other).awake=other==mover}
        core.table_settle(&motions,&es)
        index:=int(core.entity_index(mover))
        followed,refused:=false,false
        for served in 0..<4 {
            problems:core.Problems
            crossings.worlds={}
            limit.remaining=served
            context.allocator={memory_limit_proc,&limit}
            streaming_crossings(core.read(&motions),core.read(&references),core.read(&worlds),core.read(&roaming),core.ref(&hierarchy),&parents,&transforms,&members,&crossings,&problems)
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
