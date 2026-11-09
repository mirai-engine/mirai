package api

import "core:net"
import "core:time"
import win "core:sys/windows"

// The children of the editor (the compiler of a Build) do not inherit the
// sockets of the server: a connection would stay open until the child ends.
@(private)
socket_private :: proc(socket:net.TCP_Socket) {
    win.SetHandleInformation(win.HANDLE(uintptr(socket)),win.HANDLE_FLAG_INHERIT,0)
}

// Whether a socket has something to read, or the wait failed: then a read says why.
@(private)
sockets_wait :: proc(sockets:[]net.TCP_Socket,timeout:time.Duration) -> bool {
    fds:[WAIT_SOCKETS]win.WSA_POLLFD
    for socket,i in sockets {fds[i]={fd=win.SOCKET(socket),events=win.POLLRDNORM}}
    return win.WSAPoll(&fds[0],win.c_ulong(len(sockets)),win.c_int(time.duration_milliseconds(timeout)))!=0
}

// The cycles of its threads count even a wake-up too short for the process
// times, which tell a call that queues by sleeping from a process that hung.
@(private)
process_sample :: proc(pid:int) -> (sample:Process_Sample) {
    handle:=win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION,false,win.DWORD(pid))
    if handle==nil {
        sample.gone=win.GetLastError()==win.ERROR_INVALID_PARAMETER
        return
    }
    defer win.CloseHandle(handle)
    code:win.DWORD
    if win.GetExitCodeProcess(handle,&code) && code!=STILL_ACTIVE {
        sample.gone=true
        return
    }
    sample.known=bool(QueryProcessCycleTime(handle,&sample.work))
    return
}

@(private="file")
STILL_ACTIVE :: 259

foreign import kernel32 "system:Kernel32.lib"

@(private="file",default_calling_convention="system")
foreign kernel32 {
    QueryProcessCycleTime :: proc(process:win.HANDLE,cycles:^u64) -> win.BOOL ---
}
