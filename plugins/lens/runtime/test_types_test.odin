package lens

import "mirai:core"
import render "mirai:engine/render"
import volume "mirai:engine/volume"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    render.test_types(types)
    volume.test_types(types)
    append(types,
        core.test_type(Lens,default=proc(dst:^Lens) {dst^=LENS_DEFAULT}),
        core.test_type(Lens_Volume,default=proc(dst:^Lens_Volume) {dst^=LENS_VOLUME_DEFAULT}),
    )
}
