package mirai_render

import "core:math"
import "core:testing"

// A camera looks along forward with its up as close to up as that allows; a
// degenerate one still gives finite matrices, which temporal history keeps.
@(test)
camera_matrices_give_a_view_along_forward_and_stay_finite :: proc(t:^testing.T) {
    view,_,forward:=camera_matrices({forward={0,0,-1},up={0,1,0},near=0.1,fov_y=60},1)
    testing.expect_value(t,forward,Vec3{0,0,-1})
    testing.expect_value(t,view,Mat4(1))
    cases:=[]Camera{
        {forward={0,0,0},up={0,1,0},near=0.1,fov_y=60},
        {forward={0,1,0},up={0,1,0},near=0.1,fov_y=60},
        {forward={0,0,-1},up={0,0,0},near=0.1,fov_y=60},
    }
    for camera in cases {
        matrices,projection,along:=camera_matrices(camera,1)
        for v in ([3]f32)(along) {testing.expect(t,!math.is_nan(v) && !math.is_inf(v))}
        for column in 0..<4 {
            for row in 0..<4 {
                testing.expect(t,!math.is_nan(matrices[row,column]) && !math.is_inf(matrices[row,column]) && !math.is_nan(projection[row,column]))
            }
        }
    }
}

// What follows a cut starts the jitter and the pixels that share a ray over:
// its frames do not depend on how many the view drew before it.
@(test)
a_cut_restarts_the_turn_of_a_view :: proc(t:^testing.T) {
    long,short:=View_State{frames=37,turn=37,has_previous=true},View_State{frames=5,turn=5,has_previous=true}
    view_camera_cut(&long)
    view_camera_cut(&short)
    testing.expect_value(t,long.turn,short.turn)
    testing.expect_value(t,taa_jitter(long.turn,TAA_JITTER_PHASES),taa_jitter(short.turn,TAA_JITTER_PHASES))
    testing.expect_value(t,long.frames,u64(37))
}
