package subprocess

import "base:runtime"
import "core:os"
import "core:strings"
import "core:time"

// Child processes that open no window and inherit no handle of this process
// but their streams. A child and every process it starts end as one tree:
// with this process however it ends, on terminate and release, and once wait
// sees the child exit. Only a detached child leaves it. Windows holds the tree
// in a job object that kills it as its handle closes; POSIX in a process group
// with a watcher that kills the group once this process is gone.

// A child and its tree. The zero value is no process. wait, terminate and
// release take it by pointer: it keeps the exit once wait saw it.
Process :: struct {
    pid:int,
    handle:uintptr, // what core:os waits on; 0 once the exit was taken
    tree:uintptr,   // Windows: the job; POSIX: the pid of the watcher; 0 when detached
    // The ends of the pipes this process holds, nil for a stream that is not one.
    stdin,stdout,stderr:^os.File,
    state:os.Process_State, // the exit, once state.exited
}

// Pipes that start gives back: stdout and stderr each, or both through
// stdout in the order they were written; stdin too unless desc gives one.
Pipes :: enum u8 {None,Separate,Merged}
Stream :: enum u8 {Stdout,Stderr}

// What a child may use; zero is no limit.
Limits :: struct {
    // Bytes each process of the child, and each one it starts, may commit:
    // past them its allocations fail. Windows (the job) and Linux
    // (RLIMIT_DATA) apply it before the child runs; macOS does not.
    memory:u64,
    priority:Priority,
}

// The scheduling priority of a child; the processes it starts keep it.
// Low is below normal on Windows and 10 more niceness than this process on
// POSIX.
Priority :: enum u8 {Normal,Low}

// Like os.process_start. A nil stream is the null device, unless pipes makes
// it a pipe. The error is .Invalid_Command for an empty command or program,
// an argument with a NUL byte or an env entry without a name. env replaces
// the environment of this process; of a name given twice, the last one wins.
start :: proc(desc:os.Process_Desc,limits:=Limits{},pipes:=Pipes.None) -> (process:Process,error:os.Error) {
    if !desc_valid(desc.command,desc.env) {return {},.Invalid_Command}
    if pipes==.None {return _start(desc,limits)}
    // The ends the child gets close here once it has them.
    child:=desc
    theirs:[3]^os.File
    defer for file in theirs {
        if file!=nil {os.close(file)}
    }
    defer if error!=nil {pipes_close(&process)}
    if desc.stdin==nil {
        child.stdin,process.stdin=os.pipe() or_return
        theirs[0]=child.stdin
        _stdin_nonblocking(process.stdin)
    }
    process.stdout,child.stdout=os.pipe() or_return
    theirs[1]=child.stdout
    child.stderr=child.stdout
    if pipes==.Separate {
        process.stderr,child.stderr=os.pipe() or_return
        theirs[2]=child.stderr
    }
    started:=_start(child,limits) or_return
    started.stdin,started.stdout,started.stderr=process.stdin,process.stdout,process.stderr
    return started,nil
}

// Like os.process_wait, and the state stays in process. Once the child
// exited, what it left running is ended. A timeout that passes is the error
// .Timeout.
wait :: proc(process:^Process,timeout:=os.TIMEOUT_INFINITE) -> (state:os.Process_State,error:os.Error) {
    if process.pid==0 {return {},.Not_Exist}
    if process.state.exited {return process.state,nil}
    state=os.process_wait({pid=process.pid,handle=process.handle},timeout) or_return
    process.state,process.handle=state,0
    _tree_close(process)
    return
}

// Ends the child and every process it started: at once with force, or
// asking them on POSIX (SIGTERM; Windows has no asking).
terminate :: proc(process:^Process,force:=false) -> os.Error {
    if process.pid==0 {return .Not_Exist}
    if process.state.exited {return nil}
    return _terminate(process,force)
}

// Ends the tree of a child that still runs and frees all it holds.
release :: proc(process:^Process) {
    if process.pid!=0 && !process.state.exited {
        _=terminate(process,force=true)
        _,_=wait(process)
    }
    pipes_close(process)
    process^={}
}

// Reads what the child has written so far to a stream that start made a
// pipe, up to len(buffer), without waiting. open is false once the stream
// ended and everything was read. It does not allocate.
read :: proc(process:^Process,stream:Stream,buffer:[]byte) -> (count:int,open:bool) {
    file:=&process.stdout if stream==.Stdout else &process.stderr
    if file^==nil {return 0,false}
    for count<len(buffer) {
        ready,error:=os.pipe_has_data(file^)
        if error==nil && !ready {return count,true}
        read:=0
        if error==nil {read,error=os.read(file^,buffer[count:])}
        if error!=nil || read<=0 {
            os.close(file^)
            file^=nil
            return count,count>0
        }
        count+=read
    }
    return count,true
}

// The pipe never gets more than this in one write: on Windows it holds 4 KB
// and a larger write that does not fit delivers nothing.
@(private)
PIPE_WRITE_BYTES :: 4096

// Writes to the stdin pipe of the child without waiting and returns how much
// of data the pipe took; the rest has to be sent again later. It does not
// allocate.
write :: proc(process:^Process,data:[]byte) -> int {
    if process.stdin==nil {return 0}
    sent:=0
    for sent<len(data) {
        size:=min(len(data)-sent,PIPE_WRITE_BYTES)
        written,_:=os.write(process.stdin,data[sent:sent+size])
        sent+=max(written,0)
        if written<size {break}
    }
    return sent
}

// The child reads end of file on its stdin pipe.
stdin_close :: proc(process:^Process) {
    if process.stdin==nil {return}
    os.close(process.stdin)
    process.stdin=nil
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
// stderr, in allocator, also when error is not nil. The stdout and stderr
// of desc are replaced by the captured ones.
exec :: proc(desc:os.Process_Desc,allocator:runtime.Allocator,limits:=Limits{}) -> (state:os.Process_State,stdout,stderr:[]byte,error:os.Error) {
    captured:=desc
    captured.stdout,captured.stderr=nil,nil
    process:=start(captured,limits,.Separate) or_return
    defer release(&process)
    stdin_close(&process)
    out:=make([dynamic]byte,allocator)
    errs:=make([dynamic]byte,allocator)
    buffer:[4096]byte
    // Both pipes are drained as they fill, so that neither stops the child.
    // It polls without pause while output flows, and sleeps once both have
    // stayed empty for a millisecond: a pause after every empty poll caps the
    // throughput at a few MB/s.
    quiet_since:time.Tick
    quiet:=false
    for error==nil && (process.stdout!=nil || process.stderr!=nil) {
        idle:=true
        for stream in Stream {
            count,_:=read(&process,stream,buffer[:])
            if count==0 {continue}
            idle=false
            _,error=append(&out if stream==.Stdout else &errs,..buffer[:count])
        }
        if !idle {quiet=false;continue}
        if !quiet {quiet,quiet_since=true,time.tick_now();continue}
        if time.tick_since(quiet_since)>=time.Millisecond {time.sleep(time.Millisecond)}
    }
    stdout,stderr=out[:],errs[:]
    if error!=nil {return}
    state,error=wait(&process)
    return
}

// Starts a child that outlives this process, out of any tree: on POSIX in a
// session of its own, on Windows with a console of its own without a window
// and out of the job of this process when the job allows it. It holds no
// other handle of this process.
detached :: proc(desc:os.Process_Desc) -> (process:Process,error:os.Error) {
    if !desc_valid(desc.command,desc.env) {return {},.Invalid_Command}
    return _detached(desc)
}

@(private)
pipes_close :: proc(process:^Process) {
    for file in ([]^os.File{process.stdin,process.stdout,process.stderr}) {
        if file!=nil {os.close(file)}
    }
    process.stdin,process.stdout,process.stderr=nil,nil,nil
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

// Whether no later entry of env sets the name of env[i]. Windows compares
// names without case.
@(private)
variable_last :: proc(env:[]string,i:int) -> bool {
    name,_:=variable_name(env[i])
    for later in env[i+1:] {
        later_name,_:=variable_name(later)
        if strings.equal_fold(later_name,name) if ODIN_OS==.Windows else later_name==name {return false}
    }
    return true
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
