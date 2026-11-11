package mirai_math

import "core:math"
import "core:math/linalg"

// Parametric curves over floats or vectors, with t from 0 to 1 along one segment.

bezier_quadratic :: proc "contextless" (p0,p1,p2:$T,t:f32) -> T {
    u:=1-t
    return p0*(u*u)+p1*(2*u*t)+p2*(t*t)
}
// The derivative with respect to t: the direction of travel, not unit.
bezier_quadratic_tangent :: proc "contextless" (p0,p1,p2:$T,t:f32) -> T {
    return (p1-p0)*(2*(1-t))+(p2-p1)*(2*t)
}
bezier_cubic :: proc "contextless" (p0,p1,p2,p3:$T,t:f32) -> T {
    u:=1-t
    return p0*(u*u*u)+p1*(3*u*u*t)+p2*(3*u*t*t)+p3*(t*t*t)
}
bezier_cubic_tangent :: proc "contextless" (p0,p1,p2,p3:$T,t:f32) -> T {
    u:=1-t
    return (p1-p0)*(3*u*u)+(p2-p1)*(6*u*t)+(p3-p2)*(3*t*t)
}
// From p0 to p1, leaving with derivative m0 and arriving with m1.
hermite :: proc "contextless" (p0,m0,p1,m1:$T,t:f32) -> T {
    t2:=t*t
    t3:=t2*t
    return p0*(2*t3-3*t2+1)+m0*(t3-2*t2+t)+p1*(-2*t3+3*t2)+m1*(t3-t2)
}
// The segment from p1 to p2 of the curve through the four points.
catmull_rom :: proc "contextless" (p0,p1,p2,p3:$T,t:f32) -> T {
    t2:=t*t
    t3:=t2*t
    return (p1*2+(p2-p0)*t+(p0*2-p1*5+p2*4-p3)*t2+(p1*3-p0-p2*3+p3)*t3)*0.5
}
catmull_rom_tangent :: proc "contextless" (p0,p1,p2,p3:$T,t:f32) -> T {
    return ((p2-p0)+(p0*2-p1*5+p2*4-p3)*(2*t)+(p1*3-p0-p2*3+p3)*(3*t*t))*0.5
}
// A segment of the uniform cubic B-spline of the four control points: it
// passes near them, not through them, and joins its neighbors smoothly.
b_spline :: proc "contextless" (p0,p1,p2,p3:$T,t:f32) -> T {
    t2:=t*t
    t3:=t2*t
    u:=1-t
    return (p0*(u*u*u)+p1*(3*t3-6*t2+4)+p2*(-3*t3+3*t2+3*t+1)+p3*t3)*(1.0/6)
}

// A point of a path, with what lies along it there: its width and height, and
// the speed of what goes along it (water, a walker).
Path_Point :: struct {
    position:Vec3,
    width,height:f32,
    speed:f32, // m/s toward the last point
}

// The point of a path at t, from 0 to 1, of its segment from points[segment]
// to the next, and the derivative of its position by t. x and z go along the
// Catmull-Rom curve through the points, whose ends go on straight; y goes
// between the heights of the two points without passing them (the monotone
// cubic of Fritsch and Carlson), so a path that never rises from point to point
// never rises between them; width, height and speed go in proportion. Zero for
// a segment the points do not have.
path_at :: proc "contextless" (points:[]Path_Point,segment:int,t:f32) -> (p:Path_Point,tangent:Vec3) #no_bounds_check {
    if segment<0 || segment>=len(points)-1 {return}
    a,b:=points[segment],points[segment+1]
    before:=segment>0?points[segment-1].position:2*a.position-b.position
    after:=segment+2<len(points)?points[segment+2].position:2*b.position-a.position
    // The slope of y at a point between two rises, zero where it turns or
    // stops, and at most three times the lesser rise, which keeps it monotone.
    slope :: proc "contextless" (y0,y1,y2:f32) -> f32 {
        d0,d1:=y1-y0,y2-y1
        if !(d0*d1>0) {return 0}
        return clamp(0.5*(d0+d1),-3*min(abs(d0),abs(d1)),3*min(abs(d0),abs(d1)))
    }
    m0:=slope(before.y,a.position.y,b.position.y)
    m1:=slope(a.position.y,b.position.y,after.y)
    p={catmull_rom(before,a.position,b.position,after,t),a.width+(b.width-a.width)*t,a.height+(b.height-a.height)*t,a.speed+(b.speed-a.speed)*t}
    // Hermite from the rise, so a level segment stays exactly level.
    p.position.y=a.position.y+(b.position.y-a.position.y)*(3*t*t-2*t*t*t)+m0*(t*t*t-2*t*t+t)+m1*(t*t*t-t*t)
    tangent=catmull_rom_tangent(before,a.position,b.position,after,t)
    tangent.y=(a.position.y-b.position.y)*(6*t*t-6*t)+m0*(3*t*t-4*t+1)+m1*(3*t*t-2*t)
    return
}

// A path through its points sampled by length: the points and, between two,
// more on its curve (path_at) about piece apart, or farther when out cannot
// hold that many. Returns how many it wrote: zero for fewer than two points, a
// piece that is not above zero, or an out with no room for one more sample
// than the points.
path_sample :: proc "contextless" (points:[]Path_Point,piece:f32,out:[]Path_Point) -> int {
    n:=len(points)
    room:=len(out)-n
    if n<2 || room<1 || !(piece>0) {return 0}
    whole:f32
    for i in 1..<n {whole+=linalg.length(points[i].position-points[i-1].position)}
    // Each span takes at most one piece more than its share, so the pieces fit.
    piece:=max(piece,whole/f32(room))
    count:=0
    for i in 0..<n-1 {
        steps:=clamp(int(min(math.ceil(linalg.length(points[i+1].position-points[i].position)/piece),1<<30)),1,len(out)-1-count-(n-2-i))
        for k in 0..<steps {
            out[count],_=path_at(points,i,f32(k)/f32(steps))
            count+=1
        }
    }
    out[count]=points[n-1]
    return count+1
}

// The box of the curve of a path (path_at) from points[segment] to the next.
// Its x and z are a cubic Bezier through those two points, so they stay within
// the box of the two and its two inner control points; y stays between their
// heights. Zero for a segment the points do not have.
path_segment_box :: proc "contextless" (points:[]Path_Point,segment:int) -> Aabb #no_bounds_check {
    if segment<0 || segment>=len(points)-1 {return {}}
    a,b:=points[segment].position,points[segment+1].position
    before:=segment>0?points[segment-1].position:2*a-b
    after:=segment+2<len(points)?points[segment+2].position:2*b-a
    inner:=[2]Vec3{a+(b-before)/6,b-(after-a)/6}
    box:=Aabb{vec3_min(vec3_min(a,b),vec3_min(inner[0],inner[1])),vec3_max(vec3_max(a,b),vec3_max(inner[0],inner[1]))}
    box.min.y,box.max.y=min(a.y,b.y),max(a.y,b.y)
    return box
}

// The box of the curve of a path, as wide as the path on each side.
path_box :: proc "contextless" (points:[]Path_Point) -> Aabb {
    box:=path_segment_box(points,0)
    for i in 0..<len(points)-1 {
        half:=max(points[i].width,points[i+1].width)*0.5
        span:=path_segment_box(points,i)
        box=aabb_merge(box,{span.min-{half,0,half},span.max+{half,0,half}})
    }
    return box
}


// Arc length table: lengths[i] is the length of the curve from its start to
// sample i, for points sampled at even steps of the parameter. Both slices
// have the same length. Returns the total length.
arc_table_build :: proc "contextless" (points:[]$V/[$N]f32,lengths:[]f32) -> f32 {
    total:f32
    for i in 0..<min(len(points),len(lengths)) {
        if i>0 {total+=linalg.length(points[i]-points[i-1])}
        lengths[i]=total
    }
    return total
}
// The parameter, from 0 to 1, at which the curve has run `distance`: what
// moves something along a curve at constant speed.
arc_table_parameter :: proc "contextless" (lengths:[]f32,distance:f32) -> f32 {
    last:=len(lengths)-1
    if last<1 || distance<=0 {return 0}
    if distance>=lengths[last] {return 1}
    low,high:=0,last
    for high-low>1 {
        middle:=(low+high)>>1
        if lengths[middle]<=distance {low=middle} else {high=middle}
    }
    span:=lengths[high]-lengths[low]
    within:=(distance-lengths[low])/span if span>0 else 0
    return (f32(low)+within)/f32(last)
}
// The length run at parameter t; 0 for a NaN t.
arc_table_distance :: proc "contextless" (lengths:[]f32,t:f32) -> f32 {
    last:=len(lengths)-1
    if last<1 || !(t>0) {return 0}
    if t>=1 {return lengths[last]}
    position:=t*f32(last)
    index:=min(int(position),last-1)
    return lengths[index]+(lengths[index+1]-lengths[index])*(position-f32(index))
}
