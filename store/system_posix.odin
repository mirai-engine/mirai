#+build darwin, linux
package store

import "core:c"
import "core:os"
import "core:sys/posix"

when ODIN_OS==.Darwin {
    foreign import libc "system:System"
} else {
    foreign import libc "system:c"
}

@(private="file")
foreign libc {
    flock :: proc "c" (fd:c.int,operation:c.int) -> c.int ---
}

@(private="file") LOCK_SH :: 1
@(private="file") LOCK_EX :: 2
@(private="file") LOCK_NB :: 4
@(private="file") LOCK_UN :: 8

@(private)
file_open :: proc(path:string,flags:=os.File_Flags{.Read}) -> (^os.File,os.Error) {
    return os.open(path,flags)
}

@(private)
file_remove :: proc(path:string) -> os.Error {
    return os.remove(path)
}

// Renames from to to, replacing to; a reader of the old to keeps it.
@(private)
rename_replace :: proc(from,to:string) -> os.Error {
    return os.rename(from,to)
}

// Locks file for this open file, apart from every other open file of it, also
// of this process; the system lets it go when the process ends. With wait it
// blocks until the lock is free, else locked is false while another holds it.
@(private)
file_lock :: proc(file:^os.File,mode:Lock_Mode,wait:bool) -> (locked:bool,error:Error) {
    operation:c.int=LOCK_EX if mode==.Exclusive else LOCK_SH
    if !wait {operation|=LOCK_NB}
    for {
        if flock(c.int(os.fd(file)),operation)==0 {return true,.None}
        errno:=posix.errno()
        if errno==.EINTR {continue}
        if errno==.EWOULDBLOCK {return false,.None}
        return false,.Io
    }
}

@(private)
file_unlock :: proc(file:^os.File) {
    flock(c.int(os.fd(file)),LOCK_UN)
}

@(private)
no_space :: proc(error:os.Error) -> bool {
    e,ok:=error.(os.Platform_Error)
    return ok && (e==.ENOSPC || e==.EDQUOT)
}

// Maps size bytes of file read-only; the mapping outlives the file's name and
// its descriptor.
@(private)
file_map :: proc(file:^os.File,size:i64) -> ([]u8,Error) {
    if size<=0 || size>i64(max(int)) {return nil,.Invalid_Argument}
    address:=posix.mmap(nil,uint(size),{.READ},{.SHARED},posix.FD(os.fd(file)),0)
    if address==posix.MAP_FAILED {return nil,.Io}
    return ([^]u8)(address)[:size],.None
}

@(private)
file_unmap :: proc(view:[]u8) {
    if len(view)>0 {posix.munmap(raw_data(view),uint(len(view)))}
}
