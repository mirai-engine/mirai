#+build windows
package asset

import "core:mem"
import win "core:sys/windows"

// Reads a file past the cache of the system: what a first load after a boot
// pays for its data. The directory entries stay cached.
@(private)
bench_read_uncached :: proc(path:string,size:int,allocator:mem.Allocator) -> (data:[]u8,ok:bool) {
    SECTOR :: 4096
    name:=win.utf8_to_wstring(path,context.temp_allocator)
    handle:=win.CreateFileW(name,win.GENERIC_READ,win.FILE_SHARE_READ,nil,win.OPEN_EXISTING,win.FILE_FLAG_NO_BUFFERING,nil)
    if handle==win.INVALID_HANDLE_VALUE {return nil,false}
    defer win.CloseHandle(handle)
    padded:=(size+SECTOR-1)&~int(SECTOR-1)
    block,error:=mem.alloc_bytes_non_zeroed(padded,SECTOR,allocator)
    if error!=nil {return nil,false}
    total:=0
    for total<size {
        count:win.DWORD
        if !win.ReadFile(handle,raw_data(block[total:]),win.DWORD(min(padded-total,1<<30)),&count,nil) || count==0 {break}
        total+=int(count)
    }
    return block[:size],total>=size
}
