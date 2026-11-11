package terrain_editor

import "mirai:core"
import terrain "plugins:terrain/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    terrain.test_types(types)
    append(types,
        core.test_type(Terrain_Tool,free=terrain_tool_free),
        core.test_type(Terrain_Tool_Preferences,default=proc(dst:^Terrain_Tool_Preferences) {dst^=terrain_tool_preferences_default()}),
        core.test_type(Terrain_Api,default=proc(dst:^Terrain_Api) {dst^=TERRAIN_API_DEFAULT}),
    )
}
