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

// An entity with a pace of its own waits its own seconds: twice as fast, half the ticks.
@(test)
a_deadline_on_the_own_time_of_an_entity_counts_its_pace :: proc(t:^testing.T) {
    w:struct {using world:Test_World,paces:Table(Own_Pace)}
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    fast,plain:=create(&w.entities),create(&w.entities)
    add(&w.paces,fast,Own_Pace{rate=2})
    test_world_settle(&w)
    time:=Time{tick=10,dt=1.0/60}
    clock:=CLOCK_DEFAULT
    testing.expect_value(t,deadline(own_time(time,clock,read(&w.paces),fast),1),u64(40))
    testing.expect_value(t,deadline(own_time(time,clock,read(&w.paces),plain),1),u64(70))
    // In slow motion it keeps its pace: the ticks of the world last half as long for the others.
    clock.scale=0.5
    testing.expect_value(t,deadline(own_time(time,clock,read(&w.paces),fast),1),u64(25))
    time.tick=40
    testing.expect(t,abs(elapsed(own_time(time,clock,read(&w.paces),fast),10)-2)<1e-4)
}
