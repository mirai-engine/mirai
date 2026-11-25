package locomotion

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

// Jump facing a wall whose top is over ground_height climbs onto it in time and stands there, also
// on the middle of a top thinner than the character; one lower is jumped onto, one over max_height,
// with a roof over its top or behind it is not climbed.
@(test)
jump_facing_a_ledge_mantles_onto_it_where_it_fits :: proc(t:^testing.T) {
    Case :: struct {top:f32,roof:bool,yaw:f32,mantles:bool,thick:f32}
    cases:=[]Case{
        {top=1.8,mantles=true},
        {top=1.8,mantles=true,thick=0.16},
        {top=1.0},
        {top=3.0},
        {top=1.8,roof=true},
        {top=1.8,yaw=mm.PI},
    }
    for c in cases {
        f:Loco_Test
        if !loco_test_init(t,&f,{0,0,0}) {return}
        defer loco_test_destroy(&f)
        core.add(&f.mantles,f.e,MANTLE_DEFAULT)
        thick:=c.thick if c.thick>0 else 1
        loco_test_box(&f,{2,c.top*0.5,thick*0.5},{0,c.top*0.5,-0.8-thick*0.5}) // its face at z -0.8
        if c.roof {loco_test_box(&f,{2,0.1,1},{0,c.top+1.2,-1.8})}
        loco_test_tick(&f,{},30,yaw=c.yaw)
        loco_test_tick(&f,{},1,JUMP,yaw=c.yaw)
        testing.expectf(t,(loco_state(&f).mode==MODE_MANTLING)==c.mantles,"%v: mode %v",c,loco_state(&f).mode)
        if !c.mantles {continue}
        testing.expectf(t,abs(mantle_state(&f).height-c.top)<0.01,"%v: ledge %v",c,mantle_state(&f).height)
        // What warps a clip of the climb: its ends.
        climb:=mantle_state(&f)
        testing.expectf(t,abs(climb.from.y)<0.01 && abs(climb.to.y-c.top)<0.01 && climb.to.z<-0.8,"%v: from %v to %v",c,climb.from,climb.to)
        ticks:=0
        for loco_state(&f).mode==MODE_MANTLING && ticks<120 {
            loco_test_tick(&f,{},1,yaw=c.yaw)
            ticks+=1
        }
        testing.expectf(t,ticks>=int(MANTLE_DEFAULT.time*60) && ticks<=int(MANTLE_DEFAULT.time*60)+2,"%v: climbed in %d ticks",c,ticks)
        loco_test_tick(&f,{},20,yaw=c.yaw)
        at:=loco_position(&f)
        on_top:=at.z<-1.05 if c.thick==0 else at.z<-0.8 && at.z>-0.8-c.thick
        testing.expectf(t,loco_found(&f).standing && abs(at.y-c.top)<0.05 && on_top,"%v: stands on the top at %v",c,at)
        testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)
    }
}

// An Override layered move takes the climb off its own way (the root motion of the animation of the
// climb, warped onto the ledge): the body goes where the move takes it and the climb lasts its time.
@(test)
a_layered_move_drives_a_climb_for_its_time :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,0}) {return}
    defer loco_test_destroy(&f)
    core.add(&f.mantles,f.e,MANTLE_DEFAULT)
    loco_test_box(&f,{2,0.9,0.5},{0,0.9,-1.3})
    loco_test_tick(&f,{},30)
    loco_test_tick(&f,{},1,JUMP)
    testing.expect_value(t,loco_state(&f).mode,MODE_MANTLING)
    ticks:=0
    for loco_state(&f).mode==MODE_MANTLING && ticks<120 {
        add_move(&f.loco_requests,f.e,{velocity={0,4,0},ticks=1,mix=.Override})
        loco_test_tick(&f,{},1)
        ticks+=1
    }
    at:=loco_position(&f)
    testing.expectf(t,ticks>=int(MANTLE_DEFAULT.time*60) && ticks<=int(MANTLE_DEFAULT.time*60)+2,"climbed for %d ticks",ticks)
    testing.expectf(t,at.y>2 && abs(at.z)<0.1,"straight up where the move took it, not across onto the top: %v",at)
    loco_test_tick(&f,{},1)
    testing.expectf(t,loco_velocity(&f).y<1,"the move of the last tick does not carry on: %v",loco_velocity(&f))
}

// A custom mode lasts only while its owner claims it: a slide or a climb whose component is removed
// halfway hands the character back on the next tick, falling, and its walk stops it where it lands
// instead of the last move of the slide or the climb going on.
@(test)
a_custom_mode_whose_owner_goes_returns_to_the_walk_on_the_next_tick :: proc(t:^testing.T) {
    Case :: struct {mode:Locomotion_Mode}
    for c in ([]Case{{MODE_SLIDING},{MODE_MANTLING}}) {
        f:Loco_Test
        if !loco_test_init(t,&f,{0,0,0}) {return}
        defer loco_test_destroy(&f)
        loco_test_tick(&f,{},20)
        if c.mode==MODE_SLIDING {
            core.add(&f.slides,f.e,SLIDE_DEFAULT)
            loco_test_tick(&f,{0,0,-1},40)
            loco_test_tick(&f,{0,0,-1},2,CROUCH)
        } else {
            core.add(&f.mantles,f.e,MANTLE_DEFAULT)
            loco_test_box(&f,{2,0.9,0.5},{0,0.9,-1.3})
            loco_test_tick(&f,{},10)
            loco_test_tick(&f,{},1,JUMP)
            loco_test_tick(&f,{},5)
        }
        testing.expectf(t,loco_state(&f).mode==c.mode,"%v: in the mode, %v",c,loco_state(&f).mode)
        if c.mode==MODE_SLIDING {core.remove(&f.slides,f.e)} else {core.remove(&f.mantles,f.e)}
        loco_test_tick(&f,{},1)
        mode:=loco_state(&f).mode
        testing.expectf(t,mode==MODE_FALLING || mode==MODE_WALKING,"%v: back to its walk the next tick, %v",c,mode)
        loco_test_tick(&f,{},120)
        testing.expectf(t,flat_speed(&f)<0.1,"%v: it stops without a move, %v m/s",c,flat_speed(&f))
        testing.expect_value(t,f.problems.count,0)
    }
}
