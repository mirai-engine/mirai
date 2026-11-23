#+build linux, darwin, freebsd, openbsd, netbsd
package share

import "core:os"
import "core:strings"
import "core:sys/posix"

// Bytes this user may still write on the volume that holds path; false when
// the system does not say.
free_bytes :: proc(path:string) -> (bytes:i64,ok:bool) {
    info:posix.statvfs_t
    if posix.statvfs(strings.clone_to_cstring(path,context.temp_allocator),&info)!=.OK {return}
    return i64(info.f_bavail)*i64(info.f_frsize),true
}

// Whether this user may write the file or folder at path: a read-only file is
// not replaced, and a folder without write access takes no file.
writable :: proc(path:string) -> bool {
    return posix.access(strings.clone_to_cstring(path,context.temp_allocator),{.W_OK})==.OK
}

@(private)
writable_set :: proc(path:string,allow:bool) {
    if os.is_dir(path) {
        os.change_mode(path,os.Permissions_Default_Directory if allow else os.Permissions_Read_All+os.Permissions_Execute_All)
    } else {
        os.change_mode(path,os.Permissions_Default_File if allow else os.Permissions_Read_All)
    }
}
