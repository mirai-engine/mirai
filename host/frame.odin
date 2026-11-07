package host

import "core:c"
import "core:log"
import "core:path/filepath"
import "core:strings"
import "core:time"
import audio "mirai:audio"
import "mirai:core"
import "mirai:platform"
import render "mirai:render"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:ui"
import stbi "vendor:stb/image"

// A frame of the application:
//
//   app_frame_begin          platform events, resize, watches of assets and shaders
//   app_game_frame           the game loop of a world: input, fixed ticks, frame, late, ui, render
//   app_editor_frame         the editor loop of a world and the Editor_World
//   app_frame_end            mixer, the draw of the frame, pacing
//
// app_frame does the three for the player's world. What libraries add to a
// frame (layers, panels, lines, the camera) lasts for that frame.

FRAME_LAYER_CAPACITY :: 16
FRAME_PANEL_CAPACITY :: 512
FRAME_DEBUG_CAPACITY :: 8
// Room made once for the instances of a frame; there may be more, and the list grows.
FRAME_INSTANCE_RESERVE :: 256
FRAME_UI_TEXTURE_CAPACITY :: 32
FRAME_EFFECT_VIEW_CAPACITY :: 16
FRAME_SLOT_TEXTURE_CAPACITY :: 32
TEXTURE_VIEW_CAPACITY :: 8
PIPELINE_CACHE_FILE :: "pipelines.bin"

CAMERA_DEFAULT :: render.Camera{position={0,2,6},forward={0,-1,-6},up={0,1,0},fov_y=60,near=0.1}

ALL_PHASES :: core.Phases{.Input,.Fixed,.Frame,.Late,.Ui,.Render}

@(private)
Frame_Extras :: struct {
    layers:[FRAME_LAYER_CAPACITY]render.Ui_Layer,
    layer_count:int,
    panels:[FRAME_PANEL_CAPACITY]render.World_Panel,
    panel_count:int,
    debug:[FRAME_DEBUG_CAPACITY]render.Debug_Lines,
    debug_count:int,
    instances:[dynamic]render.Instance_Desc, // no limit: every animated actor may add skinned copies
    ui_textures:[FRAME_UI_TEXTURE_CAPACITY]render.Ui_Texture_Draw,
    ui_texture_count:int,
    effect_views:[FRAME_EFFECT_VIEW_CAPACITY]render.Effect_View,
    effect_view_count:int,
    probes:[render.DEPTH_PROBE_CAPACITY]render.Depth_Probe,
    probe_count:int,
    slot_textures:[FRAME_SLOT_TEXTURE_CAPACITY]Slot_Texture,
    slot_texture_count:int,
}

// A texture a slot of the mesh of an entity shows this frame over its
// material: as its base color, or as its light. Whatever draws the entity
// shows it: its mesh of the world, or what replaces it
// (render.Instance_Desc.replace_source), as a skinned copy.
Slot_Texture :: struct {
    object:u64, // render.Instance_Desc.object_id
    slot:u32,
    texture:render.Texture_Handle,
    emission:f32, // the light it gives, as Material_Info.emission; 0: it is the base color
}

// What drew the mesh of a Slot_Texture in the last frame, and where: the mesh
// the renderer posed, if one replaced that of the world.
Slot_Shown :: struct {
    object:u64,
    mesh:render.Mesh_Handle,
    anchor:[3]f32,
    transform:render.Mat4, // relative to anchor
}

// The atlas the renderer holds: that of the font all the UI contexts of the
// application borrow, at a revision.
@(private)
Font_Key :: struct {
    revision:u32,
    valid:bool,
}

@(private)
app_gpu_create :: proc(app:^App,desc:App_Desc) -> App_Error {
    p:=app.platform
    source:=platform.surface_source(p)
    app.density=platform.input_frame(p).window.density
    app.pixel_density=platform.input_frame(p).window.pixel_density
    app.drawable={i32(max(source.width,1)),i32(max(source.height,1))}
    // Compiled once, the pipelines of a project are read back from its user
    // folder: building them all again takes the GPU driver many seconds.
    pipelines:string
    if folder:=app_user_folder(app.root,context.temp_allocator);folder!="" {pipelines,_=filepath.join({folder,PIPELINE_CACHE_FILE},context.temp_allocator)}
    device,device_error:=rhi.device_create({
        app_name="Mirai",validation=desc.gpu_validation,allow_hardware_ray_tracing=true,
        vulkan_instance_extensions=platform.vulkan_instance_extensions(p),
        upload_bytes_per_frame=32<<20,allocator=app.allocator,
        on_message=desc.gpu_message!=nil?desc.gpu_message:rhi.message_print,
        loader_lock=desc.gpu_loader_lock,
        pipeline_cache_path=pipelines,
    })
    if device==nil {
        log.errorf("GPU device: %s",device_error)
        return .Device_Failed
    }
    app.device=device
    if desc.window {
        surface:=rhi.Surface_Desc{
            vulkan_create=source.vulkan_create,vulkan_user=source.vulkan_user,metal_layer=source.metal_layer,
            width=u32(app.drawable.x),height=u32(app.drawable.y),vsync=desc.vsync,
        }
        if !rhi.swapchain_create(device,surface) {
            log.errorf("swapchain: %s",rhi.device_error(device))
            return .Device_Failed
        }
    }
    renderer,allocation_error:=new(render.Renderer,app.allocator)
    if allocation_error!=nil {return .Out_Of_Memory}
    app.renderer=renderer
    generation:render.Shader_Assets
    shaders:=app_shaders_open(app,desc,&generation)
    if !render.renderer_init(renderer,{
        device=device,width=u32(app.drawable.x),height=u32(app.drawable.y),
        settings=desc.render_settings,allocator=app.allocator,shaders=shaders,
        // The pages of streamed meshes decode in the jobs of the app, from this thread, its owner.
        jobs=&app.jobs if jobs.worker_count(&app.jobs)>0 else nil,
        // A window or a surface shows each frame to someone, who would see one
        // wait for the driver; without them, what a frame draws does not depend on that time.
        pipeline_thread=desc.window || desc.shown,
    }) {
        log.errorf("renderer: %s",renderer.error)
        return .Renderer_Failed
    }
    render.renderer_resize(renderer,u32(app.drawable.x),u32(app.drawable.y),app.density,app.pixel_density)
    app.camera=CAMERA_DEFAULT
    return .None
}

@(private)
app_gpu_destroy :: proc(app:^App) {
    app_shaders_close(app)
    if app.renderer!=nil {
        if app.renderer.device!=nil {render.renderer_destroy(app.renderer)}
        free(app.renderer,app.allocator)
        app.renderer=nil
    }
    if app.device!=nil {
        rhi.device_destroy(app.device)
        app.device=nil
    }
}

// Ends the player at the end of this frame with code as its exit status; the
// first library that asks decides it.
app_exit :: proc(app:^App,code:int) {
    if app.quit {return}
    app.quit,app.exit_code=true,code
}

// The player's frame, with the phases of the game loop it runs. False once
// the application was asked to end.
app_frame :: proc(app:^App,phases:=ALL_PHASES) -> bool {
    if !app_frame_begin(app) {
        profile_frame_close(app)
        return false
    }
    if app.world!=nil {app_game_frame(app,app.world,phases)}
    app_frame_end(app)
    return !app.quit
}

// Events of the platform and what follows the window. False once the application was asked to end.
app_frame_begin :: proc(app:^App) -> bool {
    profile_frame_open(app)
    started:=time.tick_now()
    app.stats.platform_ms=0
    zone:=profile_part(app,"platform")
    platform.frame_begin(app.platform)
    frame:=platform.input_frame(app.platform)
    app.seconds+=f64(frame.dt)
    polled:=time.tick_now()
    app.stats.platform_ms=f32(time.duration_milliseconds(time.tick_diff(started,polled)))
    base.profile_end(zone)
    zone=profile_part(app,"watch")
    defer base.profile_end(zone)
    app_resize(app,frame.window)
    app_assets_watch(app,frame.dt)
    app_assets_mark(app)
    app_textures_stream(app)
    app_assets_releases_step(app)
    app_content_adopt(app)
    app_ui_fonts_apply(app)
    // The faces the contexts asked for, between their frames: text at those sizes is drawn sharp.
    if app.ui_font.ready {_=ui.font_faces_add(&app.ui_font)}
    app_shaders_watch(app)
    app.ui_input=ui_input_from_platform(frame)
    ui_input_camera(&app.ui_input,app.camera,app_scene_points(app))
    app.played_count=0
    app.stats.watch_ms=f32(time.duration_milliseconds(time.tick_since(polled)))
    if frame.window.close_requested {app.quit=true}
    return !app.quit
}

// The loop of the game for one world: its input phase, the fixed ticks that
// the time of the frame completes, and the phases of the frame. The time of
// the frame counts faster or slower by Frame_Time.dilation and by the
// core.Clock the game asked for (none while paused); step runs one
// tick whatever the frame lasted, for a world that advances only when asked;
// a dt of zero or more is how long the frame lasts instead of what the
// platform measured, for a world recorded at a fixed rate. record keeps what
// the frame gave the world; replay gives it what a recorded frame did, in
// place of the platform and the clock, with the content it had loaded, and
// the frame runs the same again.
// The editor leaves Render out of a world it also runs its own loop on.
app_game_frame :: proc(app:^App,world:rawptr,phases:=ALL_PHASES,step:=false,dt:=f64(-1),record:^Frame_Record=nil,replay:^Frame_Record=nil) {
    started:=time.tick_now()
    defer app.stats.game_ms=f32(time.duration_milliseconds(time.tick_since(started)))
    zone:=profile_part(app,"game")
    defer base.profile_end(zone)
    loop:=core.Loop.Game
    frame:=platform.input_frame(app.platform)
    ref:=app_world_ref(app,world)
    t,f:=core.world_storage_of(ref,core.Time),core.world_storage_of(ref,core.Frame_Time)
    if t==nil || f==nil {return}
    if frame.events_dropped>0 || frame.text_dropped>0 {
        core.report(app_world_storage(app,world,core.Problems),core.NONE,"input.events","%d input events and %d characters of text of a frame were lost: more arrived in one frame than the platform lists (Platform_Desc.event_capacity, 256 by default, and %d characters); the keys and the mouse kept their state. Raise event_capacity, or inject fewer events in one frame",frame.events_dropped,frame.text_dropped,platform.TEXT_CAPACITY)
    }
    speed:=max(1+f64(f.dilation),0)
    if clock:=core.world_storage_of(ref,core.Clock);clock!=nil {speed=clock.paused?0:speed*f64(clock.scale)}
    lasted:=dt>=0?dt:f64(frame.dt)
    if replay!=nil {
        lasted=replay.dt
        f.accumulator=replay.accumulator
    } else if step {f.accumulator=f64(app.tick_dt)} else {f.accumulator+=lasted*speed}
    due:=int(f.accumulator/f64(app.tick_dt))
    if due>app.max_ticks {
        app.stats.ticks_dropped+=u64(due-app.max_ticks)
        f.accumulator-=f64(due-app.max_ticks)*f64(app.tick_dt)
        due=app.max_ticks
    }
    if c:=app.content;c!=nil && replay!=nil {c.replay=replay.content}
    defer if c:=app.content;c!=nil {c.replay=nil}
    if record!=nil {
        record.dt,record.accumulator=lasted,f.accumulator
        record.content=content_generation(app)
    }
    tick_input:core.Input
    devices:=app.script_devices
    app.script_devices=false
    if input:=core.world_storage_of(ref,core.Frame_Input);input!=nil {
        if replay!=nil {input.input=replay.frame_input} else {
            input.input=input_from_platform(frame^)
            if app.game_input_blocked {input.input={mouse_position=input.mouse_position,pressure=1}}
            core.input_join(&input.input,app.script_frame_input)
            if devices {input_devices_take(&input.input,app.script_frame_input)}
            input.keys_down-=app.game_input_excluded
            input.keys_pressed-=app.game_input_excluded
            input.keys_released-=app.game_input_excluded
        }
        if record!=nil {record.frame_input=input.input}
    }
    if replay==nil {app.script_frame_input={}}
    if due>0 && replay==nil {
        tick_input=input_from_platform(platform.input_tick_take(app.platform))
        if app.game_input_blocked {tick_input={mouse_position=tick_input.mouse_position,pressure=1}}
        if app.has_script_input {
            core.input_join(&tick_input,app.script_input)
            if devices {input_devices_take(&tick_input,app.script_input)}
            app.has_script_input=false
        }
    }
    input:=core.world_storage_of(ref,core.Input)
    // The input phase sees the input of the first tick of the frame; a frame without ticks keeps what is held, without its edges.
    if input!=nil && replay!=nil {input^=replay.input} else if input!=nil {
        if due>0 {input^=tick_input} else if app.game_input_blocked {input^={mouse_position=input.mouse_position,pressure=1}} else {input_settle(input)}
        input.keys_down-=app.game_input_excluded
        input.keys_pressed-=app.game_input_excluded
        input.keys_released-=app.game_input_excluded
        input.window_size={f32(frame.window.size.x),f32(frame.window.size.y)}
    }
    if record!=nil && input!=nil {record.input=input^}
    t.playing,f.dt=true,f32(lasted)
    if app.played_count<len(app.played) {app.played[app.played_count]={world,phases};app.played_count+=1}
    run_phase(app,loop,.Input,phases,world,nil)
    for tick in 0..<due {
        if input!=nil && tick>0 {input_settle(input)}
        t.dt=app.tick_dt
        run_phase(app,loop,.Fixed,phases,world,nil)
        f.accumulator-=f64(app.tick_dt)
        core.time_advance(t)
        app.stats.ticks+=1
    }
    f.alpha=f32(f.accumulator/f64(app.tick_dt))
    for phase in ([4]core.Phase{.Frame,.Late,.Ui,.Render}) {run_phase(app,loop,phase,phases,world,nil)}
}

// A fixed tick of a world that already ran, again, from inside the phase that
// runs: a correction of the network replays the ticks after an older copy.
// content is the generation the tick saw when it ran (content_generation): it
// finds pending a first load a job made after, as a frame played again does.
// The clock advances as after any tick and the frame goes on in its phase.
app_tick_replay :: proc(app:^App,world:rawptr,content:u32) {
    seen:Maybe(u32)
    if c:=app.content;c!=nil {seen,c.replay=c.replay,content}
    defer if c:=app.content;c!=nil {c.replay=seen}
    ref:=app_world_ref(app,world)
    f,t:=core.world_storage_of(ref,core.Frame_Time),core.world_storage_of(ref,core.Time)
    // A problem the tick reports again does not count again.
    problems:=app_world_storage(app,world,core.Problems)
    if problems!=nil {problems.resimulating=t!=nil && t.resimulating}
    running:=f!=nil?f.phase:core.Phase.Fixed
    run_phase(app,.Game,.Fixed,ALL_PHASES,world,nil)
    if problems!=nil {problems.resimulating=false}
    if f!=nil {f.phase=running}
    if t!=nil {core.time_advance(t)}
}

// The loop of the editor for one world: every phase once, the fixed one with
// dt 0. A world the game loop also runs (played) keeps its time and its
// input, and its fixed phase is the game's alone.
app_editor_frame :: proc(app:^App,world,editor:rawptr,played:=false) {
    started:=time.tick_now()
    defer app.stats.editor_ms=f32(time.duration_milliseconds(time.tick_since(started)))
    zone:=profile_part(app,"editor")
    defer base.profile_end(zone)
    loop:=core.Loop.Editor
    if played {
        // A function of both loops already ran in the phases the game ran this frame: again, it
        // would see its own work as a change (a source that moved by nothing) and the frame would
        // not repeat when the game replays its record. Render is the editor's alone.
        ran:core.Phases
        for played in app.played[:app.played_count] {if played.world==world {ran+=played.phases}}
        for phase in core.Phase {
            switch {
            case phase==.Fixed:
            case phase in ran && phase!=.Render: run_editor_only(app,phase,world,editor)
            case: run_phase(app,loop,phase,ALL_PHASES,world,editor)
            }
        }
        return
    }
    frame:=platform.input_frame(app.platform)
    ref:=app_world_ref(app,world)
    if t:=core.world_storage_of(ref,core.Time);t!=nil {t.dt,t.playing=0,false}
    if f:=core.world_storage_of(ref,core.Frame_Time);f!=nil {f.dt,f.alpha=frame.dt,1}
    if input:=core.world_storage_of(ref,core.Input);input!=nil {
        tick:=input_from_platform(platform.input_tick_take(app.platform))
        if app.has_script_input {
            core.input_join(&tick,app.script_input)
            app.has_script_input=false
        }
        input^=tick
    }
    for phase in core.Phase {run_phase(app,loop,phase,ALL_PHASES,world,editor)}
}

// The functions of the editor loop in a phase that the game loop does not also call, in order.
@(private)
run_editor_only :: proc(app:^App,phase:core.Phase,world,editor:rawptr) {
    info:=app.info
    if info==nil {return}
    if f:=core.world_storage_of(app_world_ref(app,world),core.Frame_Time);f!=nil {f.phase=phase}
    for index in info.order[.Editor][phase] {
        if index<0 || int(index)>=len(info.steps) {continue}
        step:=info.steps[index]
        if .Game in step.loops || step.call==nil {continue}
        step.call(world,app.shared,editor,app,0)
    }
}

@(private)
run_phase :: proc(app:^App,loop:core.Loop,phase:core.Phase,phases:core.Phases,world,editor:rawptr) {
    run:=app.info.loops[loop][phase]
    if phase not_in phases || run==nil {return}
    ref:=app_world_ref(app,world)
    if f:=core.world_storage_of(ref,core.Frame_Time);f!=nil {f.phase=phase}
    if phase==.Render {frame_view(app,ref)}
    if !steps_run(app,loop,phase,world,editor) {run(world,app.shared,editor,app)}
}

// The camera and the time the frame is drawn with: those of the View, the
// Time and the Frame_Time of the World whose render phase runs.
@(private)
frame_view :: proc(app:^App,w:core.World_Ref) {
    if view:=core.world_storage_of(w,core.View);view!=nil {app_camera_set(app,camera_from_view(view^),view.cut,view.carried)}
    t,f:=core.world_storage_of(w,core.Time),core.world_storage_of(w,core.Frame_Time)
    if t!=nil && f!=nil {app.time=t.playing?f32(t.seconds)+f.alpha*t.dt:f32(app.seconds)}
}

// A world the window does not show is drawn relative to an origin near its
// own eye, as the window is: the origin follows that of its View before its
// render phase gives the renderer its places. The next frame of the window
// takes it back to its own eye.
@(private)
offscreen_origin :: proc(app:^App,w:core.World_Ref) {
    if view:=core.world_storage_of(w,core.View);view!=nil && app.renderer!=nil {render.renderer_origin_follow(app.renderer,view.position)}
}

@(private)
input_settle :: proc "contextless" (input:^core.Input) {
    input.keys_pressed,input.keys_released={},{}
    input.mouse_pressed,input.mouse_released={},{}
    input.mouse_delta,input.wheel={},{}
}

// Mixer, draw and pacing.
app_frame_end :: proc(app:^App) {
    started:=time.tick_now()
    zone:=profile_part(app,"audio")
    if app.mixer!=nil {audio.mixer_update(app.mixer)}
    base.profile_end(zone)
    frame:=platform.input_frame(app.platform)
    zone=profile_part(app,"render")
    profile_gpu_want(app)
    drawn:=app_draw(app,frame.window)
    app_gpu_failure_check(app)
    base.profile_end(zone)
    app.extras.layer_count,app.extras.panel_count,app.extras.debug_count=0,0,0
    clear(&app.extras.instances)
    app.extras.ui_texture_count,app.extras.effect_view_count,app.extras.probe_count,app.extras.slot_texture_count=0,0,0,0
    app.camera_cut=false
    app.camera_carried={}
    app.inspection={}
    app.view_count=0
    app.texture_view_count=0
    app.stats.frames+=1
    images:=u32(2) if drawn && app.renderer!=nil && render.renderer_stats(app.renderer).generated else 1
    app.stats.fps_frames+=int(images)
    app.stats.fps_seconds+=f64(frame.dt)
    if app.stats.fps_seconds>=0.5 {
        app.stats.fps=f32(f64(app.stats.fps_frames)/app.stats.fps_seconds)
        app.stats.fps_frames,app.stats.fps_seconds=0,0
    }
    free_all(context.temp_allocator)
    zone=profile_part(app,"pacing")
    platform.frame_end(app.platform,drawn || app.renderer==nil,images)
    base.profile_end(zone)
    app.stats.frame_ms=app.stats.platform_ms+app.stats.watch_ms+app.stats.game_ms+app.stats.editor_ms+f32(time.duration_milliseconds(time.tick_since(started)))
    profile_frame_end(app,drawn)
}

// Input the next tick sees besides that of the platform: keys and buttons
// held, their edges and the movement of the mouse. For an application driven
// by a script or an agent instead of a device. With devices, the pointer, the
// gamepads and the device of input replace those of the window in that frame.
app_input_add :: proc(app:^App,input:core.Input,devices:=false) {
    if !app.has_script_input {app.script_input={}}
    core.input_join(&app.script_input,input)
    core.input_join(&app.script_frame_input,input)
    app.has_script_input=true
    if devices {
        input_devices_take(&app.script_input,input)
        input_devices_take(&app.script_frame_input,input)
        app.script_devices=true
    }
}

@(private)
input_devices_take :: proc "contextless" (target:^core.Input,from:core.Input) {
    target.mouse_position,target.gamepads,target.device=from.mouse_position,from.gamepads,from.device
}

// The drawable follows the window; a new density is told to the UI contexts by whoever owns them.
@(private)
app_resize :: proc(app:^App,window:platform.Window_Frame) {
    if app.renderer==nil || window.pixel_size.x<=0 || window.pixel_size.y<=0 {return}
    if window.pixel_size==app.drawable && window.density==app.density && window.pixel_density==app.pixel_density {return}
    app.drawable,app.density=window.pixel_size,window.density
    app.pixel_density=window.pixel_density
    if app.ui_font.ready {ui.font_set_density(&app.ui_font,window.density)}
    render.renderer_resize(app.renderer,u32(window.pixel_size.x),u32(window.pixel_size.y),window.density,window.pixel_density)
}

@(private)
app_draw :: proc(app:^App,window:platform.Window_Frame) -> bool {
    r:=app.renderer
    if r==nil {return false}
    // A failed device draws nothing again: its frames would only fail.
    if failure,_:=rhi.device_failure(app.device);failure!=.None {
        app.stats.frames_skipped+=1
        return false
    }
    if window.minimized || window.pixel_size.x<=0 || window.pixel_size.y<=0 {
        app.stats.frames_skipped+=1
        return false
    }
    extras:=&app.extras
    // One player that shares the screen draws in its tile.
    if app.view_count==0 && app.player_tile_count>0 {
        app.views[0]={camera=app.camera,camera_cut=app.camera_cut,rect=app.player_tiles[0]}
        app.view_count=1
    }
    // The camera alone draws only where it is seen.
    if app.view_count==0 && app.scene.z>0 && app.scene.w>0 {
        app.views[0]={camera=app.camera,camera_cut=app.camera_cut,carried=app.camera_carried,inspection=app.inspection,rect=app.scene}
        app.view_count=1
    }
    started:=time.tick_now()
    // The views of the window and, after them, those drawn into a texture.
    views:[render.VIEW_CAPACITY+TEXTURE_VIEW_CAPACITY]render.Frame_View
    count:=copy(views[:],app.views[:app.view_count])
    count+=copy(views[count:],app.texture_views[:app.texture_view_count])
    drawn:=render.renderer_frame(r,{
        camera=app.camera,detail=app.detail,ui=extras.layers[:extras.layer_count],camera_cut=app.camera_cut,carried=app.camera_carried,inspection=app.inspection,time=app.time,
        views=views[:count],
        panels=extras.panels[:extras.panel_count],debug=extras.debug[:extras.debug_count],
        ui_textures=extras.ui_textures[:extras.ui_texture_count],effect_views=extras.effect_views[:extras.effect_view_count],
        probes=extras.probes[:extras.probe_count],
        output=app.output,ui_only=app.ui_only,
    })
    app.stats.render_ms=f32(time.duration_milliseconds(time.tick_since(started)))
    if !drawn {
        app.stats.frames_skipped+=1
        return false
    }
    app.stats.frames_drawn+=1
    return true
}

// A screen layer for this frame, drawn over the layers added before it.
app_ui_layer_add :: proc(app:^App,layer:render.Ui_Layer) -> bool {
    extras:=&app.extras
    if extras.layer_count>=len(extras.layers) {
        app.stats.extras_dropped+=1
        return false
    }
    extras.layers[extras.layer_count]=layer
    extras.layer_count+=1
    return true
}

app_world_panel_add :: proc(app:^App,panel:render.World_Panel) -> bool {
    extras:=&app.extras
    if extras.panel_count>=len(extras.panels) {
        app.stats.extras_dropped+=1
        return false
    }
    extras.panels[extras.panel_count]=panel
    extras.panel_count+=1
    return true
}

// A world panel drawn into a texture of render.ui_texture_add in this frame.
app_ui_texture_draw :: proc(app:^App,draw:render.Ui_Texture_Draw) -> bool {
    extras:=&app.extras
    if extras.ui_texture_count>=len(extras.ui_textures) {app.stats.extras_dropped+=1;return false}
    extras.ui_textures[extras.ui_texture_count]=draw
    extras.ui_texture_count+=1
    return true
}

// Draws UI into a texture of render.ui_texture_add in a frame of its own,
// without the scene or the window, and reads it back (RGBA8; the caller
// frees it). Between frames.
app_ui_texture_capture :: proc(app:^App,draw:render.Ui_Texture_Draw,allocator:=context.allocator) -> (pixels:[]u8,width,height:int,ok:bool) {
    r:=app.renderer
    if r==nil {return}
    draws:=[1]render.Ui_Texture_Draw{draw}
    if !render.renderer_frame(r,{offscreen=true,ui_only=true,ui_textures=draws[:],time=app.time}) {return}
    return render.ui_texture_capture(r,draw.texture,allocator)
}

// What extensions draw at the Effect stage into a texture of
// render.ui_texture_add, in this frame.
app_effect_view_add :: proc(app:^App,view:render.Effect_View) -> bool {
    extras:=&app.extras
    if extras.effect_view_count>=len(extras.effect_views) {app.stats.extras_dropped+=1;return false}
    extras.effect_views[extras.effect_view_count]=view
    extras.effect_view_count+=1
    return true
}

// A pixel whose depth this frame reads back (render.renderer_depth_probes).
app_depth_probe_add :: proc(app:^App,probe:render.Depth_Probe) -> bool {
    extras:=&app.extras
    if extras.probe_count>=len(extras.probes) {app.stats.extras_dropped+=1;return false}
    extras.probes[extras.probe_count]=probe
    extras.probe_count+=1
    return true
}

app_debug_lines_add :: proc(app:^App,lines:render.Debug_Lines) -> bool {
    extras:=&app.extras
    if extras.debug_count>=len(extras.debug) {
        app.stats.extras_dropped+=1
        return false
    }
    extras.debug[extras.debug_count]=lines
    extras.debug_count+=1
    return true
}

// Visual instances for this frame, without entities in a world.
app_instance_add :: proc(app:^App,instance:render.Instance_Desc) -> bool {
    extras:=&app.extras
    if extras.instances.allocator.procedure==nil && app.allocator.procedure!=nil {extras.instances.allocator=app.allocator}
    if _,error:=append(&extras.instances,instance);error!=nil {app.stats.extras_dropped+=1;return false}
    return true
}

app_instances :: proc(app:^App) -> []render.Instance_Desc {return app.extras.instances[:]}

// Frees what the extras of the frames hold; app_destroy does it.
app_extras_free :: proc(app:^App) {
    delete(app.extras.instances)
    app.extras.instances=nil
}

// A texture a slot of the mesh of an entity shows this frame (Slot_Texture).
// False without room for another one.
app_slot_texture_add :: proc(app:^App,texture:Slot_Texture) -> bool {
    extras:=&app.extras
    if extras.slot_texture_count>=len(extras.slot_textures) {app.stats.extras_dropped+=1;return false}
    extras.slot_textures[extras.slot_texture_count]=texture
    extras.slot_texture_count+=1
    return true
}

app_slot_textures :: proc(app:^App) -> []Slot_Texture {return app.extras.slot_textures[:app.extras.slot_texture_count]}

// What drew the mesh of the Slot_Texture of object in the last frame.
app_slot_shown :: proc(app:^App,object:u64) -> (Slot_Shown,bool) {
    for shown in app.slots_shown[:app.slots_shown_count] {if shown.object==object {return shown,true}}
    return {},false
}

// What the next frame is drawn from. cut: the view jumped and the history of
// the image goes. carried: the rigid transform that carried the camera since
// the last frame with what it sees, which keeps that history instead.
app_camera_set :: proc(app:^App,camera:render.Camera,cut:=false,carried:=render.Mat4{}) {
    app.camera=camera
    if cut {app.camera_cut=true}
    if carried!={} {app.camera_carried=carried}
}

// A view this frame draws into a texture of render.view_texture_add, before
// the views of the window. False without room for another one.
app_texture_view_add :: proc(app:^App,view:render.Frame_View) -> bool {
    if app.texture_view_count>=len(app.texture_views) || view.texture==0 {app.stats.extras_dropped+=1;return false}
    app.texture_views[app.texture_view_count]=view
    app.texture_view_count+=1
    return true
}

// Several views in this frame instead of the camera, each in its rectangle
// of the drawable, in pixels; the UI takes the pointer through the one at
// input_index. A view without a camera stays empty. The camera of each one
// stays in local_cameras for the UI of the frames that follow.
app_views_set :: proc(app:^App,views:[]core.View,rects:[][4]i32,input_index:int) {
    app.view_count=min(len(views),len(rects),len(app.views))
    for i in 0..<app.view_count {
        view:=views[i]
        app.views[i]={camera=camera_from_view(view),camera_cut=view.cut,rect=rects[i],disabled=view.camera==core.NONE,carried=view.carried}
    }
    app.local_camera_count=min(app.view_count,len(app.local_cameras))
    for i in 0..<app.local_camera_count {app.local_cameras[i]=app.views[i].camera}
    rect:[4]f32
    if app.view_count>1 {
        tile:=app.views[clamp(input_index,0,app.view_count-1)].rect
        rect={f32(tile.x),f32(tile.y),f32(tile.z),f32(tile.w)}
        rect/=max(app.density,0.01)
    }
    ui_input_camera(&app.ui_input,app.camera,rect)
}

PLAYER_TILES :: 4

// The part of a surface of size that tile index of count takes: halves for two, quarters for three and four.
split_rect :: proc "contextless" (size:[2]i32,count,index:int) -> [4]i32 {
    columns:=count>1?i32(2):i32(1)
    rows:=count>2?i32(2):i32(1)
    x,y:=i32(index)%columns,i32(index)/columns
    left,top:=size.x*x/columns,size.y*y/rows
    return {left,top,size.x*(x+1)/columns-left,size.y*(y+1)/rows-top}
}

// Where the local player of slot, of count, of the world on screen draws, in
// pixels: the tile it was given, or its part of the drawable.
app_player_rect :: proc "contextless" (app:^App,slot,count:int) -> [4]i32 {
    if slot>=0 && slot<app.player_tile_count {return app.player_tiles[slot]}
    return split_rect(app.drawable,max(count,1),slot)
}

// The size in pixels of what the camera draws: its part of the drawable.
app_scene_size :: proc "contextless" (app:^App) -> [2]f32 {
    if app.scene.z>0 && app.scene.w>0 {return {f32(app.scene.z),f32(app.scene.w)}}
    return {f32(app.drawable.x),f32(app.drawable.y)}
}

// The part of the window the camera draws in, in points; zero: all of it.
app_scene_points :: proc "contextless" (app:^App) -> [4]f32 {
    if app.scene.z<=0 || app.scene.w<=0 {return {}}
    return {f32(app.scene.x),f32(app.scene.y),f32(app.scene.z),f32(app.scene.w)}/max(app.density,0.01)
}

// A render camera from a core.View.
camera_from_view :: proc "contextless" (view:core.View) -> render.Camera {
    forward:=core.view_forward(view)
    up:=quat_up(view)
    fov:=view.fov>0?view.fov*57.29577951308232:60
    projection:=render.Projection.Perspective
    switch view.projection {
    case .Perspective:
    case .Orthographic: projection=.Orthographic
    case .Custom:       projection=.Custom
    }
    return {
        position=view.position,forward=forward,up=up,
        fov_y=fov,near=view.near>0?view.near:0.1,far=max(view.far,0),
        projection=projection,height=view.height,shift=view.shift,custom=view.custom,clip_plane=view.clip_plane,layers=view.layers,own=view.own,fade=view.fade,own_hidden=view.own_hidden,slot=view.slot,focus=view.focus,
        exposure=render_exposure(view.exposure),
    }
}

// The exposure of the renderer for that of a core.View.
render_exposure :: proc "contextless" (e:core.View_Exposure) -> render.Exposure {
    return {mode=e.mode==.Manual?.Manual:.Auto,ev100=e.ev100,compensation=e.compensation,range=e.range,adaptation=e.adaptation,adaptation_mode=e.adaptation_mode==.Speed?.Speed:.Time,own=e.own,tint=e.tint}
}

@(private)
quat_up :: proc "contextless" (view:core.View) -> [3]f32 {
    q:=view.rotation
    v:=[3]f32{0,1,0}
    u:=[3]f32{imag(q),jmag(q),kmag(q)}
    s:=real(q)
    cross :: proc "contextless" (a,b:[3]f32) -> [3]f32 {return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}}
    dot :: proc "contextless" (a,b:[3]f32) -> f32 {return a.x*b.x+a.y*b.y+a.z*b.z}
    return 2*dot(u,v)*u+(s*s-dot(u,u))*v+2*s*cross(u,v)
}

// Writes the last frame drawn as a PNG (RGBA8 at the size of the drawable).
// Between frames; it waits for the GPU.
app_capture :: proc(app:^App,path:string) -> bool {
    if app.renderer==nil {return false}
    pixels,width,height,ok:=render.renderer_capture(app.renderer,app.allocator)
    if !ok {return false}
    defer delete(pixels,app.allocator)
    file:=strings.clone_to_cstring(path,context.temp_allocator)
    return stbi.write_png(file,c.int(width),c.int(height),4,raw_data(pixels),c.int(width*4))!=0
}

// Draws a world the window does not show, with the camera and the UI its
// game gives it, into the image of the renderer without presenting it, and
// reads that image back (RGBA8; the caller frees it). frames are drawn so that what builds up over
// time settles; the edges of its input are cleared first so that its UI does
// not act twice on a press its game already took. The light probes keep the
// world that is shown, and the next frame shown starts a new history.
// A size, in pixels, draws the world alone through the camera of its view
// into an image of that size, with the inspection its render phase asks for:
// no screen UI, world panels, debug lines or outlines. editor is the World of
// the editor when its loop is the one that draws world, as the window does.
// Between frames.
app_capture_world :: proc(app:^App,world:rawptr,frames:=8,size:=[2]i32{},editor:rawptr=nil,allocator:=context.allocator) -> (pixels:[]u8,width,height:int,ok:bool) {
    r:=app.renderer
    if r==nil || world==nil || app.drawable.x<=0 || app.drawable.y<=0 || size.x<0 || size.y<0 {return}
    ui_only:=app.ui_only
    app.ui_only=false
    defer app.ui_only=ui_only
    alone:=size!={}
    texture:render.Texture_Handle
    if alone {texture=render.view_texture_add(r,u32(size.x),u32(size.y),"capture") or_return}
    defer if texture!=0 {render.view_texture_remove(r,texture)}
    ref:=app_world_ref(app,world)
    if !alone {
        if input:=core.world_storage_of(ref,core.Input);input!=nil {input_settle(input)}
        if input:=core.world_storage_of(ref,core.Frame_Input);input!=nil {input_settle(&input.input)}
    }
    loop:=editor!=nil?core.Loop.Editor:.Game
    extras:=&app.extras
    drawn:=false
    count:=max(frames,1)
    for frame:=0;frame<count;frame+=1 {
        if !alone {run_phase(app,loop,.Ui,{.Ui},world,editor)}
        offscreen_origin(app,ref)
        run_phase(app,loop,.Render,{.Render},world,editor)
        desc:=render.Frame_Desc{
            camera=app.camera,ui=extras.layers[:extras.layer_count],camera_cut=frame==0,inspection=app.inspection,time=app.time,
            views=app.views[:app.view_count],panels=extras.panels[:extras.panel_count],debug=extras.debug[:extras.debug_count],
            ui_textures=extras.ui_textures[:extras.ui_texture_count],effect_views=extras.effect_views[:extras.effect_view_count],
            offscreen=true,detail=app.detail,
        }
        seen:=[1]render.Frame_View{{camera=app.camera,camera_cut=frame==0,rect={0,0,size.x,size.y},texture=texture,inspection=app.inspection}}
        if alone {desc.ui,desc.views,desc.panels,desc.debug=nil,seen[:],nil,nil}
        drawn=render.renderer_frame(r,desc)
        extras.layer_count,extras.panel_count,extras.debug_count=0,0,0
        clear(&extras.instances)
        extras.ui_texture_count,extras.effect_view_count,extras.probe_count,extras.slot_texture_count=0,0,0,0
        app.camera_cut=false
        app.inspection={}
        app.view_count=0
        if !drawn {break}
        // The last frame drew a program as its rows while its pipelines were made: one more with them.
        if frame==count-1 && render.renderer_pipelines_pending(r) {
            render.renderer_pipelines_wait(r)
            count+=1
        }
    }
    render.renderer_camera_cut(r)
    if !drawn {return}
    if alone {return render.view_texture_capture(r,texture,allocator)}
    return render.renderer_capture(r,allocator)
}

// Draws a world the window does not show into a texture of
// render.view_texture_add of size pixels, alone through the camera of its
// View, in frames between those of the window: each one dt seconds after the
// one before, its clocks moved by the fixed phase of the loop of the editor
// (editor: the Editor_World), as the editor moves those of the World it
// shows, and drawn by the render phase of its game. cut: the first frame
// starts a new history. The camera and the time of the window stay as they
// were. False when a frame was not drawn.
app_world_draw :: proc(app:^App,world,editor:rawptr,texture:render.Texture_Handle,size:[2]i32,frames:int,dt:f32,cut:bool) -> (drawn:bool) {
    r:=app.renderer
    if r==nil || world==nil || editor==nil || texture==0 || size.x<=0 || size.y<=0 {return}
    ref:=app_world_ref(app,world)
    t,f:=core.world_storage_of(ref,core.Time),core.world_storage_of(ref,core.Frame_Time)
    if t==nil || f==nil {return}
    camera:=app.camera
    camera_cut,carried,inspection,shown,ui_only:=app.camera_cut,app.camera_carried,app.inspection,app.time,app.ui_only
    defer {
        app.camera=camera
        app.camera_cut,app.camera_carried,app.inspection,app.time,app.ui_only=camera_cut,carried,inspection,shown,ui_only
        app.view_count,app.texture_view_count=0,0
    }
    app.ui_only=false
    extras:=&app.extras
    for frame in 0..<max(frames,1) {
        t.dt,t.playing=0,false
        f.dt,f.alpha=max(dt,0),1
        run_phase(app,.Editor,.Fixed,{.Fixed},world,editor)
        offscreen_origin(app,ref)
        run_phase(app,.Game,.Render,{.Render},world,nil)
        seen:=[1]render.Frame_View{{camera=app.camera,camera_cut=cut && frame==0,rect={0,0,size.x,size.y},texture=texture}}
        drawn=render.renderer_frame(r,{camera=app.camera,camera_cut=cut && frame==0,time=app.time+f32(frame)*max(dt,0),views=seen[:],offscreen=true})
        extras.layer_count,extras.panel_count,extras.debug_count=0,0,0
        clear(&extras.instances)
        extras.ui_texture_count,extras.effect_view_count,extras.probe_count,extras.slot_texture_count=0,0,0,0
        if !drawn {return}
    }
    return
}

// A PNG a job of the application writes: compressing it takes long enough
// that a frame would wait for it. The pixels belong to the write until it is
// collected.
Png_Write :: struct {
    path:cstring,
    pixels:[]u8, // RGBA8, of the allocator of the application
    width,height:int,
    quality:int, // above 0: a JPEG of that quality, from 1 to 100, without its alpha
    written:bool,
    busy:bool,
    counter:jobs.Counter,
}

// Starts writing pixels, allocated with the allocator of the application, as
// the PNG at path, or the JPEG of quality; the write takes them.
app_png_write_start :: proc(app:^App,w:^Png_Write,path:string,pixels:[]u8,width,height:int,quality:=0) {
    w^={path=strings.clone_to_cstring(path,app.allocator),pixels=pixels,width=width,height=height,quality=quality,busy=true}
    jobs.run(&app.jobs,jobs.OWNER,png_write,w,&w.counter)
}

@(private)
png_write :: proc(w:^Png_Write,worker:int) {
    if w.quality>0 {
        w.written=stbi.write_jpg(w.path,c.int(w.width),c.int(w.height),4,raw_data(w.pixels),c.int(clamp(w.quality,1,100)))!=0
        return
    }
    w.written=stbi.write_png(w.path,c.int(w.width),c.int(w.height),4,raw_data(w.pixels),c.int(w.width*4))!=0
}

// Whether the write ended; then it is collected: its pixels are freed and
// written says whether the file is there. Without worker threads the job runs here.
app_png_write_poll :: proc(app:^App,w:^Png_Write) -> (finished,written:bool) {
    if !w.busy {return true,w.written}
    if jobs.worker_count(&app.jobs)==1 {jobs.wait(&app.jobs,jobs.OWNER,&w.counter)}
    if jobs.pending(&w.counter) {return false,false}
    delete(w.pixels,app.allocator);delete(w.path,app.allocator)
    w.pixels,w.path,w.busy=nil,nil,false
    return true,w.written
}

// Waits for the write to end and collects it.
app_png_write_wait :: proc(app:^App,w:^Png_Write) -> bool {
    if w.busy {jobs.wait(&app.jobs,jobs.OWNER,&w.counter)}
    _,written:=app_png_write_poll(app,w)
    return written
}

// The pixels of the last frame drawn; the caller frees them with the allocator.
// generated: the image shown before that of the last frame, which frame generation drew.
app_capture_pixels :: proc(app:^App,allocator:=context.allocator,generated:=false) -> (pixels:[]u8,width,height:int,ok:bool) {
    if app.renderer==nil {return}
    if generated {return render.renderer_capture_generated(app.renderer,allocator)}
    return render.renderer_capture(app.renderer,allocator)
}

// A UI context of the application: its fonts and density are those every
// other context has, so one atlas serves all of them.
// panels: the world panels it builds in a frame; 0: those of ui.
app_ui_context_create :: proc(app:^App,panels:=0) -> ^ui.Context {
    ctx:=new(ui.Context,app.allocator)
    desc:=app_ui_context_desc(app)
    desc.max_panels=panels
    if !ui.context_init(ctx,desc) {
        free(ctx,app.allocator)
        return nil
    }
    return ctx
}

app_ui_context_destroy :: proc(app:^App,ctx:^ui.Context) {
    if ctx==nil {return}
    ui.context_destroy(ctx)
    free(ctx,app.allocator)
}
