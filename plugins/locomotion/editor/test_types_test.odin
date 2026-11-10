package locomotion_editor

import "mirai:core"
import locomotion "plugins:locomotion/runtime"
import phys_editor "plugins:physics/editor"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    phys_editor.test_types(types)
    locomotion.test_types(types)
    append(types,
        core.test_type(Locomotion_Bodies,default=proc(dst:^Locomotion_Bodies) {dst^=LOCOMOTION_BODIES_DEFAULT}),
    )
}
