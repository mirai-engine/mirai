#+build windows
package project

import "core:strings"

// A path as Windows names it, in temporary memory: Git Bash writes C:/x as
// /c/x or /cygdrive/c/x. Another path with a root and no drive (/x, \x)
// names a folder of whatever drive is current, never what was meant: not ok.
// UNC paths stay.
path_native :: proc(location:string) -> (native:string,ok:bool) {
    is_separator :: proc(c:u8) -> bool {return c=='/' || c=='\\'}
    rest:=strings.has_prefix(location,"/cygdrive/")?location[len("/cygdrive"):]:location
    if len(rest)>=2 && rest[0]=='/' && (rest[1]|0x20>='a' && rest[1]|0x20<='z') && (len(rest)==2 || rest[2]=='/') {
        drive:=[2]u8{rest[1]&~u8(0x20),':'}
        return strings.concatenate({string(drive[:]),len(rest)==2?"/":rest[2:]},context.temp_allocator),true
    }
    if len(location)>=2 && is_separator(location[0]) && is_separator(location[1]) {return location,true}
    return location,len(location)==0 || !is_separator(location[0])
}
