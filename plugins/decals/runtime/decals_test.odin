package decals

import "core:math/linalg"
import "core:testing"
import render "mirai:engine/render"
import mm "mirai:std/math"

// A decal goes to the shaders relative to the origin the renderer draws from:
// its box from where its place is, and its place by the origin.
@(test)
decals_go_to_the_shaders_relative_to_the_origin :: proc(t:^testing.T) {
    pose:=mm.Transform{position={-20000.25,12,15000.5},rotation=mm.quat_axis_angle({0,1,0},0.6),scale={2,1,3}}
    to_world:=mm.transform_matrix(pose)
    d:=Gpu_Decal{to_box=mm.mat4_rows(linalg.inverse(to_world)),to_world=mm.mat4_rows(to_world),color=1}
    origin:=[3]f32{-19456,0,15360}
    relative:=decal_relative(d,origin)
    testing.expect_value(t,relative.to_box,render.origin_from_place(d.to_box,pose.position,origin))
    testing.expect_value(t,relative.to_world,render.origin_to_world(d.to_world,origin))
    testing.expect_value(t,relative.color,d.color)
}
