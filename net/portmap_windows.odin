#+build windows
package mirai_net

import cnet "core:net"
import win "core:sys/windows"

@(private)
portmap_gateway :: proc() -> Address {
    probe,error:=cnet.make_unbound_udp_socket(.IP4)
    if error!=nil {return {}}
    connected:=socket_connect(cnet.Socket(probe),address_ip4(1,1,1,1,5351))
    endpoint,endpoint_error:=cnet.bound_endpoint(probe)
    cnet.close(probe)
    if !connected || endpoint_error!=nil {return {}}
    local:=address_from_endpoint(endpoint)
    interfaces,interface_error:=cnet.enumerate_interfaces()
    if interface_error!=nil {return {}}
    defer cnet.destroy_interfaces(interfaces)
    for iface in interfaces {
        if .Up not_in iface.link.state {continue}
        selected:=false
        for lease in iface.unicast {
            if ip,ok:=lease.address.(cnet.IP4_Address);ok {
                selected=selected || (local.kind==.IP4 && ip[0]==local.ip[0] && ip[1]==local.ip[1] && ip[2]==local.ip[2] && ip[3]==local.ip[3])
            }
        }
        if !selected {continue}
        for gateway in iface.gateways {
            if ip,ok:=gateway.(cnet.IP4_Address);ok && ip!=(cnet.IP4_Address{}) {return address_ip4(ip[0],ip[1],ip[2],ip[3],5351)}
        }
    }
    return {}
}

// Starts connecting a non-blocking socket to address, IPv4 or IPv6: true
// while it connects or once it did (socket_connected tells which). A
// datagram socket only takes the route, sending nothing.
socket_connect :: proc(socket:cnet.Socket,address:Address) -> bool {
    result:i32
    #partial switch address.kind {
    case .IP4:
        native:=win.sockaddr_in{sin_family=u16(win.AF_INET),sin_port=u16be(address.port)}
        for i in 0..<4 {([^]u8)(&native.sin_addr)[i]=address.ip[i]}
        result=win.connect(win.SOCKET(socket),(^win.SOCKADDR_STORAGE_LH)(&native),size_of(native))
    case .IP6:
        native:=win.sockaddr_in6{sin6_family=u16(win.AF_INET6),sin6_port=u16be(address.port),sin6_scope_id=win.c_ulong(address.zone)}
        native.sin6_addr=transmute(win.in6_addr)address.ip
        result=win.connect(win.SOCKET(socket),(^win.SOCKADDR_STORAGE_LH)(&native),size_of(native))
    case: return false
    }
    if result==0 {return true}
    error:=win.WSAGetLastError()
    return error==win.WSAEWOULDBLOCK || error==win.WSAEINPROGRESS
}

// Whether the connect socket_connect started ended, without waiting, and
// whether it succeeded.
socket_connected :: proc(socket:cnet.Socket) -> (ready,ok:bool) {
    writable:=win.fd_set{fd_count=1,fd_array={0=win.SOCKET(socket)}}
    failed:=writable
    timeout:=win.timeval{}
    result:=win.select(0,nil,&writable,&failed,&timeout)
    if result==0 {return false,false}
    if result<0 {return true,false}
    error:i32;size:=i32(size_of(error))
    if win.getsockopt(win.SOCKET(socket),win.SOL_SOCKET,win.SO_ERROR,([^]win.c_char)(&error),&size)!=0 {return true,false}
    return true,error==0 && writable.fd_count!=0
}
