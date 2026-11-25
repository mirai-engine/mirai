package core

import "core:math"
import "core:testing"

// A wait asked in seconds lasts the same whatever the tick rate: the deadline
// is the tick that many seconds away, due from then on and not before.
@(test)
a_deadline_lasts_the_same_seconds_at_any_tick_rate :: proc(t:^testing.T) {
    for seconds in ([]f32{0.3,1,2.5,0.05}) {
        lasted:[3]f32
        for rate,i in ([3]f32{60,120,30}) {
            time:=Time{tick=1000,dt=1/rate,playing=true}
            at:=deadline(time,seconds)
            ticks:=0
            for !due(time,at) {
                time_advance(&time)
                ticks+=1
                if ticks>100000 {break}
            }
            lasted[i]=f32(ticks)/rate
            testing.expectf(t,abs(lasted[i]-seconds)<=0.5/rate+1e-4,"%v s at %v Hz lasted %v s",seconds,rate,lasted[i])
            testing.expectf(t,abs(elapsed(time,1000)-lasted[i])<1e-4,"%v s elapsed, %v s lasted",elapsed(time,1000),lasted[i])
            testing.expect_value(t,ticks_of(time,seconds),u64(ticks))
            testing.expect(t,abs(seconds_of(time,u64(ticks))-lasted[i])<1e-4)
        }
        testing.expectf(t,abs(lasted[0]-lasted[1])<=0.5/60+1e-4,"%v s lasted %v s at 60 Hz and %v s at 120 Hz",seconds,lasted[0],lasted[1])
    }
}

// What cannot be waited does not wait, and nothing overflows: seconds that
// are no number or not above 0 are due at once, a clock that does not advance
// waits one tick, and more than a tick counts never comes.
@(test)
a_deadline_of_seconds_that_cannot_be_waited_is_due_or_never :: proc(t:^testing.T) {
    nan:=math.nan_f32()
    time:=Time{tick=50,dt=1.0/60}
    for seconds in ([]f32{0,-1,nan,math.inf_f32(-1)}) {
        testing.expect_value(t,deadline(time,seconds),u64(50))
        testing.expect_value(t,ticks_of(time,seconds),u64(0))
    }
    testing.expect_value(t,deadline(time,math.inf_f32(1)),NEVER)
    testing.expect_value(t,deadline(time,max(f32)),NEVER)
    testing.expect_value(t,deadline(Time{tick=NEVER-1,dt=1},10),NEVER)
    testing.expect_value(t,deadline(time,1e-9),u64(51))
    for dt in ([]f32{0,-1,nan}) {
        stopped:=Time{tick=50,dt=dt}
        testing.expect_value(t,deadline(stopped,3),u64(51))
        testing.expect_value(t,ticks_of(stopped,3),u64(0))
    }
    testing.expect(t,due(time,0) && due(time,50) && !due(time,51) && !due(time,NEVER))
    testing.expect_value(t,elapsed(time,51),f32(0))
    testing.expect_value(t,elapsed(time,NEVER),f32(0))
}

@(private) @(test_world) Paced_World :: struct {using world:Test_World,paces:Table(Own_Pace)}

// An entity with a pace of its own waits its own seconds: twice as fast, half the ticks.
@(test)
a_deadline_on_the_own_time_of_an_entity_counts_its_pace :: proc(t:^testing.T) {
    w:Paced_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    fast,plain:=create(&w.entities),create(&w.entities)
    add(&w.paces,fast,Own_Pace{rate=2})
    test_world_settle(&w)
    time:=Time{tick=10,dt=1.0/60}
    clock:=CLOCK_DEFAULT
    testing.expect_value(t,deadline(own_time(time,clock,&w.paces,fast),1),u64(40))
    testing.expect_value(t,deadline(own_time(time,clock,&w.paces,plain),1),u64(70))
    // In slow motion it keeps its pace: the ticks of the world last half as long for the others.
    clock.scale=0.5
    testing.expect_value(t,deadline(own_time(time,clock,&w.paces,fast),1),u64(25))
    time.tick=40
    testing.expect(t,abs(elapsed(own_time(time,clock,&w.paces,fast),10)-2)<1e-4)
}

// A Cooldown and a Countdown asked in seconds last the same at any tick rate:
// ready, running, due and progress follow the seconds, not the ticks.
@(test)
cooldowns_and_countdowns_last_the_same_seconds_at_any_tick_rate :: proc(t:^testing.T) {
    Case :: struct {seconds:f32,at:f32,ready,running,ended:bool,progress:f32}
    cases:=[]Case{
        {seconds=1,at=0.5,ready=false,running=true,ended=false,progress=0.5},
        {seconds=1,at=0.25,ready=false,running=true,ended=false,progress=0.25},
        {seconds=1,at=1,ready=true,running=false,ended=true,progress=1},
        {seconds=0.5,at=2,ready=true,running=false,ended=true,progress=1},
        {seconds=0,at=0,ready=true,running=false,ended=true,progress=1},
    }
    for c in cases {
        for rate in ([]f32{30,60,120,240}) {
            time:=Time{tick=500,dt=1/rate,playing=true}
            cooldown:Cooldown
            countdown:Countdown
            cooldown_start(&cooldown,time,c.seconds)
            countdown_start(&countdown,time,c.seconds)
            time.tick+=u64(math.round(c.at*rate))
            testing.expectf(t,cooldown_ready(cooldown,time)==c.ready,"%v at %v Hz: ready",c,rate)
            testing.expectf(t,countdown_running(countdown,time)==c.running,"%v at %v Hz: running",c,rate)
            testing.expectf(t,countdown_ended(countdown,time)==c.ended,"%v at %v Hz: ended",c,rate)
            near:=0.5/rate+1e-4 // the seconds round to whole ticks
            testing.expectf(t,abs(countdown_progress(countdown,time)-c.progress)<=near,"%v at %v Hz: progress %v",c,rate,countdown_progress(countdown,time))
            testing.expectf(t,abs(countdown_elapsed(countdown,time)-min(c.at,c.seconds))<=near,"%v at %v Hz: elapsed",c,rate)
            left:=max(c.seconds-c.at,0)
            testing.expectf(t,abs(cooldown_remaining(cooldown,time)-left)<=near && abs(countdown_remaining(countdown,time)-left)<=near,"%v at %v Hz: remaining",c,rate)
        }
    }
}

// The zero values wait for nothing: a Cooldown is ready and a Countdown is not
// running, ended, due or progressing; a stopped Countdown is its zero value.
@(test)
cooldown_and_countdown_zero_values_are_ready_and_not_running :: proc(t:^testing.T) {
    for tick in ([]u64{0,1,1000,NEVER-1}) {
        time:=Time{tick=tick,dt=1.0/60}
        testing.expect(t,cooldown_ready(Cooldown{},time) && cooldown_remaining(Cooldown{},time)==0)
        zero:Countdown
        testing.expect(t,!countdown_running(zero,time) && !countdown_due(zero,time) && !countdown_ended(zero,time))
        testing.expect(t,countdown_progress(zero,time)==0 && countdown_elapsed(zero,time)==0 && countdown_remaining(zero,time)==0)
        countdown_start(&zero,time,1)
        countdown_stop(&zero)
        testing.expect_value(t,zero,Countdown{})
    }
    cooldown_start(nil,{},1)
    countdown_start(nil,{},1)
    countdown_stop(nil)
}

// A wait is plain data: a copy taken mid-wait (a world copy, a snapshot a
// rollback restores) answers as the original at every tick, the tick it ends
// is due once, and no answer changes the value.
@(test)
cooldowns_and_countdowns_survive_a_copy_and_a_rollback :: proc(t:^testing.T) {
    time:=Time{tick=10,dt=0.125,playing=true}
    cooldown:Cooldown
    countdown:Countdown
    cooldown_start(&cooldown,time,0.5)
    countdown_start(&countdown,time,0.5)
    time_advance(&time)
    time_advance(&time)
    kept_cooldown,kept_countdown:=cooldown,countdown
    due_ticks:=0
    for tick in u64(12)..=u64(20) {
        time.tick=tick
        testing.expect_value(t,cooldown_ready(kept_cooldown,time),cooldown_ready(cooldown,time))
        testing.expect_value(t,countdown_progress(kept_countdown,time),countdown_progress(countdown,time))
        if countdown_due(countdown,time) {due_ticks+=1}
    }
    testing.expect_value(t,due_ticks,1)
    testing.expect(t,kept_cooldown==cooldown && kept_countdown==countdown)
    // Rolled back to the tick of the copy, the waits answer as they did then.
    time.tick,time.resimulating=12,true
    testing.expect(t,!cooldown_ready(kept_cooldown,time) && countdown_running(kept_countdown,time))
    testing.expect_value(t,countdown_progress(kept_countdown,time),f32(0.5))
    testing.expect(t,countdown_due(kept_countdown,{tick=14,dt=0.125}) && cooldown_ready(kept_cooldown,{tick=14,dt=0.125}))
}
