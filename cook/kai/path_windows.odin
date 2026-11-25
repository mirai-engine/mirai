#+build windows
package kai_assets

import "core:strings"
import win "core:sys/windows"

// Resolves path through links and to its on-disk case using the file system.
@(private)
path_real :: proc(path:string,allocator:=context.temp_allocator) -> (full:string,ok:bool) {
    wide:=win.utf8_to_wstring(path,context.temp_allocator)
    handle:=win.CreateFileW(wide,0,win.FILE_SHARE_READ|win.FILE_SHARE_WRITE|win.FILE_SHARE_DELETE,nil,win.OPEN_EXISTING,win.FILE_FLAG_BACKUP_SEMANTICS,nil)
    if handle==win.INVALID_HANDLE_VALUE {return "",false}
    defer win.CloseHandle(handle)
    needed:=win.GetFinalPathNameByHandleW(handle,nil,0,0)
    if needed==0 {return "",false}
    buf,e:=make([]u16,int(needed)+1,context.temp_allocator)
    if e!=nil {return "",false}
    n:=win.GetFinalPathNameByHandleW(handle,cstring16(raw_data(buf)),needed+1,0)
    if n==0 || int(n)>=len(buf) {return "",false}
    text,ce:=win.utf16_to_utf8_alloc(buf[:n],allocator)
    if ce!=nil {return "",false}
    if strings.has_prefix(text,`\\?\UNC\`) {
        return strings.concatenate({`\\`,text[len(`\\?\UNC\`):]},allocator),true
    }
    if strings.has_prefix(text,`\\?\`) {
        return strings.clone(text[len(`\\?\`):],allocator),true
    }
    return text,true
}
