package mirai_physics

import cmath "core:math"
import "base:intrinsics"
import "core:math/linalg"
import math "mirai:std/math"

Vec3 :: math.Vec3
Quat :: math.Quat
Mat3 :: math.Mat3

// Rigid transform: rotation then translation.
Transform :: struct {p:Vec3,q:Quat}

QUAT_IDENTITY :: math.QUAT_IDENTITY
TRANSFORM_IDENTITY :: Transform{{0,0,0},QUAT_IDENTITY}
PI :: math.PI

@(private) dot :: #force_inline proc "contextless" (a,b:Vec3) -> f32 {return linalg.dot(a,b)}
@(private) cross :: #force_inline proc "contextless" (a,b:Vec3) -> Vec3 {return linalg.cross(a,b)}
@(private) length2 :: #force_inline proc "contextless" (a:Vec3) -> f32 {return linalg.length2(a)}
@(private) length :: #force_inline proc "contextless" (a:Vec3) -> f32 {return linalg.length(a)}
@(private) vmin :: #force_inline proc "contextless" (a,b:Vec3) -> Vec3 {return {min(a.x,b.x),min(a.y,b.y),min(a.z,b.z)}}
@(private) vmax :: #force_inline proc "contextless" (a,b:Vec3) -> Vec3 {return {max(a.x,b.x),max(a.y,b.y),max(a.z,b.z)}}
@(private) vabs :: #force_inline proc "contextless" (a:Vec3) -> Vec3 {return {abs(a.x),abs(a.y),abs(a.z)}}

// Zero for a vector too short to give a direction.
@(private) normalize :: #force_inline proc "contextless" (a:Vec3) -> Vec3 {
    l:=length(a)
    if l<1e-20 {return {}}
    return a*(1/l)
}
@(private) normalize_length :: #force_inline proc "contextless" (a:Vec3) -> (n:Vec3,l:f32) {
    l=length(a)
    if l<1e-20 {return {},0}
    return a*(1/l),l
}
// A unit vector perpendicular to a unit vector.
@(private) perp :: proc "contextless" (n:Vec3) -> Vec3 {
    if abs(n.x)<0.57735027 {return normalize({0,n.z,-n.y})}
    return normalize({n.y,-n.x,0})
}
// Whether every float of the values is a number: neither NaN nor infinite.
finite :: proc{finite_floats,finite_vectors,finite_quats,finite_matrices,finite_transforms}
finite_floats :: proc "contextless" (values:..f32) -> bool {return finite_block(values)}
finite_vectors :: proc "contextless" (values:..Vec3) -> bool {return finite_block(values)}
finite_quats :: proc "contextless" (values:..Quat) -> bool {return finite_block(values)}
finite_matrices :: proc "contextless" (values:..Mat3) -> bool {return finite_block(values)}
finite_transforms :: proc "contextless" (values:..Transform) -> bool {return finite_block(values)}
@(private)
finite_block :: #force_inline proc "contextless" (values:[]$T) -> bool {
    zero:f32
    for v in values {for x in transmute([size_of(T)/size_of(f32)]f32)v {zero+=x*0}}
    return zero==0
}

@(private) q_rotate :: #force_inline proc "contextless" (q:Quat,v:Vec3) -> Vec3 {return math.quat_rotate(q,v)}
@(private) q_inv_rotate :: #force_inline proc "contextless" (q:Quat,v:Vec3) -> Vec3 {return math.quat_rotate(conj(q),v)}
@(private) q_normalize :: #force_inline proc "contextless" (q:Quat) -> Quat {
    l:=cmath.sqrt(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w)
    if l<1e-20 {return QUAT_IDENTITY}
    s:=1/l
    return quaternion(w=q.w*s,x=q.x*s,y=q.y*s,z=q.z*s)
}
// q advanced by the rotation vector dw (angular velocity times time), first order.
@(private) q_integrate :: #force_inline proc "contextless" (q:Quat,dw:Vec3) -> Quat {
    d:Quat=quaternion(w=0,x=dw.x,y=dw.y,z=dw.z)
    r:=d*q
    return q_normalize(quaternion(w=q.w+0.5*r.w,x=q.x+0.5*r.x,y=q.y+0.5*r.y,z=q.z+0.5*r.z))
}
@(private) q_axis_angle :: proc "contextless" (axis:Vec3,angle:f32) -> Quat {
    s:=cmath.sin(0.5*angle)
    return quaternion(w=cmath.cos(0.5*angle),x=axis.x*s,y=axis.y*s,z=axis.z*s)
}
// Rotation vector (axis times angle) of the shortest rotation q.
@(private) q_rotation_vector :: proc "contextless" (q:Quat) -> Vec3 {
    q:=q
    if q.w<0 {q=quaternion(w=-q.w,x=-q.x,y=-q.y,z=-q.z)}
    v:=Vec3{q.x,q.y,q.z}
    s:=length(v)
    if s<1e-6 {return 2*v}
    return v*(2*cmath.atan2(s,q.w)/s)
}
@(private) q_matrix :: #force_inline proc "contextless" (q:Quat) -> Mat3 {return math.quat_to_mat3(q)}
// Shortest rotation taking unit vector a to unit vector b.
@(private) q_between :: proc "contextless" (a,b:Vec3) -> Quat {
    d:=dot(a,b)
    if d<-0.999999 {
        p:=perp(a)
        return quaternion(w=0,x=p.x,y=p.y,z=p.z)
    }
    c:=cross(a,b)
    return q_normalize(quaternion(w=1+d,x=c.x,y=c.y,z=c.z))
}

@(private) xf_point :: #force_inline proc "contextless" (t:Transform,p:Vec3) -> Vec3 {return q_rotate(t.q,p)+t.p}
@(private) xf_inv_point :: #force_inline proc "contextless" (t:Transform,p:Vec3) -> Vec3 {return q_inv_rotate(t.q,p-t.p)}
@(private) xf_mul :: #force_inline proc "contextless" (a,b:Transform) -> Transform {return {q_rotate(a.q,b.p)+a.p,a.q*b.q}}
// b expressed in the frame of a.
@(private) xf_inv_mul :: #force_inline proc "contextless" (a,b:Transform) -> Transform {return {q_inv_rotate(a.q,b.p-a.p),conj(a.q)*b.q}}
@(private) xf_inv :: #force_inline proc "contextless" (t:Transform) -> Transform {
    q:=conj(t.q)
    return {q_rotate(q,-t.p),q}
}

@(private) mat3_diagonal :: #force_inline proc "contextless" (d:Vec3) -> Mat3 {return Mat3{d.x,0,0, 0,d.y,0, 0,0,d.z}}
@(private) mat3_skew :: #force_inline proc "contextless" (v:Vec3) -> Mat3 {return Mat3{0,-v.z,v.y, v.z,0,-v.x, -v.y,v.x,0}}
@(private) mat3_outer :: #force_inline proc "contextless" (a,b:Vec3) -> Mat3 {
    return Mat3{a.x*b.x,a.x*b.y,a.x*b.z, a.y*b.x,a.y*b.y,a.y*b.z, a.z*b.x,a.z*b.y,a.z*b.z}
}
@(private) mat3_columns :: #force_inline proc "contextless" (x,y,z:Vec3) -> Mat3 {
    return Mat3{x.x,y.x,z.x, x.y,y.y,z.y, x.z,y.z,z.z}
}
// A matrix scaled to a largest entry of one is singular below this determinant. Relative to the scale, so that
// tensors of any size invert: the inertia of a steel ball of 1 mm is 1e-11 kg m2, of a ship 1e12.
@(private) MAT3_SINGULAR :: 1e-20

// One over the largest absolute entry; zero for a matrix that is zero, too small to scale or not finite.
@(private) mat3_scale :: #force_inline proc "contextless" (m:Mat3) -> f32 {
    s:f32
    for i in 0..<3 {for j in 0..<3 {s=max(s,abs(m[i,j]))}}
    return s>=1.1754944e-38 && s<=max(f32)?1/s:0
}
// Inverse, or zero when the matrix is singular.
@(private) mat3_inverse :: proc "contextless" (m:Mat3) -> Mat3 {
    inv_s:=mat3_scale(m)
    if inv_s==0 {return {}}
    n:=inv_s*m
    a:=Vec3{n[0,0],n[1,0],n[2,0]};b:=Vec3{n[0,1],n[1,1],n[2,1]};c:=Vec3{n[0,2],n[1,2],n[2,2]}
    bc:=cross(b,c);ca:=cross(c,a);ab:=cross(a,b)
    det:=dot(a,bc)
    if abs(det)<MAT3_SINGULAR {return {}}
    s:=inv_s/det
    if !(abs(s)<=max(f32)) {return {}}
    return Mat3{bc.x*s,bc.y*s,bc.z*s, ca.x*s,ca.y*s,ca.z*s, ab.x*s,ab.y*s,ab.z*s}
}
// Solves m x = b; zero when singular. For a matrix whose diagonal dominates, as the step of the gyroscopic
// torque: the test is relative to its largest diagonal entry, and the matrix is scaled only when its
// determinant or that tolerance leave the range of f32.
@(private) mat3_solve :: proc "contextless" (m:Mat3,b:Vec3) -> Vec3 {
    c0:=Vec3{m[0,0],m[1,0],m[2,0]};c1:=Vec3{m[0,1],m[1,1],m[2,1]};c2:=Vec3{m[0,2],m[1,2],m[2,2]}
    det:=dot(c0,cross(c1,c2))
    s:=max(abs(m[0,0]),abs(m[1,1]),abs(m[2,2]))
    tolerance:=MAT3_SINGULAR*s*s*s
    if tolerance>=1.1754944e-38 && tolerance<=max(f32) && abs(det)<=max(f32) {
        if abs(det)<tolerance {return {}}
        k:=1/det
        return {k*dot(b,cross(c1,c2)),k*dot(c0,cross(b,c2)),k*dot(c0,cross(c1,b))}
    }
    inv_s:=mat3_scale(m)
    if inv_s==0 {return {}}
    n:=inv_s*m
    c0=Vec3{n[0,0],n[1,0],n[2,0]};c1=Vec3{n[0,1],n[1,1],n[2,1]};c2=Vec3{n[0,2],n[1,2],n[2,2]}
    det=dot(c0,cross(c1,c2))
    if abs(det)<MAT3_SINGULAR {return {}}
    k:=inv_s/det
    if !(abs(k)<=max(f32)) {return {}}
    return {k*dot(b,cross(c1,c2)),k*dot(c0,cross(b,c2)),k*dot(c0,cross(c1,b))}
}
// R m R^T: a tensor given in local axes, expressed in world axes.
@(private) mat3_rotate :: #force_inline proc "contextless" (q:Quat,m:Mat3) -> Mat3 {
    r:=q_matrix(q)
    return r*m*intrinsics.transpose(r)
}
// Inertia of a point mass at offset d (parallel axis term).
mat3_point_inertia :: #force_inline proc "contextless" (mass:f32,d:Vec3) -> Mat3 {
    return mass*(mat3_diagonal({dot(d,d),dot(d,d),dot(d,d)})-mat3_outer(d,d))
}

// Motion of a body over one step, for time of impact. Centers are world centers of mass.
Sweep :: struct {local_center,c1,c2:Vec3,q1,q2:Quat}

@(private) sweep_transform :: proc "contextless" (s:Sweep,t:f32) -> Transform {
    q:=q_normalize(quaternion(
        w=s.q1.w+t*(s.q2.w-s.q1.w),x=s.q1.x+t*(s.q2.x-s.q1.x),
        y=s.q1.y+t*(s.q2.y-s.q1.y),z=s.q1.z+t*(s.q2.z-s.q1.z)))
    c:=s.c1+(s.c2-s.c1)*t
    return {c-q_rotate(q,s.local_center),q}
}
