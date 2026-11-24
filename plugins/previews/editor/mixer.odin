package previews_editor

import "core:fmt"
import "core:math"
import mixer "mirai:audio"
import "mirai:core"
import "mirai:editor"
import eaudio "mirai:engine/audio"
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"

// The Audio Mixer, under View: a row per bus of the project with its live
// meter, mute and solo, its gain and a low-pass and a high-pass, and the
// snapshots of Audio_Settings to blend to. Gain and filters write the
// project's Audio_Settings, the file at the end of each gesture; mute and solo
// are of the mixer of the editor, also in Play, and never saved. Out of Play
// the editor hears the snapshot chosen (editor.sound_mix_preview).

MIXER_SCOPE :: ui.Id(0x6d697872)
MIXER_WIDTH :: f32(560)
MIXER_NAME :: f32(76)      // of the column of the names of the buses
MIXER_METER :: f32(132)    // of a meter
MIXER_FLOOR :: f32(-60)    // dB at the left end of a meter
MIXER_TOP :: f32(6)        // dB at its right end
MIXER_FILTER_HZ :: f64(20000)

@(storage)
Mixer_Panel :: struct {
    open:bool,
    blend_seconds:f64,
    unsaved:bool, // the settings changed and their file has not taken them yet
}

MIXER_PANEL_DEFAULT :: Mixer_Panel{blend_seconds=1}

@(private)
mixer_panel_of :: proc(s:^editor.Session) -> ^Mixer_Panel {
    if s.info==nil || s.editor_world==nil {return nil}
    return core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Mixer_Panel)
}

// View > Audio Mixer opens and closes the panel.
@(private)
mixer_register :: proc(s:^editor.Session) {
    editor.command_bind(s,{name="audio_mixer",label="Audio Mixer",icon=.Sound,menu=.View,group=editor.MENU_GROUP_PLUGINS,
        state=proc(s:^editor.Session,b:^editor.Binding) -> editor.Command_State {
            p:=mixer_panel_of(s)
            return {checked=p!=nil && p.open,disabled=p==nil}
        },
        view=proc(s:^editor.Session) {if p:=mixer_panel_of(s);p!=nil {p.open=!p.open}},
    })
}

@(step="ui",after="editor_panels")
mixer_panel :: proc(s:^editor.Session,p:^Mixer_Panel,app:^host.App) {
    g:=s.gui
    if !g.begun || !p.open || s.viewport.pick.active {return}
    ctx:=g.ctx
    m:=app.mixer
    id:=ui.id_derive(ctx,MIXER_SCOPE,"panel")
    margin:=ui.metric(ctx,"margin")
    bottom:=margin
    if r:=g.rects.bottom;r.h>0 {bottom+=ctx.size.y-r.y}
    if ui.panel(ctx,id,{width=ui.fixed(MIXER_WIDTH),height=ui.FIT,direction=.Column,padding=ui.padding_all(12),gap=6,anchor=.Bottom_Right,pivot=.Bottom_Right,offset={-margin,-bottom}}) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        mixer_panel_body(s,p,m)
    }
}

// What the panel holds: its title, its snapshots and a row per bus.
@(private)
mixer_panel_body :: proc(s:^editor.Session,p:^Mixer_Panel,m:^mixer.Mixer) {
    ctx:=s.gui.ctx
    small:=ui.metric(ctx,"font_small")
    row:=ui.metric(ctx,"row")
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(row),gap=8,align_y=.Center}) {
        ui.label(ctx,"Audio Mixer",ui.metric(ctx,"font"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
        ui.spacer(ctx)
        if editor.playing(s) {
            playing_id:=ui.id(ctx,"playing")
            if ui.box(ctx,{id=playing_id,width=ui.FIT,height=ui.FIT,padding=ui.padding_xy(6,2),radius=ui.metric(ctx,"radius_control"),fill=ui.tone(ctx,"surface_alt")}) {
                ui.label(ctx,"Playing",small,ui.tone(ctx,"text_muted"))
            }
            if ui.interact(ctx,playing_id).hot {ui.tooltip(ctx,"The game mixes its buses: mute and solo still apply")}
        }
        if ui.button(ctx,ui.id(ctx,"close"),{icon=.Cross,variant="ghost",tip="Close",width=row,height=row}).clicked {p.open=false}
    }
    if m==nil {
        ui.label(ctx,"The editor has no mixer: it runs without a window, or its audio device did not open",small,ui.tone(ctx,"text_muted"))
        return
    }
    settings_at:=(^eaudio.Audio_Settings)(editor.setting_value(s,eaudio.Audio_Settings))
    settings:eaudio.Audio_Settings
    if settings_at!=nil {settings=settings_at^}
    mixer_snapshots(s,p,&settings)
    count:=mixer_bus_count(s,m)
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=2}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(row*0.8),gap=6,align_y=.Center}) {
            muted:=ui.tone(ctx,"text_muted")
            ui.label(ctx,"Bus",small,muted,MIXER_NAME)
            ui.label(ctx,"",small,muted,row*2+4)
            ui.label(ctx,"Level",small,muted,MIXER_METER)
            ui.label(ctx,"Gain",small,muted,78)
            ui.label(ctx,"Low-pass",small,muted,84)
            ui.label(ctx,"High-pass",small,muted)
        }
        for index in 0..<count {
            if mixer_bus_row(s,m,&settings,eaudio.Audio_Bus(index),settings_at!=nil) {
                p.unsaved=editor.setting_set(s,eaudio.Audio_Settings,&settings,false)
            }
        }
    }
    // The file takes the settings once no gesture changes them.
    if p.unsaved && ctx.active==0 && ctx.edit.id==0 {
        editor.setting_set(s,eaudio.Audio_Settings,&settings,true)
        p.unsaved=false
    }
}

// The buses the panel shows: those the mixer has and those the project names.
@(private)
mixer_bus_count :: proc(s:^editor.Session,m:^mixer.Mixer) -> int {
    count:=mixer.bus_count(m)
    for index in 0..<eaudio.AUDIO_BUS_CAPACITY {
        if _,named:=core.name_of(s.info,eaudio.Audio_Bus,i64(index));named {count=max(count,index+1)}
    }
    for mixer.bus_count(m)<count {
        if _,made:=mixer.bus_create(m);!made {break}
    }
    return min(count,mixer.bus_count(m),eaudio.AUDIO_BUS_CAPACITY)
}

// Settings, then each snapshot that has a name, and how long a blend takes.
@(private)
mixer_snapshots :: proc(s:^editor.Session,p:^Mixer_Panel,settings:^eaudio.Audio_Settings) {
    ctx:=s.gui.ctx
    small:=ui.metric(ctx,"font_small")
    row:=ui.metric(ctx,"row")
    shown:=editor.sound_mix_snapshot(s)
    off:=editor.playing(s)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(row),gap=4,align_y=.Center}) {
        ui.label(ctx,"Snapshot",small,ui.tone(ctx,"text_muted"),MIXER_NAME)
        if ui.button(ctx,ui.id(ctx,"snapshot",0),{label="Settings",variant="tab",active=shown<0,size=small,disabled=off,tip="The buses as Audio_Settings says"}).clicked {
            editor.sound_mix_preview(s,-1,f32(p.blend_seconds))
        }
        for &snapshot,i in settings.snapshots {
            name:=base.text_get(snapshot.name[:])
            if name=="" {continue}
            if ui.button(ctx,ui.id(ctx,"snapshot",i+1),{label=name,variant="tab",active=shown==i,size=small,disabled=off,tip="Blend the buses to this snapshot to hear it"}).clicked {
                editor.sound_mix_preview(s,i,f32(p.blend_seconds))
            }
        }
        ui.spacer(ctx)
        ui.label(ctx,"Blend",small,ui.tone(ctx,"text_muted"))
        ui.number_field(ctx,ui.id(ctx,"blend"),&p.blend_seconds,{width=ui.fixed(64),unit="s",decimals=2,speed=0.01,has_min=true,min=0,has_max=true,max=30})
    }
}

// A bus: name, mute, solo, meter, gain, low-pass and high-pass. True when it
// changed the settings.
@(private)
mixer_bus_row :: proc(s:^editor.Session,m:^mixer.Mixer,settings:^eaudio.Audio_Settings,bus:eaudio.Audio_Bus,editable:bool) -> (changed:bool) {
    ctx:=s.gui.ctx
    row:=ui.metric(ctx,"row")
    setting:=eaudio.audio_bus_setting(core.ref(settings),bus)
    name,named:=core.name_of(s.info,eaudio.Audio_Bus,i64(bus))
    if !named {name=fmt.tprintf("Bus %d",int(bus))}
    ui.id_push(ctx,ui.id(ctx,"bus",int(bus)))
    defer ui.id_pop(ctx)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(row),gap=6,align_y=.Center}) {changed=mixer_bus_fields(s,m,&setting,name,bus,editable)}
    if changed && !eaudio.audio_bus_setting_set(settings,setting) {
        editor.notify(s,"Audio_Settings has an entry for every bus it can hold: take one out in Project Settings")
        changed=false
    }
    return
}

// The fields of a bus in its row; true when they changed its setting.
@(private)
mixer_bus_fields :: proc(s:^editor.Session,m:^mixer.Mixer,setting:^eaudio.Audio_Bus_Setting,name:string,bus:eaudio.Audio_Bus,editable:bool) -> (changed:bool) {
    ctx:=s.gui.ctx
    small:=ui.metric(ctx,"font_small")
    row:=ui.metric(ctx,"row")
    at:=mixer.Bus(bus)
    ui.label(ctx,name,small,ui.tone(ctx,"text_muted") if mixer.bus_silent(m,at) else ui.tone(ctx,"text"),MIXER_NAME)
    muted,soloed:=mixer.bus_muted(m,at),mixer.bus_soloed(m,at)
    if ui.button(ctx,ui.id(ctx,"mute"),{label="M",variant="tab",active=muted,size=small,center=true,width=row,height=row,tip="Mute"}).clicked {mixer.bus_set_mute(m,at,!muted)}
    if ui.button(ctx,ui.id(ctx,"solo"),{label="S",variant="tab",active=soloed,size=small,center=true,width=row,height=row,tip="Solo: only the soloed buses, what plays into them and the master are heard",disabled=bus==eaudio.BUS_MASTER}).clicked {mixer.bus_set_solo(m,at,!soloed)}
    mixer_meter(s,mixer.bus_meter(m,at))
    disabled:=!editable || editor.playing(s)
    gain:=f64(setting.gain)
    if r:=ui.number_field(ctx,ui.id(ctx,"gain"),&gain,{width=ui.fixed(78),unit="dB",decimals=1,speed=0.1,has_min=true,min=f64(eaudio.AUDIO_SILENCE_DB),has_max=true,max=24,disabled=disabled});r.changed {
        setting.gain=f32(gain)
        changed=true
    }
    for kind,k in ([2]mixer.Filter_Kind{.Lowpass,.Highpass}) {
        band:=quick_band(setting.filters,kind)
        hz:=f64(setting.filters[band].frequency) if band>=0 && setting.filters[band].kind==kind else 0
        if r:=ui.number_field(ctx,ui.id(ctx,"cutoff",k),&hz,{width=ui.fixed(84) if k==0 else ui.GROW,unit="Hz",decimals=0,speed=10,has_min=true,min=0,has_max=true,max=MIXER_FILTER_HZ,disabled=disabled || band<0});r.changed {
            q:=setting.filters[band].q if setting.filters[band].kind==kind else 0
            setting.filters[band]={kind=kind,frequency=f32(hz),q=q} if hz>0 else {}
            changed=true
        }
    }
    return
}

// The band of the filters the quick control of a kind edits: the first of
// that kind, else the first that is off; -1 when every band is of other kinds.
@(private)
quick_band :: proc(filters:[mixer.BUS_FILTERS]mixer.Filter,kind:mixer.Filter_Kind) -> int {
    for f,band in filters {
        if f.kind==kind {return band}
    }
    for f,band in filters {
        if f.kind==.Off {return band}
    }
    return -1
}

// The level of the left and right channels, from MIXER_FLOOR to MIXER_TOP dB;
// at full scale and above in the color of danger.
@(private)
mixer_meter :: proc(s:^editor.Session,meter:[2]f32) {
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.fixed(MIXER_METER),height=ui.fixed(9),direction=.Column,gap=1,align_y=.Center}) {
        for level in meter {
            db:=20*math.log10(max(level,1e-6))
            share:=clamp((db-MIXER_FLOOR)/(MIXER_TOP-MIXER_FLOOR),0,1)
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(4),fill=ui.tone(ctx,"field"),radius=1}) {
                if share>0 {
                    color:=ui.tone(ctx,"danger") if level>=1 else ui.tone(ctx,"accent")
                    if ui.box(ctx,{width=ui.fixed(share*MIXER_METER),height=ui.GROW,fill=color,radius=1}) {}
                }
            }
        }
    }
}
