#+build linux, darwin, freebsd, openbsd, netbsd
package mirai_net

import cnet "core:net"
import "core:sys/posix"

// Starts connecting a non-blocking socket to address, IPv4 or IPv6: true
// while it connects or once it did (socket_connected tells which). A
// datagram socket only takes the route, sending nothing.
socket_connect :: proc(socket:cnet.Socket,address:Address) -> bool {
    result:posix.result
    #partial switch address.kind {
    case .IP4:
        native:=posix.sockaddr_in{sin_family=.INET,sin_port=u16be(address.port)}
        when ODIN_OS!=.Linux {native.sin_len=u8(size_of(native))}
        for i in 0..<4 {([^]u8)(&native.sin_addr)[i]=address.ip[i]}
        result=posix.connect(posix.FD(socket),(^posix.sockaddr)(&native),posix.socklen_t(size_of(native)))
    case .IP6:
        native:=posix.sockaddr_in6{sin6_family=.INET6,sin6_port=u16be(address.port),sin6_scope_id=address.zone}
        when ODIN_OS!=.Linux {native.sin6_len=u8(size_of(native))}
        native.sin6_addr=transmute(posix.in6_addr)address.ip
        result=posix.connect(posix.FD(socket),(^posix.sockaddr)(&native),posix.socklen_t(size_of(native)))
    case: return false
    }
    return result==.OK || posix.errno()==.EINPROGRESS || posix.errno()==.EWOULDBLOCK
}

// Whether the connect socket_connect started ended, without waiting, and
// whether it succeeded.
socket_connected :: proc(socket:cnet.Socket) -> (ready,ok:bool) {
    fd:=posix.pollfd{fd=posix.FD(socket),events={.OUT}}
    result:=posix.poll(&fd,1,0)
    if result==0 {return false,false}
    if result<0 {return true,false}
    error:i32;size:=posix.socklen_t(size_of(error))
    if posix.getsockopt(posix.FD(socket),posix.SOL_SOCKET,.ERROR,&error,&size)!=.OK {return true,false}
    return true,error==0 && .OUT in fd.revents
}
