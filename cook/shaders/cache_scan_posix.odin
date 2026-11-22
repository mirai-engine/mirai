#+build !windows
package shaders

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strings"

@(private)
cache_dir_entries :: proc(dir:string,allocator:runtime.Allocator) -> []Cache_Entry_Info {
    scratch:virtual.Arena
    if virtual.arena_init_growing(&scratch)!=nil {return nil}
    defer virtual.arena_destroy(&scratch)
    files,err:=os.read_all_directory_by_path(dir,virtual.arena_allocator(&scratch))
    if err!=nil {return nil}
    entries:=make([dynamic]Cache_Entry_Info,0,len(files),allocator)
    for file in files {
        if file.type==.Directory {continue}
        append(&entries,Cache_Entry_Info{
            name=strings.clone(file.name,allocator),
            modification_time=file.modification_time,
        })
    }
    return entries[:]
}
