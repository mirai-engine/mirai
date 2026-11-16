package render

import "base:runtime"
import "core:testing"
import "mirai:core"
import gpu "mirai:render"
import mm "mirai:std/math"

@(test)
set_hidden_gives_and_takes_hidden_once :: proc(t:^testing.T) {
    w:Render_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    e:=core.create(&w.entities)
    set_hidden(&w.hidden,e,true)
    set_hidden(&w.hidden,core.NONE,true)
    test_world_settle(&w)
    testing.expect(t,core.has(&w.hidden,e) && core.count(&w.hidden)==1)
    set_hidden(&w.hidden,e,true)
    test_world_settle(&w)
    testing.expect_value(t,core.count(&w.hidden),1)
    set_hidden(&w.hidden,e,false)
    test_world_settle(&w)
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
