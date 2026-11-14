package host

import audio "mirai:audio"
import "mirai:core"
import "mirai:platform"
import render "mirai:render"

// What a frame of the game loop gave its world besides its state: how long
// it lasted, the time its fixed ticks came from (Frame_Time.accumulator, once
// the clock and a step moved it) and how many ran, the input its first tick
// and the frame saw and the content it found loaded. Played again over the
// World it found, it runs the same.
Frame_Record :: struct {
    dt:f64,
    accumulator:f64,
    lag:f64, // Frame_Time.lag once its ticks were decided
    ticks:int,
    input:core.Input,
    frame_input:core.Input,
    content:u32, // Content.generations when it began: a first load a job made after is pending
}

// A recording of a world: frame after frame drawn alone through the camera of
// its View into an image of its own size, with the histories of the view kept
// between frames, and each image read back wide (render.View_Wide); the
// mixer, taken from the audio device, renders what the frames make heard.
World_Recording :: struct {
    texture:render.Texture_Handle,
    size:[2]i32,
    wide:render.View_Wide,
    frames:int,      // drawn
    mixed:u64,       // frames of audio rendered
    device_paused:bool, // the device was paused before the recording took the mixer
    mixing:bool,     // the recording renders the mixer
}

// Starts a recording at size pixels. With audio the mixer of the application
// is rendered only by app_recording_mix until the end: the audio device stops
// asking for it. A load transaction between frames; false without a
// renderer, for a size the renderer does not take, or without memory.
app_recording_begin :: proc(app:^App,rec:^World_Recording,size:[2]i32,wide:render.View_Wide,audio_:bool) -> bool {
    rec^={size=size,wide=wide}
    if app.renderer==nil || size.x<=0 || size.y<=0 || wide==.None {return false}
    texture,made:=render.view_texture_add(app.renderer,u32(size.x),u32(size.y),"recording")
    if !made {return false}
    rec.texture=texture
    if audio_ && app.mixer!=nil {
        if app.platform!=nil && platform.audio_device_is_open(app.platform) {
            rec.device_paused=platform.audio_device_paused(app.platform)
            // Paused, the device leaves the mixer alone: this thread renders it.
            if !rec.device_paused && !platform.audio_device_set_paused(app.platform,true) {
                render.view_texture_remove(app.renderer,texture)
                rec^={}
                return false
            }
        }
        rec.mixing=true
    }
    return true
}

// Draws the next frame of the recording from the render phase of the game of
// world and reads it into out (RGBA 32-bit float, size.x*size.y*4, rows from
// the top). The first frame starts the histories of the view. Between frames.
app_recording_frame :: proc(app:^App,rec:^World_Recording,world:rawptr,out:[]f32) -> bool {
    r:=app.renderer
    if r==nil || world==nil || rec.texture==0 {return false}
    ui_only:=app.ui_only
    app.ui_only=false
    defer app.ui_only=ui_only
    run_phase(app,.Game,.Render,{.Render},world,nil)
    cut:=rec.frames==0
    extras:=&app.extras
    seen:=[1]render.Frame_View{{camera=app.camera,camera_cut=cut,rect={0,0,rec.size.x,rec.size.y},texture=rec.texture,inspection=app.inspection,wide=rec.wide}}
    drawn:=render.renderer_frame(r,{
        camera=app.camera,camera_cut=cut,inspection=app.inspection,time=app.time,views=seen[:],
        ui_textures=extras.ui_textures[:extras.ui_texture_count],effect_views=extras.effect_views[:extras.effect_view_count],
        offscreen=true,
    })
    extras.layer_count,extras.panel_count,extras.debug_count=0,0,0
    clear(&extras.instances)
    extras.ui_texture_count,extras.effect_view_count,extras.probe_count=0,0,0
    app.camera_cut=false
    app.inspection={}
    app.view_count=0
    if !drawn {return false}
    rec.frames+=1
    return render.view_texture_wide(r,rec.texture,out)
}

// Renders the next frames of audio of the recording into out, interleaved
// at the channels of the mixer, and lets the mixer free what ended. Silence
// without a mixer.
app_recording_mix :: proc(app:^App,rec:^World_Recording,out:[]f32) {
    if !rec.mixing {
        for &sample in out {sample=0}
        return
    }
    // Faster than real time: what plays from feeds is decoded here, not left to the decoder thread.
    audio.mixer_decode(app.mixer)
    audio.mixer_render(app.mixer,out)
    audio.mixer_update(app.mixer)
    rec.mixed+=u64(len(out)/app.mixer.channels)
}

// Ends a recording: the device plays the mixer again as before, and the next
// frame shown starts a new history.
app_recording_end :: proc(app:^App,rec:^World_Recording) {
    if rec.texture!=0 && app.renderer!=nil {
        render.view_texture_remove(app.renderer,rec.texture)
        render.renderer_camera_cut(app.renderer)
    }
    if rec.mixing && app.platform!=nil && platform.audio_device_is_open(app.platform) && !rec.device_paused {
        platform.audio_device_set_paused(app.platform,false)
    }
    rec^={}
}

// Sample rate and channels of what app_recording_mix renders.
app_recording_audio :: proc(app:^App,rec:^World_Recording) -> (rate,channels:int) {
    if !rec.mixing {return 48000,2}
    return app.mixer.sample_rate,app.mixer.channels
}
