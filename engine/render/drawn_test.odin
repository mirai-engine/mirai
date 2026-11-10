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
    testing.expect(t,core.has(&w.hidden,e) && core.count(&w.hidden)==1)
    set_hidden(&w.hidden,e,true)
    core.test_world_settle(&w)
    testing.expect_value(t,core.count(&w.hidden),1)
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

// The last instance of the world takes the place of the one that goes, as in
// the renderer: the lists that name instances follow it, and the visual
// instances of the application stay after those of the world.
@(test)
an_instance_that_goes_gives_its_place_to_the_last_of_the_world :: proc(t:^testing.T) {
    w:Render_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    sync:Render_Sync;defer sync_free(&sync)
    entities:[4]core.Entity
    for &e,i in entities {
        e=core.create(&w.entities)
        _,kept:=core.entity_map_put(&sync.drawn,e,Drawn{derives=i==1 || i==3,lerp=i==0 || i==3})
        testing.expect(t,kept)
        if i==1 || i==3 {append(&sync.deriving,u32(i))}
        if i==0 || i==3 {append(&sync.lerping,u32(i))}
    }
    append(&sync.extras,gpu.Instance_Desc{object_id=77},gpu.Instance_Desc{object_id=u64(entities[2]),replace_source=true})
    testing.expect_value(t,instance_count(&sync),6)
    testing.expect_value(t,instance_object(&sync,3),u64(entities[3]))
    testing.expect_value(t,instance_object(&sync,4),u64(77))
    testing.expect(t,instance_object(&sync,6)==0 && instance_object(&sync,-1)==0)
    testing.expect(t,replaces(sync.extras[:],u64(entities[2])) && !replaces(sync.extras[:],77),"only what is drawn in place of a mesh replaces it")

    instance_remove(&sync,1)
    testing.expect_value(t,len(sync.drawn.entities),3)
    testing.expect_value(t,instance_entity(&sync,1),entities[3])
    testing.expect_value(t,instance_of(&sync,entities[3]),1)
    testing.expect_value(t,instance_of(&sync,entities[1]),-1)
    testing.expect(t,len(sync.deriving)==1 && sync.deriving[0]==1,"the one that took the place derives its rows there")
    testing.expect(t,len(sync.lerping)==2 && sync.lerping[0]==0 && sync.lerping[1]==1)
    testing.expect(t,len(sync.taken)==1 && sync.taken[0]==Taken{1,3},"the renderer gets what took the place, from where it has it")
    testing.expect_value(t,instance_object(&sync,3),u64(77))
    // The last one goes: no other takes a place.
    instance_remove(&sync,2)
    testing.expect(t,len(sync.taken)==1 && len(sync.deriving)==1 && len(sync.lerping)==2 && instance_count(&sync)==4)
    // The one that took a place takes another: the renderer still has it where it was first.
    instance_remove(&sync,0)
    testing.expect_value(t,instance_entity(&sync,0),entities[3])
    testing.expect(t,len(sync.taken)==1 && sync.taken[0]==Taken{0,3} && len(sync.drawn.entities)==1)
    testing.expect(t,len(sync.deriving)==1 && sync.deriving[0]==0 && len(sync.lerping)==1 && sync.lerping[0]==0)
}
