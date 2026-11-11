package mirai_anim

import cmath "core:math"

// A marker reported by a player: `clip` and `id` of the marker, the clip
// `time` it sits at, and the `weight` of the player that crossed it.
Event :: struct {
    clip:Clip,
    id:u32,
    time:f32,
    weight:f32,
    fraction:f32, // of the requested advance where it was crossed, also when a Once clip clamps it
}

// The playback of one clip. Plain data: copy it to snapshot it. `time` is the
// position on the playback timeline (see loop_time), kept reduced to one
// period so long playbacks do not lose precision. A negative speed plays
// backwards.
Player :: struct {
    clip:Clip,
    time:f32,
    speed:f32,
    weight:f32,
    fresh:bool, // nothing was advanced yet: the start counts as crossed
    done:bool,  // a Once playback reached the end it was heading to
}

MAX_PASSES_PER_ADVANCE :: 1024
@(private) PASS_LIMIT :: 1<<40

player_make :: proc "contextless" (clip:Clip,speed:f32=1,weight:f32=1) -> Player {
    return {clip=clip,speed=speed,weight=weight,fresh=true}
}
// Restarts at the beginning (or the end, for a negative speed) without touching speed or weight.
player_restart :: proc "contextless" (lib:^Library,p:^Player) {
    p.time=clip_duration(lib,p.clip) if p.speed<0 && clip_data(lib,p.clip).loop==.Once else 0
    p.fresh=true;p.done=false
}
// The time inside the clip, from 0 to its duration.
player_time :: proc "contextless" (lib:^Library,p:Player) -> f32 {
    data:=clip_data(lib,p.clip)
    time,_:=loop_time(data.loop,data.duration,p.time)
    return time
}
// The time inside the clip as a fraction of its duration.
player_normalized :: proc "contextless" (lib:^Library,p:Player) -> f32 {
    data:=clip_data(lib,p.clip)
    if data.duration<=0 {return 1}
    time,_:=loop_time(data.loop,data.duration,p.time)
    return time/data.duration
}

// Moves the playback by dt*speed and writes the markers it crossed, in the
// order it crossed them, to `events`. Returns how many were written and how
// many did not fit. A marker is crossed when playback passes it going in its
// direction; the start of a playback counts once, and in a loop the markers at
// the start and at the end of a pass each fire once per pass.
player_advance :: proc "contextless" (lib:^Library,p:^Player,dt:f32,events:[]Event) -> (written,dropped:int) {
    if !clip_valid(lib,p.clip) || p.done {p.fresh=false;return}
    data:=lib.clips[p.clip-1]
    from:=p.time
    to:=from+dt*p.speed
    if data.loop==.Once {
        to=clamp(to,0,data.duration)
        p.done=(to>=data.duration && p.speed>=0 && dt*p.speed>0) || (to<=0 && p.speed<0 && dt*p.speed<0)
    }
    if data.marker_count>0 && data.duration>0 {
        fire_markers(lib,p.clip,p.weight,data,from,to,dt*p.speed,p.fresh,events,&written,&dropped)
    }
    p.fresh=false
    p.time=to
    if period:=loop_period(data.loop,data.duration);period>0 {p.time=loop_wrap(to,period)}
    return
}

@(private)
fire_markers :: proc "contextless" (lib:^Library,clip:Clip,weight:f32,data:Clip_Data,from,to,span:f32,fresh:bool,events:[]Event,written,dropped:^int) {
    markers:=lib.markers[data.first_marker:][:data.marker_count]
    duration:=data.duration
    forward:=to>=from
    low,high:=min(from,to),max(from,to)
    // A span of more passes than PASS_LIMIT counts as that many: beyond it a float does not tell one pass
    // from the next, and what it converts to as an integer is not a number of passes.
    pass_of :: proc "contextless" (position,duration:f32) -> int {
        pass:=cmath.floor(position/duration)
        return int(clamp(pass,-PASS_LIMIT,PASS_LIMIT)) if pass==pass else 0
    }
    first_pass,last_pass:=pass_of(low,duration),pass_of(high,duration)
    if data.loop==.Once {first_pass,last_pass=0,0}
    if last_pass-first_pass>=MAX_PASSES_PER_ADVANCE {
        skipped:=last_pass-first_pass-MAX_PASSES_PER_ADVANCE+1
        dropped^+=skipped*len(markers)
        if forward {first_pass+=skipped} else {last_pass-=skipped}
    }
    entry_inclusive:=data.loop==.Loop
    count:=last_pass-first_pass+1
    for step in 0..<count {
        pass:=first_pass+step if forward else last_pass-step
        first_of_span:=step==0
        offset:=f32(pass)*duration
        x_low,x_high:=max(low-offset,0),min(high-offset,duration)
        reversed:=data.loop==.Ping_Pong && pass&1==1
        // The bound the playback enters the pass through is inclusive only at a jump (loop) or at the very start.
        enters_low:=forward
        low_inclusive:=(fresh if first_of_span else entry_inclusive) if enters_low else true
        high_inclusive:=true if enters_low else (fresh if first_of_span else entry_inclusive)
        ascending:=forward!=reversed
        for k in 0..<len(markers) {
            index:=k if ascending else len(markers)-1-k
            marker:=markers[index]
            x:=duration-marker.time if reversed else marker.time
            if x<x_low || x>x_high {continue}
            if x==x_low && !low_inclusive {continue}
            if x==x_high && !high_inclusive {continue}
            if written^<len(events) {
                fraction:=clamp((offset+x-from)/span,0,1) if span!=0 else 0
                events[written^]={clip=clip,id=marker.id,time=marker.time,weight=weight,fraction=fraction}
                written^+=1
            } else {dropped^+=1}
        }
    }
}
