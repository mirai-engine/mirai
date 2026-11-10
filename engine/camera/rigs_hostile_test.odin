package camera

import "core:math/linalg"
import "core:testing"
import "mirai:std/base"
import math "mirai:std/math"

// Every rig is handed numbers that are zero, negative, huge, NaN or infinite,
// and returns the contract its results broke, or "". Half of the rounds are
// calm: finite, moderate numbers, times that are not negative and unit
// directions, for the contracts that only hold then.

@(private="file") HOSTILE_ROUNDS :: #config(CAMERA_HOSTILE_ROUNDS,400)

@(private="file")
Hostile_Rig :: struct {name:string,contract:proc(h:^base.Hostile,calm:bool) -> string}

@(private="file")
number :: proc(h:^base.Hostile,calm:bool) -> f32 {
    return f32(base.hostile_int(h,2001)-1000)/100 if calm else base.hostile_f32(h)
}
// Not negative in a calm round.
@(private="file")
amount :: proc(h:^base.Hostile,calm:bool) -> f32 {
    return f32(base.hostile_int(h,1001))/100 if calm else base.hostile_f32(h)
}
@(private="file")
vec3 :: proc(h:^base.Hostile,calm:bool) -> math.Vec3 {return {number(h,calm),number(h,calm),number(h,calm)}}

@(private="file")
finite :: proc(v:math.Vec3) -> bool {return v-v=={}}

@(private="file")
hostile_follow :: proc(h:^base.Hostile,calm:bool) -> string {
    follow:Follow
    from,target:=vec3(h,calm),vec3(h,calm)
    follow_snap(&follow,from)
    reached:=follow_update(&follow,target,amount(h,calm),amount(h,calm))
    split:=follow
    _=follow_update_split(&split,vec3(h,calm),number(h,calm),number(h,calm),vec3(h,calm),number(h,calm))
    if !calm {return ""}
    for axis in 0..<3 {
        if reached[axis]<min(from[axis],target[axis])-1e-3 || reached[axis]>max(from[axis],target[axis])+1e-3 {return "a follow that starts at rest overshot its target"}
    }
    return ""
}

@(private="file")
hostile_orbit :: proc(h:^base.Hostile,calm:bool) -> string {
    orbit:=orbit_make(vec3(h,calm),number(h,calm),number(h,calm),number(h,calm))
    orbit.min_pitch,orbit.max_pitch=number(h,calm),number(h,calm)
    orbit.min_distance,orbit.max_distance=number(h,calm),number(h,calm)
    turn,closer:=number(h,calm),number(h,calm)
    pitch,distance:=orbit.pitch+turn,orbit.distance-closer
    orbit_rotate(&orbit,number(h,calm),turn);orbit_zoom(&orbit,closer)
    away:=orbit_direction(orbit)
    position,rotation:=orbit_position(orbit),orbit_rotation(orbit)
    _=orbit_transform(orbit)
    if pitch==pitch && orbit.min_pitch<=orbit.max_pitch && (orbit.pitch<orbit.min_pitch || orbit.pitch>orbit.max_pitch) {return "the pitch of an orbit left its limits"}
    if distance==distance && orbit.min_distance<=orbit.max_distance && (orbit.distance<orbit.min_distance || orbit.distance>orbit.max_distance) {return "the distance of an orbit left its limits"}
    if !calm {return ""}
    switch {
    case orbit.yaw< -math.PI || orbit.yaw>=math.PI: return "the yaw of an orbit left [-PI,PI)"
    case abs(linalg.length(away)-1)>1e-3 || abs(abs(rotation)-1)>1e-3: return "the direction or the rotation of an orbit is not unit"
    case abs(linalg.length(position-orbit.target)-abs(orbit.distance))>1e-3*(1+abs(orbit.distance)): return "the camera of an orbit is not at its distance"
    }
    return ""
}

@(private="file")
hostile_spring_arm :: proc(h:^base.Hostile,calm:bool) -> string {
    // A collision query that answers fractions out of range, a NaN among them.
    query:Arm_Query=proc(user:rawptr,from,to:math.Vec3,radius:f32) -> (fraction:f32,hit:bool) {
        fractions:=[5]f32{f32(0h7fc00000),-5,5,0.25,0.75}
        return fractions[(^int)(user)^%len(fractions)],true
    }
    arm:=spring_arm_make(amount(h,calm),amount(h,calm))
    arm.margin,arm.min_length,arm.return_time=amount(h,calm),amount(h,calm),amount(h,calm)
    arm.grace,arm.pull_time,arm.hold=amount(h,calm),amount(h,calm),amount(h,calm)
    pivot,direction:=vec3(h,calm),vec3(h,calm)
    if calm {direction=linalg.normalize(direction) if linalg.length(direction)>0.1 else math.Vec3{0,0,1}}
    for _ in 0..<4 {
        answer:=base.hostile_int(h,5)
        position:=spring_arm_update(&arm,pivot,direction,nil if base.hostile_int(h,3)==0 else query,&answer,amount(h,calm))
        if !calm {continue}
        if !(arm.current>=0 && arm.current<=arm.length*1.001+1e-4) {return "a spring arm left the way between its pivot and its length"}
        if !finite(position) || linalg.length(position-pivot)>arm.length*1.001+1e-3 {return "the camera of a spring arm is farther than its length"}
    }
    return ""
}

@(private="file")
hostile_shake :: proc(h:^base.Hostile,calm:bool) -> string {
    shake:=shake_make(u32(base.hostile_next(h)))
    added:=number(h,calm)
    shake_add(&shake,added)
    if added==added && !(shake.trauma>=0 && shake.trauma<=1) {return "the trauma of a shake left 0..1"}
    if base.hostile_int(h,4)==0 {shake.trauma=base.hostile_f32(h)}
    // The power is of any size in every round: how long the intensity takes must not depend on it.
    shake.power=base.hostile_f32(h)
    shake.decay,shake.frequency=amount(h,calm),amount(h,calm)
    shake.max_offset,shake.max_angle=vec3(h,calm),vec3(h,calm)
    trauma:=shake.trauma
    if intensity:=shake_intensity(shake);trauma>=0 && trauma<=1 && !(intensity>=0 && intensity<=trauma) {return "the intensity of a shake is not between 0 and its trauma"}
    offset,angles:=shake_update(&shake,amount(h,calm))
    if !calm || !(trauma>=0 && trauma<=1) {return ""}
    if !(shake.trauma>=0 && shake.trauma<=trauma) {return "the trauma of a shake grew by itself"}
    for axis in 0..<3 {
        if abs(offset[axis])>abs(shake.max_offset[axis])*1.001+1e-6 || abs(angles[axis])>abs(shake.max_angle[axis])*1.001+1e-6 {return "a shake moved the camera farther than its limits"}
    }
    return ""
}

@(private="file")
hostile_look :: proc(h:^base.Hostile,calm:bool) -> string {
    current:=math.quat_axis_angle(vec3(h,calm),number(h,calm))
    turned:=look_at_smooth(current,vec3(h,calm),vec3(h,calm),vec3(h,calm),amount(h,calm),amount(h,calm))
    if calm && abs(abs(turned)-1)>1e-3 {return "a smoothed look is not a rotation"}
    return ""
}

@(test)
hostile_numbers_keep_the_contracts_of_the_rigs :: proc(t:^testing.T) {
    rigs:=[?]Hostile_Rig{
        {"follow",hostile_follow},
        {"orbit",hostile_orbit},
        {"spring arm",hostile_spring_arm},
        {"shake",hostile_shake},
        {"look_at_smooth",hostile_look},
    }
    for rig,seed in rigs {
        h:=base.Hostile{u64(seed)+3}
        for round in 0..<HOSTILE_ROUNDS {
            if broken:=rig.contract(&h,round&1==0);!testing.expectf(t,broken=="","%s, round %d: %s",rig.name,round,broken) {break}
        }
    }
}
