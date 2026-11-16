#+build windows
package platform

import win "core:sys/windows"

// Moves a file or folder to the trash of the system, the Recycle Bin, where
// the user can bring it back. path is absolute.
trash :: proc(path:string) -> bool {
    if path=="" {return false}
    wide:=win.utf8_to_utf16(path,context.temp_allocator)
    if wide==nil {return false}
    // A list of paths ended by an empty one, with the separators of the system.
    from:=make([]u16,len(wide)+2,context.temp_allocator)
    copy(from,wide)
    for &c in from {
        if c=='/' {c='\\'}
    }
    operation:=win.SHFILEOPSTRUCTW{
        wFunc=win.FO_DELETE,
        pFrom=cstring16(raw_data(from)),
        fFlags=win.FOF_ALLOWUNDO|win.FOF_NO_UI,
    }
    return win.SHFileOperationW(&operation)==0 && !operation.fAnyOperationsAborted
}
