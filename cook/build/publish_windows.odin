#+build windows
package build

import "core:os"
import "core:strings"

@(private)
publish :: proc(staged,published:string,retired:="") -> bool {
    retired:=retired
    folder:string
    if retired=="" {
        parent,_:=os.split_path(published)
        if parent=="" {parent="."}
        path,alloc_error:=strings.concatenate({parent,"/",ENGINE_RETIRED},context.temp_allocator)
        if alloc_error!=nil {return false}
        folder=path
        engine_retired_sweep(folder)
    }
    if os.rename(staged,published)==nil {return true}
    // Windows can rename a loaded image, but cannot replace it at its current name.
    info,error:=os.lstat(published,context.temp_allocator)
    if error!=nil || info.type!=.Regular {return false}
    defer if folder!="" {_=os.remove(folder)}
    if retired=="" {
        if os.make_directory(folder)!=nil && !os.is_dir(folder) {return false}
        name,ok:=binary_temp_path(folder)
        if !ok {return false}
        retired=name
    }
    if os.rename(published,retired)!=nil {return false}
    if os.rename(staged,published)==nil {return true}
    _=os.rename(retired,published)
    return false
}

@(private)
ENGINE_RETIRED :: ".mirai-retired"

@(private)
engine_retired_sweep :: proc(folder:string) {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    for entry in entries {
        if strings.has_prefix(entry.name,BINARY_TEMP_PREFIX) {_=os.remove(entry.fullpath)}
    }
    _=os.remove(folder)
}
