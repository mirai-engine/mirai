package workspace

import win "core:sys/windows"

// An open that shares nothing: a second process fails with a sharing violation.
@(private)
lock_try :: proc(path:string) -> (handle:uintptr,taken,failed:bool) {
    name:=win.utf8_to_wstring(path,context.temp_allocator)
    h:=win.CreateFileW(name,win.GENERIC_READ|win.GENERIC_WRITE,0,nil,win.OPEN_ALWAYS,win.FILE_ATTRIBUTE_NORMAL,nil)
    if h!=win.INVALID_HANDLE_VALUE {return uintptr(h),true,false}
    error:=win.GetLastError()
    busy:=error==win.ERROR_SHARING_VIOLATION || error==win.ERROR_ACCESS_DENIED
    return 0,false,!busy
}

@(private)
lock_close :: proc(handle:uintptr) {
    win.CloseHandle(win.HANDLE(handle))
}
