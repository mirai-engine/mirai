package physics

import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import input "mirai:engine/input"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

// A character of the solver that crouches, slides and mantles as locomotion_step and the step
// drive one of the world: the mantle is looked for before the locomotion takes the jump, and the
// capsule is made as tall as the locomotion asks before every step.
@(private="file")
Moves_Test :: struct {
    w:sim.World,
    ch:sim.Character_Handle,
    loco:Locomotion_State,
    body:Character,
    walk:Walk,
    slide:Maybe(Slide),
    mantle:Maybe(Mantle),
    tactical:Maybe(Tactical_Sprint),
    ledge:Maybe(Ledge_Jump),
    asked:f32,
}

@(private="file")
moves_init :: proc(f:^Moves_Test,position:[3]f32,ground:=true) -> bool {
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.character_capacity=16,16,256,2
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=1,1,1,64
    if !sim.world_init(&f.w,desc) {return false}
    if ground {moves_box(f,{50,1,50},{0,-1,0})}
    f.body,f.walk,f.asked=character_default(),WALK_DEFAULT,sim.CHARACTER_DESC_DEFAULT.height
    f.ch=sim.character_create(&f.w,sim.CHARACTER_DESC_DEFAULT,position)
    return f.ch!={}
}

@(private="file")
moves_box :: proc(f:^Moves_Test,half,position:[3]f32,rotation:=mm.QUAT_IDENTITY) {
    desc:=sim.BODY_DESC_DEFAULT
    desc.type,desc.position,desc.rotation=.Static,position,rotation
    body:=sim.body_create(&f.w,desc)
    shape:=sim.SHAPE_DESC_DEFAULT
    shape.geometry=sim.Box{half}
    sim.shape_create(&f.w,body,shape)
}

@(private="file")
moves_tick :: proc(f:^Moves_Test,move:[3]f32,ticks:=1,buttons:=input.Action_Mask(0),yaw:f32=0) {
    dt:=f32(1.0/60)
    for _ in 0..<ticks {
        found:=character_state_of(sim.character_state(&f.w,f.ch))
        found.height=sim.character_desc(&f.w,f.ch).height
        found.cramped=found.height<f.asked-HEIGHT_EPSILON
        given:=input.Move_Input{move=move,look_yaw=yaw,buttons=buttons}
        f.loco.ledge_ready=false
        if ledge,has:=f.ledge.?;has {ledge_ready_update(&f.loco,ledge,found,sim.character_velocity(&f.w,f.ch),&f.w,f.ch)}
        if mantle,has:=f.mantle.?;has && (f.loco.mode==MODE_WALKING || f.loco.mode==MODE_FALLING || f.loco.mode==MODE_CROUCHING) {
            if wanted,from_ground:=mantle_wanted(&f.loco,mantle,found,given,TEST_JUMP);wanted {
                facing:=mm.quat_forward(mm.quat_axis_angle({0,1,0},yaw))
                if to,height,ok:=ledge_find(&f.w,f.ch,facing,mantle,from_ground);ok {mantle_start(&f.loco,sim.character_position(&f.w,f.ch),to,height)}
            }
        }
        m:sim.Character_Move
        if f.loco.mode==MODE_MANTLING {
            m=mantle_move(&f.loco,f.body,f.mantle.?,1,sim.character_position(&f.w,f.ch),given,TEST_JUMP,dt,overriding(&f.loco))
            spent:=m
            layers_apply(&f.loco,&m if f.loco.mode==MODE_MANTLING else &spent,f.body.traction_force)
        } else {
            m=locomotion_move(&f.loco,f.body,f.walk,{},nil,{slide=f.slide,tactical=f.tactical,ledge=f.ledge},found,1,given,TEST_JUMP,TEST_SPRINT,TEST_CROUCH,sim.character_velocity(&f.w,f.ch),f.w.gravity,dt)
        }
        f.asked=f.loco.crouched?f.walk.crouch_height:sim.CHARACTER_DESC_DEFAULT.height
        if abs(sim.character_desc(&f.w,f.ch).height-f.asked)>HEIGHT_EPSILON {_=sim.character_set_height(&f.w,f.ch,f.asked)}
        sim.character_set_move(&f.w,f.ch,m)
        sim.world_step(&f.w,dt)
    }
}

@(private="file")
flat_speed :: proc(f:^Moves_Test) -> f32 {
    v:=sim.character_velocity(&f.w,f.ch)
    return linalg.length(v.xz)
}

@(private="file") CROUCH :: input.Action_Mask(1)<<u64(TEST_CROUCH)
@(private="file") JUMP :: input.Action_Mask(1)<<u64(TEST_JUMP)

// Crouch held makes the capsule crouch_height tall and walks at crouch_speed; let go under a roof
// lower than standing it stays crouched (cramped) and stands up past the roof.
@(test)
crouching_walks_short_and_slow_and_stands_up_where_there_is_room :: proc(t:^testing.T) {
    f:Moves_Test
    testing.expect(t,moves_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    moves_box(&f,{2,0.1,1.5},{0,1.5,-3.5}) // a roof from 1.4 to 1.6 m over z -5..-2
    moves_tick(&f,{},30)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    moves_tick(&f,{0,0,-1},90,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_CROUCHING)
    testing.expectf(t,abs(sim.character_desc(&f.w,f.ch).height-f.walk.crouch_height)<1e-4,"height %v",sim.character_desc(&f.w,f.ch).height)
    testing.expectf(t,abs(flat_speed(&f)-f.walk.crouch_speed)<0.05,"crouched speed %v",flat_speed(&f))
    z:=sim.character_position(&f.w,f.ch).z
    testing.expectf(t,z<-2.5 && z>-4.5,"under the roof at z %v",z)
    moves_tick(&f,{0,0,-1},10)
    state:=character_state_of(sim.character_state(&f.w,f.ch))
    testing.expect_value(t,f.loco.mode,MODE_CROUCHING)
    testing.expect(t,abs(sim.character_desc(&f.w,f.ch).height-f.walk.crouch_height)<1e-4,"the roof keeps it crouched")
    testing.expect(t,state.standing)
    moves_tick(&f,{0,0,-1},60)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    testing.expectf(t,abs(sim.character_desc(&f.w,f.ch).height-sim.CHARACTER_DESC_DEFAULT.height)<1e-4,"past the roof it stands: %v",sim.character_desc(&f.w,f.ch).height)
}

// Crouch at a run slides on at the speed it ran (friction 0) crouched for time, then stands up when it
// moves, even with crouch held, which crouches again only once let go; without a move it ends crouched.
// Crouch from a walk slower than start_speed crouches; a slide starts again only after cooldown.
@(test)
a_slide_keeps_the_run_for_its_time_and_ends_standing_or_crouched :: proc(t:^testing.T) {
    f:Moves_Test
    testing.expect(t,moves_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    f.slide=SLIDE_DEFAULT
    moves_tick(&f,{},20)
    moves_tick(&f,{0,0,-1},40)
    testing.expectf(t,abs(flat_speed(&f)-5)<0.05,"running %v",flat_speed(&f))
    moves_tick(&f,{0,0,-1},1,CROUCH)
    moves_tick(&f,{0,0,-1},1,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_SLIDING)
    moves_tick(&f,{1,0,-1},60,CROUCH) // steering right turns the course at most steer_angle
    testing.expect_value(t,f.loco.mode,MODE_SLIDING)
    testing.expectf(t,abs(flat_speed(&f)-5)<0.1,"slides at the run %v",flat_speed(&f))
    testing.expectf(t,abs(sim.character_desc(&f.w,f.ch).height-f.walk.crouch_height)<1e-4,"slides crouched %v",sim.character_desc(&f.w,f.ch).height)
    v:=sim.character_velocity(&f.w,f.ch)
    turned:=linalg.atan2(v.x,-v.z)
    testing.expectf(t,turned>0.1 && turned<=SLIDE_DEFAULT.steer_angle+0.01,"steered by %v rad",turned)
    moves_tick(&f,{0,0,-1},20,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    testing.expect(t,f.loco.crouch_lock,"crouch held after a slide that ends moving does not crouch")
    moves_tick(&f,{},30,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    moves_tick(&f,{},1)
    moves_tick(&f,{},5,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_CROUCHING)
    // Without a move at the end of a slide it stays crouched.
    moves_tick(&f,{0,0,-1},60)
    moves_tick(&f,{0,0,-1},2,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_SLIDING)
    moves_tick(&f,{},90,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_CROUCHING)
}

// Down a slope steeper than downhill_angle gravity speeds the slide up and keeps it going past its
// time; a jump leaves it in the air with its speed.
@(test)
a_slide_downhill_speeds_up_past_its_time_and_a_jump_leaves_it :: proc(t:^testing.T) {
    f:Moves_Test
    testing.expect(t,moves_init(&f,{0,0.2,0},false))
    defer sim.world_destroy(&f.w)
    moves_box(&f,{5,0.5,40},{0,-0.5,0},mm.quat_axis_angle({1,0,0},-15*mm.RAD_PER_DEG)) // down toward -Z
    f.slide=SLIDE_DEFAULT
    moves_tick(&f,{},30)
    testing.expect(t,character_state_of(sim.character_state(&f.w,f.ch)).standing)
    moves_tick(&f,{0,0,-1},40)
    moves_tick(&f,{0,0,-1},2,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_SLIDING)
    moves_tick(&f,{},120,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_SLIDING)
    speed:=linalg.length(sim.character_velocity(&f.w,f.ch))
    testing.expectf(t,speed>8,"gravity sped it up to %v m/s",speed)
    moves_tick(&f,{},1,CROUCH|JUMP)
    testing.expect_value(t,f.loco.mode,MODE_FALLING)
    testing.expect(t,f.loco.jumped)
    moves_tick(&f,{},2)
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
        f:Moves_Test
        testing.expect(t,moves_init(&f,{0,0,0}))
        defer sim.world_destroy(&f.w)
        f.mantle=MANTLE_DEFAULT
        thick:=c.thick if c.thick>0 else 1
        moves_box(&f,{2,c.top*0.5,thick*0.5},{0,c.top*0.5,-0.8-thick*0.5}) // its face at z -0.8
        if c.roof {moves_box(&f,{2,0.1,1},{0,c.top+1.2,-1.8})}
        moves_tick(&f,{},30,yaw=c.yaw)
        moves_tick(&f,{},1,JUMP,yaw=c.yaw)
        testing.expectf(t,(f.loco.mode==MODE_MANTLING)==c.mantles,"%v: mode %v",c,f.loco.mode)
        if !c.mantles {continue}
        testing.expectf(t,abs(f.loco.mantle_height-c.top)<0.01,"%v: ledge %v",c,f.loco.mantle_height)
        ticks:=0
        for f.loco.mode==MODE_MANTLING && ticks<120 {
            moves_tick(&f,{},1,yaw=c.yaw)
            ticks+=1
        }
        testing.expectf(t,ticks>=int(MANTLE_DEFAULT.time*60) && ticks<=int(MANTLE_DEFAULT.time*60)+2,"%v: climbed in %d ticks",c,ticks)
        moves_tick(&f,{},20,yaw=c.yaw)
        at:=sim.character_position(&f.w,f.ch)
        state:=character_state_of(sim.character_state(&f.w,f.ch))
        on_top:=at.z<-1.05 if c.thick==0 else at.z<-0.8 && at.z>-0.8-c.thick
        testing.expectf(t,state.standing && abs(at.y-c.top)<0.05 && on_top,"%v: stands on the top at %v",c,at)
        testing.expect_value(t,f.loco.mode,MODE_WALKING)
    }
}

// An Override layered move takes the climb off its own way (the root motion of the animation of the
// climb, warped onto the ledge): the body goes where the move takes it and the climb lasts its time.
@(test)
a_layered_move_drives_a_climb_for_its_time :: proc(t:^testing.T) {
    f:Moves_Test
    testing.expect(t,moves_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    f.mantle=MANTLE_DEFAULT
    moves_box(&f,{2,0.9,0.5},{0,0.9,-1.3})
    moves_tick(&f,{},30)
    moves_tick(&f,{},1,JUMP)
    testing.expect_value(t,f.loco.mode,MODE_MANTLING)
    ticks:=0
    for f.loco.mode==MODE_MANTLING && ticks<120 {
        f.loco.moves[0],f.loco.move_count=Layered_Move{velocity={0,4,0},ticks=1,mix=.Override},1
        moves_tick(&f,{},1)
        ticks+=1
    }
    at:=sim.character_position(&f.w,f.ch)
    testing.expectf(t,ticks>=int(MANTLE_DEFAULT.time*60) && ticks<=int(MANTLE_DEFAULT.time*60)+2,"climbed for %d ticks",ticks)
    testing.expectf(t,at.y>2 && abs(at.z)<0.1,"straight up where the move took it, not across onto the top: %v",at)
    moves_tick(&f,{},1)
    testing.expectf(t,sim.character_velocity(&f.w,f.ch).y<1,"the move of the last tick does not carry on: %v",sim.character_velocity(&f.w,f.ch))
}

// With crouch_toggle a press crouches and the next stands; a press at a sprint slides, at least at
// min_speed, and the slide ends standing when it moves. A press in the air within buffer of the
// landing slides on landing even from a run under start_speed, raised to min_speed.
@(test)
crouch_toggles_and_a_press_in_the_air_slides_on_landing :: proc(t:^testing.T) {
    f:Moves_Test
    testing.expect(t,moves_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    f.walk.crouch_toggle=true
    f.slide=SLIDE_DEFAULT
    moves_tick(&f,{},20)
    moves_tick(&f,{},1,CROUCH)
    moves_tick(&f,{},20)
    testing.expect_value(t,f.loco.mode,MODE_CROUCHING)
    moves_tick(&f,{},1,CROUCH)
    moves_tick(&f,{},20)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    // A run at 3: crouch does not slide on the ground.
    f.walk.max_speed=3
    moves_tick(&f,{0,0,-1},40)
    moves_tick(&f,{0,0,-1},1,CROUCH)
    moves_tick(&f,{0,0,-1},2)
    testing.expect_value(t,f.loco.mode,MODE_CROUCHING)
    moves_tick(&f,{0,0,-1},1,CROUCH)
    moves_tick(&f,{0,0,-1},40)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    // Jump, press crouch in the air: it slides on landing at min_speed and stands up after it.
    moves_tick(&f,{0,0,-1},1,JUMP)
    moves_tick(&f,{0,0,-1},10)
    moves_tick(&f,{0,0,-1},1,CROUCH)
    landed:=false
    for _ in 0..<90 {
        moves_tick(&f,{0,0,-1})
        if f.loco.mode==MODE_SLIDING {landed=true;break}
    }
    testing.expect(t,landed,"the press in the air slides on landing")
    moves_tick(&f,{0,0,-1},10)
    testing.expect_value(t,f.loco.mode,MODE_SLIDING)
    testing.expectf(t,flat_speed(&f)>=SLIDE_DEFAULT.min_speed-0.05,"slides at least at min_speed: %v",flat_speed(&f))
    moves_tick(&f,{0,0,-1},80)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    testing.expect(t,!f.loco.crouch_on,"moving at the end of the slide stands up")
}

@(private="file") SPRINT :: input.Action_Mask(1)<<u64(TEST_SPRINT)

// Sprint held forward starts a tactical sprint: its top speed ramps to speed_multiplier times
// sprint_speed and it spends cost_per_second. With sprint held, a move off forward for less than
// grace goes on at the same ramp; letting go of sprint ends it at once. Without energy it sprints plainly and does not start again until energy comes back,
// recharge_delay after it was last spent, at recharge per second.
@(test)
a_tactical_sprint_ramps_up_spends_its_energy_and_recharges_after_its_delay :: proc(t:^testing.T) {
    f:Moves_Test
    testing.expect(t,moves_init(&f,{0,0,40}))
    defer sim.world_destroy(&f.w)
    f.walk.sprint_speed=5.5
    tactical:=TACTICAL_SPRINT_DEFAULT
    f.tactical=tactical
    top:=f.walk.sprint_speed*tactical.speed_multiplier
    // Exponential over its ramp: halfway through, the square root of the multiplier.
    halfway:=Locomotion_State{sprint_active=true,sprint_time=tactical.speed_ramp/2}
    boost,_:=tactical_boost(halfway,tactical)
    testing.expectf(t,abs(boost-cmath.sqrt(tactical.speed_multiplier))<1e-4,"halfway through its ramp: %v",boost)
    moves_tick(&f,{},20)
    moves_tick(&f,{0,0,-1},6,SPRINT)
    testing.expect(t,f.loco.sprint_active,"sprint held forward with energy starts it")
    testing.expectf(t,flat_speed(&f)<0.85*top,"it ramps up: %v after 0.1 s",flat_speed(&f))
    moves_tick(&f,{0,0,-1},54,SPRINT)
    testing.expectf(t,abs(flat_speed(&f)-top)<0.1,"at speed_multiplier after its ramp: %v",flat_speed(&f))
    testing.expectf(t,abs(f.loco.sprint_spent-tactical.cost_per_second)<0.5,"a second spends cost_per_second: %v",f.loco.sprint_spent)
    moves_tick(&f,{1,0,0},15,SPRINT)
    testing.expect(t,f.loco.sprint_active,"off forward for less than grace it goes on")
    ramp:=f.loco.sprint_time
    moves_tick(&f,{0,0,-1},40,SPRINT)
    testing.expectf(t,f.loco.sprint_time>ramp && abs(flat_speed(&f)-top)<0.1,"its ramp kept, back at top speed: %v",flat_speed(&f))
    moves_tick(&f,{1,0,0},31,SPRINT)
    testing.expect(t,!f.loco.sprint_active,"off forward past grace it ends")
    moves_tick(&f,{0,0,-1},10,SPRINT)
    testing.expect(t,f.loco.sprint_active)
    moves_tick(&f,{0,0,-1},1)
    testing.expect(t,!f.loco.sprint_active,"letting go of sprint ends it at once")
    // Out of energy it sprints as its Walk says, and energy waits recharge_delay.
    moves_tick(&f,{0,0,-1},1,SPRINT)
    testing.expect(t,f.loco.sprint_active)
    f.loco.sprint_spent=tactical.energy-1
    moves_tick(&f,{0,0,-1},60,SPRINT)
    testing.expect(t,!f.loco.sprint_active,"without energy it ends")
    testing.expectf(t,abs(flat_speed(&f)-f.walk.sprint_speed)<0.1,"and sprints plainly: %v",flat_speed(&f))
    moves_tick(&f,{},int((tactical.recharge_delay-f.loco.sprint_rest)*60)-2)
    testing.expectf(t,f.loco.sprint_spent==tactical.energy,"no recharge before its delay: %v",f.loco.sprint_spent)
    moves_tick(&f,{},62)
    testing.expectf(t,abs(tactical_energy(f.loco,tactical)-tactical.recharge)<1.5,"a second after its delay it recharged recharge: %v",tactical_energy(f.loco,tactical))
}

// A jump in a tactical sprint at the end of its ramp rises jump_multiplier times faster and costs
// cost_jump; in the air it spends nothing, and going down there past fall_grace it ends.
@(test)
a_jump_in_a_tactical_sprint_goes_higher_costs_energy_and_a_long_fall_ends_it :: proc(t:^testing.T) {
    f:Moves_Test
    testing.expect(t,moves_init(&f,{0,0,40}))
    defer sim.world_destroy(&f.w)
    f.walk.sprint_speed=5.5
    tactical:=TACTICAL_SPRINT_DEFAULT
    f.tactical=tactical
    moves_tick(&f,{},20)
    moves_tick(&f,{0,0,-1},60,SPRINT)
    spent:=f.loco.sprint_spent
    moves_tick(&f,{0,0,-1},1,SPRINT|JUMP)
    testing.expectf(t,abs(f.loco.sprint_spent-spent-tactical.cost_jump)<0.5,"the jump costs cost_jump: %v",f.loco.sprint_spent-spent)
    spent=f.loco.sprint_spent
    rise:=f32(0)
    // It rises for 0.59 s and comes down for as long: past fall_grace of that, still in the air, it ends.
    for i in 0..<69 {
        moves_tick(&f,{0,0,-1},1,SPRINT)
        rise=max(rise,sim.character_position(&f.w,f.ch).y)
        if i==50 {testing.expect(t,f.loco.sprint_active,"going up and then down within fall_grace it goes on")}
    }
    testing.expect(t,f.loco.mode==MODE_FALLING,"still in the air")
    want:=f.walk.jump_height*tactical.jump_multiplier*tactical.jump_multiplier
    testing.expectf(t,abs(rise-want)<0.05,"it rises %v, jump_multiplier times faster than to %v",rise,f.walk.jump_height)
    testing.expect(t,!f.loco.sprint_active,"past fall_grace in the air it ends")
    testing.expectf(t,f.loco.sprint_spent==spent,"nothing spent in the air: %v",f.loco.sprint_spent-spent)
}

// Standing at min_speed for min_time with the ground falling away more than min_drop within reach
// ahead, it is ready, and a jump adds added_speed along where it goes (at most max_speed) and up_speed
// up; it lasts until it lands. Slower, or over a lower drop, it is never ready and a jump is a jump.
@(test)
a_ledge_jump_launches_off_an_edge_at_speed_and_ends_when_it_lands :: proc(t:^testing.T) {
    Case :: struct {sprint:bool,drop:f32,ready:bool}
    cases:=[]Case{{sprint=true,drop=3,ready=true},{sprint=false,drop=3},{sprint=true,drop=1}}
    for c in cases {
        f:Moves_Test
        testing.expect(t,moves_init(&f,{0,0,10},false))
        defer sim.world_destroy(&f.w)
        moves_box(&f,{5,0.5,15},{0,-0.5,0})              // its top at 0, its edge at z -15
        moves_box(&f,{20,0.5,40},{0,-c.drop-0.5,-30})   // the ground under it
        f.walk.sprint_speed=7
        ledge:=LEDGE_JUMP_DEFAULT
        f.ledge=ledge
        buttons:=SPRINT if c.sprint else 0
        moves_tick(&f,{},20)
        ready_at:=f32(0)
        for _ in 0..<300 {
            moves_tick(&f,{0,0,-1},1,buttons)
            z:=sim.character_position(&f.w,f.ch).z
            if z>-10 {testing.expectf(t,!f.loco.ledge_ready,"%v: not ready far from the edge, at z %v",c,z)}
            if f.loco.ledge_ready || z<-14.8 {
                ready_at=z
                break
            }
        }
        testing.expectf(t,f.loco.ledge_ready==c.ready,"%v: ready %v at z %v",c,f.loco.ledge_ready,ready_at)
        if c.ready {testing.expectf(t,ready_at< -15+ledge.reach+0.05 && ready_at> -15+ledge.reach-0.25,"%v: ready reach before the edge, at z %v",c,ready_at)}
        before:=flat_speed(&f)
        moves_tick(&f,{0,0,-1},1,buttons|JUMP)
        moves_tick(&f,{0,0,-1},1,buttons)
        v:=sim.character_velocity(&f.w,f.ch)
        testing.expect_value(t,f.loco.ledge_jumping,c.ready)
        rise:=f32(4.852)+(ledge.up_speed if c.ready else 0) // sqrt(2 g jump_height) of WALK_DEFAULT
        testing.expectf(t,abs(v.y-rise)<0.4,"%v: it goes up at %v",c,v.y)
        if c.ready {
            testing.expectf(t,abs(flat_speed(&f)-min(before+ledge.added_speed,ledge.max_speed))<0.1,"%v: launched at %v from %v",c,flat_speed(&f),before)
            moves_tick(&f,{0,0,-1},20,buttons)
            testing.expectf(t,flat_speed(&f)>ledge.max_speed-0.1,"%v: air control steers it without slowing it: %v",c,flat_speed(&f))
        } else {
            testing.expectf(t,abs(flat_speed(&f)-before)<0.2,"%v: a plain jump keeps its speed %v: %v",c,before,flat_speed(&f))
        }
        landed:=false
        for _ in 0..<240 {
            moves_tick(&f,{},1)
            if character_state_of(sim.character_state(&f.w,f.ch)).standing {landed=true;break}
        }
        testing.expectf(t,landed,"%v: it lands",c)
        moves_tick(&f,{},1)
        testing.expectf(t,!f.loco.ledge_jumping,"%v: the landing ends it",c)
    }
}

// A jump let go at once rises jump_height; held, it keeps the speed it started with for jump_rise and
// rises that speed by jump_rise more; held longer, no more than that.
@(test)
a_jump_held_rises_at_its_speed_for_jump_rise :: proc(t:^testing.T) {
    peak :: proc(t:^testing.T,held_ticks:int,rise:f32) -> f32 {
        f:Moves_Test
        testing.expect(t,moves_init(&f,{0,0,0}))
        defer sim.world_destroy(&f.w)
        f.walk.jump_rise=rise
        moves_tick(&f,{},20)
        start:=sim.character_position(&f.w,f.ch).y
        top:=start
        for i in 0..<90 {
            moves_tick(&f,{},1,JUMP if i<held_ticks else input.Action_Mask(0))
            top=max(top,sim.character_position(&f.w,f.ch).y)
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
    f:Moves_Test
    testing.expect(t,moves_init(&f,{0,0,40}))
    defer sim.world_destroy(&f.w)
    f.walk.sprint_speed,f.walk.sprint_default,f.walk.crouch_toggle=5.5,true,true
    f.slide=SLIDE_DEFAULT
    f.tactical=TACTICAL_SPRINT_DEFAULT
    moves_tick(&f,{},20)
    moves_tick(&f,{0,0,-1},60)
    v:=sim.character_velocity(&f.w,f.ch)
    testing.expectf(t,abs(-v.z-5.5)<0.1,"it runs at sprint_speed without the action: %v",v)
    testing.expect(t,!f.loco.sprint_active,"no tactical sprint without the action")
    moves_tick(&f,{0,0,-1},1,CROUCH)
    moves_tick(&f,{0,0,-1},2)
    testing.expectf(t,f.loco.mode==MODE_SLIDING,"a crouch while running slides: mode %v",f.loco.mode)
    moves_tick(&f,{0,0,-1},120)
    moves_tick(&f,{0,0,-1},30,SPRINT)
    testing.expect(t,f.loco.sprint_active,"the sprint action asks for the tactical sprint")
}
