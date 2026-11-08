package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/subprocess"

// The compilations of every checkout of the repository share a few turns,
// as many as the memory holds, and go one at a time within a checkout or a
// project (workspace.build_acquire). One that waits says for whom. A
// measurement does not stop them: what they compile while it runs runs at low
// priority (build.compiler_limits), and it can tell that they ran
// (workspace.builds_since). When the lock cannot be taken the build goes on
// without it. also: the folders of what it writes besides root.
build_lock :: proc(root,what:string,also:=[]string{}) -> workspace.Lock {
    holder:=fmt.tprintf("pid %d, mirai %s in %s",os.get_pid(),what,root)
    lock,_:=workspace.build_acquire(root,holder,build_wait_notice,also)
    build_lock_measured(root)
    return lock
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
    if measured,measurer:=workspace.measurement_running(root,context.temp_allocator);measured {
        fmt.eprintfln("mirai: a measurement is running (%s); building at low priority",measurer!=""?measurer:"another process")
    }
}

// Takes the measurement lock: waits for another measurement and then for the
// compilations that run, so that what follows runs alone. Not held when this
// process is part of a measurement already.
measure_lock :: proc(root,what:string) -> workspace.Lock {
    if workspace.measuring() {return {}}
    holder:=fmt.tprintf("pid %d, mirai %s in %s",os.get_pid(),what,root)
    lock,_:=workspace.lock_acquire(workspace.lock_path(root,workspace.MEASURE_LOCK,context.temp_allocator),holder,proc(holder:string) {
        fmt.eprintfln("mirai: waiting for another measurement to finish (%s)",holder!=""?holder:"another process")
    })
    workspace.builds_wait(root,proc(holder:string) {
        fmt.eprintfln("mirai: waiting for the builds to finish before measuring (%s)",holder!=""?holder:"another process")
    })
    return lock
}

LOCKS_USAGE :: "locks"

// mirai locks: who holds each lock the checkouts of the repository share,
// those of compilations and measurements among them, and since when; and
// which compilation took its turn last.
cmd_locks :: proc(root:string,args:[]string) -> int {
    if len(args)>0 {fmt.eprintfln("Usage: mirai %s",LOCKS_USAGE);return 2}
    folder:=workspace.cache_folder(root,"locks",context.temp_allocator)
    names:=make([dynamic]string,context.temp_allocator)
    append(&names,workspace.BUILD_LOCK,workspace.MEASURE_LOCK)
    if entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator);error==nil {
        for entry in entries {
            if strings.has_suffix(entry.name,".lock") && !slice.contains(names[:],entry.name) {append(&names,entry.name)}
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
// checkouts, with its children: they are part of the measurement
// (workspace.MEASURE_ENV), so their compilations take turns as usual and
// nothing of theirs waits for it.
cmd_measure :: proc(root:string,args:[]string) -> int {
    command:=args
    if len(command)>0 && command[0]=="--" {command=command[1:]}
    if len(command)==0 {fmt.eprintfln("Usage: mirai %s",MEASURE_USAGE);return 2}
    lock:=measure_lock(root,fmt.tprintf("measure %s",strings.join(command," ",context.temp_allocator)))
    defer workspace.lock_release(&lock)
    if !workspace.measuring() {_=os.set_env(workspace.MEASURE_ENV,fmt.tprintf("%d",os.get_pid()))}
    resolved,found:=script_command(command)
    if !found {return 127}
    process,error:=subprocess.start({command=resolved,stdin=os.stdin,stdout=os.stdout,stderr=os.stderr})
    if error!=nil {fmt.eprintfln("mirai measure: could not run %s: %v",command[0],error);return 127}
    state,wait_error:=os.process_wait(process)
    if wait_error!=nil {fmt.eprintfln("mirai measure: %s: %v",command[0],wait_error);return 127}
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
