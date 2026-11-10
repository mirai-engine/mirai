package locomotion

import "mirai:core"
import einput "mirai:engine/input"
import phys "plugins:physics/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    phys.test_types(types)
    einput.test_types(types)
    append(types,
        core.test_type(Walk,default=proc(dst:^Walk) {dst^=WALK_DEFAULT}),
        core.test_type(Fly,default=proc(dst:^Fly) {dst^=FLY_DEFAULT}),
        core.test_type(Swim,default=proc(dst:^Swim) {dst^=SWIM_DEFAULT}),
        core.test_type(Slide,default=proc(dst:^Slide) {dst^=SLIDE_DEFAULT}),
        core.test_type(Mantle,default=proc(dst:^Mantle) {dst^=MANTLE_DEFAULT}),
        core.test_type(Tactical_Sprint,default=proc(dst:^Tactical_Sprint) {dst^=TACTICAL_SPRINT_DEFAULT}),
        core.test_type(Ledge_Jump,default=proc(dst:^Ledge_Jump) {dst^=LEDGE_JUMP_DEFAULT}),
    )
}
