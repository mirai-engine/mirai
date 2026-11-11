package camera

import "mirai:core"
import input "mirai:engine/input"
import render "mirai:engine/render"
import volume "mirai:engine/volume"

// The world the tests of this library share.
@(private)
@(test_world)
Test_Cameras :: struct {
    using world:Test_World,
    cameras:core.Table(render.Camera),
    follows:core.Table(Camera_Follow),
    activations:core.Table(Camera_Activation),
    triggers:core.Table(Environment_Trigger),
    volumes:core.Table(volume.Volume),
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
    environment:render.Environment_Requests,
}
