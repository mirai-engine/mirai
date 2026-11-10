package core

import mm "mirai:std/math"

// Waiting is a tick: the tick something is due at, kept as plain data in a
// component or a storage, so it is copied, rolled back and saved with what
// holds it. A wait given in seconds lasts the same at any tick rate, and a row
// is written when the wait starts and when it ends, not on every tick.

// A deadline that never comes.
NEVER :: max(u64)

// The ticks that `seconds` last on the clock: 0 when seconds is not above 0,
// or when the clock does not advance (dt 0, as in the editor loop).
ticks_of :: proc "contextless" (time:Time,seconds:f32) -> u64 {return mm.ticks_of(f64(seconds),time.dt)}

// The seconds that `ticks` ticks last.
seconds_of :: proc "contextless" (time:Time,ticks:u64) -> f32 {return f32(f64(ticks)*f64(time.dt))}

// The tick that comes `seconds` from this one: this one when seconds is not
// above 0, the next one at the earliest when it is, NEVER when it is past
// what a tick counts.
deadline :: proc "contextless" (time:Time,seconds:f32) -> u64 {
    if !(seconds>0) {return time.tick}
    ticks:=max(ticks_of(time,seconds),1)
    return ticks>NEVER-time.tick?NEVER:time.tick+ticks
}

// Whether the tick `at` has come. A deadline nobody set, 0, has.
due :: proc "contextless" (time:Time,at:u64) -> bool {return time.tick>=at}

// The seconds since the tick `since`; 0 when it has not come.
elapsed :: proc "contextless" (time:Time,since:u64) -> f32 {return time.tick>since?seconds_of(time,time.tick-since):0}

// The clock as e lives it: its dt is the seconds of the own time of e in a
// tick (Own_Pace). A deadline or an elapsed time asked of it counts the time
// of e at the pace it has now; what must follow a pace that changes during
// the wait adds its own time up tick by tick.
own_time :: proc "contextless" (time:Time,clock:Clock,paces:Read(Own_Pace),e:Entity) -> Time {
    own:=time
    own.dt*=pace_of(clock,paces,e)
    return own
}
