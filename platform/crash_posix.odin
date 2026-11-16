#+build linux, darwin
#+private
package platform

import "base:runtime"
import "core:c"
import "core:sys/posix"

when ODIN_OS==.Darwin {
    foreign import libc "system:System.framework"
} else {
    foreign import libc "system:c"
}

Dl_info :: struct {
    dli_fname:cstring,
    dli_fbase:rawptr,
    dli_sname:cstring, // the nearest exported symbol, often not the procedure: not reported
    dli_saddr:rawptr,
}

foreign libc {
    backtrace :: proc(buffer:[^]rawptr,size:c.int) -> c.int ---
    dladdr :: proc(address:rawptr,info:^Dl_info) -> c.int ---
}

Crash_Sink :: posix.FD

CRASH_SIGNALS :: [?]posix.Signal{.SIGSEGV,.SIGBUS,.SIGILL,.SIGFPE,.SIGTRAP,.SIGABRT}
CRASH_STACK_BYTES :: 64*1024

_crash_handler_install :: proc() {
    // The handler runs on a stack of its own, so it also reports an overflow.
    // The system keeps the stack for the life of the process.
    // Without memory for it the handler runs on the stack that faulted.
    action:posix.sigaction_t
    action.sa_sigaction=crash_signal
    action.sa_flags={.SIGINFO,.RESETHAND}
    if stack,error:=make([]u8,CRASH_STACK_BYTES);error==nil {
        alternate:=posix.stack_t{ss_sp=raw_data(stack),ss_size=c.size_t(len(stack))}
        posix.sigaltstack(&alternate,nil)
        action.sa_flags+={.ONSTACK}
    }
    for signal in CRASH_SIGNALS {posix.sigaction(signal,&action,nil)}
    // backtrace loads what it needs on its first call, which a fault cannot afford.
    warm:[1]rawptr
    backtrace(&warm[0],1)
}

crash_flush :: proc "contextless" (o:^Crash_Out) {
    for sink in o.sinks[:o.count] {posix.write(sink,&o.buffer[0],c.size_t(o.used))}
    o.used=0
}

crash_signal :: proc "c" (signal:posix.Signal,info:^posix.siginfo_t,_:rawptr) {
    context=runtime.default_context()
    o:Crash_Out
    o.sinks[0]=posix.STDERR_FILENO
    o.count=1
    if path:=posix.getenv(CRASH_REPORT_VARIABLE);path!=nil {
        if file:=posix.open(path,{.WRONLY,.CREAT,.TRUNC},{.IRUSR,.IWUSR,.IRGRP,.IROTH});file>=0 {
            o.sinks[1]=file
            o.count=2
        }
    }
    crash_put(&o,"\nmirai: the process ended by ")
    #partial switch signal {
    case .SIGSEGV:
        crash_put(&o,"an invalid access to ")
        crash_hex(&o,u64(uintptr(info.si_addr)))
    case .SIGBUS:
        crash_put(&o,"a bus error at ")
        crash_hex(&o,u64(uintptr(info.si_addr)))
    case .SIGILL,.SIGTRAP: crash_put(&o,"a trap: a failed assertion or bounds check, its message above")
    case .SIGFPE: crash_put(&o,"an arithmetic fault")
    case .SIGABRT: crash_put(&o,"an abort")
    case:
        crash_put(&o,"the signal ")
        crash_dec(&o,u64(signal))
    }
    crash_put(&o,"\n")
    frames:[CRASH_FRAMES]rawptr
    count:=int(backtrace(&frames[0],CRASH_FRAMES))
    for i in 0..<count {
        at:=uintptr(frames[i])
        if i>0 {at-=1}
        crash_put(&o,"    ")
        found:Dl_info
        if dladdr(rawptr(at),&found)!=0 && found.dli_fname!=nil {
            crash_put(&o,crash_base_name(string(found.dli_fname)))
            crash_put(&o,"+")
            crash_hex(&o,u64(at-uintptr(found.dli_fbase)))
        } else {
            crash_hex(&o,u64(at))
        }
        crash_put(&o,"\n")
    }
    crash_events_report(&o)
    crash_flush(&o)
    if o.count>1 {posix.close(o.sinks[1])}
    // The default action ends the process with this signal.
    posix.signal(signal,auto_cast posix.SIG_DFL)
    posix.raise(signal)
}

// The events the process noted before the fault, when CRASH_EVENTS_VARIABLE names their file.
crash_events_report :: proc "contextless" (o:^Crash_Out) {
    path:=posix.getenv(CRASH_EVENTS_VARIABLE)
    if path==nil {return}
    file:=posix.open(path,{})
    if file<0 {return}
    defer posix.close(file)
    head:[CRASH_EVENTS_HEAD]u8
    if posix.read(file,&head[0],CRASH_EVENTS_HEAD)!=CRASH_EVENTS_HEAD {return}
    first,count:=crash_events_order(head[:])
    if count==0 {return}
    crash_put(o,"Events before the fault, the oldest first (seconds, kind, what):\n")
    line:[CRASH_EVENT_BYTES]u8
    for i in 0..<count {
        slot:=(first+i)%CRASH_EVENT_LINES
        if posix.lseek(file,posix.off_t(CRASH_EVENTS_HEAD+slot*CRASH_EVENT_BYTES),.SET)<0 {return}
        if posix.read(file,&line[0],CRASH_EVENT_BYTES)!=CRASH_EVENT_BYTES {return}
        crash_events_line(o,line[:])
    }
}
