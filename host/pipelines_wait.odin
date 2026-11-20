package host

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "mirai:platform"
import render "mirai:render"
import "mirai:rhi"
import "mirai:ui"

// What the window shows while the renderer makes the pipelines it starts with,
// which takes minutes when the driver has none of them compiled: the first
// start after an install, or after an update of the game or of the driver.
// No pipeline exists yet, so the screen is a clear and a copy of text painted
// on the CPU into the image of the window; the title says the same.
PIPELINES_WAIT_HEADLINE :: "Compiling shaders %d/%d"
PIPELINES_WAIT_DETAIL :: "%d:%02d elapsed"
PIPELINES_WAIT_SHOWN_NS :: u64(1_000_000_000) // a start that compiles for less says nothing
PIPELINES_WAIT_SIZES :: [2]f32{22,15}         // of the headline and the detail, in points
PIPELINES_WAIT_BAND :: f32(96)                // points of the band the text takes, centered
// sRGB colors of the screen: as bytes they go to the image, which a copy does not convert.
PIPELINES_WAIT_BACKGROUND :: [3]u8{16,17,21}
PIPELINES_WAIT_HEADLINE_COLOR :: [3]u8{236,237,240}
PIPELINES_WAIT_DETAIL_COLOR :: [3]u8{150,154,163}

@(private)
Pipelines_Wait :: struct {
    app:^App,
    started:u64,
    title:[platform.TITLE_CAPACITY]u8, // of the window before, put back once they are made
    title_length:int,
    shown:bool,
    font:ui.Font, // the faces of PIPELINES_WAIT_SIZES at the density of the window
    font_ready:bool,
}

@(private)
pipelines_wait_report :: proc(user:rawptr,made,total:int) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    w:=(^Pipelines_Wait)(user)
    p:=w.app.platform
    if platform.window_wait(p) {
        rhi.device_pipelines_keep(w.app.device)
        fmt.eprintfln("mirai: closed while compiling shaders (%d/%d)",made,total)
        os.exit(0)
    }
    // The costliest are made first, and one takes minutes: the time shows that it goes on.
    seconds:=int((platform.clock_ns()-w.started)/1_000_000_000)
    if !w.shown && platform.clock_ns()-w.started>=PIPELINES_WAIT_SHOWN_NS {
        w.title_length=copy(w.title[:],platform.window_title(p))
        w.shown=true
        sizes:=PIPELINES_WAIT_SIZES
        density:=platform.input_frame(p).window.pixel_density
        w.font_ready=ui.font_init(&w.font,{ui.FONT_INTER},{i32(sizes[0]),i32(sizes[1])},density,w.app.allocator)
        fmt.eprintfln("mirai: "+PIPELINES_WAIT_HEADLINE,made,total)
    }
    if !w.shown {return}
    headline:=fmt.tprintf(PIPELINES_WAIT_HEADLINE,made,total)
    platform.window_set_title(p,headline)
    pipelines_wait_draw(w,headline,fmt.tprintf(PIPELINES_WAIT_DETAIL,seconds/60,seconds%60))
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

@(private)
app_pipeline_wait :: proc(user:rawptr) -> bool {
    app:=(^App)(user)
    if platform.window_wait(app.platform) {app_exit(app,0)}
    return !app.quit
}

// The window back as it was: its title, and the font of the screen gone.
@(private)
pipelines_wait_end :: proc(w:^Pipelines_Wait) {
    if w.shown {platform.window_set_title(w.app.platform,string(w.title[:w.title_length]))}
    if w.font_ready {ui.font_destroy(&w.font)}
    w.shown,w.font_ready=false,false
}

// One frame of the screen: the image of the window cleared to the background
// and the band of the text copied into its middle. A frame the device cannot
// begin (a minimized window) is skipped; a format other than 8-bit RGBA or
// BGRA shows the background alone.
@(private="file")
pipelines_wait_draw :: proc(w:^Pipelines_Wait,headline,detail:string) {
    d:=w.app.device
    p:=w.app.platform
    window:=platform.input_frame(p).window
    if window.minimized || window.pixel_size.x<=0 || window.pixel_size.y<=0 {return}
    rhi.swapchain_resize(d,u32(window.pixel_size.x),u32(window.pixel_size.y))
    cmd,began:=rhi.frame_begin(d)
    if !began {return}
    swap:=rhi.swapchain_texture(d)
    defer {
        submitted:=rhi.frame_end(d,cmd)
        platform.frame_end(p,submitted && swap!=0)
    }
    if swap==0 {return}
    format:=rhi.swapchain_format(d)
    width,height:=rhi.swapchain_size(d)
    srgb:=format==.RGBA8_Srgb || format==.BGRA8_Srgb
    background:=PIPELINES_WAIT_BACKGROUND
    clear:[4]f32
    for c,i in background {clear[i]=pipelines_wait_linear(c) if srgb else f32(c)/255}
    clear[3]=1
    pass:=rhi.Render_Pass_Desc{color_count=1,name="compiling shaders"}
    pass.colors[0]={texture=swap,load=.Clear,store=.Store,clear=clear}
    rhi.cmd_begin_render_pass(cmd,&pass)
    rhi.cmd_end_render_pass(cmd)
    bgra:=format==.BGRA8_Unorm || format==.BGRA8_Srgb
    if !w.font_ready || .Transfer_Dst not_in rhi.texture_desc(d,swap).usage ||
       !bgra && format!=.RGBA8_Unorm && format!=.RGBA8_Srgb {return}
    if w.font.density!=window.pixel_density {ui.font_set_density(&w.font,window.pixel_density)}
    density:=w.font.density
    band:=min(int(PIPELINES_WAIT_BAND*density),int(height))
    columns:=int(width)
    if band<=0 || columns<=0 {return}
    coverage:=make([]u8,columns*band*2,context.temp_allocator)
    if coverage==nil {return}
    sizes:=PIPELINES_WAIT_SIZES
    lines:=[2]string{headline,detail}
    baselines:=[2]f32{f32(band)*0.42,f32(band)*0.78}
    for line,i in lines {
        x:=(f32(columns)-ui.text_width(&w.font,line,sizes[i])*density)*0.5
        ui.text_paint(&w.font,line,sizes[i],coverage[i*columns*band:][:columns*band],columns,band,math.floor(x),math.floor(baselines[i]))
    }
    upload:=rhi.frame_alloc(d,u64(columns*band*4))
    if upload.ptr==nil {return}
    pixels:=([^][4]u8)(upload.ptr)[:columns*band]
    colors:=[2][3]u8{PIPELINES_WAIT_HEADLINE_COLOR,PIPELINES_WAIT_DETAIL_COLOR}
    for &pixel,at in pixels {
        rgb:=background
        for color,i in colors {
            a:=u32(coverage[i*columns*band+at])
            if a==0 {continue}
            for c in 0..<3 {rgb[c]=u8((u32(rgb[c])*(255-a)+u32(color[c])*a+127)/255)}
        }
        pixel=bgra?[4]u8{rgb[2],rgb[1],rgb[0],255}:[4]u8{rgb[0],rgb[1],rgb[2],255}
    }
    top:=(int(height)-band)/2
    rhi.cmd_copy_buffer_to_texture(cmd,upload.buffer,upload.offset,swap,0,{0,u32(top),u32(columns),u32(band)})
}

@(private="file")
pipelines_wait_linear :: proc "contextless" (c:u8) -> f32 {
    v:=f32(c)/255
    return v/12.92 if v<=0.04045 else math.pow((v+0.055)/1.055,2.4)
}
