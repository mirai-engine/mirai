package mirai_math

import "core:math/linalg"

// Position, rotation and signed scale of something relative to its parent.
// A zeroed Transform is not usable: start from TRANSFORM_IDENTITY.
Transform :: struct {
    position:Vec3,
    rotation:Quat,
    scale:Vec3,
}

TRANSFORM_IDENTITY :: Transform{{0,0,0},1,{1,1,1}}

// Mirai's hierarchy composition: the world transform of a child from the world
// transform of its parent. Position, rotation and scale stay separate. The
// child's position goes through the parent's rotation and scale, rotations
// multiply and scales multiply axis by axis, whatever the rotation: a rotated
// child of a parent with uneven scale keeps its dimensions and its right
// angles, where multiplying affine matrices would shear it.
//
// The operation is not associative. A world transform is always built from
// the root down: compose(compose(root,child),grandchild).
transform_compose :: #force_inline proc "contextless" (parent,local:Transform) -> Transform {
    return {
        parent.position+quat_rotate(parent.rotation,parent.scale*local.position),
        parent.rotation*local.rotation,
        parent.scale*local.scale,
    }
}
// The local transform that composed with the parent gives `world`: what
// reparenting stores to keep something where it is. It fails, returning the
// identity, when an axis of the parent's scale is zero.
transform_relative :: proc "contextless" (world,parent:Transform) -> (local:Transform,ok:bool) {
    for axis in parent.scale {
        if abs(axis)<1e-8 {return TRANSFORM_IDENTITY,false}
    }
    inverse:=conj(parent.rotation)
    return {quat_rotate(inverse,world.position-parent.position)/parent.scale,inverse*world.rotation,world.scale/parent.scale},true
}
// The transform that composed after t gives the identity: compose(t,inverse) is the identity.
transform_inverse :: proc "contextless" (t:Transform) -> (inverse:Transform,ok:bool) {
    return transform_relative(TRANSFORM_IDENTITY,t)
}

// Local to parent space: a point, a vector that scales, and a direction that only turns.
transform_point :: #force_inline proc "contextless" (t:Transform,p:Vec3) -> Vec3 {
    return t.position+quat_rotate(t.rotation,t.scale*p)
}
transform_vector :: #force_inline proc "contextless" (t:Transform,v:Vec3) -> Vec3 {
    return quat_rotate(t.rotation,t.scale*v)
}
transform_direction :: #force_inline proc "contextless" (t:Transform,d:Vec3) -> Vec3 {
    return quat_rotate(t.rotation,d)
}
// Parent to local space. The scale must not have a zero axis.
transform_inverse_point :: #force_inline proc "contextless" (t:Transform,p:Vec3) -> Vec3 {
    return quat_rotate(conj(t.rotation),p-t.position)/t.scale
}
transform_inverse_vector :: #force_inline proc "contextless" (t:Transform,v:Vec3) -> Vec3 {
    return quat_rotate(conj(t.rotation),v)/t.scale
}

// Translation * Rotation * Scale.
transform_matrix :: proc "contextless" (t:Transform) -> Mat4 {
    r:=quat_to_mat3(t.rotation)
    m:Mat4
    for row in 0..<3 {
        for column in 0..<3 {m[row,column]=r[row,column]*t.scale[column]}
        m[row,3]=t.position[row]
    }
    m[3,3]=1
    return m
}
// The inverse of transform_matrix, without a general matrix inversion. It
// fails, returning the identity, when an axis of the scale is zero.
transform_inverse_matrix :: proc "contextless" (t:Transform) -> (m:Mat4,ok:bool) {
    for axis in t.scale {
        if abs(axis)<1e-8 {return 1,false}
    }
    r:=quat_to_mat3(t.rotation)
    inverse_scale:=1/t.scale
    for row in 0..<3 {
        for column in 0..<3 {m[row,column]=r[column,row]*inverse_scale[row]}
        m[row,3]=-(m[row,0]*t.position.x+m[row,1]*t.position.y+m[row,2]*t.position.z)
    }
    m[3,3]=1
    return m,true
}
// Position, rotation and scale of an affine matrix. It fails when an axis has
// no length or the axes are not perpendicular, as in a matrix with shear. A
// mirrored matrix comes back with a negative X scale.
transform_from_matrix :: proc "contextless" (m:Mat4) -> (t:Transform,ok:bool) {
    t=TRANSFORM_IDENTITY
    columns:=[3]Vec3{{m[0,0],m[1,0],m[2,0]},{m[0,1],m[1,1],m[2,1]},{m[0,2],m[1,2],m[2,2]}}
    scale:Vec3
    for &column,i in columns {
        scale[i]=linalg.length(column)
        if scale[i]<1e-8 {return}
        column/=scale[i]
    }
    if abs(linalg.dot(columns[0],columns[1]))>1e-4 || abs(linalg.dot(columns[0],columns[2]))>1e-4 || abs(linalg.dot(columns[1],columns[2]))>1e-4 {return}
    if linalg.dot(linalg.cross(columns[0],columns[1]),columns[2])<0 {scale.x=-scale.x;columns[0]=-columns[0]}
    r:Mat3
    for column,i in columns {r[0,i],r[1,i],r[2,i]=column.x,column.y,column.z}
    return {{m[0,3],m[1,3],m[2,3]},linalg.normalize(quat_from_mat3(r)),scale},true
}

transform_from_euler :: proc "contextless" (position,angles,scale:Vec3) -> Transform {
    return {position,quat_from_euler(angles),scale}
}

// Position and scale interpolate linearly and the rotation along its shortest
// arc (quat_nlerp): what the renderer does between two ticks.
transform_interpolate :: proc "contextless" (a,b:Transform,t:f32) -> Transform {
    return {a.position+(b.position-a.position)*t,quat_nlerp(a.rotation,b.rotation,t),a.scale+(b.scale-a.scale)*t}
}
