#+build !windows
package kai

import "core:net"
import "core:sys/posix"

// Keeps a listening socket from leaking into child processes spawned by the editor.
@(private)
socket_cloexec :: proc(socket:net.TCP_Socket) {
    _=posix.fcntl(posix.FD(socket),.SETFD,posix.FD_CLOEXEC)
}
