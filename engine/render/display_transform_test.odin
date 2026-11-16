package render

import "core:testing"
import gpu "mirai:render"
import "mirai:project"

@(test)
a_project_takes_neutral_unless_its_settings_choose_aces :: proc(t:^testing.T) {
    settings:=Display_Transform_Settings{}
    testing.expect_value(t,settings.transform,gpu.Display_Transform.Neutral)
    list:=[]project.Setting{{name="Display_Transform_Settings",info=type_info_of(Display_Transform_Settings),value=&settings}}
    error:=project.settings_parse(`{"Display_Transform_Settings":{"transform":"ACES_2"}}`,list)
    testing.expect_value(t,error.code,project.Error_Code.None)
    testing.expect_value(t,settings.transform,gpu.Display_Transform.ACES_2)
    error=project.settings_parse(`{"Display_Transform_Settings":{"transform":"Filmic"}}`,list)
    testing.expect(t,error.code!=.None,"a transform that does not exist is an error")
}

@(test)
the_ev100_that_shows_a_luminance_white_exposes_it_to_one :: proc(t:^testing.T) {
    for luminance in ([]f32{0.05,1,250,40000}) {
        unit:=luminance*gpu.exposure_of_ev100(ev100_white(luminance),0)
        testing.expectf(t,abs(unit-1)<1e-4,"%v nits at their ev100_white are %v, not 1",luminance,unit)
    }
}
