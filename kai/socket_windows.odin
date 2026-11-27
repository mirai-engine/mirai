#+build windows
package kai

import "core:net"

@(private)
socket_cloexec :: proc(socket:net.TCP_Socket) {}
