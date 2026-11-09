package mirai_math

import "core:math"
import "core:math/linalg"

// Right-handed, Y up, meters, seconds, radians, column vectors. The types are
// Odin built-ins, so every package shares them without conversion, and
// core:math/linalg works on them directly (dot, cross, length, normalize0).

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
Quat :: quaternion128
Mat3 :: matrix[3,3]f32
Mat4 :: matrix[4,4]f32

PI :: math.PI
TAU :: math.TAU
RAD_PER_DEG :: math.RAD_PER_DEG
DEG_PER_RAD :: math.DEG_PER_RAD

QUAT_IDENTITY :Quat: 1
MAT3_IDENTITY :Mat3: 1
MAT4_IDENTITY :Mat4: 1

// Where something unrotated looks: bodies, cameras and lights face their -Z.
FORWARD :Vec3: {0,0,-1}

// Affine transform of a point (w=1) and of a vector (w=0).
mat4_point :: #force_inline proc "contextless" (m:Mat4,p:Vec3) -> Vec3 {
    return {m[0,0]*p.x+m[0,1]*p.y+m[0,2]*p.z+m[0,3],m[1,0]*p.x+m[1,1]*p.y+m[1,2]*p.z+m[1,3],m[2,0]*p.x+m[2,1]*p.y+m[2,2]*p.z+m[2,3]}
}
mat4_vector :: #force_inline proc "contextless" (m:Mat4,v:Vec3) -> Vec3 {
    return {m[0,0]*v.x+m[0,1]*v.y+m[0,2]*v.z,m[1,0]*v.x+m[1,1]*v.y+m[1,2]*v.z,m[2,0]*v.x+m[2,1]*v.y+m[2,2]*v.z}
}
// The first three rows of an affine matrix, as a shader reads a transform (float4 rows[3]).
mat4_rows :: #force_inline proc "contextless" (m:Mat4) -> [3][4]f32 {
    return {{m[0,0],m[0,1],m[0,2],m[0,3]},{m[1,0],m[1,1],m[1,2],m[1,3]},{m[2,0],m[2,1],m[2,2],m[2,3]}}
}

// Rotations are unit quaternions. q1*q2 applies q2 first.

quat_rotate :: #force_inline proc "contextless" (q:Quat,v:Vec3) -> Vec3 {
    u:=Vec3{q.x,q.y,q.z}
    t:=2*linalg.cross(u,v)
    return v+q.w*t+linalg.cross(u,t)
}
// The inverse of a unit quaternion.
quat_inverse :: #force_inline proc "contextless" (q:Quat) -> Quat {return conj(q)}
quat_to_mat3 :: linalg.matrix3_from_quaternion_f32
// The matrix must be a rotation: orthonormal with determinant 1.
quat_from_mat3 :: linalg.quaternion_from_matrix3_f32
// Rotation of `angle` radians around the axis; the identity when the axis is zero.
quat_axis_angle :: proc "contextless" (axis:Vec3,angle:f32) -> Quat {
    length:=linalg.length(axis)
    if length<1e-12 {return 1}
    s,c:=math.sincos(angle*0.5)
    v:=axis*(s/length)
    return quaternion(w=c,x=v.x,y=v.y,z=v.z)
}
// The shortest rotation that takes one direction to the other.
quat_between :: linalg.quaternion_between_two_vector3_f32
// Normalized linear interpolation along the shortest arc: cheap, and close to
// quat_slerp when the two rotations are near, as between two ticks.
quat_nlerp :: proc "contextless" (a,b:Quat,t:f32) -> Quat {
    s:=t if linalg.dot(a,b)>=0 else -t
    w,x,y,z:=a.w*(1-t)+b.w*s,a.x*(1-t)+b.x*s,a.y*(1-t)+b.y*s,a.z*(1-t)+b.z*s
    length:=math.sqrt(w*w+x*x+y*y+z*z)
    if length<1e-12 {return a}
    return quaternion(w=w/length,x=x/length,y=y/length,z=z/length)
}
// Interpolation at constant angular speed along the shortest arc.
quat_slerp :: proc "contextless" (a,b:Quat,t:f32) -> Quat {
    return linalg.normalize(linalg.quaternion_slerp_f32(a,b,t))
}
// Angle in radians between two rotations.
quat_angle :: proc "contextless" (a,b:Quat) -> f32 {
    r:=conj(a)*b
    return 2*math.atan2(math.sqrt(r.x*r.x+r.y*r.y+r.z*r.z),abs(r.w))
}
// Where a rotation looks.
quat_forward :: #force_inline proc "contextless" (q:Quat) -> Vec3 {return quat_rotate(q,FORWARD)}
// The yaw around +Y that turns FORWARD toward a direction, seen from above.
yaw_of_direction :: #force_inline proc "contextless" (direction:Vec3) -> f32 {return math.atan2(-direction.x,-direction.z)}
// Rotation of something that looks down its -Z with +Y up, so that it faces
// `forward` with its up as close to `up` as that allows.
quat_look :: proc "contextless" (forward,up:Vec3) -> Quat {
    back,right,_:=look_basis(forward,up)
    actual_up:=linalg.cross(back,right)
    m:Mat3
    m[0,0],m[1,0],m[2,0]=right.x,right.y,right.z
    m[0,1],m[1,1],m[2,1]=actual_up.x,actual_up.y,actual_up.z
    m[0,2],m[1,2],m[2,2]=back.x,back.y,back.z
    return linalg.normalize(quat_from_mat3(m))
}
// Orthonormal axes of a view along `forward`. A zero forward becomes FORWARD
// and an up that is zero or parallel to it is replaced, so the result is
// always finite.
look_basis :: proc "contextless" (forward,up:Vec3) -> (back,right,actual_forward:Vec3) {
    actual_forward=forward
    actual_forward=linalg.normalize(actual_forward) if linalg.length(actual_forward)>1e-6 else FORWARD
    hint:=up if linalg.length(up)>1e-6 else Vec3{0,1,0}
    right=linalg.cross(actual_forward,hint)
    if linalg.length(right)<1e-5 {right=linalg.cross(actual_forward,Vec3{0,0,1} if abs(actual_forward.y)>0.9 else Vec3{0,1,0})}
    right=linalg.normalize(right)
    return -actual_forward,right,actual_forward
}

// Euler angles in radians, applied around X, then Y, then Z: R = Rz*Ry*Rx.
// It is the order rotations are shown and typed in.
quat_from_euler :: proc "contextless" (angles:Vec3) -> Quat {
    sx,cx:=math.sincos(angles.x*0.5)
    sy,cy:=math.sincos(angles.y*0.5)
    sz,cz:=math.sincos(angles.z*0.5)
    return quaternion(w=cx*cy*cz+sx*sy*sz,x=sx*cy*cz-cx*sy*sz,y=cx*sy*cz+sx*cy*sz,z=cx*cy*sz-sx*sy*cz)
}
// One of the angle triples of a rotation: Y stays within a quarter turn, and X
// is 0 when Y reaches it and the other two angles merge. euler_closest picks
// the triple that continues a previous one.
quat_to_euler :: proc "contextless" (q:Quat) -> Vec3 {
    m00,m10,m20:=1-2*(q.y*q.y+q.z*q.z),2*(q.x*q.y+q.w*q.z),2*(q.x*q.z-q.w*q.y)
    cy:=math.sqrt(m00*m00+m10*m10)
    y:=math.atan2(-m20,cy)
    if cy>1e-4 {
        m21,m22:=2*(q.y*q.z+q.w*q.x),1-2*(q.x*q.x+q.y*q.y)
        return {math.atan2(m21,m22),y,math.atan2(m10,m00)}
    }
    m01,m11:=2*(q.x*q.y-q.w*q.z),1-2*(q.x*q.x+q.z*q.z)
    return {0,y,math.atan2(-m01,m11)}
}
// The same angles plus whole turns, each as near to the reference as possible:
// values do not jump while an angle is dragged past half a turn.
euler_near :: proc "contextless" (angles,reference:Vec3) -> Vec3 {
    result:=angles
    for i in 0..<3 {result[i]+=math.round((reference[i]-result[i])/TAU)*TAU}
    return result
}
// A rotation has two angle triples, {x,y,z} and {x+PI,PI-y,z+PI}. Returns the
// one nearest to the reference.
euler_closest :: proc "contextless" (angles,reference:Vec3) -> Vec3 {
    distance :: proc "contextless" (a,b:Vec3) -> f32 {return abs(a.x-b.x)+abs(a.y-b.y)+abs(a.z-b.z)}
    first:=euler_near(angles,reference)
    second:=euler_near({angles.x+PI,PI-angles.y,angles.z+PI},reference)
    return first if distance(first,reference)<=distance(second,reference) else second
}

// Splits a rotation into a twist about `axis` and the swing that follows it:
// q = swing*twist. With the axis of a bone, the twist is its roll and the
// swing where it points. A rotation a half turn away from the axis has no
// defined twist: it is the identity then.
quat_swing_twist :: proc "contextless" (q:Quat,axis:Vec3) -> (swing,twist:Quat) {
    unit:=linalg.normalize0(axis)
    along:=linalg.dot(Vec3{imag(q),jmag(q),kmag(q)},unit)*unit
    twist=quaternion(w=real(q),x=along.x,y=along.y,z=along.z)
    length:=linalg.length(Vec4{along.x,along.y,along.z,real(q)})
    if length<1e-6 {return q,1}
    twist=twist/Quat(length)
    return q*conj(twist),twist
}
