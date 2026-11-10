package navigation

import "mirai:core"
import phys "plugins:physics/runtime"
import einput "mirai:engine/input"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    phys.test_types(types)
    einput.test_types(types)
    append(types,
        core.test_type(Navigation_Settings,default=proc(dst:^Navigation_Settings) {dst^=NAVIGATION_SETTINGS_DEFAULT}),
        core.test_type(Nav_Bounds,default=proc(dst:^Nav_Bounds) {dst^=NAV_BOUNDS_DEFAULT}),
        core.test_type(Nav_Area,default=proc(dst:^Nav_Area) {dst^=NAV_AREA_DEFAULT}),
        core.test_type(Nav_Obstacle,default=proc(dst:^Nav_Obstacle) {dst^=NAV_OBSTACLE_DEFAULT}),
        core.test_type(Nav_Link,default=proc(dst:^Nav_Link) {dst^=NAV_LINK_DEFAULT}),
        core.test_type(Nav_Agent,default=proc(dst:^Nav_Agent) {dst^=NAV_AGENT_DEFAULT}),
        core.test_type(Nav_Path,default=proc(dst:^Nav_Path) {dst^=NAV_PATH_DEFAULT}),
        core.test_type(Navigation,copy=navigation_copy,copy_kept=navigation_copy_kept,free=navigation_free,reset=navigation_free),
        core.test_type(Navigation_Agents,free=agents_free),
        core.test_type(Navigation_Builds,free=builds_free),
    )
}
