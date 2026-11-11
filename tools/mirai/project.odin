package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:cook/build"
import "mirai:cook/install"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"

NEW_USAGE :: "new <folder> [--name N] [--template T] | new --list"
BUILD_USAGE :: "build tools [--debug]"
BUILD_ENGINE_USAGE :: "build engine [--release] [--force]"
BUILD_PROJECT_USAGE :: "build <editor|game|server> [project] [--release] [--out folder]"
GENERATE_USAGE :: "generate [project]"
EDIT_USAGE :: "edit [project] [--release] [editor arguments]"
PLAY_USAGE :: "play [project] [--release] [player arguments]"

// How optimized the engine and a project are built. Dev, what every command
// builds unless --release is asked for: both at -o:minimal, for checking a
// change. Release: the engine at -o:speed and the project at the optimization
// of its manifest, for playing, measuring and shipping.
// Each mode has binaries of its own.
Build_Mode :: build.Engine_Mode

// Takes --release out of args: the mode of every command that builds or picks
// engine binaries, dev unless it is there.
build_mode_take :: proc(args:[]string) -> (mode:Build_Mode,rest:[]string) {
    list:=make([dynamic]string)
    for arg in args {
        if arg=="--release" {mode=.Release} else {append(&list,arg)}
    }
    return mode,list[:]
}

cmd_new :: proc(root:string,args:[]string) -> int {
    folder,name,template:="","",build.TEMPLATE_DEFAULT
    for i:=0;i<len(args);i+=1 {
        if args[i]=="--list" {
            for found in build.templates_list(root) {fmt.printfln("  %-12s %s",found.name,found.summary)}
            return 0
        }
        if value,matched,ok:=option_value(args,&i,"--name");matched {
            if !ok || value=="" {fmt.eprintln("mirai new: --name needs a name");return 2}
            name=value
        } else if value,matched,ok=option_value(args,&i,"--template");matched {
            if !ok || value=="" {fmt.eprintln("mirai new: --template needs a name; mirai new --list shows them");return 2}
            template=value
        } else if !positional(args[i]) {
            return argument_unknown("new",args[i])
        } else if folder=="" {
            folder=args[i]
        } else {
            return argument_unknown("new",args[i])
        }
    }
    if folder=="" {fmt.eprintfln("Usage: mirai %s",NEW_USAGE);return 2}
    switch build.project_create(build.template_folder(root,template),folder,name,root) {
    case .None:
    case .Template_Missing: fmt.eprintfln("mirai new: there is no template %q in %s; mirai new --list shows them",template,build.template_folder(root,template));return 1
    case .Folder_Not_Empty: fmt.eprintfln("mirai new: %s already exists and is not an empty folder",folder);return 1
    case .Copy_Failed:      fmt.eprintfln("mirai new: could not write to %s",folder);return 1
    case .Manifest_Failed:  fmt.eprintfln("mirai new: the name does not fit in %s (up to %d bytes)",project.PROJECT_FILE,len(project.Name)-1);return 1
    }
    fmt.printfln("Project created in %s.",project.path_absolute(folder))
    return 0
}

// mirai build editor [project]: the library of the project the editor loads, in .mirai.
// mirai build game [project] [--out folder]: the game to ship, with its
// assets cooked: what was left out, what the folder weighs, and every asset
// of it checked as mirai asset verify does. mirai build server: its dedicated
// server, the same executable (run with --dedicated) without what is only
// shown or heard, in .mirai/server unless --out says another folder.
cmd_build_project :: proc(root:string,args:[]string) -> int {
    mode,rest:=build_mode_take(args[1:])
    code,_,shaders_failed:=build_project(root,args[0]=="editor"?.Editor:.Game,rest,mode,server=args[0]=="server")
    return code!=0?code:shaders_failed?1:0
}

// mirai build engine [--release] [--force]: the binaries of the engine,
// unless the ones there were built from the same sources in the same mode.
cmd_build_engine :: proc(root:string,args:[]string) -> int {
    mode,rest:=build_mode_take(args)
    force:=false
    for arg in rest {
        if arg!="--force" {return argument_unknown("build engine",arg)}
        force=true
    }
    mode=build.engine_mode_resolve(root,mode)
    // What has nothing to compile takes no turn.
    if !force && c_libraries_current(root) && build.engine_current(root,mode) {return engine_report({status=.Up_To_Date,mode=mode,folder=build.engine_paths(root,mode,context.temp_allocator).folder},root)}
    engine_release("",build.engine_paths(root,mode,context.temp_allocator).folder,"build engine")
    lock:=build_lock(root,"build engine")
    defer workspace.lock_release(&lock)
    // ui links the FreeType library, the importer that of ufbx and the editor that of SQLite.
    if !ensure_runtime_dependencies(root) {return 1}
    return engine_report(build.engine_build({engine_root=root,mode=mode,force=force}),root)
}

// Says how the build of the engine went, in out; 0 when its binaries are there.
engine_report :: proc(result:build.Engine_Result,root:string,out:=os.stdout) -> int {
    if !engine_shaders_report(result.shaders,out) {return 1}
    mode:="dev" if result.mode==.Dev else "release"
    switch result.status {
    case .Up_To_Date: fmt.fprintfln(out,"%s unchanged (%s).",result.folder,mode);return 0
    case .Built:
        fmt.fprintfln(out,"%s ready (%s, %.1f s): %d libraries compiled%s%s%s, %d copied from the shared cache%s.",result.folder,mode,result.seconds,len(result.compiled),len(result.compiled)>0?" (":"",strings.join(result.compiled,", ",context.temp_allocator),len(result.compiled)>0?")":"",result.restored,result.programs?", the programs compiled":"")
        return 0
    case .Running,.Failed:
    }
    for diagnostic in result.diagnostics {
        fmt.eprintfln("%s(%d:%d) %v: %s",diagnostic.file,diagnostic.line,diagnostic.column,diagnostic.severity,diagnostic.message)
    }
    if result.text!="" {fmt.eprintln(result.text)}
    if result.failure==.Out_Of_Memory {fmt.eprintln(out_of_memory_text("mirai build engine"))}
    fmt.eprintfln("mirai build engine: %s failed (%v).",result.step,result.failure)
    return 1
}

// mirai generate [project]: writes the generated packages and says what the attributes have wrong.
cmd_generate :: proc(root:string,args:[]string) -> int {
    if code:=positionals_only("generate",args);code!=0 {return code}
    if len(args)>1 {return argument_unknown("generate",args[1])}
    folder:=len(args)>0?args[0]:"."
    p,error:=project.open(folder,root)
    if error.code!=.None {
        fmt.eprintfln("mirai generate: %s",project_error_text(folder,error))
        return 1
    }
    defer project.close(&p)
    out,ok:=build.world_write_files(&p)
    for e in out.errors {fmt.eprintln(e)}
    if !ok {
        if len(out.errors)==0 {fmt.eprintfln("mirai generate: could not write to %s",build.generated_root(p.root))}
        return 1
    }
    fmt.printfln("%s ready.",build.generated_root(p.root))
    return 0
}

// mirai edit [project] [--release] [arguments]: builds the library of
// the project and opens it in the editor. Without a project, in a folder that is none, it opens
// the last project an editor opened when the launcher was told so, and the
// launcher otherwise: the editor of the empty template with --launcher.
cmd_edit :: proc(root:string,args:[]string) -> int {
    mode,args:=build_mode_take(args)
    named:=len(args)>0 && !strings.has_prefix(args[0],"-")
    folder:=named?args[0]:"."
    rest:=named?args[1:]:args
    extra:[]string
    if !named && !os.is_file(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator)) {
        folder,extra=edit_unnamed(root)
    }
    code,_,_:=build_project(root,.Editor,{folder},mode)
    if code!=0 {return code}
    if slice.contains(rest,"--headless") {layers_isolate(root)}
    command:=make([dynamic]string)
    append(&command,project_engine_paths(root,folder,mode).editor_program,"--project",project.path_absolute(folder))
    append(&command,..extra)
    append(&command,..rest)
    return run(root,command[:])
}

// What mirai edit opens without a project: the last one opened, when the
// launcher keeps it so and it is still there, or the launcher.
@(private="file")
edit_unnamed :: proc(root:string) -> (folder:string,extra:[]string) {
    recent:project.Recent_Projects
    if project.recent_read(root,&recent).code==.None && recent.open_last && project.recent_count(&recent)>0 {
        last:=strings.clone(base.text_get(recent.projects[0].path[:]),context.temp_allocator)
        if os.is_file(project.path(last,project.PROJECT_FILE,allocator=context.temp_allocator)) {return last,nil}
    }
    launcher:=[]string{"--launcher"}
    return build.template_folder(root,allocator=context.temp_allocator),slice.clone(launcher,context.temp_allocator)
}

// mirai play [project] [--release] [arguments] (mirai play test: play_test.odin): builds the library of
// the project and plays its game from the project, without cooking.
cmd_play :: proc(root:string,args:[]string) -> int {
    if len(args)>0 && args[0]=="test" {return cmd_play_test(root,args[1:])}
    mode,args:=build_mode_take(args)
    folder:=len(args)>0 && !strings.has_prefix(args[0],"-")?args[0]:"."
    rest:=len(args)>0 && folder==args[0]?args[1:]:args
    code,_,_:=build_project(root,.Editor,{folder},mode)
    if code!=0 {return code}
    if play_runs_headless(rest) {layers_isolate(root)}
    command:=make([dynamic]string)
    append(&command,project_engine_paths(root,folder,mode).player_program,"--project",project.path_absolute(folder))
    append(&command,..play_arguments(rest))
    return run(root,command[:])
}

// Whether the player runs these arguments without a window: asked for, or
// implied by what automates it (the player does the same with its options).
@(private)
play_runs_headless :: proc(args:[]string) -> bool {
    if slice.contains(args,"--show-window") {return false}
    return slice.contains(args,"--headless") || slice.contains(args,"--frames") || slice.contains(args,"--input") || slice.contains(args,"--capture")
}

// The arguments of the player with --capture and --input made absolute: they
// are paths of whoever runs the command, and the player runs in the engine.
play_arguments :: proc(args:[]string) -> []string {
    out:=slice.clone(args)
    for i:=0;i+1<len(out);i+=1 {
        if (out[i]=="--capture" || out[i]=="--input") && out[i+1]!="" {
            out[i+1]=project.path_absolute(out[i+1])
            i+=1
        }
    }
    return out
}

// Builds a target of a project. shaders_failed: the generation of its shaders
// failed and the library was built with the ones it had.
build_project :: proc(root:string,target:build.Target,args:[]string,mode:Build_Mode,server:=false) -> (code:int,output:string,shaders_failed:bool) {
    folder,out:=".",""
    named:=false
    for i:=0;i<len(args);i+=1 {
        if value,matched,ok:=option_value(args,&i,"--out");matched {
            if !ok || value=="" || target!=.Game {fmt.eprintfln("Usage: mirai %s",BUILD_PROJECT_USAGE);return 2,"",false}
            out=value
        } else if !positional(args[i]) || named {
            return argument_unknown("build",args[i]),"",false
        } else {
            folder,named=args[i],true
        }
    }
    // The plugins from git at the commits the project names: a fresh clone has none.
    if install.sync_needed(folder) {
        changed,message:=install.sync(folder,context.temp_allocator)
        if message!="" {fmt.eprintfln("mirai build: %s",message)}
        if changed>0 {fmt.printfln("%d plugins from Git moved to their commit.",changed)}
    }
    p,error:=project.open(folder,root)
    if error.code!=.None {
        fmt.eprintfln("mirai build: %s",project_error_text(folder,error))
        return 1,"",false
    }
    defer project.close(&p)
    // The binaries of the engine the libraries are built against.
    engine:=build.engine_mode_resolve(root,mode)
    paths:=build.project_engine(&p,engine,context.temp_allocator)
    engine_current:=target==.Game || build.engine_current(root,engine,paths.defines)
    // A project with sources goes on: its build imports what changed among them before it finds the library current.
    if target!=.Game && engine_current && len(build.imports_roots(&p))==0 && library_current(root,&p,target,engine,mode==.Dev) {
        _=engine_report({status=.Up_To_Date,mode=engine,folder=paths.folder},root)
        if os.is_file(project.path(project.shader_generation(p.root,context.temp_allocator),project.SHADERS_MANIFEST,allocator=context.temp_allocator)) {
            fmt.printfln("%s unchanged.",project.shader_generation(p.root,context.temp_allocator))
        }
        output=build.target_output(&p,target,"",context.allocator)
        fmt.printfln("%s unchanged.",output)
        session_take(p.root,paths)
        return 0,output,false
    }
    if !engine_current {engine_release(p.root,paths.folder,"build")}
    code,output,shaders_failed=build_project_run(root,&p,target,out,mode,paths,engine_current,server)
    if code==0 && target!=.Game {session_take(p.root,paths)}
    return
}

// What build_project does once it has to compile, in its turn.
@(private="file")
build_project_run :: proc(root:string,p:^project.Project,target:build.Target,out:string,mode:Build_Mode,engine:build.Engine_Paths,engine_current:bool,server:=false) -> (code:int,output:string,shaders_failed:bool) {
    lock:=build_lock(root,fmt.tprintf("build %v %s",target,p.root),{p.root})
    defer workspace.lock_release(&lock)
    // ui links the FreeType library, the importer that of ufbx and the editor that of SQLite.
    if !ensure_runtime_dependencies(root) {return 1,"",false}
    // The libraries of a project are built against the binaries of the engine;
    // the game, against its sources.
    if target!=.Game && engine_current {
        _=engine_report({status=.Up_To_Date,mode=engine.mode,folder=engine.folder},root)
    } else if target!=.Game {
        if code:=engine_report(build.engine_build({engine_root=root,mode=engine.mode,defines=engine.defines}),root);code!=0 {return code,"",false}
    } else if !engine_shaders(root,turn_held=true) {
        return 1,"",false
    }
    // The generation first: a game ships the one that is published, and a dedicated server none.
    if !server {
        generation:=build.shaders_run(p)
        defer build.shaders_destroy(generation)
        switch generation.result.status {
        case .Running,.None,.Cancelled:
        case .Up_To_Date: fmt.printfln("%s unchanged.",generation.result.output)
        case .Built:      fmt.printfln("%s ready (%.1f s): %d material programs, %d stages compiled and %d reused.",generation.result.output,generation.result.seconds,generation.result.programs,generation.result.compiled,generation.result.reused)
        case .Failed:
            shaders_failed=true
            fmt.eprintfln("mirai build: could not generate the shaders of the project: %s",generation.result.message)
            if target==.Game {return 1,"",true}
        }
        if generation.result.status!=.Failed && generation.result.message!="" {fmt.eprintln(generation.result.message)}
    }
    rebuilt:bool
    {
        job:=build.job_run({project=p,target=target,output=out,server=server,dev=mode==.Dev,engine=engine.mode})
        defer build.job_destroy(job)
        result:=&job.result
        for diagnostic in result.diagnostics {
            fmt.eprintfln("%s(%d:%d) %s: %s",diagnostic.file,diagnostic.line,diagnostic.column,diagnostic.severity==.Error?"Error":"Warning",diagnostic.message)
        }
        if compiled:=result.plugins_built-result.plugins_restored-result.plugins_relinked;compiled>0 {fmt.printfln("%s: %d plugin libraries built.",build.plugins_libraries_folder(p.root),compiled)}
        if result.plugins_relinked>0 {fmt.printfln("%s: %d plugin libraries linked again.",build.plugins_libraries_folder(p.root),result.plugins_relinked)}
        if result.plugins_restored>0 {fmt.printfln("%s: %d plugin libraries copied from the shared cache.",build.plugins_libraries_folder(p.root),result.plugins_restored)}
        switch result.status {
        case .Running:
        case .Built:      fmt.printfln("%s ready (%.1f s%s).",result.output,result.seconds,result.relinked?", linked again":"")
        case .Up_To_Date: fmt.printfln("%s unchanged.",result.output)
        case .Failed:
            if result.text!="" {fmt.eprintln(result.text)}
            switch result.failure {
            case .None,.Compile,.Shaders,.Tests:
            case .Out_Of_Memory:    fmt.eprintln(out_of_memory_text("mirai build"))
            case .Engine_Defines:
            case .Engine_Missing:   fmt.eprintln("mirai build: the engine root is unknown")
            case .Engine_Incomplete: fmt.eprintln("mirai build: the installed engine lacks some of its binaries: unpack its package again")
            case .Generate:         fmt.eprintln("mirai build: the attributes of the project packages do not generate a world")
            case .Compiler_Missing: fmt.eprintln("mirai build: cannot find the Odin compiler (MIRAI_ODIN, .deps/odin/dist or PATH); mirai doctor says where it looks")
            case .Compiler_Failed:  fmt.eprintln("mirai build: could not run the Odin compiler")
            case .Write_Failed:     fmt.eprintfln("mirai build: could not write to %s",project.folder_path(p.root,.Generated))
            case .Output_Locked:    fmt.eprintfln("mirai build: %s is in use and could not be replaced",result.output)
            case .Output_Invalid:   fmt.eprintln("mirai build: --out cannot be the project folder")
            case .Copy_Failed:      fmt.eprintfln("mirai build: could not copy the files that go with %s",result.output)
            case .Settings_Invalid: fmt.eprintln("mirai build: could not merge the settings of the engine and the project; fix or delete the file named above")
            case .Import_Failed:    fmt.eprintln("mirai build: a source of the project did not import")
            case .Cook_Failed:      fmt.eprintfln("mirai build: could not cook the assets: %v %s",result.cook.error,result.cook.detail)
            case .Cancelled:        fmt.eprintln("mirai build: cancelled")
            case .Engine_Time_Code:
                fmt.eprintln("mirai build: the game imports engine-time packages, which are not shipped:")
                for folder in result.engine_time {fmt.eprintfln("  %s",folder)}
            }
            if result.failure==.Compile {fmt.eprintfln("mirai build: could not build %s",result.output)}
            return 1,"",shaders_failed
        }
        if target==.Game && !shipped_report(job) {return 1,"",shaders_failed}
        output=strings.clone(result.output)
        rebuilt=result.status==.Built
    }
    if target==.Editor && rebuilt && !editor_methods_register(root,p.root,engine) {return 1,"",shaders_failed}
    return 0,output,shaders_failed
}

// Whether an editor of the build registers every method of the project and
// its plugins: each library has its own types, which only a run of the
// libraries together shows. It prints the methods that did not register.
@(private="file")
editor_methods_register :: proc(root,folder:string,engine:build.Engine_Paths) -> bool {
    command:=[]string{engine.editor_program,"--project",folder,"--headless","--no-gpu","--frames","1","--no-api"}
    state,_,stderr,error:=subprocess.exec({command=command,working_dir=root},context.temp_allocator)
    if error!=nil {
        fmt.eprintfln("mirai build: could not run %s to check its API: %v",command[0],error)
        return false
    }
    if state.exit_code==0 {return true}
    fmt.eprintfln("mirai build: the built editor does not open the API of %s (exit code %d):\n%s",folder,state.exit_code,string(stderr))
    return false
}

// Why the compiler stopped at the memory it may use, and how to go on.
out_of_memory_text :: proc(command:string) -> string {
    memory,_:=build.compiler_memory()
    stopped:=memory>0?fmt.tprintf("went past its limit of %.1f GiB of memory and was stopped",f64(memory)/(1<<30)):"ran out of memory"
    return fmt.tprintf("%s: the compiler %s. Most likely it is a multiple assignment of values larger than 64 bytes (odin-lang/Odin#7937), like a,b=b,a with large structs or a ternary between them: write one value per assignment. mirai test cook/build no_store_of_an_aggregate_of_more_than_64_bytes finds it in the engine and the demo. If the build really needs more, raise %s (GiB; 0: no limit).",
        command,stopped,build.COMPILER_MEMORY_ENV)
}

// The binaries of the engine the project at folder runs in mode: those built
// with the defines of its manifest the engine reads.
project_engine_paths :: proc(root,folder:string,mode:Build_Mode) -> build.Engine_Paths {
    manifest,_:=project.manifest_read(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator))
    return build.engine_paths(root,mode,context.temp_allocator,build.engine_defines(root,build.manifest_defines(&manifest,context.temp_allocator),context.temp_allocator))
}

// Whether building a library of a project against a current engine would
// compile nothing: the C libraries, the shaders of the project and the
// library stand. What has nothing to compile takes no turn.
@(private="file")
library_current :: proc(root:string,p:^project.Project,target:build.Target,engine:Build_Mode,dev:bool) -> bool {
    return c_libraries_current(root) && build.shaders_current(p) && build.target_state(p,target,"",dev,engine)==.Current
}

// The value after args[index^], advancing the index past it; false at their end.
option_next :: proc(args:[]string,index:^int) -> (value:string,ok:bool) {
    if index^+1>=len(args) {return "",false}
    index^+=1
    return args[index^],true
}

// The value of `--name value` or `--name=value` at args[index^]; advances the index past it.
option_value :: proc(args:[]string,index:^int,name:string) -> (value:string,matched,ok:bool) {
    argument:=args[index^]
    if argument==name {
        value,ok=option_next(args,index)
        return value,true,ok
    }
    if strings.has_prefix(argument,name) && len(argument)>len(name) && argument[len(name)]=='=' {return argument[len(name)+1:],true,true}
    return "",false,false
}

project_error_text :: proc(folder:string,error:project.Error) -> string {return project.error_text(folder,error)}

// What a game ships: the report of its cook, every cooked asset verified and
// the size of its folder. False when an asset of the output is not valid.
@(private="file")
shipped_report :: proc(job:^build.Job) -> bool {
    result:=&job.result
    folder:=result.output[:max(strings.last_index_byte(result.output,'/'),0)]
    bad:=0
    if job.cook.assets!="" {
        fmt.print(build.cook_summary(&result.cook,context.temp_allocator))
        types:asset.Types
        asset.types_init(&types)
        defer asset.types_destroy(&types)
        verified:=0
        for file in result.cook.files {
            if file.id=={} {continue}
            path:=fmt.tprintf("%s/%s",job.cook.output,file.path)
            if reason:=verify(path,&types);reason!="" {
                bad+=1
                fmt.eprintfln("FAIL %s: %s",path,reason)
            } else {
                verified+=1
            }
        }
        fmt.printfln("%d assets verified%s",verified,bad>0?fmt.tprintf(", %d with errors",bad):"")
    }
    total:i64
    files:=0
    walker:=os.walker_create(folder)
    defer os.walker_destroy(&walker)
    for info in os.walker_walk(&walker) {
        if info.type==.Regular {total+=info.size;files+=1}
    }
    fmt.printfln("%s: %d files, %.2f MB",folder,files,f64(total)/(1<<20))
    return bad==0
}
