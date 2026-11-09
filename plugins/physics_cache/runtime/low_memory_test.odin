package physics_cache

import "base:runtime"
import "core:testing"
import mm "mirai:std/math"

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

// The rooms of a recorder, with the memory ending at each request in turn:
// it answers Out_Of_Memory and holds nothing, and with memory enough it is made.
@(test)
a_recorder_without_memory_is_refused_and_holds_nothing :: proc(t:^testing.T) {
    limit:=Memory_Limit{owner=context.allocator}
    limited:=runtime.Allocator{memory_limit_proc,&limit}
    descs:=[]Recorder_Desc{
        {frames=4,tracks=3,samples=8,vertices=128,indices=256,origin=mm.TRANSFORM_IDENTITY},
        {frames=1,tracks=1,samples=1,vertices=24,indices=36,origin=mm.TRANSFORM_IDENTITY},
    }
    for desc,at in descs {
        record:Cache_Recorder
        made,refused:=false,false
        for served in 0..<32 {
            limit.remaining=served
            error:=record_init(&record,desc,limited)
            limit.remaining=max(int)
            if made=error==.None;made {break}
            refused=true
            if !testing.expectf(t,error==.Out_Of_Memory,"recorder %d with %d requests served: %v",at,served,error) {break}
            testing.expectf(t,record.allocator.procedure==nil && cap(record.tracks)==0 && record.scratch==nil,"recorder %d with %d requests served keeps rooms",at,served)
        }
        testing.expectf(t,made && refused && cap(record.frames)>=desc.frames,"recorder %d: refused without memory, and made with it",at)
        record_destroy(&record)
    }
}
