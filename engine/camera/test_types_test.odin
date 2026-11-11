package camera

import "mirai:core"
import input "mirai:engine/input"
import render "mirai:engine/render"
import volume "mirai:engine/volume"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    input.test_types(types)
    render.test_types(types)
    volume.test_types(types)
    append(types,
        core.test_type(Camera_Follow,default=proc(dst:^Camera_Follow) {dst^=CAMERA_FOLLOW_DEFAULT}),
        core.test_type(Camera_Activation,default=proc(dst:^Camera_Activation) {dst^=CAMERA_ACTIVATION_DEFAULT}),
    )
}

// The world the tests of this library share.
@(private)
Test_Cameras :: struct {
    using world:core.Test_World,
    cameras:core.Table(render.Camera),
    follows:core.Table(Camera_Follow),
    activations:core.Table(Camera_Activation),
    transforms:core.Table(core.Transform),
    worlds:core.Table(core.World_Transform),
    parents:core.Table(core.Parent),
    moves:core.Table(input.Move_Input),
    hierarchy:core.Hierarchy,
    seats:core.Table(input.Seat),
    seat_state:input.Seats,
    selected:Cameras,
    requests:Camera_Requests,
    shakes:Camera_Shakes,
}
