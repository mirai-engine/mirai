package render

import "base:runtime"
import "core:testing"
import "mirai:core"
import gpu "mirai:render"
import mm "mirai:std/math"

@(test)
set_hidden_gives_and_takes_hidden_once :: proc(t:^testing.T) {
    w:Render_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    e:=core.create(&w.entities)
    set_hidden(&w.hidden,e,true)
    set_hidden(&w.hidden,core.NONE,true)
    core.test_world_settle(&w)
    testing.expect(t,core.has(&w.hidden,e) && core.count(core.read(&w.hidden))==1)
    set_hidden(&w.hidden,e,true)
    core.test_world_settle(&w)
    testing.expect_value(t,core.count(core.read(&w.hidden)),1)
    set_hidden(&w.hidden,e,false)
    core.test_world_settle(&w)
    testing.expect(t,!core.has(&w.hidden,e))
}

@(test)
an_entity_is_drawn_between_its_last_two_ticks_at_the_alpha_of_the_frame :: proc(t:^testing.T) {
    previous,current:=mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY
    current.position={2,0,0}
    world:=core.World_Transform{current,previous}
    testing.expect_value(t,drawn_transform(world,core.FRAME_TIME_DEFAULT),current)
    testing.expect_value(t,drawn_transform(world,{alpha=1}),current)
    testing.expect_value(t,drawn_transform(world,{alpha=0.5}).position,[3]f32{1,0,0})
    testing.expect_value(t,drawn_transform(world,{alpha=0}).position,previous.position)
}

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private)
Memory_Limit :: struct {owner:runtime.Allocator,remaining:int}

@(private)
memory_limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    limit:=(^Memory_Limit)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if limit.remaining<=0 {return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// What the instances the renderer is given ask memory for, with the memory
// ending at each request in turn: those of a frame that draws an instance in
// place of a mesh are refused whole, and with memory enough they are made;
// a frame that replaces no mesh asks for none.
@(test)
instances_shown_in_place_of_a_mesh_without_memory_are_refused :: proc(t:^testing.T) {
    limit:=Memory_Limit{owner=context.allocator,remaining=max(int)}
    context.allocator=runtime.Allocator{memory_limit_proc,&limit}
    sync:Render_Sync;defer sync_free(&sync)
    for i in 0..<3 {append(&sync.instances,gpu.Instance_Desc{object_id=u64(i+1)})}
    Row :: struct {extras:[]gpu.Instance_Desc,asks:bool}
    rows:=[?]Row{
        {nil,false},
        {{{object_id=2}},false},
        {{{object_id=0,replace_source=true}},false},
        {{{object_id=2,replace_source=true}},true},
    }
    for row,at in rows {
        done,refused:=false,false
        for served in 0..<4 {
            limit.remaining=served
            composed,ok:=instances_composed(&sync,row.extras)
            limit.remaining=max(int)
            if done=ok;done {
                testing.expectf(t,len(composed)==len(sync.instances),"row %d: %d instances of %d",at,len(composed),len(sync.instances))
                break
            }
            refused=true
            testing.expectf(t,composed==nil,"row %d with %d requests served gives no instance",at,served)
        }
        testing.expectf(t,done && refused==row.asks,"row %d: refused only when it asks for memory and has none",at)
    }
}
