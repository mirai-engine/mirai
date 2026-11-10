package physics_cache

import "mirai:core"

// What the declarations of this library name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    append(types,
        core.test_type(Geometry_Playback,default=proc(dst:^Geometry_Playback) {dst^=GEOMETRY_PLAYBACK_DEFAULT}),
        core.test_type(Cache_Library,free=cache_library_free),
    )
}
