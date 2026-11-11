package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

// What a track drives. Position and Scale use xyz, Rotation a quaternion in
// xyzw, Float the x component, Vector all four; Float and Vector tracks of
// one target are told apart by their slot.
Property :: enum u8 {Position,Rotation,Scale,Float,Vector}

Interpolation :: enum u8 {
    Linear,
    Step,  // holds the previous value until this key
    Cubic, // Hermite through the keys; a rotation follows a spherical spline (squad)
    Cubic_Spline,
}

// `ease` and `interpolation` describe how the value arrives at this key from
// the previous one, as in the keyframes of ui.
Keyframe :: struct {
    time:f32,
    value:math.Vec4,
    ease:math.Ease,
    interpolation:Interpolation,
    // Cubic: the slopes of the curve as it arrives at this key and as it
    // leaves it, per second. Without them a slope comes from the neighbors
    // and the curve does not pass the value of a key.
    // A rotation ignores them: its spline takes its controls from the neighbors.
    tangents:bool,
    in_slope,out_slope:math.Vec4,
}

vec4_quat :: #force_inline proc "contextless" (v:math.Vec4) -> math.Quat {return quaternion(w=v.w,x=v.x,y=v.y,z=v.z)}
quat_vec4 :: #force_inline proc "contextless" (q:math.Quat) -> math.Vec4 {return {q.x,q.y,q.z,q.w}}

// The value of a track at a time. Keys are sorted by time; before the first
// and after the last one the track holds their values, and at a NaN time the
// value of the first. Zero without keys.
track_evaluate :: proc "contextless" (keys:[]Keyframe,property:Property,time:f32) -> math.Vec4 {
    count:=len(keys)
    if count==0 {return {}}
    last:=count-1
    if !(time>keys[0].time) {return keys[0].value}
    if time>=keys[last].time {return keys[last].value}
    low,high:=0,last
    for high-low>1 {
        middle:=(low+high)>>1
        if keys[middle].time<=time {low=middle} else {high=middle}
    }
    return keyframe_segment(keys,low,property,time)
}
@(private)
keyframe_segment :: proc "contextless" (keys:[]Keyframe,index:int,property:Property,time:f32) -> math.Vec4 {
    a,b:=keys[index],keys[index+1]
    span:=b.time-a.time
    if span<=0 {return b.value}
    t:=math.ease_apply(b.ease,(time-a.time)/span)
    switch b.interpolation {
    case .Step: return a.value
    case .Linear:
        if property==.Rotation {return quat_vec4(math.quat_slerp(vec4_quat(a.value),vec4_quat(b.value),t))}
        return a.value+(b.value-a.value)*t
    case .Cubic,.Cubic_Spline:
        before:=keys[max(index-1,0)]
        after:=keys[min(index+2,len(keys)-1)]
        v0,v1,vb,va:=a.value,b.value,before.value,after.value
        if property==.Rotation && b.interpolation==.Cubic {
            v1=quat_align(v1,v0);vb=quat_align(vb,v0);va=quat_align(va,v1)
            q0,q1:=vec4_quat(v0),vec4_quat(v1)
            return quat_vec4(squad(q0,q1,squad_control(vec4_quat(vb),q0,q1),squad_control(q0,q1,vec4_quat(va)),t))
        }
        m0:=a.out_slope if a.tangents else keyframe_tangent(before.time,vb,a.time,v0,b.time,v1)
        m1:=b.in_slope if b.tangents else keyframe_tangent(a.time,v0,b.time,v1,after.time,va)
        value:=math.hermite(v0,m0*span,v1,m1*span,t)
        if property==.Rotation {return quat_vec4(linalg.normalize0(vec4_quat(value)))}
        return value
    }
    return a.value
}
// Slope at the middle key, per component: the line through its neighbors, clamped so that neither
// segment passes the value of a key (Fritsch-Carlson); zero at an end, at a peak or a valley, and
// beside an equal neighbor, so a value keyed to hold stays still.
@(private)
keyframe_tangent :: proc "contextless" (t0:f32,v0:math.Vec4,t1:f32,v1:math.Vec4,t2:f32,v2:math.Vec4) -> (slope:math.Vec4) {
    if !(t1>t0) || !(t2>t1) {return}
    before,after:=(v1-v0)/(t1-t0),(v2-v1)/(t2-t1)
    line:=(v2-v0)/(t2-t0)
    for i in 0..<4 {
        if !(before[i]*after[i]>0) {continue}
        slope[i]=min(line[i],3*before[i],3*after[i]) if before[i]>0 else max(line[i],3*before[i],3*after[i])
    }
    return
}
// The same rotation with the sign that puts it in the hemisphere of `reference`.
quat_align :: #force_inline proc "contextless" (v,reference:math.Vec4) -> math.Vec4 {return -v if linalg.dot(v,reference)<0 else v}

// Shoemake's spherical cubic between q0 and q1 with the inner controls s0 and
// s1: it passes through every key with a rotation speed that does not jump at
// them, as a Hermite curve does for a position.
squad :: proc "contextless" (q0,q1,s0,s1:math.Quat,t:f32) -> math.Quat {
    return math.quat_slerp(math.quat_slerp(q0,q1,t),math.quat_slerp(s0,s1,t),2*t*(1-t))
}
// The inner control of q between its neighbors, all in one hemisphere.
squad_control :: proc "contextless" (previous,q,next:math.Quat) -> math.Quat {
    inverse:=conj(q)
    sum:=quat_log(inverse*next)+quat_log(inverse*previous)
    return linalg.normalize0(q*quat_exp(-sum/4))
}
// The logarithm of a unit quaternion: half its angle along its axis, in xyz.
quat_log :: proc "contextless" (q:math.Quat) -> math.Vec3 {
    v:=math.Vec3{imag(q),jmag(q),kmag(q)}
    length:=linalg.length(v)
    if length<1e-7 {return {}}
    return v*(cmath.atan2(length,real(q))/length)
}
quat_exp :: proc "contextless" (v:math.Vec3) -> math.Quat {
    angle:=linalg.length(v)
    if angle<1e-7 {return 1}
    s,c:=cmath.sincos(angle)
    axis:=v*(s/angle)
    return quaternion(w=c,x=axis.x,y=axis.y,z=axis.z)
}
