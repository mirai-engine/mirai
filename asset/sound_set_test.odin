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
    info.hearing={attenuation=.Linear,min_distance=2,max_distance=300,rolloff=0.5,reverb=0.4,priority=3}
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

    Case :: struct {field:string,change:proc(info:^Sound_Set_Info)}
    for c in ([?]Case{
        {"volume_min",proc(i:^Sound_Set_Info) {i.volume_min=2}},
        {"pitch_min",proc(i:^Sound_Set_Info) {i.pitch_min=0}},
        {"pitch_min",proc(i:^Sound_Set_Info) {i.pitch_max=65}},
        {"sounds.weight",proc(i:^Sound_Set_Info) {i.sounds[0].weight=math.nan_f32()}},
        {"hearing.min_distance",proc(i:^Sound_Set_Info) {i.hearing.max_distance=i.hearing.min_distance}},
        {"hearing.min_distance",proc(i:^Sound_Set_Info) {i.hearing.min_distance=0}},
        {"hearing.min_distance",proc(i:^Sound_Set_Info) {i.hearing.max_distance=math.inf_f32(1)}},
        {"hearing.rolloff",proc(i:^Sound_Set_Info) {i.hearing.rolloff=math.nan_f32()}},
        {"hearing.reverb",proc(i:^Sound_Set_Info) {i.hearing.reverb=2}},
        {"hearing.attenuation",proc(i:^Sound_Set_Info) {i.hearing.attenuation=Attenuation_Model(9)}},
    }) {
        bad:=SOUND_SET_DEFAULTS
        c.change(&bad)
        field,message:=sound_set_problem(bad)
        testing.expectf(t,field==c.field && message!="","%s: %s",c.field,field)
        testing.expect_value(t,sound_set_save(path,&types,{id={7,8},info=bad}),Error.Invalid)
    }
}
