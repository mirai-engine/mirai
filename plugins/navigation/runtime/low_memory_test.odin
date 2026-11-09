package navigation

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

// The scratch the ticks of the navigation grow, with the memory ending at
// each request in turn: the part that needed it is left for a later tick with
// a problem that says so, and with memory enough it goes through.
@(test)
navigation_scratch_without_memory_reports_it_and_leaves_its_part :: proc(t:^testing.T) {
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    Call :: enum {Seen,Avoid}
    for call in Call {
        problems:core.Problems
        builds:Navigation_Builds
        agents:Navigation_Agents
        paths:core.Table(Nav_Path)
        core.table_init(&paths,"Nav_Path")
        for i in 0..<3 {append(&agents.near,Near{entity=core.Entity(i+1),position={f32(i),0,0},radius=0.5,height=2})}
        done,refused:=false,false
        for served in 0..<8 {
            problems={}
            limit.remaining=served
            context.allocator={memory_limit_proc,&limit}
            switch call {
            case .Seen:
                seen:[]bool
                seen,done=seen_reset(&builds,8,&problems)
                done&&=len(seen)==8
            case .Avoid:
                agents_avoid(nil,&agents,&paths,1.0/60,&problems)
                done=len(agents.sorted)==len(agents.near) && len(agents.scratch)==len(agents.near)
            }
            context.allocator=owner
            limit.remaining=max(int)
            if done {
                testing.expectf(t,problems.count==0,"%v with %d requests served reports a problem and goes through",call,served)
                break
            }
            refused=true
            testing.expectf(t,problems.count==1,"%v with %d requests served reports nothing",call,served)
        }
        testing.expectf(t,done && refused,"%v: reported without memory, and with it it goes through",call)
        delete(builds.seen)
        delete(agents.near);delete(agents.sorted);delete(agents.scratch)
        core.table_destroy(&paths)
    }
}
