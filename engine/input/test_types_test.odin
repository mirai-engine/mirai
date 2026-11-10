package input

import "mirai:core"

// What the declarations of this library name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    append(types,
        core.test_type(Look_Actions,default=proc(dst:^Look_Actions) {dst^=look_actions_default()}),
        core.test_type(Local_Multiplayer,default=proc(dst:^Local_Multiplayer) {dst^=LOCAL_MULTIPLAYER_DEFAULT}),
    )
}
