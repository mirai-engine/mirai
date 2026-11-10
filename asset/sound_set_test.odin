package asset

import "core:math"
import "core:fmt"
import "core:testing"
import "mirai:std/base"

@(test)
sound_sets_keep_their_sounds_and_ranges_and_depend_on_their_sounds :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    info:=SOUND_SET_DEFAULTS
    info.sounds[0]={sound=base.Asset_Id{1,2},weight=2}
    info.sounds[1]={sound=base.Asset_Id{3,4}}
    info.volume_min,info.pitch_min,info.pitch_max=0.5,0.9,1.1
    path:=fmt.tprintf("%s/steps.sound_set",base.test_folder(t,"asset"))
    testing.expect_value(t,sound_set_save(path,&types,{id={7,8},info=info}),Error.None)

    a:Asset
    testing.expect_value(t,asset_load(&a,path),Error.None)
    defer asset_close(&a)
    view,error:=sound_set_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,view.info^==info)
    testing.expect_value(t,len(a.dependencies),2)
    kind,known:=kind_of_extension("x/steps.sound_set")
    testing.expect(t,known && kind==KIND_SOUND_SET)
    kind,known=kind_of_extension("x/step.sound")
    testing.expect(t,known && kind==KIND_SOUND)

    for bad in ([4]Sound_Set_Info{
        {volume_min=2,volume_max=1,pitch_min=1,pitch_max=1},
        {volume_min=1,volume_max=1,pitch_min=0,pitch_max=1},
        {volume_min=1,volume_max=1,pitch_min=1,pitch_max=65},
        {sounds={0={weight=math.nan_f32()}},volume_min=1,volume_max=1,pitch_min=1,pitch_max=1},
    }) {
        field,message:=sound_set_problem(bad)
        testing.expect(t,field!="" && message!="")
        testing.expect_value(t,sound_set_save(path,&types,{id={7,8},info=bad}),Error.Invalid)
    }
}
