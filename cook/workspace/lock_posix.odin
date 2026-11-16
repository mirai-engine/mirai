#+build !windows
package workspace

import "core:c"
import "core:strings"
import "core:sys/posix"

when ODIN_OS==.Darwin {
    foreign import libc "system:System.framework"
} else {
    foreign import libc "system:c"
}

@(private="file")
LOCK_EX :: 2
@(private="file")
LOCK_NB :: 4

@(private="file")
foreign libc {
    flock :: proc(fd:c.int,operation:c.int) -> c.int ---
}

// A lock of the open file, as on Windows: another open of it, also in this
// process, gets EWOULDBLOCK, and closing that one does not release this one.
@(private)
lock_try :: proc(path:string) -> (handle:uintptr,taken,failed:bool) {
    name:=strings.clone_to_cstring(path,context.temp_allocator)
    fd:=posix.open(name,{.RDWR,.CREAT,.CLOEXEC},posix.mode_t{.IRUSR,.IWUSR,.IRGRP,.IROTH})
    if fd<0 {return 0,false,true}
    if flock(c.int(fd),LOCK_EX|LOCK_NB)==0 {return uintptr(fd),true,false}
    errno:=posix.errno()
    posix.close(fd)
    return 0,false,errno!=.EWOULDBLOCK
}

@(private)
lock_close :: proc(handle:uintptr) {
    posix.close(posix.FD(handle))
}
