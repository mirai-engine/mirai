package mirai_physics

import cmath "core:math"
import math "mirai:std/math"

// Water along a path: the points of a curve (math.path_at), each with the
// width of the water there, its height, which is its depth, and the speed it
// flows at toward the last point. The surface goes along the curve, never
// rising from the first point to the last, and is level across, between banks
// at half the width on each side; the floor is the depth under it. It ends at
// its first and its last point. The current of its Fluid_Desc is what flows
// across (+X to the right) and up (+Y); along it flows by the speed of its
// points. Bodies float and drift in it, and the water draws it, from this one
// curve.

FLUID_PATH_POINTS :: 64

Path_Point :: math.Path_Point

@(private)
path_valid :: proc "contextless" (path:[]Path_Point) -> bool {
    if len(path)<2 || len(path)>FLUID_PATH_POINTS {return false}
    for p,i in path {
        if !is_finite3(p.position) || !(p.width>0 && p.width<=max(f32)) || !(p.height>0 && p.height<=max(f32)) || !(abs(p.speed)<=max(f32)) {return false}
        if i>0 {
            q:=path[i-1].position
            if !((p.position.x-q.x)*(p.position.x-q.x)+(p.position.z-q.z)*(p.position.z-q.z)>1e-6) {return false}
        }
    }
    return true
}

// Where a path is nearest over (x, z): the point of its curve there, the way it goes there (unit) and the
// segment it is on; inside when (x, z) is between its banks and its ends.
@(private)
Path_Spot :: struct {
    point:Path_Point,
    along:Vec3,
    segment:i32,
    inside:bool,
}

@(private) PATH_PIECES :: 8 // chords of a segment the nearest point starts from, before Newton refines it

// The nearest point over (x, z) of segment j of a path: its t and the square of its distance seen from above.
@(private)
path_segment_nearest :: proc "contextless" (points:[]Path_Point,j:int,x,z:f32) -> (t,far:f32) #no_bounds_check {
    a,b:=points[j].position,points[j+1].position
    before:=j>0?points[j-1].position:2*a-b
    after:=j+2<len(points)?points[j+2].position:2*b-a
    // The curve seen from above as c0 + c1 t + c2 t^2 + c3 t^3, from (x, z).
    flat :: #force_inline proc "contextless" (v:Vec3) -> [2]f32 {return {v.x,v.z}}
    p0,p1,p2,p3:=flat(before),flat(a),flat(b),flat(after)
    c0:=p1-{x,z}
    c1:=0.5*(p2-p0)
    c2:=0.5*(2*p0-5*p1+4*p2-p3)
    c3:=0.5*(3*p1-p0-3*p2+p3)
    at :: #force_inline proc "contextless" (c0,c1,c2,c3:[2]f32,t:f32) -> [2]f32 {return c0+t*(c1+t*(c2+t*c3))}
    far=max(f32)
    from:=at(c0,c1,c2,c3,0)
    for k in 1..=PATH_PIECES {
        u:=f32(k)/PATH_PIECES
        to:=at(c0,c1,c2,c3,u)
        chord:=to-from
        long:=chord.x*chord.x+chord.y*chord.y
        s:=long>0?clamp(-(from.x*chord.x+from.y*chord.y)/long,0,1):0
        off:=from+chord*s
        if d:=off.x*off.x+off.y*off.y;d<far {far,t=d,u+(s-1)/PATH_PIECES}
        from=to
    }
    // Newton on the derivative of the square distance, which is zero at the nearest point.
    for _ in 0..<3 {
        c:=at(c0,c1,c2,c3,t)
        d1:=c1+t*(2*c2+t*3*c3)
        d2:=2*c2+t*6*c3
        slope:=c.x*d1.x+c.y*d1.y
        curve:=d1.x*d1.x+d1.y*d1.y+c.x*d2.x+c.y*d2.y
        if !(curve>0) {break}
        t=clamp(t-slope/curve,0,1)
    }
    c:=at(c0,c1,c2,c3,t)
    return t,min(far,c.x*c.x+c.y*c.y)
}

// The spot of a path over (x, z). From a segment where the last spot was, it looks there and at the two
// next to it, and at all of them when the nearest is at the edge of those; from -1 at all of them, past
// the segments whose box is farther than the nearest yet.
@(private)
path_spot :: proc "contextless" (points:[]Path_Point,x,z:f32,hint:i32=-1) -> (spot:Path_Spot) #no_bounds_check {
    last:=len(points)-2
    best:=max(f32)
    t:f32
    j:=-1
    if hint>=0 && int(hint)<=last {
        lo,hi:=max(int(hint)-1,0),min(int(hint)+1,last)
        for k in lo..=hi {
            u,far:=path_segment_nearest(points,k,x,z)
            if far<best {best,t,j=far,u,k}
        }
        if j==lo && t<=0 && lo>0 || j==hi && t>=1 && hi<last {j=-1}
    }
    if j<0 {
        best=max(f32)
        for k in 0..=last {
            box:=math.path_segment_box(points,k)
            dx,dz:=max(box.min.x-x,x-box.max.x,0),max(box.min.z-z,z-box.max.z,0)
            if dx*dx+dz*dz>=best {continue}
            u,far:=path_segment_nearest(points,k,x,z)
            if far<best {best,t,j=far,u,k}
        }
    }
    if j<0 {return} // (x, z) is not finite
    p,tangent:=math.path_at(points,j,t)
    spot={point=p,along=normalize(tangent),segment=i32(j)}
    off:=Vec3{x,p.position.y,z}-p.position
    spot.inside=best<=0.25*p.width*p.width && !(j==0 && t<=0 && dot(off,tangent)<0) && !(j==last && t>=1 && dot(off,tangent)>0)
    return
}

// The normal of the surface of a path where it goes along `along`: level across, sloped along.
@(private)
path_normal :: #force_inline proc "contextless" (along:Vec3) -> Vec3 {
    across:=cmath.sqrt(along.x*along.x+along.z*along.z)
    if !(across>0) {return UP}
    return normalize(Vec3{-along.x*along.y,across*across,-along.z*along.y})
}

// The current of a path at a spot: along it by the speed there, across and up by `current`.
@(private)
path_current :: #force_inline proc "contextless" (spot:Path_Spot,current:Vec3) -> Vec3 {
    right:=normalize(Vec3{-spot.along.z,0,spot.along.x})
    return right*current.x+UP*current.y+spot.along*spot.point.speed
}

// The banks and the floor of a path at a spot, as outward planes.
@(private)
path_planes :: proc "contextless" (spot:Path_Spot) -> [3]Plane {
    side:=normalize(Vec3{-spot.along.z,0,spot.along.x})
    n:=path_normal(spot.along)
    center,half:=spot.point.position,0.5*spot.point.width
    return {{side,dot(side,center)+half},{-side,-dot(side,center)+half},{-n,-dot(n,center-UP*spot.point.height)}}
}

// The box of a path, down to its floor.
@(private)
path_aabb :: proc "contextless" (points:[]Path_Point) -> Aabb {
    box:=math.path_box(points)
    for k in 0..<len(points)-1 {
        a,b:=points[k],points[k+1]
        box.min.y=min(box.min.y,min(a.position.y,b.position.y)-max(a.height,b.height))
    }
    return box
}
