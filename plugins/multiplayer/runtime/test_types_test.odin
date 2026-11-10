package multiplayer

import "mirai:core"
import erender "mirai:engine/render"
import einput "mirai:engine/input"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    erender.test_types(types)
    einput.test_types(types)
    append(types,
        core.test_type(Replicate,default=proc(dst:^Replicate) {dst^=REPLICATE_DEFAULT}),
        core.test_type(Net_Session,free=session_free),
        core.test_type(Rewind_History,free=rewind_free),
    )
}
