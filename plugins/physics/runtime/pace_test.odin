package physics

import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import sim "plugins:physics/runtime/sim"

@(private="file")
PACED_RATE :: 60 // ticks per second the walkers step at

@(private="file")
Paced_World :: struct {
    using world:core.Test_World,
    paces:core.Table(core.Own_Pace),
}

// Two walkers on a floor under one clock, the first with an Own_Pace of rate 1,
// driven as locomotion_step drives them.
@(private="file")
Paced :: struct {
    w:sim.World,
    using rows:Paced_World,
    walkers:[2]core.Entity,
    chars:[2]sim.Character_Handle,
    locos:[2]Locomotion_State,
}

@(private="file")
paced_init :: proc(t:^testing.T,f:^Paced) -> bool {
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.character_capacity=16,16,128,2
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=1,1,1,64
    if !testing.expect(t,sim.world_init(&f.w,desc)) {return false}
    if !core.test_world_init(t,&f.rows) {
        sim.world_destroy(&f.w)
        return false
    }
    floor:=sim.BODY_DESC_DEFAULT
    floor.type,floor.position=.Static,{0,-1,0}
    shape:=sim.SHAPE_DESC_DEFAULT
    shape.geometry=sim.Box{{200,1,200}}
    sim.shape_create(&f.w,sim.body_create(&f.w,floor),shape)
    for i in 0..<2 {
        f.walkers[i]=core.create(&f.entities)
        f.chars[i]=sim.character_create(&f.w,sim.CHARACTER_DESC_DEFAULT,{f32(i)*4,0,0})
        f.locos[i]={}
    }
    core.add(&f.paces,f.walkers[0],core.OWN_PACE_DEFAULT)
    core.test_world_settle(&f.rows)
    return true
}

@(private="file")
paced_destroy :: proc(f:^Paced) {
    core.test_world_destroy(&f.rows)
    sim.world_destroy(&f.w)
}

@(private="file")
paced_ticks :: proc(f:^Paced,clock:core.Clock,ticks:int,move:[3]f32,buttons:=input.Action_Mask(0)) {
    for _ in 0..<ticks {
        for i in 0..<2 {
            found:=character_state_of(sim.character_state(&f.w,f.chars[i]))
            given:=input.Move_Input{move=move,buttons=buttons}
            pace:=core.pace_of(clock,core.read(&f.paces),f.walkers[i])
            m:=locomotion_move_paced(&f.locos[i],character_default(),WALK_DEFAULT,{},nil,{},found,1,given,TEST_JUMP,TEST_SPRINT,TEST_CROUCH,sim.character_velocity(&f.w,f.chars[i]),f.w.gravity,1.0/PACED_RATE,pace)
            sim.character_set_move(&f.w,f.chars[i],m)
        }
        sim.world_step(&f.w,1.0/PACED_RATE)
    }
}

// m along -Z each walker goes in a second of the frames: PACED_RATE times the scale of the clock in ticks.
@(private="file")
paced_second :: proc(f:^Paced,clock:core.Clock) -> (went:[2]f32) {
    from:=[2]f32{sim.character_position(&f.w,f.chars[0]).z,sim.character_position(&f.w,f.chars[1]).z}
    paced_ticks(f,clock,int(PACED_RATE*clock.scale),{0,0,-1})
    for i in 0..<2 {went[i]=from[i]-sim.character_position(&f.w,f.chars[i]).z}
    return
}

@(test)
a_character_with_its_own_pace_walks_as_far_in_a_second_whatever_the_time_scale :: proc(t:^testing.T) {
    f:Paced
    if !paced_init(t,&f) {return}
    defer paced_destroy(&f)
    normal:=core.CLOCK_DEFAULT
    slow:=core.Clock{scale=0.25}
    paced_ticks(&f,normal,60,{0,0,-1})
    at_one:=paced_second(&f,normal)
    testing.expectf(t,abs(at_one[0]-WALK_DEFAULT.max_speed)<0.05 && abs(at_one[1]-WALK_DEFAULT.max_speed)<0.05,"at full speed both walk max_speed in a second: %v",at_one)
    // The clock slows while they walk: the one with its own pace keeps its speed from the first tick.
    at_quarter:=paced_second(&f,slow)
    testing.expectf(t,abs(at_quarter[0]-at_one[0])<0.05,"with its own pace it walks as far in a second of the frames at scale 0.25 as at 1: %v and %v",at_quarter[0],at_one[0])
    testing.expectf(t,abs(at_quarter[1]-at_one[1]/4)<0.05,"without one it walks a quarter as far: %v and %v",at_quarter[1],at_one[1])
    // And again at full speed.
    back:=paced_second(&f,normal)
    testing.expectf(t,abs(back[0]-at_one[0])<0.05 && abs(back[1]-at_one[1])<0.05,"back at scale 1 both walk as before: %v",back)
}

@(test)
a_character_with_its_own_pace_jumps_as_high_and_as_long_in_slow_motion :: proc(t:^testing.T) {
    f:Paced
    if !paced_init(t,&f) {return}
    defer paced_destroy(&f)
    slow:=core.Clock{scale=0.25}
    paced_ticks(&f,slow,10,{})
    top:[2]f32
    aloft:[2]int
    jump:=input.action_bit(TEST_JUMP)
    for tick in 0..<240 {
        paced_ticks(&f,slow,1,{},tick==0?jump:0)
        for i in 0..<2 {
            top[i]=max(top[i],sim.character_position(&f.w,f.chars[i]).y)
            if .Standing not_in sim.character_state(&f.w,f.chars[i]).ground {aloft[i]+=1}
        }
    }
    height:=WALK_DEFAULT.jump_height
    testing.expectf(t,abs(top[0]-height)<0.05 && abs(top[1]-height)<0.05,"both reach jump_height: %v",top)
    // In the air for 2*sqrt(2h/g) of their own time: 15 ticks of the slow clock per second of the frames for the one with its own pace, 60 for the other.
    testing.expectf(t,abs(f32(aloft[1])-4*f32(aloft[0]))<=4,"without its own pace it stays in the air four times the ticks: %v",aloft)
}

@(test)
layered_moves_last_their_ticks_of_its_own_time :: proc(t:^testing.T) {
    loco:Locomotion_State
    loco.moves[0]={velocity={0,0,-10},ticks=8,mix=.Override}
    loco.move_count=1
    move:sim.Character_Move
    layers_apply(&loco,&move,800,4)
    testing.expect_value(t,loco.move_count,1)
    layers_apply(&loco,&move,800,4)
    testing.expect_value(t,loco.move_count,0)
    loco.moves[0]={velocity={0,0,-10},ticks=1,mix=.Additive}
    loco.move_count=1
    layers_apply(&loco,&move,800,0.5)
    testing.expect_value(t,loco.move_count,1)
    layers_apply(&loco,&move,800,0.5)
    testing.expect_value(t,loco.move_count,0)
}
