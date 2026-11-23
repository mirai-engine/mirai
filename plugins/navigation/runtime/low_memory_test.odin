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

@(private)
@(test_world)
Scratch_World :: struct {
    using world:Test_World,
    paths:core.Table(Nav_Path),
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
        w:Scratch_World
        if !test_world_init(t,&w) {return}
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
                agents_avoid(nil,&agents,&w.paths,nil,1.0/60,&problems)
                done=len(agents.grid.items)>=len(agents.near)
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
        agents_free(&agents)
        test_world_destroy(&w)
    }
}

// The scratch of the neighbors is made for every agent, with or without a
// body, and every other character before they are gathered: without memory
// for a crowd that came, the tick says so instead of leaving some out.
@(test)
a_crowd_without_memory_for_its_neighbors_reports_it :: proc(t:^testing.T) {
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner,remaining=max(int)}
    context.allocator={memory_limit_proc,&limit}
    defer context.allocator=owner
    f:Nav_Test
    if !nav_test_init(t,&f) {return}
    defer nav_test_destroy(&f)
    nav_test_box(&f,{0,-0.5,0},{20,0.5,20})
    nav_test_settled(t,&f)
    bodyless_player(&f,{0,0,0})
    bodyless_walker(&f,{-5,0,0})
    for _ in 0..<3 {agents_test_step(&f)}
    for i in 0..<100 {bodyless_walker(&f,{-15+f32(i%10),0,-5+f32(i/10)})}
    agents_test_step(&f)
    limit.remaining=0
    agents_test_step(&f)
    limit.remaining=max(int)
    reported:=core.problem_find(&f.problems,core.NONE,"navigation.memory")!=nil
    testing.expectf(t,len(f.run.near)==102 || reported,"%d of 102 are near each other and nothing is reported",len(f.run.near))
}
