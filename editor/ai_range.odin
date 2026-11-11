package editor

import "core:fmt"
import "core:math"
import "core:strings"
import "mirai:platform"
import "mirai:std/base"
import "mirai:ui"

// The stretch of time the next message is about, chosen on a timeline: ticks
// of the paused Play of the user, frames of an asset that plays or ticks of the
// clip of an entity of the scene. A chip over the composer and, when it is sent, a
// line of the instructions of the turn. Copy range and the turn say the same,
// never a path outside the project.

Ai_Range_Kind :: enum u8 {Play,Asset,Clip}

AI_RANGE_NAME :: 64

Ai_Range :: struct {
    kind:Ai_Range_Kind,
    from,to:u64,              // ticks of a Play or a clip of the scene, frames of an asset; to<=from: none
    run:u64,                  // Run.id of a Play
    rate:f32,                 // frames per second of an asset
    path:[AI_PATH_BYTES]u8,   // the scene, or the asset; in the project, empty for one never saved
    name:[AI_RANGE_NAME]u8,   // the clip of an asset, or the entity that plays the clip of the scene
}

// What context.json says of the range.
Ai_Context_Range :: struct {
    kind:string,
    from,to,run:u64,
    rate:f32,
    path,name:string,
}

ai_context_range :: proc(r:^Ai_Range) -> Ai_Context_Range {
    if r.to<=r.from {return {}}
    kind:=[Ai_Range_Kind]string{.Play="play",.Asset="asset",.Clip="clip"}
    return {kind[r.kind],r.from,r.to,r.run,r.rate,base.text_get(r.path[:]),base.text_get(r.name[:])}
}

// What Copy range puts on the clipboard, for a chat in the editor or out of it.
ai_range_text :: proc(r:^Ai_Range) -> string {
    path:=base.text_get(r.path[:])
    if path=="" {path="no file"}
    name:=base.text_get(r.name[:])
    switch r.kind {
    case .Asset:
        text:=fmt.tprintf("Range: frames %d to %d at %g fps\nAsset: %s",r.from,r.to,r.rate,path)
        return name!=""?fmt.tprintf("%s\nClip: %s",text,name):text
    case .Clip:
        return fmt.tprintf("Range: ticks %d to %d\nClip of: %s\nScene: %s",r.from,r.to,name,path)
    case .Play:
    }
    return fmt.tprintf("Range: ticks %d to %d\nRun: %d\nScene: %s",r.from,r.to,r.run,path)
}

ai_range_set :: proc(s:^Session,r:Ai_Range) {
    m:=s.ai
    if m==nil || r.to<=r.from {return}
    m.range=r
    m.focus=true
}

// What the strip of a document asked of the range it describes: the chat
// of the agent with the range, or the clipboard.
timeline_range_use :: proc(s:^Session,asked:Timeline_Result,r:Ai_Range) {
    if r.to<=r.from {return}
    if asked.ask {
        ai_ask(s)
        ai_range_set(s,r)
    }
    if asked.copy {
        range:=r
        if s.app==nil || s.app.platform==nil {return}
        if !platform.clipboard_set(s.app.platform,ai_range_text(&range)) {
            notify(s,"The range does not fit in the clipboard")
            return
        }
        notify(s,fmt.tprintf("Copied %s %d to %d",r.kind==.Asset?"frames":"ticks",r.from,r.to))
    }
}

// Whether a strip can describe its range: the agent of the editor in a project.
timeline_can_ask :: proc(s:^Session) -> bool {return s.ai!=nil && s.has_project}

@(private)
ai_range_rows :: proc(m:^Ai) -> int {return m!=nil && m.range.to>m.range.from?1:0}

@(private)
ai_range_build :: proc(s:^Session,width:f32,rows:int) {
    m:=s.ai
    if rows<=0 || ai_range_rows(m)==0 {return}
    ctx:=s.gui.ctx
    buffer:[64]u8
    label:=fmt.bprintf(buffer[:],"%s %d to %d",m.range.kind==.Asset?"Frames":"Ticks",m.range.from,m.range.to)
    size:=min(width,math.ceil(ui.text_width(&ctx.font,label,ui.metric(ctx,"font_small")))+AI_CHIP_ROOM)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_CHIP_HEIGHT),gap=5,align_y=.Center}) {
        chip:=ui.Box{width=ui.fixed(size),height=ui.fixed(AI_CHIP_HEIGHT),padding={5,0,5,0},gap=4,
            align_y=.Center,fill=ui.tone(ctx,"field"),radius=ui.metric(ctx,"radius_control")}
        if ui.box(ctx,chip) {
            ui.icon(ctx,timeline_icon(.Range),ui.tone(ctx,"text_muted"),12)
            ui.label(ctx,label,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),size-40)
            remove:=ui.Button{icon=.Cross,icon_color=ui.tone(ctx,"text_muted"),icon_size=10,padding=-1,
                variant="ghost",width=12,height=12}
            if ui.button(ctx,ui.id(ctx,"remove_range"),remove).clicked {m.range={}}
        }
    }
}

// The line of the instructions that names them.
@(private)
ai_range_prompt :: proc(task:^Ai_Task,b:^strings.Builder) {
    r:=&task.range
    if r.to<=r.from {return}
    path:=base.text_get(r.path[:])
    name:=base.text_get(r.name[:])
    switch r.kind {
    case .Play:
        fmt.sbprintf(b,"- The user chose ticks %d to %d of run %d, a Play of %s, on its timeline: "+
            "this message is about them. `play.history` with `run` %d, `from` %d and `to` %d reads "+
            "them, also after the user stopped that Play: with `trace`, values of entities at those "+
            "ticks; with `verify`, whether playing them again repeats them.\n",
            r.from,r.to,r.run,path!=""?path:"a scene without a file",r.run,r.from,r.to)
    case .Asset:
        rate:=r.rate>0?r.rate:1
        fmt.sbprintf(b,"- The user chose frames %d to %d (%.2f s to %.2f s) of %s%s%s on its "+
            "timeline: this message is about them.\n",r.from,r.to,f32(r.from)/rate,f32(r.to)/rate,
            path,name!=""?", clip ":"",name)
    case .Clip:
        fmt.sbprintf(b,"- The user chose ticks %d to %d of the clip of %s in %s on its "+
            "timeline: this message is about them.\n",r.from,r.to,name,
            path!=""?path:"a scene without a file")
    }
}
