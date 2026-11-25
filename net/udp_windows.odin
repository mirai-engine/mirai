#+build windows
package mirai_net

import cnet "core:net"
import win "core:sys/windows"

// Lets an IPv6 socket, before its bind, also carry IPv4: the system shows those peers as ::ffff:a.b.c.d.
@(private)
udp_dual_stack :: proc(socket:cnet.UDP_Socket) -> bool {
    off:win.DWORD=0
    return win.setsockopt(win.SOCKET(uintptr(socket)),win.IPPROTO_IPV6,win.IPV6_V6ONLY,&off,size_of(off))==0
}

// Blocks until the socket or the waker has a datagram, or milliseconds pass. woken: the waker has.
@(private)
udp_poll :: proc(u:^Udp,milliseconds:int) -> (woken:bool) {
    fds:=[2]win.WSA_POLLFD{{fd=win.SOCKET(uintptr(u.socket)),events=win.POLLRDNORM},{fd=win.SOCKET(uintptr(u.waker)),events=win.POLLRDNORM}}
    return win.WSAPoll(&fds[0],2,i32(milliseconds))>0 && fds[1].revents&win.POLLRDNORM!=0
}

@(private)
udp_sockaddr :: proc "contextless" (u:^Udp,to:Address,out:^win.SOCKADDR_STORAGE_LH) -> (size:i32,ok:bool) {
    target:=udp_target(u,to)
    out^={}
    #partial switch target.kind {
    case .IP4:
        a:=(^win.sockaddr_in)(out)
        a.sin_family=u16(win.AF_INET)
        a.sin_port=u16be(target.port)
        copy((transmute(^[4]u8)&a.sin_addr)[:],target.ip[:4])
        return size_of(win.sockaddr_in),true
    case .IP6:
        a:=(^win.sockaddr_in6)(out)
        a.sin6_family=u16(win.AF_INET6)
        a.sin6_port=u16be(target.port)
        a.sin6_addr.s6_addr=target.ip
        a.sin6_scope_id=win.c_ulong(target.zone)
        return size_of(win.sockaddr_in6),true
    }
    return 0,false
}
@(private)
udp_from_sockaddr :: proc "contextless" (from:^win.SOCKADDR_STORAGE_LH) -> Address {
    switch from.ss_family {
    case u16(win.AF_INET):
        a:=(^win.sockaddr_in)(from)
        ip:=transmute([4]u8)a.sin_addr
        return address_ip4(ip[0],ip[1],ip[2],ip[3],int(a.sin_port))
    case u16(win.AF_INET6):
        a:=(^win.sockaddr_in6)(from)
        address:=address_unmap(a.sin6_addr.s6_addr,u16(a.sin6_port))
        if address.kind==.IP6 {address.zone=u32(a.sin6_scope_id)}
        return address
    }
    return {}
}

// Windows sockets have no call that sends or receives several datagrams: one call each.
@(private)
udp_send_batch :: proc(u:^Udp,batch:[]Datagram) -> int {
    sent:=0
    for datagram in batch {
        name:win.SOCKADDR_STORAGE_LH
        size,ok:=udp_sockaddr(u,datagram.address,&name)
        if !ok {continue}
        if win.sendto(win.SOCKET(uintptr(u.socket)),raw_data(datagram.bytes),i32(len(datagram.bytes)),0,&name,size)>=0 {sent+=1}
    }
    return sent
}

@(private)
udp_receive_batch :: proc(u:^Udp,batch:[]Datagram) -> int {
    for &datagram,i in batch {
        // An ICMP answer to an earlier send surfaces as an error on the next receive: skip those.
        received:=false
        for _ in 0..<8 {
            name:win.SOCKADDR_STORAGE_LH
            size:=i32(size_of(name))
            count:=win.recvfrom(win.SOCKET(uintptr(u.socket)),raw_data(datagram.bytes),i32(len(datagram.bytes)),0,&name,&size)
            if count>=0 {
                datagram={udp_from_sockaddr(&name),datagram.bytes[:count]}
                received=true
                break
            }
            if error:=win.WSAGetLastError();error==i32(win.WSAEWOULDBLOCK) || error==i32(win.WSAETIMEDOUT) {break}
        }
        if !received {return i}
    }
    return len(batch)
}
