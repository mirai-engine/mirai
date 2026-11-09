package base

import "base:runtime"
import "core:strings"
import "core:testing"

@(test)
a_name_resolves_only_to_the_one_candidate_it_can_mean :: proc(t:^testing.T) {
    names:=[]string{"Point_Light","Spot_Light","Foo_Bar","FooBar","Open"}
    cases:=[]struct{name:string,index,matches:int}{
        {"Point_Light",0,1},
        {"PointLight",0,1},
        {"point light",0,1},
        {"POINT-LIGHT",0,1},
        {"open",4,1},
        {"FooBar",3,1},
        {"foobar",-1,2},
        {"Light",-1,0},
        {"",-1,0},
        {"___",-1,0},
    }
    for c in cases {
        index,matches:=name_find(c.name,names)
        testing.expectf(t,index==c.index && matches==c.matches,"%q: %d of %d",c.name,index,matches)
    }
}

@(test)
what_is_wrong_with_a_name_lists_those_it_could_mean_or_the_nearest :: proc(t:^testing.T) {
    names:=[]string{"A","B","L","Enter","Left_Control","Right_Control","Point_Light","Spot_Light","Foo_Bar","FooBar"}
    cases:=[]struct{name,says:string}{
        {"LCtrl",`"LCtrl" is not one; the nearest are Left_Control`},
        {"Light",`"Light" is not one; the nearest are Spot_Light, Point_Light`},
        {"Fobar",`"Fobar" is not one; the nearest are Foo_Bar, FooBar`},
        {"Nope",`"Nope" is not one`},
        {"foobar",`"foobar" fits several: Foo_Bar, FooBar;`},
    }
    for c in cases {
        problem:=name_problem(c.name,"one",names,context.temp_allocator)
        testing.expectf(t,strings.has_prefix(problem,c.says),"%s",problem)
    }
    nearest:[NAME_NEAREST]int
    paths:=[]string{"textures/grass","meshes/grass_rock","meshes/stone"}
    testing.expect_value(t,names_nearest("grass rock",paths,nearest[:],context.temp_allocator),1)
    testing.expect_value(t,nearest[0],1)
    testing.expect_value(t,names_nearest("Nope",{"Animation_Progress","Name","Boss","Bob","Door"},nearest[:],context.temp_allocator),0)
    testing.expect_value(t,names_nearest("a",{"Alpha","Be","a_"},nearest[:],context.temp_allocator),1)
}

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private="file")
Names_Memory :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
names_memory_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    limit:=(^Names_Memory)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if limit.remaining<=0 {return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// What the names ask their allocator for, with the memory ending at each
// request in turn: the nearest names are none or indices of candidates, what
// is wrong with a name still starts with it, and with memory enough both say
// what they say with all of it.
@(test)
names_without_memory_say_less_and_never_past_their_candidates :: proc(t:^testing.T) {
    long:="a_name_far_longer_than_the_sixty_three_bytes_a_distance_takes_without_asking_for_memory"
    names:=[]string{"Left_Control","Right_Control",long,"Spot_Light","Point_Light"}
    limit:=Names_Memory{owner=context.temp_allocator}
    limited:=runtime.Allocator{names_memory_proc,&limit}
    Call :: enum {Nearest,Problem}
    cases:=[]struct{call:Call,name:string}{{.Nearest,"Light"},{.Nearest,long[1:]},{.Problem,"LCtrl"},{.Problem,long[1:]}}
    for c in cases {
        whole:[NAME_NEAREST]int
        whole_count:=names_nearest(c.name,names,whole[:],context.temp_allocator)
        whole_problem:=name_problem(c.name,"one",names,context.temp_allocator)
        done,refused:=false,false
        for served in 0..<256 {
            limit.remaining=served
            nearest:[NAME_NEAREST]int
            count:=0
            problem:string
            switch c.call {
            case .Nearest: count=names_nearest(c.name,names,nearest[:],limited)
            case .Problem: problem=name_problem(c.name,"one",names,limited)
            }
            starved:=limit.remaining==0
            limit.remaining=max(int)
            for at in nearest[:count] {testing.expectf(t,at>=0 && at<len(names),"%v of %q with %d requests served: candidate %d",c.call,c.name,served,at)}
            if c.call==.Problem {testing.expectf(t,problem=="" || problem[0]=='"',"%q with %d requests served: %s",c.name,served,problem)}
            if !starved {
                done=true
                same:=problem==whole_problem if c.call==.Problem else count==whole_count && nearest==whole
                testing.expectf(t,same,"%v of %q with memory: %d, %s",c.call,c.name,count,problem)
                break
            }
            refused=true
        }
        testing.expectf(t,done && refused,"%v of %q: asked for memory %v, went through with it %v",c.call,c.name,refused,done)
    }
}
