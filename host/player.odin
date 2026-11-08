package host

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:platform"
import "mirai:project"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:ui"
import stbi "vendor:stb/image"

// The player: opens a project, loads its start scene into the world and
// runs the game loop until it quits. It is the whole main of the game of a
// project, which the generator writes.

PLAYER_OK :: 0
PLAYER_FAILED :: 1  // the application could not be created
PLAYER_USAGE :: 2   // an argument it does not understand
PLAYER_SCENE :: 3   // the start scene could not be loaded
PLAYER_CAPTURE :: 4 // the capture could not be written
PLAYER_VALIDATION :: 6 // --validation and the graphics API reported errors
PLAYER_GPU_LOST :: 7   // the GPU device stopped working (app_gpu_failure)
// 5 is left to a library that ends the player (app_exit) for a reason of its own.

PLAYER_ASSETS :: "assets"
PLAYER_LOAD_TOP :: 5 // slowest assets and loop functions of each load the player prints

@(private)
Player_Options :: struct {
    project:string,
    scene:string,
    capture:string,
    input:string,
    frames:int,
    players:int,        // local players; 0: what the scene says
    window:[4]i32,      // where the window goes, in screen coordinates; zero: centered
    surface:[3]f32,     // pixels and density of the image another process shows (player_surface.odin); zero: none
    arguments:[dynamic]string, // what it does not read itself, for the libraries
    headless,no_gpu,validation,attached:bool,
    dedicated:bool, // a server nobody plays on; the flag also stays in arguments, for the plugin of the network
}

@(private) PLAYER_SCRIPT_CAPACITY :: 256

// Input held from a frame to another, both included.
@(private)
Player_Script_Line :: struct {
    first,last:int,
    keys:core.Keys,
    mouse:core.Mouse_Buttons,
    look:[2]f32, // mouse movement of every frame
    pointer:[2]f32, // where the pointer goes on the first frame, in window points
    points:bool,    // the line places the pointer
}

@(private)
Player_Script :: struct {
    lines:[PLAYER_SCRIPT_CAPACITY]Player_Script_Line,
    count:int,
}

@(private)
PLAYER_USAGE_TEXT :: `Usage: [--project <folder>] [--scene <path>] [--headless] [--no-gpu] [--dedicated] [--frames <n>] [--capture <png>]
     [--validation] [--input <script>] [--players <n>] [--window <x>,<y>,<width>,<height>] [--surface <width>,<height>,<density>]
     [--attached] [--library play|editor] [arguments of the project's plugins]
  --scene       start scene, relative to the project's assets folder, or the absolute path of a .scene file
  --headless    no window: draws offscreen with 1/60 s steps
  --no-gpu      no window or renderer: only simulates
  --dedicated   a server nobody plays on: no window, renderer, audio or local players, at the pace of its
                ticks and without the phases ui and render; the plugin of the network serves the game
  --frames      exits after n frames
  --capture     writes the last frame as a PNG on exit
  --validation  enables graphics API validation; exits with code 6 if there are errors
  --input       input script: lines "<first frame> <last frame> <what>...", with keys (W, Space),
                buttons (mouse:Left), mouse movement per frame (look:dx,dy) and the position of the
                pointer in window points (pointer:x,y), which stays there until another line moves it
  --players     local split-screen players, from 1 to 4; if omitted, as many as the scene says
  --window      window position and size, frame included, in screen coordinates
  --surface     no window: draws into shared textures shown by the process that opened it,
                which sends it input through stdin (used by the editor)
  --attached    exits when its stdin closes: when the process that opened it is gone (used by the editor)
  --library     the library of the project mirai-player loads: play, the default, or editor, the one
                the editor loaded, of which it runs only the game (used by the editor)`

@(private)
player_options :: proc(args:[]string) -> (options:Player_Options,ok:bool) {
    for i:=0;i<len(args);i+=1 {
        value :: proc(args:[]string,i:^int) -> (string,bool) {
            if i^+1>=len(args) {return "",false}
            i^+=1
            return args[i^],true
        }
        switch args[i] {
        case "--project":    options.project=value(args,&i) or_return
        case "--scene":      options.scene=value(args,&i) or_return
        case "--capture":    options.capture=value(args,&i) or_return
        case "--frames":
            text:=value(args,&i) or_return
            options.frames=strconv.parse_int(text,10) or_return
            if options.frames<=0 {return options,false}
        case "--headless":   options.headless=true
        case "--no-gpu":     options.no_gpu=true
        case "--dedicated":
            options.dedicated=true
            append(&options.arguments,args[i])
        case "--validation": options.validation=true
        case "--input":      options.input=value(args,&i) or_return
        case "--attached":    options.attached=true
        case "--library":    _=value(args,&i) or_return // host.launch loads it
        case "--players":
            text:=value(args,&i) or_return
            options.players=strconv.parse_int(text,10) or_return
            if options.players<1 || options.players>4 {return options,false}
        case "--window":
            text:=value(args,&i) or_return
            parts:=strings.split(text,",",context.temp_allocator)
            if len(parts)!=4 {return options,false}
            for part,k in parts {options.window[k]=i32(strconv.parse_int(strings.trim_space(part),10) or_return)}
            if options.window[2]<=0 || options.window[3]<=0 {return options,false}
        case "--surface":
            text:=value(args,&i) or_return
            parts:=strings.split(text,",",context.temp_allocator)
            if len(parts)!=3 {return options,false}
            for part,k in parts {options.surface[k]=strconv.parse_f32(strings.trim_space(part)) or_return}
            if options.surface[0]<1 || options.surface[1]<1 || options.surface[2]<=0 {return options,false}
        case:                append(&options.arguments,args[i])
        }
    }
    return options,true
}

// Reads a script. On failure, line is the number of the line it does not understand.
@(private)
player_script_parse :: proc(text:string,script:^Player_Script) -> (line:int,ok:bool) {
    script.count=0
    rest:=text
    for row in strings.split_lines_iterator(&rest) {
        line+=1
        fields:=strings.fields(row,context.temp_allocator)
        if len(fields)==0 || strings.has_prefix(fields[0],"#") {continue}
        if len(fields)<3 || script.count==len(script.lines) {return line,false}
        entry:Player_Script_Line
        entry.first=strconv.parse_int(fields[0],10) or_return
        entry.last=strconv.parse_int(fields[1],10) or_return
        if entry.first<0 || entry.last<entry.first {return line,false}
        for field in fields[2:] {
            switch {
            case strings.has_prefix(field,"mouse:"):
                button:=reflect.enum_from_name(core.Mouse_Button,field[6:]) or_return
                entry.mouse+={button}
            case strings.has_prefix(field,"look:"):
                x,_,y:=strings.partition(field[5:],",")
                entry.look.x=strconv.parse_f32(x) or_return
                entry.look.y=strconv.parse_f32(y) or_return
            case strings.has_prefix(field,"pointer:"):
                x,_,y:=strings.partition(field[8:],",")
                entry.pointer.x=strconv.parse_f32(x) or_return
                entry.pointer.y=strconv.parse_f32(y) or_return
                if math.is_nan(entry.pointer.x) || math.is_inf(entry.pointer.x) || math.is_nan(entry.pointer.y) || math.is_inf(entry.pointer.y) {return line,false}
                entry.points=true
            case:
                key:=reflect.enum_from_name(core.Key,field) or_return
                entry.keys+={key}
            }
        }
        script.lines[script.count]=entry
        script.count+=1
    }
    return 0,true
}

// What the script holds in a frame, with the edges of what starts and of what ended in the frame before.
@(private)
player_script_input :: proc(script:^Player_Script,frame:int) -> (input:core.Input) {
    for &line in script.lines[:script.count] {
        if frame>=line.first && frame<=line.last {
            input.keys_down+=line.keys
            input.mouse_down+=line.mouse
            input.mouse_delta+=line.look
        }
        if frame==line.first {
            input.keys_pressed+=line.keys
            input.mouse_pressed+=line.mouse
        }
        if frame==line.last+1 {
            input.keys_released+=line.keys
            input.mouse_released+=line.mouse
        }
    }
    return
}

// Where the script has left the pointer by a frame: the line that started
// last places it, and it stays after the line ends so that a release lands
// where the press did.
@(private)
player_script_pointer :: proc(script:^Player_Script,frame:int) -> (pointer:[2]f32,points:bool) {
    latest:=-1
    for &line in script.lines[:script.count] {
        if line.points && line.first<=frame && line.first>=latest {pointer,points,latest=line.pointer,true,line.first}
    }
    return
}

// Adds what the script does in a frame to the input of the UI, which reads
// keys and buttons as a window gives them.
@(private)
player_script_ui :: proc(input:^ui.Input,scripted:core.Input,pointer:[2]f32,points:bool) {
    frame:platform.Input_Frame
    frame.keys_down,frame.keys_pressed,frame.keys_repeated=scripted.keys_down,scripted.keys_pressed,scripted.keys_pressed
    frame.mouse_down,frame.mouse_pressed,frame.mouse_released=scripted.mouse_down,scripted.mouse_pressed,scripted.mouse_released
    if .Left in scripted.mouse_pressed {frame.mouse_clicks[.Left]=1}
    given:=ui_input_from_platform(&frame)
    input.down+=given.down
    input.pressed+=given.pressed
    input.released+=given.released
    input.clicks=max(input.clicks,given.clicks)
    input.keys_down+=given.keys_down
    input.keys_pressed+=given.keys_pressed
    input.keys_repeated+=given.keys_repeated
    input.modifiers+=given.modifiers
    if points {input.pointer,input.pointer_absent=pointer,false}
}

// A frame of the player: app_frame with what the script does added to the
// input of the UI, once the frame has built it from the devices.
@(private)
player_frame :: proc(app:^App,phases:core.Phases,played:bool,scripted:core.Input,pointer:[2]f32,points:bool) -> bool {
    if !app_frame_begin(app) {
        profile_frame_close(app)
        return false
    }
    if played {
        player_script_ui(&app.ui_input,scripted,pointer,points)
        if points {ui_input_camera(&app.ui_input,app.camera,app_scene_points(app))}
    }
    if app.world!=nil {app_game_frame(app,app.world,phases)}
    app_frame_end(app)
    return !app.quit
}

// Why app_capture failed, which only says that it did.
@(private)
player_capture_problem :: proc(app:^App,path:string) -> string {
    context.allocator=context.temp_allocator
    if app.renderer==nil {return "nothing is drawn with --no-gpu or --dedicated"}
    if folder:=filepath.dir(path);!os.is_directory(folder) {return fmt.tprintf("the folder %s does not exist",folder)}
    existed:=os.exists(path)
    file,error:=os.open(path,{.Write,.Create})
    if error!=nil {return os.error_string(error)}
    os.close(file)
    if !existed {_=os.remove(path)}
    return "the renderer had no frame to read, or the PNG could not be encoded"
}

// The icon of the window: a PNG, read as 8 bits per channel with alpha.
@(private)
player_icon_set :: proc(app:^App,file:string) -> bool {
    width,height,channels:c.int
    pixels:=stbi.load(strings.clone_to_cstring(file,context.temp_allocator),&width,&height,&channels,4)
    if pixels==nil {return false}
    defer stbi.image_free(pixels)
    return platform.window_set_icon(app.platform,pixels[:width*height*4],i32(width),i32(height))
}

// engine_root: the engine the player runs with, whose general settings lie
// under those of the project; empty in a shipped game, which carries them merged.
player_run :: proc(info:^core.World_Info,project_root,engine_root:string,args:[]string) -> int {
    platform.crash_handler_install()
    options,understood:=player_options(args)
    defer delete(options.arguments)
    if !understood {
        fmt.eprintln(PLAYER_USAGE_TEXT)
        return PLAYER_USAGE
    }
    script:=new(Player_Script)
    defer free(script)
    if options.input!="" {
        path:=project.path_absolute(options.input,context.temp_allocator)
        text,read_error:=os.read_entire_file(path,context.allocator)
        if read_error!=nil {
            fmt.eprintfln("mirai: could not read %s: %s",path,os.error_string(read_error))
            return PLAYER_USAGE
        }
        defer delete(text)
        if line,parsed:=player_script_parse(string(text),script);!parsed {
            fmt.eprintfln("mirai: %s, line %d: expected \"<first frame> <last frame> <keys, mouse:Button, look:dx,dy or pointer:x,y>...\"",path,line)
            return PLAYER_USAGE
        }
    }
    if options.dedicated && (options.headless || options.capture!="" || options.validation || options.input!="" || options.players>0 || options.window.z>0 || options.surface[0]>0) {
        fmt.eprintln("mirai: --dedicated is a server nobody plays on, without a window, a renderer or local players: it does not go with --headless, --capture, --validation, --input, --players, --window or --surface")
        return PLAYER_USAGE
    }
    root:=options.project!=""?options.project:(project_root!=""?project_root:".")
    assets,_:=filepath.join({root,PLAYER_ASSETS},context.allocator)
    defer delete(assets)

    window:=platform.Window_Desc{title=filepath.base(root),rect=options.window}
    surfaced:=options.surface[0]>0
    if surfaced {
        options.headless=true
        window.density=options.surface[2]
    }
    icon:=""
    if manifest,manifest_error:=project.manifest_read(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator));manifest_error.code==.None {
        window.version=strings.clone(base.text_get(manifest.version[:]),context.temp_allocator)
        window.identifier=strings.clone(base.text_get(manifest.identifier[:]),context.temp_allocator)
        if path:=base.text_get(manifest.icon[:]);path!="" {icon=project.path(root,path,allocator=context.temp_allocator)}
        if title:=base.text_get(manifest.window.title[:]);title!="" {window.title=strings.clone(title,context.temp_allocator)}
        else if name:=base.text_get(manifest.name[:]);name!="" {window.title=strings.clone(name,context.temp_allocator)}
        if manifest.window.width>0 && manifest.window.height>0 {window.size={manifest.window.width,manifest.window.height}}
        if options.window.z<=0 {
            window.fullscreen=manifest.window.mode==.Fullscreen
            window.maximized=manifest.window.mode==.Maximized
        }
    }
    if surfaced {window.size={max(i32(options.surface[0]/options.surface[2]+0.5),1),max(i32(options.surface[1]/options.surface[2]+0.5),1)}}
    mounts:[]asset.Registry_Mount
    if p,open_error:=project.open(root,engine_root,context.temp_allocator);open_error.code==.None {
        mounts=project_asset_mounts(&p,context.temp_allocator)
    }
    gpu:=!options.no_gpu && !options.dedicated
    windowed:=!options.headless && gpu
    started:=time.tick_now()
    app,error:=app_create({
        info=info,root=root,engine_root=engine_root,options=app_user_folder(root,context.temp_allocator),threads=jobs.THREADS_AUTO,
        window=windowed,shown=surfaced,gpu=gpu,gpu_validation=options.validation,
        window_desc=window,vsync=windowed,game_window=options.window.z<=0, // a window an editor places (--window) keeps its place
        fixed_dt=windowed || options.dedicated?0:1.0/60,
        audio=windowed || surfaced?.Device:.None,
        assets_root=os.is_directory(assets)?assets:"",
        animation_cache=project.cache_path(root,project.ANIMATION_CACHE,allocator=context.temp_allocator),
        asset_mounts=mounts,
        shaders_root=root,
    })
    if app==nil {
        fmt.eprintfln("mirai: could not start the application: %v",error)
        return PLAYER_FAILED
    }
    defer app_destroy(app)
    if icon!="" && windowed && !player_icon_set(app,icon) {fmt.eprintfln("mirai: %s is not a PNG the window can show; the game runs without its icon",icon)}
    if app.world=app_world_create(app);app.world==nil {
        fmt.eprintln("mirai: could not create the world")
        return PLAYER_FAILED
    }
    load_startup(app,time.duration_nanoseconds(time.tick_since(started)))
    // Nobody watches a dedicated server: its frames last a tick, and the
    // generator keeps the game from depending on what ui and render do.
    phases:=ALL_PHASES
    if options.dedicated {
        phases-={.Ui,.Render}
        platform.set_pacing(app.platform,{limit=u32(1/app.tick_dt+0.5)})
    }
    if options.scene=="" {options.scene=project.start_scene(root,context.temp_allocator)}
    taken:=make([]bool,len(options.arguments))
    defer delete(taken)
    app.launch={scene=options.scene,players=options.players,arguments=options.arguments[:],taken=taken}
    surface:^Player_Surface
    if surfaced {
        surface=new(Player_Surface)
        if !surface_open(app,surface) {
            free(surface)
            fmt.eprintln("mirai: could not create the shared textures")
            return PLAYER_FAILED
        }
    }
    defer if surface!=nil {surface_close(app,surface);free(surface)}
    attached:^Player_Attached
    if options.attached && surface==nil {
        attached=new(Player_Attached)
        if !attached_open(attached) {
            fmt.eprintln("mirai: could not watch standard input")
            return PLAYER_FAILED
        }
    }

    code:=PLAYER_OK
    scripted:=0
    for frame:=1;;frame+=1 {
        played:=script.count>0 && !app.script_hold
        pointer:[2]f32
        points:=false
        input:core.Input
        if played {
            input=player_script_input(script,scripted)
            pointer,points=player_script_pointer(script,scripted)
            if points {input.mouse_position=pointer}
            app_input_add(app,input,devices=points)
            scripted+=1
        }
        if surface!=nil && !surface_frame_begin(app,surface) {break}
        if attached!=nil && attached_gone(attached) {break}
        if !player_frame(app,phases,played,input,pointer,points) {
            code=app.exit_code
            break
        }
        if failure,text:=app_gpu_failure(app);failure!=.None {
            fmt.eprintfln("mirai: %s",text)
            code=PLAYER_GPU_LOST
            break
        }
        if surface!=nil {surface_frame_end(app,surface)}
        // Where the seconds of each load went, once it is resident.
        if text:=load_profile_text(app,PLAYER_LOAD_TOP,context.temp_allocator);text!="" {fmt.eprint(text)}
        if frame==1 {
            if untaken:=launch_untaken(&app.launch);untaken!="" {
                fmt.eprintfln("mirai: no plugin of the project reads the argument %s",untaken)
                fmt.eprintln(PLAYER_USAGE_TEXT)
                return PLAYER_USAGE
            }
        }
        if options.frames>0 && frame>=options.frames {break}
    }
    if code==PLAYER_OK && options.capture!="" {
        path:=project.path_absolute(options.capture,context.temp_allocator)
        if !app_capture(app,path) {
            fmt.eprintfln("mirai: could not write %s: %s",path,player_capture_problem(app,path))
            code=PLAYER_CAPTURE
        }
    }
    if options.validation && app.device!=nil {
        if errors:=rhi.device_validation_errors(app.device);errors>0 {
            fmt.eprintfln("mirai: validation errors %d; last: %s",errors,rhi.device_validation_message(app.device))
            if code==PLAYER_OK {code=PLAYER_VALIDATION}
        }
    }
    return code
}
