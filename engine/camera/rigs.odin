package camera

import cmath "core:math"
import "core:math/linalg"
import "mirai:std/math"

// Camera helpers: plain state and procedures that produce a position or a
// rotation. They do not own a camera; the caller applies the result to its
// camera entity. Right-handed, Y up, the camera looks down its -Z.

// Follows a target with a critically damped spring: it reaches it without
// overshooting, whatever the frame rate.
Follow :: struct {
    position,velocity:math.Vec3,
}

follow_snap :: proc "contextless" (f:^Follow,position:math.Vec3) {f^={position=position}}
// `half_life` is the time the spring takes to close half of its distance to a
// target that does not move.
follow_update :: proc "contextless" (f:^Follow,target:math.Vec3,half_life:f32,dt:f32) -> math.Vec3 {
    if half_life<=0 {f.position=target;f.velocity={};return f.position}
    f.position,f.velocity=math.spring_critical(f.position,f.velocity,target,math.spring_omega(half_life),dt)
    return f.position
}

// follow_update with its own half-life along `up` (a unit vector) for the part
// of the motion along it; up_half_life 0 takes half_life.
follow_update_split :: proc "contextless" (f:^Follow,target:math.Vec3,half_life,up_half_life:f32,up:math.Vec3,dt:f32) -> math.Vec3 {
    if up_half_life<=0 || up_half_life==half_life {return follow_update(f,target,half_life,dt)}
    along :: proc "contextless" (v,up:math.Vec3) -> f32 {return v.x*up.x+v.y*up.y+v.z*up.z}
    vertical:=Follow{position=up*along(f.position,up),velocity=up*along(f.velocity,up)}
    across:=Follow{position=f.position-vertical.position,velocity=f.velocity-vertical.velocity}
    follow_update(&vertical,up*along(target,up),up_half_life,dt)
    follow_update(&across,target-up*along(target,up),half_life,dt)
    f.position,f.velocity=across.position+vertical.position,across.velocity+vertical.velocity
    return f.position
}

// A camera that turns around a point at a distance. `yaw` turns around Y; at
// yaw and pitch 0 the camera is on the +Z side of the target, looking at it.
Orbit :: struct {
    target:math.Vec3,
    yaw,pitch,distance:f32,
    min_pitch,max_pitch:f32,
    min_distance,max_distance:f32,
}

orbit_make :: proc "contextless" (target:math.Vec3,distance:f32,yaw:f32=0,pitch:f32=0) -> Orbit {
    o:=Orbit{target=target,yaw=yaw,pitch=pitch,distance=distance,min_pitch=-1.5533,max_pitch=1.5533,min_distance=0.1,max_distance=1e4}
    orbit_rotate(&o,0,0);orbit_zoom(&o,0)
    return o
}
// Turns by the given angles (radians); the pitch stays within its limits.
orbit_rotate :: proc "contextless" (o:^Orbit,d_yaw,d_pitch:f32) {
    o.yaw=math.angle_wrap(o.yaw+d_yaw)
    o.pitch=clamp(o.pitch+d_pitch,o.min_pitch,o.max_pitch)
}
// Moves closer by `amount` (farther when negative); the distance stays within its limits.
orbit_zoom :: proc "contextless" (o:^Orbit,amount:f32) {o.distance=clamp(o.distance-amount,o.min_distance,o.max_distance)}
// The unit vector from the target to the camera.
orbit_direction :: proc "contextless" (o:Orbit) -> math.Vec3 {
    cp:=cmath.cos(o.pitch)
    return {cmath.sin(o.yaw)*cp,cmath.sin(o.pitch),cmath.cos(o.yaw)*cp}
}
orbit_position :: proc "contextless" (o:Orbit) -> math.Vec3 {return o.target+orbit_direction(o)*o.distance}
orbit_rotation :: proc "contextless" (o:Orbit) -> math.Quat {return math.quat_look(-orbit_direction(o),{0,1,0})}
orbit_transform :: proc "contextless" (o:Orbit) -> math.Transform {
    return {position=orbit_position(o),rotation=orbit_rotation(o),scale={1,1,1}}
}

// The caller's collision query for a spring arm: sweeps a sphere of `radius`
// from `from` to `to` and returns the fraction of the way (0 to 1) at which it
// first touches something.
Arm_Query :: proc(user:rawptr,from,to:math.Vec3,radius:f32) -> (fraction:f32,hit:bool)

// A boom that holds the camera at `length` from its pivot, pulled in when
// something is in the way. What reaches the camera pulls it in at once, so
// it never sits inside a wall, not even where the way is shorter than its
// minimum. What only stands between the pivot and the camera, a post or
// someone who walks by, is let be for `grace` and then pulled in smoothly,
// so a passing obstruction does not make it jump. Once the way is clear for
// `hold` it goes back out smoothly. Every time is in seconds, and 0 is at
// once.
Spring_Arm :: struct {
    length:f32,       // wanted
    current:f32,      // where the camera is
    probe_radius:f32, // of the sphere swept to find obstructions
    margin:f32,       // kept between the camera and what it hit
    min_length:f32,
    grace:f32,        // what stands between is let be this long
    pull_time:f32,    // half-life of the pull in toward what stands between
    hold:f32,         // it stays in this long after the way clears
    return_time:f32,  // half-life of the way back out
    blocked:f32,      // seconds what stands between has been there; below 0: never updated
    clear:f32,        // seconds the way has been clear
}

SPRING_ARM_GRACE :: 0.12
SPRING_ARM_PULL_TIME :: 0.06
SPRING_ARM_HOLD :: 0.3
SPRING_ARM_RETURN_TIME :: 0.17
SPRING_ARM_MARGIN :: 0.05

spring_arm_make :: proc "contextless" (length:f32,probe_radius:f32=0.2) -> Spring_Arm {
    return {
        length=length,current=length,probe_radius=probe_radius,margin=SPRING_ARM_MARGIN,min_length=0.1,
        grace=SPRING_ARM_GRACE,pull_time=SPRING_ARM_PULL_TIME,hold=SPRING_ARM_HOLD,return_time=SPRING_ARM_RETURN_TIME,blocked=-1,
    }
}

// Closes on target by half of the way in each half_life seconds; 0: at once.
@(private)
arm_approach :: proc "contextless" (current,target,half_life,dt:f32) -> f32 {
    if half_life<=0 {return target}
    return math.damp(current,target,0.6931472/half_life,dt)
}
// The position of the camera for a pivot and the unit direction from the pivot to the camera.
spring_arm_update :: proc(arm:^Spring_Arm,pivot,direction:math.Vec3,query:Arm_Query,user:rawptr,dt:f32) -> math.Vec3 {
    wanted:=arm.length
    if query!=nil {
        if fraction,hit:=query(user,pivot,pivot+direction*arm.length,arm.probe_radius);hit {
            // What it hit, measured from the pivot. The minimum only raises the
            // camera while it stays this side of it: past that, the camera goes
            // as far as the hit allows, even below its minimum.
            reach:=math.saturate(fraction)*arm.length
            wanted=reach-arm.margin
            if wanted<arm.min_length && arm.min_length<=reach {wanted=arm.min_length}
            wanted=clamp(wanted,0,arm.length)
        }
    }
    switch {
    case wanted<arm.current:
        arm.clear=0
        switch {
        // A new arm, or a hit about where the camera is: the camera would be in it.
        case arm.blocked<0 || arm.current-wanted<=arm.probe_radius+arm.margin: arm.current=wanted
        case arm.blocked>=arm.grace: arm.current=arm_approach(arm.current,wanted,arm.pull_time,dt)
        }
        arm.blocked=max(arm.blocked,0)+dt
    case:
        arm.blocked=0
        arm.clear+=dt
        if arm.clear>=arm.hold {arm.current=arm_approach(arm.current,wanted,arm.return_time,dt)}
    }
    return pivot+direction*arm.current
}

// Trauma-based camera shake. Adding trauma (0 to 1) makes the camera shake
// with an intensity of trauma to the `power`, and the trauma drains away at
// `decay` per second, so a hit shakes hard and settles. The motion is smooth
// noise, deterministic for a seed.
Shake :: struct {
    trauma:f32,
    time:f32,
    seed:u32,
    decay:f32,         // trauma lost per second
    power:f32,         // 2 gives the usual feel: small trauma barely moves the camera
    frequency:f32,     // how fast the noise moves, in noise units per second
    max_offset:math.Vec3,
    max_angle:math.Vec3, // radians: pitch, yaw, roll
}

SHAKE_POWER_MAX :: 1024

shake_make :: proc "contextless" (seed:u32=0) -> Shake {
    return {seed=seed,decay=1,power=2,frequency=18,max_offset={0.25,0.25,0.1},max_angle={0.04,0.06,0.08}}
}
shake_add :: proc "contextless" (s:^Shake,amount:f32) {s.trauma=clamp(s.trauma+amount,0,1)}
shake_intensity :: proc "contextless" (s:Shake) -> f32 {
    // The whole part of the power, from 1 to SHAKE_POWER_MAX: what a huge power
    // or a NaN turns into as an integer differs between processors, and the
    // number of products must not.
    power:=int(min(s.power,SHAKE_POWER_MAX)) if s.power>=1 else 1
    intensity,factor:f32=1,s.trauma
    for ;power>0;power>>=1 {
        if power&1==1 {intensity*=factor}
        factor*=factor
    }
    return intensity
}
// Advances the shake and returns the offset to add to the camera position and the angles to add to its rotation.
shake_update :: proc "contextless" (s:^Shake,dt:f32) -> (offset,angles:math.Vec3) {
    s.time+=dt
    s.trauma=max(s.trauma-s.decay*dt,0)
    intensity:=shake_intensity(s^)
    if intensity<=0 {return}
    t:=s.time*s.frequency
    for axis in 0..<3 {
        offset[axis]=s.max_offset[axis]*intensity*math.noise_perlin2({t,f32(axis)*31.7},s.seed)
        angles[axis]=s.max_angle[axis]*intensity*math.noise_perlin2({t,f32(axis+3)*31.7},s.seed)
    }
    return
}

// Turns `current` toward the rotation that faces `target` from `from`, closing
// a fixed share of the remaining angle per second (`rate` is 1/seconds), the
// same at any frame rate. `up` is the world's up.
look_at_smooth :: proc "contextless" (current:math.Quat,from,target,up:math.Vec3,rate,dt:f32) -> math.Quat {
    direction:=target-from
    if linalg.length2(direction)<1e-12 {return current}
    wanted:=math.quat_look(linalg.normalize(direction),up)
    return math.quat_slerp(current,wanted,1-cmath.exp(-rate*dt))
}
