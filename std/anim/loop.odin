package mirai_anim

import cmath "core:math"

// What a playback does when it reaches the end of its duration.
Loop :: enum u8 {Once,Loop,Ping_Pong}

// Playback time is a position on an unbounded timeline: a pass is one length
// of the duration, and a ping-pong plays its odd passes backwards. loop_time
// maps it to the time inside the clip and tells whether a Once playback ended.
loop_time :: proc "contextless" (loop:Loop,duration,time:f32) -> (clip_time:f32,finished:bool) {
    if duration<=0 {return 0,true}
    switch loop {
    case .Once: return clamp(time,0,duration),time>=duration
    case .Loop: return loop_wrap(time,duration),false
    case .Ping_Pong:
        folded:=loop_wrap(time,2*duration)
        return folded if folded<=duration else 2*duration-folded,false
    }
    return 0,true
}
// The timeline position folded into [0, period).
loop_wrap :: proc "contextless" (time,period:f32) -> f32 {
    wrapped:=time-cmath.floor(time/period)*period
    // Rounding, or a time too many periods away to tell where it falls, can leave it outside.
    return wrapped if wrapped>=0 && wrapped<period else 0
}
// Length of the timeline a playback repeats over: 0 for Once.
loop_period :: proc "contextless" (loop:Loop,duration:f32) -> f32 {
    switch loop {
    case .Once: return 0
    case .Loop: return duration
    case .Ping_Pong: return 2*duration
    }
    return 0
}
