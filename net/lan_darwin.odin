#+build darwin
package mirai_net

import cnet "core:net"

// The broadcast address of the network of an IPv4 address of this machine: what
// getifaddrs gives the interface that holds it.
@(private)
lan_broadcast :: proc(lan:Address) -> (broadcast:Address,ok:bool) {
    interfaces,error:=cnet.enumerate_interfaces(context.temp_allocator)
    if error!=nil {return}
    for iface in interfaces {
        holds:=false
        for lease in iface.unicast {
            if ip,is_ip4:=lease.address.(cnet.IP4_Address);is_ip4 && ip[0]==lan.ip[0] && ip[1]==lan.ip[1] && ip[2]==lan.ip[2] && ip[3]==lan.ip[3] {holds=true}
        }
        if !holds {continue}
        for address in iface.multicast {
            if ip,is_ip4:=address.(cnet.IP4_Address);is_ip4 && ip!=(cnet.IP4_Address{}) {return address_ip4(ip[0],ip[1],ip[2],ip[3],int(lan.port)),true}
        }
    }
    return
}
