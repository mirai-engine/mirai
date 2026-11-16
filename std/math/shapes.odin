package mirai_math

import "core:math"
import "core:math/linalg"

Ray :: struct {origin,direction:Vec3}
Segment :: struct {a,b:Vec3}
// The points p with dot(normal,p)+d = 0. The normal is unit and points to the positive side.
Plane :: struct {normal:Vec3,d:f32}
Aabb :: struct {min,max:Vec3}
// A box with its own axes: `half` are its half sizes along them.
Obb :: struct {center:Vec3,rotation:Quat,half:Vec3}
Sphere :: struct {center:Vec3,radius:f32}
// Every point within `radius` of the segment a-b.
Capsule :: struct {a,b:Vec3,radius:f32}
Triangle :: struct {a,b,c:Vec3}
// Six planes with their normals pointing inside, in the order of Frustum_Plane.
Frustum :: struct {planes:[Frustum_Plane]Plane}
Frustum_Plane :: enum u8 {Left,Right,Bottom,Top,Far,Near}

// The box that contains nothing: merging it with another box gives that box.
AABB_EMPTY :: Aabb{{math.F32_MAX,math.F32_MAX,math.F32_MAX},{-math.F32_MAX,-math.F32_MAX,-math.F32_MAX}}

ray_at :: #force_inline proc "contextless" (ray:Ray,t:f32) -> Vec3 {return ray.origin+ray.direction*t}

// Smaller and larger with one instruction each: the builtin min and max also
// order NaN, at five times the cost. With a NaN they give the second value.
float_min :: #force_inline proc "contextless" (a,b:f32) -> f32 {return a if a<b else b}
float_max :: #force_inline proc "contextless" (a,b:f32) -> f32 {return a if a>b else b}
vec3_min :: #force_inline proc "contextless" (a,b:Vec3) -> Vec3 {
    return {a.x if a.x<b.x else b.x,a.y if a.y<b.y else b.y,a.z if a.z<b.z else b.z}
}
vec3_max :: #force_inline proc "contextless" (a,b:Vec3) -> Vec3 {
    return {a.x if a.x>b.x else b.x,a.y if a.y>b.y else b.y,a.z if a.z>b.z else b.z}
}

aabb_from_center :: proc "contextless" (center,half:Vec3) -> Aabb {return {center-half,center+half}}
aabb_from_points :: proc "contextless" (points:[]Vec3) -> Aabb {
    box:=AABB_EMPTY
    for point in points {box.min=vec3_min(box.min,point);box.max=vec3_max(box.max,point)}
    return box
}
aabb_center :: #force_inline proc "contextless" (box:Aabb) -> Vec3 {return (box.min+box.max)*0.5}
aabb_half :: #force_inline proc "contextless" (box:Aabb) -> Vec3 {return (box.max-box.min)*0.5}
aabb_size :: #force_inline proc "contextless" (box:Aabb) -> Vec3 {return box.max-box.min}
aabb_is_empty :: #force_inline proc "contextless" (box:Aabb) -> bool {
    return box.min.x>box.max.x || box.min.y>box.max.y || box.min.z>box.max.z
}
aabb_merge :: #force_inline proc "contextless" (a,b:Aabb) -> Aabb {return {vec3_min(a.min,b.min),vec3_max(a.max,b.max)}}
aabb_add_point :: #force_inline proc "contextless" (box:Aabb,point:Vec3) -> Aabb {
    return {vec3_min(box.min,point),vec3_max(box.max,point)}
}
// Grows the box by the margin on every side.
aabb_expand :: #force_inline proc "contextless" (box:Aabb,margin:f32) -> Aabb {return {box.min-margin,box.max+margin}}
// 0 for the empty box.
aabb_surface_area :: proc "contextless" (box:Aabb) -> f32 {
    if aabb_is_empty(box) {return 0}
    size:=box.max-box.min
    return 2*(size.x*size.y+size.y*size.z+size.z*size.x)
}
aabb_volume :: proc "contextless" (box:Aabb) -> f32 {
    if aabb_is_empty(box) {return 0}
    size:=box.max-box.min
    return size.x*size.y*size.z
}
aabb_contains_point :: #force_inline proc "contextless" (box:Aabb,point:Vec3) -> bool {
    return point.x>=box.min.x && point.x<=box.max.x && point.y>=box.min.y && point.y<=box.max.y && point.z>=box.min.z && point.z<=box.max.z
}
// True when `inner` is completely inside `outer`.
aabb_contains :: #force_inline proc "contextless" (outer,inner:Aabb) -> bool {
    return inner.min.x>=outer.min.x && inner.max.x<=outer.max.x && inner.min.y>=outer.min.y && inner.max.y<=outer.max.y && inner.min.z>=outer.min.z && inner.max.z<=outer.max.z
}
// The box around the transformed box: the transformed center, and half sizes
// that add up the absolute contribution of every axis.
aabb_transform :: proc "contextless" (box:Aabb,m:Mat4) -> Aabb {
    if aabb_is_empty(box) {return box}
    center,half:=aabb_center(box),aabb_half(box)
    moved:=mat4_point(m,center)
    extent:Vec3
    for row in 0..<3 {extent[row]=abs(m[row,0])*half.x+abs(m[row,1])*half.y+abs(m[row,2])*half.z}
    return {moved-extent,moved+extent}
}
aabb_from_obb :: proc "contextless" (box:Obb) -> Aabb {
    r:=quat_to_mat3(box.rotation)
    extent:Vec3
    for row in 0..<3 {extent[row]=abs(r[row,0])*box.half.x+abs(r[row,1])*box.half.y+abs(r[row,2])*box.half.z}
    return {box.center-extent,box.center+extent}
}
aabb_from_sphere :: proc "contextless" (sphere:Sphere) -> Aabb {return {sphere.center-sphere.radius,sphere.center+sphere.radius}}
aabb_from_capsule :: proc "contextless" (capsule:Capsule) -> Aabb {
    return {vec3_min(capsule.a,capsule.b)-capsule.radius,vec3_max(capsule.a,capsule.b)+capsule.radius}
}

// The plane through a point with the given normal, which need not be unit.
plane_from_point :: proc "contextless" (point,normal:Vec3) -> Plane {
    n:=linalg.normalize0(normal)
    return {n,-linalg.dot(n,point)}
}
// The plane of a triangle; its normal follows the counter-clockwise winding.
plane_from_points :: proc "contextless" (a,b,c:Vec3) -> Plane {
    return plane_from_point(a,linalg.cross(b-a,c-a))
}
// Signed distance: positive on the side the normal points to.
plane_distance :: #force_inline proc "contextless" (plane:Plane,point:Vec3) -> f32 {
    return linalg.dot(plane.normal,point)+plane.d
}

// The planes of a view-projection matrix whose clip space has depth from 0 to
// 1, as perspective and orthographic produce. With reversed depth the plane
// of depth 0 is the far one.
frustum_from_matrix :: proc "contextless" (view_projection:Mat4) -> Frustum {
    m:=view_projection
    row :: #force_inline proc "contextless" (m:Mat4,i:int) -> Vec4 {return {m[i,0],m[i,1],m[i,2],m[i,3]}}
    r0,r1,r2,r3:=row(m,0),row(m,1),row(m,2),row(m,3)
    raw:=[Frustum_Plane]Vec4{.Left=r3+r0,.Right=r3-r0,.Bottom=r3+r1,.Top=r3-r1,.Far=r2,.Near=r3-r2}
    frustum:Frustum
    for plane,side in raw {
        length:=math.sqrt(plane.x*plane.x+plane.y*plane.y+plane.z*plane.z)
        scaled:=plane/length if length>1e-8 else plane
        frustum.planes[side]={scaled.xyz,scaled.w}
    }
    return frustum
}
