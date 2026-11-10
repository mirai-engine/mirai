package terrain_multiplayer

import "mirai:core"
import terrain "plugins:terrain/runtime"
import multiplayer "plugins:multiplayer/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    terrain.test_types(types)
    multiplayer.test_types(types)
    append(types,
        core.test_type(Terrain_Net_Settings,default=proc(dst:^Terrain_Net_Settings) {dst^=TERRAIN_NET_SETTINGS_DEFAULT}),
        core.test_type(Terrain_Net,free=net_free),
    )
}
