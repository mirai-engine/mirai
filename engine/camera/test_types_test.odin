package camera

import "mirai:core"
import input "mirai:engine/input"
import render "mirai:engine/render"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    input.test_types(types)
    render.test_types(types)
    append(types,
        core.test_type(Camera_Follow,default=proc(dst:^Camera_Follow) {dst^=CAMERA_FOLLOW_DEFAULT}),
        core.test_type(Camera_Activation,default=proc(dst:^Camera_Activation) {dst^=CAMERA_ACTIVATION_DEFAULT}),
        core.test_type(Environment_Trigger,default=proc(dst:^Environment_Trigger) {dst^=ENVIRONMENT_TRIGGER_DEFAULT}),
    )
}
