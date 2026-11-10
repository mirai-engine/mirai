#+build linux
package mirai_net

import "core:math/bits"
import "core:os"
import "core:strconv"
import "core:strings"

// The length of the prefix of the network of an IPv4 address of this machine:
// the narrowest route without a gateway that holds it, from /proc/net/route,
// whose words are in the byte order of the machine, the first byte lowest.
@(private)
lan_prefix :: proc(lan:Address) -> (prefix:int,ok:bool) {
    file,error:=os.open("/proc/net/route")
    if error!=nil {return}
    defer os.close(file)
    buffer:[65536]u8
    size:=0
    for size<len(buffer) {
        count,read_error:=os.read(file,buffer[size:])
        size+=count
        if read_error!=nil || count==0 {break}
    }
    if size==len(buffer) {return}
    own:=u32(lan.ip[0])|u32(lan.ip[1])<<8|u32(lan.ip[2])<<16|u32(lan.ip[3])<<24
    remaining:=string(buffer[:size])
    for line in strings.split_lines_iterator(&remaining) {
        fields:[11]string;count:=0
        field_remaining:=line
        for field in strings.fields_iterator(&field_remaining) {if count<len(fields) {fields[count]=field;count+=1}}
        if count<8 {continue}
        destination,dok:=strconv.parse_u64(fields[1],16)
        gateway,gok:=strconv.parse_u64(fields[2],16)
        flags,fok:=strconv.parse_u64(fields[3],16)
        mask,mok:=strconv.parse_u64(fields[7],16)
        if !dok || !gok || !fok || !mok || flags&1==0 || gateway!=0 || mask==0 || own&u32(mask)!=u32(destination) {continue}
        length:=int(bits.count_ones(u32(mask)))
        if !ok || length>prefix {prefix,ok=length,true}
    }
    return
}
