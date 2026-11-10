package imprint

import "mirai:core"
import phys "plugins:physics/runtime"
import erender "mirai:engine/render"
import vfx "plugins:vfx/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    phys.test_types(types)
    erender.test_types(types)
    vfx.test_types(types)
    append(types,
        core.test_type(Imprint_Ground,default=proc(dst:^Imprint_Ground) {dst^=IMPRINT_GROUND_DEFAULT}),
        core.test_type(Imprint_Stamp,default=proc(dst:^Imprint_Stamp) {dst^=IMPRINT_STAMP_DEFAULT}),
    )
}
