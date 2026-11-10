package foliage_editor

import "mirai:core"
import foliage "plugins:foliage/runtime"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    foliage.test_types(types)
    append(types,
        core.test_type(Foliage_Tool,free=foliage_tool_free),
        core.test_type(Foliage_Tool_Preferences,default=proc(dst:^Foliage_Tool_Preferences) {dst^=foliage_tool_preferences_default()}),
        core.test_type(Foliage_Api,default=proc(dst:^Foliage_Api) {dst^=FOLIAGE_API_DEFAULT}),
        core.test_type(Foliage_Thumbnails,default=proc(dst:^Foliage_Thumbnails) {dst^=FOLIAGE_THUMBNAILS_DEFAULT}),
        core.test_type(Foliage_Kinds,default=proc(dst:^Foliage_Kinds) {dst^=FOLIAGE_KINDS_DEFAULT}),
        core.test_type(Foliage_Menu,default=proc(dst:^Foliage_Menu) {dst^=FOLIAGE_MENU_DEFAULT}),
    )
}
