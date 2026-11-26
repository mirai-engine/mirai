package store

import "core:os"
import "core:sys/windows"
import "core:time"

// Odin workaround (docs/ODIN_WORKAROUNDS.md, file_share_delete): os.open on
// Windows does not share delete, so a file of the store held open by a reader,
// another process or an antivirus could be neither replaced nor removed.
// file_open shares read, write and delete.

@(private="file") FILE_RENAME_INFO_EX :: windows.FILE_INFO_BY_HANDLE_CLASS(22)
@(private="file") FILE_DISPOSITION_INFO_EX :: windows.FILE_INFO_BY_HANDLE_CLASS(21)
@(private="file") FILE_RENAME_FLAG_REPLACE_IF_EXISTS :: 0x1
@(private="file") FILE_RENAME_FLAG_POSIX_SEMANTICS :: 0x2
@(private="file") FILE_DISPOSITION_FLAG_DELETE :: 0x1
@(private="file") FILE_DISPOSITION_FLAG_POSIX_SEMANTICS :: 0x2
@(private="file") FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE :: 0x10
@(private="file") ERROR_DISK_FULL :: 112
@(private="file") ERROR_HANDLE_DISK_FULL :: 39
@(private="file") SHARE_ALL :: windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE
// An antivirus or the search indexer opens a file for a few milliseconds
// after it is written; a lasting cause still fails, about 0.4 s later.
@(private="file") RETRIES :: 10 // sleeps of 1, 2, 4 ... 64, then 100 ms

@(private="file")
Wide_Path :: [PATH_BYTES+9]u16

// FILE_RENAME_INFO with the name inline; the name length is in bytes, without
// the terminator.
@(private="file")
File_Rename_Info :: struct {
    flags:u32,
    root:windows.HANDLE,
    name_length:u32,
    name:Wide_Path,
}
#assert(offset_of(File_Rename_Info,root)==8 && offset_of(File_Rename_Info,name)==20)
#assert(align_of(File_Rename_Info)==8)

// Runs attempt until it succeeds or fails with something other than a
// sharing violation or a denied access, sleeping a little longer each time.
@(private="file")
retrying :: proc(attempt:proc(data:rawptr) -> u32,data:rawptr) -> u32 {
    for retry:=0;;retry+=1 {
        code:=attempt(data)
        if code!=windows.ERROR_ACCESS_DENIED && code!=windows.ERROR_SHARING_VIOLATION || retry==RETRIES {return code}
        time.sleep(time.Duration(min(1<<uint(retry),100))*time.Millisecond)
    }
}

@(private="file")
platform_error :: proc(code:u32) -> os.Error {
    switch code {
    case 0: return nil
    case windows.ERROR_FILE_NOT_FOUND,windows.ERROR_PATH_NOT_FOUND: return .Not_Exist
    case windows.ERROR_FILE_EXISTS,windows.ERROR_ALREADY_EXISTS: return .Exist
    case windows.ERROR_NOT_ENOUGH_MEMORY,windows.ERROR_OUTOFMEMORY: return .Out_Of_Memory
    }
    return os.Platform_Error(code)
}

@(private)
file_open :: proc(path:string,flags:=os.File_Flags{.Read}) -> (^os.File,os.Error) {
    Open :: struct {path:cstring16,access,mode:u32,handle:windows.HANDLE}
    buffer:Wide_Path
    wide,error:=rename_path(path,&buffer)
    if error!=.None {return nil,.Invalid_Path}
    o:=Open{path=wide,mode=windows.OPEN_EXISTING}
    if .Read in flags {o.access|=windows.FILE_GENERIC_READ}
    if .Write in flags || .Create in flags {o.access|=windows.FILE_GENERIC_WRITE}
    switch {
    case flags&{.Create,.Excl}=={.Create,.Excl}: o.mode=windows.CREATE_NEW
    case flags&{.Create,.Trunc}=={.Create,.Trunc}: o.mode=windows.CREATE_ALWAYS
    case .Create in flags: o.mode=windows.OPEN_ALWAYS
    case .Trunc in flags: o.mode=windows.TRUNCATE_EXISTING
    }
    code:=retrying(proc(data:rawptr) -> u32 {
        o:=(^Open)(data)
        o.handle=windows.CreateFileW(o.path,o.access,SHARE_ALL,nil,o.mode,windows.FILE_ATTRIBUTE_NORMAL,nil)
        return 0 if o.handle!=windows.INVALID_HANDLE_VALUE else windows.GetLastError()
    },&o)
    if code!=0 {return nil,platform_error(code)}
    file:=os.new_file(uintptr(o.handle),path)
    if file==nil {
        windows.CloseHandle(o.handle)
        return nil,.Out_Of_Memory
    }
    return file,nil
}

// Takes the name out of its folder at once, also while a scanner holds the
// file, and also when it is read-only.
@(private)
file_remove :: proc(path:string) -> os.Error {
    buffer:Wide_Path
    wide,error:=rename_path(path,&buffer)
    if error!=.None {return .Invalid_Path}
    return platform_error(retrying(proc(data:rawptr) -> u32 {
        path:=cstring16(data)
        handle:=windows.CreateFileW(path,windows.DELETE,SHARE_ALL,nil,windows.OPEN_EXISTING,
            windows.FILE_FLAG_OPEN_REPARSE_POINT,nil)
        if handle==windows.INVALID_HANDLE_VALUE {
            code:=windows.GetLastError()
            if code==windows.ERROR_FILE_NOT_FOUND || code==windows.ERROR_PATH_NOT_FOUND {return code}
        } else {
            flags:windows.DWORD=FILE_DISPOSITION_FLAG_DELETE|FILE_DISPOSITION_FLAG_POSIX_SEMANTICS|
                FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE
            deleted:=windows.SetFileInformationByHandle(handle,FILE_DISPOSITION_INFO_EX,&flags,size_of(flags))
            windows.CloseHandle(handle)
            if deleted {return 0}
        }
        // A file system without POSIX semantics.
        return 0 if windows.DeleteFileW(path) else windows.GetLastError()
    },rawptr(wide)))
}

@(private="file")
Move :: struct {from,to:cstring16,flags:u32,posix:bool}

@(private="file")
move :: proc(data:rawptr) -> u32 {
    m:=(^Move)(data)
    if windows.MoveFileExW(m.from,m.to,m.flags) {return 0}
    code:=windows.GetLastError()
    // A destination held open, even shared, keeps its name until its last
    // handle closes; a POSIX rename supersedes it at once, and its readers
    // keep the old file.
    if m.posix && (code==windows.ERROR_ACCESS_DENIED || code==windows.ERROR_SHARING_VIOLATION) && posix_replace(m.from,m.to) {return 0}
    return code
}

@(private="file")
posix_replace :: proc(from,to:cstring16) -> bool {
    handle:=windows.CreateFileW(from,windows.DELETE|windows.SYNCHRONIZE,SHARE_ALL,nil,windows.OPEN_EXISTING,
        windows.FILE_FLAG_BACKUP_SEMANTICS,nil)
    if handle==windows.INVALID_HANDLE_VALUE {return false}
    defer windows.CloseHandle(handle)
    name:=([^]u16)(rawptr(to))
    length:=0
    for name[length]!=0 {length+=1}
    info:File_Rename_Info
    if length+1>len(info.name) {return false}
    info.flags=FILE_RENAME_FLAG_POSIX_SEMANTICS|FILE_RENAME_FLAG_REPLACE_IF_EXISTS
    info.name_length=u32(length*2)
    copy(info.name[:length+1],name[:length+1])
    size:=int(offset_of(File_Rename_Info,name))+(length+1)*2
    return bool(windows.SetFileInformationByHandle(handle,FILE_RENAME_INFO_EX,&info,u32(size)))
}

// Renames from to to, replacing to; a reader of the old to keeps it.
@(private)
rename_replace :: proc(from,to:string) -> os.Error {
    a,b:Wide_Path
    m:Move
    error:Error
    if m.from,error=rename_path(from,&a);error!=.None {return .Invalid_Path}
    if m.to,error=rename_path(to,&b);error!=.None {return .Invalid_Path}
    m.flags,m.posix=windows.MOVEFILE_REPLACE_EXISTING,true
    return platform_error(retrying(move,&m))
}

@(private)
rename_path :: proc(path:string,buffer:^Wide_Path) -> (cstring16,Error) {
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

@(private)
no_space :: proc(error:os.Error) -> bool {
    e,ok:=error.(os.Platform_Error)
    return ok && (u32(e)==ERROR_DISK_FULL || u32(e)==ERROR_HANDLE_DISK_FULL)
}

// Locks a byte far past the end of file, so the lock never stands in the way
// of reading or writing its content, for this handle apart from every other
// handle of it, also of this process; the system lets it go when the process
// ends. With wait it blocks until the lock is free, else locked is false while
// another holds it.
@(private)
file_lock :: proc(file:^os.File,mode:Lock_Mode,wait:bool) -> (locked:bool,error:Error) {
    flags:windows.DWORD
    if mode==.Exclusive {flags|=windows.LOCKFILE_EXCLUSIVE_LOCK}
    if !wait {flags|=windows.LOCKFILE_FAIL_IMMEDIATELY}
    at:windows.OVERLAPPED
    at.OffsetHigh=LOCK_AT
    if windows.LockFileEx(windows.HANDLE(os.fd(file)),flags,0,1,0,&at) {return true,.None}
    code:=windows.GetLastError()
    if code==windows.ERROR_LOCK_VIOLATION || code==windows.ERROR_IO_PENDING {return false,.None}
    return false,.Io
}

@(private)
file_unlock :: proc(file:^os.File) {
    at:windows.OVERLAPPED
    at.OffsetHigh=LOCK_AT
    windows.UnlockFileEx(windows.HANDLE(os.fd(file)),0,1,0,&at)
}

@(private="file") LOCK_AT :: 0x4000_0000 // high half of the offset locked: 1<<62

// Maps size bytes of file read-only; the mapping outlives the file's name and
// its handle.
@(private)
file_map :: proc(file:^os.File,size:i64) -> ([]u8,Error) {
    if size<=0 || size>i64(max(int)) {return nil,.Invalid_Argument}
    handle:=windows.HANDLE(os.fd(file))
    mapping:=windows.CreateFileMappingW(handle,nil,windows.PAGE_READONLY,u32(u64(size)>>32),u32(size),nil)
    if mapping==nil {return nil,.Io}
    defer windows.CloseHandle(mapping)
    address:=windows.MapViewOfFile(mapping,windows.FILE_MAP_READ,0,0,uint(size))
    if address==nil {return nil,.Io}
    return ([^]u8)(address)[:size],.None
}

@(private)
file_unmap :: proc(view:[]u8) {
    if len(view)>0 {windows.UnmapViewOfFile(raw_data(view))}
}
