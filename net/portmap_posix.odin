#+build linux, darwin, freebsd, openbsd, netbsd
package mirai_net

import cnet "core:net"
import "core:sys/posix"

@(private)
portmap_socket_connect :: proc(socket:cnet.Socket,address:Address) -> bool {
    if address.kind!=.IP4 {return false}
    native:=posix.sockaddr_in{sin_family=.INET,sin_port=u16be(address.port)}
    when ODIN_OS!=.Linux {native.sin_len=u8(size_of(native))}
    for i in 0..<4 {([^]u8)(&native.sin_addr)[i]=address.ip[i]}
    result:=posix.connect(posix.FD(socket),(^posix.sockaddr)(&native),posix.socklen_t(size_of(native)))
    return result==.OK || posix.errno()==.EINPROGRESS || posix.errno()==.EWOULDBLOCK
}

@(private)
portmap_socket_connected :: proc(socket:cnet.Socket) -> (ready,ok:bool) {
    fd:=posix.pollfd{fd=posix.FD(socket),events={.OUT}}
    result:=posix.poll(&fd,1,0)
    if result==0 {return false,false}
    if result<0 {return true,false}
    error:i32;size:=posix.socklen_t(size_of(error))
    if posix.getsockopt(posix.FD(socket),posix.SOL_SOCKET,.ERROR,&error,&size)!=.OK {return true,false}
    return true,error==0 && .OUT in fd.revents
}
