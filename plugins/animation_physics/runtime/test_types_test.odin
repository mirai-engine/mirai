package animation_physics

import "mirai:core"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// What the declarations of the libraries this one joins name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    phys.test_types(types)
    anim.test_types(types)
}
