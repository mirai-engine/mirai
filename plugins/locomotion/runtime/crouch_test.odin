package locomotion

import cmath "core:math"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"

@(private="file") STANDING :: f32(1.8) // the height of phys.collider_character

// Crouch held makes the capsule crouch_height tall and walks at crouch_speed; let go under a roof
// lower than standing it stays crouched (cramped) and stands up past the roof.
@(test)
crouching_walks_short_and_slow_and_stands_up_where_there_is_room :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,0}) {return}
    defer loco_test_destroy(&f)
    walk:=WALK_DEFAULT
    loco_test_box(&f,{2,0.1,1.5},{0,1.5,-3.5}) // a roof from 1.4 to 1.6 m over z -5..-2
    loco_test_tick(&f,{},30)
    testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)
    loco_test_tick(&f,{0,0,-1},90,CROUCH)
    testing.expect_value(t,loco_state(&f).mode,MODE_CROUCHING)
    testing.expectf(t,abs(height_of(&f)-walk.crouch_height)<1e-4,"height %v",height_of(&f))
    testing.expectf(t,abs(flat_speed(&f)-walk.crouch_speed)<0.05,"crouched speed %v",flat_speed(&f))
    z:=loco_position(&f).z
    testing.expectf(t,z<-2.5 && z>-4.5,"under the roof at z %v",z)
    loco_test_tick(&f,{0,0,-1},10)
    testing.expect_value(t,loco_state(&f).mode,MODE_CROUCHING)
    testing.expect(t,abs(height_of(&f)-walk.crouch_height)<1e-4,"the roof keeps it crouched")
    testing.expect(t,loco_found(&f).standing && loco_found(&f).cramped)
    loco_test_tick(&f,{0,0,-1},60)
    testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)
    testing.expectf(t,abs(height_of(&f)-STANDING)<1e-4,"past the roof it stands: %v",height_of(&f))
}

// A jump held to its apex reaches jump_height, whatever its jump_rise; let go at once it keeps only the
// speed it started with, and with jump_cut less of it.
@(test)
a_jump_held_reaches_jump_height_and_one_let_go_early_less :: proc(t:^testing.T) {
    peak :: proc(t:^testing.T,held_ticks:int,height,rise,cut:f32) -> f32 {
        f:Loco_Test
        if !loco_test_init(t,&f,{0,0,0}) {return 0}
        defer loco_test_destroy(&f)
        loco_test_tick(&f,{},20)
        walk:=core.edit(&f.walks,f.e)
        walk.jump_height,walk.jump_rise,walk.jump_cut=height,rise,cut
        start:=loco_position(&f).y
        top:=start
        for i in 0..<180 {
            loco_test_tick(&f,{},1,JUMP if i<held_ticks else input.Action_Mask(0))
            top=max(top,loco_position(&f).y)
        }
        return top-start
    }
    g:=f32(9.81)
    Case :: struct {height,rise:f32}
    for c in ([?]Case{{1.2,0},{1.2,0.25},{2.9,5.0/30},{0.6,0.5}}) {
        held:=peak(t,170,c.height,c.rise,1)
        testing.expectf(t,abs(held-c.height)<0.01*c.height,"%v: held it rises %v, not jump_height",c,held)
        speed:=walk_jump_speed(Walk{jump_height=c.height,jump_rise=c.rise},g)
        testing.expectf(t,abs(speed*c.rise+speed*speed/(2*g)-c.height)<1e-4*c.height,"%v: launch %v",c,speed)
        // Let go at once, it holds the tick it jumps in.
        tapped:=peak(t,1,c.height,c.rise,1)
        want:=speed*min(c.rise,1.0/60)+speed*speed/(2*g)
        testing.expectf(t,abs(tapped-want)<0.01*c.height,"%v: let go at once it rises %v, want %v",c,tapped,want)
        if c.rise>0 {testing.expectf(t,tapped<held-0.05,"%v: let go at once it rises %v, held %v",c,tapped,held)}
        cut:=peak(t,1,c.height,c.rise,0.5)
        testing.expectf(t,cut<0.75*tapped,"%v: with jump_cut it rises %v, without %v",c,cut,tapped)
    }
}
