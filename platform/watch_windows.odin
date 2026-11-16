#+build windows
#+private
package platform

import win32 "core:sys/windows"

// FindFirstFile hands out the size and the modification time with every
// name, so listing a folder costs no call per file.
Dir_Iterator :: struct {
    handle:win32.HANDLE,
    data:win32.WIN32_FIND_DATAW,
    pending:bool, // data holds an entry that was not returned yet
}

dir_open :: proc(it:^Dir_Iterator,path:string) -> bool {
    wide:[WATCH_PATH_BYTES+4]u16
    length:=i32(0)
    if len(path)>0 {
        length=win32.MultiByteToWideChar(win32.CP_UTF8,0,raw_data(path),i32(len(path)),raw_data(wide[:]),WATCH_PATH_BYTES)
        if length<=0 {return false}
    }
    if length>0 && wide[length-1]!='/' && wide[length-1]!='\\' {wide[length]='\\';length+=1}
    wide[length]='*';wide[length+1]=0
    it.handle=win32.FindFirstFileW(cstring16(raw_data(wide[:])),&it.data)
    if it.handle==win32.INVALID_HANDLE_VALUE {it.handle=nil;return false}
    it.pending=true
    return true
}

// The name is written to name; an entry whose name does not fit is skipped.
dir_next :: proc(it:^Dir_Iterator,name:[]u8) -> (entry:Dir_Entry,ok:bool) {
    if it.handle==nil {return}
    for {
        if !it.pending && !win32.FindNextFileW(it.handle,&it.data) {return}
        it.pending=false
        d:=&it.data
        if d.cFileName[0]=='.' && (d.cFileName[1]==0 || (d.cFileName[1]=='.' && d.cFileName[2]==0)) {continue}
        length:=win32.WideCharToMultiByte(win32.CP_UTF8,0,cstring16(raw_data(d.cFileName[:])),-1,raw_data(name),i32(len(name)),nil,nil)
        if length<=1 {continue}
        entry.name=string(name[:length-1])
        // A link to a folder is not entered: it could lead back above itself.
        entry.directory=d.dwFileAttributes&win32.FILE_ATTRIBUTE_DIRECTORY!=0 && d.dwFileAttributes&win32.FILE_ATTRIBUTE_REPARSE_POINT==0
        if d.dwFileAttributes&win32.FILE_ATTRIBUTE_DIRECTORY!=0 && !entry.directory {continue}
        entry.size=u64(d.nFileSizeHigh)<<32|u64(d.nFileSizeLow)
        entry.modified=win32.FILETIME_as_unix_nanoseconds(d.ftLastWriteTime)
        return entry,true
    }
}

dir_close :: proc(it:^Dir_Iterator) {
    if it.handle!=nil {win32.FindClose(it.handle);it.handle=nil}
}

// The system signals the handle when a name, a size or a time of writing
// changes anywhere under the folder.
Dir_Notify :: struct {handle:win32.HANDLE}

dir_notify_open :: proc(n:^Dir_Notify,path:string,recursive:bool) -> bool {
    wide:[WATCH_PATH_BYTES+4]u16
    length:=win32.MultiByteToWideChar(win32.CP_UTF8,0,raw_data(path),i32(len(path)),raw_data(wide[:]),WATCH_PATH_BYTES)
    if length<=0 {return false}
    wide[length]=0
    filter:=win32.DWORD(win32.FILE_NOTIFY_CHANGE_FILE_NAME|win32.FILE_NOTIFY_CHANGE_DIR_NAME|win32.FILE_NOTIFY_CHANGE_SIZE|win32.FILE_NOTIFY_CHANGE_LAST_WRITE)
    handle:=win32.FindFirstChangeNotificationW(raw_data(wide[:]),win32.BOOL(recursive),filter)
    if handle==win32.INVALID_HANDLE_VALUE || handle==nil {return false}
    n.handle=handle
    return true
}

// changed: something under the folder changed since the last call that said
// so, or since dir_notify_open. alive is false once the system stops telling.
dir_notify_take :: proc(n:^Dir_Notify) -> (changed,alive:bool) {
    switch win32.WaitForSingleObject(n.handle,0) {
    case win32.WAIT_TIMEOUT:  return false,true
    case win32.WAIT_OBJECT_0: return true,bool(win32.FindNextChangeNotification(n.handle))
    }
    return true,false
}

dir_notify_close :: proc(n:^Dir_Notify) {
    if n.handle!=nil {win32.FindCloseChangeNotification(n.handle);n.handle=nil}
}
