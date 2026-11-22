#+build darwin, linux
package kai

import "core:os"
import cnet "core:net"
import "core:sys/posix"

// The lock of a workspace: a file held open with an exclusive flock, which
// the system lets go when the process ends.
Lock :: struct {
    file:^os.File,
}

@(private)
lock_take :: proc(path:string) -> (lock:Lock,error:Error) {
    file,e:=os.open(path,{.Read,.Write,.Create})
    if e!=nil {return {},.Io}
    if !flock_exclusive(os.fd(file)) {
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

// Lets other sockets of this user bind the port too: every one of them gets
// a broadcast to it.
@(private)
socket_share_port :: proc(socket:cnet.UDP_Socket) -> bool {
    on:i32=1
    return posix.setsockopt(posix.FD(socket),posix.SOL_SOCKET,posix.Sock_Option(SO_REUSEPORT),&on,size_of(on))==.OK
}
