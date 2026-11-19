#+build linux, darwin, freebsd, openbsd, netbsd
package share

import "core:strings"
import "core:sys/posix"

// Bytes this user may still write on the volume that holds path; false when
// the system does not say.
free_bytes :: proc(path:string) -> (bytes:i64,ok:bool) {
    info:posix.statvfs_t
    if posix.statvfs(strings.clone_to_cstring(path,context.temp_allocator),&info)!=.OK {return}
    return i64(info.f_bavail)*i64(info.f_frsize),true
}
