package shapes_editor

import "mirai:core"
import shapes "plugins:shapes/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    shapes.test_types(types)
    append(types,
        core.test_type(Shapes_Tool,free=shapes_tool_free),
        core.test_type(Shapes_Api,default=proc(dst:^Shapes_Api) {dst^=SHAPES_API_DEFAULT}),
    )
}
