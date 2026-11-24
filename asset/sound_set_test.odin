package asset

import "core:math"
import "core:fmt"
import "core:testing"
import "mirai:std/base"

@(test)
sound_sets_keep_their_sounds_and_ranges_and_depend_on_their_sounds :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    info:=SOUND_SET_DEFAULTS
    info.sounds[0]={sound=base.Asset_Id{1,2},weight=2,gain=0.5,pitch=1.5}
    info.sounds[1]={sound=base.Asset_Id{3,4},delay=0.25}
    info.volume_min,info.pitch_min,info.pitch_max=0.5,0.9,1.1
    info.mode=.Layered
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
        {"sounds.gain",proc(i:^Sound_Set_Info) {i.sounds[1].gain=-1}},
        {"sounds.gain",proc(i:^Sound_Set_Info) {i.sounds[1].gain=math.inf_f32(1)}},
        {"sounds.pitch",proc(i:^Sound_Set_Info) {i.sounds[2].pitch=65}},
        {"sounds.pitch",proc(i:^Sound_Set_Info) {i.sounds[2].pitch=math.nan_f32()}},
        {"sounds.delay",proc(i:^Sound_Set_Info) {i.sounds[3].delay=-0.01}},
        {"sounds.delay",proc(i:^Sound_Set_Info) {i.sounds[3].delay=SOUND_SET_DELAY_MAX+1}},
        {"sounds.delay",proc(i:^Sound_Set_Info) {i.sounds[3].delay=math.nan_f32()}},
        {"hearing.min_distance",proc(i:^Sound_Set_Info) {i.hearing.max_distance=i.hearing.min_distance}},
        {"hearing.min_distance",proc(i:^Sound_Set_Info) {i.hearing.min_distance=0}},
        {"hearing.min_distance",proc(i:^Sound_Set_Info) {i.hearing.max_distance=math.inf_f32(1)}},
        {"hearing.rolloff",proc(i:^Sound_Set_Info) {i.hearing.rolloff=math.nan_f32()}},
        {"hearing.reverb",proc(i:^Sound_Set_Info) {i.hearing.reverb=2}},
        {"hearing.attenuation",proc(i:^Sound_Set_Info) {i.hearing.attenuation=Attenuation_Model(9)}},
        {"mode",proc(i:^Sound_Set_Info) {i.mode=Sound_Set_Mode(7)}},
        {"parameters.glide",proc(i:^Sound_Set_Info) {i.parameters[0].glide=-1}},
        {"parameters.name",proc(i:^Sound_Set_Info) {base.text_set(i.parameters[0].name[:],"rpm");base.text_set(i.parameters[2].name[:],"rpm")}},
        {"curves.parameter",proc(i:^Sound_Set_Info) {i.curves[0]={parameter=1,count=1}}},
        {"curves.parameter",proc(i:^Sound_Set_Info) {i.curves[0]={parameter=5,count=1}}},
        {"curves.layer",proc(i:^Sound_Set_Info) {base.text_set(i.parameters[0].name[:],"rpm");i.curves[0]={parameter=1,layer=17,count=1,points={0={0,1}}}}},
        {"curves.layer",proc(i:^Sound_Set_Info) {
            base.text_set(i.parameters[0].name[:],"rpm")
            i.mode=.Layered
            i.curves[0]={parameter=1,target=.Pitch,layer=2,count=1,points={0={0,1}}}
        }},
        {"curves.count",proc(i:^Sound_Set_Info) {base.text_set(i.parameters[0].name[:],"rpm");i.curves[0]={parameter=1,count=0}}},
        {"curves.points",proc(i:^Sound_Set_Info) {base.text_set(i.parameters[0].name[:],"rpm");i.curves[0]={parameter=1,count=2,points={0={1,1},1={0,1}}}}},
        {"curves.points",proc(i:^Sound_Set_Info) {base.text_set(i.parameters[0].name[:],"rpm");i.curves[0]={parameter=1,count=1,points={0={0,-1}}}}},
        {"curves.points",proc(i:^Sound_Set_Info) {base.text_set(i.parameters[0].name[:],"rpm");i.curves[0]={parameter=1,target=.Pitch,count=1,points={0={0,0}}}}},
        {"curves.points",proc(i:^Sound_Set_Info) {base.text_set(i.parameters[0].name[:],"rpm");i.curves[0]={parameter=1,target=.Lowpass,count=1,points={0={math.nan_f32(),100}}}}},
    }) {
        bad:=SOUND_SET_DEFAULTS
        c.change(&bad)
        field,message:=sound_set_problem(bad)
        testing.expectf(t,field==c.field && message!="","%s: %s",c.field,field)
        testing.expect_value(t,sound_set_save(path,&types,{id={7,8},info=bad}),Error.Invalid)
    }
}

// A Layered set with its parameters and curves is kept as it was written.
@(test)
sound_sets_keep_their_mode_parameters_and_curves :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    info:=SOUND_SET_DEFAULTS
    info.mode=.Layered
    info.sounds[0],info.sounds[1]={sound=base.Asset_Id{1,2}},{sound=base.Asset_Id{3,4}}
    base.text_set(info.parameters[0].name[:],"rpm")
    info.parameters[0].glide=0.25
    info.curves[0]={parameter=1,target=.Gain,layer=1,count=2,points={0={0,1},1={1,0}}}
    info.curves[1]={parameter=1,target=.Pitch,count=2,points={0={0,0.8},1={1,1.6}}}
    _,message:=sound_set_problem(info)
    testing.expect_value(t,message,"")
    path:=fmt.tprintf("%s/engine.sound_set",base.test_folder(t,"asset"))
    testing.expect_value(t,sound_set_save(path,&types,{id={9,9},info=info}),Error.None)
    a:Asset
    testing.expect_value(t,asset_load(&a,path),Error.None)
    defer asset_close(&a)
    view,error:=sound_set_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,view.info^==info)
    index,found:=sound_set_parameter(view.info,"rpm")
    testing.expect(t,found && index==0)
    _,found=sound_set_parameter(view.info,"speed")
    testing.expect(t,!found)
}

// What the curves of a set give each of its sounds, by the values of its parameters.
@(test)
sound_set_curves_shape_their_sounds :: proc(t:^testing.T) {
    info:=SOUND_SET_DEFAULTS
    base.text_set(info.parameters[0].name[:],"intensity")
    base.text_set(info.parameters[1].name[:],"distance")
    // The first sound fades out as the second fades in; the second is a bump.
    info.curves[0]={parameter=1,target=.Gain,layer=1,count=2,points={0={0,1},1={1,0}}}
    info.curves[1]={parameter=1,target=.Gain,layer=2,count=3,points={0={0,0},1={0.5,1},2={1,0}}}
    info.curves[2]={parameter=1,target=.Pitch,count=2,points={0={0,1},1={1,2}}}
    info.curves[3]={parameter=2,target=.Lowpass,count=2,points={0={0,SOUND_LOWPASS_MAX},1={1,100}}}
    // A second curve on the same target multiplies.
    info.curves[4]={parameter=2,target=.Gain,count=1,points={0={0,0.5}}}
    Case :: struct {layer:int,values:[SOUND_SET_PARAMETERS]f32,want:Sound_Shape}
    for c in ([?]Case{
        {0,{0,0,0,0},{0.5,1,0}},
        {0,{0.5,0,0,0},{0.25,1.5,0}},
        {0,{2,0,0,0},{0,2,0}},  // past the last point: flat
        {0,{-1,0,0,0},{0.5,1,0}}, // before the first: flat
        {1,{0.25,0,0,0},{0.25,1.25,0}},
        {1,{0.5,0,0,0},{0.5,1.5,0}},
        {1,{0.75,0,0,0},{0.25,1.75,0}},
        {2,{0.5,0,0,0},{0.5,1.5,0}}, // no curve of its own
        // By octaves: halfway from 24 kHz to 100 Hz is their geometric mean.
        {2,{0,0.5,0,0},{0.5,1,math.sqrt(SOUND_LOWPASS_MAX*100)}},
        {2,{0,1,0,0},{0.5,1,100}},
    }) {
        got:=sound_set_shape(&info,c.layer,c.values)
        ok:=abs(got.gain-c.want.gain)<1e-5 && abs(got.pitch-c.want.pitch)<1e-5 && abs(got.lowpass-c.want.lowpass)<c.want.lowpass*1e-4+1e-5
        testing.expectf(t,ok,"layer %d at %v: %v, want %v",c.layer,c.values,got,c.want)
    }
}
