#+build linux, darwin, freebsd, openbsd, netbsd
package mirai_net

import cnet "core:net"
import "core:sys/posix"

// Lets an IPv6 socket, before its bind, also carry IPv4: the system shows those peers as ::ffff:a.b.c.d.
@(private)
udp_dual_stack :: proc(socket:cnet.UDP_Socket) -> bool {
    off:i32=0
    return posix.setsockopt(posix.FD(socket),i32(posix.Protocol.IPV6),posix.Sock_Option(posix.IPV6_V6ONLY),&off,size_of(off))==.OK
}
