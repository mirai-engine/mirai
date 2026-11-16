package mirai_physics

import cmath "core:math"

// Convex shape for GJK in a local frame: the hull of a point set swept by a disc of radius `disc` in the local
// XZ plane, inflated by `radius`. Points on the Y axis and a disc make a cylinder. The points belong to the
// caller (hull vertices or a small array on the stack). At most 255 points.
Proxy :: struct {points:[]Vec3,radius:f32,disc:f32}

// Index of the point farthest along a direction; the lowest index wins ties.
proxy_support :: proc "contextless" (p:Proxy,direction:Vec3) -> int #no_bounds_check {
    best:=0
    best_value:=dot(p.points[0],direction)
    for i in 1..<len(p.points) {
        value:=dot(p.points[i],direction)
        if value>best_value {best_value=value;best=i}
    }
    return best
}

// The point of the disc farthest along a direction; its center when the direction is along Y.
@(private)
disc_support :: #force_inline proc "contextless" (disc:f32,direction:Vec3) -> Vec3 {
    l2:=direction.x*direction.x+direction.z*direction.z
    if !(l2>1e-24) {return {}}
    s:=disc/cmath.sqrt(l2)
    return {direction.x*s,0,direction.z*s}
}

// Index of the farthest point and the farthest point of the core, the disc included.
@(private)
proxy_support_point :: #force_inline proc "contextless" (p:Proxy,direction:Vec3) -> (int,Vec3) #no_bounds_check {
    i:=proxy_support(p,direction)
    if p.disc==0 {return i,p.points[i]}
    return i,p.points[i]+disc_support(p.disc,direction)
}
