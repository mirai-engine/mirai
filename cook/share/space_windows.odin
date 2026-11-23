package share

import win "core:sys/windows"

// Bytes this user may still write on the volume that holds path; false when
// the system does not say.
free_bytes :: proc(path:string) -> (bytes:i64,ok:bool) {
    available:win.ULARGE_INTEGER
    if !win.GetDiskFreeSpaceExW(win.utf8_to_wstring(path,context.temp_allocator),&available,nil,nil) {return}
    return i64(available),true
}

// Whether this user may write the file or folder at path: a file with the
// read-only attribute is not replaced. Windows ignores that attribute on a
// folder.
writable :: proc(path:string) -> bool {
    attributes:=win.GetFileAttributesW(win.utf8_to_wstring(path,context.temp_allocator))
    if attributes==win.INVALID_FILE_ATTRIBUTES {return false}
    return attributes&win.FILE_ATTRIBUTE_READONLY==0 || attributes&win.FILE_ATTRIBUTE_DIRECTORY!=0
}

// Toggles the read-only attribute on a file (Odin's os.change_mode opens with
// {.Write}, which fails on a file that is already read-only).
@(private)
writable_set :: proc(path:string,allow:bool) {
    wide:=win.utf8_to_wstring(path,context.temp_allocator)
    attributes:=win.GetFileAttributesW(wide)
    if attributes==win.INVALID_FILE_ATTRIBUTES {return}
    next:=attributes&~win.FILE_ATTRIBUTE_READONLY if allow else attributes|win.FILE_ATTRIBUTE_READONLY
    win.SetFileAttributesW(wide,next)
}
