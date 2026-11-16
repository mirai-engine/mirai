#+build darwin
package mirai_net

import "core:c"

foreign import portmap_system "system:System"
foreign portmap_system {
    @(link_name="sysctl")
    portmap_sysctl :: proc(name:[^]c.int,namelen:c.uint,oldp:rawptr,oldlenp:^c.size_t,newp:rawptr,newlen:c.size_t) -> c.int ---
}

@(private)
portmap_gateway :: proc() -> Address {
    mib:=[6]c.int{4,17,0,2,1,0}
    bytes:[65536]u8;length:=c.size_t(len(bytes))
    if portmap_sysctl(raw_data(mib[:]),6,&bytes,&length,nil,0)!=0 || length>len(bytes) {return {}}
    offset:=0
    for offset+92<=int(length) {
        b:=bytes[offset:int(length)]
        size:=int(u16(b[0])|u16(b[1])<<8)
        if size<92 || size>len(b) {return {}}
        flags:=u32(b[8])|u32(b[9])<<8|u32(b[10])<<16|u32(b[11])<<24
        addrs:=u32(b[12])|u32(b[13])<<8|u32(b[14])<<16|u32(b[15])<<24
        if flags&3==3 && addrs&3==3 {
            cursor:=92
            destination,gateway:Address
            for bit in 0..<8 {
                if addrs&(1<<uint(bit))==0 {continue}
                if cursor+2>size {break}
                address_size:=int(b[cursor]);aligned:=max(4,(address_size+3)&~3)
                if address_size<2 || cursor+aligned>size {break}
                if b[cursor+1]==2 && address_size>=8 {
                    addr:=address_ip4(b[cursor+4],b[cursor+5],b[cursor+6],b[cursor+7],5351)
                    if bit==0 {destination=addr};if bit==1 {gateway=addr}
                }
                cursor+=aligned
            }
            if destination.kind==.IP4 && destination.ip==([16]u8{}) && gateway.kind==.IP4 && gateway.ip!=([16]u8{}) {return gateway}
        }
        offset+=size
    }
    return {}
}
