package gui

import "mirai:core"
import audio "mirai:engine/audio"
import inp "mirai:engine/input"
import render "mirai:engine/render"
import volume "mirai:engine/volume"

// The seats of the players and the bodies they drive, as the tests of this library hold them.
@(private)
@(test_world)
Seats_Test_World :: struct {
    using world:Test_World,
    seats:core.Table(inp.Seat),
    moves:core.Table(inp.Move_Input),
}
