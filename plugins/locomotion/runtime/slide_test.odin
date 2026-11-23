package locomotion

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

@(private)
flat_speed :: proc(f:^Loco_Test) -> f32 {
    v:=loco_velocity(f)
    return linalg.length(v.xz)
}

@(private)
height_of :: proc(f:^Loco_Test) -> f32 {return loco_found(f).height}

// Crouch at a run slides on at the speed it ran (friction 0) crouched for time, then stands up when it
// moves, even with crouch held, which crouches again only once let go; without a move it ends crouched.
// Crouch from a walk slower than start_speed crouches; a slide starts again only after cooldown.
@(test)
a_slide_keeps_the_run_for_its_time_and_ends_standing_or_crouched :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,0}) {return}
    defer loco_test_destroy(&f)
    core.add(&f.slides,f.e,SLIDE_DEFAULT)
    loco_test_tick(&f,{},20)
    loco_test_tick(&f,{0,0,-1},40)
    testing.expectf(t,abs(flat_speed(&f)-5)<0.05,"running %v",flat_speed(&f))
    loco_test_tick(&f,{0,0,-1},1,CROUCH)
    loco_test_tick(&f,{0,0,-1},1,CROUCH)
    testing.expect_value(t,loco_state(&f).mode,MODE_SLIDING)
    loco_test_tick(&f,{1,0,-1},60,CROUCH) // steering right turns the course at most steer_angle
    testing.expect_value(t,loco_state(&f).mode,MODE_SLIDING)
    testing.expectf(t,abs(flat_speed(&f)-5)<0.1,"slides at the run %v",flat_speed(&f))
    testing.expectf(t,abs(height_of(&f)-WALK_DEFAULT.crouch_height)<1e-4,"slides crouched %v",height_of(&f))
    v:=loco_velocity(&f)
    turned:=linalg.atan2(v.x,-v.z)
    testing.expectf(t,turned>0.1 && turned<=SLIDE_DEFAULT.steer_angle+0.01,"steered by %v rad",turned)
    loco_test_tick(&f,{0,0,-1},20,CROUCH)
    testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)
    testing.expect(t,loco_state(&f).crouch_lock,"crouch held after a slide that ends moving does not crouch")
    loco_test_tick(&f,{},30,CROUCH)
    testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)
    loco_test_tick(&f,{},1)
    loco_test_tick(&f,{},5,CROUCH)
    testing.expect_value(t,loco_state(&f).mode,MODE_CROUCHING)
    // Without a move at the end of a slide it stays crouched.
    loco_test_tick(&f,{0,0,-1},60)
    loco_test_tick(&f,{0,0,-1},2,CROUCH)
    testing.expect_value(t,loco_state(&f).mode,MODE_SLIDING)
    loco_test_tick(&f,{},90,CROUCH)
    testing.expect_value(t,loco_state(&f).mode,MODE_CROUCHING)
}

// Down a slope steeper than downhill_angle gravity speeds the slide up and keeps it going past its
// time; a jump leaves it in the air with its speed.
@(test)
a_slide_downhill_speeds_up_past_its_time_and_a_jump_leaves_it :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0.2,0},false) {return}
    defer loco_test_destroy(&f)
    loco_test_box(&f,{5,0.5,40},{0,-0.5,0},mm.quat_axis_angle({1,0,0},-15*mm.RAD_PER_DEG)) // down toward -Z
    core.add(&f.slides,f.e,SLIDE_DEFAULT)
    loco_test_tick(&f,{},30)
    testing.expect(t,loco_found(&f).standing)
    loco_test_tick(&f,{0,0,-1},40)
    loco_test_tick(&f,{0,0,-1},2,CROUCH)
    testing.expect_value(t,loco_state(&f).mode,MODE_SLIDING)
    loco_test_tick(&f,{},120,CROUCH)
    testing.expect_value(t,loco_state(&f).mode,MODE_SLIDING)
    speed:=linalg.length(loco_velocity(&f))
    testing.expectf(t,speed>8,"gravity sped it up to %v m/s",speed)
    loco_test_tick(&f,{},1,CROUCH|JUMP)
    testing.expect_value(t,loco_state(&f).mode,MODE_FALLING)
    testing.expect(t,loco_state(&f).jumped)
    loco_test_tick(&f,{},2)
    testing.expectf(t,flat_speed(&f)>7,"the jump keeps the speed of the slide: %v",flat_speed(&f))
}

// With crouch_toggle a press crouches and the next stands; a press at a sprint slides, at least at
// min_speed, and the slide ends standing when it moves. A press in the air within buffer of the
// landing slides on landing even from a run under start_speed, raised to min_speed.
@(test)
crouch_toggles_and_a_press_in_the_air_slides_on_landing :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,0}) {return}
    defer loco_test_destroy(&f)
    core.add(&f.slides,f.e,SLIDE_DEFAULT)
    loco_test_tick(&f,{},20)
    core.edit(&f.walks,f.e).crouch_toggle=true
    loco_test_tick(&f,{},1,CROUCH)
    loco_test_tick(&f,{},20)
    testing.expect_value(t,loco_state(&f).mode,MODE_CROUCHING)
    loco_test_tick(&f,{},1,CROUCH)
    loco_test_tick(&f,{},20)
    testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)
    // A run at 3: crouch does not slide on the ground.
    core.edit(&f.walks,f.e).max_speed=3
    loco_test_tick(&f,{0,0,-1},40)
    loco_test_tick(&f,{0,0,-1},1,CROUCH)
    loco_test_tick(&f,{0,0,-1},2)
    testing.expect_value(t,loco_state(&f).mode,MODE_CROUCHING)
    loco_test_tick(&f,{0,0,-1},1,CROUCH)
    loco_test_tick(&f,{0,0,-1},40)
    testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)
    // Jump, press crouch in the air: it slides on landing at min_speed and stands up after it.
    loco_test_tick(&f,{0,0,-1},1,JUMP)
    loco_test_tick(&f,{0,0,-1},10)
    loco_test_tick(&f,{0,0,-1},1,CROUCH)
    landed:=false
    for _ in 0..<90 {
        loco_test_tick(&f,{0,0,-1})
        if loco_state(&f).mode==MODE_SLIDING {landed=true;break}
    }
    testing.expect(t,landed,"the press in the air slides on landing")
    loco_test_tick(&f,{0,0,-1},10)
    testing.expect_value(t,loco_state(&f).mode,MODE_SLIDING)
    testing.expectf(t,flat_speed(&f)>=SLIDE_DEFAULT.min_speed-0.05,"slides at least at min_speed: %v",flat_speed(&f))
    loco_test_tick(&f,{0,0,-1},80)
    testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)
    testing.expect(t,!loco_state(&f).crouch_on,"moving at the end of the slide stands up")
}

// With sprint_default it sprints forward without the sprint action, so a crouch while running slides.
@(test)
sprint_by_default_runs_at_sprint_speed_and_a_crouch_slides :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,40}) {return}
    defer loco_test_destroy(&f)
    core.add(&f.slides,f.e,SLIDE_DEFAULT)
    loco_test_tick(&f,{},20)
    walk:=core.edit(&f.walks,f.e)
    walk.sprint_speed,walk.sprint_default,walk.crouch_toggle=5.5,true,true
    loco_test_tick(&f,{0,0,-1},60)
    v:=loco_velocity(&f)
    testing.expectf(t,abs(-v.z-5.5)<0.1,"it runs at sprint_speed without the action: %v",v)
    loco_test_tick(&f,{0,0,-1},1,CROUCH)
    loco_test_tick(&f,{0,0,-1},2)
    testing.expectf(t,loco_state(&f).mode==MODE_SLIDING,"a crouch while running slides: mode %v",loco_state(&f).mode)
}
