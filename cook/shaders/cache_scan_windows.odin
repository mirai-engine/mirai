#+build windows
package shaders

import "base:runtime"
import "core:strings"
import "core:time"
import win32 "core:sys/windows"

// Lists regular files in dir with their modification times using FindFirstFileW /
// FindNextFileW directly, avoiding core:os's per-entry CreateFileW +
// GetFileInformationByHandleEx calls that stall for minutes on large Windows caches.
@(private)
cache_dir_entries :: proc(dir:string,allocator:runtime.Allocator) -> []Cache_Entry_Info {
    pattern:=strings.concatenate({dir,"\\*"},context.temp_allocator)
    wpattern:=win32.utf8_to_wstring(pattern,context.temp_allocator)
    if wpattern==nil {return nil}
    data:win32.WIN32_FIND_DATAW
    handle:=win32.FindFirstFileW(wpattern,&data)
    if handle==win32.INVALID_HANDLE_VALUE {return nil}
    defer win32.FindClose(handle)

    entries:=make([dynamic]Cache_Entry_Info,allocator)
    for {
        if (data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY)==0 {
            if name,err:=win32.wstring_to_utf8(win32.wstring(&data.cFileName[0]),-1,allocator);err==nil && name!="" {
                mtime:=time.unix(0,win32.FILETIME_as_unix_nanoseconds(data.ftLastWriteTime))
                append(&entries,Cache_Entry_Info{name=name,modification_time=mtime})
            }
        }
        if !win32.FindNextFileW(handle,&data) {break}
    }
    return entries[:]
}
