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
