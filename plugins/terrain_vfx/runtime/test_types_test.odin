package terrain_vfx

import "mirai:core"
import terrain "plugins:terrain/runtime"
import vfx "plugins:vfx/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    terrain.test_types(types)
    vfx.test_types(types)
    append(types,
        core.test_type(Terrain_Dust,default=proc(dst:^Terrain_Dust) {dst^=TERRAIN_DUST_DEFAULT}),
    )
}
