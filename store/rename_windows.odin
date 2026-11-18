package store

import "core:sys/windows"

@(private)
rename_new :: proc(from,to:string) -> (exists:bool,error:Error) {
    a,b:[PATH_BYTES+9]u16
    old:=rename_path(from,&a) or_return
    new:=rename_path(to,&b) or_return
    if windows.MoveFileExW(old,new,0) {return false,.None}
    code:=windows.GetLastError()
    if code==windows.ERROR_ALREADY_EXISTS || code==windows.ERROR_FILE_EXISTS {return true,.None}
    return false,.Io
}

@(private)
rename_path :: proc(path:string,buffer:^[PATH_BYTES+9]u16) -> (cstring16,Error) {
    text:[PATH_BYTES+1]u16
    if len(path)==0 || len(path)>PATH_BYTES {return nil,.Invalid_Argument}
    converted:=windows.MultiByteToWideChar(windows.CP_UTF8,windows.MB_ERR_INVALID_CHARS,
        raw_data(path),i32(len(path)),raw_data(text[:]),i32(len(text)-1))
    if converted==0 {return nil,.Invalid_Argument}
    target:=buffer[8:]
    n:=windows.GetFullPathNameW(cstring16(&text[0]),u32(len(target)),cstring16(&target[0]),nil)
    if n==0 || int(n)>=len(target) {return nil,.Io}
    prefix:=[4]u16{'\\','\\','?','\\'}
    if n<248 || (^[4]u16)(&target[0])^==prefix {
        return cstring16(&target[0]),.None
    }
    if target[0]=='\\' && target[1]=='\\' {
        copy(buffer[2:10],[]u16{'\\','\\','?','\\','U','N','C','\\'})
        return cstring16(&buffer[2]),.None
    }
    copy(buffer[4:8],prefix[:])
    return cstring16(&buffer[4]),.None
}
