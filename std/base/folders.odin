package base

import "base:runtime"
import "core:os"
import "core:strings"

// Makes a folder and the ones above it that are missing; nil when path is
// already a folder. It stands for os.make_directory_all
// (docs/ODIN_WORKAROUNDS.md), which on macOS and Linux gives .Exist for a
// folder that is already there.
make_directory_all :: proc(path:string) -> os.Error {
    error:=os.make_directory_all(path)
    return nil if error==.Exist && os.is_dir(path) else error
}

// Copies what is in the folder src into dst, which it makes when it is
// missing. It stands for os.copy_directory_all (docs/ODIN_WORKAROUNDS.md),
// which on macOS copies src itself into a dst that is already there.
copy_directory_all :: proc(dst,src:string) -> os.Error {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    make_directory_all(dst) or_return
    entries:=os.read_all_directory_by_path(src,context.temp_allocator) or_return
    for entry in entries {
        to:=strings.concatenate({dst,"/",entry.name},context.temp_allocator) or_return
        copied:=copy_directory_all(to,entry.fullpath) if entry.type==.Directory else os.copy_file(to,entry.fullpath)
        if copied!=nil {return copied}
    }
    return nil
}
