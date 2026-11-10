package water

import "mirai:core"
import phys "plugins:physics/runtime"
import erender "mirai:engine/render"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    phys.test_types(types)
    erender.test_types(types)
    append(types,
        core.test_type(Water,default=proc(dst:^Water) {dst^=WATER_DEFAULT}),
    )
}
