package share

import win "core:sys/windows"

// Bytes this user may still write on the volume that holds path; false when
// the system does not say.
free_bytes :: proc(path:string) -> (bytes:i64,ok:bool) {
    available:win.ULARGE_INTEGER
    if !win.GetDiskFreeSpaceExW(win.utf8_to_wstring(path,context.temp_allocator),&available,nil,nil) {return}
    return i64(available),true
}
