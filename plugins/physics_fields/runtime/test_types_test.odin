package physics_fields

import "mirai:core"
import phys "plugins:physics/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    phys.test_types(types)
    append(types,
        core.test_type(Physics_Field,default=proc(dst:^Physics_Field) {dst^=PHYSICS_FIELD_DEFAULT}),
    )
}
