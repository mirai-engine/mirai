package subprocess

import "base:runtime"
import "core:os"
import "core:strings"
import "core:time"

// Child processes that open no window. The process returned is the one of
// core:os: process_wait, process_kill and process_terminate apply to it, and
// process_wait frees it.
//
// On Windows a child inherits only its stdin, stdout and stderr, never the
// other handles of this process. A console program started by a process
// without a console gets a console of its own, and Windows shows it unless
// told not to: here it has none, while a child of a process with a console
// shares it, so that Ctrl+C and the terminal still reach it.

// What a child may use; zero is no limit.
Limits :: struct {
    // Bytes each process of the child, and each one it starts, may commit:
    // past them its allocations fail. Windows (a job object) and Linux
    // (RLIMIT_DATA, set once the child runs) apply it; macOS does not.
    memory:u64,
    priority:Priority,
}

// The scheduling priority of a child; the processes it starts keep it.
// Low is below normal on Windows and 10 more niceness than this process on
// POSIX, set once the child runs: on Linux it reaches the threads the child
// starts after that.
Priority :: enum u8 {Normal,Low}

// Like os.process_start. A nil stream is the null device. The error is
// .Invalid_Command for an empty command or program, an argument with a NUL
// byte or an env entry without a name.
start :: proc(desc:os.Process_Desc,limits:=Limits{}) -> (process:os.Process,error:os.Error) {
    if !desc_valid(desc.command,desc.env) {return {},.Invalid_Command}
    return _start(desc,limits)
}

// Whether a process with that pid runs, whoever started it.
process_alive :: proc(pid:int) -> bool {
    if pid<=0 {return false}
    process,error:=os.process_open(pid)
    // Odin workaround (docs/ODIN_WORKAROUNDS.md): on Windows a process that is gone opens without an error and with no handle.
    if error!=nil || process.handle==0 {return false}
    // Opened, it exists; the wait tells an ended one that something still holds
    // apart, and fails with ECHILD for one this process did not start.
    state,wait_error:=os.process_wait(process,0)
    // process_wait leaves the process open only when it is still running.
    if wait_error==os.General_Error.Timeout {process_close(process)}
    return !state.exited
}

// Runs the command to its end and returns what it wrote to stdout and to
// stderr, in allocator, also when error is not nil. The streams of desc are
// replaced by the captured ones.
exec :: proc(desc:os.Process_Desc,allocator:runtime.Allocator,limits:=Limits{}) -> (state:os.Process_State,stdout,stderr:[]byte,error:os.Error) {
    if !desc_valid(desc.command,desc.env) {return {},nil,nil,.Invalid_Command}
    out_read,out_write:=os.pipe() or_return
    defer os.close(out_read)
    err_read,err_write,pipe_error:=os.pipe()
    if pipe_error!=nil {
        os.close(out_write)
        return {},nil,nil,pipe_error
    }
    defer os.close(err_read)
    process:os.Process
    {
        // Without the write ends here, the read ends end when the child does.
        defer os.close(out_write)
        defer os.close(err_write)
        captured:=desc
        captured.stdout=out_write
        captured.stderr=err_write
        process=_start(captured,limits) or_return
    }
    out:=make([dynamic]byte,allocator)
    errs:=make([dynamic]byte,allocator)
    buffer:[4096]byte
    out_open,err_open:=true,true
    // Polls without pause while output flows, and sleeps once both pipes have
    // stayed empty for a millisecond: a pause after every empty poll caps the
    // throughput at a few MB/s.
    quiet_since:time.Tick
    quiet:=false
    for error==nil && (out_open || err_open) {
        idle:=true
        if out_open {out_open,error=drain(out_read,&out,buffer[:],&idle)}
        if error==nil && err_open {err_open,error=drain(err_read,&errs,buffer[:],&idle)}
        if !idle {quiet=false;continue}
        if !quiet {quiet,quiet_since=true,time.tick_now();continue}
        if time.tick_since(quiet_since)>=time.Millisecond {time.sleep(time.Millisecond)}
    }
    stdout=out[:]
    stderr=errs[:]
    if error!=nil {
        if state,_=os.process_wait(process,0);!state.exited {
            _=os.process_kill(process)
            state,_=os.process_wait(process)
        }
        return
    }
    state,error=os.process_wait(process)
    return
}

// Starts command so that it outlives this process: it writes stdout and
// stderr to log, which it truncates, reads the null device and holds no
// other handle of this process. On Windows it has a console of its own
// without a window, and leaves the job of this process when the job allows
// it.
detached :: proc(command:[]string,log,working_dir:string) -> (process:os.Process,error:os.Error) {
    if !desc_valid(command,nil) {return {},.Invalid_Command}
    file:=os.open(log,{.Write,.Create,.Trunc}) or_return
    defer os.close(file)
    return _detached(command,file,working_dir)
}

// The name of a "NAME=VALUE" entry. On Windows a name can start with '='
// ("=C:=C:\\work").
@(private)
variable_name :: proc(entry:string) -> (name:string,ok:bool) {
    if len(entry)<2 {return "",false}
    cut:=strings.index_byte(entry[1:],'=')
    if cut<0 {return "",false}
    return entry[:cut+1],true
}

@(private)
desc_valid :: proc(command,env:[]string) -> bool {
    if len(command)==0 || command[0]=="" {return false}
    for argument in command {
        if strings.index_byte(argument,0)>=0 {return false}
    }
    for entry in env {
        if _,ok:=variable_name(entry);!ok || strings.index_byte(entry,0)>=0 {return false}
    }
    return true
}

// Appends what the pipe holds. open is false once the writer is gone.
@(private="file")
drain :: proc(pipe:^os.File,into:^[dynamic]byte,buffer:[]byte,idle:^bool) -> (open:bool,error:os.Error) {
    for {
        ready,ready_error:=os.pipe_has_data(pipe)
        count:=0
        read_error:=ready_error
        if ready_error==nil {
            if !ready {return true,nil}
            count,read_error=os.read(pipe,buffer)
        }
        switch read_error {
        case nil:
        case .EOF,.Broken_Pipe: return false,nil
        case: return false,read_error
        }
        if count==0 {return true,nil}
        idle^=false
        if _,append_error:=append(into,..buffer[:count]);append_error!=nil {return false,append_error}
    }
}
