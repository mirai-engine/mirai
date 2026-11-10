package mirai_math

import "core:math"
import "core:math/linalg"
import "core:simd"

// Ray queries. The direction need not be unit: t is in units of its length,
// so the hit is ray_at(ray,t) and t stays the same when a ray is moved to
// another space with a matrix. Only hits with t >= 0 count. A ray that starts
// inside a solid shape hits where it leaves it.

// The plane is hit from either side.
ray_plane :: proc "contextless" (ray:Ray,plane:Plane) -> (t:f32,hit:bool) {
    slope:=linalg.dot(ray.direction,plane.normal)
    if abs(slope)<1e-12 {return 0,false}
    t=-plane_distance(plane,ray.origin)/slope
    return t,t>=0
}

ray_aabb :: proc "contextless" (ray:Ray,box:Aabb) -> (t:f32,normal:Vec3,hit:bool) {
    low,high:=f32(-math.F32_MAX),f32(math.F32_MAX)
    low_axis,high_axis:=0,0
    for axis in 0..<3 {
        if abs(ray.direction[axis])<1e-12 {
            if ray.origin[axis]<box.min[axis] || ray.origin[axis]>box.max[axis] {return}
            continue
        }
        a:=(box.min[axis]-ray.origin[axis])/ray.direction[axis]
        b:=(box.max[axis]-ray.origin[axis])/ray.direction[axis]
        if a>b {a,b=b,a}
        if a>low {low=a;low_axis=axis}
        if b<high {high=b;high_axis=axis}
        if low>high {return}
    }
    if high<0 || high==math.F32_MAX {return}
    if low>=0 {
        normal[low_axis]=-1 if ray.direction[low_axis]>0 else 1
        return low,normal,true
    }
    normal[high_axis]=1 if ray.direction[high_axis]>0 else -1
    return high,normal,true
}
// The test a hierarchy traversal repeats: no normal, and the reciprocal of the
// direction computed once by the caller. A direction component of 0 must give
// an infinite reciprocal of either sign; a ray that runs exactly along a face
// of the box may then be reported as a miss.
ray_aabb_fast :: #force_inline proc "contextless" (origin,inverse_direction:Vec3,box:Aabb,t_max:f32) -> (t:f32,hit:bool) {
    a:=(box.min-origin)*inverse_direction
    b:=(box.max-origin)*inverse_direction
    near,far:=vec3_min(a,b),vec3_max(a,b)
    enter:=float_max(float_max(near.x,near.y),float_max(near.z,0))
    exit:=float_min(float_min(far.x,far.y),float_min(far.z,t_max))
    return enter,enter<=exit
}

ray_obb :: proc "contextless" (ray:Ray,box:Obb) -> (t:f32,normal:Vec3,hit:bool) {
    inverse:=conj(box.rotation)
    local:=Ray{quat_rotate(inverse,ray.origin-box.center),quat_rotate(inverse,ray.direction)}
    t,normal,hit=ray_aabb(local,{-box.half,box.half})
    return t,quat_rotate(box.rotation,normal),hit
}

ray_sphere :: proc "contextless" (ray:Ray,sphere:Sphere) -> (t:f32,normal:Vec3,hit:bool) {
    offset:=ray.origin-sphere.center
    a:=linalg.dot(ray.direction,ray.direction)
    if a<1e-24 {return}
    b:=linalg.dot(offset,ray.direction)
    c:=linalg.dot(offset,offset)-sphere.radius*sphere.radius
    discriminant:=b*b-a*c
    if discriminant<0 {return}
    root:=math.sqrt(discriminant)
    t=(-b-root)/a
    if t<0 {t=(-b+root)/a}
    if t<0 {return 0,{},false}
    return t,linalg.normalize0(ray_at(ray,t)-sphere.center),true
}

ray_capsule :: proc "contextless" (ray:Ray,capsule:Capsule) -> (t:f32,normal:Vec3,hit:bool) {
    axis:=capsule.b-capsule.a
    axis_squared:=linalg.dot(axis,axis)
    if axis_squared<1e-12 {return ray_sphere(ray,{capsule.a,capsule.radius})}
    best:=f32(math.F32_MAX)
    // The side: the cylinder around the axis, between its two ends.
    offset:=ray.origin-capsule.a
    direction_squared:=linalg.dot(ray.direction,ray.direction)
    axis_direction,axis_offset:=linalg.dot(axis,ray.direction),linalg.dot(axis,offset)
    a:=axis_squared*direction_squared-axis_direction*axis_direction
    if a>1e-9*axis_squared*direction_squared {
        b:=axis_squared*linalg.dot(offset,ray.direction)-axis_offset*axis_direction
        c:=axis_squared*linalg.dot(offset,offset)-axis_offset*axis_offset-capsule.radius*capsule.radius*axis_squared
        discriminant:=b*b-a*c
        if discriminant<0 {return}
        root:=math.sqrt(discriminant)
        for candidate in ([2]f32{(-b-root)/a,(-b+root)/a}) {
            along:=axis_offset+candidate*axis_direction
            if candidate<0 || candidate>=best || along<0 || along>axis_squared {continue}
            best=candidate
            normal=(offset+ray.direction*candidate-axis*(along/axis_squared))/capsule.radius
            hit=true
        }
    }
    // The ends: the half of each sphere that looks away from the other end.
    for center,end in ([2]Vec3{capsule.a,capsule.b}) {
        from:=ray.origin-center
        b:=linalg.dot(from,ray.direction)
        c:=linalg.dot(from,from)-capsule.radius*capsule.radius
        discriminant:=b*b-direction_squared*c
        if discriminant<0 || direction_squared<1e-24 {continue}
        root:=math.sqrt(discriminant)
        for candidate in ([2]f32{(-b-root)/direction_squared,(-b+root)/direction_squared}) {
            if candidate<0 || candidate>=best {continue}
            outward:=from+ray.direction*candidate
            side:=linalg.dot(outward,axis)
            if (end==0 && side>0) || (end==1 && side<0) {continue}
            best=candidate
            normal=outward/capsule.radius
            hit=true
        }
    }
    if !hit {return 0,{},false}
    return best,linalg.normalize0(normal),true
}

// Both faces are hit. uv are the barycentric weights of b and c at the hit; a has 1-u-v.
ray_triangle :: proc "contextless" (ray:Ray,triangle:Triangle) -> (t:f32,uv:Vec2,hit:bool) {
    return ray_triangle_edges(ray,triangle.a,triangle.b-triangle.a,triangle.c-triangle.a)
}
// The same for a triangle kept as a corner and the two edges that leave it.
ray_triangle_edges :: proc "contextless" (ray:Ray,a,e1,e2:Vec3) -> (t:f32,uv:Vec2,hit:bool) {
    p:=linalg.cross(ray.direction,e2)
    determinant:=linalg.dot(e1,p)
    if abs(determinant)<1e-12 {return}
    inverse:=1/determinant
    s:=ray.origin-a
    u:=linalg.dot(s,p)*inverse
    if u<0 || u>1 {return}
    q:=linalg.cross(s,e1)
    v:=linalg.dot(ray.direction,q)*inverse
    if v<0 || u+v>1 {return}
    t=linalg.dot(e2,q)*inverse
    if t<0 {return 0,{},false}
    return t,{u,v},true
}
// The unit normal of the face that follows the counter-clockwise winding.
triangle_normal :: proc "contextless" (triangle:Triangle) -> Vec3 {
    return linalg.normalize0(linalg.cross(triangle.b-triangle.a,triangle.c-triangle.a))
}

// The stretch of the ray inside the frustum: from t_enter to t_exit.
ray_frustum :: proc "contextless" (ray:Ray,frustum:Frustum) -> (t_enter,t_exit:f32,hit:bool) {
    t_enter,t_exit=0,math.F32_MAX
    for plane in frustum.planes {
        distance:=plane_distance(plane,ray.origin)
        slope:=linalg.dot(plane.normal,ray.direction)
        if abs(slope)<1e-12 {
            if distance<0 {return 0,0,false}
            continue
        }
        t:=-distance/slope
        if slope>0 {t_enter=max(t_enter,t)} else {t_exit=min(t_exit,t)}
        if t_enter>t_exit {return 0,0,false}
    }
    return t_enter,t_exit,true
}

// Parameters of the closest points of two lines: a_origin+a_direction*s and
// b_origin+b_direction*t. ok is false when they are parallel.
line_line_closest :: proc "contextless" (a_origin,a_direction,b_origin,b_direction:Vec3) -> (s,t:f32,ok:bool) {
    aa,bb,ab:=linalg.dot(a_direction,a_direction),linalg.dot(b_direction,b_direction),linalg.dot(a_direction,b_direction)
    denominator:=aa*bb-ab*ab
    if denominator<1e-8*aa*bb || aa*bb==0 {return}
    w:=a_origin-b_origin
    aw,bw:=linalg.dot(a_direction,w),linalg.dot(b_direction,w)
    return (ab*bw-bb*aw)/denominator,(aa*bw-ab*aw)/denominator,true
}

// Four boxes in columns, as a BVH with four children per node keeps them.
Aabb4 :: struct {min_x,min_y,min_z,max_x,max_y,max_z:#simd[4]f32}

// ray_aabb_fast for four boxes at once: the distance at which the ray enters
// each, and which of them it hits (lane i for box i). The same caveats hold.
ray_aabb4 :: proc "contextless" (origin,inverse_direction:Vec3,boxes:^Aabb4,t_max:f32) -> (t:[4]f32,hits:bit_set[0..<4]) {
    F4 :: #simd[4]f32
    smaller :: #force_inline proc "contextless" (a,b:F4) -> F4 {return simd.select(simd.lanes_lt(a,b),a,b)}
    larger :: #force_inline proc "contextless" (a,b:F4) -> F4 {return simd.select(simd.lanes_gt(a,b),a,b)}
    ox,oy,oz:=F4(origin.x),F4(origin.y),F4(origin.z)
    ix,iy,iz:=F4(inverse_direction.x),F4(inverse_direction.y),F4(inverse_direction.z)
    ax,bx:=(boxes.min_x-ox)*ix,(boxes.max_x-ox)*ix
    ay,by:=(boxes.min_y-oy)*iy,(boxes.max_y-oy)*iy
    az,bz:=(boxes.min_z-oz)*iz,(boxes.max_z-oz)*iz
    enter:=larger(larger(smaller(ax,bx),smaller(ay,by)),larger(smaller(az,bz),F4(0)))
    exit:=smaller(smaller(larger(ax,bx),larger(ay,by)),smaller(larger(az,bz),F4(t_max)))
    return simd.to_array(enter),transmute(bit_set[0..<4])u8(transmute(u8)simd.extract_msbs(simd.lanes_le(enter,exit)))
}

aabb4_set :: proc "contextless" (boxes:^Aabb4,lane:int,box:Aabb) {
    boxes.min_x=simd.replace(boxes.min_x,lane,box.min.x);boxes.min_y=simd.replace(boxes.min_y,lane,box.min.y);boxes.min_z=simd.replace(boxes.min_z,lane,box.min.z)
    boxes.max_x=simd.replace(boxes.max_x,lane,box.max.x);boxes.max_y=simd.replace(boxes.max_y,lane,box.max.y);boxes.max_z=simd.replace(boxes.max_z,lane,box.max.z)
}
