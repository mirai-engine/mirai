package gui

import "mirai:core"
import inp "mirai:engine/input"
import render "mirai:engine/render"
import volume "mirai:engine/volume"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    inp.test_types(types)
    render.test_types(types)
    volume.test_types(types)
    append(types,
        core.test_type(World_Widget,default=proc(dst:^World_Widget) {dst^=WORLD_WIDGET_DEFAULT}),
        core.test_type(UI_Settings,default=proc(dst:^UI_Settings) {dst^=UI_SETTINGS_DEFAULT}),
        core.test_type(UI_Preferences,default=proc(dst:^UI_Preferences) {dst^=UI_PREFERENCES_DEFAULT}),
        core.test_type(Menu_Actions,default=proc(dst:^Menu_Actions) {dst^=menu_actions_default()}),
        core.test_type(Gui,free=gui_free),
    )
}

// The seats of the players and the bodies they drive, as the tests of this library hold them.
@(private)
Seats_Test_World :: struct {
    using world:core.Test_World,
    seats:core.Table(inp.Seat),
    drivables:core.Table(inp.Drivable),
}
