package physics_editor

import "mirai:core"
import phys "plugins:physics/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    phys.test_types(types)
    append(types,
        core.test_type(Physics_Inspector,default=proc(dst:^Physics_Inspector) {dst^=PHYSICS_INSPECTOR_DEFAULT}),
        core.test_type(Physics_Api,default=proc(dst:^Physics_Api) {dst^=PHYSICS_API_DEFAULT}),
        core.test_type(Physics_Components,default=proc(dst:^Physics_Components) {dst^=PHYSICS_COMPONENTS_DEFAULT}),
        core.test_type(Physics_Simulation,default=proc(dst:^Physics_Simulation) {dst^=PHYSICS_SIMULATION_DEFAULT}),
        core.test_type(Collision_View,free=collision_view_free),
    )
}
