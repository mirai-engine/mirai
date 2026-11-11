package vfx

import "mirai:core"
import erender "mirai:engine/render"
import evolume "mirai:engine/volume"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    erender.test_types(types)
    evolume.test_types(types)
    append(types,
        core.test_type(Particle_Emitter,default=proc(dst:^Particle_Emitter) {dst^=PARTICLE_EMITTER_DEFAULT}),
        core.test_type(Particle_Settings,default=proc(dst:^Particle_Settings) {dst^=PARTICLE_SETTINGS_DEFAULT}),
        core.test_type(Particle_Grid,default=proc(dst:^Particle_Grid) {dst^=PARTICLE_GRID_DEFAULT}),
        core.test_type(Particle_Volume,default=proc(dst:^Particle_Volume) {dst^=PARTICLE_VOLUME_DEFAULT}),
        core.test_type(Particle_Sync,free=particle_sync_free),
        core.test_type(Particle_Data_Read,free=particle_data_read_free),
        core.test_type(Particle_Reports,free=particle_reports_free),
    )
}
