package locomotion

import cmath "core:math"
import "core:reflect"
import "core:strings"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import volume "mirai:engine/volume"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

@(test)
walking_reaches_the_speed_of_the_locomotion_and_brakes :: proc(t:^testing.T) {
    // The acceleration of the walk decides how fast it gets there, past what the traction force of
    // the 80 kg body (3200 N, 40 m/s2) would drive: 5 m/s at 90 m/s2 takes 1/18 s, under 4 ticks.
    for acceleration in ([2]f32{30,90}) {
        f:Loco_Test
        if !loco_test_init(t,&f,{0,0,0}) {return}
        defer loco_test_destroy(&f)
        loco_test_tick(&f,{},30)
        core.edit(&f.walks,f.e).acceleration=acceleration
        ticks:=int(cmath.ceil(5/(acceleration/60)-1e-3))
        loco_test_tick(&f,{0,0,-1},ticks-1)
        testing.expectf(t,-loco_velocity(&f).z<4.95,"at %v m/s2 it is short of 5 m/s a tick early: %v",acceleration,loco_velocity(&f))
        loco_test_tick(&f,{0,0,-1},1)
        testing.expectf(t,near(-loco_velocity(&f).z,5,0.05),"at %v m/s2 it walks at 5 m/s in %d ticks: %v",acceleration,ticks,loco_velocity(&f))
    }
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,0}) {return}
    defer loco_test_destroy(&f)
    loco_test_tick(&f,{},30)
    testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)
    loco_test_tick(&f,{0,0,-1},10)
    // 30 m/s2 for 10 ticks; the first tick decides on the ground the step before it found.
    v:=loco_velocity(&f)
    testing.expectf(t,near(v.z,-5,0.1),"velocity %v",v)
    loco_test_tick(&f,{0,0,-1},50)
    v=loco_velocity(&f)
    testing.expectf(t,near(v.z,-5,0.02) && abs(v.x)<0.01 && abs(v.y)<0.01,"velocity %v",v)
    // The look yaw turns the move: a quarter turn to the left makes forward point to -X.
    loco_test_tick(&f,{0,0,-1},40,yaw=0.5*cmath.PI)
    v=loco_velocity(&f)
    testing.expectf(t,near(v.x,-5,0.02) && abs(v.z)<0.02,"turned velocity %v",v)
    loco_test_tick(&f,{},20)
    testing.expect(t,abs(loco_velocity(&f).x)<0.01)
}

// Holding sprint walks forward at sprint_speed, not sideways or back; moving back loses
// backward_slowdown of the speed; a sprint slower than max_speed, a zero slowdown or a sideways
// move change nothing.
@(test)
walking_sprints_and_slows_backward :: proc(t:^testing.T) {
    Case :: struct {sprint_speed,slowdown:f32,move:[3]f32,sprinting:bool,speed:f32}
    cases:=[]Case{
        {sprint_speed=8,move={0,0,-1},sprinting=true,speed=8},
        {sprint_speed=8,move={0,0,-1},speed=5},
        {sprint_speed=3,move={0,0,-1},sprinting=true,speed=5},
        {sprint_speed=8,move={1,0,-1},sprinting=true,speed=8},
        {sprint_speed=8,move={1,0,0},sprinting=true,speed=5},
        {sprint_speed=8,slowdown=0.2,move={0,0,1},sprinting=true,speed=4},
        {slowdown=0.2,move={0,0,1},speed=4},
        {slowdown=0.2,move={1,0,0},speed=5},
        {slowdown=0.2,move={0,0,0.5},speed=4},
        {slowdown=2,move={0,0,1},speed=0},
        {slowdown=cmath.nan_f32(),move={0,0,1},speed=5},
    }
    for c in cases {
        walk:=WALK_DEFAULT
        walk.sprint_speed,walk.backward_slowdown=c.sprint_speed,c.slowdown
        got:=walk_speed(walk,{move=c.move},c.sprinting)
        testing.expectf(t,near(got,c.speed,1e-5),"%v gives %v",c,got)
    }
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,0}) {return}
    defer loco_test_destroy(&f)
    loco_test_tick(&f,{},30)
    core.edit(&f.walks,f.e).sprint_speed=8
    loco_test_tick(&f,{0,0,-1},90,SPRINT)
    v:=loco_velocity(&f)
    testing.expectf(t,near(v.z,-8,0.05),"sprint velocity %v",v)
    loco_test_tick(&f,{0,0,-1},60)
    v=loco_velocity(&f)
    testing.expectf(t,near(v.z,-5,0.05),"after letting sprint go %v",v)
}

// A move asks for a share of the top speed of a mode, up to all of it; a velocity, for that speed up
// to the top one. What is not a number asks for nothing.
@(test)
a_move_asks_a_share_of_the_top_speed_or_a_velocity_up_to_it :: proc(t:^testing.T) {
    nan,inf:=cmath.nan_f32(),cmath.inf_f32(1)
    Case :: struct {move:[3]f32,velocity:bool,top:f32,share:[3]f32}
    cases:=[]Case{
        {move={0.5,0,0},top=4,share={0.5,0,0}},
        {move={3,0,4},top=4,share={0.6,0,0.8}},
        {move={2,0,0},velocity=true,top=4,share={0.5,0,0}},
        {move={0,0,-8},velocity=true,top=4,share={0,0,-1}},
        {move={2,0,0},velocity=true,top=0,share={}},
        {move={2,0,0},velocity=true,top=nan,share={}},
        {move={2,0,0},velocity=true,top=inf,share={}},
        {move={nan,0,0},top=4,share={}},
        {move={inf,0,0},velocity=true,top=4,share={}},
    }
    for c in cases {
        got:=move_share({move=c.move,velocity=c.velocity},c.top)
        testing.expectf(t,abs(got.x-c.share.x)<1e-5 && abs(got.y-c.share.y)<1e-5 && abs(got.z-c.share.z)<1e-5,"%v gives %v",c,got)
    }
}

// The body faces where the look does: -Z.
@(test)
walking_toward_plus_x_turns_the_front_of_the_body_to_plus_x_and_keeps_the_look :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,0}) {return}
    defer loco_test_destroy(&f)
    look:=f32(-0.5*cmath.PI)
    loco_test_tick(&f,{0,0,-1},60,yaw=look)
    v:=loco_velocity(&f)
    testing.expectf(t,near(v.x,5,0.05) && abs(v.z)<0.05,"velocity %v",v)
    pose,_:=core.get(&f.transforms,f.e)
    front:=mm.quat_forward(pose.rotation)
    testing.expectf(t,near(front.x,1,1e-4),"the body's -Z is %v",front)
    move,_:=core.get(&f.moves,f.e)
    testing.expectf(t,near(move.value.yaw,look,1e-6),"move yaw %v",move.value.yaw)
    testing.expectf(t,near(phys.look_yaw_of(mm.QUAT_IDENTITY,pose.rotation),look,1e-4),"the look taken from the body %v",phys.look_yaw_of(mm.QUAT_IDENTITY,pose.rotation))
}

// The body turns toward the look it is asked at its turn_speed, wherever it goes meanwhile.
@(test)
the_body_turns_toward_its_look_at_its_turn_speed :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,0}) {return}
    defer loco_test_destroy(&f)
    loco_test_tick(&f,{})
    testing.expect(t,near(loco_state(&f).yaw,0,1e-6))
    core.edit(&f.characters,f.e).turn_speed=cmath.PI
    dt:=f32(1.0/60)
    core.edit(&f.inputs,f.e)^=input.Move_Input{move={1,0,0},look_yaw=-0.5*cmath.PI}
    core.test_world_settle(&f.w)
    locomotion_step(
        core.read(&f.characters),&f.loco_states,&f.moves,&f.inputs,core.read(&f.walks),core.read(&f.flights),core.read(&f.swims),core.read(&f.slides),
        core.read(&f.mantles),core.read(&f.tacticals),core.read(&f.ledges),core.read(&f.character_states),core.read(&f.bodies),core.read(&f.transforms),
        core.read(&f.parents),core.read(&f.remotes),core.ref(&f.state),core.ref(&f.places),core.read(&f.paces),{base=TEST_WALK_BASE},&f.loco_requests,{playing=true,dt=dt},core.CLOCK_DEFAULT,&f.problems,
    )
    testing.expectf(t,near(loco_state(&f).yaw,-cmath.PI*dt,1e-5),"a tick turns it pi*dt: %v",loco_state(&f).yaw)
    move,_:=core.get(&f.moves,f.e)
    testing.expectf(t,near(move.value.yaw,loco_state(&f).yaw,1e-6),"it faces that yaw: %v",move.value.yaw)
}

@(test)
a_jump_reaches_the_height_of_the_locomotion_once_per_press :: proc(t:^testing.T) {
    for height in ([2]f32{0.6,1.5}) {
        f:Loco_Test
        if !loco_test_init(t,&f,{0,0,0}) {return}
        defer loco_test_destroy(&f)
        loco_test_tick(&f,{},30)
        core.edit(&f.walks,f.e).jump_height=height
        apex:f32
        for i in 0..<120 {
            // The button stays down: only the press jumps.
            loco_test_tick(&f,{},1,JUMP)
            apex=max(apex,loco_position(&f).y)
            if i==5 {testing.expect(t,loco_state(&f).mode==MODE_FALLING && loco_state(&f).jumped)}
        }
        testing.expectf(t,near(apex,height,0.03*height),"apex %v for a jump of %v",apex,height)
        testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)
    }
    // Let go while it rises, it keeps jump_cut of its speed up; with 1 the jump goes on as it was.
    for cut in ([2]f32{1,0.5}) {
        f:Loco_Test
        if !loco_test_init(t,&f,{0,0,0}) {return}
        defer loco_test_destroy(&f)
        loco_test_tick(&f,{},30)
        core.edit(&f.walks,f.e).jump_cut=cut
        loco_test_tick(&f,{},6,JUMP)
        speed,apex:=loco_velocity(&f).y,loco_position(&f).y
        want:=apex+cut*cut*speed*speed/(2*9.81)
        for _ in 0..<120 {
            loco_test_tick(&f,{})
            apex=max(apex,loco_position(&f).y)
        }
        testing.expectf(t,near(apex,want,0.05),"with jump_cut %v it rises to %v, want %v",cut,apex,want)
    }
}

// Placed at rest (a respawn) while it falls at 20 m/s, a walker stops where it is put and its
// locomotion starts over: no fall carried on, so it lands as from a standstill.
@(test)
a_walker_placed_at_rest_stops_and_starts_its_locomotion_over :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,60,0}) {return}
    defer loco_test_destroy(&f)
    loco_test_tick(&f,{},60)
    core.push(&f.requests.queue,phys.Body_Request{entity=f.e,kind=.Velocity,linear={0,-20,0}})
    loco_test_tick(&f,{})
    testing.expectf(t,loco_velocity(&f).y< -19.5 && loco_state(&f).fall_time>0.9,"it falls at %v for %v s",loco_velocity(&f).y,loco_state(&f).fall_time)
    turned:=mm.quat_axis_angle({0,1,0},1)
    core.push(&f.places.queue,core.Place_Request{f.e,{0,0,0},turned,true})
    loco_test_tick(&f,{})
    v:=loco_velocity(&f)
    testing.expectf(t,abs(v.y)<0.2 && abs(v.x)<0.01 && abs(v.z)<0.01,"it stops where it is put: %v",v)
    state:=loco_state(&f)
    testing.expectf(t,state.fall_time==0 && state.air_time<0.02 && near(state.yaw,1,1e-4),"its locomotion starts over facing the place: %v",state)
    loco_test_tick(&f,{},10)
    testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)
}

@(test)
coyote_time_allows_a_jump_just_after_walking_off_a_ledge :: proc(t:^testing.T) {
    for wait,i in ([2]int{2,20}) {
        f:Loco_Test
        if !loco_test_init(t,&f,{0,0,-1},false) {return}
        defer loco_test_destroy(&f)
        loco_test_box(&f,{2,1,2},{0,-1,0})
        loco_test_tick(&f,{},30)
        for tick:=0;tick<300 && loco_state(&f).mode==MODE_WALKING;tick+=1 {loco_test_tick(&f,{0,0,-1})}
        testing.expect(t,loco_state(&f).coyote>0)
        loco_test_tick(&f,{0,0,-1},wait)
        loco_test_tick(&f,{0,0,-1},1,JUMP)
        loco_test_tick(&f,{0,0,-1},1)
        if i==0 {
            testing.expect(t,loco_state(&f).jumped && loco_velocity(&f).y>4)
        } else {
            testing.expect(t,!loco_state(&f).jumped && loco_velocity(&f).y< -2)
        }
    }
}

@(test)
a_dash_overrides_the_locomotion_for_its_ticks_and_a_conveyor_adds_to_it :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,0}) {return}
    defer loco_test_destroy(&f)
    loco_test_tick(&f,{},30)
    add_move(&f.loco_requests,f.e,{velocity={12,0,0},ticks=12,mix=.Override,id=7})
    loco_test_tick(&f,{},12)
    // 12 m/s for 12 ticks, less what it ramps up to that speed within its first tick.
    p:=loco_position(&f)
    testing.expectf(t,near(p.x,2.35,0.05) && near(p.y,0,0.01),"dashed to %v",p)
    testing.expect(t,near(loco_velocity(&f).x,12,0.05))
    testing.expect_value(t,loco_state(&f).move_count,0)
    loco_test_tick(&f,{},30)
    testing.expect(t,abs(loco_velocity(&f).x)<0.05)
    testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)

    add_move(&f.loco_requests,f.e,{velocity={0,0,2},ticks=1000,mix=.Additive,id=9})
    loco_test_tick(&f,{},30)
    testing.expect(t,near(loco_velocity(&f).z,2,0.02))
    loco_test_tick(&f,{0,0,-1},30)
    testing.expectf(t,near(loco_velocity(&f).z,-3,0.03),"against the conveyor %v",loco_velocity(&f).z)
    remove_moves(&f.loco_requests,f.e,9)
    loco_test_tick(&f,{0,0,-1},30)
    testing.expect_value(t,loco_state(&f).move_count,0)
    testing.expect(t,near(loco_velocity(&f).z,-5,0.03))
}

@(test)
a_flying_locomotion_flies_toward_the_look_and_holds_its_height :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,0}) {return}
    defer loco_test_destroy(&f)
    loco_test_tick(&f,{},30)
    core.add(&f.flights,f.e,FLY_DEFAULT)
    set_mode(&f.loco_requests,f.e,MODE_FLYING)
    pitch:f32=30*cmath.RAD_PER_DEG
    loco_test_tick(&f,{0,0,-1},60,pitch=pitch)
    v:=loco_velocity(&f)
    testing.expectf(t,near(v.y,8*cmath.sin(pitch),0.02) && near(v.z,-8*cmath.cos(pitch),0.02) && abs(v.x)<0.02,"flying %v",v)
    testing.expect_value(t,loco_state(&f).mode,MODE_FLYING)
    loco_test_tick(&f,{},60)
    height:=loco_position(&f).y
    loco_test_tick(&f,{},30)
    testing.expect(t,near(loco_position(&f).y,height,0.001) && height>3)
    set_mode(&f.loco_requests,f.e,MODE_FALLING)
    loco_test_tick(&f,{},150)
    testing.expect(t,loco_state(&f).mode==MODE_WALKING && near(loco_position(&f).y,0,0.01))
}

// An Additive move that lunges faster than traction would drive the body (the root motion of a slash)
// is followed, and the locomotion does not count it as its own: when the lunge eases off and stops,
// the body stops where it went instead of sliding back.
@(test)
an_additive_lunge_is_followed_and_does_not_slide_back :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,0}) {return}
    defer loco_test_destroy(&f)
    loco_test_tick(&f,{},30)
    lunge:=[?]f32{6,12,18,21,21,18,12,8,5,3,2,1}
    fastest:f32
    for speed in lunge {
        add_move(&f.loco_requests,f.e,{velocity={0,0,-speed},ticks=1,mix=.Additive,id=5})
        loco_test_tick(&f,{})
        fastest=max(fastest,-loco_velocity(&f).z)
    }
    gone:=loco_position(&f).z
    loco_test_tick(&f,{},60)
    p:=loco_position(&f)
    expected:f32
    for speed in lunge {expected+=speed/60}
    testing.expectf(t,fastest>20,"the body follows the lunge: %v m/s at most",fastest)
    testing.expectf(t,near(gone,-expected,0.15),"it went %v of the %v the lunge asked",gone,-expected)
    testing.expectf(t,p.z<=gone+0.02 && abs(loco_velocity(&f).z)<0.05,"it stays where the lunge left it: %v from %v",p.z,gone)

    // Into a wall the body stops at it, and when the lunge ends it does not bounce back off it.
    wall:=p.z-1.2
    loco_test_box(&f,{5,2,0.25},{0,2,wall-0.25})
    for _ in 0..<2 {
        for speed in lunge {
            add_move(&f.loco_requests,f.e,{velocity={0,0,-speed},ticks=1,mix=.Additive,id=5})
            loco_test_tick(&f,{})
        }
    }
    stopped:=loco_position(&f).z
    loco_test_tick(&f,{},60)
    q:=loco_position(&f).z
    testing.expectf(t,stopped>wall && stopped<wall+0.6,"it stops at the wall at %v: %v",wall,stopped)
    testing.expectf(t,abs(q-stopped)<0.05,"it stays at the wall: %v from %v",q,stopped)
}

// A mode of the game writes its own move; the layered moves of the
// locomotion still go on top of it, one tick at a time.
@(test)
layered_moves_go_on_top_of_the_move_of_a_mode_of_the_game :: proc(t:^testing.T) {
    loco:Locomotion_State
    loco.mode=Locomotion_Mode(16)
    loco.moves[0]={velocity={0,0,2},ticks=2,mix=.Additive,id=3}
    loco.move_count=1
    swim:=phys.Character_Drive{air={velocity={1,0,0},force=50},flags={.Airborne,.No_Gravity}}
    move:=swim
    layers_apply(&loco,&move,800)
    testing.expect_value(t,move.air,phys.Drive{velocity={1,0,2},force=50})
    testing.expect_value(t,loco.added,[3]f32{0,0,2})
    testing.expect_value(t,loco.move_count,1)
    move=swim
    layers_apply(&loco,&move,800)
    testing.expect_value(t,loco.move_count,0)
    move=swim
    layers_apply(&loco,&move,800)
    testing.expect_value(t,move,swim)
}

// A Character starts in the first of walking (falling until it stands), swimming and flying whose
// component it has, and one without any is not moved by locomotion. A mode asked of an entity without
// its component, or a request for one that is no Character with a mode, is a problem and changes
// nothing. Its first look is where its Transform turns it, also before a World_Transform is propagated
// for it, as for a body spawned in this tick.
@(test)
a_character_starts_in_the_mode_of_its_components_and_a_mode_needs_its_component :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,0}) {return}
    defer loco_test_destroy(&f)
    flier:=loco_test_walker(&f,{3,0,0})
    core.add(&f.flights,flier,FLY_DEFAULT)
    swimmer:=loco_test_walker(&f,{6,0,0},walks=false)
    core.add(&f.swims,swimmer,SWIM_DEFAULT)
    bird:=loco_test_walker(&f,{9,2,0},walks=false)
    core.add(&f.flights,bird,FLY_DEFAULT)
    statue:=loco_test_walker(&f,{12,0,0},walks=false)
    turned:=loco_test_walker(&f,{0,0,6},mm.quat_axis_angle({0,1,0},2.5))
    loco_test_tick(&f,{})
    Start :: struct {e:core.Entity,mode:Locomotion_Mode}
    for start in ([?]Start{{f.e,MODE_FALLING},{flier,MODE_FALLING},{swimmer,MODE_SWIMMING},{bird,MODE_FLYING}}) {
        testing.expectf(t,core.has(&f.loco_states,start.e) && loco_state(&f,start.e).mode==start.mode,"%v starts in %v, not %v",start.e,start.mode,loco_state(&f,start.e).mode)
    }
    testing.expect(t,!core.has(&f.loco_states,statue) && !core.has(&f.inputs,statue) && !core.has(&f.moves,statue),"without a mode locomotion leaves it to whoever writes its Character_Move")
    testing.expect(t,core.has(&f.inputs,f.e) && core.has(&f.moves,f.e),"playing adds its Move_Input and its Character_Move")
    looking,_:=core.get(&f.inputs,turned)
    testing.expectf(t,abs(looking.look_yaw-mm.angle_wrap(2.5))<1e-4,"it looks where its Transform turns its body, not %v",looking.look_yaw)
    loco_test_tick(&f,{},30)
    testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)
    set_mode(&f.loco_requests,f.e,MODE_FLYING)
    set_mode(&f.loco_requests,flier,MODE_FLYING)
    set_mode(&f.loco_requests,statue,MODE_FLYING)
    add_move(&f.loco_requests,statue,{velocity={1,0,0},ticks=1})
    loco_test_tick(&f,{})
    testing.expect(t,loco_state(&f).mode!=MODE_FLYING,"asking for flying without a Fly is refused")
    testing.expect_value(t,loco_state(&f,flier).mode,MODE_FLYING)
    testing.expect(t,core.problem_find(&f.problems,f.e,"locomotion.mode_component")!=nil)
    testing.expect(t,core.problem_find(&f.problems,statue,"locomotion.mode_component")!=nil)
    testing.expect(t,core.problem_find(&f.problems,statue,"locomotion.request")!=nil)
    testing.expect(t,!core.has(&f.loco_states,statue))
}

// The game scales the gravity of a Character for a while through the locomotion: the scale holds until
// asked again, one that is not finite is a problem that changes nothing, and the authored Character
// stays as it was; the state of the locomotion is all transient, so a scene saved after play holds no
// run-time field and the editor offers no Locomotion_State to add.
@(test)
a_requested_gravity_scale_holds_until_asked_again :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,0}) {return}
    defer loco_test_destroy(&f)
    scale_of :: proc(f:^Loco_Test) -> f32 {
        loco_test_tick(f,{})
        return locomotion_gravity(loco_state(f))
    }
    testing.expect_value(t,scale_of(&f),f32(1))
    set_gravity_scale(&f.loco_requests,f.e,0.4)
    testing.expect_value(t,scale_of(&f),f32(0.4))
    testing.expect_value(t,scale_of(&f),f32(0.4))
    set_gravity_scale(&f.loco_requests,f.e,f32(cmath.inf_f32(1)))
    testing.expect_value(t,scale_of(&f),f32(0.4))
    testing.expect(t,core.problem_find(&f.problems,f.e,"locomotion.request")!=nil)
    set_mode(&f.loco_requests,f.e,MODE_CROUCHING)
    set_gravity_scale(&f.loco_requests,f.e,1)
    testing.expect_value(t,scale_of(&f),f32(1))
    authored,_:=core.get(&f.characters,f.e)
    testing.expect_value(t,authored.gravity_scale,phys.character_default().gravity_scale)
    for field in reflect.struct_fields_zipped(Locomotion_State) {
        testing.expectf(t,strings.contains(string(reflect.struct_tag_get(field.tag,"mirai")),"transient"),"Locomotion_State.%s is saved",field.name)
    }
}

// The sea of a test: a plane of water whose surface is at height.
@(private)
loco_test_sea :: proc(f:^Loco_Test,height:f32) {
    sea:=core.create(&f.entities)
    core.add(&f.fluids,sea,phys.Fluid{density=1000})
    core.add(&f.volumes,sea,volume.plane())
    core.add(&f.transforms,sea,core.Transform{{0,height,0},1,{1,1,1}})
}

// Walks in from the shallows, swims on the surface with its head out, dives,
// comes back up and climbs out onto a ledge.
@(test)
a_swimmer_walks_in_swims_dives_surfaces_and_climbs_out_onto_a_ledge :: proc(t:^testing.T) {
    f:Loco_Test
    if !loco_test_init(t,&f,{0,0,5},false) {return}
    defer loco_test_destroy(&f)
    loco_test_box(&f,{10,1,10},{0,-1,10})       // the shallows, a metre under the sea, toward +Z
    loco_test_box(&f,{10,1,10},{0,-7,-10})      // the deep, toward -Z
    loco_test_box(&f,{10,3.65,2},{0,-2.35,-14}) // a ledge 0.3 m over the sea
    loco_test_sea(&f,1)
    core.add(&f.swims,f.e,SWIM_DEFAULT)
    head :: proc(f:^Loco_Test) -> f32 {return loco_found(f).head_depth}
    loco_test_tick(&f,{},30)
    testing.expect_value(t,loco_state(&f).mode,MODE_WALKING)
    testing.expectf(t,near(head(&f),1-1.8,0.02),"head %v",head(&f))
    for i:=0;i<300 && loco_state(&f).mode!=MODE_SWIMMING;i+=1 {loco_test_tick(&f,{0,0,-1})}
    testing.expect_value(t,loco_state(&f).mode,MODE_SWIMMING)
    loco_test_tick(&f,{},300)
    testing.expectf(t,near(head(&f),-SWIM_DEFAULT.surface_offset,0.03),"on the surface the head is %v under it",head(&f))
    testing.expect(t,abs(loco_velocity(&f).y)<0.05)
    // Looking down and forward it dives.
    loco_test_tick(&f,{0,0,-1},90,pitch=-60*cmath.RAD_PER_DEG)
    state:=loco_found(&f)
    testing.expectf(t,state.head_depth>1 && .Underwater in state.fluid,"dived to %v",state.head_depth)
    // Let go, the water stops it and it rises slowly back to the surface, and floats there.
    rise:f32
    for i:=0;i<1200 && head(&f)>0;i+=1 {
        loco_test_tick(&f,{})
        if head(&f)>0.5 {rise=max(rise,loco_velocity(&f).y)}
    }
    testing.expectf(t,rise>0 && rise<0.5,"rises at %v m/s at most",rise)
    loco_test_tick(&f,{},240)
    testing.expect_value(t,loco_state(&f).mode,MODE_SWIMMING)
    testing.expectf(t,near(head(&f),-SWIM_DEFAULT.surface_offset,0.03),"back on the surface, head %v",head(&f))
    // To the ledge, and out onto it.
    for i:=0;i<600 && loco_position(&f).z>-11.6;i+=1 {loco_test_tick(&f,{0,0,-1})}
    loco_test_tick(&f,{0,0,-1},1,JUMP)
    testing.expect_value(t,loco_state(&f).mode,MODE_FALLING)
    loco_test_tick(&f,{0,0,-1},40)
    loco_test_tick(&f,{},80)
    state=loco_found(&f)
    p:=loco_position(&f)
    testing.expectf(t,loco_state(&f).mode==MODE_WALKING && state.standing && near(p.y,1.3,0.02),"out at %v in mode %v",p,loco_state(&f).mode)
    testing.expect_value(t,state.fluid,phys.Fluid_Flags{})
    testing.expectf(t,near(state.head_depth,-(0.3+1.8),0.02),"head %v",state.head_depth)
}

@(test)
without_gravity_a_swimmer_on_the_surface_does_not_climb :: proc(t:^testing.T) {
    loco:=Locomotion_State{mode=MODE_SWIMMING}
    found:phys.Character_State
    found.fluid,found.head_depth,found.depth={.In_Fluid},-0.25,1.55
    given:=input.Move_Input{buttons=JUMP}
    move:=locomotion_move(&loco,phys.character_default(),WALK_DEFAULT,{},SWIM_DEFAULT,{},found,1,given,TEST_JUMP,TEST_SPRINT,TEST_CROUCH,{},{},1.0/60)
    testing.expect_value(t,loco.mode,MODE_SWIMMING)
    testing.expect_value(t,loco.move_count,0)
    testing.expect(t,.Float in move.flags)
}

// A motion of a character in a world a setup makes, where it starts.
@(private="file")
Lock_Case :: struct {
    name:string,
    setup:proc(f:^Loco_Test),
    move:[3]f32,
    buttons:input.Action_Mask,
    yaw,pitch:f32,
    launch:[3]f32,
}

@(private="file")
lock_test_ground :: proc(f:^Loco_Test) {loco_test_box(f,{50,1,50},{0,-1,0})}

@(private="file")
lock_test_place :: proc(f:^Loco_Test,at:[3]f32) {core.edit(&f.transforms,f.e).position=at}

// With Linear_Z locked nothing the step does takes a character off its plane, in any motion; without the
// lock each of them moves it along Z.
@(test)
a_character_locked_along_z_stays_in_its_plane_in_every_motion :: proc(t:^testing.T) {
    diagonal:f32=0.25*cmath.PI
    cases:=[?]Lock_Case{
        {name="walk",setup=lock_test_ground,move={1,0,-1}},
        {name="jump",setup=lock_test_ground,move={1,0,-1},buttons=JUMP},
        {name="tilted gravity",move={1,0,0},setup=proc(f:^Loco_Test) {
            lock_test_ground(f)
            f.gravity={0,-9.81,-4}
            lock_test_place(f,{0,3,0})
        }},
        {name="slope",move={1,0,-1},setup=proc(f:^Loco_Test) {
            loco_test_box(f,{20,1,20},{0,-1,0},mm.quat_axis_angle({1,0,0},-20*cmath.RAD_PER_DEG))
            lock_test_place(f,{0,0.5,0})
        }},
        {name="step and slanted wall",move={1,0,0},setup=proc(f:^Loco_Test) {
            lock_test_ground(f)
            loco_test_box(f,{1,0.1,1},{1.5,0.1,0})
            loco_test_box(f,{0.2,1,3},{4,1,0},mm.quat_axis_angle({0,1,0},0.25*cmath.PI))
        }},
        {name="push a box",move={1,0,0},setup=proc(f:^Loco_Test) {
            lock_test_ground(f)
            loco_test_box(f,{0.4,0.4,0.4},{1.2,0.4,0.3},mm.quat_axis_angle({0,1,0},0.25*cmath.PI),phys.RIGID_BODY_DYNAMIC,300)
        }},
        {name="pushed by a box",setup=proc(f:^Loco_Test) {
            lock_test_ground(f)
            box:=loco_test_box(f,{0.3,0.3,0.3},{-2,0.9,2},rigid=phys.RIGID_BODY_DYNAMIC,density=2000)
            phys.set_velocity(&f.requests,box,{6,0,-6})
        }},
        {name="launch",setup=lock_test_ground,launch={3,5,4}},
        {name="overlap",setup=proc(f:^Loco_Test) {
            lock_test_ground(f)
            loco_test_box(f,{0.5,1,0.5},{0,1,0.65})
        }},
        {name="moving platform",setup=proc(f:^Loco_Test) {
            platform:=loco_test_box(f,{3,0.25,3},{0,0.25,0},rigid=phys.RIGID_BODY_KINEMATIC)
            phys.set_velocity(&f.requests,platform,{0.5,0,1},{0,0.8,0})
            lock_test_place(f,{0.5,0.6,0.5})
        }},
        {name="fly",move={0,0,-1},yaw=diagonal,pitch=0.3,setup=proc(f:^Loco_Test) {
            lock_test_ground(f)
            core.add(&f.flights,f.e,FLY_DEFAULT)
            set_mode(&f.loco_requests,f.e,MODE_FLYING)
        }},
        {name="swim",move={0,0,-1},yaw=diagonal,pitch=-0.5,setup=proc(f:^Loco_Test) {
            loco_test_box(f,{50,1,50},{0,-9,0})
            loco_test_sea(f,1)
            lock_test_place(f,{0,-3,0})
            core.add(&f.swims,f.e,SWIM_DEFAULT)
            set_mode(&f.loco_requests,f.e,MODE_SWIMMING)
        }},
    }
    for c in cases {
        for locked in ([2]bool{false,true}) {
            f:Loco_Test
            if !loco_test_init(t,&f,{0,0,0},false) {return}
            defer loco_test_destroy(&f)
            core.test_world_settle(&f.w)
            if locked {core.edit(&f.characters,f.e).locks={.Linear_Z}}
            c.setup(&f)
            core.test_world_settle(&f.w)
            start,_:=core.get(&f.transforms,f.e)
            off:f32
            for tick in 0..<150 {
                if tick==20 && c.launch!={} {phys.apply_impulse(&f.requests,f.e,c.launch*phys.character_default().mass)}
                loco_test_tick(&f,tick<20?{}:c.move,1,tick<20?{}:c.buttons,c.yaw,c.pitch)
                off=max(off,abs(loco_position(&f).z-start.position.z))
            }
            moved:=loco_position(&f)-start.position
            if locked {
                testing.expectf(t,off<1e-3,"%s: locked along Z it left its plane by %v",c.name,off)
                testing.expectf(t,abs(loco_velocity(&f).z)<1e-6,"%s: velocity %v",c.name,loco_velocity(&f))
            } else {
                testing.expectf(t,off>0.05,"%s: without the lock it moves along Z, only %v here",c.name,off)
            }
            testing.expectf(t,abs(moved.x)+abs(moved.y)<1e3,"%s: %v",c.name,moved)
        }
    }
}
