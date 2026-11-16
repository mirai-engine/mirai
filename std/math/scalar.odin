package mirai_math

import "core:math"
import "core:math/linalg"

// Works on floats and on vectors: a*(1-t)+b*t.
lerp :: math.lerp
saturate :: #force_inline proc "contextless" (value:f32) -> f32 {return clamp(value,0,1)}
// Takes a value from one range to another, without clamping. An empty source range gives to_low.
remap :: proc "contextless" (value,from_low,from_high,to_low,to_high:f32) -> f32 {
    if from_high==from_low {return to_low}
    return to_low+(value-from_low)/(from_high-from_low)*(to_high-to_low)
}
remap_clamped :: proc "contextless" (value,from_low,from_high,to_low,to_high:f32) -> f32 {
    if from_high==from_low {return to_low}
    return to_low+saturate((value-from_low)/(from_high-from_low))*(to_high-to_low)
}
// 0 below edge0, 1 above edge1 and a smooth S between them, with no slope at
// the edges. Equal edges make a step.
smoothstep :: proc "contextless" (edge0,edge1,value:f32) -> f32 {
    if edge0==edge1 {return 0 if value<edge0 else 1}
    t:=saturate((value-edge0)/(edge1-edge0))
    return t*t*(3-2*t)
}
// Like smoothstep, with no curvature at the edges either.
smootherstep :: proc "contextless" (edge0,edge1,value:f32) -> f32 {
    if edge0==edge1 {return 0 if value<edge0 else 1}
    t:=saturate((value-edge0)/(edge1-edge0))
    return t*t*t*(t*(t*6-15)+10)
}

// Moves toward the target by at most `step`, without passing it.
approach :: proc "contextless" (current,target,step:f32) -> f32 {
    delta:=target-current
    if abs(delta)<=step {return target}
    return current+(step if delta>0 else -step)
}
approach_point :: proc "contextless" (current,target:$V/[$N]f32,step:f32) -> V {
    delta:=target-current
    distance:=linalg.length(delta)
    if distance<=step || distance<1e-12 {return target}
    return current+delta*(step/distance)
}

// The same angle in [-PI,PI).
angle_wrap :: proc "contextless" (angle:f32) -> f32 {
    turns:=math.floor((angle+PI)/TAU)
    wrapped:=angle-turns*TAU
    return wrapped-TAU if wrapped>=PI else wrapped
}
// The shortest turn that takes one angle to the other, in [-PI,PI).
angle_delta :: proc "contextless" (from,to:f32) -> f32 {return angle_wrap(to-from)}
angle_lerp :: proc "contextless" (from,to,t:f32) -> f32 {return from+angle_delta(from,to)*t}
// Turns toward the target by at most `step` along the shortest way.
angle_approach :: proc "contextless" (current,target,step:f32) -> f32 {
    delta:=angle_delta(current,target)
    if abs(delta)<=step {return target}
    return current+(step if delta>0 else -step)
}

// Smoothing that does not depend on the frame rate: the gap to the target
// shrinks by the same factor per second whatever the size of the steps. With
// `rate` in 1/seconds, 63% of the gap closes in 1/rate seconds. Works on
// floats and on vectors.
damp :: proc "contextless" (current,target:$T,rate,dt:f32) -> T {
    return target+(current-target)*exp_det(-rate*dt)
}
damp_angle :: proc "contextless" (current,target,rate,dt:f32) -> f32 {
    return current+angle_delta(current,target)*(1-exp_det(-rate*dt))
}

// Critically damped spring: reaches the target as fast as a spring can
// without overshooting when it starts at rest. It is the exact solution, so
// it is stable for any dt and any split of a time span into steps gives the
// same result. `omega` is the natural frequency in radians per second: see
// spring_omega. Works on floats and on vectors.
spring_critical :: proc "contextless" (current,velocity,target:$T,omega,dt:f32) -> (value,new_velocity:T) {
    offset:=current-target
    change:=velocity+offset*omega
    decay:=exp_det(-omega*dt)
    return target+(offset+change*dt)*decay,(change-(offset+change*dt)*omega)*decay
}
// The frequency with which a spring at rest closes half of its gap in `half_life` seconds.
spring_omega :: proc "contextless" (half_life:f32) -> f32 {return 1.6783469900166605/half_life}

// The nearest multiple of `step`. A step of 0 leaves the value as it is.
snap :: proc{snap_scalar,snap_vector}
snap_scalar :: proc "contextless" (value,step:f32) -> f32 {
    return math.round(value/step)*step if step!=0 else value
}
snap_vector :: proc "contextless" (value:$V/[$N]f32,step:f32) -> V {
    result:=value
    if step!=0 {for &component in result {component=math.round(component/step)*step}}
    return result
}
// The nearest value of origin + n*step.
snap_from :: proc "contextless" (value,origin,step:f32) -> f32 {return origin+snap_scalar(value-origin,step)}

// Moves toward target as a critically damped spring that gets there in about
// smooth_time seconds, never faster than max_speed (0: no limit), and never
// past it. The caller keeps velocity between calls. Deterministic: the decay
// is a rational approximation, not the exp of the platform.
smooth_damp :: proc{smooth_damp_scalar,smooth_damp_vector}
smooth_damp_scalar :: proc "contextless" (current,target:f32,velocity:^f32,smooth_time,dt:f32,max_speed:f32=0) -> f32 {
    time:=max(smooth_time,1e-4)
    omega:=2/time
    x:=omega*dt
    decay:=1/(1+x+0.48*x*x+0.235*x*x*x)
    change:=current-target
    if max_speed>0 {change=clamp(change,-max_speed*time,max_speed*time)}
    goal:=current-change
    pulled:=(velocity^+omega*change)*dt
    velocity^=(velocity^-omega*pulled)*decay
    result:=goal+(change+pulled)*decay
    if (target-current>0)==(result>target) {
        velocity^=0
        return target
    }
    return result
}
smooth_damp_vector :: proc "contextless" (current,target:Vec3,velocity:^Vec3,smooth_time,dt:f32,max_speed:f32=0) -> Vec3 {
    time:=max(smooth_time,1e-4)
    omega:=2/time
    x:=omega*dt
    decay:=1/(1+x+0.48*x*x+0.235*x*x*x)
    change:=current-target
    if max_speed>0 {
        limit:=max_speed*time
        if length:=linalg.length(change);length>limit {change*=limit/length}
    }
    goal:=current-change
    pulled:=(velocity^+omega*change)*dt
    velocity^=(velocity^-omega*pulled)*decay
    result:=goal+(change+pulled)*decay
    if linalg.dot(target-current,result-target)>0 {
        velocity^={}
        return target
    }
    return result
}
// smooth_damp for an angle in radians, by the shorter way around.
smooth_damp_angle :: proc "contextless" (current,target:f32,velocity:^f32,smooth_time,dt:f32,max_speed:f32=0) -> f32 {
    return smooth_damp_scalar(current,current+angle_delta(current,target),velocity,smooth_time,dt,max_speed)
}
