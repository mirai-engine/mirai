#+build darwin
#+private
package subprocess

import "core:os"
import "core:sys/kqueue"
import "core:sys/posix"

// Returns once parent ended, also when it already had.
parent_wait :: proc(parent:posix.pid_t) {
    queue,error:=kqueue.kqueue()
    if error!=nil {return}
    change:=[]kqueue.KEvent{{ident=uintptr(parent),filter=.Proc,flags={.Add},fflags={fproc={.Exit}}}}
    // Watched while it is still the parent, it is that process and not a later one with its pid.
    if _,add_error:=kqueue.kevent(queue,change,nil,nil);add_error!=nil || posix.getppid()!=parent {return}
    happened:[1]kqueue.KEvent
    for {
        if _,wait_error:=kqueue.kevent(queue,nil,happened[:],nil);wait_error!=.EINTR {return}
    }
}

descriptors_close :: proc() {
    limit:posix.rlimit
    count:=1024
    if posix.getrlimit(.NOFILE,&limit)==.OK {count=int(min(limit.rlim_cur,1<<20))}
    for fd in 0..<count {_=posix.close(posix.FD(fd))}
}

// The process of core:os holds no handle on macOS.
process_close :: proc(process:os.Process) {}
