package input

import "mirai:core"

// What the declarations of this library name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {}

// The world the tests of this library share.
@(private)
Test_Seats :: struct {
    using world:core.Test_World,
    seats:core.Table(Seat),
    drivables:core.Table(Drivable),
    worlds:core.Table(core.World_Transform),
    remotes:core.Table(core.Remote),
    hold_requests:Hold_Requests,
    context_requests:Context_Requests,
}
