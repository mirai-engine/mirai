package physics

import cmath "core:math"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

// A character of the solver driven by locomotion_move, as locomotion_step drives one of the world.
@(private="file")
Loco_Test :: struct {
    w:sim.World,
    ch:sim.Character_Handle,
    loco:Character,
    walk:Walk,
    fly:Fly,
    swim:Maybe(Swim),
    slide:Maybe(Slide),
}

@(private="file")
loco_test_init :: proc(f:^Loco_Test,position:[3]f32,ground:=true) -> bool {
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.character_capacity=16,16,128,2
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=1,1,1,64
    if !sim.world_init(&f.w,desc) {return false}
    if ground {loco_test_box(f,{50,1,50},{0,-1,0})}
    f.loco,f.walk=character_default(),WALK_DEFAULT
    f.ch=sim.character_create(&f.w,sim.CHARACTER_DESC_DEFAULT,position)
    return f.ch!={}
}

@(private="file")
loco_test_box :: proc(f:^Loco_Test,half,position:[3]f32,rotation:=mm.QUAT_IDENTITY,type:=sim.Body_Type.Static,density:f32=1000) -> sim.Body_Handle {
    desc:=sim.BODY_DESC_DEFAULT
    desc.type,desc.position,desc.rotation=type,position,rotation
    body:=sim.body_create(&f.w,desc)
    shape:=sim.SHAPE_DESC_DEFAULT
    shape.geometry=sim.Box{half}
    shape.density=density
    sim.shape_create(&f.w,body,shape)
    return body
}

// The actions of a test world: input.Look_Action from 0, and Walk_Action after it.
@(private) TEST_WALK_BASE :: input.Action(len(input.Look_Action))
@(private) TEST_MOVE :: TEST_WALK_BASE+input.Action(Walk_Action.Move)
@(private) TEST_JUMP :: TEST_WALK_BASE+input.Action(Walk_Action.Jump)
@(private) TEST_SPRINT :: TEST_WALK_BASE+input.Action(Walk_Action.Sprint)
@(private) TEST_CROUCH :: TEST_WALK_BASE+input.Action(Walk_Action.Crouch)

@(private="file")
loco_test_tick :: proc(f:^Loco_Test,move:[3]f32,ticks:=1,buttons:=input.Action_Mask(0),yaw:f32=0,pitch:f32=0) {
    for _ in 0..<ticks {
        found:=character_state_of(sim.character_state(&f.w,f.ch))
        given:=input.Move_Input{move=move,look_yaw=yaw,look_pitch=pitch,buttons=buttons}
        m:=locomotion_move(&f.loco,f.walk,f.fly,f.swim,{slide=f.slide},found,1,given,TEST_JUMP,TEST_SPRINT,TEST_CROUCH,sim.character_velocity(&f.w,f.ch),f.w.gravity,1.0/60)
        sim.character_set_move(&f.w,f.ch,m)
        sim.world_step(&f.w,1.0/60)
    }
}

@(private="file")
near :: proc(a,b,tolerance:f32) -> bool {return abs(a-b)<=tolerance}

@(test)
walking_reaches_the_speed_of_the_locomotion_and_brakes :: proc(t:^testing.T) {
    f:Loco_Test
    testing.expect(t,loco_test_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    loco_test_tick(&f,{},30)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    loco_test_tick(&f,{0,0,-1},10)
    // 30 m/s2 for 10 ticks; the first tick decides on the ground the step before it found.
    v:=sim.character_velocity(&f.w,f.ch)
    testing.expectf(t,near(v.z,-5,0.1),"velocity %v",v)
    loco_test_tick(&f,{0,0,-1},50)
    v=sim.character_velocity(&f.w,f.ch)
    testing.expectf(t,near(v.z,-5,0.02) && abs(v.x)<0.01 && abs(v.y)<0.01,"velocity %v",v)
    // The look yaw turns the move: a quarter turn to the left makes forward point to -X.
    loco_test_tick(&f,{0,0,-1},40,yaw=0.5*cmath.PI)
    v=sim.character_velocity(&f.w,f.ch)
    testing.expectf(t,near(v.x,-5,0.02) && abs(v.z)<0.02,"turned velocity %v",v)
    loco_test_tick(&f,{},20)
    testing.expect(t,abs(sim.character_velocity(&f.w,f.ch).x)<0.01)
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
    testing.expect(t,loco_test_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    f.walk.sprint_speed=8
    loco_test_tick(&f,{},30)
    loco_test_tick(&f,{0,0,-1},90,buttons=input.action_bit(TEST_SPRINT))
    v:=sim.character_velocity(&f.w,f.ch)
    testing.expectf(t,near(v.z,-8,0.05),"sprint velocity %v",v)
    loco_test_tick(&f,{0,0,-1},60)
    v=sim.character_velocity(&f.w,f.ch)
    testing.expectf(t,near(v.z,-5,0.05),"after letting sprint go %v",v)
}

// The body faces where the look does: -Z.
@(test)
walking_toward_plus_x_turns_the_front_of_the_body_to_plus_x_and_keeps_the_look :: proc(t:^testing.T) {
    f:Loco_Test
    testing.expect(t,loco_test_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    look:=f32(-0.5*cmath.PI)
    loco_test_tick(&f,{0,0,-1},60,yaw=look)
    v:=sim.character_velocity(&f.w,f.ch)
    testing.expectf(t,near(v.x,5,0.05) && abs(v.z)<0.05,"velocity %v",v)
    rotation:=sim.body_transform(&f.w,sim.character_body(&f.w,f.ch)).q
    front:=mm.quat_forward(rotation)
    testing.expectf(t,near(front.x,1,1e-4),"the body's -Z is %v",front)
    testing.expectf(t,near(sim.character_move(&f.w,f.ch).yaw,look,1e-6),"move yaw %v",sim.character_move(&f.w,f.ch).yaw)
    testing.expectf(t,near(look_yaw_of(mm.QUAT_IDENTITY,rotation),look,1e-4),"the look taken from the body %v",look_yaw_of(mm.QUAT_IDENTITY,rotation))
}

// From 3 m up it lands on flat ground or on a ledge below whose top is 1.5 m up, when and as fast
// as predicted from the start and again in the middle of the fall; going across off a ledge it
// lands on the floor where its arc reaches it, not on the ledge below its feet; with no ground
// nothing is.
@(test)
a_falling_character_predicts_when_and_how_fast_it_lands_on_the_arc_it_follows :: proc(t:^testing.T) {
    Case :: struct {ground:bool,start:[3]f32,ledge,height,across:f32}
    cases:=[4]Case{
        {ground=true,start={0,3,0},height=3},
        {ground=true,start={0,3,0},ledge=1.5,height=1.5},
        {ground=true,start={.6,3.5,0},ledge=3,height=3.5,across=6},
        {start={0,3,0},height=3},
    }
    for c in cases {
        f:Loco_Test
        if !testing.expect(t,loco_test_init(&f,c.start,c.ground)) {continue}
        defer sim.world_destroy(&f.w)
        if c.ledge>0 {loco_test_box(&f,{1,c.ledge/2,1},{0,c.ledge/2,0})}
        sim.body_set_linear_velocity(&f.w,sim.character_body(&f.w,f.ch),{c.across,0,0})
        g:=-f.w.gravity.y
        time,speed,found:=landing_on_arc(&f.w,f.ch)
        if !c.ground {
            testing.expectf(t,!found,"with no ground below nothing lands, not in %.3f s",time)
            continue
        }
        expected:=cmath.sqrt(2*c.height/g)
        testing.expectf(t,found && near(time,expected,.02) && near(speed,g*expected,.2),"from %.1f m it lands in %.3f s at %.2f m/s, not %.3f s at %.2f m/s",c.height,expected,g*expected,time,speed)
        ticks:=0
        for ; ticks<240; ticks+=1 {
            if .Standing in sim.character_state(&f.w,f.ch).ground {break}
            loco_test_tick(&f,{})
            if ticks==20 {
                left,_,_:=landing_on_arc(&f.w,f.ch)
                testing.expectf(t,near(left,expected-21.0/60,.03),"in the middle of the fall it lands in %.3f s, not %.3f s",expected-21.0/60,left)
            }
        }
        testing.expectf(t,near(f32(ticks)/60,time,3.0/60),"it lands after %.3f s, as predicted %.3f s",f32(ticks)/60,time)
        at:=sim.character_position(&f.w,f.ch)
        testing.expectf(t,near(at.x,c.start.x+c.across*time,.2) && near(at.y,c.start.y-c.height,.05),"it lands at %v, where its arc reaches the ground",at)
    }
}

@(test)
a_jump_reaches_the_height_of_the_locomotion_once_per_press :: proc(t:^testing.T) {
    for height in ([2]f32{0.6,1.5}) {
        f:Loco_Test
        testing.expect(t,loco_test_init(&f,{0,0,0}))
        f.walk.jump_height=height
        loco_test_tick(&f,{},30)
        apex:f32
        for i in 0..<120 {
            // The button stays down: only the press jumps.
            loco_test_tick(&f,{},1,input.action_bit(TEST_JUMP))
            apex=max(apex,sim.character_position(&f.w,f.ch).y)
            if i==5 {testing.expect(t,f.loco.mode==MODE_FALLING && f.loco.jumped)}
        }
        testing.expectf(t,near(apex,height,0.03*height),"apex %v for a jump of %v",apex,height)
        testing.expect_value(t,f.loco.mode,MODE_WALKING)
        sim.world_destroy(&f.w)
    }
    // Let go while it rises, it keeps jump_cut of its speed up; with 1 the jump goes on as it was.
    for cut in ([2]f32{1,0.5}) {
        f:Loco_Test
        testing.expect(t,loco_test_init(&f,{0,0,0}))
        defer sim.world_destroy(&f.w)
        f.walk.jump_cut=cut
        loco_test_tick(&f,{},30)
        loco_test_tick(&f,{},6,input.action_bit(TEST_JUMP))
        speed,apex:=sim.character_velocity(&f.w,f.ch).y,sim.character_position(&f.w,f.ch).y
        want:=apex+cut*cut*speed*speed/(2*abs(f.w.gravity.y))
        for _ in 0..<120 {
            loco_test_tick(&f,{})
            apex=max(apex,sim.character_position(&f.w,f.ch).y)
        }
        testing.expectf(t,near(apex,want,0.05),"with jump_cut %v it rises to %v, want %v",cut,apex,want)
    }
}

@(test)
coyote_time_allows_a_jump_just_after_walking_off_a_ledge :: proc(t:^testing.T) {
    for wait,i in ([2]int{2,20}) {
        f:Loco_Test
        testing.expect(t,loco_test_init(&f,{0,0,-1},false))
        loco_test_box(&f,{2,1,2},{0,-1,0})
        loco_test_tick(&f,{},30)
        for f.loco.mode==MODE_WALKING {loco_test_tick(&f,{0,0,-1})}
        testing.expect(t,f.loco.coyote>0)
        loco_test_tick(&f,{0,0,-1},wait)
        loco_test_tick(&f,{0,0,-1},1,input.action_bit(TEST_JUMP))
        loco_test_tick(&f,{0,0,-1},1)
        if i==0 {
            testing.expect(t,f.loco.jumped && sim.character_velocity(&f.w,f.ch).y>4)
        } else {
            testing.expect(t,!f.loco.jumped && sim.character_velocity(&f.w,f.ch).y<-2)
        }
        sim.world_destroy(&f.w)
    }
}

@(test)
a_dash_overrides_the_locomotion_for_its_ticks_and_a_conveyor_adds_to_it :: proc(t:^testing.T) {
    f:Loco_Test
    testing.expect(t,loco_test_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    loco_test_tick(&f,{},30)
    f.loco.moves[0]={velocity={12,0,0},force=80*12*240,ticks=12,mix=.Override,id=7}
    f.loco.move_count=1
    loco_test_tick(&f,{},12)
    p:=sim.character_position(&f.w,f.ch)
    testing.expectf(t,near(p.x,2.4,0.05) && near(p.y,0,0.01),"dashed to %v",p)
    testing.expect(t,near(sim.character_velocity(&f.w,f.ch).x,12,0.05))
    testing.expect_value(t,f.loco.move_count,0)
    loco_test_tick(&f,{},30)
    testing.expect(t,abs(sim.character_velocity(&f.w,f.ch).x)<0.05)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)

    f.loco.moves[0]={velocity={0,0,2},ticks=1000,mix=.Additive,id=9}
    f.loco.move_count=1
    loco_test_tick(&f,{},30)
    testing.expect(t,near(sim.character_velocity(&f.w,f.ch).z,2,0.02))
    loco_test_tick(&f,{0,0,-1},30)
    testing.expectf(t,near(sim.character_velocity(&f.w,f.ch).z,-3,0.03),"against the conveyor %v",sim.character_velocity(&f.w,f.ch).z)
    moves_remove(&f.loco,9)
    testing.expect_value(t,f.loco.move_count,0)
    loco_test_tick(&f,{0,0,-1},30)
    testing.expect(t,near(sim.character_velocity(&f.w,f.ch).z,-5,0.03))
}

@(test)
a_flying_locomotion_flies_toward_the_look_and_holds_its_height :: proc(t:^testing.T) {
    f:Loco_Test
    testing.expect(t,loco_test_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    loco_test_tick(&f,{},30)
    f.loco.mode=MODE_FLYING
    f.fly=FLY_DEFAULT
    pitch:f32=30*cmath.RAD_PER_DEG
    loco_test_tick(&f,{0,0,-1},60,pitch=pitch)
    v:=sim.character_velocity(&f.w,f.ch)
    testing.expectf(t,near(v.y,8*cmath.sin(pitch),0.02) && near(v.z,-8*cmath.cos(pitch),0.02) && abs(v.x)<0.02,"flying %v",v)
    testing.expect_value(t,f.loco.mode,MODE_FLYING)
    loco_test_tick(&f,{},60)
    height:=sim.character_position(&f.w,f.ch).y
    loco_test_tick(&f,{},30)
    testing.expect(t,near(sim.character_position(&f.w,f.ch).y,height,0.001) && height>3)
    f.loco.mode=MODE_FALLING
    loco_test_tick(&f,{},150)
    testing.expect(t,f.loco.mode==MODE_WALKING && near(sim.character_position(&f.w,f.ch).y,0,0.01))
}

// An Additive move that lunges faster than traction drives the body (the root motion of a slash) and
// brings its force is followed, and the locomotion does not count it as its own: when the lunge
// eases off and stops, the body stops where it went instead of sliding back.
@(test)
an_additive_lunge_with_its_force_is_followed_and_does_not_slide_back :: proc(t:^testing.T) {
    f:Loco_Test
    testing.expect(t,loco_test_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    loco_test_tick(&f,{},30)
    lunge:=[?]f32{6,12,18,21,21,18,12,8,5,3,2,1}
    fastest:f32
    for speed in lunge {
        f.loco.moves[0]={velocity={0,0,-speed},force=f.loco.mass*speed*60,ticks=1,mix=.Additive,id=5}
        f.loco.move_count=1
        loco_test_tick(&f,{})
        fastest=max(fastest,-sim.character_velocity(&f.w,f.ch).z)
    }
    gone:=sim.character_position(&f.w,f.ch).z
    loco_test_tick(&f,{},60)
    p:=sim.character_position(&f.w,f.ch)
    expected:f32
    for speed in lunge {expected+=speed/60}
    testing.expectf(t,fastest>20,"the body follows the lunge: %v m/s at most",fastest)
    testing.expectf(t,near(gone,-expected,0.15),"it went %v of the %v the lunge asked",gone,-expected)
    testing.expectf(t,p.z<=gone+0.02 && abs(sim.character_velocity(&f.w,f.ch).z)<0.05,"it stays where the lunge left it: %v from %v",p.z,gone)

    // Into a wall the body stops at it, and when the lunge ends it does not bounce back off it.
    wall:=p.z-1.2
    loco_test_box(&f,{5,2,0.25},{0,2,wall-0.25})
    for _ in 0..<2 {
        for speed in lunge {
            f.loco.moves[0]={velocity={0,0,-speed},force=f.loco.mass*speed*60,ticks=1,mix=.Additive,id=5}
            f.loco.move_count=1
            loco_test_tick(&f,{})
        }
    }
    stopped:=sim.character_position(&f.w,f.ch).z
    loco_test_tick(&f,{},60)
    q:=sim.character_position(&f.w,f.ch).z
    testing.expectf(t,stopped>wall && stopped<wall+0.6,"it stops at the wall at %v: %v",wall,stopped)
    testing.expectf(t,abs(q-stopped)<0.05,"it stays at the wall: %v from %v",q,stopped)
}

// A mode of the game writes its own move; the layered moves of the
// locomotion still go on top of it, one tick at a time.
@(test)
layered_moves_go_on_top_of_the_move_of_a_mode_of_the_game :: proc(t:^testing.T) {
    loco:=character_default()
    loco.mode=Locomotion_Mode(16)
    loco.moves[0]={velocity={0,0,2},ticks=2,mix=.Additive,id=3}
    loco.move_count=1
    swim:=sim.Character_Move{air={velocity={1,0,0},force=50},flags={.Airborne,.No_Gravity}}
    move:=swim
    layers_apply(&loco,&move,800)
    testing.expect_value(t,move.air,sim.Drive{velocity={1,0,2},force=50})
    testing.expect_value(t,loco.added,[3]f32{0,0,2})
    testing.expect_value(t,loco.move_count,1)
    move=swim
    layers_apply(&loco,&move,800)
    testing.expect_value(t,loco.move_count,0)
    move=swim
    layers_apply(&loco,&move,800)
    testing.expect_value(t,move,swim)
}

// What locomotion_step reads and writes, to run it alone.
@(private="file")
Loco_World :: struct {
    using world:core.Test_World,
    characters:core.Table(Character),
    moves:core.Table(Character_Move),
    inputs:core.Table(input.Move_Input),
    walks:core.Table(Walk),
    flights:core.Table(Fly),
    swims:core.Table(Swim),
    slides:core.Table(Slide),
    mantles:core.Table(Mantle),
    tacticals:core.Table(Tactical_Sprint),
    ledges:core.Table(Ledge_Jump),
    found:core.Table(Character_State),
    motions:core.Table(core.Motion),
    locals:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    remotes:core.Table(core.Remote),
    physics:Physics_State,
    requests:Locomotion_Requests,
}

@(private="file")
Loco_Step_Test :: struct {
    using w:Loco_World,
    problems:core.Problems,
}

@(private="file")
loco_step_test_run :: proc(f:^Loco_Step_Test,playing:bool) {
    locomotion_step(&f.characters,&f.moves,&f.inputs,core.read(&f.walks),core.read(&f.flights),core.read(&f.swims),core.read(&f.slides),core.read(&f.mantles),core.read(&f.tacticals),core.read(&f.ledges),core.read(&f.found),core.read(&f.motions),core.read(&f.locals),core.read(&f.parents),core.read(&f.remotes),core.ref(&f.physics),{},{base=TEST_WALK_BASE},&f.requests,{playing=playing,dt=1.0/60},core.CLOCK_DEFAULT,&f.problems)
}

// A mode needs the component of its parameters: flying without a Fly, asked
// for or started in, is a problem and the character does not fly. Its first
// look is where its Transform turns it, also before a World_Transform is
// propagated for it, as for a body spawned in this tick.
@(test)
a_mode_needs_its_component :: proc(t:^testing.T) {
    f:Loco_Step_Test
    if !core.test_world_init(t,&f.w,test_types) {return}
    defer core.test_world_destroy(&f.w)
    walker,flier:=core.create(&f.entities),core.create(&f.entities)
    starts_flying:=character_default()
    starts_flying.mode=MODE_FLYING
    core.add(&f.characters,walker,starts_flying)
    core.add(&f.characters,flier,character_default())
    core.add(&f.flights,flier,FLY_DEFAULT)
    for e in ([2]core.Entity{walker,flier}) {core.add(&f.walks,e,WALK_DEFAULT)}
    core.add(&f.locals,walker,core.Transform{{0,0,0},mm.quat_axis_angle({0,1,0},2.5),{1,1,1}})
    core.test_world_settle(&f.w)
    set_mode(&f.requests,flier,MODE_FLYING)
    loco_step_test_run(&f,true)
    walking,_:=core.get(&f.characters,walker)
    flying,_:=core.get(&f.characters,flier)
    testing.expect(t,walking.mode!=MODE_FLYING,"without a Fly it does not fly")
    testing.expect_value(t,flying.mode,MODE_FLYING)
    testing.expect(t,core.problem_find(&f.problems,walker,"locomotion.mode_component")!=nil)
    set_mode(&f.requests,walker,MODE_FLYING)
    loco_step_test_run(&f,true)
    walking,_=core.get(&f.characters,walker)
    testing.expect(t,walking.mode!=MODE_FLYING,"asking for flying without a Fly is refused")
    core.test_world_settle(&f.w)
    testing.expect(t,core.has(&f.inputs,walker) && core.has(&f.moves,walker),"playing adds its Move_Input and its Character_Move")
    looking,_:=core.get(&f.inputs,walker)
    testing.expectf(t,abs(looking.look_yaw-mm.angle_wrap(2.5))<1e-4,"it looks where its Transform turns its body, not %v",looking.look_yaw)
}

// The game scales the gravity of a Character for a while through the locomotion, its only writer:
// the scale holds until asked again, and one that is not finite is a problem that changes nothing.
@(test)
a_requested_gravity_scale_holds_until_asked_again :: proc(t:^testing.T) {
    f:Loco_Step_Test
    if !core.test_world_init(t,&f.w,test_types) {return}
    defer core.test_world_destroy(&f.w)
    walker:=core.create(&f.entities)
    core.add(&f.characters,walker,character_default())
    core.add(&f.walks,walker,WALK_DEFAULT)
    core.test_world_settle(&f.w)
    scale_of :: proc(f:^Loco_Step_Test,e:core.Entity) -> f32 {c,_:=core.get(&f.characters,e);return c.gravity_scale}
    testing.expect_value(t,scale_of(&f,walker),f32(1))
    set_gravity_scale(&f.requests,walker,0.4)
    loco_step_test_run(&f,false)
    testing.expect_value(t,scale_of(&f,walker),f32(0.4))
    loco_step_test_run(&f,false)
    testing.expect_value(t,scale_of(&f,walker),f32(0.4))
    set_gravity_scale(&f.requests,walker,f32(cmath.inf_f32(1)))
    loco_step_test_run(&f,false)
    testing.expect_value(t,scale_of(&f,walker),f32(0.4))
    testing.expect(t,core.problem_find(&f.problems,walker,"locomotion.request")!=nil)
    set_gravity_scale(&f.requests,walker,1)
    loco_step_test_run(&f,false)
    testing.expect_value(t,scale_of(&f,walker),f32(1))
}

// Walks in from the shallows, swims on the surface with its head out, dives,
// comes back up and climbs out onto a ledge.
@(test)
a_swimmer_walks_in_swims_dives_surfaces_and_climbs_out_onto_a_ledge :: proc(t:^testing.T) {
    f:Loco_Test
    testing.expect(t,loco_test_init(&f,{0,0,5},false))
    defer sim.world_destroy(&f.w)
    loco_test_box(&f,{10,1,10},{0,-1,10})       // the shallows, a metre under the sea, toward +Z
    loco_test_box(&f,{10,1,10},{0,-7,-10})      // the deep, toward -Z
    loco_test_box(&f,{10,3.65,2},{0,-2.35,-14}) // a ledge 0.3 m over the sea
    testing.expect(t,sim.fluid_create(&f.w,{shape=.Plane,position={0,1,0},density=1000})!={})
    f.swim=SWIM_DEFAULT
    head :: proc(f:^Loco_Test) -> f32 {return sim.character_state(&f.w,f.ch).head_depth}
    loco_test_tick(&f,{},30)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    expect_near(t,head(&f),1-1.8,0.02)
    for i:=0;i<300 && f.loco.mode!=MODE_SWIMMING;i+=1 {loco_test_tick(&f,{0,0,-1})}
    testing.expect_value(t,f.loco.mode,MODE_SWIMMING)
    loco_test_tick(&f,{},300)
    testing.expectf(t,near(head(&f),-SWIM_DEFAULT.surface_offset,0.03),"on the surface the head is %v under it",head(&f))
    testing.expect(t,abs(sim.character_velocity(&f.w,f.ch).y)<0.05)
    // Looking down and forward it dives.
    loco_test_tick(&f,{0,0,-1},90,pitch=-60*cmath.RAD_PER_DEG)
    state:=sim.character_state(&f.w,f.ch)
    testing.expectf(t,state.head_depth>1 && .Underwater in state.fluid,"dived to %v",state.head_depth)
    // Let go, the water stops it and it rises slowly back to the surface, and floats there.
    rise:f32
    for i:=0;i<1200 && head(&f)>0;i+=1 {
        loco_test_tick(&f,{})
        if head(&f)>0.5 {rise=max(rise,sim.character_velocity(&f.w,f.ch).y)}
    }
    testing.expectf(t,rise>0 && rise<0.5,"rises at %v m/s at most",rise)
    loco_test_tick(&f,{},240)
    testing.expect_value(t,f.loco.mode,MODE_SWIMMING)
    testing.expectf(t,near(head(&f),-SWIM_DEFAULT.surface_offset,0.03),"back on the surface, head %v",head(&f))
    // To the ledge, and out onto it.
    for i:=0;i<600 && sim.character_position(&f.w,f.ch).z>-11.6;i+=1 {loco_test_tick(&f,{0,0,-1})}
    loco_test_tick(&f,{0,0,-1},1,input.action_bit(TEST_JUMP))
    testing.expect_value(t,f.loco.mode,MODE_FALLING)
    loco_test_tick(&f,{0,0,-1},40)
    loco_test_tick(&f,{},80)
    state=sim.character_state(&f.w,f.ch)
    p:=sim.character_position(&f.w,f.ch)
    testing.expectf(t,f.loco.mode==MODE_WALKING && .Standing in state.ground && near(p.y,1.3,0.02),"out at %v in mode %v",p,f.loco.mode)
    testing.expect_value(t,state.fluid,sim.Fluid_Flags{})
    expect_near(t,state.head_depth,-(0.3+1.8),0.02)
}

@(private="file")
expect_near :: proc(t:^testing.T,value,expected,tolerance:f32,loc:=#caller_location) {
    testing.expectf(t,abs(value-expected)<=tolerance,"got %v, expected %v",value,expected,loc=loc)
}

@(test)
without_gravity_a_swimmer_on_the_surface_does_not_climb :: proc(t:^testing.T) {
    f:Loco_Test
    testing.expect(t,loco_test_init(&f,{0,0,0},false))
    defer sim.world_destroy(&f.w)
    f.loco.mode,f.swim=MODE_SWIMMING,SWIM_DEFAULT
    found:sim.Character_State
    found.fluid,found.head_depth,found.depth={.In_Fluid},-0.25,1.55
    given:=input.Move_Input{buttons=input.action_bit(TEST_JUMP)}
    move:=locomotion_move(&f.loco,f.walk,f.fly,f.swim,{slide=f.slide},character_state_of(found),1,given,TEST_JUMP,TEST_SPRINT,TEST_CROUCH,{},{},1.0/60)
    testing.expect_value(t,f.loco.mode,MODE_SWIMMING)
    testing.expect_value(t,f.loco.move_count,0)
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

// With Linear_Z locked nothing the step does takes a character off its plane, in any motion; without the
// lock each of them moves it along Z.
@(test)
a_character_locked_along_z_stays_in_its_plane_in_every_motion :: proc(t:^testing.T) {
    diagonal:f32=0.25*cmath.PI
    cases:=[?]Lock_Case{
        {name="walk",setup=lock_test_ground,move={1,0,-1}},
        {name="jump",setup=lock_test_ground,move={1,0,-1},buttons=input.action_bit(TEST_JUMP)},
        {name="tilted gravity",move={1,0,0},setup=proc(f:^Loco_Test) {
            lock_test_ground(f)
            sim.world_set_gravity(&f.w,{0,-9.81,-4})
            sim.character_set_position(&f.w,f.ch,{0,3,0})
        }},
        {name="slope",move={1,0,-1},setup=proc(f:^Loco_Test) {
            loco_test_box(f,{20,1,20},{0,-1,0},mm.quat_axis_angle({1,0,0},-20*cmath.RAD_PER_DEG))
            sim.character_set_position(&f.w,f.ch,{0,0.5,0})
        }},
        {name="step and slanted wall",move={1,0,0},setup=proc(f:^Loco_Test) {
            lock_test_ground(f)
            loco_test_box(f,{1,0.1,1},{1.5,0.1,0})
            loco_test_box(f,{0.2,1,3},{4,1,0},mm.quat_axis_angle({0,1,0},0.25*cmath.PI))
        }},
        {name="push a box",move={1,0,0},setup=proc(f:^Loco_Test) {
            lock_test_ground(f)
            loco_test_box(f,{0.4,0.4,0.4},{1.2,0.4,0.3},mm.quat_axis_angle({0,1,0},0.25*cmath.PI),.Dynamic,300)
        }},
        {name="pushed by a box",setup=proc(f:^Loco_Test) {
            lock_test_ground(f)
            box:=loco_test_box(f,{0.3,0.3,0.3},{-2,0.9,2},type=.Dynamic,density=2000)
            sim.body_set_velocity(&f.w,box,{6,0,-6},{})
        }},
        {name="launch",setup=lock_test_ground,launch={3,5,4}},
        {name="overlap",setup=proc(f:^Loco_Test) {
            lock_test_ground(f)
            loco_test_box(f,{0.5,1,0.5},{0,1,0.65})
        }},
        {name="moving platform",setup=proc(f:^Loco_Test) {
            platform:=loco_test_box(f,{3,0.25,3},{0,0.25,0},type=.Kinematic)
            sim.body_set_velocity(&f.w,platform,{0.5,0,1},{0,0.8,0})
            sim.character_set_position(&f.w,f.ch,{0.5,0.6,0.5})
        }},
        {name="fly",move={0,0,-1},yaw=diagonal,pitch=0.3,setup=proc(f:^Loco_Test) {
            lock_test_ground(f)
            f.loco.mode,f.fly=MODE_FLYING,FLY_DEFAULT
        }},
        {name="swim",move={0,0,-1},yaw=diagonal,pitch=-0.5,setup=proc(f:^Loco_Test) {
            loco_test_box(f,{50,1,50},{0,-9,0})
            sim.fluid_create(&f.w,{shape=.Plane,position={0,1,0},density=1000})
            sim.character_set_position(&f.w,f.ch,{0,-3,0})
            f.loco.mode,f.swim=MODE_SWIMMING,SWIM_DEFAULT
        }},
    }
    for c in cases {
        for locked in ([2]bool{false,true}) {
            f:Loco_Test
            if !testing.expect(t,loco_test_init(&f,{0,0,0},false)) {return}
            if locked {sim.character_set_locks(&f.w,f.ch,{.Lock_Linear_Z})}
            c.setup(&f)
            start:=sim.character_position(&f.w,f.ch)
            off:f32
            for tick in 0..<150 {
                if tick==20 && c.launch!={} {sim.character_launch(&f.w,f.ch,c.launch)}
                loco_test_tick(&f,tick<20?{}:c.move,1,tick<20?{}:c.buttons,c.yaw,c.pitch)
                off=max(off,abs(sim.character_position(&f.w,f.ch).z-start.z))
            }
            moved:=sim.character_position(&f.w,f.ch)-start
            if locked {
                testing.expectf(t,off<1e-3,"%s: locked along Z it left its plane by %v",c.name,off)
                testing.expectf(t,abs(sim.character_velocity(&f.w,f.ch).z)<1e-6,"%s: velocity %v",c.name,sim.character_velocity(&f.w,f.ch))
            } else {
                testing.expectf(t,off>0.05,"%s: without the lock it moves along Z, only %v here",c.name,off)
            }
            testing.expectf(t,abs(moved.x)+abs(moved.y)<1e3,"%s: %v",c.name,moved)
            sim.world_destroy(&f.w)
        }
    }
}

// A Character locked along Z walks on the plane where it was made; a place puts it on another plane, where
// it stays, and the lock taken away lets its move take it along Z again.
@(test)
a_place_moves_a_character_locked_along_z_to_another_plane_where_it_stays :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.gravity={0,-9.81,0}
    physics_test_box(&f,{0,-1,0},{50,1,50})
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{{0,0,0},1,{1,1,1}})
    core.add(&f.colliders,e,collider_character())
    config:=character_default()
    config.locks={.Linear_Z}
    core.add(&f.characters,e,config)
    core.add(&f.moves,e,Character_Move{value={ground={velocity={2,0,2},force=3200},air={velocity={2,0,2},force=800}}})
    for _ in 0..<30 {physics_test_step(&f)}
    at:=physics_test_pose(&f,e).position
    testing.expectf(t,abs(at.z)<1e-3 && at.x>0.5,"walked to %v",at)
    teleport(&f.requests,e,{at.x,0,3})
    for _ in 0..<60 {physics_test_step(&f)}
    after:=physics_test_pose(&f,e).position
    testing.expectf(t,abs(after.z-3)<1e-3 && after.x>at.x+1.5,"placed at z 3, it is at %v",after)
    core.edit(&f.characters,e).locks={}
    for _ in 0..<30 {physics_test_step(&f)}
    free:=physics_test_pose(&f,e).position
    testing.expectf(t,free.z>3.5,"without the lock it walks along Z again: %v",free)
}
