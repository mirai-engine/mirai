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
own_time :: proc "contextless" (time:Time,clock:Clock,paces:^Table(Own_Pace,$A),e:Entity) -> Time {
    own:=time
    own.dt*=pace_of(clock,paces,e)
    return own
}

// A wait that is ready at a tick, as a named field of a component (a gun's
// next shot, a dash): ready by its zero value, written when it starts.
Cooldown :: struct {
    ready_at:u64 `mirai:"readonly"`, // the tick it is ready at; 0: ready
}

cooldown_start :: proc "contextless" (c:^Cooldown,time:Time,seconds:f32) {
    if c!=nil {c.ready_at=deadline(time,seconds)}
}

cooldown_ready :: proc "contextless" (c:Cooldown,time:Time) -> bool {return due(time,c.ready_at)}

// The seconds until it is ready; 0 when it is.
cooldown_remaining :: proc "contextless" (c:Cooldown,time:Time) -> f32 {
    return due(time,c.ready_at)?0:seconds_of(time,c.ready_at-time.tick)
}

// A wait with a start and an end, as a named field of a component (a hold,
// a fuse, a round): not running by its zero value, written when it starts and
// when it is stopped, never while it runs. Once its end comes it stays ended
// until it is started again or stopped.
Countdown :: struct {
    started:u64 `mirai:"readonly"`, // the tick it started at
    ends:u64 `mirai:"readonly"`,    // the tick it ends at
    active:bool `mirai:"readonly"`, // started and not stopped
}

countdown_start :: proc "contextless" (c:^Countdown,time:Time,seconds:f32) {
    if c!=nil {c^={started=time.tick,ends=deadline(time,seconds),active=true}}
}

countdown_stop :: proc "contextless" (c:^Countdown) {
    if c!=nil {c^={}}
}

// Started and its end has not come.
countdown_running :: proc "contextless" (c:Countdown,time:Time) -> bool {return c.active && time.tick<c.ends}

// The one tick it ends at: what runs every tick sees it once, with no write.
countdown_due :: proc "contextless" (c:Countdown,time:Time) -> bool {return c.active && time.tick==c.ends}

// Its end has come, from that tick until it is started again or stopped.
countdown_ended :: proc "contextless" (c:Countdown,time:Time) -> bool {return c.active && time.tick>=c.ends}

// The seconds it has run, up to its end; 0 when it is not active.
countdown_elapsed :: proc "contextless" (c:Countdown,time:Time) -> f32 {
    if !c.active || time.tick<=c.started {return 0}
    return seconds_of(time,min(time.tick,c.ends)-c.started)
}

// The seconds until its end; 0 when it is not running.
countdown_remaining :: proc "contextless" (c:Countdown,time:Time) -> f32 {
    return countdown_running(c,time)?seconds_of(time,c.ends-time.tick):0
}

// How far it has run, from 0 at its start to 1 at its end; 0 when it is not
// active.
countdown_progress :: proc "contextless" (c:Countdown,time:Time) -> f32 {
    if !c.active {return 0}
    if time.tick>=c.ends {return 1}
    if time.tick<=c.started {return 0}
    return f32(f64(time.tick-c.started)/f64(c.ends-c.started))
}
