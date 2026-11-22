package kai

import "core:c"
import "core:strings"

foreign import libc "system:System"

@(private)
foreign libc {
    @(link_name="flock") posix_flock :: proc "c" (fd:c.int,operation:c.int) -> c.int ---
    clonefile :: proc "c" (src,dst:cstring,flags:u32) -> c.int ---
}

@(private) LOCK_EX :: 2
@(private) LOCK_NB :: 4

@(private)
flock_exclusive :: proc(fd:uintptr) -> bool {
    return posix_flock(c.int(fd),LOCK_EX|LOCK_NB)==0
}

// Copies the file at from to to, which must not exist, sharing its blocks
// (APFS clonefile): Unsupported where the volume cannot.
file_clone :: proc(from,to:string) -> Error {
    a,e1:=strings.clone_to_cstring(from,context.temp_allocator)
    b,e2:=strings.clone_to_cstring(to,context.temp_allocator)
    if e1!=nil || e2!=nil {return .Out_Of_Memory}
    if clonefile(a,b,0)!=0 {return .Unsupported}
    return .None
}
