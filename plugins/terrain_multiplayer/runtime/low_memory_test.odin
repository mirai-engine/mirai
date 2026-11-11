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

// The first piece of a part a client receives and the first ask of a
// connection a server counts, with the memory ending at each request in turn:
// the part is left out, broken or with a problem, and the ask is refused as
// Rate; with memory enough the part waits for its bytes and the ask is let in.
@(test)
a_part_and_an_ask_without_memory_are_left_out :: proc(t:^testing.T) {
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    n:Terrain_Net
    defer net_free(&n)
    problems:core.Problems
    source:=base.Asset_Id{3,3}
    held,left_out:=false,false
    for served:=0;!held && served<8;served+=1 {
        limit.remaining=served
        context.allocator={memory_limit_proc,&limit}
        page_chunk(&n,Net_Terrain_Page{source=source,part=.Grid,raw=8,total=8},&problems)
        context.allocator=owner
        limit.remaining=max(int)
        src:=net_source(&n,source,false)
        held=src!=nil && len(src.pages)==1 && !src.pages[0].broken && len(src.pages[0].bytes)==8
        if held {break}
        left_out=true
        testing.expectf(t,core.problem_find(&problems,core.NONE,"terrain.net_memory")!=nil || src!=nil && len(src.pages)==1 && src.pages[0].broken,"with %d requests served: the part is neither held nor told",served)
        if src!=nil {
            for &page in src.pages {delete(page.bytes)}
            clear(&src.pages)
        }
    }
    testing.expect(t,held && left_out,"left out without memory, and held with it")

    time:=core.Time{tick=10,dt=1.0/60}
    let_in,refused:=false,false
    for served:=0;!let_in && served<8;served+=1 {
        limit.remaining=served
        context.allocator={memory_limit_proc,&limit}
        answer:=ask_admit(&n,7,Net_Terrain_Ask{source=source,tick=10},time,{rate=4})
        context.allocator=owner
        limit.remaining=max(int)
        let_in=answer==.None
        if let_in {break}
        refused=true
        testing.expectf(t,answer==.Rate && len(n.rates)==0,"with %d requests served: %v, %d connections counted",served,answer,len(n.rates))
    }
    testing.expect(t,let_in && refused && len(n.rates)==1,"refused without memory, and let in with it")
}
