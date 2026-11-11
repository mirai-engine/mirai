package volume

import "mirai:core"
import scene "mirai:engine/scene"

// What the declarations of this library name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    scene.test_types(types)
    append(types,
        core.test_type(Gravity,default=proc(dst:^Gravity) {dst^=GRAVITY_DEFAULT}),
        core.test_type(Volume,default=proc(dst:^Volume) {dst^=VOLUME_DEFAULT}),
        core.test_type(Spline,default=proc(dst:^Spline) {dst^=SPLINE_DEFAULT}),
        core.test_type(Wind,default=proc(dst:^Wind) {dst^=WIND_DEFAULT}),
    )
}
