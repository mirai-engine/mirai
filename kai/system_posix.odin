#+build darwin, linux
package kai

import "core:os"
import cnet "core:net"
import "core:strings"
import "core:sys/posix"

// The lock of a workspace: a file held open with an exclusive flock, which
// the system lets go when the process ends.
Lock :: struct {
    file:^os.File,
}

@(private)
lock_take :: proc(path:string) -> (lock:Lock,error:Error) {
    file,e:=os.open(path,{.Read,.Write,.Create})
    if e!=nil {return {},.Io}
    if !flock_exclusive(os.fd(file)) {
        os.close(file)
        return {},.Locked
    }
    return {file},.None
}

@(private)
lock_release :: proc(lock:^Lock) {
    if lock.file==nil {return}
    os.close(lock.file)
    lock^={}
}

// Lets other sockets of this user bind the port too: every one of them gets
// a broadcast to it.
@(private)
socket_share_port :: proc(socket:cnet.UDP_Socket) -> bool {
    on:i32=1
    return posix.setsockopt(posix.FD(socket),posix.SOL_SOCKET,posix.Sock_Option(SO_REUSEPORT),&on,size_of(on))==.OK
}

// Keeps an IPv6 socket, before its bind, to IPv6 alone.
@(private)
socket_ip6_only :: proc(socket:cnet.UDP_Socket) -> bool {
    on:i32=1
    return posix.setsockopt(posix.FD(socket),i32(posix.Protocol.IPV6),posix.Sock_Option(posix.IPV6_V6ONLY),&on,size_of(on))==.OK
}

// Lets an IPv6 socket take what is sent to the multicast group on the
// interface of index.
@(private)
socket_join6 :: proc(socket:cnet.UDP_Socket,group:[16]u8,index:u32) -> bool {
    m:=posix.ipv6_mreq{ipv6mr_multiaddr=transmute(posix.in6_addr)group,ipv6mr_interface=index}
    return posix.setsockopt(posix.FD(socket),i32(posix.Protocol.IPV6),posix.Sock_Option(posix.IPV6_JOIN_GROUP),&m,size_of(m))==.OK
}

// The indexes of the interfaces that are up and have an IPv6 address: where
// a link-local multicast goes out.
@(private)
interfaces6 :: proc(out:^[dynamic]u32) {
    interfaces,e:=cnet.enumerate_interfaces(context.temp_allocator)
    if e!=nil {return}
    for interface in interfaces {
        if cnet.Link_States.Up not_in interface.link.state {continue}
        has6:=false
        for lease in interface.unicast {
            _,ip6:=lease.address.(cnet.IP6_Address)
            has6||=ip6
        }
        if !has6 {continue}
        name,ce:=strings.clone_to_cstring(interface.adapter_name,context.temp_allocator)
        if ce!=nil {continue}
        if index:=posix.if_nametoindex(name);index!=0 {append(out,u32(index))}
    }
}

// This machine's host name, in buffer; empty when the system gives none.
@(private)
host_name :: proc(buffer:[]u8) -> string {
    if len(buffer)<2 || posix.gethostname(raw_data(buffer),uint(len(buffer)-1))!=.OK {return ""}
    n:=0
    for n<len(buffer) && buffer[n]!=0 {n+=1}
    return string(buffer[:n])
}
