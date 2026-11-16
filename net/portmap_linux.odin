#+build linux
package mirai_net

import "core:os"
import "core:strconv"
import "core:strings"

@(private)
portmap_gateway :: proc() -> Address {
    file,error:=os.open("/proc/net/route")
    if error!=nil {return {}}
    defer os.close(file)
    buffer:[65536]u8
    size:=0
    for size<len(buffer) {
        count,read_error:=os.read(file,buffer[size:])
        size+=count
        if read_error!=nil || count==0 {break}
    }
    if size==len(buffer) {return {}}
    bytes:=buffer[:size]
    best_metric:=max(u64)
    result:Address
    remaining:=string(bytes)
    for line in strings.split_lines_iterator(&remaining) {
        fields:[11]string;count:=0
        field_remaining:=line
        for field in strings.fields_iterator(&field_remaining) {if count<len(fields) {fields[count]=field;count+=1}}
        if count<8 || fields[1]!="00000000" || fields[7]!="00000000" {continue}
        gateway,gok:=strconv.parse_u64(fields[2],16)
        flags,fok:=strconv.parse_u64(fields[3],16)
        metric,mok:=strconv.parse_u64(fields[6],10)
        if !gok || !fok || !mok || flags&3!=3 || gateway==0 || metric>=best_metric {continue}
        result=address_ip4(u8(gateway),u8(gateway>>8),u8(gateway>>16),u8(gateway>>24),5351)
        best_metric=metric
    }
    return result
}
