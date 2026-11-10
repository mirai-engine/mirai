package foliage

import "mirai:core"
import phys "plugins:physics/runtime"
import erender "mirai:engine/render"
import evolume "mirai:engine/volume"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    phys.test_types(types)
    erender.test_types(types)
    evolume.test_types(types)
    append(types,
        core.test_type(Foliage_Settings,default=proc(dst:^Foliage_Settings) {dst^=FOLIAGE_SETTINGS_DEFAULT}),
        core.test_type(Foliage_Bender,default=proc(dst:^Foliage_Bender) {dst^=FOLIAGE_BENDER_DEFAULT}),
        core.test_type(Foliage_Resident,free=foliage_resident_free),
    )
}
