#+build windows, linux
package mirai_net

// The broadcast address of the network of an IPv4 address of this machine, from the length of its prefix.
@(private)
lan_broadcast :: proc(lan:Address) -> (broadcast:Address,ok:bool) {
    prefix:=lan_prefix(lan) or_return
    if prefix<=0 || prefix>=31 {return}
    own:=u32(lan.ip[0])<<24|u32(lan.ip[1])<<16|u32(lan.ip[2])<<8|u32(lan.ip[3])
    all:=own|max(u32)>>uint(prefix)
    return address_ip4(u8(all>>24),u8(all>>16),u8(all>>8),u8(all),int(lan.port)),true
}
