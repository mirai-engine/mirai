package destruct_multiplayer

import "mirai:core"
import destruct "plugins:destruct/runtime"
import multiplayer "plugins:multiplayer/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    destruct.test_types(types)
    multiplayer.test_types(types)
    append(types,core.test_type(Destruct_Net,free=net_free))
}
