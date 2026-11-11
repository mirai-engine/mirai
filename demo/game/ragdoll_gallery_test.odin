package game

import "base:runtime"
import "core:testing"
import "mirai:core"
import rag "plugins:ragdoll/runtime"

// The requests of the gallery with the memory ending at each request in
// turn: without room for them the update says so and a cycle asked for is
// not queued; with memory enough it is.
@(test)
ragdoll_gallery_without_memory_reports_it :: proc(t:^testing.T) {
    Limit :: struct {owner:runtime.Allocator,remaining:int}
    limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        limit:=(^Limit)(data)
        if size>0 && (mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed) {
            if limit.remaining<=0 {return nil,.Out_Of_Memory}
            limit.remaining-=1
        }
        return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
    }
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    gallery:core.Table(Ragdoll_Gallery);configs:core.Table(rag.Ragdoll)
    core.table_init(&gallery,"Ragdoll_Gallery");core.table_init(&configs,"Ragdoll")
    defer core.table_destroy(&gallery);defer core.table_destroy(&configs)
    rig:=core.create(&entities)
    core.add(&gallery,rig,Ragdoll_Gallery{})
    core.add(&configs,rig,rag.Ragdoll{})
    core.table_settle(&gallery,&entities);core.table_settle(&configs,&entities)
    problems:=new(core.Problems);defer free(problems)
    done,refused:=false,false
    for served in 0..<4 {
        limit:=Limit{owner=context.allocator,remaining=served}
        requests:Ragdoll_Gallery_Requests
        requests.queue.items=make([dynamic]core.Entity,runtime.Allocator{limit_proc,&limit})
        problems^={}
        ragdoll_gallery_update(&gallery,&configs,&requests,core.Time{},problems)
        ragdoll_gallery_cycle(&requests,rig)
        done=len(requests.queue.items)==1
        testing.expectf(t,done==(problems.count==0),"%d requests served: a cycle is queued, or the update said why not",served)
        delete(requests.queue.items)
        if done {break}
        refused=true
    }
    testing.expect(t,done && refused,"refused without memory, and with it it goes through")
}
