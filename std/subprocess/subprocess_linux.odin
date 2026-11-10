#+build linux
#+private
package subprocess

import "base:intrinsics"
import "core:os"
import "core:sys/linux"

// Bounds what the process allocates from now on: what it allocated before stays.
memory_limit :: proc(pid:int,memory:u64) {
    limit:=linux.RLimit{cur=uint(memory),max=uint(memory)}
    _=intrinsics.syscall(linux.SYS_prlimit64,uintptr(pid),uintptr(linux.RLimit_Kind.DATA),uintptr(&limit),0)
}

process_close :: proc(process:os.Process) {_=linux.close(linux.Fd(process.handle))}
