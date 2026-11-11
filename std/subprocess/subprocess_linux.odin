#+build linux
#+private
package subprocess

import "core:os"
import "core:sys/linux"
import "core:sys/posix"

// Returns once parent ended, also when it already had.
parent_wait :: proc(parent:posix.pid_t) {
    pidfd,error:=linux.pidfd_open(linux.Pid(parent),{})
    // Opened while it is still the parent, it is that process and not a later one with its pid.
    if error!=.NONE || linux.getppid()!=linux.Pid(parent) {return}
    fds:=[]linux.Poll_Fd{{fd=linux.Fd(pidfd),events={.IN}}}
    for {
        if _,poll_error:=linux.poll(fds,-1);poll_error!=.EINTR {return}
    }
}

descriptors_close :: proc() {_=linux.close_range(0,max(linux.Fd),{})}

process_close :: proc(process:os.Process) {_=linux.close(linux.Fd(process.handle))}
