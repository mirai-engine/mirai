package store

import "core:c"
import "core:os"
import "core:sys/posix"

foreign import libc "system:System"

@(private)
foreign libc {
    renamex_np :: proc "c" (from,to:cstring,flags:c.uint) -> c.int ---
    sysctl :: proc "c" (name:[^]c.int,namelen:c.uint,oldp:rawptr,oldlenp:^c.size_t,newp:rawptr,newlen:c.size_t) -> c.int ---
}

@(private)
rename_new :: proc(from,to:string) -> (exists:bool,error:Error) {
    a,b:[PATH_BYTES+1]u8
    if len(from)>=len(a) || len(to)>=len(b) {return false,.Invalid_Argument}
    copy(a[:],from)
    copy(b[:],to)
    RENAME_EXCL :: 0x00000004
    if renamex_np(cstring(&a[0]),cstring(&b[0]),RENAME_EXCL)==0 {return false,.None}
    errno:=posix.errno()
    if errno==.EEXIST {return true,.None}
    return false,os_error(os.Platform_Error(errno))
}

@(private)
no_space :: proc(error:os.Error) -> bool {
    e,ok:=error.(os.Platform_Error)
    return ok && (e==.ENOSPC || e==.EDQUOT)
}

// When the process started, in microseconds of the system clock; alive is
// false for one that is not running.
@(private)
process_start :: proc(pid:u64) -> (start:u64,alive:bool) {
    if pid==0 || pid>u64(max(i32)) {return 0,false}
    CTL_KERN :: 1
    KERN_PROC :: 14
    KERN_PROC_PID :: 1
    // kinfo_proc begins with extern_proc: p_starttime, a timeval, at 0 and p_stat at 36.
    KINFO_PROC_BYTES :: 648
    SZOMB :: 5
    name:=[4]c.int{CTL_KERN,KERN_PROC,KERN_PROC_PID,c.int(pid)}
    info:[KINFO_PROC_BYTES]u8
    size:=c.size_t(len(info))
    if sysctl(&name[0],4,&info[0],&size,nil,0)!=0 || size<40 || info[36]==SZOMB {return 0,false}
    seconds:=(^i64)(&info[0])^
    micros:=(^i32)(&info[8])^
    return u64(seconds)*1_000_000+u64(micros),true
}

@(private)
host_name :: proc(buffer:^[HOST_BYTES]u8) {
    posix.gethostname(&buffer[0],HOST_BYTES-1)
}
