package kai

import "core:os"
import win "core:sys/windows"
import cnet "core:net"

// The lock of a workspace: a file held open with an exclusive LockFileEx,
// which the system lets go when the process ends.
Lock :: struct {
    file:^os.File,
}

@(private)
lock_take :: proc(path:string) -> (lock:Lock,error:Error) {
    file,e:=os.open(path,{.Read,.Write,.Create})
    if e!=nil {return {},.Io}
    overlapped:win.OVERLAPPED
    if !win.LockFileEx(win.HANDLE(os.fd(file)),win.LOCKFILE_EXCLUSIVE_LOCK|win.LOCKFILE_FAIL_IMMEDIATELY,0,1,0,&overlapped) {
        os.close(file)
        return {},.Locked
    }
    return {file},.None
}

@(private)
lock_release :: proc(lock:^Lock) {
    if lock.file==nil {return}
    os.close(lock.file)
    lock^={}
}

// ReFS block cloning (FSCTL_DUPLICATE_EXTENTS_TO_FILE) is not used yet: a
// switch writes the file from the store instead.
file_clone :: proc(from,to:string) -> Error {
    return .Unsupported
}

// Lets other sockets of this user bind the port too: SO_REUSEADDR does it on
// Windows, and every one of them gets a broadcast to it.
@(private)
socket_share_port :: proc(socket:cnet.UDP_Socket) -> bool {
    on:win.BOOL=true
    return win.setsockopt(win.SOCKET(uintptr(socket)),win.SOL_SOCKET,win.SO_REUSEADDR,&on,size_of(on))==0
}
