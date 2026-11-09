package destruct_multiplayer

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

// The state of a broken destructible a client receives, whole in a piece and
// in two, with the memory ending at each request in turn: the piece is left
// out with a problem, the state is asked for again and none stands half
// written; with memory enough it stands.
@(test)
a_state_without_memory_is_left_out_reported_and_asked_again :: proc(t:^testing.T) {
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    Case :: struct {id:base.Entity_Id,total:u32}
    cases:=[]Case{{5,64},{6,NET_STATE_CHUNK+8}}
    for c in cases {
        n:Destruct_Net
        stood,refused:=false,false
        for served in 0..<8 {
            problems:core.Problems
            limit.remaining=served
            context.allocator={memory_limit_proc,&limit}
            for offset:=u32(0);offset<c.total;offset+=NET_STATE_CHUNK {
                net_chunk(&n,Net_State{id=c.id,sequence=1,check=9,total=c.total,offset=offset,count=min(c.total-offset,NET_STATE_CHUNK)},&problems)
            }
            context.allocator=owner
            limit.remaining=max(int)
            l:=net_link(&n,c.id,false)
            if stood=l!=nil && l.state_ready;stood {
                testing.expectf(t,problems.count==0 && len(l.state)==int(c.total),"state %d with %d requests served stands with a problem",c.id,served)
                break
            }
            refused=true
            testing.expectf(t,problems.count==1,"state %d with %d requests served reports nothing",c.id,served)
            if l!=nil {testing.expectf(t,l.ask && l.state_have==0 && len(l.state)==0,"state %d with %d requests served is half written",c.id,served)}
        }
        testing.expectf(t,stood && refused,"state %d: left out without memory, and it stands with it",c.id)
        net_free(&n)
    }
}
