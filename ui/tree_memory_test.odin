package ui

import "base:runtime"
import "core:mem"
import "core:testing"
import "mirai:std/base"

// What a tree asks its allocator for to be made, loaded, linked with the
// widgets it names and instanced, with the memory ending at each request in
// turn: the call answers false and leaves nothing allocated, and with memory
// enough it goes through.
@(test)
tree_calls_without_memory_fail_whole :: proc(t:^testing.T) {
    Limit :: struct {owner:runtime.Allocator,remaining:int}
    limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        limit:=(^Limit)(data)
        if size>0 && (mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed) {
            if limit.remaining<=0 {return nil,.Out_Of_Memory}
            limit.remaining-=1
        }
        return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
    }
    r:Test_Components
    data:=test_components(&r)
    whole:Widget_Tree
    if !testing.expect(t,tree_load(&whole,data,{})) {return}
    defer tree_destroy(&whole)

    texts:=make([dynamic]u8,context.temp_allocator)
    widget_styles:=[2]Node_Style{{},{fill={10,20,30,255}}}
    widget_nodes:=[2]Tree_Node{
        tree_node_record(&texts,-1,{kind=.Box,name="frame",style=1}),
        tree_node_record(&texts,0,{kind=.Text,name="label",style=1,text="Button"}),
    }
    components:=[1]Tree_Component{tree_component_record("button",0,0)}
    components[0].widget=base.Asset_Id{1,2}
    nodes:=[2]Tree_Node{
        tree_node_record(&texts,-1,{kind=.Box,name="inventory"}),
        tree_node_record(&texts,0,{kind=.Component,name="equip",component=1}),
    }
    imports:=[1]Tree_Data{{text=texts[:],nodes=widget_nodes[:],styles=widget_styles[:]}}
    named:=Tree_Data{text=texts[:],nodes=nodes[:],components=components[:]}
    // What tree_link gives lives in its allocator, which whoever links frees whole.
    block:=make([]u8,1<<20)
    defer delete(block)

    Call :: enum {Init,Load,Link,Instance}
    for call in Call {
        done,refused:=false,false
        for served in 0..<512 {
            tracking:mem.Tracking_Allocator
            mem.tracking_allocator_init(&tracking,context.allocator)
            arena:mem.Arena
            mem.arena_init(&arena,block)
            limit:=Limit{owner=mem.arena_allocator(&arena) if call==.Link else mem.tracking_allocator(&tracking),remaining=served}
            limited:=runtime.Allocator{limit_proc,&limit}
            ok:bool
            switch call {
            case .Init:
                tree:Widget_Tree
                ok=tree_init(&tree,{allocator=limited,max_nodes=8})
                testing.expectf(t,ok==(tree.nodes!=nil),"%d requests served: a tree or none",served)
                if ok {tree_destroy(&tree)}
            case .Load:
                tree:Widget_Tree
                ok=tree_load(&tree,data,{},limited)
                testing.expectf(t,ok==(tree.nodes!=nil) && (!ok || tree.node_count==whole.node_count),"%d requests served: a tree or none",served)
                if ok {tree_destroy(&tree)}
            case .Link:
                linked:Tree_Data
                linked,ok=tree_link(named,imports[:],limited)
                testing.expectf(t,ok==(len(linked.component_nodes)>0),"%d requests served: the records of the widget or none",served)
            case .Instance:
                instance:Tree_Instance
                ok=tree_instance_init(&instance,&whole,nil,nil,"",limited)
                if ok || instance.allocator.procedure!=nil {tree_instance_destroy(&instance)}
            }
            testing.expectf(t,len(tracking.allocation_map)==0 && len(tracking.bad_free_array)==0,"%v with %d requests served: %d left allocated",call,served,len(tracking.allocation_map))
            mem.tracking_allocator_destroy(&tracking)
            if done=ok;done {break}
            refused=true
        }
        testing.expectf(t,done && refused,"%v: refused without memory, and with it it goes through",call)
    }
}
