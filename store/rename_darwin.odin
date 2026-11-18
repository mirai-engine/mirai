package store

import "core:c"
import "core:sys/posix"

foreign import libc "system:System"

@(private)
foreign libc {
    renamex_np :: proc "c" (from,to:cstring,flags:c.uint) -> c.int ---
}

@(private)
rename_new :: proc(from,to:string) -> (exists:bool,error:Error) {
    a,b:[PATH_BYTES+1]u8
    if len(from)>=len(a) || len(to)>=len(b) {return false,.Invalid_Argument}
    copy(a[:],from)
    copy(b[:],to)
    RENAME_EXCL :: 0x00000004
    if renamex_np(cstring(&a[0]),cstring(&b[0]),RENAME_EXCL)==0 {return false,.None}
    if posix.errno()==.EEXIST {return true,.None}
    return false,.Io
}
