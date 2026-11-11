package ragdoll

import "mirai:core"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    phys.test_types(types)
    anim.test_types(types)
    append(types,
        core.test_type(Ragdoll,default=proc(dst:^Ragdoll) {dst^=RAGDOLL_DEFAULT}),
        core.test_type(Ragdoll_Bone,default=proc(dst:^Ragdoll_Bone) {dst^=RAGDOLL_BONE_DEFAULT}),
        core.test_type(Ragdoll_Settings,default=proc(dst:^Ragdoll_Settings) {dst^=RAGDOLL_SETTINGS_DEFAULT}),
    )
}
