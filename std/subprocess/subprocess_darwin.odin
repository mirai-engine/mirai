#+build darwin
#+private
package subprocess

import "core:os"
import "core:sys/darwin"
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

// The flavor 4 of proc_pid_rusage up to its lifetime peak footprint, the
// first field after it standing for those that follow.
Rusage_Info_V4 :: struct {
    uuid:[16]u8,
    before:[28]u64, // times, wakeups, sizes, its children's, disk, QoS times, billed and serviced, logical writes
    lifetime_max_phys_footprint:u64,
    after:[6]u64,
}

// A child that exited and was not reaped keeps its usage.
_exit_peak :: proc(process:^Process) -> i64 {
    peak,_:=_memory_peak(process.pid)
    return peak
}

_memory_peak :: proc(pid:int) -> (bytes:i64,ok:bool) {
    usage:Rusage_Info_V4
    if darwin.proc_pid_rusage(posix.pid_t(pid),.V4,&usage)!=0 {return}
    return i64(usage.lifetime_max_phys_footprint),true
}

descriptors_close :: proc() {
    limit:posix.rlimit
    count:=1024
    if posix.getrlimit(.NOFILE,&limit)==.OK {count=int(min(limit.rlim_cur,1<<20))}
    for fd in 0..<count {_=posix.close(posix.FD(fd))}
}

// The process of core:os holds no handle on macOS.
process_close :: proc(process:os.Process) {}
