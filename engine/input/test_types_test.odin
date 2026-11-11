package input

import "mirai:core"

// What the declarations of this library name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    append(types,
        core.test_type(Local_Multiplayer,default=proc(dst:^Local_Multiplayer) {dst^=LOCAL_MULTIPLAYER_DEFAULT}),
        core.test_type(Drivable,default=proc(dst:^Drivable) {dst^=DRIVABLE_DEFAULT}),
    )
}

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
