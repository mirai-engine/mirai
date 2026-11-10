package shaders

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "mirai:cook/workspace"
import "mirai:std/subprocess"
import "mirai:project"

Tool :: enum {Slangc,Spirv_Val,Spirv_Opt,Spirv_Cross}

@(private)
TOOL_NAMES :: [Tool]string{.Slangc="slangc",.Spirv_Val="spirv-val",.Spirv_Opt="spirv-opt",.Spirv_Cross="spirv-cross"}

// The tool the environment names (MIRAI_SLANGC or MIRAI_SLANG, for the
// compiler), then the one installed under the deps of root
// (workspace.deps_folder: also from a worktree), then PATH. What a
// checkout installed comes before PATH: an editor has no SDK in its PATH, and
// a slangc that happens to be there is not the pinned one.
tool_find :: proc(root:string,tool:Tool,allocator:=context.allocator) -> (path:string,ok:bool) {
    names:=TOOL_NAMES
    executable:=strings.concatenate({names[tool],project.EXECUTABLE_SUFFIX},context.temp_allocator)
    if tool==.Slangc {
        for variable in ([]string{"MIRAI_SLANGC","MIRAI_SLANG"}) {
            if configured,found:=os.lookup_env(variable,context.temp_allocator);found && configured!="" {return path_clean(configured,allocator),true}
        }
        candidate:=path_join(workspace.deps_folder(root,context.temp_allocator),"slang/bin",executable,allocator=context.temp_allocator)
        if os.is_file(candidate) {return strings.clone(candidate,allocator),true}
    } else {
        // In a folder one, two or three levels below .deps, the shallowest first.
        deps:=workspace.deps_folder(root,context.temp_allocator)
        level:=make([dynamic]string,context.temp_allocator)
        append(&level,deps)
        for _ in 0..<3 {
            next:=make([dynamic]string,context.temp_allocator)
            for directory in level {
                entries,err:=os.read_all_directory_by_path(directory,context.temp_allocator)
                if err!=nil {continue}
                for entry in entries {
                    child:=path_join(directory,entry.name,allocator=context.temp_allocator)
                    if os.is_directory(child) {append(&next,child)}
                }
            }
            slice.sort_by(next[:],path_less)
            for directory in next {
                candidate:=path_join(directory,executable,allocator=context.temp_allocator)
                if os.is_file(candidate) {return strings.clone(candidate,allocator),true}
            }
            level=next
        }
    }
    search,_:=os.lookup_env("PATH",context.temp_allocator)
    directories,_:=os.split_path_list(search,context.temp_allocator)
    for directory in directories {
        if directory=="" {continue}
        candidate:=path_clean(path_join(directory,executable,allocator=context.temp_allocator),context.temp_allocator)
        if os.is_file(candidate) {return strings.clone(candidate,allocator),true}
    }
    return "",false
}

// Tools that run at once: one for each worker of a generation.
@(private)
RUNNER_CAPACITY :: 64

// Starting a process hands it every inheritable handle of this one, the pipes
// of the tools other threads are running among them. Starts are serialized so
// a tool only ever holds the writing end of its own pipe. A runner that is
// cancelled starts no tool and has killed those that ran.
@(private)
Runner :: struct {
    lock:     sync.Mutex,
    runs:     int,  // tools run since the runner was made (guarded by lock)
    cancelled:bool, // guarded by lock
    running:  [RUNNER_CAPACITY]os.Process, // the tools started and not yet waited for (guarded by lock)
    running_count:int,
}

// Runs a tool and returns what it wrote to stdout and stderr, in the order it
// wrote it. ok: it could be started and exited with zero.
@(private)
tool_run :: proc(runner:^Runner,command:[]string,allocator:=context.allocator) -> (output:string,ok:bool) {
    reader,writer:^os.File
    process:os.Process
    {
        sync.guard(&runner.lock)
        if runner.cancelled {return strings.clone("the generation was cancelled",allocator),false}
        runner.runs+=1
        pipe_error:os.Error
        reader,writer,pipe_error=os.pipe()
        if pipe_error!=nil {return strings.clone("could not create the pipe of the tool",allocator),false}
        start_error:os.Error
        process,start_error=subprocess.start({command=command,stdout=writer,stderr=writer})
        os.close(writer)
        if start_error!=nil {
            os.close(reader)
            return strings.concatenate({"could not run ",command[0]},allocator),false
        }
        if runner.running_count<RUNNER_CAPACITY {
            runner.running[runner.running_count]=process
            runner.running_count+=1
        }
    }
    collected:=make([dynamic]u8,allocator)
    buffer:[4096]u8
    for {
        count,read_error:=os.read(reader,buffer[:])
        if count>0 {append(&collected,..buffer[:count])}
        if read_error!=nil || count<=0 {break}
    }
    os.close(reader)
    // Out of the list before it is waited for: a process waited for may give its id to another one.
    {
        sync.guard(&runner.lock)
        for i in 0..<runner.running_count {
            if runner.running[i].pid!=process.pid {continue}
            runner.running_count-=1
            runner.running[i]=runner.running[runner.running_count]
            break
        }
    }
    state,wait_error:=os.process_wait(process)
    return string(lf_bytes(collected[:])),wait_error==nil && state.exited && state.exit_code==0
}

// No tool starts any more and those running are killed: their runs fail.
@(private)
runner_cancel :: proc(runner:^Runner) {
    sync.guard(&runner.lock)
    runner.cancelled=true
    for process in runner.running[:runner.running_count] {_=os.process_kill(process)}
}

@(private)
runner_cancelled :: proc(runner:^Runner) -> bool {
    sync.guard(&runner.lock)
    return runner.cancelled
}
