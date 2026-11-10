package playtest_editor

import "mirai:core"
import input "mirai:engine/input"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    input.test_types(types)
    append(types,
        core.test_type(Playtest,free=playtest_free),
        core.test_type(Playtest_Api,default=proc(dst:^Playtest_Api) {dst^=playtest_api_default()}),
        core.test_type(Playtest_Listener,default=proc(dst:^Playtest_Listener) {dst^=playtest_listener_default()}),
    )
}
