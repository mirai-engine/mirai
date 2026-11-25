#+build linux, darwin
package mirai_net

import cnet "core:net"
import "core:sys/posix"

// Lets an IPv6 socket, before its bind, also carry IPv4: the system shows those peers as ::ffff:a.b.c.d.
@(private)
udp_dual_stack :: proc(socket:cnet.UDP_Socket) -> bool {
    off:i32=0
    return posix.setsockopt(posix.FD(socket),i32(posix.Protocol.IPV6),posix.Sock_Option(posix.IPV6_V6ONLY),&off,size_of(off))==.OK
}

// Blocks until the socket or the waker has a datagram, or milliseconds pass. woken: the waker has.
@(private)
udp_poll :: proc(u:^Udp,milliseconds:int) -> (woken:bool) {
    fds:=[2]posix.pollfd{{fd=posix.FD(u.socket),events={.IN}},{fd=posix.FD(u.waker),events={.IN}}}
    return posix.poll(&fds[0],2,i32(milliseconds))>0 && .IN in fds[1].revents
}

@(private)
udp_sockaddr :: proc "contextless" (u:^Udp,to:Address,out:^posix.sockaddr_storage) -> (size:posix.socklen_t,ok:bool) {
    target:=udp_target(u,to)
    out^={}
    #partial switch target.kind {
    case .IP4:
        a:=(^posix.sockaddr_in)(out)
        a.sin_family=.INET
        a.sin_port=u16be(target.port)
        copy((transmute(^[4]u8)&a.sin_addr)[:],target.ip[:4])
        size=size_of(posix.sockaddr_in)
    case .IP6:
        a:=(^posix.sockaddr_in6)(out)
        a.sin6_family=.INET6
        a.sin6_port=u16be(target.port)
        a.sin6_addr=transmute(posix.in6_addr)target.ip
        a.sin6_scope_id=target.zone
        size=size_of(posix.sockaddr_in6)
    case:
        return 0,false
    }
    when ODIN_OS==.Darwin {out.ss_len=u8(size)}
    return size,true
}
@(private)
udp_from_sockaddr :: proc "contextless" (from:^posix.sockaddr_storage) -> Address {
    #partial switch from.ss_family {
    case .INET:
        a:=(^posix.sockaddr_in)(from)
        ip:=transmute([4]u8)a.sin_addr
        return address_ip4(ip[0],ip[1],ip[2],ip[3],int(a.sin_port))
    case .INET6:
        a:=(^posix.sockaddr_in6)(from)
        address:=address_from_endpoint({transmute(cnet.IP6_Address)a.sin6_addr,int(a.sin6_port)})
        if address.kind==.IP6 {address.zone=a.sin6_scope_id}
        return address
    }
    return {}
}
