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

// A point of a path, with the width and the height of what lies along it there.
Path_Point :: struct {
    position:Vec3,
    width,height:f32,
}

// A path through its points sampled by length: the points and, between two,
// more on the Catmull-Rom curve through them about piece apart, or farther
// when out cannot hold that many, with width and height in proportion. The
// ends go on straight. Returns how many it wrote: zero for fewer than two
// points, a piece that is not above zero, or an out with no room for one more
// sample than the points.
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
        a,b:=points[i],points[i+1]
        before:=i>0?points[i-1].position:2*a.position-b.position
        after:=i+2<n?points[i+2].position:2*b.position-a.position
        steps:=clamp(int(min(math.ceil(linalg.length(b.position-a.position)/piece),1<<30)),1,len(out)-1-count-(n-2-i))
        for k in 0..<steps {
            t:=f32(k)/f32(steps)
            out[count]={catmull_rom(before,a.position,b.position,after,t),a.width+(b.width-a.width)*t,a.height+(b.height-a.height)*t}
            count+=1
        }
    }
    out[count]=points[n-1]
    return count+1
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
