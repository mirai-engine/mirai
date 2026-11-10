package editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "mirai:cook/build"
import "mirai:cook/install"
import "mirai:project"
import "mirai:std/base"
import "mirai:ui"

// Build: the shaders of the project (with the sources of programs the editor
// holds unsaved) and its library (the world generated from the attributes of
// its packages, its game and its plugins) are made without stopping the
// editor. One that succeeds is loaded into the running editor, its worlds
// migrated when their layout changed (reload.odin); one that fails leaves
// this editor running and shows what the compiler said.
// Play builds first when an Odin source of the project changed since the last
// build that stood, and starts once the new code is loaded.
// A build of the game (Target.Game) generates the shaders the game ships
// first and then the game in its folder, and leaves the editor as it is.

Build_Phase :: enum u8 {Idle,Running,Built,Up_To_Date,Failed}

Build_Diagnostic :: struct {
    severity:build.Severity,
    file:string, // absolute, with forward slashes
    line,column:int,
    message:string,
}

@(storage)
Build_State :: struct {
    phase:Build_Phase,
    target:build.Target,      // of the build that runs or ran last: Editor or Game
    job:^build.Job,
    shaders:^build.Shaders_Job,
    project:^project.Project, // open while the jobs run
    started:time.Tick,
    seconds:f64,
    failure:build.Failure,
    output:string,            // the editor the last build left
    game:string,              // the executable of the game the last build of the game left
    game_folder:string,       // where the build of the game that runs writes; empty: .mirai/game
    diagnostics:[dynamic]Build_Diagnostic,
    text:string,              // what the compiler said besides its diagnostics
    shaders_text:string,
    scroll:f32,
    text_scroll:[2]f32,
    programs:Programs_Publication,
    sources:u64,        // code_fingerprint of what the library loaded was built from
    started_sources:u64, // of the build that runs
    play:Build_Play,
    play_error:[256]u8, // why the Play that waited for the build did not start; empty when it did
    shader_sources:u64, // shaders_fingerprint of what was last published or seen on disk
    reload:bool,        // the library built waits to be loaded (build_reload)
    probing:bool,       // a check or a run of the tests (code_probe)
}

// A Play that waits for the build of the code that changed.
Build_Play :: struct {
    pending:bool,
    request:bool, // the Play of the toolbar or of a shortcut; otherwise of play.start, with these
    owner,players,online,ping_ms:int,
    saved_only:bool,
}

// Starts a build of the editor of the project, or of its game into folder
// (empty: .mirai/game of the project).
build_start :: proc(s:^Session,target:=build.Target.Editor,folder:="") -> bool {
    b:=s.build
    if b.phase==.Running || b.reload {return false}
    if b.probing {
        notify(s,"The code is being checked or tested; wait for it")
        return false
    }
    // Both builds generate the world of the project in the same folder.
    if player_building(s) {
        notify(s,"The player of the project is being built; wait for it")
        return false
    }
    if !s.has_project || s.engine_root=="" {
        notify(s,"Build needs a project and the root of the engine")
        return false
    }
    // A pull can move the commit of a plugin from git: its checkout follows before the build.
    if install.sync_needed(s.project_root) {
        if _,message:=install.sync(s.project_root,context.temp_allocator);message!="" {notify(s,message)}
    }
    p:=new(project.Project)
    opened,error:=project.open(s.project_root,s.engine_root)
    if error.code!=.None {
        free(p)
        log.errorf("the project could not be opened: %v",error.code)
        notify(s,"The project could not be opened")
        return false
    }
    p^=opened
    build_results_free(b)
    b.project=p
    b.target=target
    delete(b.game_folder)
    b.game_folder=strings.clone(folder)
    if target==.Game {
        // The game ships the shaders as they are saved, generated before it is built.
        b.shaders=build.shaders_start(p)
    } else {
        b.shaders=build.shaders_start(p,overlay=programs_overlay(s))
        b.started_sources=code_fingerprint(s.project_root)
        b.job=build.job_start({project=p,target=.Editor,dev=build.ENGINE_MODE_HERE==.Dev})
    }
    b.phase=.Running
    b.started=time.tick_now()
    log.infof("build of the %s started",target==.Game?"game":"editor")
    return true
}

// Follows the jobs, and the game player.start runs; between frames.
build_poll :: proc(s:^Session) {
    b:=s.build
    programs_poll(s)
    build_reload(s)
    player_launch_poll(s)
    if b.phase!=.Running {return}
    if b.shaders!=nil && !build.shaders_poll(b.shaders) {return}
    if b.target==.Game && b.job==nil && b.shaders!=nil && b.shaders.result.status!=.Failed {
        b.job=build.job_start({project=b.project,target=.Game,output=b.game_folder})
        return
    }
    if b.job!=nil && !build.job_poll(b.job) {return}
    b.seconds=time.duration_seconds(time.tick_since(b.started))
    if b.shaders!=nil {
        result:=&b.shaders.result
        switch result.status {
        case .Running,.None,.Up_To_Date,.Cancelled:
        case .Built:  log.infof("shaders built: %d programs, %d stages compiled",result.programs,result.compiled)
        case .Failed:
            log.errorf("the shaders of the project failed: %s",result.message)
            if len(result.diagnostics)==0 {b.shaders_text=strings.clone(result.message)}
            for d in result.diagnostics {
                if d.severity==.Info {continue}
                file:=d.file
                if d.file!="" && !filepath.is_abs(d.file) {
                    in_project:=project.path(s.project_root,d.file,allocator=context.temp_allocator)
                    file=os.exists(in_project)?in_project:project.path(s.engine_root,d.file,allocator=context.temp_allocator)
                }
                append(&b.diagnostics,Build_Diagnostic{d.severity==.Error?.Error:.Warning,strings.clone(file),d.line,d.column,strings.clone(d.message)})
            }
        }
    }
    if b.job==nil {
        // The shaders of a game failed: it is not built.
        b.phase=.Failed
        b.failure=.Shaders
        bottom_toggle_open(s.gui,.Build)
        notify(s,"The shaders of the game could not be generated")
        build_jobs_free(b)
        return
    }
    result:=&b.job.result
    b.failure=result.failure
    for d in result.diagnostics {
        append(&b.diagnostics,Build_Diagnostic{d.severity,strings.clone(d.file),d.line,d.column,strings.clone(d.message)})
        if d.severity==.Error {log.errorf("%s(%d:%d) %s",d.file,d.line,d.column,d.message)} else {log.warnf("%s(%d:%d) %s",d.file,d.line,d.column,d.message)}
    }
    #partial switch result.failure {
    case .Engine_Time_Code: b.text=strings.clone(fmt.tprintf("the game reaches engine-time packages, which are not shipped: %s",strings.join(result.engine_time,", ",context.temp_allocator)))
    case .Cook_Failed:      b.text=strings.clone(fmt.tprintf("the assets could not be cooked: %v %s",result.cook.error,result.cook.detail))
    case:                   b.text=strings.clone(result.text)
    }
    if result.failure==.Engine_Time_Code || result.failure==.Cook_Failed {log.error(b.text)}
    if b.target==.Game && result.status!=.Failed {
        b.phase=result.status==.Built?.Built:.Up_To_Date
        delete(b.game)
        b.game=strings.clone(result.output)
        log.infof("%s %s",result.output,result.status==.Built?"built":"is up to date")
        notify(s,fmt.tprintf("The game is %s: %s",result.status==.Built?"built":"up to date",result.output))
        build_jobs_free(b)
        return
    }
    switch result.status {
    case .Running:
    case .Built:
        b.phase=.Built
        delete(b.output)
        b.output=strings.clone(result.output)
        log.infof("built %s in %.1f s",result.output,result.seconds)
        // Libraries of plugins built again have names of their own: the new library loads beside the old.
        b.reload=true
        build_reload(s)
    case .Up_To_Date:
        b.phase=.Up_To_Date
        delete(b.output)
        b.output=strings.clone(result.output)
        b.sources=b.started_sources
        if !b.play.pending {notify(s,"The project is up to date")}
        build_play_resume(s)
    case .Failed:
        b.phase=.Failed
        log.errorf("the build failed: %v",result.failure)
        bottom_toggle_open(s.gui,.Build)
        notify(s,b.play.pending?"The code does not build: the game did not start":"The build failed")
        b.play={}
    }
    build_jobs_free(b)
}

@(private)
build_jobs_free :: proc(b:^Build_State) {
    build.job_destroy(b.job)
    build.shaders_destroy(b.shaders)
    project.close(b.project)
    free(b.project)
    b.job,b.shaders,b.project=nil,nil,nil
}

// What a build of the code of a project reads besides the engine: the Odin
// files under its game, editor and plugin folders and its manifest, by name,
// size and time.
code_fingerprint :: proc(root:string) -> u64 {
    names:=project.FOLDER_NAMES
    hash:u64
    for folder in ([]project.Folder{.Game,.Editor,.Plugins}) {
        files_fingerprint(project.path(root,names[folder],allocator=context.temp_allocator),".odin",&hash,0)
    }
    files_fingerprint(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator),"",&hash,0)
    return hash
}

// Every file under the shaders of a project and the Slang sources of its
// plugins: what programs_publish_request publishes.
shaders_fingerprint :: proc(root:string) -> u64 {
    names:=project.FOLDER_NAMES
    hash:u64
    files_fingerprint(project.path(root,names[.Shaders],allocator=context.temp_allocator),"",&hash,0)
    files_fingerprint(project.path(root,names[.Plugins],allocator=context.temp_allocator),".slang",&hash,0)
    return hash
}

// Adds the files of path (one, or a folder and those under it) whose name
// ends in extension, by name, size and time, to hash: a sum, so the order a
// folder is listed in does not matter.
@(private="file")
files_fingerprint :: proc(path,extension:string,hash:^u64,depth:int) {
    if depth>12 {return}
    entries,error:=os.read_all_directory_by_path(path,context.temp_allocator)
    if error!=nil {
        if info,stat_error:=os.stat(path,context.temp_allocator);stat_error==nil && info.type!=.Directory {
            file:=base.name_hash(path)
            file=base.hash_combine(file,u64(info.size))
            hash^+=base.hash_combine(file,u64(time.time_to_unix_nano(info.modification_time)))
        }
        return
    }
    for entry in entries {
        if entry.name=="" || entry.name[0]=='.' {continue}
        if entry.type==.Directory {
            files_fingerprint(entry.fullpath,extension,hash,depth+1)
            continue
        }
        if !strings.has_suffix(entry.name,extension) {continue}
        file:=base.name_hash(entry.fullpath)
        file=base.hash_combine(file,u64(entry.size))
        hash^+=base.hash_combine(file,u64(time.time_to_unix_nano(entry.modification_time)))
    }
}

// The declarations the code of the project compiles against, its public
// API: of the engine and of its plugins. Empty without the root of the engine.
code_api_folders :: proc(s:^Session) -> (engine,plugins:string) {
    if s.engine_root=="" {return}
    engine=build.engine_paths(s.engine_root,.Keep,context.temp_allocator).decl
    manifest,error:=project.manifest_read(project.path(s.project_root,project.PROJECT_FILE,allocator=context.temp_allocator))
    if error.code!=.None {return}
    opened:=project.Project{manifest=manifest}
    if folder:=build.plugins_decl(s.project_root,build.plugins_mode(&opened,false),context.temp_allocator);os.is_dir(folder) {plugins=folder}
    return
}

// Loads the library a build left, once nothing holds the worlds.
@(private)
build_reload :: proc(s:^Session) {
    b:=s.build
    if !b.reload {return}
    switch library_reload(s) {
    case .Wait:
    case .Restart:
        b.reload=false
        b.play={}
        ai_resume_native_mark(s)
        // A call that waits for this build answers first.
        if st:=api_state(s);st!=nil && st.waiting>0 {st.restart=true} else {s.requests+={.Restart}}
    case .Reloaded:
        b.reload=false
        b.sources=b.started_sources
        api_port_file_refresh(s)
        build_play_resume(s)
    }
}

// The code of the project changed since the library loaded was built.
code_changed :: proc(s:^Session) -> bool {
    return s.has_project && s.engine_root!="" && code_fingerprint(s.project_root)!=s.build.sources
}

// Builds first when the code changed: Play of owner starts once the build
// stands (build_play_resume) and does not when it fails. True while it waits.
play_build_first :: proc(s:^Session,play:Build_Play) -> bool {
    b:=s.build
    if b.phase!=.Running && !b.reload {
        if !code_changed(s) || !build_start(s) {return false}
    }
    b.play=play
    b.play.pending=true
    b.play_error={}
    return true
}

// The Play that waited for the build, with the code it built.
@(private)
build_play_resume :: proc(s:^Session) {
    play:=s.build.play
    s.build.play={}
    if !play.pending {return}
    if play.request {
        s.requests+={.Play}
        return
    }
    if error:=play_begin(s,play.owner,play.players,play.online,play.ping_ms,play.saved_only);error!="" {
        base.text_set(s.build.play_error[:],error)
        log.errorf("the game did not start after the build: %s",error)
        notify(s,"The game could not start")
    }
}

// Checks the code of the project or runs its tests, to the end or for
// seconds at most, without loading anything: the editor draws frames
// meanwhile. The job is the caller's to destroy.
code_probe :: proc(s:^Session,action:build.Action,test_package:string,test_names:[]string,seconds:f64) -> (job:^build.Job,error:string) {
    b:=s.build
    if b.phase==.Running || b.probing {return nil,"A build is running; build.status says when it ends"}
    if player_building(s) {return nil,"The player of the project is being built; wait for it"}
    if !s.has_project || s.engine_root=="" {return nil,"It needs a project and the root of the engine"}
    opened,open_error:=project.open(s.project_root,s.engine_root)
    if open_error.code!=.None {return nil,"The project could not be opened"}
    defer project.close(&opened)
    b.probing=true
    defer b.probing=false
    job=build.job_start({project=&opened,target=.Editor,action=action,test_package=test_package,test={names=test_names,quiet=true}})
    started:=time.tick_now()
    for !build.job_poll(job) {
        if time.duration_seconds(time.tick_since(started))>seconds || api_stop_asked(s) || api_frames(s,1,0)==0 {
            build.job_cancel(job)
            break
        }
    }
    return job,""
}

// Stops what runs: when the editor ends.
build_cancel :: proc(s:^Session) {
    b:=s.build
    programs_cancel(s)
    if b.job!=nil {build.job_destroy(b.job)}
    if b.shaders!=nil {build.shaders_destroy(b.shaders)}
    if b.project!=nil {
        project.close(b.project)
        free(b.project)
    }
    b.job,b.shaders,b.project=nil,nil,nil
    if b.phase==.Running {b.phase=.Idle}
    b.play={}
    build_results_free(b)
    delete(b.output)
    delete(b.game)
    delete(b.game_folder)
    b.output,b.game,b.game_folder="","",""
}

@(private)
build_results_free :: proc(b:^Build_State) {
    for d in b.diagnostics {delete(d.file);delete(d.message)}
    clear(&b.diagnostics)
    delete(b.text);delete(b.shaders_text)
    b.text,b.shaders_text="",""
    b.failure=.None
}

@(private)
build_tools :: proc(s:^Session) {
    b:=s.build
    ctx:=s.gui.ctx
    th:=&ctx.theme
    if b.phase==.Running {
        ui.label(ctx,fmt.tprintf("%.0f s",time.duration_seconds(time.tick_since(b.started))),th.font_small,th.text_muted)
        return
    }
    state:=action_state(s,.Build)
    if ui.button(ctx,ui.id(ctx,"build_run"),{label="Build",style=.Field,height=24,width=72,center=true,size=th.font_small,disabled=state.disabled}).clicked {build_start(s)}
}

FAILURE_TEXTS :: [build.Failure]string{
    .None="",.Engine_Missing="The root of the engine is not known",
    .Engine_Incomplete="The installed engine lacks some of its binaries: unpack its package again",.Generate="The attributes of the packages are wrong",
    .Compiler_Missing="No Odin compiler in MIRAI_ODIN or PATH",.Shaders="The shaders of the engine could not be generated",
    .Compiler_Failed="The compiler could not run",
    .Write_Failed="A generated file could not be written",.Compile="The code does not compile",
    .Out_Of_Memory="The compiler passed its memory cap: likely a multiple assignment of values over 64 bytes (odin-lang/Odin#7937); assign one value at a time. mirai test cook/build no_store_of_an_aggregate_of_more_than_64_bytes finds it; MIRAI_COMPILER_MEMORY raises the cap",
    .Output_Locked="The editor could not be replaced",.Output_Invalid="The output folder is the project",
    .Engine_Time_Code="Engine-time code reached the game",.Copy_Failed="The files of the game could not be copied",
    .Settings_Invalid="A settings file of the engine or of the project is not valid",
    .Cook_Failed="The assets could not be cooked",.Tests="Tests failed",.Cancelled="Cancelled",
}

@(private)
build_panel_build :: proc(s:^Session,height:f32) {
    b:=s.build
    ctx:=s.gui.ctx
    th:=&ctx.theme
    texts:=FAILURE_TEXTS
    status:string
    color:=th.text_muted
    switch b.phase {
    case .Idle:       status="No build yet"
    case .Running:    status="Building..."
    case .Built:      status=fmt.tprintf("Built in %.1f s",b.seconds)
    case .Up_To_Date: status="Up to date"
    case .Failed:
        status=fmt.tprintf("Failed after %.1f s: %s",b.seconds,texts[b.failure])
        color=th.danger
    }
    ui.label(ctx,status,th.font_small,color,0)
    room:=max(height-26,CONSOLE_ROW)
    colors:=LEVEL_COLORS
    if len(b.diagnostics)>0 {
        list:=ui.id(ctx,"build_list")
        first,last:=ui.list_begin(ctx,list,&b.scroll,len(b.diagnostics),CONSOLE_ROW,room)
        for index in first..<last {
            d:=&b.diagnostics[index]
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(CONSOLE_ROW),gap=6,align_y=.Center}) {
                level:=d.severity==.Error?Console_Level.Error:.Warning
                if ui.box(ctx,{width=ui.fixed(6),height=ui.fixed(6),fill=colors[level],radius=3}) {}
                where_:=fmt.tprintf("%s(%d:%d)",filepath.base(d.file),d.line,d.column)
                ui.label(ctx,where_,th.font_small,th.text_muted)
                ui.label(ctx,d.message,th.font_small,colors[level],0)
            }
        }
        ui.list_end(ctx,list,len(b.diagnostics),last,CONSOLE_ROW)
        return
    }
    text:=b.text
    if text=="" {text=b.shaders_text}
    if text!="" {
        if ui.scroll_area(ctx,ui.id(ctx,"build_text"),&b.text_scroll,{height=ui.fixed(room)}) {
            ui.paragraph(ctx,text,th.font_small,th.text_muted)
        }
    }
}
