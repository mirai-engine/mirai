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

// Windows sockets have no call that sends or receives several datagrams: one call each.
@(private)
udp_send_batch :: proc(u:^Udp,batch:[]Datagram) -> int {
    sent:=0
    for datagram in batch {
        endpoint,valid:=address_to_endpoint(udp_target(u,datagram.address))
        if !valid {continue}
        if _,error:=cnet.send_udp(u.socket,datagram.bytes,endpoint);error==nil {sent+=1}
    }
    return sent
}

@(private)
udp_receive_batch :: proc(u:^Udp,batch:[]Datagram) -> int {
    for &datagram,i in batch {
        // An ICMP answer to an earlier send surfaces as an error on the next receive: skip those.
        received:=false
        for _ in 0..<8 {
            count,endpoint,error:=cnet.recv_udp(u.socket,datagram.bytes)
            if error==nil {
                datagram={address_from_endpoint(endpoint),datagram.bytes[:count]}
                received=true
                break
            }
            if error==.Would_Block || error==.Timeout {break}
        }
        if !received {return i}
    }
    return len(batch)
}
