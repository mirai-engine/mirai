package scene

import "mirai:core"
import input "mirai:engine/input"
import volume "mirai:engine/volume"

// What the declarations of this library and of the libraries it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    input.test_types(types)
    volume.test_types(types)
    append(types,
        core.test_type(Section_Loads,free=section_loads_free),
        core.test_type(Prefab_Forms,free=prefab_forms_free),
    )
}
