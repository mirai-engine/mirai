package editor

import "core:math"
import "mirai:core"
import "mirai:platform"
import "mirai:std/base"
import "mirai:ui"

// The past of the Play of the user under the scene while it is paused: a
// strip over the ticks its history goes to, whose head is the tick it is at.
// Taking the head, or a step, asks to go to a tick; it is done between
// frames (play_history_seek), never inside the loop that draws the strip.
// Its Play plays the past again at the pace of the clock, the game still
// paused; Play from here plays the game on from the head.
PLAY_STRIP_WIDTH :: f32(720)

History_Playback :: struct {
    playing,loop:bool,
    elapsed:f64, // s of the clock not yet turned into ticks
}

// The run whose strip is under the scene: the Play of the user, paused, with
// a past of more than one tick. nil while there is none.
play_strip_run :: proc(s:^Session) -> ^Run {
    if !play_paused(s) || scene_covered(s) {return nil}
    r:=run_find(s,0)
    if r==nil || core.world_storage_of(run_ref(s,r),core.Time)==nil {return nil}
    oldest,newest,_,_,ok:=history_span(r.history)
    return ok && newest>oldest?r:nil
}

// The Play of the strip plays the past or stops; at the end it plays from the start.
play_strip_toggle :: proc(s:^Session,r:^Run) {
    p:=&s.history_playback
    p.playing,p.elapsed=!p.playing,0
    oldest,newest,_,_,_:=history_span(r.history)
    if t:=core.world_storage_of(run_ref(s,r),core.Time);p.playing && t.tick>=newest {s.history_seek=oldest+1}
}

play_history_bar :: proc(s:^Session) {
    r:=play_strip_run(s)
    if r==nil {return}
    oldest,newest,_,_,_:=history_span(r.history)
    t:=core.world_storage_of(run_ref(s,r),core.Time)
    g:=s.gui
    ctx:=g.ctx
    rate:=s.app.tick_dt>0?1/s.app.tick_dt:f32(core.SIMULATION_SETTINGS_DEFAULT.tick_rate)
    // Play resumes from the newest frame; from a frame it went back to, the
    // game can also play on from there, edited or not, without what came after.
    p:=&s.history_playback
    clock:=Timeline_Clock{frame=f32(t.tick-min(t.tick,oldest)),frames=f32(max(newest,t.tick)-oldest),rate=rate,playing=p.playing,loop=p.loop,here=r.history.at<r.history.serial}
    clock.ask=timeline_can_ask(s)
    width:=min(PLAY_STRIP_WIDTH,max(ctx.size.x-2*ui.metric(ctx,"margin"),240))
    if ui.panel(ctx,shell_id(g,"play_history"),{width=ui.fixed(width),height=ui.FIT,anchor=.Bottom_Center,pivot=.Bottom_Center,offset={0,-ui.metric(ctx,"margin")}}) {
        result:=timeline_strip(s,&s.play_strip,clock,nil,shell_id(g,"play_history_strip"))
        if result.seek {
            s.history_seek=oldest+u64(max(math.round(result.frame),0))+1
            p.playing=false
        }
        if result.loop {p.loop=!p.loop}
        if result.play {play_strip_toggle(s,r)}
        if result.here {s.requests+={.Resume_Here}}
        if result.ask || result.copy {
            if range,found:=play_range_of(s,r,&s.play_strip,clock.frames,oldest);found {timeline_range_use(s,result,range)}
        }
    }
}

// The ticks of the range of a strip whose frame 0 is the tick oldest, in the
// run r of the scene open; none while the range is off.
play_range_of :: proc(s:^Session,r:^Run,t:^Timeline,frames:f32,oldest:u64) -> (range:Ai_Range,ok:bool) {
    if !t.range || t.range_out<=t.range_in {return}
    lo,hi:=timeline_range(t,frames)
    if hi<=lo {return}
    range.kind,range.from,range.to,range.run=.Play,oldest+u64(lo),oldest+u64(hi),r.id
    if s.document!=nil {base.text_set(range.path[:],document_path(s.document))}
    return range,true
}

// Goes to the tick the strip asked for, between frames, or plays the past
// on by the ticks the clock went through since the last frame.
play_history_seek :: proc(s:^Session) {
    r:=run_find(s,0)
    p:=&s.history_playback
    if r==nil || !play_paused(s) || r.history==nil {
        p.playing,s.history_seek=false,0
        return
    }
    if p.playing && s.history_seek==0 {
        t:=core.world_storage_of(run_ref(s,r),core.Time)
        oldest,newest,_,_,_:=history_span(r.history)
        tick_dt:=f64(s.app.tick_dt>0?s.app.tick_dt:1.0/f32(core.SIMULATION_SETTINGS_DEFAULT.tick_rate))
        p.elapsed+=f64(platform.input_frame(s.app.platform).dt)
        ticks:=u64(p.elapsed/tick_dt+1e-6) // a frame as long as some ticks makes them all, rounded as f32
        if t==nil || ticks==0 {return}
        p.elapsed-=f64(ticks)*tick_dt
        to:=t.tick+ticks
        if to>=newest {
            to=newest
            if p.loop {to=oldest} else {p.playing=false}
        }
        s.history_seek=to+1
    }
    if s.history_seek==0 {return}
    tick:=s.history_seek-1
    s.history_seek=0
    serial:=history_frame_for(r.history,tick)
    // Forward goes at least to the next tick a frame reached.
    if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil && tick>t.tick {
        if f:=history_frame_of(r.history,serial);f==nil || f.tick<=t.tick {serial=history_frame_after(r.history,t.tick)}
    }
    if serial==0 {return}
    if seek:=history_seek(s,r,serial);!seek.ok {notify(s,"No memory to go back: the game stays where it was")}
}

// The frame a recording draws, over the scene while the viewport looks
// through a camera of the game, as a recording does: what lies outside its
// proportion darkened. Through the camera of the editor it would frame
// nothing a recording sees.
output_frame_draw :: proc(s:^Session) {
    v:=s.viewport
    size:=s.recording!={}?s.recording:v.output_size
    if !v.show_output_frame || size.x<=0 || size.y<=0 {return}
    game:=core.world_storage_of(shown_world(s),core.View)
    if !camera_previewing(s) && (s.mode!=.Play || game==nil || game.camera==core.NONE) {return}
    view:=viewport_rect(v)
    if view.w<=0 || view.h<=0 {return}
    ctx:=s.gui.ctx
    aspect:=f32(size.x)/f32(size.y)
    w,h:=view.w,view.w/aspect
    if h>view.h {h=view.h;w=h*aspect}
    x,y:=view.x+(view.w-w)/2,view.y+(view.h-h)/2
    shade:=ui.tone(ctx,"backdrop")
    ui.draw_rect(ctx,{view.x,view.y,view.w,y-view.y},shade)
    ui.draw_rect(ctx,{view.x,y+h,view.w,view.y+view.h-y-h},shade)
    ui.draw_rect(ctx,{view.x,y,x-view.x,h},shade)
    ui.draw_rect(ctx,{x+w,y,view.x+view.w-x-w,h},shade)
    ui.draw_rect_lines(ctx,{x,y,w,h},1,ui.tone(ctx,"text_muted"))
}
