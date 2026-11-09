package mirai_math

import "core:math"
import "core:math/linalg"

// Everything looks down its -Z with +Y up: cameras, lights, bodies. Clip space has Y up and depth from 0
// to 1, reversed: the near plane is at depth 1 and the far one at 0, which
// spends the precision of floats where a perspective needs it. Screen points
// are pixels from the top left corner of the viewport, Y down.

// View matrix of a camera at `eye` looking at `target`. A target on the eye,
// or an up parallel to the view, still gives a finite matrix.
look_at :: proc "contextless" (eye,target,up:Vec3) -> Mat4 {
    back,right,forward:=look_basis(target-eye,up)
    actual_up:=linalg.cross(right,forward)
    view:Mat4=1
    for i in 0..<3 {
        view[0,i]=right[i];view[1,i]=actual_up[i];view[2,i]=back[i]
    }
    view[0,3]=-linalg.dot(right,eye)
    view[1,3]=-linalg.dot(actual_up,eye)
    view[2,3]=-linalg.dot(back,eye)
    return view
}
// View matrix of a camera from its world position and rotation.
view_matrix :: proc "contextless" (position:Vec3,rotation:Quat) -> Mat4 {
    r:=quat_to_mat3(rotation)
    view:Mat4=1
    for row in 0..<3 {
        for column in 0..<3 {view[row,column]=r[column,row]}
        view[row,3]=-(r[0,row]*position.x+r[1,row]*position.y+r[2,row]*position.z)
    }
    return view
}

// fov_y is the vertical field of view in radians; 0 < near < far.
perspective :: proc "contextless" (fov_y,aspect,near,far:f32) -> Mat4 {
    f:=1/math.tan(fov_y*0.5)
    m:Mat4
    m[0,0]=f/aspect
    m[1,1]=f
    m[2,2]=near/(far-near)
    m[2,3]=far*near/(far-near)
    m[3,2]=-1
    return m
}
// A perspective without a far plane: depth reaches 0 at infinity.
perspective_infinite :: proc "contextless" (fov_y,aspect,near:f32) -> Mat4 {
    f:=1/math.tan(fov_y*0.5)
    m:Mat4
    m[0,0]=f/aspect
    m[1,1]=f
    m[2,3]=near
    m[3,2]=-1
    return m
}
// A box of the given size centered on the view axis.
orthographic :: proc "contextless" (width,height,near,far:f32) -> Mat4 {
    return orthographic_off_center(-width*0.5,width*0.5,-height*0.5,height*0.5,near,far)
}
orthographic_off_center :: proc "contextless" (left,right,bottom,top,near,far:f32) -> Mat4 {
    m:Mat4
    m[0,0]=2/(right-left)
    m[0,3]=-(right+left)/(right-left)
    m[1,1]=2/(top-bottom)
    m[1,3]=-(top+bottom)/(top-bottom)
    m[2,2]=1/(far-near)
    m[2,3]=far/(far-near)
    m[3,3]=1
    return m
}

// Pixel of a world point and its depth. ok is false, with a pixel far outside
// any viewport, when the point is behind a perspective camera.
world_to_screen :: proc "contextless" (point:Vec3,viewport:Vec2,view_projection:Mat4) -> (screen:Vec2,depth:f32,ok:bool) {
    clip:=view_projection*Vec4{point.x,point.y,point.z,1}
    if clip.w<0.001 {return {-10000,-10000},0,false}
    ndc:=clip.xyz/clip.w
    return {(ndc.x*0.5+0.5)*viewport.x,(0.5-ndc.y*0.5)*viewport.y},ndc.z,true
}
// The world ray through a pixel, with a unit direction. With a perspective it
// starts at the eye; with an orthographic projection, on the near plane.
// `view` must be a rotation and a translation, as look_at and view_matrix give.
screen_ray :: proc "contextless" (screen,viewport:Vec2,view,projection:Mat4) -> Ray {
    x:=2*screen.x/viewport.x-1
    y:=1-2*screen.y/viewport.y
    origin,direction:Vec3
    if projection[3,3]==0 {
        direction=linalg.normalize0(Vec3{(x+projection[0,2])/projection[0,0],(y+projection[1,2])/projection[1,1],-1})
    } else {
        origin={(x-projection[0,3])/projection[0,0],(y-projection[1,3])/projection[1,1],(1-projection[2,3])/projection[2,2]}
        direction=FORWARD
    }
    // The inverse of a rigid view: its rotation transposed.
    offset:=origin-Vec3{view[0,3],view[1,3],view[2,3]}
    world_origin,world_direction:Vec3
    for i in 0..<3 {
        world_origin[i]=view[0,i]*offset.x+view[1,i]*offset.y+view[2,i]*offset.z
        world_direction[i]=view[0,i]*direction.x+view[1,i]*direction.y+view[2,i]*direction.z
    }
    return {world_origin,world_direction}
}
// World units one pixel covers at `depth` in front of a perspective camera.
perspective_world_per_pixel :: proc "contextless" (depth,fov_y,viewport_height:f32) -> f32 {
    return 2*math.tan(fov_y*0.5)*depth/viewport_height
}
