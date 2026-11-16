package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

// The time of a transition: elapsed of its duration, and deficit, the seconds an interrupted one
// left undone, which a transition that interrupts again takes from its own duration.
Inertial_State :: struct {elapsed,duration,deficit:f32,active:bool}
// The offset of a bone from its target per channel (position, rotation as the logarithm of the
// residual, scale), the speed at which the length of each one closes (never away from the target:
// x position, y rotation, z scale) and the seconds at which each one reaches its target.
Inertial_Bone :: struct {position,rotation,scale,speed,end:math.Vec3}
Inertial_Curve :: struct {offset,speed,end:f32}
Inertial_Input :: struct {
    previous,current,target_previous,target:[]math.Transform,
    previous_curves,current_curves,target_previous_curves,target_curves:[]f32,
    dt,duration:f32,
}

@(private)
inertial_rotation_delta :: proc "contextless" (from,to:math.Quat) -> math.Vec3 {
    delta:=conj(from)*to
    if real(delta)<0 {delta=-delta}
    return quat_log(delta)
}

@(private)
inertial_buffers_overlap :: proc "contextless" (a:[]$A,b:[]$B) -> bool {
    if len(a)==0 || len(b)==0 {return false}
    first,second:=uintptr(raw_data(a)),uintptr(raw_data(b))
    return second-first<uintptr(len(a))*size_of(A) if second>=first else first-second<uintptr(len(b))*size_of(B)
}

@(private)
inertial_input_valid :: proc "contextless" (input:Inertial_Input,bones,curves:int) -> bool {
    count:=len(input.current)
    if len(input.previous)!=count || len(input.target)!=count || bones!=count || len(input.target_previous)!=0 && len(input.target_previous)!=count {return false}
    count=len(input.current_curves)
    if len(input.previous_curves)!=count || len(input.target_curves)!=count || curves!=count || len(input.target_previous_curves)!=0 && len(input.target_previous_curves)!=count {return false}
    if !anim_finite(input.dt) || input.dt<0 || !anim_finite(input.duration) || input.duration<0 {return false}
    if !anim_pose_valid(input.previous) || !anim_pose_valid(input.current) || !anim_pose_valid(input.target_previous) || !anim_pose_valid(input.target) {return false}
    for values in ([4][]f32{input.previous_curves,input.current_curves,input.target_previous_curves,input.target_curves}) {for value in values {if !anim_finite(value) {return false}}}
    return true
}

@(private)
inertial_state_valid :: proc "contextless" (state:Inertial_State) -> bool {
    return anim_finite(state.elapsed) && state.elapsed>=0 && anim_finite(state.duration) && state.duration>=0 && anim_finite(state.deficit) && state.deficit>=0
}

// The duration of a transition that starts now and the deficit it leaves: one that interrupts an
// unfinished transition remembers what that one left undone and, when that one had interrupted
// another too, gives it up from its own duration, so transitions that follow each other at every
// tick do not pile up offsets on a target that does not hold still.
@(private)
inertial_begin :: proc "contextless" (state:^Inertial_State,duration:f32) -> (length:f32) {
    length=duration
    deficit:f32
    if state.active && inertial_state_valid(state^) && state.elapsed<state.duration {
        deficit=state.duration-state.elapsed
        if state.deficit>0 {length=max(duration-deficit,0)}
    }
    state^={duration=length,deficit=deficit,active=length>0}
    return
}

// How fast the length of an offset closes given its velocity, never away from zero, and when it
// reaches zero: a fast approach ends before duration so the offset does not overshoot.
@(private)
inertial_close :: proc "contextless" (length,speed,duration:f32) -> (closing,end:f32) {
    closing,end=min(speed,0),duration
    if length>1e-7 && closing< -1e-7 {end=min(end,-5*length/closing)}
    return
}
@(private)
inertial_close_vector :: proc "contextless" (offset,velocity:math.Vec3,duration:f32) -> (closing,end:f32) {
    length:=linalg.length(offset)
    if !(length>1e-7) {return 0,duration}
    return inertial_close(length,linalg.dot(velocity,offset/length),duration)
}

// The length of an offset at t of a fifth-degree curve that starts at x0 with speed v0 (not
// positive) and reaches zero at t1 with no speed or acceleration: its initial acceleration is the
// least that keeps it from crossing zero.
@(private)
inertial_value :: proc "contextless" (x0,v0,t,t1:f32) -> f32 {
    if !(t<t1) || !(t1>0) || !(x0>0) {return 0}
    x,v,s,e:=f64(x0),f64(v0),f64(max(t,0)),f64(t1)
    e2:=e*e;e3:=e2*e;e4:=e3*e;e5:=e4*e
    a:=max(0,(-8*e*v-20*x)/e2)
    c5:=-.5*(a*e2+6*e*v+12*x)/e5
    c4:=.5*(3*a*e2+16*e*v+30*x)/e4
    c3:=-.5*(3*a*e2+12*e*v+20*x)/e3
    return f32(((((c5*s+c4)*s+c3)*s+.5*a)*s+v)*s+x)
}
// The share of an offset that a transition of duration, started at rest, still has at t: 1 when it
// starts and 0 from duration on, along the curve that pose transitions follow. For a value that
// changes along with a pose (a direction its clip travels in), so both arrive together.
inertial_remaining :: proc "contextless" (t,duration:f32) -> f32 {return inertial_value(1,0,t,duration)}
@(private)
inertial_offset :: #force_inline proc "contextless" (offset:math.Vec3,speed,t,end:f32) -> math.Vec3 {
    length:=linalg.length(offset)
    if !(length>1e-7) {return {}}
    return offset*(inertial_value(length,speed,t,end)/length)
}

inertial_capture :: proc "contextless" (state:^Inertial_State,bones:[]Inertial_Bone,curves:[]Inertial_Curve,input:Inertial_Input) -> bool {
    if state==nil || !inertial_input_valid(input,len(bones),len(curves)) {return false}
    probe:=state^
    duration:=inertial_begin(&probe,input.duration)
    for current,i in input.current {
        target:=input.target[i]
        value:=Inertial_Bone{position=current.position-target.position,rotation=inertial_rotation_delta(target.rotation,current.rotation),scale=current.scale-target.scale}
        position_velocity,rotation_velocity,scale_velocity:math.Vec3
        if input.dt>1e-8 {
            previous:=input.previous[i]
            position_velocity=(current.position-previous.position)/input.dt
            scale_velocity=(current.scale-previous.scale)/input.dt
            previous_target:=target
            if len(input.target_previous)>0 {
                previous_target=input.target_previous[i]
                position_velocity-=(target.position-previous_target.position)/input.dt
                scale_velocity-=(target.scale-previous_target.scale)/input.dt
            }
            residual:=conj(target.rotation)*current.rotation;if real(residual)<0 {residual=-residual}
            prior:=conj(previous_target.rotation)*previous.rotation;if linalg.dot(residual,prior)<0 {prior=-prior}
            rotation_velocity=(value.rotation-quat_log(prior))/input.dt
        }
        value.speed.x,value.end.x=inertial_close_vector(value.position,position_velocity,duration)
        value.speed.y,value.end.y=inertial_close_vector(value.rotation,rotation_velocity,duration)
        value.speed.z,value.end.z=inertial_close_vector(value.scale,scale_velocity,duration)
        if !anim_vec3_valid(value.position) || !anim_vec3_valid(value.rotation) || !anim_vec3_valid(value.scale) || !anim_vec3_valid(value.speed) || !anim_vec3_valid(value.end) {return false}
        bones[i]=value
    }
    for current,i in input.current_curves {
        offset:=current-input.target_curves[i]
        velocity:f32
        if input.dt>1e-8 {
            velocity=(current-input.previous_curves[i])/input.dt
            if len(input.target_previous_curves)>0 {velocity-=(input.target_curves[i]-input.target_previous_curves[i])/input.dt}
        }
        closing,end:=inertial_close(abs(offset),velocity if offset>=0 else -velocity,duration)
        value:=Inertial_Curve{offset=offset,speed=closing,end=end}
        if !anim_finite(value.offset) || !anim_finite(value.speed) || !anim_finite(value.end) {return false}
        curves[i]=value
    }
    state^=probe
    return true
}

inertial_advance :: proc "contextless" (state:^Inertial_State,dt:f32) -> bool {
    if state==nil || !anim_finite(dt) || dt<0 || !inertial_state_valid(state^) {return false}
    state.elapsed=f32(min(f64(state.elapsed)+f64(dt),f64(state.duration)))
    state.deficit=0 if state.elapsed>=state.duration else max(state.deficit-dt,0)
    state.active=state.elapsed<state.duration
    return true
}

inertial_pose_apply :: proc "contextless" (state:Inertial_State,bones:[]Inertial_Bone,target,out:[]math.Transform,mask:[]f32=nil) -> bool {
    if len(bones)!=len(target) || len(out)!=len(target) || len(mask)!=0 && len(mask)!=len(target) || !anim_pose_valid(target) {return false}
    if raw_data(target)!=raw_data(out) && inertial_buffers_overlap(target,out) {return false}
    if !inertial_state_valid(state) {return false}
    for value in bones {if !anim_vec3_valid(value.position) || !anim_vec3_valid(value.rotation) || !anim_vec3_valid(value.scale) || !anim_vec3_valid(value.speed) || !anim_vec3_valid(value.end) {return false}}
    for value in mask {if !anim_finite(value) || value<0 || value>1 {return false}}
    t:=state.elapsed if state.active else max(f32)
    for value,i in target {
        delta:=bones[i]
        weight:=mask[i] if len(mask)>0 else f32(1)
        result:=value
        result.position+=inertial_offset(delta.position,delta.speed.x,t,delta.end.x)*weight
        result.rotation=linalg.normalize0(value.rotation*quat_exp(inertial_offset(delta.rotation,delta.speed.y,t,delta.end.y)*weight))
        result.scale+=inertial_offset(delta.scale,delta.speed.z,t,delta.end.z)*weight
        if !anim_transform_valid(result) {return false}
        out[i]=result
    }
    return true
}

inertial_curves_apply :: proc "contextless" (state:Inertial_State,curves:[]Inertial_Curve,target,out:[]f32,filtered:[]bool=nil) -> bool {
    if len(curves)!=len(target) || len(out)!=len(target) || len(filtered)!=0 && len(filtered)!=len(target) {return false}
    if raw_data(target)!=raw_data(out) && inertial_buffers_overlap(target,out) {return false}
    if !inertial_state_valid(state) {return false}
    for value,i in curves {if !anim_finite(value.offset) || !anim_finite(value.speed) || !anim_finite(value.end) || !anim_finite(target[i]) {return false}}
    t:=state.elapsed if state.active else max(f32)
    for value,i in curves {
        result:=target[i]
        if len(filtered)==0 || !filtered[i] {result+=cmath.sign(value.offset)*inertial_value(abs(value.offset),value.speed,t,value.end)}
        if !anim_finite(result) {return false}
        out[i]=result
    }
    return true
}
