package base

import "base:runtime"
import "core:os"

// Removes a file, or a folder with everything in it, without following links;
// nil when there is nothing at path. It stands for os.remove_all
// (docs/ODIN_WORKAROUNDS.md), which on Windows goes through SHFileOperationW:
// its shell code raises C++ exceptions and catches them itself, and the
// vectored handler of the Odin test runner takes each one for a crash of the
// test that called it, or of the runner when a cleanup runs on its thread.
remove_all :: proc(path:string) -> os.Error {
    if path=="" {return nil}
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    info,error:=os.lstat(path,context.temp_allocator)
    if error==.Not_Exist {return nil}
    if error!=nil {return error}
    if info.type==.Directory {
        entries,read_error:=os.read_all_directory_by_path(path,context.temp_allocator)
        if read_error!=nil {return read_error}
        for entry in entries {
            removed:=remove_all(entry.fullpath) if entry.type==.Directory else os.remove(entry.fullpath)
            if removed!=nil && removed!=.Not_Exist {return removed}
        }
    }
    error=os.remove(path)
    return nil if error==.Not_Exist else error
}
