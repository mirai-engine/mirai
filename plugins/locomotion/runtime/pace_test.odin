package locomotion

import "core:testing"
import "mirai:core"
import phys "plugins:physics/runtime"

@(private="file")
PACED_RATE :: 60 // ticks per second the walkers step at

// Two walkers on a floor under one clock, the first with an Own_Pace of rate 1.
@(private="file")
paced_init :: proc(t:^testing.T,f:^Loco_Test) -> (walkers:[2]core.Entity,ok:bool) {
    if !loco_test_init(t,f,{0,0,0}) {return}
    walkers={f.e,loco_test_walker(f,{4,0,0})}
    core.add(&f.paces,walkers[0],core.OWN_PACE_DEFAULT)
    return walkers,true
}

// m along -Z each walker goes in a second of the frames: PACED_RATE times the scale of the clock in ticks.
@(private="file")
paced_second :: proc(f:^Loco_Test,walkers:[2]core.Entity,clock:core.Clock) -> (went:[2]f32) {
    from:=[2]f32{loco_position(f,walkers[0]).z,loco_position(f,walkers[1]).z}
    loco_test_tick(f,{0,0,-1},int(PACED_RATE*clock.scale),clock=clock)
    for i in 0..<2 {went[i]=from[i]-loco_position(f,walkers[i]).z}
    return
}

@(test)
a_character_with_its_own_pace_walks_as_far_in_a_second_whatever_the_time_scale :: proc(t:^testing.T) {
    f:Loco_Test
    walkers,ok:=paced_init(t,&f)
    if !ok {return}
    defer loco_test_destroy(&f)
    normal:=core.CLOCK_DEFAULT
    slow:=core.Clock{scale=0.25}
    loco_test_tick(&f,{0,0,-1},60)
    at_one:=paced_second(&f,walkers,normal)
    testing.expectf(t,abs(at_one[0]-WALK_DEFAULT.max_speed)<0.05 && abs(at_one[1]-WALK_DEFAULT.max_speed)<0.05,"at full speed both walk max_speed in a second: %v",at_one)
    // The clock slows while they walk: the one with its own pace keeps its speed from the first tick.
    at_quarter:=paced_second(&f,walkers,slow)
    testing.expectf(t,abs(at_quarter[0]-at_one[0])<0.05,"with its own pace it walks as far in a second of the frames at scale 0.25 as at 1: %v and %v",at_quarter[0],at_one[0])
    testing.expectf(t,abs(at_quarter[1]-at_one[1]/4)<0.05,"without one it walks a quarter as far: %v and %v",at_quarter[1],at_one[1])
    // And again at full speed.
    back:=paced_second(&f,walkers,normal)
    testing.expectf(t,abs(back[0]-at_one[0])<0.05 && abs(back[1]-at_one[1])<0.05,"back at scale 1 both walk as before: %v",back)
}

@(test)
a_character_with_its_own_pace_jumps_as_high_and_as_long_in_slow_motion :: proc(t:^testing.T) {
    f:Loco_Test
    walkers,ok:=paced_init(t,&f)
    if !ok {return}
    defer loco_test_destroy(&f)
    slow:=core.Clock{scale=0.25}
    loco_test_tick(&f,{},10,clock=slow)
    top:[2]f32
    aloft:[2]int
    for tick in 0..<240 {
        loco_test_tick(&f,{},1,JUMP if tick==0 else 0,clock=slow)
        for e,i in walkers {
            top[i]=max(top[i],loco_position(&f,e).y)
            if !loco_found(&f,e).standing {aloft[i]+=1}
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
    move:phys.Character_Drive
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
