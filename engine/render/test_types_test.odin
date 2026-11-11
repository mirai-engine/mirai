package render

import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:rhi"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    volume.test_types(types)
    append(types,
        core.test_type(Graphics_Settings,default=proc(dst:^Graphics_Settings) {dst^=GRAPHICS_SETTINGS_DEFAULT},for_device=proc(dst:^Graphics_Settings,device:rawptr) {dst^=graphics_settings_for_device((cast(^rhi.Device_Info)device)^)}),
        core.test_type(Tint,default=proc(dst:^Tint) {dst^=TINT_DEFAULT}),
        core.test_type(Sun,default=proc(dst:^Sun) {dst^=SUN_DEFAULT}),
        core.test_type(Point_Light,default=proc(dst:^Point_Light) {dst^=POINT_LIGHT_DEFAULT}),
        core.test_type(Spot_Light,default=proc(dst:^Spot_Light) {dst^=SPOT_LIGHT_DEFAULT}),
        core.test_type(Rect_Light,default=proc(dst:^Rect_Light) {dst^=RECT_LIGHT_DEFAULT}),
        core.test_type(Camera,default=proc(dst:^Camera) {dst^=CAMERA_DEFAULT}),
        core.test_type(Layers,default=proc(dst:^Layers) {dst^=LAYERS_DEFAULT}),
        core.test_type(Exposure,default=proc(dst:^Exposure) {dst^=EXPOSURE_DEFAULT}),
        core.test_type(Outline,default=proc(dst:^Outline) {dst^=OUTLINE_DEFAULT}),
        core.test_type(Outline_Styles,default=proc(dst:^Outline_Styles) {dst^=OUTLINE_STYLES_DEFAULT}),
        core.test_type(Render_Sync,free=sync_free),
        core.test_type(Sky,default=proc(dst:^Sky) {dst^=SKY_DEFAULT}),
        core.test_type(View_Volume,default=proc(dst:^View_Volume) {dst^=VIEW_VOLUME_DEFAULT}),
    )
}
