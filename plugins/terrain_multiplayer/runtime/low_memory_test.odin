package terrain_multiplayer

import "base:runtime"
import "core:testing"
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

// The edits of the server a client logs, the one that opens the log, one past
// its end and one before its start, with the memory ending at each request in
// turn: the edit is left out and the log stays as it was, and with memory
// enough it is logged.
@(test)
an_edit_without_memory_for_its_log_is_left_out_and_the_log_stays :: proc(t:^testing.T) {
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    n:Terrain_Net
    defer net_free(&n)
    source:=base.Asset_Id{3,3}
    sequences:=[]u32{5,9,3}
    refused:=false
    for sequence in sequences {
        put:=false
        for served in 0..<8 {
            src:=net_source(&n,source,false)
            before_first,before_count:=u32(0),0
            if src!=nil {before_first,before_count=src.first,len(src.log)}
            limit.remaining=served
            context.allocator={memory_limit_proc,&limit}
            enough:=false
            if src=net_source(&n,source,true);src!=nil {put,enough=log_put(src,Net_Terrain_Edit{source=source,sequence=sequence})}
            context.allocator=owner
            limit.remaining=max(int)
            if put {break}
            refused=true
            if !testing.expectf(t,!enough,"edit %d with %d requests served is left out with memory enough",sequence,served) {break}
            if src!=nil && before_count>0 {testing.expectf(t,src.first==before_first && len(src.log)==before_count,"edit %d with %d requests served moved the log",sequence,served)}
        }
        testing.expectf(t,put,"edit %d is logged with memory enough",sequence)
    }
    testing.expect(t,refused,"the log asks for memory")
    src:=net_source(&n,source,false)
    if !testing.expect(t,src!=nil) {return}
    testing.expect(t,src.first==3 && len(src.log)==7 && src.newest==9)
    for sequence in sequences {testing.expect_value(t,src.log[sequence-src.first].edit.sequence,sequence)}
}
