package terrain

import "mirai:core"
import phys "plugins:physics/runtime"
import erender "mirai:engine/render"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    phys.test_types(types)
    erender.test_types(types)
    append(types,
        core.test_type(Terrain,default=proc(dst:^Terrain) {dst^=TERRAIN_DEFAULT}),
        core.test_type(Terrain_Settings,default=proc(dst:^Terrain_Settings) {dst^=TERRAIN_SETTINGS_DEFAULT}),
        core.test_type(Terrain_Data,copy=terrain_data_copy,swap=terrain_data_swap,free=terrain_data_free,reset=terrain_data_reset),
        core.test_type(Terrain_Displacement,free=terrain_displacement_free),
        core.test_type(Terrain_Resident,free=terrain_resident_free),
        core.test_type(Terrain_Dust,default=proc(dst:^Terrain_Dust) {dst^=TERRAIN_DUST_DEFAULT}),
    )
}
