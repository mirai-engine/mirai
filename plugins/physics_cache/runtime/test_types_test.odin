package physics_cache

import "mirai:core"
import destruct "plugins:destruct/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    destruct.test_types(types)
    append(types,
        core.test_type(Geometry_Playback,default=proc(dst:^Geometry_Playback) {dst^=GEOMETRY_PLAYBACK_DEFAULT}),
        core.test_type(Cache_Library,free=cache_library_free),
    )
}
