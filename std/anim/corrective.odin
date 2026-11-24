package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

CORRECTIVE_MAX_EDGES :: 256

// How a driver bone's rotation relative to its rest pose maps to a corrective weight in [0, 1].
// - Twist: signed twist about axis in [-pi, pi], ramping 0..1 across [min_angle, max_angle].
// - Swing: unsigned swing of axis away from rest in [0, pi], ramping 0..1 across [min_angle, max_angle].
// - Cone: unsigned angle between rotated axis and cone_axis in [0, pi], ramping 1..0 across
//   [min_angle, max_angle] (1 inside min_angle, 0 outside max_angle).
Corrective_Mode :: enum u8 {
    Twist,
    Swing,
    Cone,
}

Corrective_Driver :: struct {
    mode:Corrective_Mode,
    axis:math.Vec3,      // driver bone local axis (unit)
    cone_axis:math.Vec3, // target direction in driver's rest frame (Cone mode, unit)
    min_angle:f32,       // radians
    max_angle:f32,       // radians (> min_angle)
    smooth:bool,         // false: linear ramp, true: Hermite smoothstep
}

CORRECTIVE_DRIVER_DEFAULT :: Corrective_Driver{
    mode=.Swing,
    axis={0,1,0},
    cone_axis={0,0,-1},
    min_angle=0,
    max_angle=math.PI*0.5,
}

Corrective :: struct {
    driver:Corrective_Driver,
    delta:math.Transform, // additive offset on driven bone: position (m), local rotation, scale factor
}

CORRECTIVE_DEFAULT :: Corrective{
    driver=CORRECTIVE_DRIVER_DEFAULT,
    delta=math.TRANSFORM_IDENTITY,
}

corrective_driver_valid :: proc "contextless" (driver:Corrective_Driver) -> bool {
    if driver.mode>max(Corrective_Mode) {return false}
    if _,ok:=anim_unit(driver.axis);!ok {return false}
    if !anim_vec3_valid(driver.cone_axis) {return false}
    if driver.mode==.Cone {
        if _,ok:=anim_unit(driver.cone_axis);!ok {return false}
    }
    if !anim_finite(driver.min_angle) || !anim_finite(driver.max_angle) || !(driver.min_angle<driver.max_angle) {
        return false
    }
    switch driver.mode {
    case .Twist:
        if driver.min_angle< -math.PI || driver.max_angle>math.PI {return false}
    case .Swing,.Cone:
        if driver.min_angle<0 || driver.max_angle>math.PI {return false}
    }
    return true
}

corrective_delta_valid :: proc "contextless" (delta:math.Transform) -> bool {
    if !anim_transform_valid(delta) {return false}
    return delta.scale.x>0 && delta.scale.y>0 && delta.scale.z>0
}

corrective_valid :: proc "contextless" (config:Corrective) -> bool {
    return corrective_driver_valid(config.driver) && corrective_delta_valid(config.delta)
}

corrective_weight :: proc "contextless" (rotation,reference:math.Quat,driver:Corrective_Driver) -> (weight:f32,ok:bool) {
    if !anim_rotation_valid(rotation) || !anim_rotation_valid(reference) || !corrective_driver_valid(driver) {return}
    axis,_:=anim_unit(driver.axis)
    delta:=linalg.normalize0(conj(reference)*rotation)
    if delta.w<0 {delta=-delta}
    span:=driver.max_angle-driver.min_angle
    t:f32
    switch driver.mode {
    case .Twist:
        projected:=linalg.dot(math.Vec3{delta.x,delta.y,delta.z},axis)
        angle:f32
        if abs(delta.w)+abs(projected)>=1e-6 {angle=2*cmath.atan2(projected,delta.w)}
        t=math.saturate((angle-driver.min_angle)/span)
    case .Swing:
        rotated:=math.quat_rotate(delta,axis)
        angle:=cmath.atan2(linalg.length(linalg.cross(axis,rotated)),linalg.dot(axis,rotated))
        t=math.saturate((angle-driver.min_angle)/span)
    case .Cone:
        cone,_:=anim_unit(driver.cone_axis)
        rotated:=math.quat_rotate(delta,axis)
        angle:=cmath.atan2(linalg.length(linalg.cross(cone,rotated)),linalg.dot(cone,rotated))
        t=1-math.saturate((angle-driver.min_angle)/span)
    }
    if driver.smooth {t=t*t*(3-2*t)}
    if !anim_finite(t) {return}
    return t,true
}

corrective_apply :: proc "contextless" (local:^math.Transform,delta:math.Transform,weight:f32) -> bool {
    if local==nil || !anim_transform_valid(local^) || !corrective_delta_valid(delta) || !anim_finite(weight) {return false}
    w:=math.saturate(weight)
    if w==0 {return true}
    next:=local^
    next.position+=delta.position*w
    next.rotation=linalg.normalize0(next.rotation*math.quat_slerp(1,delta.rotation,w))
    next.scale*=math.Vec3{1,1,1}+(delta.scale-math.Vec3{1,1,1})*w
    if !anim_transform_valid(next) {return false}
    local^=next
    return true
}

// Computes topological execution order for directed edges (drivers[i] -> drivens[i]) using
// Kahn's algorithm in O(n^2) with zero allocations. Writes acyclic edge indices into order[:ordered]
// when order is given, marks each acyclic edge true in peeled when peeled is given, and returns
// acyclic == true iff all edges are free of self-loops and cycles.
corrective_order :: proc "contextless" (
    drivers,drivens:[]$T,order:[]u16=nil,peeled:[]bool=nil,
) -> (ordered:int,acyclic:bool) where T==i32 || T==u64 {
    n:=len(drivers)
    if n!=len(drivens) || n>CORRECTIVE_MAX_EDGES {return 0,false}
    if peeled!=nil && len(peeled)<n {return 0,false}
    if order!=nil && len(order)<n {return 0,false}
    local_peeled:[CORRECTIVE_MAX_EDGES]bool
    marks:=peeled[:n] if peeled!=nil else local_peeled[:n]
    for &m in marks {m=false}
    if n==0 {return 0,true}

    blocked:[CORRECTIVE_MAX_EDGES]u16
    queue:[CORRECTIVE_MAX_EDGES]u16
    head,tail:=0,0
    for i in 0..<n {
        count:u16
        source:=drivers[i]
        for j in 0..<n {
            if drivens[j]==source {count+=1}
        }
        blocked[i]=count
        if count==0 {
            queue[tail]=u16(i)
            tail+=1
        }
    }
    for head<tail {
        idx:=int(queue[head])
        head+=1
        marks[idx]=true
        if order!=nil {order[ordered]=u16(idx)}
        ordered+=1
        target:=drivens[idx]
        for k in 0..<n {
            if !marks[k] && drivers[k]==target {
                blocked[k]-=1
                if blocked[k]==0 {
                    queue[tail]=u16(k)
                    tail+=1
                }
            }
        }
    }
    return ordered,ordered==n
}

// Whether directed edges (drivers[i] -> drivens[i]) are free of self-loops and cycles.
// When peeled is given (length >= len(drivers)), marks each acyclic edge true and each
// cyclic or cycle-dependent edge false.
corrective_acyclic :: proc "contextless" (drivers,drivens:[]$T,peeled:[]bool=nil) -> bool where T==i32 || T==u64 {
    _,acyclic:=corrective_order(drivers,drivens,nil,peeled)
    return acyclic
}

// Evaluates and applies one corrective edge in local pose space without recomputing world poses.
corrective_solve :: proc "contextless" (
    rest,local:[]math.Transform,driver,driven:i32,config:Corrective,weight:f32=1,
) -> (applied_weight:f32,ok:bool) {
    if len(local)!=len(rest) ||
        driver<0 || int(driver)>=len(local) || driven<0 || int(driven)>=len(local) ||
        driver==driven || !anim_finite(weight) || !corrective_valid(config) {
        return
    }
    driven_weight,valid:=corrective_weight(local[driver].rotation,rest[driver].rotation,config.driver)
    if !valid {return}
    effective:=driven_weight*math.saturate(weight)
    if !corrective_apply(&local[driven],config.delta,effective) {return}
    return effective,true
}

skeleton_corrective :: proc "contextless" (
    skeleton:Skeleton,local,world:[]math.Transform,driver,driven:i32,config:Corrective,
    weight:f32=1,root_transform:math.Transform=math.TRANSFORM_IDENTITY,
) -> (applied_weight:f32,ok:bool) {
    if !skeleton_validate(skeleton) || len(world)!=len(local) {return}
    effective,valid:=corrective_solve(skeleton.rest,local,driver,driven,config,weight)
    if !valid {return}
    if !pose_world(skeleton.parents,local,world,root_transform) {return}
    return effective,true
}
