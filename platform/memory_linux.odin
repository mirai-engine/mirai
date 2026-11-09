#+build linux
package platform

import "core:sys/posix"

// From the VmRSS, RssAnon and VmSwap lines of /proc/self/status, in kB.
process_memory :: proc() -> (m:Process_Memory) {
    fd:=posix.open("/proc/self/status",{.CLOEXEC})
    if fd<0 {return}
    defer posix.close(fd)
    buffer:[8192]u8
    length:=0
    for length<len(buffer) {
        read:=posix.read(fd,raw_data(buffer[length:]),uint(len(buffer)-length))
        if read<=0 {break}
        length+=int(read)
    }
    anonymous,swapped:u64
    text:=string(buffer[:length])
    for len(text)>0 {
        end:=0
        for end<len(text) && text[end]!='\n' {end+=1}
        line:=text[:end]
        text=text[min(end+1,len(text)):]
        colon:=0
        for colon<len(line) && line[colon]!=':' {colon+=1}
        kilobytes:u64
        for c in line[min(colon+1,len(line)):] {
            if c>='0' && c<='9' {kilobytes=kilobytes*10+u64(c-'0')} else if kilobytes>0 {break}
        }
        switch line[:colon] {
        case "VmRSS": m.resident=kilobytes*1024
        case "RssAnon": anonymous=kilobytes*1024
        case "VmSwap": swapped=kilobytes*1024
        }
    }
    m.private=anonymous+swapped
    return
}
