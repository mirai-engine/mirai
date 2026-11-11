package input

import "mirai:core"

// The world the tests of this library share.
@(private)
@(test_world)
Test_Seats :: struct {
    using world:Test_World,
    seats:core.Table(Seat),
    moves:core.Table(Move_Input),
    worlds:core.Table(core.World_Transform),
    remotes:core.Table(core.Remote),
    hold_requests:Hold_Requests,
    context_requests:Context_Requests,
}
