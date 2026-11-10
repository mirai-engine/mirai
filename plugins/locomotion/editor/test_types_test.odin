package locomotion_editor

import "mirai:core"
import locomotion "plugins:locomotion/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    locomotion.test_types(types)
    append(types,
        core.test_type(Locomotion_Bodies,default=proc(dst:^Locomotion_Bodies) {dst^=LOCOMOTION_BODIES_DEFAULT}),
    )
}
