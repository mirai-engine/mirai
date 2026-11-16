package ai

import "core:math/linalg"

// Local avoidance between agents, by optimal reciprocal collision avoidance
// (ORCA, van den Berg et al.), in N dimensions: N=2 for agents that move on a
// plane (discs), N=3 for agents that fly or swim (spheres). Every neighbor
// forbids a half-space of velocities, the ones that would bring the two
// together within the time horizon, and each agent takes half of the change
// needed to leave it, or all of it toward one that does not step aside (a
// player, a moving body), met at its real velocity. On the plane, every wall
// near the agent forbids the velocities that would cross it within its own
// horizon, before any neighbor: what the walls forbid is never chosen,
// whatever the neighbors ask. The new velocity is the allowed one nearest to
// the preferred velocity, found with a linear program in N dimensions; when
// the half-spaces leave nothing, the one that violates those of the neighbors
// least. Agents that all run it do not collide and do not oscillate.

AVOID_MAX_NEIGHBORS :: #config(MIRAI_AVOID_MAX_NEIGHBORS,16)
AVOID_MAX_WALLS :: #config(MIRAI_AVOID_MAX_WALLS,8)
AVOID_WALL_TOUCH :: f32(0.01) // m from a wall within which an agent is on it

Avoid_Agent :: struct($N:int) {
    position,velocity:[N]f32,
    radius:f32,
    ignores:bool, // as a neighbor, it does not step aside: the agent takes the whole change
}

// A wall the center of an agent on the plane does not cross: the segment
// from a to b, walked on the side to its right ((d.y,-d.x) for the direction
// d from a to b). The walls of one boundary follow each other with that side
// kept: where one ends and the next begins, the corner is known to turn
// toward the agent or away from it.
Avoid_Wall :: struct {
    a,b:[2]f32,
}

// The velocities v with dot(v,normal)>=offset.
@(private)
Avoid_Plane :: struct($N:int) {
    normal:[N]f32, // unit
    offset:f32,
}
// The velocities v with dot(v-center,normals[k])==0 for each k below its
// depth, the number of planes it lies on; the normals are orthogonal to each
// other. `center` is the one nearest to the origin.
@(private)
Avoid_Space :: struct($N:int) {
    center:[N]f32,
    normals:[N][N]f32,
    inverses:[N]f32, // 1/length2 of each normal
}
@(private)
AVOID_EPSILON :: 1e-5

// The velocity for `self`, no faster than `max_speed` and as near to
// `preferred` as the walls and the neighbors allow. `horizon` is how far
// ahead, in seconds, collisions are avoided; `dt` is the step of the
// simulation, in which agents that already overlap are pushed apart. Only the
// AVOID_MAX_NEIGHBORS nearest neighbors count. On the plane, `walls` are those
// near the agent, nearest first, of which the first AVOID_MAX_WALLS count,
// and `wall_horizon` how far ahead, in seconds, it keeps from crossing them
// (at least dt). A wall the agent is behind is none of its own.
avoid_velocity :: proc "contextless" (self:Avoid_Agent($N),preferred:[N]f32,max_speed:f32,neighbors:[]Avoid_Agent(N),horizon,dt:f32,walls:[]Avoid_Wall=nil,wall_horizon:f32=0) -> [N]f32 {
    planes:[AVOID_MAX_WALLS+AVOID_MAX_NEIGHBORS]Avoid_Plane(N)
    fixed:=0
    when N==2 {fixed=avoid_wall_planes(self,preferred,walls,max(wall_horizon,dt),planes[:AVOID_MAX_WALLS])}
    nearest:[AVOID_MAX_NEIGHBORS]i32
    distances:[AVOID_MAX_NEIGHBORS]f32
    count:=0
    for other,index in neighbors {
        distance:=linalg.length2(other.position-self.position)
        if count==AVOID_MAX_NEIGHBORS && distance>=distances[count-1] {continue}
        slot:=min(count,AVOID_MAX_NEIGHBORS-1)
        for slot>0 && distances[slot-1]>distance {
            nearest[slot]=nearest[slot-1];distances[slot]=distances[slot-1]
            slot-=1
        }
        nearest[slot]=i32(index);distances[slot]=distance
        count=min(count+1,AVOID_MAX_NEIGHBORS)
    }
    inverse_horizon:=1/max(horizon,AVOID_EPSILON)
    for i in 0..<count {
        other:=neighbors[nearest[i]]
        relative_position:=other.position-self.position
        relative_velocity:=self.velocity-other.velocity
        distance2:=distances[i]
        combined:=self.radius+other.radius
        combined2:=combined*combined
        plane:Avoid_Plane(N)
        push:f32 // how far the relative velocity must move along the normal
        if distance2>combined2 {
            // From the cap of the velocities that collide at the horizon...
            w:=relative_velocity-relative_position*inverse_horizon
            w_length2:=linalg.length2(w)
            along:=linalg.dot(w,relative_position)
            if along<0 && along*along>combined2*w_length2 && w_length2>AVOID_EPSILON*AVOID_EPSILON {
                w_length:=linalg.sqrt(w_length2)
                plane.normal=w/w_length
                push=combined*inverse_horizon-w_length
            } else {
                // ...or from the nearer side of the cone behind it, whose
                // normal lies in the plane of the relative position and
                // velocity, or of a side when they are parallel.
                across,area2:=avoid_across(relative_position,relative_velocity)
                if area2<=AVOID_EPSILON*AVOID_EPSILON*distance2 {across,area2=avoid_across(relative_position,avoid_side(relative_position))}
                inverse:=1/(distance2*area2)
                spread:=linalg.sqrt((distance2-combined2)*distance2*inverse)
                plane.normal=(across*spread-relative_position*combined)*(area2*inverse)
                push=-linalg.dot(relative_velocity,plane.normal)
            }
        } else {
            // Already overlapping: be apart after one step.
            inverse_dt:=1/max(dt,AVOID_EPSILON)
            w:=relative_velocity-relative_position*inverse_dt
            w_length:=linalg.length(w)
            if w_length>AVOID_EPSILON {plane.normal=w/w_length} else {plane.normal[0]=1}
            push=combined*inverse_dt-w_length
        }
        plane.offset=linalg.dot(self.velocity,plane.normal)+push*(1 if other.ignores else 0.5)
        planes[fixed+i]=plane
    }
    count+=fixed
    result,failed:=#force_inline avoid_program(planes[:count],Avoid_Space(N){},max_speed,preferred,false,0)
    if failed<count {result=avoid_least_violation(planes[:count],failed,fixed,max_speed,result)}
    return result
}

// The half-planes of the walls near an agent on the plane, written to
// `planes`; how many. A wall away from the agent forbids the velocities that
// reach it within the horizon: the cone from the agent to its two ends, cut
// at the wall, linearized at the side of it nearest to the velocity of the
// agent. That part is adapted from the obstacle lines of the RVO2 Library
// (Agent.cpp, computeNewVelocity; Apache License 2.0, Copyright 2008
// University of North Carolina at Chapel Hill), for an agent that is a point
// to the walls. A wall the agent is on forbids moving into it; at the
// corner of two walls that turns away from the agent (a pillar), only the one
// of the two the preferred velocity breaks least, as either side is walked.
@(private)
avoid_wall_planes :: proc "contextless" (self:Avoid_Agent(2),preferred:[2]f32,walls:[]Avoid_Wall,horizon:f32,planes:[]Avoid_Plane(2)) -> (count:int) {
    inverse:=1/max(horizon,AVOID_EPSILON)
    near:=walls[:min(len(walls),AVOID_MAX_WALLS)]
    for wall,index in near {
        if count>=len(planes) {break}
        direction,open,length,valid:=avoid_wall_frame(wall)
        if !valid {continue}
        left,right:=wall.a-self.position,wall.b-self.position
        distance:=-linalg.dot(left,open)   // from its line, on the side that is walked
        along:=-linalg.dot(left,direction) // from a toward b
        if !(distance>=-AVOID_WALL_TOUCH) {continue}
        if distance<=AVOID_WALL_TOUCH {
            // Edge-on beyond an end it is no wall of here: those that meet it at that end are.
            if along<-AVOID_WALL_TOUCH || along>length+AVOID_WALL_TOUCH {continue}
            at_start,at_end:=along<=AVOID_WALL_TOUCH,along>=length-AVOID_WALL_TOUCH
            keeps:=true
            if at_start || at_end {
                corner:=wall.a if at_start else wall.b
                keeps=false
                for other,k in near {
                    if k==index {continue}
                    other_direction,other_open,_,other_valid:=avoid_wall_frame(other)
                    if !other_valid {continue}
                    touch2:=AVOID_WALL_TOUCH*AVOID_WALL_TOUCH
                    // The wall that comes to this corner, or goes on from it.
                    joins:=other.b if at_start else other.a
                    if linalg.length2(joins-corner)>touch2 {
                        // Two boundaries that touch at a point: both hold.
                        meets:=other.a if at_start else other.b
                        if linalg.length2(meets-corner)<=touch2 {keeps=true}
                        continue
                    }
                    incoming,outgoing:=other_direction,direction
                    if at_end {incoming,outgoing=direction,other_direction}
                    turns_away:=incoming.x*outgoing.y-incoming.y*outgoing.x>0
                    mine,theirs:=linalg.dot(preferred,open),linalg.dot(preferred,other_open)
                    keeps=!turns_away || mine>theirs || mine==theirs && at_end
                    break
                }
            }
            if keeps {
                planes[count]={open,0}
                count+=1
            }
            continue
        }
        left_cut,right_cut:=left*inverse,right*inverse
        covered:=false
        for plane in planes[:count] {
            if linalg.dot(left_cut,plane.normal)<=plane.offset+AVOID_EPSILON && linalg.dot(right_cut,plane.normal)<=plane.offset+AVOID_EPSILON {covered=true;break}
        }
        if covered {continue}
        left_leg,right_leg:=linalg.normalize0(left),linalg.normalize0(right)
        cut:=right_cut-left_cut
        t:=linalg.dot(self.velocity-left_cut,cut)/linalg.length2(cut)
        t_left:=linalg.dot(self.velocity-left_cut,left_leg)
        t_right:=linalg.dot(self.velocity-right_cut,right_leg)
        plane:Avoid_Plane(2)
        switch {
        case t<0 && t_left<0:
            // Nearest to the left end of the cut: around it.
            w:=linalg.normalize0(self.velocity-left_cut)
            if w=={} {w=open}
            plane={w,linalg.dot(left_cut,w)}
        case t>1 && t_right<0:
            w:=linalg.normalize0(self.velocity-right_cut)
            if w=={} {w=open}
            plane={w,linalg.dot(right_cut,w)}
        case:
            to_cut:=max(f32) if t<0 || t>1 else linalg.length2(self.velocity-(left_cut+cut*t))
            to_left:=max(f32) if t_left<0 else linalg.length2(self.velocity-(left_cut+left_leg*t_left))
            to_right:=max(f32) if t_right<0 else linalg.length2(self.velocity-(right_cut+right_leg*t_right))
            if to_cut<=to_left && to_cut<=to_right {
                plane={open,linalg.dot(left_cut,open)}
            } else if to_left<=to_right {
                plane={{-left_leg.y,left_leg.x},0}
            } else {
                plane={{right_leg.y,-right_leg.x},0}
            }
        }
        planes[count]=plane
        count+=1
    }
    return
}

// The direction of a wall from a to b, the side it is walked on and its
// length; not valid for one without length or that is not finite.
@(private)
avoid_wall_frame :: #force_inline proc "contextless" (wall:Avoid_Wall) -> (direction,open:[2]f32,length:f32,valid:bool) {
    along:=wall.b-wall.a
    length2:=linalg.length2(along)
    if !(length2>AVOID_EPSILON*AVOID_EPSILON) || !(length2<=max(f32)) || !(abs(wall.a.x)<=max(f32)) || !(abs(wall.a.y)<=max(f32)) {return}
    length=linalg.sqrt(length2)
    direction=along/length
    return direction,{direction.y,-direction.x},length,true
}

// A vector perpendicular to `axis` that turns with it, so that agents that
// meet head-on step to opposite sides: a quarter turn in the plane of the
// first and last coordinates (the ground, with y up), or of the first two
// when the axis is nearly perpendicular to that plane.
@(private)
avoid_side :: proc "contextless" (axis:[$N]f32) -> [N]f32 {
    side:[N]f32
    side[0],side[N-1]=axis[N-1],-axis[0]
    if linalg.length2(side)<0.25*linalg.length2(axis) {
        side={}
        side[0],side[1]=axis[1],-axis[0]
    }
    return side
}

// `v` without its part along `p`, times length2(p), and the square of the
// area between them, length2(p)*length2(v)-dot(p,v)^2, both from the
// determinants of each two coordinates so that they do not cancel out when
// the two are nearly parallel.
@(private)
avoid_across :: proc "contextless" (p,v:[$N]f32) -> (across:[N]f32,area2:f32) {
    for i in 0..<N {
        for j in i+1..<N {
            w:=p[i]*v[j]-p[j]*v[i]
            across[i]-=p[j]*w
            across[j]+=p[i]*w
            area2+=w*w
        }
    }
    return
}

// `v` without its parts along the normals of `space`. When `v` is nearly
// along them, what is left keeps some rounding along them: flattening it
// again removes it.
@(private)
avoid_flatten :: proc "contextless" (space:Avoid_Space($N),v:[N]f32,$DEPTH:int) -> [N]f32 {
    v:=v
    when DEPTH>0 {
        for k in 0..<DEPTH {v-=space.normals[k]*(linalg.dot(v,space.normals[k])*space.inverses[k])}
    }
    return v
}

// Narrows `space` to the boundary of `plane`; false when they are parallel.
@(private)
avoid_restrict :: proc "contextless" (space:^Avoid_Space($N),plane:Avoid_Plane(N),$DEPTH:int) -> bool {
    normal:=plane.normal
    inverse:f32=1
    when DEPTH>0 {
        normal=avoid_flatten(space^,avoid_flatten(space^,normal,DEPTH),DEPTH)
        length2:=linalg.length2(normal)
        if !(length2>AVOID_EPSILON*AVOID_EPSILON) {return false}
        inverse=1/length2
    }
    space.center+=normal*((plane.offset-linalg.dot(space.center,plane.normal))*inverse)
    space.normals[DEPTH]=normal
    space.inverses[DEPTH]=inverse
    return true
}

// Two orthogonal directions of `space` when it is a plane (DEPTH==N-2), with
// 1/length2 of each: the two axes least along its normals, without those
// parts.
@(private)
avoid_span :: proc "contextless" (space:Avoid_Space($N),$DEPTH:int) -> (span:[2][N]f32,inverses:[2]f32) {
    for s in 0..<2 {
        axis:=0
        least:=max(f32)
        for a in 0..<N {
            weight:f32
            when DEPTH>0 {
                for k in 0..<DEPTH {weight+=space.normals[k][a]*space.normals[k][a]*space.inverses[k]}
            }
            if s==1 {weight+=span[0][a]*span[0][a]*inverses[0]}
            if weight<least {axis,least=a,weight}
        }
        v:[N]f32
        for a in 0..<N {v[a]=1 if a==axis else 0}
        v=avoid_flatten(space,v,DEPTH)
        if s==1 {v-=span[0]*(linalg.dot(v,span[0])*inverses[0])}
        span[s]=v
        inverses[s]=1/linalg.length2(v)
    }
    return
}

// The velocity of `space` (of two or more dimensions) no further than
// `radius` from the origin that every plane allows and is nearest to
// `objective`, or furthest along it when it is a unit direction. When the
// best velocity so far breaks a plane, the best one lies on its boundary: the
// planes before it are solved again in that smaller space, down to a line.
// `failed` is the first plane that could not be satisfied, the number of
// planes, or -1 when the space misses the ball.
@(private)
avoid_program :: proc "contextless" (planes:[]Avoid_Plane($N),space:Avoid_Space(N),radius:f32,objective:[N]f32,direction:bool,$DEPTH:int) -> (result:[N]f32,failed:int) {
    room:=radius*radius-linalg.length2(space.center)
    if room<0 {return space.center,-1}
    toward:=avoid_flatten(space,avoid_flatten(space,objective,DEPTH),DEPTH)
    length2:=linalg.length2(toward)
    if direction {
        when DEPTH==0 {
            result=objective*radius
        } else {
            result=space.center+toward*linalg.sqrt(room/length2) if length2>AVOID_EPSILON*AVOID_EPSILON else space.center
        }
    } else {
        result=space.center+toward
        if linalg.length2(result)>radius*radius {result=space.center+toward*linalg.sqrt(room/length2)}
    }
    when DEPTH+2==N {span,span_inverses:=avoid_span(space,DEPTH)}
    for plane,i in planes {
        if linalg.dot(result,plane.normal)<plane.offset {
            boundary:=space
            if !avoid_restrict(&boundary,plane,DEPTH) {return result,i}
            next:[N]f32
            inner:int
            when DEPTH+2==N {
                // In a plane, the boundary is the line across the normal.
                along:=span[0]*linalg.dot(plane.normal,span[1])-span[1]*linalg.dot(plane.normal,span[0])
                when DEPTH>0 {along-=boundary.normals[DEPTH]*(linalg.dot(along,boundary.normals[DEPTH])*boundary.inverses[DEPTH])}
                next,inner=avoid_program_line(planes[:i],boundary.center,along,span_inverses[0]*span_inverses[1]*boundary.inverses[DEPTH],radius,objective,direction)
            } else {
                next,inner=avoid_program(planes[:i],boundary,radius,objective,direction,DEPTH+1)
            }
            if inner<i {return result,i}
            result=next
        }
    }
    return result,len(planes)
}

// avoid_program on the line through `center` (its point nearest to the
// origin) along `along`, where the planes leave an interval of it. `inverse`
// is 1/length2(along).
@(private)
avoid_program_line :: proc "contextless" (planes:[]Avoid_Plane($N),center,along:[N]f32,inverse,radius:f32,objective:[N]f32,direction:bool) -> (result:[N]f32,failed:int) {
    room:=radius*radius-linalg.length2(center)
    if room<0 {return center,-1}
    reach:=linalg.sqrt(room*inverse)
    low,high:=-reach,reach
    for plane,i in planes {
        rate:=linalg.dot(along,plane.normal)
        offset:=linalg.dot(center,plane.normal)-plane.offset
        if rate*rate*inverse<=AVOID_EPSILON*AVOID_EPSILON {
            if offset<0 {return center,i}
            continue
        }
        t:=-offset/rate
        if rate>0 {low=max(low,t)} else {high=min(high,t)}
        if low>high {return center,i}
    }
    t:f32
    if !direction {
        t=linalg.dot(along,objective-center)*inverse
    } else {
        toward:=linalg.dot(along,objective)
        if toward*toward*inverse>AVOID_EPSILON*AVOID_EPSILON {t=high if toward>0 else low}
    }
    return center+along*clamp(t,low,high),len(planes)
}

// With no velocity that every plane allows, the one that goes least far into
// the forbidden side of any of them past the first `fixed`, the walls, which
// stay as they are.
@(private)
avoid_least_violation :: proc "contextless" (planes:[]Avoid_Plane($N),begin,fixed:int,radius:f32,start:[N]f32) -> [N]f32 {
    result:=start
    distance:f32
    projected:[AVOID_MAX_WALLS+AVOID_MAX_NEIGHBORS]Avoid_Plane(N)
    copy(projected[:fixed],planes[:fixed])
    for i in begin..<len(planes) {
        plane:=planes[i]
        if plane.offset-linalg.dot(result,plane.normal)<=distance {continue}
        count:=fixed
        if i>fixed {
            for other in planes[fixed:i] {
                // Where the two are broken alike; nowhere, when they face the same way.
                normal:=other.normal-plane.normal
                length2:=linalg.length2(normal)
                if length2<=AVOID_EPSILON*AVOID_EPSILON {continue}
                inverse:=1/linalg.sqrt(length2)
                projected[count]={normal*inverse,(other.offset-plane.offset)*inverse}
                count+=1
            }
        }
        candidate,failed:=#force_inline avoid_program(projected[:count],Avoid_Space(N){},radius,plane.normal,true,0)
        if failed==count {result=candidate}
        distance=plane.offset-linalg.dot(result,plane.normal)
    }
    return result
}
