package ai

import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

AVOID_DT :: 1.0/30

// Moves every agent toward its goal with avoidance for `steps` and returns the least gap between two of them.
avoid_simulate :: proc(agents:[]Avoid_Agent($N),goals:[][N]f32,max_speed:f32,steps:int,horizon:f32=2) -> (least_gap:f32) {
    least_gap=1e30
    others:[32]Avoid_Agent(N)
    next:[32][N]f32
    for _ in 0..<steps {
        for agent,i in agents {
            count:=0
            for other,j in agents {if j!=i {others[count]=other;count+=1}}
            preferred:=limit_length(goals[i]-agent.position,max_speed)
            next[i]=avoid_velocity(agent,preferred,max_speed,others[:count],horizon,AVOID_DT)
        }
        for &agent,i in agents {
            agent.velocity=next[i]
            agent.position+=agent.velocity*AVOID_DT
        }
        for a,i in agents {
            for b in agents[i+1:] {least_gap=min(least_gap,linalg.distance(a.position,b.position)-a.radius-b.radius)}
        }
    }
    return
}

limit_length :: proc(v:[$N]f32,limit:f32) -> [N]f32 {
    length:=linalg.length(v)
    return v*(limit/length) if length>limit else v
}

avoid_finite :: proc(v:[$N]f32) -> bool {
    for x in v {if !(abs(x)<=max(f32)) {return false}}
    return true
}

@(test)
avoidance_without_neighbors_keeps_the_preferred_velocity_within_the_speed_limit :: proc(t:^testing.T) {
    self:=Avoid_Agent(2){radius=0.5}
    testing.expect(t,near_vec(avoid_velocity(self,{1,0.5},2,nil,2,AVOID_DT),math.Vec2{1,0.5}))
    fast:=avoid_velocity(self,{30,40},2,nil,2,AVOID_DT)
    testing.expect(t,near_vec(fast,math.Vec2{1.2,1.6}))
    far:=[]Avoid_Agent(2){{position={100,0},radius=0.5}}
    testing.expect(t,near_vec(avoid_velocity(self,{1,0},2,far,2,AVOID_DT),math.Vec2{1,0}))
}

@(test)
two_agents_walking_at_each_other_pass_without_touching :: proc(t:^testing.T) {
    agents:=[]Avoid_Agent(2){{position={-5,0},radius=0.5},{position={5,0.01},radius=0.5}}
    goals:=[]math.Vec2{{5,0},{-5,0}}
    gap:=avoid_simulate(agents,goals,1.5,400)
    testing.expectf(t,gap>-1e-3,"gap %v",gap)
    for agent,i in agents {testing.expectf(t,linalg.distance(agent.position,goals[i])<0.1,"agent %d at %v",i,agent.position)}
}

@(test)
a_ring_of_agents_swaps_sides_without_touching :: proc(t:^testing.T) {
    COUNT :: 8
    agents:[COUNT]Avoid_Agent(2)
    goals:[COUNT]math.Vec2
    for i in 0..<COUNT {
        s,c:=cmath.sincos(f32(i)*math.TAU/COUNT+0.3*f32(i%3))
        agents[i]={position={c*8,s*8},radius=0.4}
        goals[i]={-c*8,-s*8}
    }
    gap:=avoid_simulate(agents[:],goals[:],1.5,1200,6)
    testing.expectf(t,gap>-1e-3,"gap %v",gap)
    for agent,i in agents {testing.expectf(t,linalg.distance(agent.position,goals[i])<0.5,"agent %d at %v, goal %v",i,agent.position,goals[i])}
}

@(test)
agents_that_overlap_are_pushed_apart :: proc(t:^testing.T) {
    agents:=[]Avoid_Agent(2){{position={0,0},radius=0.5},{position={0.3,0},radius=0.5}}
    goals:=[]math.Vec2{{0,0},{0.3,0}}
    avoid_simulate(agents,goals,2,30)
    testing.expect(t,linalg.distance(agents[0].position,agents[1].position)>=1-1e-2)
    same:=[]Avoid_Agent(2){{radius=0.5}}
    velocity:=avoid_velocity(Avoid_Agent(2){radius=0.5},{},2,same,2,AVOID_DT)
    testing.expect(t,avoid_finite(velocity))
    testing.expect(t,linalg.length(velocity)<=2+1e-4)
}

@(test)
avoidance_considers_the_nearest_neighbors_when_there_are_too_many :: proc(t:^testing.T) {
    neighbors:[AVOID_MAX_NEIGHBORS+9]Avoid_Agent(2)
    for &other,i in neighbors {other={position={-50-f32(i),40},radius=0.5}}
    neighbors[len(neighbors)-1]={position={1.5,0},radius=0.5}
    self:=Avoid_Agent(2){velocity={1,0},radius=0.5}
    velocity:=avoid_velocity(self,{1,0},1,neighbors[:],2,AVOID_DT)
    testing.expect(t,linalg.distance(velocity,math.Vec2{1,0})>0.1)
    testing.expect(t,linalg.length(velocity)<=1+1e-4)
}

// Eight neighbors around, close and rushing in: nothing is allowed.
avoid_squeezed_crowd :: proc() -> (neighbors:[8]Avoid_Agent(2)) {
    for &other,i in neighbors {
        s,c:=cmath.sincos(f32(i)*math.TAU/8)
        other={position={c*1.05,s*1.05},velocity={-c*3,-s*3},radius=0.5}
    }
    return
}

@(test)
a_crowd_squeezed_from_every_side_still_gets_a_finite_velocity_within_the_limit :: proc(t:^testing.T) {
    neighbors:=avoid_squeezed_crowd()
    velocity:=avoid_velocity(Avoid_Agent(2){radius=0.5},{1,0},1,neighbors[:],2,AVOID_DT)
    testing.expect(t,avoid_finite(velocity))
    testing.expect(t,linalg.length(velocity)<=1+1e-3)
}

@(test)
two_agents_flying_at_each_other_pass_without_touching :: proc(t:^testing.T) {
    // From rest a little off the line, like on the plane; and already closing
    // in exactly head-on, level and one above the other, where each steps to
    // its own side.
    cases:=[?][2]Avoid_Agent(3){
        {{position={-5,2,0},radius=0.5},{position={5,2,0.01},radius=0.5}},
        {{position={-2,2,0},velocity={1.5,0,0},radius=0.5},{position={2,2,0},velocity={-1.5,0,0},radius=0.5}},
        {{position={0,-2,1},velocity={0,1.5,0},radius=0.5},{position={0,2,1},velocity={0,-1.5,0},radius=0.5}},
    }
    for &agents,c in cases {
        goals:=[]math.Vec3{agents[1].position,agents[0].position}
        gap:=avoid_simulate(agents[:],goals,1.5,400)
        testing.expectf(t,gap>-1e-3,"case %d: gap %v",c,gap)
        for agent,i in agents {testing.expectf(t,linalg.distance(agent.position,goals[i])<0.1,"case %d: agent %d at %v",c,i,agent.position)}
    }
}

@(test)
a_sphere_of_agents_swaps_sides_without_touching :: proc(t:^testing.T) {
    COUNT :: 20
    agents:[COUNT]Avoid_Agent(3)
    goals:[COUNT]math.Vec3
    golden:=math.PI*(3-cmath.sqrt(f32(5)))
    for i in 0..<COUNT {
        y:=1-2*(f32(i)+0.5)/COUNT
        ring:=cmath.sqrt(1-y*y)
        s,c:=cmath.sincos(f32(i)*golden)
        point:=math.Vec3{c*ring,y,s*ring}*8
        agents[i]={position=point,radius=0.4}
        goals[i]=-point
    }
    gap:=avoid_simulate(agents[:],goals[:],1.5,1200,6)
    testing.expectf(t,gap>-1e-3,"gap %v",gap)
    for agent,i in agents {testing.expectf(t,linalg.distance(agent.position,goals[i])<0.5,"agent %d at %v, goal %v",i,agent.position,goals[i])}
}

@(test)
agents_that_overlap_in_a_volume_are_pushed_apart :: proc(t:^testing.T) {
    agents:=[]Avoid_Agent(3){{position={0,0,0},radius=0.5},{position={0.2,0.2,0.1},radius=0.5}}
    goals:=[]math.Vec3{{0,0,0},{0.2,0.2,0.1}}
    avoid_simulate(agents,goals,2,30)
    testing.expect(t,linalg.distance(agents[0].position,agents[1].position)>=1-1e-2)
    same:=[]Avoid_Agent(3){{radius=0.5}}
    velocity:=avoid_velocity(Avoid_Agent(3){radius=0.5},{},2,same,2,AVOID_DT)
    testing.expect(t,avoid_finite(velocity))
    testing.expect(t,linalg.length(velocity)<=2+1e-4)
}

@(test)
a_crowd_squeezed_from_every_side_in_a_volume_still_gets_a_finite_velocity_within_the_limit :: proc(t:^testing.T) {
    // Neighbors toward the six faces and the eight corners of a cube.
    neighbors:[14]Avoid_Agent(3)
    count:=0
    for x in -1..=1 {
        for y in -1..=1 {
            for z in -1..=1 {
                if abs(x)+abs(y)+abs(z)==1 || abs(x)+abs(y)+abs(z)==3 {
                    d:=linalg.normalize(math.Vec3{f32(x),f32(y),f32(z)})
                    neighbors[count]={position=d*1.05,velocity=-d*3,radius=0.5}
                    count+=1
                }
            }
        }
    }
    velocity:=avoid_velocity(Avoid_Agent(3){radius=0.5},{1,0,0},1,neighbors[:],2,AVOID_DT)
    testing.expect(t,avoid_finite(velocity))
    testing.expect(t,linalg.length(velocity)<=1+1e-3)
}

@(test)
avoidance_in_a_volume_with_every_height_zero_matches_the_plane :: proc(t:^testing.T) {
    lift :: proc(v:math.Vec2) -> math.Vec3 {return {v.x,0,v.y}}
    check :: proc(t:^testing.T,round:int,self:Avoid_Agent(2),preferred:math.Vec2,max_speed:f32,flat:[]Avoid_Agent(2)) {
        raised:[16]Avoid_Agent(3)
        for other,i in flat {raised[i]={lift(other.position),lift(other.velocity),other.radius}}
        a:=avoid_velocity(self,preferred,max_speed,flat,2,AVOID_DT)
        b:=avoid_velocity(Avoid_Agent(3){lift(self.position),lift(self.velocity),self.radius},lift(preferred),max_speed,raised[:len(flat)],2,AVOID_DT)
        testing.expectf(t,near_vec(lift(a),b,1e-4),"round %d: %v on the plane, %v in the volume",round,a,b)
    }
    crowd:=avoid_squeezed_crowd()
    check(t,-1,{radius=0.5},{1,0},1,crowd[:])
    rng:=math.rng_make(11)
    flat:[12]Avoid_Agent(2)
    for round in 0..<400 {
        // From crowds where nothing is allowed to sparse ones.
        spread:=f32(1+round%4)
        for &other in flat {
            other={
                position={math.random_range(&rng,-spread,spread),math.random_range(&rng,-spread,spread)},
                velocity={math.random_range(&rng,-2,2),math.random_range(&rng,-2,2)},
                radius=math.random_range(&rng,0.2,0.6),
            }
        }
        self:=Avoid_Agent(2){velocity={math.random_range(&rng,-1.5,1.5),math.random_range(&rng,-1.5,1.5)},radius=0.4}
        preferred:=math.Vec2{math.random_range(&rng,-2,2),math.random_range(&rng,-2,2)}
        check(t,round,self,preferred,1.5,flat[:])
    }
}

// Two groups meet head-on in a corridor too narrow for them to pass side by
// side: how far the farthest of them got beyond a wall.
avoid_corridor_crowd :: proc(walls:[]Avoid_Wall) -> (beyond:f32) {
    COUNT :: 8
    agents:[COUNT]Avoid_Agent(2)
    goals:[COUNT]math.Vec2
    for i in 0..<COUNT {
        side:=f32(1 if i%2==0 else -1)
        agents[i]={position={-side*(3+f32(i/2)*1.1),f32(i%3-1)*0.45},radius=0.4}
        goals[i]={side*12,agents[i].position.y}
    }
    others:[COUNT]Avoid_Agent(2)
    next:[COUNT]math.Vec2
    for _ in 0..<900 {
        for agent,i in agents {
            count:=0
            for other,j in agents {if j!=i {others[count]=other;count+=1}}
            next[i]=avoid_velocity(agent,limit_length(goals[i]-agent.position,1.5),1.5,others[:count],2,AVOID_DT,walls,0.5)
        }
        for &agent,i in agents {
            agent.velocity=next[i]
            agent.position+=agent.velocity*AVOID_DT
            beyond=max(beyond,abs(agent.position.y)-1)
        }
    }
    return
}

@(test)
a_crowd_that_meets_in_a_corridor_does_not_cross_its_walls :: proc(t:^testing.T) {
    // Walked on the right of a to b: the upper wall runs toward +x, the lower one back.
    walls:=[]Avoid_Wall{{{-20,1},{20,1}},{{20,-1},{-20,-1}}}
    beyond:=avoid_corridor_crowd(walls)
    testing.expectf(t,beyond<=1e-3,"an agent got %v m beyond a wall",beyond)
    testing.expect(t,avoid_corridor_crowd(nil)>0.1,"The crowd fits the corridor without its walls: the case shows nothing")
}

@(test)
walls_forbid_what_crosses_them_and_a_corner_that_turns_away_leaves_a_side :: proc(t:^testing.T) {
    wall:=[]Avoid_Wall{{{-5,1},{5,1}}}
    // Away from the wall, only as fast toward it as reaches it at the horizon; along it, as preferred.
    toward:=avoid_velocity(Avoid_Agent(2){radius=0.4},{0,2},2,nil,2,AVOID_DT,wall,0.5)
    testing.expectf(t,toward.y<=2+1e-4 && toward.y>1,"toward the wall at %v",toward)
    near_wall:=[]Avoid_Wall{{{-5,0.25},{5,0.25}}}
    held:=avoid_velocity(Avoid_Agent(2){radius=0.4},{0,2},2,nil,2,AVOID_DT,near_wall,0.5)
    testing.expectf(t,held.y<=0.5+1e-3,"into the wall at %v",held)
    testing.expect(t,near_vec(avoid_velocity(Avoid_Agent(2){radius=0.4},{2,0},2,nil,2,AVOID_DT,near_wall,0.5),math.Vec2{2,0}))
    // On it: not into it, and along it as it wants.
    on:=[]Avoid_Wall{{{-5,0},{5,0}}}
    slid:=avoid_velocity(Avoid_Agent(2){radius=0.4},{1,1},2,nil,2,AVOID_DT,on,0.5)
    testing.expectf(t,near_vec(slid,math.Vec2{1,0}),"on the wall it moves at %v",slid)
    // Behind it, it is no wall of the agent.
    behind:=[]Avoid_Wall{{{-5,-1},{5,-1}}}
    testing.expect(t,near_vec(avoid_velocity(Avoid_Agent(2){radius=0.4},{0,1},2,nil,2,AVOID_DT,behind,0.5),math.Vec2{0,1}))
    // The corner of a pillar that fills x<0, y<0, with the agent on it: either side is walked.
    pillar:=[]Avoid_Wall{{{0,-5},{0,0}},{{0,0},{-5,0}}}
    testing.expect(t,near_vec(avoid_velocity(Avoid_Agent(2){radius=0.4},{0,-1},2,nil,2,AVOID_DT,pillar,0.5),math.Vec2{0,-1}))
    testing.expect(t,near_vec(avoid_velocity(Avoid_Agent(2){radius=0.4},{-1,0},2,nil,2,AVOID_DT,pillar,0.5),math.Vec2{-1,0}))
    into:=avoid_velocity(Avoid_Agent(2){radius=0.4},{-1,-1},2,nil,2,AVOID_DT,pillar,0.5)
    testing.expectf(t,!(into.x<-1e-4 && into.y<-1e-4),"into the pillar at %v",into)
    // The corner of a room that is walked where x>0 and y>0: both walls hold.
    room:=[]Avoid_Wall{{{5,0},{0,0}},{{0,0},{0,5}}}
    cornered:=avoid_velocity(Avoid_Agent(2){radius=0.4},{-1,-0.5},2,nil,2,AVOID_DT,room,0.5)
    testing.expectf(t,cornered.x>=-1e-4 && cornered.y>=-1e-4,"out of the corner at %v",cornered)
    // Walls that are no walls shape nothing.
    nan:=transmute(f32)u32(0x7fc00000)
    broken:=[]Avoid_Wall{{{1,1},{1,1}},{{nan,0},{1,nan}},{{max(f32),0},{-max(f32),0}}}
    testing.expect(t,avoid_finite(avoid_velocity(Avoid_Agent(2){radius=0.4},{1,0},2,nil,2,AVOID_DT,broken,nan)))
}
