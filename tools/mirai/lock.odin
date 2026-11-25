package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:cook/build"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/subprocess"

// The compilations of every checkout of the repository share a few turns,
// as many as the memory holds, and go one at a time within a folder they write
// (workspace.build_acquire). One that waits says for whom. A measurement does
// not stop them: what they compile while it runs runs at low priority
// (build.compiler_limits), and it can tell that they ran
// (workspace.builds_since). When the lock cannot be taken the build goes on
// without it. This one writes the engine: its folder is held.
build_lock :: proc(root,what:string) -> workspace.Lock {return build_lock_folders(root,what,{root})}

// The turn of a build of a project, which holds the folder of the project:
// the engine only for its game, which compiles the engine from its sources and
// writes the test worlds of its packages. A library, a test or a program of
// the project builds against binaries of the engine project_engine_ready made
// current first, so two projects build side by side.
project_lock :: proc(root,what,project_root:string,target:build.Target) -> workspace.Lock {
    if target==.Game {return build_lock_folders(root,what,{root,project_root})}
    return build_lock_folders(root,what,{project_root})
}

@(private="file")
build_lock_folders :: proc(root,what:string,folders:[]string) -> workspace.Lock {
    holder:=fmt.tprintf("pid %d, mirai %s in %s",os.get_pid(),what,root)
    lock,_:=workspace.build_acquire(root,holder,folders,build_wait_notice)
    build_lock_measured(root)
    return lock
}

// Builds the binaries of the engine a project's libraries link, with the
// defines of the project, unless they are current: in a turn of their own that
// holds the folder of the engine only while they build, so the build of a
// project that follows holds its own folder alone and another project builds
// beside it. What the build says goes to stderr; false when it failed.
project_engine_ready :: proc(root:string,p:^project.Project,mode:build.Engine_Mode,what:string) -> bool {
    engine:=build.project_engine(p,mode,context.temp_allocator)
    if c_libraries_current(root) && build.engine_current(root,mode,engine.defines) {return true}
    lock:=build_lock(root,fmt.tprintf("%s: build engine",what))
    defer workspace.lock_release(&lock)
    if !ensure_runtime_dependencies(root) {return false}
    return engine_report(build.engine_build({engine_root=root,mode=mode,defines=engine.defines}),root,os.stderr)==0
}

// The turn of a generation of shaders, which waits for no compilation of
// another checkout.
shaders_lock :: proc(root:string) -> workspace.Lock {
    holder:=fmt.tprintf("pid %d, mirai shaders in %s",os.get_pid(),root)
    lock,_:=workspace.shaders_acquire(root,holder,build_wait_notice)
    build_lock_measured(root)
    return lock
}

@(private="file")
build_wait_notice :: proc(holder:string) {
    fmt.eprintfln("mirai: waiting for another build to finish (%s)",holder!=""?holder:"another process")
}

@(private="file")
build_lock_measured :: proc(root:string) {
    if measured,measurer:=workspace.measured(root,false,allocator=context.temp_allocator);measured==.Low {
        fmt.eprintfln("mirai: a measurement is running (%s); building at low priority",measurer)
    }
}

// Takes the measurement lock: waits for another measurement, then for the
// compilations and the GPU work of others that run (workspace.measure_try),
// so that what follows runs alone. Not held when this process is part of a
// measurement that holds it already. Taken only for what is timed.
measure_lock :: proc(root,what:string) -> workspace.Lock {
    holder:=workspace.measure_holder(fmt.tprintf("mirai %s in %s",what,root))
    lock,_,_,_:=workspace.measure_try(root,holder,workspace.MEASURE_WAIT_ALL,notice=proc(why:workspace.Measure_Wait,holder:string) {
        #partial switch why {
        case .Measurement: fmt.eprintfln("mirai: waiting for another measurement to finish (%s)",holder)
        case .Build:       fmt.eprintfln("mirai: waiting for the builds to finish before measuring (%s)",holder)
        case .Gpu:         fmt.eprintfln("mirai: waiting for the GPU work in flight to finish before measuring (%s)",holder)
        }
    })
    return lock
}

// Says this process is part of the measurement it takes or is part of
// already: what it starts from now on, as the editors it measures, is too.
measure_env_set :: proc() {
    if !workspace.measuring() {_=os.set_env(workspace.MEASURE_ENV,fmt.tprintf("%d",os.get_pid()))}
}

// What else loads the GPU while a measurement draws nothing
// (workspace.gpu_load), printed by the command that measures.
measure_load_say :: proc(command,when_:string,own:=[]int{}) {
    warnings:=make([dynamic]string,context.temp_allocator)
    workspace.gpu_load(&warnings,own,when_,true)
    for warning in warnings {fmt.eprintfln("mirai %s: %s",command,warning)}
}

LOCKS_USAGE :: "locks"

// mirai locks: who holds each lock the checkouts of the repository share,
// those of compilations and measurements among them, and since when; the
// turns of the GPU together; and which compilation took its turn last.
cmd_locks :: proc(root:string,args:[]string) -> int {
    if len(args)>0 {return argument_unknown("locks",args[0])}
    folder:=workspace.cache_folder(root,"locks",context.temp_allocator)
    names:=make([dynamic]string,context.temp_allocator)
    append(&names,workspace.BUILD_LOCK,workspace.MEASURE_LOCK)
    if entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator);error==nil {
        for entry in entries {
            if !strings.has_suffix(entry.name,".lock") || slice.contains(names[:],entry.name) {continue}
            if entry.name==workspace.GPU_ADMISSION_LOCK || strings.has_prefix(entry.name,"gpu-") {continue}
            append(&names,entry.name)
        }
    }
    slice.sort(names[2:])
    fmt.printfln("Turns of the checkouts of %s (%s):",project.shared_root(root,context.temp_allocator),folder)
    now:=time.now()
    for name in names {
        label:=strings.trim_suffix(name,".lock")
        switch name {
        case workspace.BUILD_LOCK:   label="build"
        case workspace.MEASURE_LOCK: label="measurement"
        }
        held,holder,since:=workspace.lock_holder(join(folder,name),context.temp_allocator)
        if !held {fmt.printfln("  %-14s free",label);continue}
        fmt.printf("  %-14s %s",label,holder!=""?holder:"a process that does not say which")
        if since!={} {fmt.printf(", for %s",duration_text(time.diff(since,now)))}
        fmt.println()
    }
    gpu_turns_print(root)
    note:=workspace.lock_path(root,workspace.BUILD_NOTE,context.temp_allocator)
    if info,error:=os.stat(note,context.temp_allocator);error==nil {
        last,_:=os.read_entire_file(note,context.temp_allocator)
        fmt.printfln("The last build took its turn %s ago: %s",duration_text(time.diff(info.modification_time,now)),strings.trim_space(string(last)))
    }
    return 0
}

// A duration for a person: seconds, minutes or hours and minutes.
duration_text :: proc(duration:time.Duration) -> string {
    seconds:=max(int(time.duration_seconds(duration)),0)
    switch {
    case seconds<60:   return fmt.tprintf("%d s",seconds)
    case seconds<3600: return fmt.tprintf("%d min",seconds/60)
    }
    return fmt.tprintf("%d h %d min",seconds/3600,seconds%3600/60)
}

MEASURE_USAGE :: "measure [--] <command> [arguments...]"

// mirai measure: runs a command that measures time alone among the
// checkouts, with its children, holding the measurement for as long as it
// runs: they are part of the measurement (workspace.MEASURE_ENV), so their
// compilations take turns as usual and nothing of theirs waits for it. What
// else loads the GPU is said before and after it.
cmd_measure :: proc(root:string,args:[]string) -> int {
    command:=args
    if len(command)>0 && command[0]=="--" {command=command[1:]}
    if len(command)==0 {fmt.eprintfln("Usage: mirai %s",MEASURE_USAGE);return 2}
    if len(command)==len(args) && !positional(command[0]) {return argument_unknown("measure",command[0])}
    resolved,found:=script_command(command)
    if !found {return 127}
    lock:=measure_lock(root,fmt.tprintf("measure %s",strings.join(command," ",context.temp_allocator)))
    defer workspace.lock_release(&lock)
    measure_env_set()
    measure_load_say("measure","before the command")
    process,error:=subprocess.start({command=resolved,stdin=os.stdin,stdout=os.stdout,stderr=os.stderr})
    if error!=nil {fmt.eprintfln("mirai measure: could not run %s: %v",command[0],error);return 127}
    state,wait_error:=subprocess.wait(&process)
    if wait_error!=nil {fmt.eprintfln("mirai measure: %s: %v",command[0],wait_error);return 127}
    measure_load_say("measure","after the command")
    return state.exit_code
}

// Vulkan loads the implicit layers that overlays install (Steam, OBS, Epic)
// into every process, and reports as an error of the loader one whose
// manifest is gone. An agent runs tests and headless programs without them:
// the loader looks for implicit layers in an empty folder instead of the
// registry. MIRAI_KEEP_LAYERS=1 keeps them.
layers_isolate :: proc(root:string) {
    if keep,found:=os.lookup_env("MIRAI_KEEP_LAYERS",context.temp_allocator);found && keep!="" && keep!="0" {return}
    if _,set:=os.lookup_env("VK_IMPLICIT_LAYER_PATH",context.temp_allocator);set {return}
    empty:=workspace.cache_folder(root,"vulkan-without-implicit-layers",context.temp_allocator)
    if os.make_directory_all(empty)!=nil && !os.is_dir(empty) {return}
    _=os.set_env("VK_IMPLICIT_LAYER_PATH",empty)
}
