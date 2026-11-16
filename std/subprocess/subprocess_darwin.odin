#+build darwin
#+private
package subprocess

import "core:c"
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

// The flavor 4 of proc_pid_rusage, with only the fields read named.
Rusage_Info_V4 :: struct {
    uuid:[16]u8,
    times:[6]u64, // user and system, idle and interrupt wakeups, pageins, wired size
    resident_size,phys_footprint:u64,
    proc_start_abstime,proc_exit_abstime:u64,
    later:[18]u64, // those of its children, disk, QoS times, billed and serviced, logical writes
    lifetime_max_phys_footprint:u64,
    last:[6]u64,
}
#assert(size_of(Rusage_Info_V4)==296)

// A child that exited and was not reaped keeps its usage.
_exit_peak :: proc(process:^Process) -> i64 {
    usage:Rusage_Info_V4
    if darwin.proc_pid_rusage(posix.pid_t(process.pid),.V4,&usage)!=0 {return 0}
    return i64(usage.lifetime_max_phys_footprint)
}

// An ended process that is not reaped still answers: it holds nothing.
_memory_held :: proc(pid:int) -> (now,peak:i64,ok:bool) {
    usage:Rusage_Info_V4
    if darwin.proc_pid_rusage(posix.pid_t(pid),.V4,&usage)!=0 || usage.proc_exit_abstime!=0 {return}
    return i64(usage.phys_footprint),i64(usage.lifetime_max_phys_footprint),true
}

// _IOR('f',127,int) of sys/filio.h.
FIONREAD :: 0x4004667f

// The bytes a pipe holds to be read; -1 when it cannot tell.
pipe_unread :: proc(file:^os.File) -> int {
    count:c.int
    if ioctl(posix.FD(os.fd(file)),FIONREAD,&count)==-1 {return -1}
    return int(count)
}

descriptors_close :: proc() {
    limit:posix.rlimit
    count:=1024
    if posix.getrlimit(.NOFILE,&limit)==.OK {count=int(min(limit.rlim_cur,1<<20))}
    for fd in 0..<count {_=posix.close(posix.FD(fd))}
}

// The process of core:os holds no handle on macOS.
process_close :: proc(process:os.Process) {}
