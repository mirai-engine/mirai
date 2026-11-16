package editor

import "core:math"
import "mirai:asset"
import "mirai:std/base"
import "mirai:ui"

// What the documents of assets that play share: the time inside a duration
// at a speed, with the view and the range of its time strip; the sun of a
// preview in the toolbar; and their columns with a heading each.

Asset_Playback :: struct {
    time:f32, // s
    speed:f32,
    loop,playing:bool,
    strip:Timeline,
}
ASSET_PLAYBACK_RATE :: f32(30) // frames per second the strip counts a preview in

// Moves the time of what plays inside its range. What does not loop stops at its end.
asset_playback_advance :: proc(p:^Asset_Playback,duration,dt:f32) {
    if duration<=0 {
        p.time,p.playing=0,false
        return
    }
    lo,hi:=timeline_bounds(&p.strip,duration*ASSET_PLAYBACK_RATE)
    lo,hi=lo/ASSET_PLAYBACK_RATE,hi/ASSET_PLAYBACK_RATE
    if p.playing {
        next:=p.time+dt*p.speed
        if p.loop && hi>lo {
            if next<lo || next>=hi {next=lo+(next-lo)-math.floor((next-lo)/(hi-lo))*(hi-lo)}
        } else if next>=hi || next<=lo {
            next=clamp(next,lo,hi)
            p.playing=false
        }
        p.time=next
    }
    p.time=clamp(p.time,0,duration)
}

// The time strip of a preview of the asset under it, with lanes of marks:
// what it asks of the time, of play and of its range goes to p and the
// agent; what it asks of the marks is returned. part names the clip of an
// asset with several.
asset_playback_strip :: proc(s:^Session,p:^Asset_Playback,duration:f32,lanes:[]Timeline_Lane,subject:base.Asset_Id,part:="") -> Timeline_Result {
    frames:=max(duration,0)*ASSET_PLAYBACK_RATE
    clock:=Timeline_Clock{frame=p.time*ASSET_PLAYBACK_RATE,frames=frames,rate=ASSET_PLAYBACK_RATE,playing=p.playing,loop=p.loop,speed=p.speed,ask=timeline_can_ask(s)}
    r:=timeline_strip(s,&p.strip,clock,lanes,ui.id(s.gui.ctx,"strip"))
    if (r.ask || r.copy) && p.strip.range {
        lo,hi:=timeline_range(&p.strip,frames)
        range:=Ai_Range{kind=.Asset,from=u64(lo),to=u64(hi),rate=ASSET_PLAYBACK_RATE}
        if a:=s.app.assets;a!=nil {
            if file,found:=asset.registry_find(&a.registry,subject);found {base.text_set(range.path[:],file.path)}
        }
        base.text_set(range.name[:],part)
        timeline_range_use(s,r,range)
    }
    if r.seek {p.time,p.playing=r.frame/ASSET_PLAYBACK_RATE,false}
    if r.loop {p.loop=!p.loop}
    if r.speed>0 {p.speed=r.speed}
    if r.play {
        p.playing=!p.playing
        // Played again from the end it stopped at.
        lo,hi:=timeline_bounds(&p.strip,frames)
        if p.playing && (p.time*ASSET_PLAYBACK_RATE>=hi || p.time*ASSET_PLAYBACK_RATE<lo) {p.time=lo/ASSET_PLAYBACK_RATE}
    }
    return r
}

// The sun of a preview, in the room the toolbar leaves the document.
asset_preview_sun :: proc(s:^Session,sun:^bool) {
    g:=s.gui;ctx:=g.ctx
    rect,found:=asset_toolbar(g)
    if !found || rect.w<=0 {return}
    if ui.box(ctx,{width=ui.fixed(rect.w),height=ui.fixed(rect.h),padding={12,0,0,0},gap=8,align_y=.Center,float={to=.Surface,offset={rect.x,rect.y},layer=ui.LAYER_BAR}}) {
        ui.id_push(ctx,shell_id(g,"asset_playback"))
        defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.fixed(1),height=ui.fixed(18),fill=ui.tone(ctx,"border")}) {}
        if ui.button(ctx,ui.id(ctx,"sun"),{icon=.Sun,tip="Preview sunlight",variant="tab",active=sun^,width=26,height=ui.metric(ctx,"control")}).clicked {sun^=!sun^}
    }
}

// A column of a document with a heading and a border on the side it meets the next.
asset_column_begin :: proc(ctx:^ui.Context,width:ui.Size,title:string,note:="") -> bool {
    ui.box_begin(ctx,{width=width,height=ui.GROW,direction=.Column})
    asset_heading(ctx,title,note)
    return true
}
asset_column_end :: proc(ctx:^ui.Context) {ui.box_end(ctx,{})}

// The line between two columns.
asset_column_divider :: proc(ctx:^ui.Context) {
    if ui.box(ctx,{width=ui.fixed(1),height=ui.GROW,fill=ui.tone(ctx,"border")}) {}
}
