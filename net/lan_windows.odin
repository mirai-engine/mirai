#+build windows
package mirai_net

import win "core:sys/windows"

// The length of the prefix of the network of an IPv4 address of this machine.
@(private)
lan_prefix :: proc(lan:Address) -> (prefix:int,ok:bool) {
    size:=u32(16<<10)
    for _ in 0..<3 {
        buffer,error:=make([]u8,size,context.temp_allocator)
        if error!=nil {return}
        adapters:=(^win.IP_Adapter_Addresses)(raw_data(buffer))
        result:=win.GetAdaptersAddresses(.IPv4,{.Skip_Anycast,.Skip_Multicast,.Skip_DNS_Server,.Skip_Friendly_Name},nil,adapters,&size)
        if result==111 {continue} // ERROR_BUFFER_OVERFLOW: size holds what it needs
        if result!=0 {return}
        for adapter:=adapters;adapter!=nil;adapter=adapter.Next {
            for unicast:=adapter.FirstUnicastAddress;unicast!=nil;unicast=unicast.Next {
                native:=unicast.Address.lpSockaddr
                if native==nil || unicast.Address.iSockaddrLength<8 || native.sa_family!=u16(win.AF_INET) {continue}
                bytes:=([^]u8)(native)[4:8]
                if bytes[0]==lan.ip[0] && bytes[1]==lan.ip[1] && bytes[2]==lan.ip[2] && bytes[3]==lan.ip[3] {return int(unicast.OnLinkPrefixLength),true}
            }
        }
        return
    }
    return
}
