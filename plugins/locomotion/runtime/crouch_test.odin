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

// A jump let go at once rises jump_height; held, it keeps the speed it started with for jump_rise and
// rises that speed by jump_rise more; held longer, no more than that.
@(test)
a_jump_held_rises_at_its_speed_for_jump_rise :: proc(t:^testing.T) {
    peak :: proc(t:^testing.T,held_ticks:int,rise:f32) -> f32 {
        f:Loco_Test
        if !loco_test_init(t,&f,{0,0,0}) {return 0}
        defer loco_test_destroy(&f)
        loco_test_tick(&f,{},20)
        core.edit(&f.walks,f.e).jump_rise=rise
        start:=loco_position(&f).y
        top:=start
        for i in 0..<90 {
            loco_test_tick(&f,{},1,JUMP if i<held_ticks else input.Action_Mask(0))
            top=max(top,loco_position(&f).y)
        }
        return top-start
    }
    g:=f32(9.81)
    speed:=cmath.sqrt(2*g*WALK_DEFAULT.jump_height)
    tapped:=peak(t,1,0.25)
    testing.expectf(t,abs(tapped-WALK_DEFAULT.jump_height)<0.05,"let go at once it rises %v, not jump_height %v",tapped,WALK_DEFAULT.jump_height)
    held:=peak(t,60,0.25)
    want:=WALK_DEFAULT.jump_height+speed*0.25
    testing.expectf(t,abs(held-want)<0.08,"held it rises %v, want %v",held,want)
    without:=peak(t,60,0)
    testing.expectf(t,abs(without-WALK_DEFAULT.jump_height)<0.05,"without jump_rise holding does nothing: %v",without)
}
