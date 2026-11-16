package render

import "core:math/linalg"
import "core:testing"
import mm "mirai:std/math"

// Far from the centre of the world, a transform out of the world found from
// its place relative to the origin finds a point where the world does, to the
// tenth of a millimetre, and a plane through the place keeps the side of it.
@(test)
a_transform_found_from_its_place_keeps_where_it_is_far_from_the_centre :: proc(t:^testing.T) {
    pose:=mm.Transform{position={-20000.25,12,15000.5},rotation=mm.quat_axis_angle({0,1,0},0.6),scale={2,1,3}}
    to_world:=mm.transform_matrix(pose)
    rows:=mm.mat4_rows(linalg.inverse(to_world))
    origin:=[3]f32{-19456,0,15360}
    relative:=origin_from_place(rows,pose.position,origin)
    local:=[3]f32{0.25,-0.5,0.4}
    there:=mm.transform_point(mm.Transform{origin_point(pose.position,origin),pose.rotation,pose.scale},local)
    for row,i in relative {
        back:=row.x*there.x+row.y*there.y+row.z*there.z+row.w
        testing.expectf(t,abs(back-local[i])<1e-4,"axis %d: back in the box at %v, not %v",i,back,local[i])
    }
    normal:=mm.quat_rotate(pose.rotation,[3]f32{0,0,1})
    plane:=origin_plane_through({normal.x,normal.y,normal.z,0},pose.position,origin)
    front:=origin_point(pose.position+normal,origin)
    testing.expectf(t,abs(linalg.dot(plane.xyz,front)+plane.w-1)<1e-3,"a metre in front of the place is %v in front",linalg.dot(plane.xyz,front)+plane.w)
}
