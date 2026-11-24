package previews_editor

import "core:testing"
import "mirai:asset"
import mixer "mirai:audio"
import "mirai:std/base"

// The band a quick control of the mixer edits: the first of its kind, else
// the first that is off, else none.
@(test)
quick_filters_edit_the_band_of_their_kind_or_a_free_one :: proc(t:^testing.T) {
    Case :: struct {filters:[mixer.BUS_FILTERS]mixer.Filter,kind:mixer.Filter_Kind,band:int}
    for c,i in ([?]Case{
        {{},.Lowpass,0},
        {{0={kind=.Lowpass,frequency=500}},.Highpass,1},
        {{0={kind=.Highpass},2={kind=.Lowpass}},.Lowpass,2},
        {{{kind=.Peak},{kind=.Peak},{kind=.Bandpass},{kind=.Highpass}},.Lowpass,-1},
        {{{kind=.Peak},{kind=.Peak},{kind=.Bandpass},{kind=.Highpass}},.Highpass,3},
    }) {
        testing.expectf(t,quick_band(c.filters,c.kind)==c.band,"case %d: band %d",i,quick_band(c.filters,c.kind))
    }
}

// Play hears a set at the values of its sliders, looping while it has
// parameters; a new curve starts flat, changing nothing.
@(test)
a_set_is_heard_at_its_sliders_and_new_curves_change_nothing :: proc(t:^testing.T) {
    p:Sound
    p.id,p.kind=base.Asset_Id{1,2},asset.KIND_SOUND_SET
    p.held=asset.SOUND_SET_DEFAULTS
    p.preview={0.25,0,0.5,0}
    source:=sound_heard_as(&p)
    testing.expect(t,!source.loop && source.parameters=={0.25,0,0.5,0} && source.sound==p.id)
    base.text_set(p.held.parameters[2].name[:],"rpm")
    testing.expect(t,sound_heard_as(&p).loop && sound_set_named(&p.held)==1)
    for target in asset.Sound_Curve_Target {
        c:=asset.Sound_Curve{parameter=3,target=target}
        curve_flat(&c)
        p.held.curves[0]=c
        _,message:=asset.sound_set_problem(p.held)
        testing.expectf(t,message=="","%v: %s",target,message)
        shape:=asset.sound_set_shape(&p.held,0,{0,0,0.5,0})
        testing.expectf(t,shape==asset.SOUND_SHAPE_NONE,"%v: %v",target,shape)
    }
    // Switching target clamps out-of-range points (e.g. gain 0 -> pitch/lowpass).
    c:=asset.Sound_Curve{parameter=3,target=.Gain,layer=1,count=2,points={0={0,0},1={1,0}}}
    for target in ([2]asset.Sound_Curve_Target{.Pitch,.Lowpass}) {
        c.target=target
        curve_clamp_target(&c,.Layered)
        p.held.curves[0]=c
        _,message:=asset.sound_set_problem(p.held)
        testing.expectf(t,message=="","after switching to %v: %s",target,message)
    }
}
