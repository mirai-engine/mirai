#+build !windows
package kai_assets

import "core:os"

// Resolves path through links and to its on-disk case using the file system.
@(private)
path_real :: proc(path:string,allocator:=context.temp_allocator) -> (full:string,ok:bool) {
    info,e:=os.stat(path,allocator)
    if e!=nil {return "",false}
    return info.fullpath,true
}
