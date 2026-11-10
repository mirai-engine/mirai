package locomotion

import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import mm "mirai:std/math"

@(private="file")
flat_speed :: proc(f:^Loco_Test) -> f32 {
    v:=loco_velocity(f)
    return linalg.length(v.xz)
}

@(private="file")
height_of :: proc(f:^Loco_Test) -> f32 {return loco_found(f).height}

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
        testing.expectf(t,abs(loco_state(&f).mantle_height-c.top)<0.01,"%v: ledge %v",c,loco_state(&f).mantle_height)
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

// Sprint held forward starts a tactical sprint: its top speed ramps to speed_multiplier times
// sprint_speed and it spends cost_per_second. With sprint held, a move off forward for less than
// grace goes on at the same ramp; letting go of sprint ends it at once. Without energy it sprints
// plainly and does not start again until energy comes back, recharge_delay after it was last spent,
// at recharge per second.
@(test)
a_tactical_sprint_ramps_up_spends_its_energy_and_recharges_after_its_delay :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,40}) {return}
    defer loco_test_destroy(&f)
    tactical:=TACTICAL_SPRINT_DEFAULT
    core.add(&f.tacticals,f.e,tactical)
    sprint_speed:=f32(5.5)
    top:=sprint_speed*tactical.speed_multiplier
    // Exponential over its ramp: halfway through, the square root of the multiplier.
    halfway:=Locomotion_State{sprint_active=true,sprint_time=tactical.speed_ramp/2}
    boost,_:=tactical_boost(halfway,tactical)
    testing.expectf(t,abs(boost-cmath.sqrt(tactical.speed_multiplier))<1e-4,"halfway through its ramp: %v",boost)
    loco_test_tick(&f,{},20)
    core.edit(&f.walks,f.e).sprint_speed=sprint_speed
    loco_test_tick(&f,{0,0,-1},6,SPRINT)
    testing.expect(t,loco_state(&f).sprint_active,"sprint held forward with energy starts it")
    testing.expectf(t,flat_speed(&f)<0.85*top,"it ramps up: %v after 0.1 s",flat_speed(&f))
    loco_test_tick(&f,{0,0,-1},54,SPRINT)
    testing.expectf(t,abs(flat_speed(&f)-top)<0.1,"at speed_multiplier after its ramp: %v",flat_speed(&f))
    testing.expectf(t,abs(loco_state(&f).sprint_spent-tactical.cost_per_second)<0.5,"a second spends cost_per_second: %v",loco_state(&f).sprint_spent)
    loco_test_tick(&f,{1,0,0},15,SPRINT)
    testing.expect(t,loco_state(&f).sprint_active,"off forward for less than grace it goes on")
    ramp:=loco_state(&f).sprint_time
    loco_test_tick(&f,{0,0,-1},40,SPRINT)
    testing.expectf(t,loco_state(&f).sprint_time>ramp && abs(flat_speed(&f)-top)<0.1,"its ramp kept, back at top speed: %v",flat_speed(&f))
    loco_test_tick(&f,{1,0,0},31,SPRINT)
    testing.expect(t,!loco_state(&f).sprint_active,"off forward past grace it ends")
    loco_test_tick(&f,{0,0,-1},10,SPRINT)
    testing.expect(t,loco_state(&f).sprint_active)
    loco_test_tick(&f,{0,0,-1},1)
    testing.expect(t,!loco_state(&f).sprint_active,"letting go of sprint ends it at once")
    // Out of energy it sprints as its Walk says, and energy waits recharge_delay.
    loco_test_tick(&f,{0,0,-1},1,SPRINT)
    testing.expect(t,loco_state(&f).sprint_active)
    core.edit(&f.loco_states,f.e).sprint_spent=tactical.energy-1
    loco_test_tick(&f,{0,0,-1},60,SPRINT)
    testing.expect(t,!loco_state(&f).sprint_active,"without energy it ends")
    testing.expectf(t,abs(flat_speed(&f)-sprint_speed)<0.1,"and sprints plainly: %v",flat_speed(&f))
    loco_test_tick(&f,{},int((tactical.recharge_delay-loco_state(&f).sprint_rest)*60)-2)
    testing.expectf(t,loco_state(&f).sprint_spent==tactical.energy,"no recharge before its delay: %v",loco_state(&f).sprint_spent)
    loco_test_tick(&f,{},62)
    testing.expectf(t,abs(tactical_energy(loco_state(&f),tactical)-tactical.recharge)<1.5,"a second after its delay it recharged recharge: %v",tactical_energy(loco_state(&f),tactical))
}

// A jump in a tactical sprint at the end of its ramp rises jump_multiplier times faster and costs
// cost_jump; in the air it spends nothing, and going down there past fall_grace it ends.
@(test)
a_jump_in_a_tactical_sprint_goes_higher_costs_energy_and_a_long_fall_ends_it :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,40}) {return}
    defer loco_test_destroy(&f)
    tactical:=TACTICAL_SPRINT_DEFAULT
    core.add(&f.tacticals,f.e,tactical)
    loco_test_tick(&f,{},20)
    core.edit(&f.walks,f.e).sprint_speed=5.5
    loco_test_tick(&f,{0,0,-1},60,SPRINT)
    spent:=loco_state(&f).sprint_spent
    loco_test_tick(&f,{0,0,-1},1,SPRINT|JUMP)
    testing.expectf(t,abs(loco_state(&f).sprint_spent-spent-tactical.cost_jump)<0.5,"the jump costs cost_jump: %v",loco_state(&f).sprint_spent-spent)
    spent=loco_state(&f).sprint_spent
    rise:=f32(0)
    // It rises for 0.59 s and comes down for as long: past fall_grace of that, still in the air, it ends.
    for i in 0..<69 {
        loco_test_tick(&f,{0,0,-1},1,SPRINT)
        rise=max(rise,loco_position(&f).y)
        if i==50 {testing.expect(t,loco_state(&f).sprint_active,"going up and then down within fall_grace it goes on")}
    }
    testing.expect(t,loco_state(&f).mode==MODE_FALLING,"still in the air")
    want:=WALK_DEFAULT.jump_height*tactical.jump_multiplier*tactical.jump_multiplier
    testing.expectf(t,abs(rise-want)<0.05,"it rises %v, jump_multiplier times faster than to %v",rise,WALK_DEFAULT.jump_height)
    testing.expect(t,!loco_state(&f).sprint_active,"past fall_grace in the air it ends")
    testing.expectf(t,loco_state(&f).sprint_spent==spent,"nothing spent in the air: %v",loco_state(&f).sprint_spent-spent)
}

// Standing at min_speed for min_time with the ground falling away more than min_drop within reach
// ahead, it is ready, and a jump adds added_speed along where it goes (at most max_speed) and up_speed
// up; it lasts until it lands. Slower, or over a lower drop, it is never ready and a jump is a jump.
@(test)
a_ledge_jump_launches_off_an_edge_at_speed_and_ends_when_it_lands :: proc(t:^testing.T) {
    Case :: struct {sprint:bool,drop:f32,ready:bool}
    cases:=[]Case{{sprint=true,drop=3,ready=true},{sprint=false,drop=3},{sprint=true,drop=1}}
    for c in cases {
        f:Loco_Test
        if !loco_test_init(t,&f,{0,0,10},false) {return}
        defer loco_test_destroy(&f)
        loco_test_box(&f,{5,0.5,15},{0,-0.5,0})              // its top at 0, its edge at z -15
        loco_test_box(&f,{20,0.5,40},{0,-c.drop-0.5,-30})   // the ground under it
        ledge:=LEDGE_JUMP_DEFAULT
        core.add(&f.ledges,f.e,ledge)
        buttons:=SPRINT if c.sprint else 0
        loco_test_tick(&f,{},20)
        core.edit(&f.walks,f.e).sprint_speed=7
        ready_at:=f32(0)
        for _ in 0..<300 {
            loco_test_tick(&f,{0,0,-1},1,buttons)
            z:=loco_position(&f).z
            if z>-10 {testing.expectf(t,!loco_state(&f).ledge_ready,"%v: not ready far from the edge, at z %v",c,z)}
            if loco_state(&f).ledge_ready || z<-14.8 {
                ready_at=z
                break
            }
        }
        testing.expectf(t,loco_state(&f).ledge_ready==c.ready,"%v: ready %v at z %v",c,loco_state(&f).ledge_ready,ready_at)
        if c.ready {testing.expectf(t,ready_at< -15+ledge.reach+0.05 && ready_at> -15+ledge.reach-0.25,"%v: ready reach before the edge, at z %v",c,ready_at)}
        before:=flat_speed(&f)
        loco_test_tick(&f,{0,0,-1},1,buttons|JUMP)
        loco_test_tick(&f,{0,0,-1},1,buttons)
        v:=loco_velocity(&f)
        testing.expect_value(t,loco_state(&f).ledge_jumping,c.ready)
        rise:=f32(4.852)+(ledge.up_speed if c.ready else 0) // sqrt(2 g jump_height) of WALK_DEFAULT
        testing.expectf(t,abs(v.y-rise)<0.4,"%v: it goes up at %v",c,v.y)
        if c.ready {
            testing.expectf(t,abs(flat_speed(&f)-min(before+ledge.added_speed,ledge.max_speed))<0.1,"%v: launched at %v from %v",c,flat_speed(&f),before)
            loco_test_tick(&f,{0,0,-1},20,buttons)
            testing.expectf(t,flat_speed(&f)>ledge.max_speed-0.1,"%v: air control steers it without slowing it: %v",c,flat_speed(&f))
        } else {
            testing.expectf(t,abs(flat_speed(&f)-before)<0.2,"%v: a plain jump keeps its speed %v: %v",c,before,flat_speed(&f))
        }
        landed:=false
        for _ in 0..<240 {
            loco_test_tick(&f,{},1)
            if loco_found(&f).standing {landed=true;break}
        }
        testing.expectf(t,landed,"%v: it lands",c)
        loco_test_tick(&f,{},1)
        testing.expectf(t,!loco_state(&f).ledge_jumping,"%v: the landing ends it",c)
    }
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

// With sprint_default it sprints forward without the sprint action, so a crouch while running slides;
// the action then asks for the tactical sprint.
@(test)
sprint_by_default_runs_at_sprint_speed_and_a_crouch_slides :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,40}) {return}
    defer loco_test_destroy(&f)
    core.add(&f.slides,f.e,SLIDE_DEFAULT)
    core.add(&f.tacticals,f.e,TACTICAL_SPRINT_DEFAULT)
    loco_test_tick(&f,{},20)
    walk:=core.edit(&f.walks,f.e)
    walk.sprint_speed,walk.sprint_default,walk.crouch_toggle=5.5,true,true
    loco_test_tick(&f,{0,0,-1},60)
    v:=loco_velocity(&f)
    testing.expectf(t,abs(-v.z-5.5)<0.1,"it runs at sprint_speed without the action: %v",v)
    testing.expect(t,!loco_state(&f).sprint_active,"no tactical sprint without the action")
    loco_test_tick(&f,{0,0,-1},1,CROUCH)
    loco_test_tick(&f,{0,0,-1},2)
    testing.expectf(t,loco_state(&f).mode==MODE_SLIDING,"a crouch while running slides: mode %v",loco_state(&f).mode)
    loco_test_tick(&f,{0,0,-1},120)
    loco_test_tick(&f,{0,0,-1},30,SPRINT)
    testing.expect(t,loco_state(&f).sprint_active,"the sprint action asks for the tactical sprint")
}
