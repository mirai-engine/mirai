package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

// Root motion: how a target of a clip (its root) moved and turned between two
// positions of the playback timeline, so that a game moves the body that plays
// the clip by that much instead of letting the clip carry it away. A looping
// clip adds the motion of a whole pass every time it wraps; a Once or
// ping-pong playback moves by the difference of where the root is. The
// movement is in the space of the clip: the caller turns it by the body. A
// looping span of more than 2^62 passes, or not finite, moves nothing.
clip_root_motion :: proc "contextless" (lib:^Library,clip:Clip,root:u64,from,to:f32) -> (moved:math.Vec3,turned:math.Quat) {
    turned=1
    if !clip_valid(lib,clip) {return}
    data:=clip_data(lib,clip)
    position,rotation:Track
    has_position,has_rotation:bool
    for track in clip_tracks(lib,clip) {
        if track.target!=root {continue}
        if track.property==.Position {position,has_position=track,true}
        if track.property==.Rotation {rotation,has_rotation=track,true}
    }
    at :: proc "contextless" (lib:^Library,track:Track,time:f32) -> math.Vec4 {return clip_evaluate(lib,track,time)}
    if data.loop!=.Loop || !(data.duration>0) {
        a,_:=loop_time(data.loop,data.duration,from)
        b,_:=loop_time(data.loop,data.duration,to)
        if has_position {moved=(at(lib,position,b)-at(lib,position,a)).xyz}
        if has_rotation {turned=linalg.normalize0(conj(vec4_quat(at(lib,rotation,a)))*vec4_quat(at(lib,rotation,b)))}
        return
    }
    // Forward or backward, the passes the playback crosses between the two positions.
    duration:=data.duration
    wraps:=cmath.floor(to/duration)-cmath.floor(from/duration)
    if !(abs(wraps)<=1<<62) {return}
    a,b:=loop_wrap(from,duration),loop_wrap(to,duration)
    if has_position {
        cycle:=(at(lib,position,duration)-at(lib,position,0)).xyz
        moved=(at(lib,position,b)-at(lib,position,a)).xyz+cycle*wraps
    }
    if has_rotation {
        start,end:=vec4_quat(at(lib,rotation,0)),vec4_quat(at(lib,rotation,duration))
        turned=conj(vec4_quat(at(lib,rotation,a)))
        if wraps!=0 {
            // The passes between the first and the last one crossed.
            middle:=quat_power(conj(start)*end,u64(abs(wraps))-1)
            if wraps>0 {turned*=end*middle*conj(start)} else {turned*=start*conj(middle)*conj(end)}
        }
        turned=linalg.normalize0(turned*vec4_quat(at(lib,rotation,b)))
    }
    return
}
// q to the power n, by squaring.
@(private)
quat_power :: proc "contextless" (q:math.Quat,n:u64) -> math.Quat {
    result:math.Quat=1
    base,n:=q,n
    for n>0 {
        if n&1==1 {result=linalg.normalize0(result*base)}
        base=linalg.normalize0(base*base)
        n>>=1
    }
    return result
}

// The root motion of the next player_advance of p by dt: call it before.
player_root_motion :: proc "contextless" (lib:^Library,p:Player,root:u64,dt:f32) -> (moved:math.Vec3,turned:math.Quat) {
    if !clip_valid(lib,p.clip) || p.done {return {},1}
    return clip_root_motion(lib,p.clip,root,p.time,p.time+dt*p.speed)
}

// The root motion of a fader: that of every clip it plays, by its weight halfway through dt.
fader_root_motion :: proc "contextless" (lib:^Library,fader:Fader,target:u64,dt:f32,current_dt:f32=-1) -> (position:math.Vec3,rotation:math.Quat) {
    fader:=fader
    rotation=1
    if fader.outgoing_count<0 || fader.outgoing_count>len(fader.outgoing) || !anim_finite(dt) || !anim_finite(current_dt) || current_dt< -1 {return}
    center:=fader
    center.elapsed+=abs(dt)*0.5
    for &outgoing in center.outgoing[:center.outgoing_count] {outgoing.elapsed+=abs(dt)*0.5}
    p,q:=player_root_motion(lib,fader.current,target,current_dt if current_dt>=0 else dt)
    weight:=fader_current_weight(center)
    position=p*weight
    sum:=quat_vec4(q)*weight
    total:=weight
    for outgoing,i in fader.outgoing[:fader.outgoing_count] {
        weight=fade_out_weight(center.outgoing[i])
        if weight<=0 {continue}
        p,q=player_root_motion(lib,outgoing.player,target,dt)
        value:=quat_vec4(q)
        if total>0 {value=quat_align(value,sum)}
        position+=p*weight;sum+=value*weight;total+=weight
    }
    if total>0 {position/=total;rotation=linalg.normalize0(vec4_quat(sum))}
    return
}
