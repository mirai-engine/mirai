package game

import "core:math/linalg"
import "core:testing"
import mm "mirai:std/math"

@(private="file")
close :: proc(a,b:[3]f32) -> bool {return linalg.length(a-b)<1e-3}

@(test)
a_portal_shot_near_the_edge_of_a_wall_moves_in_to_fit_its_face :: proc(t:^testing.T) {
    // A wall 10 m wide, 4 high and 1 thick standing on the floor, its front face at z 0.5.
    wall:=mm.Transform{{0,2,0},1,{1,1,1}}
    box:=Surface_Box{{-5,-2,-0.5},{5,2,0.5}}
    placed,ok:=portal_fit(wall,box,{-4.9,0.3,0.5},{0,0,1},{0,1,0},nil)
    testing.expect(t,ok)
    testing.expectf(t,close(placed.position,{-5+0.5*PORTAL_SIZE.x,0.5*PORTAL_SIZE.y,0.5+PORTAL_LIFT}),"placed at %v",placed.position)
    testing.expect(t,close(mm.quat_rotate(placed.rotation,[3]f32{0,0,1}),{0,0,1}) && close(mm.quat_rotate(placed.rotation,[3]f32{0,1,0}),{0,1,0}))
    // The other portal on the same face pushes it aside; on the back face it does not.
    other:=mm.Transform{{-3.9,1.1,0.52},1,{1,1,1}}
    beside,fits:=portal_fit(wall,box,{-3.5,1,0.5},{0,0,1},{0,1,0},other)
    testing.expect(t,fits)
    testing.expectf(t,abs(beside.position.x-(-3.9))>=PORTAL_SIZE.x-1e-3,"overlaps at %v",beside.position)
    behind,_:=portal_fit(wall,box,{-3.9,1,-0.5},{0,0,-1},{0,1,0},other)
    testing.expect(t,close(behind.position,{-3.9,1.1,-0.5-PORTAL_LIFT}))
    // A face smaller than the opening takes no portal.
    _,small:=portal_fit(wall,{{-0.5,-0.5,-0.5},{0.5,0.5,0.5}},{0,0,0.5},{0,0,1},{0,1,0},nil)
    testing.expect(t,!small)
}

@(test)
a_portal_on_the_floor_has_its_top_along_the_axis_of_the_floor_nearest_to_the_look :: proc(t:^testing.T) {
    floor:=mm.Transform{{0,-1,0},1,{1,1,1}}
    box:=Surface_Box{{-6,-1,-6},{6,1,6}}
    look:=linalg.normalize([3]f32{0.3,0,-1})
    placed,ok:=portal_fit(floor,box,{1,0,1},{0,1,0},look,nil)
    testing.expect(t,ok)
    testing.expect(t,close(mm.quat_rotate(placed.rotation,[3]f32{0,0,1}),{0,1,0}))
    testing.expect(t,close(mm.quat_rotate(placed.rotation,[3]f32{0,1,0}),{0,0,-1}))
    testing.expect(t,close(placed.position,{1,PORTAL_LIFT,1}))
}
