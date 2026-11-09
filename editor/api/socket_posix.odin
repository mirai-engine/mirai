#+build linux, darwin, freebsd, openbsd, netbsd
package api

import "core:c"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:sys/posix"

// The children of the editor (the compiler of a Build) do not inherit the
// sockets of the server: a connection would stay open until the child ends.
@(private)
socket_private :: proc(socket:net.TCP_Socket) {
    posix.fcntl(posix.FD(socket),.SETFD,c.int(posix.FD_CLOEXEC))
}

// Whether a socket has something to read, or the wait failed: then a read says why.
@(private)
sockets_wait :: proc(sockets:[]net.TCP_Socket,timeout:time.Duration) -> bool {
    fds:[WAIT_SOCKETS]posix.pollfd
    for socket,i in sockets {fds[i]={fd=posix.FD(socket),events={.IN}}}
    return posix.poll(&fds[0],posix.nfds_t(len(sockets)),c.int(time.duration_milliseconds(timeout)))!=0
}

// Whole ticks of CPU hide a process that only wakes for a moment, as a call
// that queues by sleeping: the nanoseconds of the main thread show it on
// Linux, and the context switches on macOS.
@(private)
process_sample :: proc(pid:int) -> (sample:Process_Sample) {
    if posix.kill(posix.pid_t(pid),posix.Signal(0))!=.OK && posix.errno()==.ESRCH {
        sample.gone=true
        return
    }
    when ODIN_OS==.Linux {
        stat,error:=os.read_entire_file(fmt.tprintf("/proc/%d/stat",pid),context.temp_allocator)
        if error!=nil {return}
        text:=string(stat)
        after:=strings.last_index_byte(text,')')
        if after<0 || after+2>=len(text) {return}
        fields:=strings.fields(text[after+2:],context.temp_allocator)
        if len(fields)<13 {return}
        if fields[0]=="Z" {
            sample.gone=true
            return
        }
        user,_:=strconv.parse_u64(fields[11],10)
        system,_:=strconv.parse_u64(fields[12],10)
        sample.work=user+system
        if schedule,schedule_error:=os.read_entire_file(fmt.tprintf("/proc/%d/schedstat",pid),context.temp_allocator);schedule_error==nil {
            run:=strings.fields(string(schedule),context.temp_allocator)
            if len(run)>0 {
                nanoseconds,_:=strconv.parse_u64(run[0],10)
                sample.work+=nanoseconds
            }
        }
        sample.known=true
    } else when ODIN_OS==.Darwin {
        info:Proc_Task_Info
        if proc_pidinfo(c.int(pid),PROC_PIDTASKINFO,0,&info,size_of(info))==size_of(info) {
            sample.work=info.total_user+info.total_system+u64(info.csw)
            sample.known=true
        }
    }
    return
}

when ODIN_OS==.Darwin {
    @(private="file") PROC_PIDTASKINFO :: 4

    // struct proc_taskinfo of <sys/proc_info.h>.
    @(private="file")
    Proc_Task_Info :: struct {
        virtual_size,resident_size,total_user,total_system,threads_user,threads_system:u64,
        policy,faults,pageins,cow_faults,messages_sent,messages_received,syscalls_mach,syscalls_unix,csw,threadnum,numrunning,priority:i32,
    }

    foreign import libproc "system:System"

    @(private="file")
    foreign libproc {
        proc_pidinfo :: proc(pid,flavor:c.int,arg:u64,buffer:rawptr,size:c.int) -> c.int ---
    }
}
