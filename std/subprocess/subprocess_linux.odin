#+build linux
#+private
package subprocess

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
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

// An exited child has no memory to read any more: what the wait reports of it.
_exit_peak :: proc(process:^Process) -> i64 {
    info:linux.Sig_Info
    usage:linux.RUsage
    if linux.waitid(.PID,linux.Id(process.pid),&info,{.WEXITED,.WNOWAIT,.WNOHANG},&usage)!=.NONE {return 0}
    return i64(usage.maxrss_word)*1024
}

// VmRSS and VmHWM of /proc/<pid>/status, in kB; an ended process has neither.
_memory_held :: proc(pid:int) -> (now,peak:i64,ok:bool) {
    data,error:=os.read_entire_file(fmt.tprintf("/proc/%d/status",pid),context.temp_allocator)
    if error!=nil {return}
    found:[2]bool
    text:=string(data)
    for line in strings.split_lines_iterator(&text) {
        for name,i in ([2]string{"VmRSS:","VmHWM:"}) {
            if !strings.has_prefix(line,name) {continue}
            kilobytes,parsed:=strconv.parse_i64(strings.trim_space(strings.trim_suffix(strings.trim_space(line[len(name):]),"kB")))
            if !parsed {return}
            if i==0 {now=kilobytes*1024} else {peak=kilobytes*1024}
            found[i]=true
        }
    }
    return now,peak,found[0] && found[1]
}

descriptors_close :: proc() {_=linux.close_range(0,max(linux.Fd),{})}

process_close :: proc(process:os.Process) {_=linux.close(linux.Fd(process.handle))}
