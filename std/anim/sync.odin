package mirai_anim

import math "mirai:std/math"

// Where a clip is in its cycle, to put another clip at the same point: between
// the same two markers when both have them, at the same fraction otherwise.
// Spans (markers with a duration) do not mark the cycle.
Sync_Phase :: struct {previous,next:u32,fraction,normalized:f32,markers:bool}

sync_phase :: proc "contextless" (lib:^Library,player:Player) -> (Sync_Phase,bool) {
    duration:=clip_duration(lib,player.clip)
    if !(duration>0) || !anim_finite(duration) || !anim_finite(player.time) {return {},false}
    time:=player_time(lib,player)
    phase:=Sync_Phase{normalized=time/duration}
    markers:=clip_markers(lib,player.clip)
    previous,last,points:=-1,-1,0
    for marker,i in markers {if marker.duration>0 {continue};points+=1;last=i;if marker.time<=time {previous=i}}
    if points<2 {return phase,true}
    if previous<0 {previous=last}
    next:=point_after(markers,previous)
    start,end:=markers[previous].time,markers[next].time
    if next<=previous {end+=duration}
    sample:=time
    if sample<start {sample+=duration}
    if !(end>start) {return phase,true}
    phase.previous,phase.next=markers[previous].id,markers[next].id
    phase.fraction=(sample-start)/(end-start)
    phase.markers=true
    return phase,true
}

sync_time :: proc "contextless" (lib:^Library,clip:Clip,phase:Sync_Phase) -> (f32,bool) {
    duration:=clip_duration(lib,clip)
    if !(duration>0) || !anim_finite(duration) || !anim_finite(phase.normalized) || !anim_finite(phase.fraction) {return 0,false}
    if phase.markers {
        markers:=clip_markers(lib,clip)
        for marker,i in markers {
            if marker.duration>0 {continue}
            next:=point_after(markers,i)
            if marker.id!=phase.previous || markers[next].id!=phase.next {continue}
            end:=markers[next].time
            if next<=i {end+=duration}
            time:=marker.time+(end-marker.time)*math.saturate(phase.fraction)
            if clip_data(lib,clip).loop==.Once {return clamp(time,0,duration),true}
            return loop_wrap(time,duration),true
        }
    }
    return math.saturate(phase.normalized)*duration,true
}

player_synchronize :: proc "contextless" (lib:^Library,player:^Player,phase:Sync_Phase) -> bool {
    time,ok:=sync_time(lib,player.clip,phase)
    if !ok {return false}
    player.time=time
    player.fresh=false
    player.done=false
    return true
}

// The point marker after index i, round the clip.
@(private="file")
point_after :: proc "contextless" (markers:[]Marker,i:int) -> int {
    for step in 1..=len(markers) {if j:=(i+step)%len(markers);markers[j].duration==0 {return j}}
    return i
}
