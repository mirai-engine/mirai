package host

import "base:runtime"
import "core:fmt"
import "core:os"
import "mirai:platform"
import "mirai:project"
import render "mirai:render"
import "mirai:rhi"
import "mirai:ui"

// What the window shows while the renderer makes the pipelines it starts with,
// which takes minutes when the driver has none of them compiled: the first
// start after an install, or after an update of the game or of the driver.
// A UI context of its own, drawn with the pipeline of the UI the renderer
// makes before the others (render.renderer_startup_frame): how many are made,
// the time it takes and Cancel, under the bar of a custom chrome with the
// buttons of the window. The title says the same. Cancel, Escape and closing
// the window write what is made and end the application.
PIPELINES_WAIT_HEADLINE :: "Compiling shaders %d/%d"
PIPELINES_WAIT_DETAIL :: "%d:%02d elapsed"
PIPELINES_WAIT_SHOWN_NS :: u64(1_000_000_000) // a start that compiles for less says nothing
PIPELINES_LOG_NS :: u64(2_000_000_000)        // the least between two lines of pipelines_log_report
PIPELINES_WAIT_SIZES :: [2]f32{22,15}         // of the headline and the detail, in points
PIPELINES_WAIT_BAR :: f32(36)                 // points of the bar of a custom chrome
PIPELINES_WAIT_CONTROL :: f32(46)             // width of a button of the window on the bar
PIPELINES_WAIT_CANCEL :: [2]f32{96,30}        // size of Cancel
PIPELINES_WAIT_BACKGROUND :: ui.Color{16,17,21,255}
PIPELINES_WAIT_HEADLINE_COLOR :: ui.Color{236,237,240,255}
PIPELINES_WAIT_DETAIL_COLOR :: ui.Color{150,154,163,255}
PIPELINES_WAIT_BUTTON :: ui.Color{38,40,46,255}
PIPELINES_WAIT_HOVER :: ui.Color{54,57,65,255}
PIPELINES_WAIT_CLOSE_HOVER :: ui.Color{196,43,28,255}

@(private)
Pipelines_Wait :: struct {
    app:^App,
    started:u64,
    chrome:platform.Window_Chrome,
    cancel:proc(user:rawptr), // App_Desc.on_pipelines_cancel
    cancel_user:rawptr,
    title:[platform.TITLE_CAPACITY]u8, // of the window before, put back once they are made
    title_length:int,
    shown:bool,
    ctx:^ui.Context,
    logged:int,     // made when pipelines_log_report last wrote
    logged_at:u64,  // and when
}

// Without a window, stderr says how many are made (project.PIPELINES_PROGRESS)
// once they take PIPELINES_WAIT_SHOWN_NS, and again while the count rises.
@(private)
pipelines_log_report :: proc(user:rawptr,made,total:int) {
    w:=(^Pipelines_Wait)(user)
    now:=platform.clock_ns()
    if now-w.started<PIPELINES_WAIT_SHOWN_NS || w.logged_at!=0 && (made==w.logged || now-w.logged_at<PIPELINES_LOG_NS) {return}
    w.logged,w.logged_at=made,now
    fmt.eprintfln(project.PIPELINES_PROGRESS+"%d/%d",made,total)
}

@(private)
pipelines_wait_report :: proc(user:rawptr,made,total:int) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    w:=(^Pipelines_Wait)(user)
    p:=w.app.platform
    if !w.shown {
        if platform.window_wait(p) {pipelines_wait_quit(w,made,total,false)}
        if platform.clock_ns()-w.started<PIPELINES_WAIT_SHOWN_NS {return}
        w.title_length=copy(w.title[:],platform.window_title(p))
        w.shown=true
        w.ctx=app_ui_context_create(w.app)
        fmt.eprintfln("mirai: "+PIPELINES_WAIT_HEADLINE,made,total)
    }
    platform.frame_begin(p)
    frame:=platform.input_frame(p)
    if frame.window.close_requested {pipelines_wait_quit(w,made,total,false)}
    // The costliest are made first, and one takes minutes: the time shows that it goes on.
    seconds:=int((platform.clock_ns()-w.started)/1_000_000_000)
    headline:=fmt.tprintf(PIPELINES_WAIT_HEADLINE,made,total)
    platform.window_set_title(p,headline)
    cancel,close,presented:=pipelines_wait_draw(w,frame,headline,fmt.tprintf(PIPELINES_WAIT_DETAIL,seconds/60,seconds%60))
    platform.frame_end(p,presented)
    if cancel || close {pipelines_wait_quit(w,made,total,cancel)}
}

// The pipelines made are written, so the next start goes on from them, and
// the process ends at once: the threads that make the others are inside the
// driver, which a quit would wait for for minutes.
@(private="file")
pipelines_wait_quit :: proc(w:^Pipelines_Wait,made,total:int,cancelled:bool) -> ! {
    rhi.device_pipelines_keep(w.app.device)
    fmt.eprintfln("mirai: %s while compiling shaders (%d/%d): those compiled are kept for the next start","cancelled" if cancelled else "closed",made,total)
    if cancelled && w.cancel!=nil {w.cancel(w.cancel_user)}
    os.exit(0)
}

// Called last before app_destroy, once what the application keeps is written
// (its worlds, documents and sessions closed): when the renderer is inside the
// driver making a pipeline, which a quit would wait for for minutes, the kept
// pipelines are written and the process ends at once with code, as for a
// window closed while the renderer starts. Else it returns, and app_destroy
// ends the application as always.
app_quit_compiling :: proc(app:^App,code:int) {
    if app==nil || !render.renderer_pipelines_stop(app.renderer) {return}
    rhi.device_pipelines_keep(app.device)
    fmt.eprintln("mirai: quit while a shader compiles: it is left to the next start")
    os.exit(code)
}

// The window back as it was: its title and regions, and the context of the screen gone.
@(private)
pipelines_wait_end :: proc(w:^Pipelines_Wait) {
    if w.shown {
        platform.window_set_title(w.app.platform,string(w.title[:w.title_length]))
        platform.window_set_regions(w.app.platform,nil)
    }
    app_ui_context_destroy(w.app,w.ctx)
    w.shown,w.ctx=false,nil
}

// One frame of the screen; cancel: Cancel or Escape, close: the button of
// the window that closes it. Without its context
// (no memory for it) the window shows nothing, and closing it still ends.
@(private="file")
pipelines_wait_draw :: proc(w:^Pipelines_Wait,frame:^platform.Input_Frame,headline,detail:string) -> (cancel,close,presented:bool) {
    ctx:=w.ctx
    p:=w.app.platform
    window:=frame.window
    if ctx==nil || window.minimized || window.pixel_size.x<=0 || window.pixel_size.y<=0 {return}
    input:=ui_input_from_platform(frame)
    ui.frame_begin(ctx,input)
    custom:=w.chrome==.Custom
    controls:=custom && platform.WINDOW_CONTROLS==.Right
    if ui.box(ctx,{width=ui.GROW,height=ui.GROW,direction=.Column,fill=PIPELINES_WAIT_BACKGROUND}) {
        if custom {close=pipelines_wait_bar(ctx,p,window,controls)}
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW,direction=.Column,align_x=.Center,align_y=.Center,gap=6}) {
            sizes:=PIPELINES_WAIT_SIZES
            ui.label(ctx,headline,sizes[0],PIPELINES_WAIT_HEADLINE_COLOR)
            ui.label(ctx,detail,sizes[1],PIPELINES_WAIT_DETAIL_COLOR)
            ui.spacer(ctx,0,18)
            id:=ui.id(ctx,"pipelines_wait_cancel")
            look:=ui.Node_Style{text={size=14,color=PIPELINES_WAIT_HEADLINE_COLOR},fill=PIPELINES_WAIT_HOVER if ctx.hot==id else PIPELINES_WAIT_BUTTON,radius={6,6,6,6}}
            button:=PIPELINES_WAIT_CANCEL
            cancel=ui.button(ctx,id,{label="Cancel",look=&look,width=button.x,height=button.y,center=true}).clicked
        }
    }
    cancel||=.Escape in input.keys_pressed
    result:=ui.frame_end(ctx)
    if custom {
        regions:[4]platform.Window_Region
        regions[0]={rect={0,0,input.size.x,PIPELINES_WAIT_BAR},kind=.Drag}
        count:=1
        if controls {
            for i in 0..<3 {
                x:=input.size.x-f32(3-i)*PIPELINES_WAIT_CONTROL
                regions[count]={rect={x,0,PIPELINES_WAIT_CONTROL,PIPELINES_WAIT_BAR},kind=.Control}
                count+=1
            }
        }
        platform.window_set_regions(p,regions[:count],!window.maximized && !window.fullscreen)
    }
    if !app_ui_font_sync(w.app,ctx) {return}
    draws:[UI_COMMAND_CAPACITY]render.Ui_Draw
    layer,_,_,_:=ui_frame_convert(result,draws[:],nil)
    layers:=[1]render.Ui_Layer{layer}
    background:=PIPELINES_WAIT_BACKGROUND
    clear:=render.Vec4{f32(background[0])/255,f32(background[1])/255,f32(background[2])/255,1}
    presented=render.renderer_startup_frame(w.app.renderer,layers[:],u32(window.pixel_size.x),u32(window.pixel_size.y),input.size,clear)
    return
}

// The bar of a custom chrome: where it is dragged from and, where the
// window draws its own, its buttons. close: the one that closes it.
@(private="file")
pipelines_wait_bar :: proc(ctx:^ui.Context,p:^platform.Platform,window:platform.Window_Frame,controls:bool) -> (close:bool) {
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(PIPELINES_WAIT_BAR),direction=.Row}) {
        ui.spacer(ctx)
        for i in 0..<3 {
            if !controls {break}
            id:=ui.id(ctx,"pipelines_wait_control",i)
            it:=ui.interact(ctx,id)
            hover:=PIPELINES_WAIT_CLOSE_HOVER if i==2 else PIPELINES_WAIT_HOVER
            if ui.box(ctx,{id=id,width=ui.fixed(PIPELINES_WAIT_CONTROL),height=ui.GROW,align_x=.Center,align_y=.Center,fill=hover if it.hot else {}}) {
                switch i {
                case 0: ui.box(ctx,{width=ui.fixed(10),height=ui.fixed(1),fill=PIPELINES_WAIT_HEADLINE_COLOR})
                case 1: ui.box(ctx,{width=ui.fixed(10),height=ui.fixed(10),stroke=PIPELINES_WAIT_HEADLINE_COLOR,stroke_width=1})
                case 2: ui.icon(ctx,.Cross,PIPELINES_WAIT_HEADLINE_COLOR,16)
                }
            }
            if !it.clicked {continue}
            switch i {
            case 0: platform.window_minimize(p)
            case 1: platform.window_set_maximized(p,!window.maximized)
            case 2: close=true
            }
        }
    }
    return
}
