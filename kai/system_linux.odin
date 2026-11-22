package kai

import "core:os"
import "core:sys/linux"

@(private)
flock_exclusive :: proc(fd:uintptr) -> bool {
    return linux.flock(linux.Fd(fd),{.EX,.NB})==.NONE
}

@(private) FICLONE :: 0x40049409

// Copies the file at from to to, which must not exist, sharing its extents
// (Btrfs and XFS FICLONE): Unsupported where the volume cannot.
file_clone :: proc(from,to:string) -> Error {
    source,e:=os.open(from)
    if e!=nil {return .Io}
    defer os.close(source)
    target,f:=os.open(to,{.Write,.Create,.Excl})
    if f!=nil {return .Io}
    result:=linux.ioctl(linux.Fd(os.fd(target)),FICLONE,os.fd(source))
    os.close(target)
    if result!=0 {
        os.remove(to)
        return .Unsupported
    }
    return .None
}

@(private) SO_REUSEPORT :: 15
