package terrain_debris

import "mirai:core"
import terrain "plugins:terrain/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    terrain.test_types(types)
    append(types,
        core.test_type(Terrain_Debris,default=proc(dst:^Terrain_Debris) {dst^=TERRAIN_DEBRIS_DEFAULT}),
    )
}
