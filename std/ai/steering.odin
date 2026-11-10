package ai

import "core:math/linalg"
import "mirai:std/math"

// Steering behaviors as pure functions: each takes what it reads and returns
// a steering force (a change of velocity per second, for a unit mass) no
// longer than `max_force`. They work on Vec2 and Vec3 alike. Combine them by
// adding the forces (weighted, or in priority order), then call
// steering_integrate. A velocity that is zero has no heading: the behaviors
// that need one give no force.

// A neighbor of a flocking agent.
Boid :: struct($V:typeid) {
    position,velocity:V,
}
// A sphere (a circle in 2D) to steer around.
Obstacle :: struct($V:typeid) {
    center:V,
    radius:f32,
}

limit_length :: proc "contextless" (v:$V/[$N]f32,max_length:f32) -> V {
    length:=linalg.length(v)
    // A vector whose length is not a number, or does not fit in one, has no direction to keep.
    if !(length<=max(f32)) {return {}}
    return v*(max_length/length) if length>max_length && length>0 else v
}

// The force that turns the current velocity into the one that heads for the
// wanted one.
@(private)
steer_to :: proc "contextless" (desired,velocity:$V/[$N]f32,max_force:f32) -> V {return limit_length(desired-velocity,max_force)}

seek :: proc "contextless" (position,velocity,target:$V/[$N]f32,max_speed,max_force:f32) -> V {
    return steer_to(linalg.normalize0(target-position)*max_speed,velocity,max_force)
}
flee :: proc "contextless" (position,velocity,threat:$V/[$N]f32,max_speed,max_force:f32) -> V {
    return steer_to(linalg.normalize0(position-threat)*max_speed,velocity,max_force)
}
// Like seek, but slows down inside `slow_radius` and stops at the target.
arrive :: proc "contextless" (position,velocity,target:$V/[$N]f32,max_speed,max_force,slow_radius:f32) -> V {
    offset:=target-position
    distance:=linalg.length(offset)
    if distance<=1e-6 {return limit_length(-velocity,max_force)}
    speed:=max_speed if slow_radius<=0 else max_speed*math.saturate(distance/slow_radius)
    return steer_to(offset*(speed/distance),velocity,max_force)
}
// Seeks where a moving target will be: the distance to it divided by the
// agent's top speed ahead in time, at most `max_prediction` seconds.
pursue :: proc "contextless" (position,velocity,target_position,target_velocity:$V/[$N]f32,max_speed,max_force,max_prediction:f32) -> V {
    return seek(position,velocity,predict(position,target_position,target_velocity,max_speed,max_prediction),max_speed,max_force)
}
evade :: proc "contextless" (position,velocity,threat_position,threat_velocity:$V/[$N]f32,max_speed,max_force,max_prediction:f32) -> V {
    return flee(position,velocity,predict(position,threat_position,threat_velocity,max_speed,max_prediction),max_speed,max_force)
}
@(private)
predict :: proc "contextless" (position,target,target_velocity:$V/[$N]f32,max_speed,max_prediction:f32) -> V {
    time:=linalg.length(target-position)/max_speed if max_speed>0 else 0
    return target+target_velocity*min(time,max_prediction)
}

// Wandering keeps a point on a circle (a sphere) of `radius` that sits
// `distance` ahead of the agent, and nudges it a little every call so the
// heading drifts. `displacement` is that point relative to the circle's
// center: keep it between calls, zero at the start. No force without `rng`.
wander :: proc "contextless" (displacement:^$V/[$N]f32,heading:V,distance,radius,jitter,max_force:f32,rng:^math.Rng) -> V {
    if displacement==nil || rng==nil {return {}}
    when N==2 {nudge:=math.random_unit_vec2(rng)} else {nudge:=math.random_unit_vec3(rng)}
    moved:=displacement^+nudge*jitter
    if linalg.length(moved)<=1e-6 {moved=nudge}
    displacement^=linalg.normalize0(moved)*radius
    return limit_length(linalg.normalize0(heading)*distance+displacement^,max_force)
}

// Pushes away from the neighbors within `radius`, harder the closer they are.
separation :: proc "contextless" (position:$V/[$N]f32,neighbors:[]Boid(V),radius,max_force:f32) -> V {
    force:V
    for other in neighbors {
        away:=position-other.position
        distance:=linalg.length(away)
        if distance<=1e-6 || distance>=radius {continue}
        force+=away/(distance*distance)
    }
    return limit_length(force,max_force)
}
// Steers toward the average velocity of the neighbors within `radius`.
alignment :: proc "contextless" (position,velocity:$V/[$N]f32,neighbors:[]Boid(V),radius,max_speed,max_force:f32) -> V {
    sum:V
    count:=0
    for other in neighbors {
        if linalg.length(other.position-position)<radius {sum+=other.velocity;count+=1}
    }
    if count==0 {return {}}
    return steer_to(linalg.normalize0(sum/f32(count))*max_speed,velocity,max_force)
}
// Seeks the center of the neighbors within `radius`.
cohesion :: proc "contextless" (position,velocity:$V/[$N]f32,neighbors:[]Boid(V),radius,max_speed,max_force:f32) -> V {
    sum:V
    count:=0
    for other in neighbors {
        if linalg.length(other.position-position)<radius {sum+=other.position;count+=1}
    }
    if count==0 {return {}}
    return seek(position,velocity,sum/f32(count),max_speed,max_force)
}

// Steers around the nearest obstacle that the agent, `agent_radius` wide,
// would touch within `look_ahead` along its velocity: the force points from
// the obstacle to the nearest point of that path.
avoid_obstacles :: proc "contextless" (position,velocity:$V/[$N]f32,obstacles:[]Obstacle(V),look_ahead,agent_radius,max_force:f32) -> V {
    speed:=linalg.length(velocity)
    if speed<=1e-6 {return {}}
    ahead:=position+velocity*(look_ahead/speed)
    path:=ahead-position
    path_length2:=linalg.dot(path,path)
    nearest:=f32(1e30)
    force:V
    for obstacle in obstacles {
        t:=math.saturate(linalg.dot(obstacle.center-position,path)/path_length2) if path_length2>0 else 0
        closest:=position+path*t
        away:=closest-obstacle.center
        distance:=linalg.length(away)
        if distance>=obstacle.radius+agent_radius {continue}
        along:=linalg.length(closest-position)
        if along>=nearest {continue}
        nearest=along
        if distance>1e-6 {force=away/distance*max_force} else {
            side:=linalg.normalize0(path)
            force=perpendicular(side)*max_force
        }
    }
    return limit_length(force,max_force)
}
@(private)
perpendicular :: proc "contextless" (v:$V/[$N]f32) -> V {
    when N==2 {return {-v.y,v.x}} else {
        axis:=V{1,0,0} if abs(v.x)<0.9 else V{0,1,0}
        return linalg.normalize0(linalg.cross(v,axis))
    }
}

// One Euler step: adds the force to the velocity (unit mass), limits the
// speed and moves the position.
steering_integrate :: proc "contextless" (position,velocity,force:$V/[$N]f32,max_speed,dt:f32) -> (new_position,new_velocity:V) {
    new_velocity=limit_length(velocity+force*dt,max_speed)
    return position+new_velocity*dt,new_velocity
}
