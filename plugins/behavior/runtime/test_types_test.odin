package behavior

import "mirai:core"
import nav "plugins:navigation/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    nav.test_types(types)
    append(types,
        core.test_type(Perceiver,default=proc(dst:^Perceiver) {dst^=PERCEIVER_DEFAULT}),
        core.test_type(Perceivable,default=proc(dst:^Perceivable) {dst^=PERCEIVABLE_DEFAULT}),
        core.test_type(Behavior_Settings,default=proc(dst:^Behavior_Settings) {dst^=BEHAVIOR_SETTINGS_DEFAULT}),
        core.test_type(Mind_Presentation,default=proc(dst:^Mind_Presentation) {dst^=MIND_PRESENTATION_DEFAULT}),
        core.test_type(Places,free=places_free),
        core.test_type(Influence,free=influence_free),
    )
}
