package mirai_math

import "core:math/linalg"

// Closest points. A point inside a solid shape is its own closest point.

closest_point_plane :: proc "contextless" (point:Vec3,plane:Plane) -> Vec3 {
    return point-plane.normal*plane_distance(plane,point)
}
closest_point_aabb :: #force_inline proc "contextless" (point:Vec3,box:Aabb) -> Vec3 {
    return vec3_max(box.min,vec3_min(point,box.max))
}
closest_point_obb :: proc "contextless" (point:Vec3,box:Obb) -> Vec3 {
    local:=quat_rotate(conj(box.rotation),point-box.center)
    return box.center+quat_rotate(box.rotation,vec3_max(-box.half,vec3_min(local,box.half)))
}
// t is where the closest point lies along the segment: 0 at a, 1 at b.
closest_point_segment :: proc "contextless" (point:Vec3,segment:Segment) -> (closest:Vec3,t:f32) {
    direction:=segment.b-segment.a
    length_squared:=linalg.dot(direction,direction)
    if length_squared<1e-12 {return segment.a,0}
    t=clamp(linalg.dot(point-segment.a,direction)/length_squared,0,1)
    return segment.a+direction*t,t
}
// The pair of closest points of two segments, and where each lies along its segment.
closest_segment_segment :: proc "contextless" (first,second:Segment) -> (on_first,on_second:Vec3,s,t:f32) {
    d1,d2:=first.b-first.a,second.b-second.a
    r:=first.a-second.a
    a,e:=linalg.dot(d1,d1),linalg.dot(d2,d2)
    f:=linalg.dot(d2,r)
    switch {
    case a<1e-12 && e<1e-12:
        return first.a,second.a,0,0
    case a<1e-12:
        t=clamp(f/e,0,1)
    case:
        c:=linalg.dot(d1,r)
        if e<1e-12 {
            s=clamp(-c/a,0,1)
        } else {
            b:=linalg.dot(d1,d2)
            denominator:=a*e-b*b
            if denominator>1e-9*a*e {s=clamp((b*f-c*e)/denominator,0,1)}
            t=(b*s+f)/e
            if t<0 {
                t=0;s=clamp(-c/a,0,1)
            } else if t>1 {
                t=1;s=clamp((b-c)/a,0,1)
            }
        }
    }
    return first.a+d1*s,second.a+d2*t,s,t
}
closest_point_triangle :: proc "contextless" (point:Vec3,triangle:Triangle) -> Vec3 {
    a,b,c:=triangle.a,triangle.b,triangle.c
    ab,ac,ap:=b-a,c-a,point-a
    d1,d2:=linalg.dot(ab,ap),linalg.dot(ac,ap)
    if d1<=0 && d2<=0 {return a}
    bp:=point-b
    d3,d4:=linalg.dot(ab,bp),linalg.dot(ac,bp)
    if d3>=0 && d4<=d3 {return b}
    vc:=d1*d4-d3*d2
    if vc<=0 && d1>=0 && d3<=0 {return a+ab*(d1/(d1-d3))}
    cp:=point-c
    d5,d6:=linalg.dot(ab,cp),linalg.dot(ac,cp)
    if d6>=0 && d5<=d6 {return c}
    vb:=d5*d2-d1*d6
    if vb<=0 && d2>=0 && d6<=0 {return a+ac*(d2/(d2-d6))}
    va:=d3*d6-d5*d4
    if va<=0 && d4-d3>=0 && d5-d6>=0 {return b+(c-b)*((d4-d3)/((d4-d3)+(d5-d6)))}
    total:=va+vb+vc
    if abs(total)<1e-20 {return a}
    return a+ab*(vb/total)+ac*(vc/total)
}
