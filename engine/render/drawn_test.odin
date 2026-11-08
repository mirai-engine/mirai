package render

import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

@(test)
set_hidden_gives_and_takes_hidden_once :: proc(t:^testing.T) {
    es:core.Entities;core.entities_init(&es);defer core.entities_destroy(&es)
    hidden:core.Table(Hidden);core.table_init(&hidden,"Hidden");defer core.table_destroy(&hidden)
    e:=core.create(&es)
    set_hidden(&hidden,e,true)
    set_hidden(&hidden,core.NONE,true)
    core.table_settle(&hidden,&es)
    testing.expect(t,core.has(&hidden,e) && core.count(core.read(&hidden))==1)
    set_hidden(&hidden,e,true)
    core.table_settle(&hidden,&es)
    testing.expect_value(t,core.count(core.read(&hidden)),1)
    set_hidden(&hidden,e,false)
    core.table_settle(&hidden,&es)
    testing.expect(t,!core.has(&hidden,e))
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
