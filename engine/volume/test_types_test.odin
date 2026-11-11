package volume

import "mirai:core"

// What the declarations of this library name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    append(types,
        core.test_type(Gravity,default=proc(dst:^Gravity) {dst^=GRAVITY_DEFAULT}),
        core.test_type(Volume,default=proc(dst:^Volume) {dst^=VOLUME_DEFAULT}),
        core.test_type(Wind,default=proc(dst:^Wind) {dst^=WIND_DEFAULT}),
    )
}
