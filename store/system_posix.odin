#+build darwin, linux
package store

import "core:os"
import "core:sys/posix"

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

// Renames the folder from to to, which must not hold anything.
@(private)
rename_folder :: proc(from,to:string) -> os.Error {
    return os.rename(from,to)
}

// Maps size bytes of file read-only; the mapping outlives the file's name.
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
