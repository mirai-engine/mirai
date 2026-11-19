#+build !windows
package mirai_net

import "core:testing"
import cnet "core:net"
import "core:sys/posix"

@(test)
a_udp_socket_asks_for_larger_buffers_than_the_default :: proc(t:^testing.T) {
    plain,plain_error:=cnet.make_unbound_udp_socket(.IP4)
    if !testing.expect(t,plain_error==nil) {return}
    defer cnet.close(plain)
    u:Udp
    if !testing.expect(t,udp_open(&u,address_loopback(0)),"cannot bind a UDP socket on 127.0.0.1") {return}
    defer udp_close(&u)
    for option in ([2]posix.Sock_Option{.RCVBUF,.SNDBUF}) {
        testing.expectf(t,test_buffer(u.socket,option)>test_buffer(plain,option),
            "%v is larger than a plain socket's, or the system's most",option)
    }
}

@(private="file")
test_buffer :: proc(socket:cnet.UDP_Socket,option:posix.Sock_Option) -> int {
    value:i32
    size:=posix.socklen_t(size_of(value))
    if posix.getsockopt(posix.FD(socket),posix.SOL_SOCKET,option,&value,&size)!=.OK {return -1}
    return int(value)
}
