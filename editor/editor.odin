package editor

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import eaudio "mirai:engine/audio"
import input "mirai:engine/input"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"
import "mirai:std/subprocess"
import "mirai:ui"

// The editor of a project: the application with its window, the World that
// is edited, the World of a Play and the Editor_World of the editor and of
// the editor packages of its plugins. Everything it does in a frame are
// steps of the editor loop over the World shown (editor_begin, editor_tools,
// editor_panels, editor_end); what replaces a World (Play, Stop, opening a
// scene, the restart after a build) is asked for in Session.requests and
// done by run between frames.

EDITOR_BACKGROUND_FPS :: 10 // frames per second at most of a window without focus out of Play

EDITOR_OK :: 0
EDITOR_FAILED :: 1  // the application could not be created
EDITOR_USAGE :: 2
EDITOR_SCENE :: 3   // the scene asked for could not be opened
EDITOR_CAPTURE :: 4 // the capture could not be written
EDITOR_API :: 5     // headless and manual, without the API it is driven by
EDITOR_GPU_LOST :: 7 // the GPU stopped working again right after the editor started again for it

ASSETS_FOLDER :: "assets"
TOAST_SECONDS :: f32(2.5)
TOAST_BYTES :: 160
HEADLESS_DT :: f32(1.0/60)

// Watch shows the run of an agent without editing it; the game of the user,
// if any, goes on unseen.
Mode :: enum u8 {Edit,Play,Paused,Simulate,Simulation_Paused,Watch}

Request :: enum u8 {
    Play,    // copy the edited World and run its game loop
    Simulate,
    Apply_Simulation,
    Recover,Discard_Recovery,
    Stop,    // discard the World of the Play
    Pause,
    Resume,
    Resume_Here, // from the frame the history went back to, dropping what came after it
    New,     // an empty scene, without asking
    Open,    // Session.open_path, without asking
    Restart, // the executable Build_State.output with the scene as it is
    Quit,    // ends without asking
    Document_Switch,
    Document_Close,
    Document_Discard,
    Asset_Switch,  // Session.asset_request comes to the front; -1: the scene
    Asset_Close,   // Session.asset_request closes, asking about its asset
    Asset_Discard, // Session.asset_request closes without asking
    Quit_Check,
    Camera_Preview, // preview Camera_Preview_Run.request
    Camera_Keep,    // end previewing, keeping what the cameras became
    Camera_Discard, // end previewing without it
}
Requests :: bit_set[Request;u64]

EDITOR_RUNS :: 1+AI_WORKER_CAPACITY*PLAYER_PROCESSES

// A copy of the edited World that a game runs on. The run of the user is the
// one the editor shows while it plays; the run of an AI task is not shown and
// advances one tick for each step it asks for, with only the input it gives.
Run :: struct {
    world:rawptr,               // nil: the place is free
    id:u64,                     // what play.history and play.seek take as run; from 1, never reused in a session
    player:int,                 // 0: the run of its owner; more: another player of its game on the network, a client of the first (an agent's)
    owner:int,                  // the AI task that keeps it alive; 0: the user
    step:bool,                  // one tick was asked for it
    input:core.Input,           // that the tick it was asked for sees
    has_input:bool,
    held_keys:core.Keys,        // by the last step, for the edges of the next
    held_buttons:core.Mouse_Buttons,
    held_pads:[core.GAMEPAD_CAPACITY]platform.Gamepad_Buttons,
    pointer:[2]f32,             // where the last step left the pointer, in points of the window
    pointer_set:bool,           // a step placed it: the UI of the game has a pointer, and steps give it what they hold
    ui:ui.Input,                // what the steps give the UI of the game; the size and the scale are those of the window
    frame_dt:f64,               // >0: the step asked for is a frame that lasts this long, as a recording advances it
    history:^Run_History,       // its past, once it kept a copy
    history_off:bool,           // it keeps none: its ring could not be made
    document:u64,               // edits_scene_state of the document it copied
    quit_asked:bool,            // the game asked to quit since what holds it last looked
    quit_held:bool,             // a plugin drives it: asking to quit does not end it
}

@(private)
USAGE_TEXT :: `Usage: [--project <folder>] [--scene <path>] [--headless] [--hidden] [--no-gpu] [--frames <n>] [--capture <png>] [--validation]
     [--width <points>] [--height <points>] [--density <x>] [--engine <folder>] [--api-port <port>] [--no-api]
     [--share [port]] [--join <invitation>] [--name <name>] [--preferences]
  --api-port    port of the agent API (JSON-RPC and MCP); 7940 if missing, or a free one when it is taken; 0: a free one, never 7940
  --no-api      without the agent API
  --share       shares the scene with other editors; port 7950 if missing. Prints the invitation code
  --join        joins the session of another editor with the code of its invitation (K7Q2-9XMA-PL3F-0B2C)
  --name        name in the shared session
  --project     project folder; the current one if missing
  --scene       scene to open: a file or a path relative to the assets folder
  --headless    without a window: draws off screen with steps of 1/60 s; without the editor preferences
  --preferences with --headless: reads and saves the editor preferences, like one with a window
  --no-gpu      with --headless: without a renderer
  --density     with --headless: pixels per UI point (1.25, 1.5...), like on a scaled screen; 1 if missing
  --frames      ends after n frames
  --capture     writes the last frame as a PNG at the end
  --validation  turns on the validation of the graphics API
  --engine      engine root for Build; if missing, MIRAI_ROOT or the engine above the executable or the working folder`

// The arguments the editor was started with.
Options :: struct {
    project,scene,engine,capture:string,
    restore:string,  // a scene file the restart left: loaded instead of scene, which stays the path of the document
    documents:string,
    gpu_lost:string, // what stopped the GPU of the editor whose restart this is
    built:bool,      // a Build of the editor whose restart this is succeeded: its library is the one loaded
    view:string,     // the camera: "x,y,z,yaw,pitch,distance"
    select:string,   // Ids of the entities selected, in hexadecimal, separated by commas
    dirty:bool,      // the restored scene had unsaved changes
    frames,width,height:int,
    density:f32,     // headless: pixels per point; 0: 1
    headless,no_gpu,validation,hidden:bool,
    preferences:bool, // a headless editor keeps the preferences of the editor too
    api_port:int,    // of the agent API; 0: the default one
    api_port_any:bool, // --api-port 0: a free one the system picks, never the default, which stays the user's editor's
    no_api:bool,
    name:string,     // in a shared session
    share:int,       // >0: shares the scene on this port; <0: the default one
    join:string,     // an address: enters the session of another editor
    launcher:bool,   // only the projects of the machine, to open one (projects.odin)
    git_init:bool,   // the project becomes a repository once git answers, with git_lfs and git_remote
    git_lfs:bool,
    git_remote:string,
}

// The editor while it runs. The other storages of the editor are reachable
// from here for code that works on the whole editor: the API, the restart.
@(storage,shared,free="session_free")
Session :: struct {
    app:^host.App,
    info:^core.World_Info,
    libraries:[dynamic]host.Project_Library, // loaded by Builds after the first: they stay until the editor ends
    library_generation:int,
    cards:[CARD_CAPACITY]Card,                   // of cards(): the presets and those of the plugins of the library in use
    card_tables:[CARD_CAPACITY]^core.Table_Info, // of the component each one is the icon of
    card_count:int,
    cards_library:int,                           // library_generation+1 of the cards held
    providers:Providers,                         // of the plugins of the library in use
    edit_world:rawptr,   // the World being edited
    runs:[EDITOR_RUNS]Run,
    run_serial:u64,      // the id of the newest run
    replay:Run,          // the last Play of the user after it stopped, with its history (play_review)
    paused_view:core.View, // what the camera of the game saw at the tick a Play the user paused is at (view_write)
    watch:Watch,
    edit_orbit:Orbit,
    edit_selection:history.Selection, // that of the document while the editor shows a game
    recovery:Recovery,
    events:platform.Crash_Events, // what the crash report names before a fault (events.odin)
    events_turns:u64,             // the turns of the history whose steps were noted
    editor_world:rawptr,
    mode:Mode,
    edit_relative_mouse:bool,
    play_input_released,play_capture_click:bool,
    play_stepped:bool, // paused by play.step or play.record: the viewport keeps the view of the game
    camera_run:Camera_Preview_Run,
    edit_layout:Layout,
    edit_chat_open,play_chat_open,play_chat_input_released:bool,
    requests:Requests,
    project_root:string, // absolute, with forward slashes
    engine_root:string,  // empty when unknown: Build cannot run
    program:string,      // the executable it started from, as named then, with forward slashes: a build that moves the running binaries aside (build.engine_unlock) leaves the new ones there
    engine_stamp:string, // of the binaries it started from (build.engine_stamp_of): a build of the engine afterwards changes the one beside them
    assets_root:string,
    has_project:bool,    // the folder has a project.mirai
    settings_unsaved:bool, // a setting changed that the file of its layer does not have yet
    settings_layer:project.Settings_Layer, // the one the settings dialog edits
    settings_engine:[]project.Setting,     // the settings dialog: the values of the code and of the file of the engine (settings.odin)
    settings_plugins:Settings_Plugins,     // the settings dialog: the plugins the project can activate (settings.odin)
    settings_project:Settings_Project,     // the settings dialog: project.mirai as it edits it (project_settings.odin)
    plugins_git:Plugins_Git,               // plugins from git and the catalog: what git does for them (plugins_git.odin)
    settings_dialog:Settings_Dialog,       // what the settings dialog shows: its category, section and search
    headless:bool,
    args:[dynamic]string, // what a restart passes on besides the scene
    gpu_lost_before:string, // --gpu-lost: what stopped the GPU of the editor that started this one
    ready_ns:u64,           // platform.clock_ns when open finished
    gpu_failure:Gpu_Failure_Reaction, // what the editor did once its GPU stopped working (gpu_failure.odin)
    open_path:[1024]u8,open_length:int,
    open_confirmed:bool, // the scene of open_path replaces the open one: the question was answered
    frame:u64,
    quit:bool,
    frames:int,          // frames to run before it ends; 0: until it is asked to
    capture:string,      // a PNG of the last frame written when it ends
    view_cut:bool,       // the World shown changed: the history of the image goes
    studio_shown:bool,   // the renderer has the studio light in place of the sun and the sky of the world
    recording:[2]i32,    // pixels of the frames play.record draws while it records; zero: none
    play_strip:Timeline, // of the past of the Play of the user (play_history_bar)
    history_seek:u64,    // the tick the strip asked to go back to, plus one; 0: none
    history_playback:History_Playback,
    play_asked:scene.Play_Origin, // where Play from here puts player 1; the next play_start takes it
    toast:[TOAST_BYTES]u8,toast_length:int,
    toast_seconds:f32,
    id_state:u64,        // of the ids given to new entities
    selection:^history.Selection,
    copied:[dynamic]base.Entity_Id, // by Copy: the ids of the roots that Paste duplicates
    edits:^history.Edits,
    document:^Document,
    documents:[dynamic]Document_Tab,
    active_document,document_request:int,
    asset_documents:[dynamic]Asset_Document,
    asset_shown:int,   // the asset document in front of the scenes, as its index+1; 0: the scene
    asset_request:int,
    viewport:^Viewport,
    gui:^Editor_Ui,
    console:^Console,
    build:^Build_State,
    picker:^Picker,
    outliner:^Outliner,
    inspector:^Inspector,
    content:^Content,
    dropped:Asset_Drop, // what a plugin takes (asset_drop_take)
    heard:eaudio.Voice, // what Play sound of the content browser or of Details, or audio.play, plays
    heard_sound:eaudio.Audio_Source, // as it was set when it started, or last changed
    materials:^Materials,
    thumbnails:^Thumbnails,
    graphics:^Graphics,
    preferences:^Preferences,
    importer:^Importer,
    finder:^Finder,
    ai:^Ai,
    play_players:^Play_Players,
    play_history:^Play_History,
    processes:^Player_Processes,
    view_modes:^View_Modes,
    panels:^Project_Panels,
    git:^Git,
    projects:^Projects,
    profiles:Profiles,
}

// The World the editor shows and edits this frame: that of the run of the
// user while it plays, or the one being watched. The runs of agents are shown
// only while they are watched.
shown_world :: proc(s:^Session) -> core.World_Ref {
    if s.mode==.Watch {
        if w:=watch_world(s);w!=nil {return core.world_ref(w,s.info)}
        return core.world_ref(s.edit_world,s.info)
    }
    if r:=run_find(s,0);r!=nil && s.mode!=.Edit {return core.world_ref(r.world,s.info)}
    return core.world_ref(s.edit_world,s.info)
}

// The World of the document: what undo, scenes and Build work on.
edited_world :: proc(s:^Session) -> core.World_Ref {return core.world_ref(s.edit_world,s.info)}

// The world an edit writes: the document inside a transaction, which a call
// of the API holds on it whatever plays, and otherwise what the view shows.
editing_world :: proc(s:^Session) -> core.World_Ref {
    if s.edits!=nil && s.edits.open {return edited_world(s)}
    return shown_world(s)
}

playing :: proc "contextless" (s:^Session) -> bool {return s.mode!=.Edit}

// The selection of the document: the one in sight in Edit, the one kept for
// Stop while the editor shows a game. Edits of the document go with it.
document_selection :: proc(s:^Session) -> ^history.Selection {return &s.edit_selection if playing(s) else s.selection}

// The run of an owner: the user (0) or an AI task. nil without one.
run_find :: proc "contextless" (s:^Session,owner:int) -> ^Run {return run_player(s,owner,0)}

// A run of an owner by player: 0 is its run, the others join the game of it on the network.
run_player :: proc "contextless" (s:^Session,owner,player:int) -> ^Run {
    for &r in s.runs {
        if r.world!=nil && r.owner==owner && r.player==player {return &r}
    }
    return nil
}

// What a new run asks of its world before its first tick: how many players
// sit at it (0: what the scene says).
run_configure :: proc(s:^Session,r:^Run,players:int) {
    if run:=core.world_storage_of(run_ref(s,r),input.Run_Players);run!=nil {run.count=players}
}

// The World of a run; none without one.
run_ref :: proc(s:^Session,r:^Run) -> core.World_Ref {
    if r==nil {return {}}
    return core.world_ref(r.world,s.info)
}

// The run whose World this is, shown or not.
run_of_world :: proc "contextless" (s:^Session,world:rawptr) -> ^Run {
    for &r in s.runs {
        if world!=nil && r.world==world {return &r}
    }
    return nil
}

// Some run exists, of the user or of an agent.
running :: proc "contextless" (s:^Session) -> bool {
    for r in s.runs {if r.world!=nil {return true}}
    return false
}

// Ends every run, and the last Play kept: the document they copied is about to change.
runs_stop :: proc(s:^Session) {
    if s.watch.task!=0 {watch_stop(s)}
    play_stop(s,true)
    for &r in s.runs {
        if r.world!=nil {run_free(s,&r)}
    }
    replay_free(s)
}

// One line at the bottom of the window for a while.
notify :: proc(s:^Session,text:string) {
    s.toast_length=copy(s.toast[:],text)
    s.toast_seconds=TOAST_SECONDS
}

// What the editor is doing, for whoever drives it: an agent, a test.
Status :: struct {
    mode:Mode,
    document:string,  // path of the scene; empty for one never saved
    dirty:bool,
    entities:int,     // alive in the World shown
    selected:int,
    active:core.Entity,
    undo,redo:int,    // steps the user can undo and redo
    building:bool,
    build:Build_Phase,
    fps:f32,
    frame:u64,
}

status :: proc(s:^Session) -> (st:Status) {
    st.mode=s.mode
    st.document=document_path(s.document)
    st.dirty=document_dirty(s)
    st.entities=core.world_entities(shown_world(s)).alive
    st.selected=len(s.selection.entities)
    st.active=history.selection_active(s.selection)
    st.undo,st.redo=history.edits_undo_count(s.edits),history.edits_redo_count(s.edits)
    st.building=s.build.phase==.Running
    st.build=s.build.phase
    st.fps,st.frame=s.app.stats.fps,s.frame
    return
}

// Writes the last frame drawn as a PNG, with the UI. Between frames, or from
// a step: it is the frame that was on screen.
capture :: proc(s:^Session,path:string) -> bool {return host.app_capture(s.app,path)}

// The main of the editor of a project: open, a frame after another until
// it ends, close.
run :: proc(info:^core.World_Info,args:[]string) -> int {
    s,code:=open(info,args)
    if s==nil {return code}
    previous:=context.logger
    context.logger=console_logger(s.console,previous)
    gpu_failure_notify(s)
    for advance(s) {}
    context.logger=previous
    next:os.Process
    starts:=s.projects!=nil && s.projects.starts
    if starts {next=s.projects.started}
    code=close(s)
    // The editor it started writes to the same terminal: mirai edit ends with it.
    if starts {
        if state,error:=os.process_wait(next);error==nil {code=state.exit_code}
    }
    return code
}

// The application, its Worlds and the scene the arguments ask for. nil, with
// the exit code, when the editor cannot start. Whoever drives the frames
// (run, a test, a host that steps it) calls advance and then close.
open :: proc(info:^core.World_Info,args:[]string) -> (s:^Session,code:int) {
    options,understood:=options_read(args)
    if !understood {
        fmt.eprintln(USAGE_TEXT)
        return nil,EDITOR_USAGE
    }
    root:=project.path_absolute(options.project!=""?options.project:".",context.temp_allocator)
    engine:=project.engine_root_find(options.engine,context.temp_allocator)
    assets:=project.path(root,ASSETS_FOLDER,allocator=context.temp_allocator)
    if !os.is_dir(assets) {_=os.make_directory_all(assets)}

    window:=platform.Window_Desc{
        title="Mirai",chrome=.Custom,size={i32(options.width),i32(options.height)},hidden=options.hidden,density=options.density,
        maximized=!options.headless && options.width==0 && options.height==0,
    }
    if options.launcher && options.width==0 && options.height==0 {window.size,window.fixed_size,window.maximized=PROJECTS_WINDOW,true,false}
    mounts:=make([dynamic]asset.Registry_Mount,context.temp_allocator)
    has_project:=false
    if p,error:=project.open(root,engine,context.temp_allocator);error.code==.None {
        has_project=true
        append(&mounts,..host.project_asset_mounts(&p,context.temp_allocator))
        if title:=project.window_title(&p.manifest);title!="" {window.title=strings.clone(title,context.temp_allocator)}
    }
    append(&mounts,asset.Registry_Mount{folder=project.path(engine,EDITOR_ASSETS,allocator=context.temp_allocator),prefix=EDITOR_ASSETS_PREFIX})
    windowed:=!options.headless
    app,app_error:=host.app_create({
        info=info,root=root,engine_root=engine,threads=jobs.THREADS_AUTO,
        window=windowed,gpu=!options.no_gpu,gpu_validation=options.validation,
        window_desc=window,vsync=windowed,fixed_dt=windowed?0:HEADLESS_DT,
        // Without a window the mixer plays to nowhere, in real time: what play.record mixes is there.
        audio=windowed || !options.no_gpu?.Device:.None,audio_driver=windowed?"":"dummy",
        assets_root=os.is_dir(assets)?assets:"",assets_cache=project.cache_path(root,project.REGISTRY_CACHE,allocator=context.temp_allocator),
        animation_cache=project.cache_path(root,project.ANIMATION_CACHE,allocator=context.temp_allocator),
        asset_mounts=mounts[:],shaders_root=root,
    })
    if app==nil {
        fmt.eprintfln("mirai: the editor could not start: %v",app_error)
        return nil,EDITOR_FAILED
    }
    edit_world:=host.app_world_create(app)
    editor_world:=host.app_editor_create(app)
    if editor_world!=nil {s=core.world_storage_of(core.world_ref(editor_world,info,.Editor),Session)}
    if edit_world==nil || s==nil || !session_init(s,app,edit_world,editor_world) {
        fmt.eprintln("mirai: the editor worlds could not be created: generate the project again")
        if editor_world!=nil {host.app_editor_free(app,editor_world)}
        if edit_world!=nil {host.app_world_free(app,edit_world)}
        host.app_destroy(app)
        return nil,EDITOR_FAILED
    }
    s.project_root=strings.clone(root)
    s.engine_root=strings.clone(engine)
    program,_:=os.get_executable_path(context.temp_allocator)
    s.program,_=strings.replace_all(program,"\\","/")
    s.engine_stamp=engine_stamp_here(s)
    s.assets_root=strings.clone(assets)
    s.has_project=has_project
    if has_project {s.build.sources=code_fingerprint(root)}
    s.headless=options.headless
    s.frames=options.frames
    s.capture=strings.clone(options.capture)
    s.gpu_lost_before=strings.clone(options.gpu_lost)
    // build.status of the editor that restarted on a Build says it ended, as the one before would have.
    if options.built {s.build.phase=.Built}
    for arg in options_passed(args) {append(&s.args,strings.clone(arg))}
    preferences_open(s,options)
    events_open(s)
    s.projects.launcher=options.launcher
    if options.launcher {projects_show(s)} else if has_project && !options.headless {projects_remember(s)}
    if options.git_init && has_project {git_init_later(s,options.git_remote,options.git_lfs)}

    if options.view!="" {view_parse(&s.viewport.orbit,options.view)}
    scene:=options.scene
    if scene=="" && options.restore=="" && has_project {scene=project.start_scene(root,context.temp_allocator)}
    switch {
    case options.documents!="":
        if why:=documents_restore(s,options.documents);why!="" {log.errorf("The document tabs could not all be restored; the recovery files were kept: %s",why)}
    case options.restore!="":
        if error:=document_restore(s,options.restore,options.scene,options.dirty);error!=.None {
            log.errorf("the restarted scene could not be read: %s",document_error_text(error))
        }
        _=os.remove(options.restore)
    case scene!="":
        if error:=scene_open(s,scene);error!=.None {
            fmt.eprintfln("mirai: could not open the scene %s: %s",scene,document_error_text(error))
            if options.scene!="" {
                close(s)
                return nil,EDITOR_SCENE
            }
        }
    }
    if options.select!="" {select_ids(s,options.select)}
    if options.restore=="" {recovery_open(s)}
    if !services_open(s,options) && options.headless && options.frames==0 {
        close(s)
        return nil,EDITOR_API
    }
    s.ready_ns=platform.clock_ns()
    return s,EDITOR_OK
}

// One frame: the game loop of a Play, the loop of the editor over the World
// shown, the draw, and what has to happen between frames. False once the
// editor ends.
advance :: proc(s:^Session) -> bool {
    app:=s.app
    if api_idle(s) {return !s.quit}
    // Behind other windows, out of Play and without an agent driving it, the editor runs slow.
    background:=u32(0) if playing(s) || api_active(s) else EDITOR_BACKGROUND_FPS
    if app.platform.background!=background {platform.set_background(app.platform,background)}
    if !host.app_frame_begin(app) {
        app.quit=false
        quit_request(s)
    }
    play_input_update(s)
    camera_preview_frame(s)
    player_processes_input(s)
    app.game_input_excluded=run_find(s,0)!=nil?{.F1}:{}
    editor_input:=app.ui_input
    if (s.mode==.Play || simulating(s)) && app.game_input_blocked {
        app.ui_input={size=editor_input.size,scale=editor_input.scale,safe=editor_input.safe,dt=editor_input.dt,pointer=editor_input.pointer,pointer_absent=true,view=editor_input.view}
    }
    if playing(s) {app.ui_input.safe[1]=max(app.ui_input.safe[1],s.gui.rects.bar.h)}
    game_frame(s)
    app.ui_input=editor_input
    // The Tab of the game does not move the focus of the editor's panels.
    if s.mode==.Play {
        app.ui_input.keys_down-={.Tab}
        app.ui_input.keys_pressed-={.Tab}
        app.ui_input.keys_repeated-={.Tab}
    }
    if simulating(s) {
        platform.window_set_relative_mouse(app.platform,false)
        app.extras.layer_count=0
    }
    // A player of another process that has the input keeps the mouse it asked for.
    if s.play_input_released && !player_processes_captured(s) {platform.window_set_relative_mouse(app.platform,false)}
    // A document in front of the scene covers it: it is not drawn, nor given
    // to the renderer.
    app.ui_only=player_processes_view(s) || scene_covered(s)
    shown:=shown_world(s).data
    host.app_editor_frame(app,shown,s.editor_world,shown!=s.edit_world)
    if simulating(s) {host.app_views_set(app,nil,nil,0)}
    host.app_frame_end(app)
    between_frames(s)
    gpu_failure_react(s)
    services_poll(s)
    if s.frames>0 && int(s.frame)>=s.frames {s.quit=true}
    return !s.quit
}

// Ends the editor: the capture the arguments asked for, the Worlds and the
// application. Returns the exit code.
close :: proc(s:^Session) -> int {
    code:=EDITOR_OK
    if s.capture!="" && !host.app_capture(s.app,s.capture) {
        fmt.eprintfln("mirai: could not write %s",s.capture)
        code=EDITOR_CAPTURE
    }
    if s.gpu_failure==.Ended {code=EDITOR_GPU_LOST}
    runs_stop(s)
    tools_release(s)
    preferences_close(s)
    services_close(s)
    // A normal end leaves no chain; one for the GPU kept what it needs.
    recovery_chains_close(s,s.gpu_failure!=.Ended)
    if s.recovery.assets_owned {os.remove_all(recovery_assets_own(s))}
    recovery_log_destroy(s)
    events_close(s)
    app,edit_world,editor_world:=s.app,s.edit_world,s.editor_world
    session_destroy(s)
    host.app_world_free(app,edit_world)
    host.app_editor_free(app,editor_world)
    host.app_destroy(app)
    return code
}

// The game loops of the runs: that of the user every frame while it plays,
// or one tick when a paused one is stepped; that of each agent one tick when
// it steps it, after the user's, so the input of the window reaches only the
// game the user plays. While the editor watches another run, the game of the
// user goes on as it was, without input. What a run that is not shown adds to
// the frame (layers of its UI, views) is dropped. A game of the user that
// quits stops the Play.
game_frame :: proc(s:^Session) {
    app:=s.app
    phases:=host.ALL_PHASES-{.Render}
    shown:=shown_world(s).data
    if r:=run_find(s,0);r!=nil {
        mode:=s.mode==.Watch?s.watch.from:s.mode
        if mode==.Simulate || mode==.Simulation_Paused {app.has_script_input=false;app.script_input={};app.script_frame_input={};r.has_input=false}
        kept:=extras_mark(app)
        switch mode {
        case .Edit,.Watch:
        case .Play,.Simulate:
            history_before(s,r)
            run_input_give(s,r)
            record:host.Frame_Record
            host.app_game_frame(app,r.world,phases,record=&record)
            history_frame(s,r,&record)
        case .Paused,.Simulation_Paused:
            stepped:=r.step
            game_tick(s,r,phases)
            if !stepped && mode==.Paused && s.play_stepped {game_ui_frame(s,r)}
        }
        if r.world!=shown {extras_drop(app,kept)}
        if app.quit {
            app.quit=false
            r.quit_asked=true
            if s.mode!=.Watch && !r.quit_held {s.requests+={.Stop}}
        }
    }
    blocked:=app.game_input_blocked
    app.game_input_blocked=true
    for &r in s.runs {
        if r.world==nil || r.owner==0 {continue}
        kept:=extras_mark(app)
        game_tick(s,&r,phases)
        if app.quit {r.quit_asked,app.quit=true,false}
        if r.world!=shown {extras_drop(app,kept)}
    }
    app.game_input_blocked=blocked
    // A game an agent plays that asks to quit ends where it is.
    app.quit=false
}

@(private)
Extras_Mark :: struct {layers,panels,debug,instances,views:int}

@(private)
extras_mark :: proc(app:^host.App) -> Extras_Mark {
    e:=&app.extras
    return {e.layer_count,e.panel_count,e.debug_count,len(e.instances),app.view_count}
}

@(private)
extras_drop :: proc(app:^host.App,mark:Extras_Mark) {
    e:=&app.extras
    e.layer_count,e.panel_count,e.debug_count=mark.layers,mark.panels,mark.debug
    resize(&e.instances,mark.instances)
    app.view_count=mark.views
}

// The input a step gave to a run, for the next frame of its game loop alone:
// with its pointer, its gamepads and its device in place of the window's.
@(private)
run_input_give :: proc(s:^Session,r:^Run) {
    if !r.has_input {return}
    host.app_input_add(s.app,r.input,devices=true)
    r.input,r.has_input={},false
}

// The UI of the game of a turn sees only what its steps give, never the
// window of the user; that of the user in the frames a step gave input to, and
// from the moment one placed the pointer.
@(private)
run_ui_scripted :: proc "contextless" (r:^Run) -> bool {return r.owner!=0 || r.pointer_set || r.has_input}

// What the UI of the game of a run sees in its next frame: what its steps
// gave, over the surface of the window.
@(private)
run_ui_input :: proc "contextless" (r:^Run,window:ui.Input) -> (input:ui.Input) {
    input=r.ui
    input.size,input.scale,input.safe,input.dt=window.size,window.scale,window.safe,window.dt
    input.pointer,input.pointer_absent=r.pointer,!r.pointer_set
    return
}

// Between the frames of an editor driven by the API, which draws none of its
// own, the network of every run goes on as in a paused game: a player that
// joins in the meantime is answered.
@(private)
runs_pump :: proc(s:^Session) {
    p:=providers(s)
    if !p.plays || p.play.pump==nil {return}
    for &r in s.runs {
        if r.world!=nil {p.play.pump(run_ref(s,&r),s.app)}
    }
}

// One tick of a run that only advances when it is stepped. Between steps its
// network goes on.
@(private)
game_tick :: proc(s:^Session,r:^Run,phases:core.Phases) {
    app:=s.app
    if !r.step {
        if p:=providers(s);p.plays && p.play.pump!=nil {p.play.pump(run_ref(s,r),app)}
        return
    }
    r.step=false
    history_before(s,r)
    scripted:=run_ui_scripted(r)
    run_input_give(s,r)
    record:host.Frame_Record
    window:=app.ui_input
    if scripted {app.ui_input=run_ui_input(r,window)}
    if r.frame_dt>0 {
        // A frame of a recording: what the window does reaches no game.
        blocked:=app.game_input_blocked
        app.game_input_blocked=true
        host.app_game_frame(app,r.world,phases,dt=r.frame_dt,record=&record)
        app.game_input_blocked=blocked
        r.frame_dt=0
    } else {host.app_game_frame(app,r.world,phases,step=true,record=&record)}
    app.ui_input=window
    ui.input_next_frame(&r.ui)
    app.has_script_input,app.script_input,app.script_frame_input=false,{},{}
    if r.owner==0 {platform.window_set_relative_mouse(app.platform,false)}
    history_frame(s,r,&record)
}

// A frame of the interfaces of a game that play.step holds paused, between its
// steps: they are drawn and route the pointer the steps left, as in the tick
// that built them, while no tick runs and the window reaches no game.
@(private)
game_ui_frame :: proc(s:^Session,r:^Run) {
    app:=s.app
    window,blocked:=app.ui_input,app.game_input_blocked
    app.ui_input=run_ui_input(r,window)
    app.game_input_blocked=true
    host.app_game_frame(app,r.world,{.Ui},dt=0)
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    app.ui_input=window
    app.game_input_blocked=blocked
}

// What replaces a World or ends the editor, and the jobs that run beside it.
@(private)
between_frames :: proc(s:^Session) {
    s.frame+=1
    thumbnail_scene_capture(s)
    thumbnail_picture_draw(s)
    asset_document_between(s)
    build_poll(s)
    import_poll(s)
    git_poll(s)
    projects_poll(s)
    plugins_git_poll(s)
    requests_run(s)
    play_history_seek(s)
    watch_update(s)
    play_plugin_poll(s)
    recovery_update(s)
    asset_documents_retain(s)
}

@(private)
requests_run :: proc(s:^Session) {
    requests:=s.requests
    s.requests-={.Play,.Simulate,.Apply_Simulation,.Stop,.Pause,.Resume,.Resume_Here,.New,.Open,.Restart,.Quit,.Recover,.Discard_Recovery,.Document_Switch,.Document_Close,.Document_Discard,.Asset_Switch,.Asset_Close,.Asset_Discard,.Quit_Check,.Camera_Preview,.Camera_Keep,.Camera_Discard}
    if .Recover in requests {
        if _,why:=recovery_resolve(s,false);why!="" {notify(s,why)}
    }
    if .Discard_Recovery in requests {
        if _,why:=recovery_resolve(s,true);why!="" {notify(s,why)}
    }
    if .Stop in requests {
        switch {
        case s.mode==.Watch:   watch_stop(s)
        case playing(s):       play_stop(s)
        case play_plugin_active(s): play_plugin_stop(s)
        }
    }
    if .Apply_Simulation in requests && simulating(s) {simulation_apply_selection(s)}
    if .Camera_Keep in requests {camera_preview_end(s,true)}
    if .Camera_Discard in requests {camera_preview_end(s,false)}
    if .Camera_Preview in requests && !playing(s) && !camera_preview_start(s,s.camera_run.request) {notify(s,"The camera could not be previewed")}
    if .Play in requests && playing(s) {s.play_asked={}}
    if .Play in requests && !playing(s) && !play_build_first(s,{request=true}) && !play_start(s) {notify(s,"The game could not start")}
    if .Simulate in requests && !playing(s) && !simulation_start(s) {notify(s,"The simulation could not start")}
    if .Pause in requests && (s.mode==.Play || s.mode==.Simulate) {play_pause(s,true)}
    if .Resume in requests && play_paused(s) {play_pause(s,false)}
    if .Resume_Here in requests && play_paused(s) {play_pause(s,false,here=true)}
    if .New in requests {
        runs_stop(s)
        asset_document_activate(s,-1)
        scene_new(s)
    }
    if .Open in requests {open_run(s)}
    if .Document_Switch in requests {
        asset_document_activate(s,-1)
        document_activate(s,s.document_request)
    }
    if .Document_Close in requests {document_close(s,s.document_request)}
    if .Document_Discard in requests {document_close_active(s)}
    if .Asset_Switch in requests {asset_document_activate(s,s.asset_request)}
    if .Asset_Close in requests {asset_document_close(s,s.asset_request)}
    if .Asset_Discard in requests {asset_document_close_now(s,s.asset_request)}
    asset_documents_prune(s)
    if .Quit_Check in requests {documents_quit_next(s)}
    if .Restart in requests {restart(s,{"--built"})}
    if .Quit in requests {s.quit=true}
}

// Opens the scene of open_path, or asks first what the open one would lose.
open_run :: proc(s:^Session) {
    path:=string(s.open_path[:s.open_length])
    scene:=document_scene_tab(s)
    // Another scene takes the place of the one open: who would lose what
    // they do, or what is unsaved, is asked about first.
    replaces:=scene>=0 && !path_is_prefab(path) && !document_holds_file(s,path)
    if replaces && !s.open_confirmed {
        asset_document_activate(s,-1)
        document_activate(s,scene)
        assets:=document_closing_assets(s)
        if document_dirty(s) || len(assets)>0 || scene_switch_interrupts(s) || !collab_can_open(s) {
            confirm_open(s,.Open_Scene,assets)
            return
        }
    }
    s.open_confirmed=false
    if replaces && !collab_can_open(s) {collab_leave(s)}
    runs_stop(s)
    asset_document_activate(s,-1)
    if error:=document_open_tab(s,path);error!=.None {notify(s,fmt.tprintf("%s: %s",filepath.base(path),document_error_text(error)))}
}

// A run of an owner on a copy of the edited World, with its own clock. The
// run of the user is shown: the editor plays it and Stop restores the editing
// view and selection. The run of an agent is not: the editor stays as it is
// and the run advances only when that agent steps it. True when the owner has
// its run; the user can only have one at a time.
play_start :: proc(s:^Session,simulate:=false,owner:int=0) -> bool {
    asked:=owner==0 && !simulate?s.play_asked:{}
    if owner==0 {s.play_asked={}}
    if run_find(s,owner)!=nil {return owner!=0}
    host.load_open(s.app,.Play,document_path(s.document))
    stopping:=host.load_phase_begin(s.app,.Editor)
    if owner==0 && s.mode==.Watch {watch_stop(s)}
    if owner==0 && !simulate {replay_free(s)}
    // The game of the user is shown: the scene comes to the front.
    if owner==0 {asset_document_activate(s,-1)}
    if owner==0 {tools_release(s)}
    host.load_phase_end(s.app,stopping)
    waiting:=host.load_phase_begin(s.app,.Animations)
    play_animations_load(s,wait=true)
    host.load_phase_end(s.app,waiting)
    copying:=host.load_phase_begin(s.app,.World_Copy)
    r:=run_create(s,owner,0)
    entities:=core.world_entities(run_ref(s,r)).alive if r!=nil else 0
    host.load_phase_end(s.app,copying,entities)
    if r==nil {
        host.load_fail(s.app,.Play,"the document could not be copied: no room for another run, an edit was refused, or no memory")
        return false
    }
    defer host.load_ready(s.app,.Play,entities)
    if owner!=0 {
        log.info("Play of an agent")
        return true
    }
    // The players of Play share the screen , as many as the
    // selector says, and a plugin readies the world for its game.
    run_configure(s,r,s.play_players!=nil?s.play_players.players:PLAY_PLAYERS_DEFAULT.players)
    // Play starts with the environment that is on, not with the preview of a section.
    if preview:=core.world_storage_of(host.app_world_ref(s.app,r.world),erender.Environment_Preview);preview!=nil {preview^={}}
    // A body with no spawn point to appear at appears at the camera; player 1 where Play from here asked.
    if origin:=core.world_storage_of(host.app_world_ref(s.app,r.world),scene.Play_Origin);origin!=nil {origin^=asked.asked?asked:camera_origin(s)}
    starting:=host.load_phase_begin(s.app,.Plugins)
    if p:=providers(s);p.plays && p.play.play_begin!=nil {p.play.play_begin(s,r)}
    host.load_phase_end(s.app,starting)
    play_view_enter(s,simulate)
    s.mode=simulate?.Simulate:.Play
    log.info("Play")
    return true
}

// The .anim the edited world can play, directly or through its prefabs and other assets, start
// their first load; with wait, Play waits for them so that no entity of its world holds a rest
// pose while its .anim compresses (once per input: later ones come from the project cache).
play_animations_load :: proc(s:^Session,wait:bool) {
    ids:=make([dynamic]base.Asset_Id,context.temp_allocator)
    host.world_asset_ids(edited_world(s),&ids)
    animations:=make([dynamic]base.Asset_Id,context.temp_allocator)
    host.content_animations_start(s.app,ids[:],&animations)
    if wait {_=host.content_animations_pending(s.app,animations[:],wait=true)}
}

// The editor shows the run of the user: what Stop puts back is kept.
@(private)
play_view_enter :: proc(s:^Session,simulate:bool) {
    s.edit_orbit=s.viewport.orbit
    history.selection_set(&s.edit_selection,s.selection.entities[:])
    s.edit_relative_mouse=platform.window_relative_mouse(s.app.platform)
    s.play_input_released,s.play_capture_click,s.play_stepped=false,false,false
    if !simulate {
        s.edit_layout=s.gui.layout
        s.edit_chat_open=ai_chat_open(s.ai)
        s.gui.layout.left_open=false
        ai_chat_show(s.ai,false);ai_chat_focus(s.ai,false)
        s.play_chat_open,s.play_chat_input_released=false,false
        if s.gui.ctx!=nil {s.gui.ctx.edit={};ui.popup_close(s.gui.ctx)}
    }
    s.app.has_script_input,s.app.script_input,s.app.script_frame_input=false,{},{}
    s.view_cut=true
}

// The last Play of the user, kept after Stop, is shown again paused at the
// frame it was at: its past can be looked at and played on from there. False
// without one, or while the editor shows another game.
play_review :: proc(s:^Session) -> bool {
    if s.mode!=.Edit || s.replay.world==nil {return false}
    r:^Run
    for &place in s.runs {
        if place.world==nil {r=&place;break}
    }
    if r==nil {return false}
    asset_document_activate(s,-1)
    tools_release(s)
    r^=s.replay
    s.replay={}
    play_view_enter(s,false)
    platform.window_set_relative_mouse(s.app.platform,false)
    s.mode=.Paused
    r.history.held=true
    log.info("Play opened again")
    return true
}

// A new run of an owner, a copy of the edited World: nil without room or when the document cannot be copied.
run_create :: proc(s:^Session,owner,player:int) -> ^Run {
    r:^Run
    for &place in s.runs {
        if place.world==nil {r=&place;break}
    }
    if r==nil {return nil}
    if !history.edits_commit(s.edits,edited_world(s),s.selection) && s.edits.error!=.No_Change {notify(s,history.edits_error_text(s.edits.error));return nil}
    if !recovery_protect(s) {return nil}
    world:=host.app_world_create(s.app)
    if world==nil {return nil}
    // Physics takes the edits since the last frame as its own, or the copy reads them as written by another.
    simulation_settle(s,edited_world(s))
    if !s.info.copy(world,s.edit_world) {host.app_world_free(s.app,world);return nil}
    s.run_serial+=1
    r^={world=world,id=s.run_serial,owner=owner,player=player,document=history.edits_scene_state(s.edits)}
    return r
}

// Ends the run of the user and returns to Edit. A turn that began inside it
// and has no run of its own keeps it instead: the agent goes on playing that
// copy while the editor is back in Edit.
play_stop :: proc(s:^Session,force:=false) {
    r:=run_find(s,0)
    if r==nil {return}
    // The game of a plugin it served ends with it: its players are gone.
    if p:=providers(s);p.plays && p.play.play_end!=nil {p.play.play_end(s)}
    if !force {
        if owner:=play_heir(s);owner!=0 {
            r.owner=owner
            // Watching another, the view returns when the watch ends.
            if s.mode!=.Watch {play_view_restore(s)}
            log.info("Play left to an agent")
            return
        }
    }
    if s.mode!=.Watch {tools_release(s)}
    // A Play that kept its past stays, with its World, until the next Play;
    // its voices stop as those of a World that is freed.
    if (s.mode==.Play || s.mode==.Paused) && r.history!=nil && r.history.count>0 {
        eaudio.audio_release(host.app_world_storage(s.app,r.world,eaudio.Voices),s.app.mixer)
        replay_free(s)
        run_tell_ended(s,r)
        s.replay=r^
        r^={}
    } else {
        run_free(s,r)
    }
    if s.mode!=.Watch {play_view_restore(s)}
    log.info("Stop")
}

// Drops the last Play kept after Stop.
replay_free :: proc(s:^Session) {
    if s.replay.world!=nil {run_free(s,&s.replay)}
}

// Ends the runs of an AI task, which the editor does not show.
run_stop :: proc(s:^Session,owner:int) {
    if owner==0 {return}
    for &r in s.runs {
        if r.world!=nil && r.owner==owner {run_free(s,&r)}
    }
}

@(private)
run_free :: proc(s:^Session,r:^Run) {
    run_tell_ended(s,r)
    history_free(s,r)
    host.app_world_free(s.app,r.world)
    r^={}
}

// The agent that inherits a run the user leaves: a turn of this document that
// began inside it, has not ended and has no run of its own.
@(private)
play_heir :: proc(s:^Session) -> int {
    if s.mode==.Edit {return 0}
    for &task in ai_tasks(s.ai) {
        if task.play && !ai_task_finished(&task) && ai_task_current(s,&task) && run_find(s,task.id)==nil {return task.id}
    }
    return 0
}

// The editor returns to Edit: its layout, camera, selection and input.
@(private)
play_view_restore :: proc(s:^Session) {
    if s.mode==.Edit {return}
    if !simulating(s) {
        s.gui.layout=s.edit_layout
        ai_chat_show(s.ai,s.edit_chat_open);ai_chat_focus(s.ai,false)
        s.play_chat_open,s.play_chat_input_released=false,false
        if s.gui.ctx!=nil {s.gui.ctx.edit={};ui.popup_close(s.gui.ctx)}
    }
    tools_release(s)
    s.viewport.orbit=s.edit_orbit
    viewport_camera(s.viewport)
    history.selection_set(s.selection,s.edit_selection.entities[:])
    history.selection_clear(&s.edit_selection)
    platform.window_set_relative_mouse(s.app.platform,s.edit_relative_mouse)
    s.app.game_input_excluded={}
    s.app.has_script_input,s.app.script_input,s.app.script_frame_input=false,{},{}
    s.app.player_tile_count=0
    s.play_input_released,s.play_capture_click,s.play_stepped=false,false,false
    s.mode=.Edit
    s.view_cut=true
    history.selection_prune(s.selection,edited_world(s))
}

// Asks to end: with unsaved changes the editor asks first.
quit_request :: proc(s:^Session) {
    for &tab in s.documents {tab.quit_approved=false}
    s.requests+={.Quit_Check}
}

// The editor starts again on the library a Build left, with the scene as
// it is: written to a file the new one reads and removes. extra: arguments
// for the new one alone. False when this one goes on.
@(private)
restart :: proc(s:^Session,extra:[]string=nil) -> bool {
    exe:=s.program
    if exe=="" {
        notify(s,"The editor program could not be found")
        return false
    }
    runs_stop(s)
    tools_release(s)
    if !history.edits_commit(s.edits,edited_world(s),s.selection) && s.edits.error!=.No_Change {notify(s,history.edits_error_text(s.edits.error));return false}
    folder:=project.folder_path(s.project_root,.Generated,context.temp_allocator)
    _=os.make_directory_all(folder)
    file,kept:=documents_save_restart(s,folder)
    if !kept {
        notify(s,"The documents could not be kept: the editor goes on")
        return false
    }
    // The new editor reads them as this one leaves them.
    preferences_save(s)
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,exe,"--project",s.project_root,"--documents",file)
    for arg in s.args {append(&command,arg)}
    append(&command,..extra)
    process,error:=subprocess.start({command=command[:],stdin=os.stdin,stdout=os.stdout,stderr=os.stderr})
    if error!=nil {
        log.errorf("%s could not be started: %v",exe,error)
        notify(s,"The built editor could not be started")
        return false
    }
    session_record_follow(s,process.pid)
    log.infof("restarting with %s",exe)
    s.quit=true
    return true
}

// The Ids of the selected entities, as --select takes them.
@(private)
selected_ids :: proc(s:^Session) -> string {
    w:=edited_world(s)
    b:=strings.builder_make(context.temp_allocator)
    for e in s.selection.entities {
        id,_:=entity_get(w,e,core.Id)
        if id.value==0 {continue}
        if strings.builder_len(b)>0 {strings.write_byte(&b,',')}
        buffer:[16]u8
        strings.write_string(&b,base.entity_id_format(id.value,buffer[:]))
    }
    return strings.to_string(b)
}

// Selects the entities whose Ids a list names.
@(private)
select_ids :: proc(s:^Session,text:string) {
    es:=core.world_entities(edited_world(s))
    picked:=make([dynamic]core.Entity,context.temp_allocator)
    rest:=text
    for part in strings.split_iterator(&rest,",") {
        id,ok:=base.entity_id_parse(strings.trim_space(part))
        if e:=core.entity_of(es,id);ok && e!=core.NONE {append(&picked,e)}
    }
    history.selection_set(s.selection,picked[:])
}

@(private)
session_init :: proc(s:^Session,app:^host.App,edit_world,editor_world:rawptr) -> bool {
    s.app,s.info=app,app.info
    s.edit_world,s.editor_world=edit_world,editor_world
    s.id_state=platform.clock_ns()~0x6d697261695f6964
    if !session_bind(s) {return false}
    viewport_init(s.viewport)
    if !gui_init(s.gui,app) {return false}
    history.edits_reset(s.edits,edited_world(s))
    document_reset(s)
    documents_ensure(s)
    return true
}

// The storages of the editor the session reaches, where the Editor_World holds them.
@(private)
session_bind :: proc(s:^Session) -> bool {
    ref:=core.world_ref(s.editor_world,s.info,.Editor)
    s.selection=core.world_storage_of(ref,history.Selection)
    s.edits=core.world_storage_of(ref,history.Edits)
    s.document=core.world_storage_of(ref,Document)
    s.viewport=core.world_storage_of(ref,Viewport)
    s.gui=core.world_storage_of(ref,Editor_Ui)
    s.console=core.world_storage_of(ref,Console)
    s.build=core.world_storage_of(ref,Build_State)
    s.picker=core.world_storage_of(ref,Picker)
    s.outliner=core.world_storage_of(ref,Outliner)
    s.inspector=core.world_storage_of(ref,Inspector)
    s.content=core.world_storage_of(ref,Content)
    s.materials=core.world_storage_of(ref,Materials)
    s.thumbnails=core.world_storage_of(ref,Thumbnails)
    s.graphics=core.world_storage_of(ref,Graphics)
    s.preferences=core.world_storage_of(ref,Preferences)
    s.importer=core.world_storage_of(ref,Importer)
    s.finder=core.world_storage_of(ref,Finder)
    s.ai=core.world_storage_of(ref,Ai)
    s.play_players=core.world_storage_of(ref,Play_Players)
    s.play_history=core.world_storage_of(ref,Play_History)
    s.processes=core.world_storage_of(ref,Player_Processes)
    s.view_modes=core.world_storage_of(ref,View_Modes)
    s.panels=core.world_storage_of(ref,Project_Panels)
    s.git=core.world_storage_of(ref,Git)
    s.projects=core.world_storage_of(ref,Projects)
    return !(s.selection==nil || s.edits==nil || s.document==nil || s.viewport==nil || s.gui==nil || s.console==nil || s.build==nil || s.picker==nil || s.outliner==nil || s.inspector==nil || s.content==nil || s.materials==nil || s.thumbnails==nil || s.graphics==nil || s.preferences==nil || s.importer==nil || s.finder==nil || s.ai==nil || s.play_players==nil || s.play_history==nil || s.processes==nil || s.view_modes==nil || s.panels==nil || s.git==nil || s.projects==nil)
}

// What Session holds that core.value_free cannot free: the arenas of the
// captures and the block of the settings dialog, whose names and values point
// into it. Runs as well after session_destroy.
session_free :: proc(s:^Session) {
    profiles_destroy(s)
    settings_engine_free(s)
    core.value_free(s,type_info_of(Session))
}

@(private)
session_destroy :: proc(s:^Session) {
    profiles_destroy(s)
    asset_documents_free(s)
    documents_free(s)
    play_plugin_stop(s)
    player_launch_stop(s)
    player_processes_close(s)
    build_cancel(s)
    import_end(s)
    projects_cancel(s)
    plugins_git_free(s)
    ai_destroy(s)
    thumbnails_destroy(s)
    gui_destroy(s.gui)
    document_previous_free(s.document)
    picker_clear(s.picker)
    history.edits_free(s.edits)
    delete(s.edit_selection.entities)
    s.edit_selection={}
    delete(s.copied)
    s.copied=nil
    console_destroy(s.console)
    settings_engine_free(s)
    delete(s.project_root);delete(s.engine_root);delete(s.program);delete(s.engine_stamp);delete(s.assets_root);delete(s.capture);delete(s.gpu_lost_before)
    for arg in s.args {delete(arg)}
    delete(s.args)
    s.project_root,s.engine_root,s.program,s.assets_root,s.capture,s.gpu_lost_before,s.args="","","","","","",{}
}

@(private)
options_read :: proc(args:[]string) -> (o:Options,ok:bool) {
    for i:=0;i<len(args);i+=1 {
        value :: proc(args:[]string,i:^int) -> (string,bool) {
            if i^+1>=len(args) {return "",false}
            i^+=1
            return args[i^],true
        }
        number :: proc(args:[]string,i:^int) -> (n:int,ok:bool) {
            text:=value(args,i) or_return
            n=strconv.parse_int(text,10) or_return
            return n,n>0
        }
        switch args[i] {
        case "--project":    o.project=value(args,&i) or_return
        case "--scene":      o.scene=value(args,&i) or_return
        case "--engine":     o.engine=value(args,&i) or_return
        case "--capture":    o.capture=value(args,&i) or_return
        case "--restore":    o.restore=value(args,&i) or_return
        case "--documents":  o.documents=value(args,&i) or_return
        case "--gpu-lost":   o.gpu_lost=value(args,&i) or_return
        case "--built":      o.built=true
        case "--view":       o.view=value(args,&i) or_return
        case "--select":     o.select=value(args,&i) or_return
        case "--dirty":      o.dirty=true
        case "--frames":     o.frames=number(args,&i) or_return
        case "--width":      o.width=number(args,&i) or_return
        case "--height":     o.height=number(args,&i) or_return
        case "--density":
            text:=value(args,&i) or_return
            density,parsed:=strconv.parse_f32(text)
            if !parsed || !(density>=0.5 && density<=4) {return o,false}
            o.density=density
        case "--headless":   o.headless=true
        case "--hidden":     o.hidden=true
        case "--preferences": o.preferences=true
        case "--no-gpu":     o.no_gpu=true
        case "--validation": o.validation=true
        case "--api-port":
            text:=value(args,&i) or_return
            port,parsed:=strconv.parse_int(text,10)
            if !parsed || port<0 || port>65535 {return o,false}
            if port==0 {o.api_port_any=true} else {o.api_port=port}
        case "--no-api":     o.no_api=true
        case "--name":       o.name=value(args,&i) or_return
        case "--launcher":   o.launcher=true
        case "--git-init":   o.git_init=true
        case "--git-lfs":    o.git_lfs=true
        case "--git-remote": o.git_remote=value(args,&i) or_return
        case "--join":       o.join=value(args,&i) or_return
        case "--share":
            o.share=-1
            if i+1<len(args) {
                if port,numeric:=strconv.parse_int(args[i+1],10);numeric && port>0 && port<65536 {
                    o.share=port
                    i+=1
                }
            }
        case:                return o,false
        }
    }
    if o.no_gpu && !o.headless || o.density>0 && !o.headless {return o,false}
    return o,true
}

// The arguments a restart gives the new editor again: those that are not
// about the scene, the project or the frames to run.
@(private)
options_passed :: proc(args:[]string) -> []string {
    kept:=make([dynamic]string,context.temp_allocator)
    for i:=0;i<len(args);i+=1 {
        switch args[i] {
        case "--validation","--no-api","--headless","--no-gpu","--hidden","--preferences": append(&kept,args[i])
        case "--engine","--width","--height","--density","--api-port","--name":
            if i+1<len(args) {append(&kept,args[i],args[i+1])}
            i+=1
        case "--project","--scene","--restore","--documents","--gpu-lost","--view","--select","--frames","--capture","--join":
            i+=1
        }
    }
    return kept[:]
}

