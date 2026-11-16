#+build !windows
#+private
package subprocess

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"

when ODIN_OS==.Darwin {
    foreign import libc "system:System"
} else {
    foreign import libc "system:c"
}

// core:sys/posix does not declare these.
foreign libc {
    getpriority :: proc(which:c.int,who:u32) -> c.int ---
    setpriority :: proc(which:c.int,who:u32,priority:c.int) -> c.int ---
}

PRIO_PROCESS :: 0
LOW_NICENESS :: 10
NICENESS_MOST :: 19

_start :: proc(desc:os.Process_Desc,limits:Limits) -> (process:Process,error:os.Error) {
    process=spawn(desc,limits,false) or_return
    // The watcher joins the group of the child and kills it once this process
    // is gone. Both set the group, so that it is in it whichever runs first.
    parent:=posix.getpid()
    watcher:=posix.fork()
    if watcher==0 {watch(posix.pid_t(process.pid),parent)}
    if watcher<0 {error=os.Platform_Error(posix.errno());release(&process);return}
    _=posix.setpgid(watcher,posix.pid_t(process.pid))
    process.tree=uintptr(watcher)
    return
}

_detached :: proc(desc:os.Process_Desc) -> (process:Process,error:os.Error) {
    return spawn(desc,{},true)
}

// The whole group: the child, what it started and the watcher, which only
// SIGKILL ends.
_terminate :: proc(process:^Process,force:bool) -> os.Error {
    if posix.killpg(posix.pid_t(process.pid),.SIGKILL if force else .SIGTERM)!=.OK {return os.Platform_Error(posix.errno())}
    return nil
}

// Ends what the child left in its group and reaps the watcher.
_tree_close :: proc(process:^Process) {
    if process.tree==0 {return}
    watcher:=posix.pid_t(process.tree)
    _=posix.killpg(posix.pid_t(process.pid),.SIGKILL)
    _=posix.kill(watcher,.SIGKILL)
    for posix.waitpid(watcher,nil,{})<0 && posix.errno()==.EINTR {}
    process.tree=0
}

// A write that does not fit returns at once. Writing to a child that ended
// is then an error instead of a SIGPIPE that ends this process.
_stdin_nonblocking :: proc(file:^os.File) {
    fd:=posix.FD(os.fd(file))
    _=posix.fcntl(fd,.SETFL,posix.fcntl(fd,.GETFL)|posix.O_NONBLOCK)
    _=posix.signal(.SIGPIPE,transmute(proc "c" (posix.Signal))posix.SIG_IGN)
}

// How high this process runs, comparable between processes: higher runs first.
priority_rank :: proc() -> int {
    return -int(getpriority(PRIO_PROCESS,0))
}

// Forks and executes desc in a process group of its own, or a session of its
// own when detached. Between fork and exec the child only makes system calls:
// everything it needs is prepared before.
@(private="file")
spawn :: proc(desc:os.Process_Desc,limits:Limits,detached:bool) -> (process:Process,error:os.Error) {
    scratch:=context.temp_allocator
    program:=executable(desc.command[0],scratch) or_return
    arguments:=make([]cstring,len(desc.command)+1,scratch) or_return
    for argument,i in desc.command {arguments[i]=strings.clone_to_cstring(argument,scratch) or_return}
    env:=desc.env
    if env==nil {env=os.environ(scratch) or_return}
    entries:=make([dynamic]cstring,0,len(env)+1,scratch) or_return
    for entry,i in env {
        if desc.env==nil || variable_last(env,i) {append(&entries,strings.clone_to_cstring(entry,scratch) or_return) or_return}
    }
    append(&entries,nil) or_return
    folder:cstring
    if desc.working_dir!="" {folder=strings.clone_to_cstring(desc.working_dir,scratch) or_return}
    null:=posix.open("/dev/null",{.RDWR,.CLOEXEC})
    if null<0 {return {},os.Platform_Error(posix.errno())}
    defer posix.close(null)
    streams:[3]posix.FD
    for file,i in ([]^os.File{desc.stdin,desc.stdout,desc.stderr}) {streams[i]=posix.FD(os.fd(file)) if file!=nil else null}
    // The child reports through it why it could not execute; exec closes it.
    report:[2]posix.FD
    if posix.pipe(&report)!=.OK {return {},os.Platform_Error(posix.errno())}
    for fd in report {_=posix.fcntl(fd,.SETFD,posix.FD_CLOEXEC)}
    priority:=min(getpriority(PRIO_PROCESS,0)+LOW_NICENESS,NICENESS_MOST)
    pid:=posix.fork()
    if pid==0 {
        if detached {_=posix.setsid()} else {_=posix.setpgid(0,0)}
        // What this process blocked or ignored is not the child's.
        mask:posix.sigset_t
        _=posix.sigemptyset(&mask)
        _=posix.sigprocmask(.SETMASK,&mask,nil)
        _=posix.signal(.SIGPIPE,transmute(proc "c" (posix.Signal))posix.SIG_DFL)
        for stream,i in streams {_=posix.dup2(stream,posix.FD(i))}
        if limits.priority==.Low {_=setpriority(PRIO_PROCESS,0,priority)}
        when ODIN_OS==.Linux {
            if limits.memory>0 {
                limit:=posix.rlimit{rlim_cur=posix.rlim_t(limits.memory),rlim_max=posix.rlim_t(limits.memory)}
                _=posix.setrlimit(.DATA,&limit)
            }
        }
        if folder==nil || posix.chdir(folder)==.OK {_=posix.execve(program,raw_data(arguments),raw_data(entries))}
        code:=i32(posix.errno())
        _=posix.write(report[1],cast([^]byte)&code,size_of(code))
        posix._exit(127)
    }
    posix.close(report[1])
    defer posix.close(report[0])
    if pid<0 {return {},os.Platform_Error(posix.errno())}
    if !detached {_=posix.setpgid(pid,pid)}
    code:i32
    count:=posix.read(report[0],cast([^]byte)&code,size_of(code))
    for count<0 && posix.errno()==.EINTR {count=posix.read(report[0],cast([^]byte)&code,size_of(code))}
    if count==size_of(code) {
        for posix.waitpid(pid,nil,{})<0 && posix.errno()==.EINTR {}
        return {},os.Platform_Error(code)
    }
    opened:=os.process_open(int(pid)) or_return
    return {pid=opened.pid,handle=opened.handle},nil
}

// The program to execute: with a slash as it is, else the first in PATH.
@(private="file")
executable :: proc(name:string,allocator:=context.allocator) -> (program:cstring,error:os.Error) {
    path:=os.get_env("PATH",context.temp_allocator) if strings.index_byte(name,'/')<0 else ""
    for folder in strings.split_iterator(&path,":") {
        program=strings.clone_to_cstring(strings.concatenate({folder if folder!="" else ".","/",name},allocator) or_return,allocator) or_return
        if posix.access(program,{.X_OK})==.OK {return}
    }
    program=strings.clone_to_cstring(name,allocator) or_return
    return program,nil if strings.index_byte(name,'/')>=0 && posix.access(program,{.X_OK})==.OK else .Not_Exist
}

// The watcher: in the group of the child, holding nothing of this process,
// until parent ends; then it kills the group, itself with it.
@(private="file")
watch :: proc(group,parent:posix.pid_t) -> ! {
    _=posix.setpgid(0,group)
    _=posix.signal(.SIGTERM,transmute(proc "c" (posix.Signal))posix.SIG_IGN)
    _=posix.signal(.SIGINT,transmute(proc "c" (posix.Signal))posix.SIG_IGN)
    descriptors_close()
    parent_wait(parent)
    _=posix.killpg(group,.SIGKILL)
    posix._exit(0)
}
