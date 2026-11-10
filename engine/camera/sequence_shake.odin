package camera

import "core:math"
import "mirai:core"
import render "mirai:engine/render"
import mm "mirai:std/math"

// A camera shake authored as keys (a camera animation): the angles it adds to the view, and the
// field of view it adds to a perspective lens, along its own time, played at a rate, scaled, and
// blended in and out. Unlike Shake (trauma and noise), it
// moves the view the same way every time, as a swing or a landing asks. camera_shake asks a camera
// for one; camera_follow, the only writer of the camera, plays it over the rotation it gives the
// view, in the axes of the view: pitch up, yaw to its left and roll counterclockwise as seen, all
// positive.

SHAKE_SEQUENCE_KEYS :: 16
CAMERA_SHAKES :: 4
// The field of view a shake leaves a perspective lens within, radians: render.Camera takes 0 as its
// default and needs less than pi.
SHAKE_FOV_MIN :: 1*mm.RAD_PER_DEG
SHAKE_FOV_MAX :: 179*mm.RAD_PER_DEG

// A key of a channel: its value at time (seconds of the sequence) and the slope it passes with
// (per second of the sequence; 0 is flat). Between two keys the value is the cubic Hermite of
// both.
Shake_Key :: struct {
    time:f32 `mirai:"min=0,unit=s"`,
    value:f32 `mirai:"angle"`,
    slope:f32 `mirai:"unit=1/s"`,
}

Shake_Channel :: struct {
    keys:[SHAKE_SEQUENCE_KEYS]Shake_Key,
    count:u8, // keys used, in order of time
}

Shake_Sequence :: struct {
    pitch,yaw,roll:Shake_Channel,
    fov:Shake_Channel,                    // radians added to the vertical field of view of a perspective lens
    length:f32 `mirai:"min=0,unit=s"`,    // of the sequence; it ends there
    rate:f32 `mirai:"min=0"`,             // sequence seconds per second; 0: 1
    scale:f32,                            // of its angles
    blend_in,blend_out:f32 `mirai:"min=0,unit=s"`, // seconds of play to reach its full weight and to leave it
    single:bool,                          // asked again while it plays, it starts over instead of adding another
    id:u32,                               // what single compares; given by the game
}

Shake_Playing :: struct {
    sequence:Shake_Sequence,
    time:f32, // seconds of play since it started
}

Shake_Request :: struct {
    camera:core.Entity,
    sequence:Shake_Sequence,
}

@(storage,queue)
Camera_Shakes :: struct {
    queue:core.Queue(Shake_Request),
}

// Asks camera to play sequence over its view. A camera that already plays CAMERA_SHAKES of them
// drops the one nearest its end.
camera_shake :: proc(shakes:^Camera_Shakes,camera:core.Entity,sequence:Shake_Sequence) {
    core.push(&shakes.queue,Shake_Request{camera,sequence})
}

// The value of a channel at time t of its sequence: the first value before its first key and the
// last after its last.
shake_channel_at :: proc "contextless" (c:Shake_Channel,t:f32) -> f32 {
    count:=int(min(c.count,SHAKE_SEQUENCE_KEYS))
    if count==0 {return 0}
    if t<=c.keys[0].time {return c.keys[0].value}
    for i in 1..<count {
        a,b:=c.keys[i-1],c.keys[i]
        if t>b.time {continue}
        span:=b.time-a.time
        if !(span>0) {return b.value}
        u:=(t-a.time)/span
        u2,u3:=u*u,u*u*u
        return (2*u3-3*u2+1)*a.value+(u3-2*u2+u)*span*a.slope+(-2*u3+3*u2)*b.value+(u3-u2)*span*b.slope
    }
    return c.keys[count-1].value
}

// The weight of a shake that has played time seconds: up over blend_in, down over the last
// blend_out of its length at its rate; 0 when it ended.
shake_weight :: proc "contextless" (s:Shake_Sequence,time:f32) -> f32 {
    rate:=s.rate if s.rate>0 else 1
    length:=s.length/rate
    if !(time<length) || time<0 {return 0}
    weight:f32=1
    if s.blend_in>0 {weight=min(weight,time/s.blend_in)}
    if s.blend_out>0 {weight=min(weight,(length-time)/s.blend_out)}
    return clamp(weight,0,1)
}

// The rotation a shake adds to the view after time seconds of play.
shake_sequence_rotation :: proc "contextless" (s:Shake_Sequence,time:f32) -> mm.Quat {
    weight:=shake_weight(s,time)*s.scale
    if weight==0 || !(abs(weight)<math.F32_MAX) {return 1}
    rate:=s.rate if s.rate>0 else 1
    t:=time*rate
    pitch,yaw,roll:=shake_channel_at(s.pitch,t)*weight,shake_channel_at(s.yaw,t)*weight,shake_channel_at(s.roll,t)*weight
    return mm.quat_axis_angle({0,1,0},yaw)*mm.quat_axis_angle({1,0,0},pitch)*mm.quat_axis_angle({0,0,1},roll)
}

// The radians a shake adds to the vertical field of view after time seconds of play.
shake_sequence_fov :: proc "contextless" (s:Shake_Sequence,time:f32) -> f32 {
    weight:=shake_weight(s,time)*s.scale
    if weight==0 || !(abs(weight)<math.F32_MAX) {return 0}
    rate:=s.rate if s.rate>0 else 1
    widen:=shake_channel_at(s.fov,time*rate)*weight
    return widen if abs(widen)<math.F32_MAX else 0
}

// Starts what was asked of a camera that follows: a single one that plays starts over.
@(private)
shakes_take :: proc(follows:^core.Table(Camera_Follow),shakes:^Camera_Shakes,problems:^core.Problems) {
    if shakes==nil {return}
    for asked in core.take(&shakes.queue) {
        follow:=core.edit(follows,asked.camera)
        if follow==nil {
            core.report(problems,asked.camera,"camera.shake","a camera shake was asked of an entity without a Camera_Follow; ask it of the camera that follows")
            continue
        }
        if !(asked.sequence.length>0) || asked.sequence.rate<0 || asked.sequence.blend_in<0 || asked.sequence.blend_out<0 {
            core.report(problems,asked.camera,"camera.shake","a camera shake was asked with length %v, rate %v and blends %v and %v: give it a length above 0 and a rate and blends of 0 or more",asked.sequence.length,asked.sequence.rate,asked.sequence.blend_in,asked.sequence.blend_out)
            continue
        }
        slots:=&follow.state.shakes
        slot:=-1
        if asked.sequence.single {
            for p,i in slots {if p.sequence.length>0 && p.sequence.single && p.sequence.id==asked.sequence.id {slot=i;break}}
        }
        if slot<0 {
            left:=f32(math.F32_MAX)
            for p,i in slots {
                rate:=p.sequence.rate if p.sequence.rate>0 else 1
                remaining:=p.sequence.length/rate-p.time
                if p.sequence.length<=0 {slot=i;break}
                if remaining<left {left,slot=remaining,i}
            }
        }
        slots[slot]={sequence=asked.sequence}
    }
}

// The rotation and the radians of vertical field of view the shakes of a camera add this frame,
// after advancing them dt seconds.
@(private)
shakes_advance :: proc "contextless" (state:^Camera_Follow_State,dt:f32) -> (turn:mm.Quat,widen:f32) {
    turn=1
    for &p in state.shakes {
        if p.sequence.length<=0 {continue}
        p.time+=dt
        rate:=p.sequence.rate if p.sequence.rate>0 else 1
        if !(p.time<p.sequence.length/rate) {p={};continue}
        turn*=shake_sequence_rotation(p.sequence,p.time)
        widen+=shake_sequence_fov(p.sequence,p.time)
    }
    return
}

// Gives a perspective camera its field of view without the shakes plus widen, within
// SHAKE_FOV_MIN..SHAKE_FOV_MAX. What it had without them is kept in state, so the shakes of one
// frame never add to those of the last; an orthographic one keeps its own.
@(private)
shakes_fov :: proc "contextless" (camera:^render.Camera,state:^Camera_Follow_State,widen:f32) {
    shakes_fov_restore(camera,state)
    if camera.projection!=.Perspective || widen==0 {return}
    state.fov_base,state.fov_shaken=camera.fov,true
    lens:=camera.fov if camera.fov>0 else render.CAMERA_DEFAULT.fov
    camera.fov=clamp(lens+widen,SHAKE_FOV_MIN,SHAKE_FOV_MAX)
}

// Puts back the field of view a camera had without its shakes.
@(private)
shakes_fov_restore :: proc "contextless" (camera:^render.Camera,state:^Camera_Follow_State) {
    if !state.fov_shaken {return}
    camera.fov=state.fov_base
    state.fov_shaken=false
}
