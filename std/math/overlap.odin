package mirai_math

import "core:math"
import "core:math/linalg"

// Overlap tests. Shapes that only touch count as overlapping.

aabb_overlaps :: #force_inline proc "contextless" (a,b:Aabb) -> bool {
    return a.min.x<=b.max.x && a.max.x>=b.min.x && a.min.y<=b.max.y && a.max.y>=b.min.y && a.min.z<=b.max.z && a.max.z>=b.min.z
}
sphere_overlaps :: #force_inline proc "contextless" (a,b:Sphere) -> bool {
    offset,reach:=a.center-b.center,a.radius+b.radius
    return linalg.dot(offset,offset)<=reach*reach
}
sphere_overlaps_aabb :: proc "contextless" (sphere:Sphere,box:Aabb) -> bool {
    offset:=sphere.center-closest_point_aabb(sphere.center,box)
    return linalg.dot(offset,offset)<=sphere.radius*sphere.radius
}

// False only when the box is entirely outside one of the planes: a box near
// a corner of the frustum can pass without touching it, which is what culling wants.
frustum_overlaps_aabb :: proc "contextless" (frustum:Frustum,box:Aabb) -> bool {
    for plane in frustum.planes {
        n:=plane.normal
        corner:=Vec3{box.max.x if n.x>=0 else box.min.x,box.max.y if n.y>=0 else box.min.y,box.max.z if n.z>=0 else box.min.z}
        if linalg.dot(n,corner)+plane.d<0 {return false}
    }
    return true
}
frustum_overlaps_sphere :: proc "contextless" (frustum:Frustum,sphere:Sphere) -> bool {
    for plane in frustum.planes {
        if plane_distance(plane,sphere.center)<-sphere.radius {return false}
    }
    return true
}

// Separating axis test over the three axes of each box and their nine cross products.
obb_overlaps :: proc "contextless" (a,b:Obb) -> bool {
    ra,rb:=quat_to_mat3(a.rotation),quat_to_mat3(b.rotation)
    // b in the frame of a.
    r:=linalg.transpose(ra)*rb
    t:=linalg.transpose(ra)*(b.center-a.center)
    // The margin keeps nearly parallel edges, whose cross product is almost zero, from separating the boxes.
    q:Mat3
    for i in 0..<3 {for j in 0..<3 {q[i,j]=abs(r[i,j])+1e-6}}
    for i in 0..<3 {
        if abs(t[i])>a.half[i]+b.half.x*q[i,0]+b.half.y*q[i,1]+b.half.z*q[i,2] {return false}
    }
    for j in 0..<3 {
        if abs(t.x*r[0,j]+t.y*r[1,j]+t.z*r[2,j])>a.half.x*q[0,j]+a.half.y*q[1,j]+a.half.z*q[2,j]+b.half[j] {return false}
    }
    for i in 0..<3 {
        i1,i2:=(i+1)%3,(i+2)%3
        for j in 0..<3 {
            j1,j2:=(j+1)%3,(j+2)%3
            reach:=a.half[i1]*q[i2,j]+a.half[i2]*q[i1,j]+b.half[j1]*q[i,j2]+b.half[j2]*q[i,j1]
            if abs(t[i2]*r[i1,j]-t[i1]*r[i2,j])>reach {return false}
        }
    }
    return true
}

// How far apart two oriented boxes are along the axis that separates them
// most, of the fifteen of the separating axis test: positive when they do
// not touch, and then a lower bound of their distance (exact when a face of
// one is what is nearest to the other); negative when they overlap, and then
// minus the least they would have to move apart.
obb_separation :: proc "contextless" (a,b:Obb) -> f32 {
    ra,rb:=quat_to_mat3(a.rotation),quat_to_mat3(b.rotation)
    r:=linalg.transpose(ra)*rb
    t:=linalg.transpose(ra)*(b.center-a.center)
    q:Mat3
    for i in 0..<3 {for j in 0..<3 {q[i,j]=abs(r[i,j])}}
    gap:=-F32_MAX_SEPARATION
    for i in 0..<3 {
        gap=max(gap,abs(t[i])-(a.half[i]+b.half.x*q[i,0]+b.half.y*q[i,1]+b.half.z*q[i,2]))
    }
    for j in 0..<3 {
        gap=max(gap,abs(t.x*r[0,j]+t.y*r[1,j]+t.z*r[2,j])-(a.half.x*q[0,j]+a.half.y*q[1,j]+a.half.z*q[2,j]+b.half[j]))
    }
    for i in 0..<3 {
        i1,i2:=(i+1)%3,(i+2)%3
        for j in 0..<3 {
            j1,j2:=(j+1)%3,(j+2)%3
            // The axis is the cross product of the two edges: its length divides the projections.
            length:=1-r[i,j]*r[i,j]
            if length<1e-10 {continue}
            reach:=a.half[i1]*q[i2,j]+a.half[i2]*q[i1,j]+b.half[j1]*q[i,j2]+b.half[j2]*q[i,j1]
            gap=max(gap,(abs(t[i2]*r[i1,j]-t[i1]*r[i2,j])-reach)/math.sqrt(length))
        }
    }
    return gap
}
@(private="file") F32_MAX_SEPARATION :: f32(3.4e38)
