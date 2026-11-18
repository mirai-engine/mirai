package store

import "core:sys/linux"

@(private)
rename_new :: proc(from,to:string) -> (exists:bool,error:Error) {
    a,b:[PATH_BYTES+1]u8
    if len(from)>=len(a) || len(to)>=len(b) {return false,.Invalid_Argument}
    copy(a[:],from)
    copy(b[:],to)
    result:=linux.renameat2(linux.AT_FDCWD,cstring(&a[0]),
        linux.AT_FDCWD,cstring(&b[0]),{.NOREPLACE})
    if result==.NONE {return false,.None}
    if result==.EEXIST {return true,.None}
    return false,.Io
}
