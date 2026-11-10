package editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:cook/build"
import "mirai:editor/api"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"

// A game the editor runs in a window of its own, as mirai play does: the
// player of the project, whose library is built first, or the game that the
// last build of the game shipped. It reads the saved files of the project and
// ends with the editor (--attached); what it prints goes to the console.

PLAYER_LAUNCH_ARGUMENTS :: 512

Player_Launch :: struct {
    process:Player_Process,
    waiting:bool,  // for the build of the library of the player
    job:^build.Job,
    project:^project.Project, // what job builds
    shipped:bool,  // it runs the game a build of the game shipped
    scene:[256]u8, // relative to the assets folder; empty: the start scene
    players:int,   // 0: as the scene says
    arguments:[PLAYER_LAUNCH_ARGUMENTS]u8, // more arguments of the player, separated by spaces
    exit_code:int,
    ended:bool,    // it ran and ended, with exit_code
}

// Starts the game: the player of the project once its library is built, or
// the shipped game at once. arguments: more of the player, separated by
// spaces. Returns why it could not.
player_launch_start :: proc(s:^Session,shipped:bool,scene:string,players:int,arguments:string) -> string {
    p:=s.processes
    l:=&p.launch
    if l.process.handle!=0 || l.waiting {return "A game player.start started still runs: player.stop ends it"}
    if !s.has_project {return "There is no project: open a folder with a project.mirai"}
    if len(arguments)>len(l.arguments) {return fmt.tprintf("The arguments take at most %d bytes",len(l.arguments))}
    if len(scene)>len(l.scene) {return fmt.tprintf("The path of the scene takes at most %d bytes",len(l.scene))}
    if unsaved:=play_unsaved(s);unsaved!="" {return unsaved}
    if shipped {
        if player_launch_game(s)=="" {return "There is no shipped game: build.start with target game builds it"}
    } else if error:=player_build_start(s);error!="" {return error}
    l^={shipped=shipped,waiting=!shipped,players=players,job=l.job,project=l.project}
    copy(l.scene[:],scene)
    copy(l.arguments[:],arguments)
    if shipped {return player_launch_open(s)}
    log.info("building the player of the project")
    return ""
}

// Follows the build the player waits for and the process; between frames.
player_launch_poll :: proc(s:^Session) {
    p:=s.processes
    if p==nil {return}
    l:=&p.launch
    if l.waiting {
        done,built:=player_build_poll(s)
        if !done {return}
        l.waiting=false
        if !built {
            l.ended,l.exit_code=true,-1
            notify(s,"The player could not be built: the console says why")
            return
        }
        if message:=player_launch_open(s);message!="" {
            l.ended,l.exit_code=true,-1
            notify(s,message)
        }
        return
    }
    if l.process.handle==0 {return}
    player_launch_drain(s)
    exited,code:=platform.process_poll(s.app.platform,l.process.handle)
    if !exited {return}
    player_launch_drain(s)
    platform.process_release(s.app.platform,l.process.handle)
    l.process.handle=0
    l.ended,l.exit_code=true,code
    if code!=0 {log.warnf("the game ended with code %d",code)} else {log.info("the game ended")}
}

// Ends the game, and the build it waits for.
player_launch_stop :: proc(s:^Session) {
    p:=s.processes
    if p==nil {return}
    l:=&p.launch
    if l.waiting {
        player_build_free(l)
        l.waiting=false
    }
    if l.process.handle!=0 {
        _=platform.process_terminate(s.app.platform,l.process.handle,force=true)
        platform.process_release(s.app.platform,l.process.handle)
        l.process.handle=0
        l.ended,l.exit_code=true,-1
    }
}

// Builds the library play for the player, at the mode of this engine, as the
// editor was built: its plugin libraries are reused. Returns why it could not.
@(private)
player_build_start :: proc(s:^Session) -> string {
    l:=&s.processes.launch
    if s.engine_root=="" {
        // Without the root of the engine the game is not built: the last one runs.
        if !os.is_file(project.project_library(s.project_root,"play",context.temp_allocator)) {return "The game is not built and the root of the engine is unknown"}
        return ""
    }
    opened,error:=project.open(s.project_root,s.engine_root)
    if error.code!=.None {return "The project could not be opened"}
    l.project=new(project.Project)
    l.project^=opened
    l.job=build.job_start({project=l.project,target=.Play,dev=build.ENGINE_MODE_HERE==.Dev,engine=build.ENGINE_MODE_HERE})
    return ""
}

// Whether the build of the player finished, and whether it built. Its errors go to the console.
@(private)
player_build_poll :: proc(s:^Session) -> (done,built:bool) {
    l:=&s.processes.launch
    if l.job==nil {return true,true}
    if !build.job_poll(l.job) {return}
    result:=&l.job.result
    built=result.status==.Built || result.status==.Up_To_Date
    if !built {
        for d in result.diagnostics {
            if d.severity==.Error {log.errorf("%s(%d:%d) %s",d.file,d.line,d.column,d.message)}
        }
        if result.text!="" {log.error(result.text)}
        bottom_toggle_open(s.gui,.Console)
    }
    player_build_free(l)
    return true,built
}

// The player is being built: a build of the editor waits for it, as both
// generate the world of the project in the same folder.
player_building :: proc "contextless" (s:^Session) -> bool {return s.processes!=nil && s.processes.launch.job!=nil}

@(private)
player_build_free :: proc(l:^Player_Launch) {
    if l.job!=nil {build.job_destroy(l.job)}
    if l.project!=nil {
        project.close(l.project)
        free(l.project)
    }
    l.job,l.project=nil,nil
}

// The executable of the shipped game: the one the last build of the game
// left, or the one of .mirai/game. Empty: none.
@(private)
player_launch_game :: proc(s:^Session) -> string {
    if s.build.game!="" && os.is_file(s.build.game) {return s.build.game}
    opened,error:=project.open(s.project_root,s.engine_root,context.temp_allocator)
    if error.code!=.None {return ""}
    if game:=build.target_output(&opened,.Game,"",context.temp_allocator);os.is_file(game) {return game}
    return ""
}

@(private)
player_launch_open :: proc(s:^Session) -> string {
    l:=&s.processes.launch
    command:=make([dynamic]string,context.temp_allocator)
    folder:=s.project_root
    if l.shipped {
        game:=player_launch_game(s)
        if game=="" {return "There is no shipped game: build.start with target game builds it"}
        folder=filepath.dir(game)
        append(&command,game,"--attached")
    } else {
        player:=engine_program_here(s,"mirai-player")
        if !os.is_file(player) {return "The player program is missing next to the editor"}
        append(&command,player,"--attached","--project",s.project_root)
    }
    if scene:=base.text_get(l.scene[:]);scene!="" {append(&command,"--scene",scene)}
    if l.players>0 {append(&command,"--players",fmt.tprintf("%d",l.players))}
    append(&command,..strings.fields(base.text_get(l.arguments[:]),context.temp_allocator))
    process,error:=platform.process_start(s.app.platform,{command=command[:],working_directory=folder,merge_stderr=true})
    if error!=.None {return fmt.tprintf("The game could not be started: %v",error)}
    l.process={handle=process}
    log.infof("the game runs: %s",strings.join(command[:]," ",context.temp_allocator))
    return ""
}

@(private)
player_launch_drain :: proc(s:^Session) {
    process:=&s.processes.launch.process
    buffer:[2048]u8
    for {
        count,open:=platform.process_read(s.app.platform,process.handle,.Stdout,buffer[:])
        for b in buffer[:count] {
            if b=='\n' || process.length==len(process.line) {
                if process.length>0 {log.infof("game: %s",strings.trim_right_space(string(process.line[:process.length])))}
                process.length=0
                if b=='\n' {continue}
            }
            process.line[process.length]=b
            process.length+=1
        }
        if count<len(buffer) || !open {break}
    }
}

// ---------------------------------------------------------------- API

Api_Player_Start_Params :: struct {
    shipped:bool `mirai:"optional,label=Runs the game the last build of the game shipped (build.start with target game) instead of the player of the project which is built first as mirai play does"`,
    scene:[256]u8 `mirai:"optional,text,label=A .scene relative to the assets folder; empty: the start scene of the project"`,
    players:int `mirai:"optional,min=0,max=4,label=Local players sharing the screen; 0: as the scene says"`,
    arguments:[PLAYER_LAUNCH_ARGUMENTS]u8 `mirai:"optional,text,label=More arguments of the player separated by spaces: those of the plugins of the project as --server"`,
}

Api_Player_Status :: struct {
    running:bool,
    building:bool `mirai:"label=The player of the project is being built; it starts once it is"`,
    shipped:bool,
    ended:bool `mirai:"label=It ran and ended: exit_code says how; -1 when it was stopped or could not start"`,
    exit_code:int,
    scene:[256]u8 `mirai:"text"`,
    players:int,
    arguments:[PLAYER_LAUNCH_ARGUMENTS]u8 `mirai:"text"`,
}

@(private)
player_launch_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="player.start",summary="Runs the game in a window of its own as mirai play does, or the shipped game: it reads the saved files of the project, prints to the console and ends with the editor.",params=type_info_of(Api_Player_Start_Params),result=type_info_of(Api_Player_Status),run=api_player_start})
    api_register(s,st,{name="player.status",summary="State of the game player.start runs.",result=type_info_of(Api_Player_Status),flags={.Read_Only},run=api_player_status})
    api_register(s,st,{name="player.stop",summary="Ends the game player.start runs, or the build it waits for.",result=type_info_of(Api_Player_Status),flags={.Idempotent},run=api_player_stop})
}

@(private)
api_player_start :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Player_Start_Params)
    scene:=base.text_get(params.scene[:])
    if scene!="" && s.assets_root!="" && !os.is_file(project.path(s.assets_root,scene,allocator=context.temp_allocator)) {
        api.call_failf(call,api.INVALID_PARAMS,"The scene %s does not exist in %s: name a .scene with a path relative to the assets folder",scene,s.assets_root)
        return
    }
    if message:=player_launch_start(s,params.shipped,scene,params.players,strings.trim_space(base.text_get(params.arguments[:])));message!="" {
        api.call_fail(call,api.SERVER_ERROR,message)
        return
    }
    api_player_status(s,call)
}

@(private)
api_player_status :: proc(s:^Session,call:^api.Call) {
    l:=&s.processes.launch
    result:=api.call_result(call,Api_Player_Status)
    result^={running=l.process.handle!=0,building=l.waiting,shipped=l.shipped,ended=l.ended,exit_code=l.exit_code,scene=l.scene,players=l.players,arguments=l.arguments}
}

@(private)
api_player_stop :: proc(s:^Session,call:^api.Call) {
    player_launch_stop(s)
    api_player_status(s,call)
}
