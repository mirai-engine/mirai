package host

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "mirai:asset"
import audio "mirai:audio"
import "mirai:core"
import "mirai:platform"
import "mirai:project"
import render "mirai:render"
import "mirai:rhi"
import "mirai:ui"
import "mirai:std/base"
import "mirai:std/jobs"

// The application: the platform, the job system, the GPU device and the
// renderer when asked for, the mixer, the assets and the worlds of the
// project it runs. Three ways to run:
//
//   window          a window, a device that presents to it and a renderer
//   gpu alone       a device and a renderer that draw off screen: captures and tests
//   neither         no GPU: simulation tests and dedicated servers

App_Error :: enum u8 {None,Out_Of_Memory,Platform_Failed,Jobs_Failed,World_Failed,Device_Failed,Renderer_Failed,Audio_Failed,Assets_Failed}

Audio_Output :: enum u8 {
    None,
    Device, // a mixer played by the default output of the system
    Memory, // a mixer nobody plays: whoever owns the app renders it with audio.mixer_render
}

App_Desc :: struct {
    info:^core.World_Info,       // of the project: generated
    allocator:runtime.Allocator, // context.allocator when unset
    threads:int,                 // job threads besides the caller. 0: none. jobs.THREADS_AUTO: one per remaining core
    fixed_dt:f32,                // >0: every frame lasts this long and is not paced (deterministic runs)
    max_ticks_per_frame:int,     // 0: 8

    window:bool,                 // opens a window; implies gpu
    shown:bool,                  // without a window, its frames still reach someone: a surface another process shows (the player's --surface)
    gpu:bool,                    // creates the device and the renderer
    window_desc:platform.Window_Desc,
    game_window:bool,            // the window is the game's, as the player opens it: what the player chose of it applies (Display_Settings of the render library)
    video_driver:string,
    vsync:bool,
    gpu_validation:bool,
    gpu_message:rhi.Message_Proc,
    gpu_loader_lock:^sync.Mutex,
    render_settings:Maybe(render.Settings),
    ui_font_sizes:[]i32,         // point sizes of every UI context of the application; those of the editor when empty

    audio:Audio_Output,
    audio_driver:string,

    root:string,                 // the project: its manifest and its settings
    engine_root:string,          // the engine whose general settings lie under those of the project; empty: only the project's, as in a shipped game
    options:string,              // folder of the options the player chose (settings of the machine and input bindings) over those of the project; "": none, as in the editor
    assets_root:string,          // folder of cooked assets; its changes are reloaded
    assets_imported:string,      // the imported folder that goes with assets_root, of a project that is not shipped; "": none
    assets_cache:string,         // file where the registry of assets_root keeps what it saw; "": none
    animation_cache:string,      // folder where the content keeps the .anim it compressed; "": none
    shaders_root:string,         // folder whose shader generation is loaded; "": the one that holds assets_root
    asset_mounts:[]asset.Registry_Mount,
}

// What the player was asked for at launch: libraries read it (the first
// scene, the local players). Each library takes from arguments the ones it
// reads (launch_flag, launch_value); one that none took after the first frame
// is an argument the player does not understand.
Launch :: struct {
    scene:string,
    players:int,        // --players: the local players of the run (input.Run_Players); 0: not asked
    arguments:[]string, // what the player does not read itself
    taken:[]bool,       // by argument: a library read it
}

// Whether the launch has flag, which is then taken, and where.
launch_flag :: proc(launch:^Launch,flag:string) -> (index:int,found:bool) {
    for argument,i in launch.arguments {
        if argument!=flag {continue}
        launch.taken[i]=true
        return i,true
    }
    return -1,false
}

// The argument after the one at index when it is not another flag, which is then taken.
launch_value :: proc(launch:^Launch,index:int) -> (value:string,found:bool) {
    next:=index+1
    if index<0 || next>=len(launch.arguments) || len(launch.arguments[next])>=2 && launch.arguments[next][:2]=="--" {return}
    launch.taken[next]=true
    return launch.arguments[next],true
}

// The first argument no library took; empty when all were.
launch_untaken :: proc(launch:^Launch) -> string {
    for argument,i in launch.arguments {
        if !launch.taken[i] {return argument}
    }
    return ""
}

// From now on frames last what the clock says, at the pace of the clock: what
// a library that talks to other processes needs (a session on a network) in a
// run that stepped a fixed dt without a window.
app_real_time :: proc(app:^App) {
    if app.platform==nil || app.platform.fixed_dt<=0 {return}
    app.platform.fixed_dt=0
    app.platform.pacing=platform.FRAME_PACING_DEFAULT
}

App_Stats :: struct {
    frames:u64,
    frames_drawn:u64,
    frames_skipped:u64,
    watch_slices:u64,
    ticks:u64,
    ticks_dropped:u64, // ticks a slow frame could not simulate
    // Time of the main thread in the parts of the last frame, in ms.
    platform_ms:f32,
    watch_ms:f32,
    game_ms:f32,     // the loop of the game
    editor_ms:f32,   // the loop of the editor
    render_ms:f32,   // render.renderer_frame, with its waits for the GPU
    frame_ms:f32,
    fps:f32,         // images shown per second over the last half second: two a frame that generated one
    fps_frames:int,
    fps_seconds:f64,
}

App :: struct {
    allocator:runtime.Allocator,
    // What the window opened with, its title aside: what a choice of the
    // player left at zero goes back to. Before the field platform, which hides the package.
    window:platform.Window_Desc,
    game_window:bool, // App_Desc.game_window
    platform:^platform.Platform,
    jobs:jobs.Job_System,
    info:^core.World_Info,
    shared:rawptr,   // the Shared of the project: one per application
    world:rawptr,    // the World the player runs
    worlds:[dynamic]World_Slot, // the Worlds it made, by the index of their core.World_Id
    reserved:map[rawptr]int,    // the address space of each struct of a place it made (world_alloc)
    scratch:rawptr,  // a World app_world_replace prepares the replacements in; made the first time
    scratch_mixed:bool, // it holds parts of several Worlds, which a replacement of what changed left: to copy over or to clear, never to run
    root,engine_root,options:string, // those of App_Desc
    animation_cache:string,          // App_Desc.animation_cache
    start_ns:u64,
    seconds:f64, // the frames so far, each as long as its dt: the fixed one in a manual run
    quit:bool,
    exit_code:int,    // of the player once a library quits it (app_exit)
    script_hold:bool, // the scripted input of the player waits: what it drives is not ready (a client before it joins)
    paced:bool, // a window at the pace of the clock: the graphics settings set its frame rate
    stats:App_Stats,
    texture_streaming:Texture_Streaming, // the reads of the levels of textures under way
    asset_releases:Assets_Releases, // what jobs read for the loads, freed in jobs
    step_ns:[]u64, // the time of each function of info.steps since whoever reads it last cleared it, settle included
    profiler:Profiler, // the frames someone asked to record (profile.odin)
    load_profile:Load_Profile, // what the last loads took (load_profile.odin)

    tick_dt:f32,
    max_ticks:int,
    // The worlds whose game loop ran in this frame and its phases: over them the editor loop runs
    // only its own functions in those phases.
    played:[GAME_FRAMES_KEPT]Played_World,
    played_count:int,

    device:^rhi.Device,
    gpu_failure:[GPU_FAILURE_TEXT]u8, // what app_gpu_failure says once the device failed
    gpu_failure_length:int,
    renderer:^render.Renderer, // nil without gpu
    drawable:[2]i32,           // device pixels
    density:f32,               // device pixels per window point
    pixel_density:f32,
    camera:render.Camera,      // what the next frame is drawn from: the render library sets it
    output:rhi.Texture,        // where the frame also goes: the shared texture of a player another process shows
    ui_only:bool,              // the next frame draws only the screen UI: something covers the scene
    camera_cut:bool,
    camera_carried:render.Mat4, // the camera was carried with what it sees since the last frame; zero: it was not
    inspection:render.View_Inspection, // what the view of the camera shows in the next frame instead of its lit image: the editor sets it
    detail:render.Frame_Detail, // the camera that chooses the detail of the views of the window in the next frame: the editor sets it
    // The part of the drawable the camera draws in, in pixels: what is not
    // always covered (the editor leaves out its bars). Zero: all of it.
    scene:[4]i32,
    scene_shift:[2]f32, // where the center of the view of the camera is, in halves of scene: what surrounds scene is part of the view, not drawn
    time:f32,                 // seconds of the world the next frame shows: the render library sets it
    views:[render.VIEW_CAPACITY]render.Frame_View,
    view_count:int,
    // The camera of each local player in the last frame the screen was split,
    // which stays for the UI of the next one (app_views_set).
    local_cameras:[PLAYER_TILES]render.Camera,
    local_camera_count:int,
    // Where each local player of the world on screen draws, in pixels, when
    // the screen is shared with others (the players of other processes an
    // editor shows); none: they split the drawable among them.
    player_tiles:[PLAYER_TILES][4]i32,
    player_tile_count:int,
    ui_font_sizes:[]i32,
    // The font every UI context of the application borrows, on demand: the
    // application rasterizes what they ask for (app_ui_font_sync).
    ui_font:ui.Font,
    font:Font_Key,
    extras:Frame_Extras,
    ui_input:ui.Input,    // of the pointer and the keyboard this frame, for the UI of the game

    mixer:^audio.Mixer, // nil without audio

    assets:^Assets,       // nil without assets_root
    assets_watch:Assets_Watch,
    asset_marks:Assets_Marks,
    shaders:App_Shaders,
    content:^Content,
    records:App_Records, // the rows of the record types of the world, read once a function asks for them
    texts:App_Texts,     // every .strings of the assets, read once something asks for a text

    launch:Launch,
    script_input:core.Input,
    script_frame_input:core.Input,
    has_script_input:bool,
    script_devices:bool, // script_input holds the pointer, the gamepads and the device: they replace those of the window
    game_input_blocked:bool, // the pointer is on the editor: the game gets no input this frame
    game_mouse_off:bool,     // the editor has the mouse (Play paused or released, Simulate, Watch): the game does not capture it
    game_input_excluded:core.Keys,
}

// A World the application made, at the index of its core.World_Id. A free
// slot keeps the generation of the last World it held, so the id of a freed
// World names no other.
World_Slot :: struct {
    data:rawptr, // nil while free
    generation:u32,
}

app_create :: proc(desc:App_Desc) -> (app:^App,error:App_Error) {
    allocator:=desc.allocator.procedure!=nil?desc.allocator:context.allocator
    allocation_error:runtime.Allocator_Error
    if app,allocation_error=new(App,allocator);allocation_error!=nil {return nil,.Out_Of_Memory}
    app.allocator=allocator
    app.info=desc.info
    if app.info!=nil {
        if app.step_ns,allocation_error=make([]u64,len(app.info.steps),allocator);allocation_error!=nil {
            app_destroy(app)
            return nil,.Out_Of_Memory
        }
    }
    app.density=1
    app.pixel_density=1
    texts:[4]runtime.Allocator_Error
    app.root,texts[0]=strings.clone(desc.root,allocator)
    app.engine_root,texts[1]=strings.clone(desc.engine_root,allocator)
    app.options,texts[2]=strings.clone(desc.options,allocator)
    app.animation_cache,texts[3]=strings.clone(desc.animation_cache,allocator)
    for text in texts {
        if text!=nil {
            app_destroy(app)
            return nil,.Out_Of_Memory
        }
    }
    app.paced=desc.window && desc.fixed_dt<=0
    app.game_window=desc.window && desc.game_window
    app.window=desc.window_desc
    app.window.title,app.window.version,app.window.identifier="","",""
    app.tick_dt=1/f32(core.SIMULATION_SETTINGS_DEFAULT.tick_rate)
    app.max_ticks=desc.max_ticks_per_frame>0?desc.max_ticks_per_frame:8
    app.worlds=make([dynamic]World_Slot,allocator)
    if app.extras.instances,allocation_error=make([dynamic]render.Instance_Desc,0,FRAME_INSTANCE_RESERVE,allocator);allocation_error!=nil {
        app_destroy(app)
        return nil,.Out_Of_Memory
    }
    platform_desc:=platform.Platform_Desc{
        headless=!desc.window,window=desc.window_desc,video_driver=desc.video_driver,
        fixed_dt=desc.fixed_dt,allocator=allocator,
    }
    if desc.fixed_dt>0 {platform_desc.pacing=platform.Frame_Pacing{}}
    else if desc.vsync {platform_desc.pacing=platform.Frame_Pacing{limit=platform.FRAME_PACING_DEFAULT.limit,vsync=true}}
    platform_error:platform.Error
    if app.platform,platform_error=platform.create(platform_desc);platform_error!=.None {
        app_destroy(app)
        return nil,.Platform_Failed
    }
    if !jobs.system_init(&app.jobs,{threads=desc.threads,allocator=allocator}) {
        app_destroy(app)
        return nil,.Jobs_Failed
    }
    if len(desc.ui_font_sizes)>0 {
        if app.ui_font_sizes,allocation_error=make([]i32,len(desc.ui_font_sizes),allocator);allocation_error!=nil {
            app_destroy(app)
            return nil,.Out_Of_Memory
        }
        copy(app.ui_font_sizes,desc.ui_font_sizes)
    }
    app.start_ns=platform.clock_ns()
    if desc.window || desc.gpu {
        if error=app_gpu_create(app,desc);error!=.None {
            app_destroy(app)
            return nil,error
        }
    }
    if desc.audio!=.None {
        audio_error:audio.Error
        if app.mixer,audio_error=audio.mixer_create({allocator=allocator,decoder_thread=desc.audio==.Device});audio_error!=.None {
            app_destroy(app)
            return nil,.Audio_Failed
        }
        if desc.audio==.Device && platform.audio_device_open(app.platform,app.mixer,{driver=desc.audio_driver})!=.None {
            app_destroy(app)
            return nil,.Audio_Failed
        }
    }
    if desc.assets_root!="" {
        if error=app_assets_create(app,desc.assets_root,desc.assets_cache,desc.asset_mounts,desc.assets_imported);error!=.None {
            app_destroy(app)
            return nil,error
        }
    }
    if app.info!=nil {
        if app.shared=world_alloc(app,.Shared);app.shared==nil {
            app_destroy(app)
            return nil,.World_Failed
        }
    }
    return app,.None
}

app_destroy :: proc(app:^App) {
    if app==nil {return}
    if app.world!=nil {app_world_free(app,app.world)}
    app_world_scratch_free(app)
    if app.shared!=nil {world_free(app,app.shared,.Shared)}
    delete(app.worlds)
    delete(app.reserved)
    delete(app.step_ns,app.allocator)
    load_profile_destroy(app)
    delete(app.ui_font_sizes,app.allocator)
    ui.font_destroy(&app.ui_font)
    if app.mixer!=nil {
        if app.platform!=nil {platform.audio_device_close(app.platform)}
        audio.mixer_destroy(app.mixer)
    }
    app_content_destroy(app)
    app_records_destroy(app)
    app_texts_destroy(app)
    assets_marks_free(&app.asset_marks)
    app_assets_destroy(app)
    app_gpu_destroy(app)
    if jobs.worker_count(&app.jobs)>0 {jobs.system_destroy(&app.jobs)}
    profile_release(app)
    if app.platform!=nil {platform.destroy(app.platform)}
    delete(app.root,app.allocator);delete(app.engine_root,app.allocator);delete(app.options,app.allocator)
    delete(app.animation_cache,app.allocator)
    extras_free(&app.extras)
    free(app,app.allocator)
}

// A World of the project, initialized, with its id: the player's, the
// editor's and the one of its Play. nil without memory.
app_world_create :: proc(app:^App) -> rawptr {
    at:=world_slot_free(app)
    if at<0 {return nil}
    data:=world_alloc(app,.World)
    if data==nil {return nil}
    if !world_register(app,at,data) {
        world_unregister(app,data)
        world_free(app,data,.World)
        return nil
    }
    tick_rate_follow(app)
    return data
}

// The fixed step the Worlds made from now on advance by: the tick rate of the
// Simulation_Settings of the application, which Project Settings changes.
@(private)
tick_rate_follow :: proc(app:^App) {
    if app.shared==nil {return}
    if settings:=core.world_storage_of(core.world_ref(app.shared,app.info,.Shared),core.Simulation_Settings);settings!=nil && settings.tick_rate>0 {
        app.tick_dt=1/f32(settings.tick_rate)
    }
}

// Frees a World: first its release phase, where the storages of the
// application let go of what they hold for it.
app_world_free :: proc(app:^App,data:rawptr) {
    if data==nil {return}
    run_phase(app,.Game,.Release,{.Release},data,nil)
    world_unregister(app,data)
    world_free(app,data,.World)
}

// The id of a World the application made; zero for another.
app_world_id :: proc(app:^App,data:rawptr) -> core.World_Id {
    at:=world_slot_of(app,data)
    if at<0 {return {}}
    return {u32(at),app.worlds[at].generation}
}

// The World of an id; nil once that World was freed.
app_world_of :: proc(app:^App,id:core.World_Id) -> rawptr {
    if id.generation==0 || int(id.index)>=len(app.worlds) {return nil}
    slot:=&app.worlds[id.index]
    return slot.generation==id.generation?slot.data:nil
}

// The Worlds the application holds.
app_world_count :: proc(app:^App) -> (count:int) {
    for slot in app.worlds {if slot.data!=nil {count+=1}}
    return
}

// The storage T of a World as its functions receive it: in the World, or its
// own value of a by_world storage of the Shared. nil without one, or without
// the layout of the Worlds (no game loaded).
app_world_storage :: proc(app:^App,data:rawptr,$T:typeid) -> ^T {
    if app.info==nil {return nil}
    if value:=core.world_storage_of(app_world_ref(app,data),T);value!=nil {return value}
    if app.shared==nil {return nil}
    for s in app.info.storages {
        if s.type==T && s.place==.Shared && s.by_world {return core.by_world_get(cast(^core.By_World(T))(uintptr(app.shared)+s.offset),app_world_id(app,data))}
    }
    return nil
}

@(private)
world_slot_of :: proc(app:^App,data:rawptr) -> int {
    if data==nil {return -1}
    for slot,at in app.worlds {if slot.data==data {return at}}
    return -1
}

// Where the next World goes: a free slot, or room for one more. -1 without memory.
@(private)
world_slot_free :: proc(app:^App) -> int {
    for slot,at in app.worlds {if slot.data==nil {return at}}
    if reserve(&app.worlds,len(app.worlds)+1)!=nil {return -1}
    return len(app.worlds)
}

// Gives the World the slot world_slot_free found, a new generation of it, its
// id and the values of the by_world storages. False without memory for them.
@(private)
world_register :: proc(app:^App,at:int,data:rawptr) -> bool {
    if at==len(app.worlds) {append(&app.worlds,World_Slot{})}
    slot:=&app.worlds[at]
    slot.generation+=1
    if slot.generation==0 {slot.generation=1}
    slot.data=data
    if id:=core.world_storage_of(app_world_ref(app,data),core.World_Id);id!=nil {id^={u32(at),slot.generation}}
    return core.world_attach(app.info,data,app.shared,app.allocator)
}

// Takes the World out of its slot with the values of its by_world storages.
@(private)
world_unregister :: proc(app:^App,data:rawptr) {
    if app.allocator.procedure!=nil {context.allocator=app.allocator}
    core.world_detach(app.info,data,app.shared)
    if at:=world_slot_of(app,data);at>=0 {app.worlds[at].data=nil}
}

// Makes the World dst a copy of src, all of it or nothing: src is copied into
// a World of the application, which then trades its contents with dst
// without allocating. False when memory ran out: dst stays as it was. What
// the World does not copy (copy=false) stays in dst. The traded contents wait
// in that World for the next replacement, which copies over them without
// allocating when they fit. marks: when src is a copy core.world_copy_changed
// keeps of dst, its marks: only what dst changed since that copy is copied
// and traded, and the readers of the rest see no change (core.world_restore).
app_world_replace :: proc(app:^App,dst,src:rawptr,marks:[]core.Copy_Mark=nil) -> bool {
    if dst==src {return true}
    if dst==nil || src==nil {return false}
    if app.scratch==nil {
        if app.scratch=app_world_create(app);app.scratch==nil {return false}
    }
    context.allocator=app.allocator
    ok,mixed:=core.world_restore(app.info,dst,src,app.scratch,marks)
    app.scratch_mixed=mixed
    return ok
}

// Frees the World app_world_replace keeps: what a replacement that happens
// seldom, as opening a scene, need not hold until the next one.
app_world_scratch_free :: proc(app:^App) {
    if app.scratch==nil {return}
    // Parts of several Worlds are no World to run a release phase on: it runs on it cleared.
    if app.scratch_mixed && !core.world_clear(app.info,app.scratch) {
        world_unregister(app,app.scratch)
        world_free(app,app.scratch,.World)
    } else {app_world_free(app,app.scratch)}
    app.scratch,app.scratch_mixed=nil,false
}

// An Editor_World of the project, initialized.
app_editor_create :: proc(app:^App) -> rawptr {return world_alloc(app,.Editor)}
app_editor_free :: proc(app:^App,data:rawptr) {world_free(app,data,.Editor)}

// The address space of a struct of a place: what a library whose worlds lay
// out larger grows it into, where it is (app_worlds_migrate). Only what it
// holds takes memory.
WORLD_RESERVE :: 256<<20
GAME_FRAMES_KEPT :: 8 // the user's run and those of the agents that step in one frame
Played_World :: struct {world:rawptr,phases:core.Phases}

@(private)
world_alloc :: proc(app:^App,place:core.Place) -> rawptr {
    info:=app.info
    size:=max(info.sizes[place],1)
    if info.aligns[place]>PAGE {return nil}
    reserved:=max(WORLD_RESERVE,page_round(size)*4)
    block,error:=virtual.reserve(uint(reserved))
    if error!=nil {return nil}
    data:=raw_data(block)
    if virtual.commit(data,uint(page_round(size)))!=nil {
        virtual.release(data,uint(reserved))
        return nil
    }
    app.reserved.allocator=app.allocator
    app.reserved[data]=reserved
    if !core.world_init(info,place,data,app.allocator) {
        world_free(app,data,place)
        return nil
    }
    if place!=.Editor {app_settings_load(app,data,place)}
    return data
}

@(private)
world_free :: proc(app:^App,data:rawptr,place:core.Place) {
    context.allocator=app.allocator
    core.world_destroy(app.info,place,data)
    _,reserved:=delete_key(&app.reserved,data)
    virtual.release(data,uint(reserved))
    if len(app.reserved)==0 {
        delete(app.reserved)
        app.reserved=nil
    }
}

@(private) PAGE :: 4096

@(private)
page_round :: proc "contextless" (size:int) -> int {return (size+PAGE-1)&~(PAGE-1)}

// Moves every struct the application made into the layout of m.to, each
// where it is, and makes m.to its World_Info: the Worlds, the Shared and the
// Editor_World of editor (nil without one). The caller settles every World
// first. False, with nothing changed, when one would not fit the room it has.
// Nothing else may run meanwhile: what moves is not where it was until each
// struct is back.
app_worlds_migrate :: proc(app:^App,m:^core.World_Migration,editor:rawptr) -> bool {
    context.allocator=app.allocator
    to:=m.to
    worlds:=make([dynamic]rawptr,context.temp_allocator)
    for slot in app.worlds {if slot.data!=nil {append(&worlds,slot.data)}}
    fits :: proc(app:^App,data:rawptr,size:int) -> bool {return data==nil || page_round(size)<=(app.reserved[data] or_else 0)}
    for place in m.places {
        if to.aligns[place]>PAGE {return false}
    }
    if .World in m.places {
        for data in worlds {if !fits(app,data,to.sizes[.World]) {return false}}
    }
    if .Shared in m.places && !fits(app,app.shared,to.sizes[.Shared]) {return false}
    if .Editor in m.places && !fits(app,editor,to.sizes[.Editor]) {return false}
    app.info=to
    if .Shared in m.places && app.shared!=nil {place_replace(app,m,.Shared,app.shared)}
    if .Editor in m.places && editor!=nil {place_replace(app,m,.Editor,editor)}
    if .World in m.places {
        for data in worlds {place_replace(app,m,.World,data)}
    }
    // What the by_world storages hold for each World, of those that did not move.
    if .Shared in m.places && app.shared!=nil {
        for data in worlds {
            if id:=core.world_storage_of(app_world_ref(app,data),core.World_Id);id!=nil {_=core.by_world_new(m,app.shared,id^,app.allocator)}
        }
    }
    return true
}

// A struct of a place migrated into one the new library made, which then
// takes its place.
@(private)
place_replace :: proc(app:^App,m:^core.World_Migration,place:core.Place,data:rawptr) {
    size:=max(m.to.sizes[place],1)
    fresh,error:=mem.alloc(size,max(m.to.aligns[place],1),app.allocator)
    if error!=nil || !core.world_init(m.to,place,fresh,app.allocator) {
        // Without memory for it, the struct starts as the new library makes it.
        if fresh!=nil {core.world_destroy(m.to,place,fresh);mem.free(fresh,app.allocator)}
        core.world_destroy(m.from,place,data)
        mem.zero(data,size)
        _=core.world_init(m.to,place,data,app.allocator)
        return
    }
    if place!=.Editor {app_settings_load(app,fresh,place)}
    core.place_migrate(m,place,data,fresh,app.allocator)
    core.world_destroy(m.from,place,data)
    old:=max(m.from.sizes[place],1)
    if page_round(size)>page_round(old) {_=virtual.commit(data,uint(page_round(size)))}
    mem.copy(data,fresh,size)
    if old>size {mem.zero(rawptr(uintptr(data)+uintptr(size)),old-size)}
    mem.free(fresh,app.allocator)
}

app_world_ref :: proc(app:^App,data:rawptr) -> core.World_Ref {return core.world_ref(data,app.info)}

// Seconds of real time since the application was created.
app_seconds :: proc(app:^App) -> f64 {return f64(platform.clock_ns()-app.start_ns)/1e9}

USER_ORGANIZATION :: "Mirai"

// What the project keeps for its user, the saves and the compiled GPU
// pipelines: <user data>/Mirai/<name of the project>, made when missing. ""
// without a project or a folder of user data.
app_user_folder :: proc(root:string,allocator:=context.allocator) -> string {
    if root=="" {return ""}
    name:=filepath.base(root)
    if manifest,error:=project.manifest_read(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator));error.code==.None {
        if declared:=base.text_get(manifest.name[:]);declared!="" {name=strings.clone(declared,context.temp_allocator)}
    }
    folder,_:=platform.path_user_data_folder(USER_ORGANIZATION,name,allocator)
    return folder
}
