package abilities

import "mirai:core"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    phys.test_types(types)
    anim.test_types(types)
    append(types,
        core.test_type(Ability_Settings,default=proc(dst:^Ability_Settings) {dst^=ABILITY_SETTINGS_DEFAULT}),
    )
}
