#+build windows
package serial

import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import win32 "core:sys/windows"
import "core:time"

@(private)
Read_File :: win32.HANDLE

// Readers share delete, so a save renames over a file another reader holds.
@(private)
file_open_read :: proc(path:string) -> (Read_File,File_Error) {
    wide:=file_wide(path)
    if wide==nil {return nil,.Open}
    file:=win32.CreateFileW(wide,win32.FILE_GENERIC_READ,win32.FILE_SHARE_READ|win32.FILE_SHARE_WRITE|win32.FILE_SHARE_DELETE,nil,win32.OPEN_EXISTING,win32.FILE_ATTRIBUTE_NORMAL,nil)
    if file!=win32.INVALID_HANDLE {return file,.None}
    error:=win32.GetLastError()
    return nil,error==win32.ERROR_FILE_NOT_FOUND || error==win32.ERROR_PATH_NOT_FOUND?.Not_Found:.Open
}

@(private)
file_close :: proc(file:Read_File) {win32.CloseHandle(file)}

@(private)
file_size :: proc(file:Read_File) -> (i64,bool) {
    size:win32.LARGE_INTEGER
    sized:=win32.GetFileSizeEx(file,&size)
    return i64(size),bool(sized)
}

@(private)
file_read_at :: proc(file:Read_File,offset:i64,out:[]u8) -> bool {
    for total:=0;total<len(out); {
        at:win32.OVERLAPPED
        at.OffsetFull=u64(offset+i64(total))
        count:win32.DWORD
        if !win32.ReadFile(file,raw_data(out[total:]),win32.DWORD(min(len(out)-total,1<<30)),&count,&at) || count==0 {return false}
        total+=int(count)
    }
    return true
}

// A rename with POSIX semantics replaces a file that readers hold open with FILE_SHARE_DELETE; a
// scanner or an indexer that opened it without sharing delete holds it a moment, so the rename
// retries (Godot retries the same way). A file system without POSIX renames (FAT) takes the
// plain replace.
@(private)
RENAME_PATIENCE :: time.Second

@(private="file")
Rename_Info :: struct {flags:u32,root:win32.HANDLE,name_bytes:u32,name:[1]u16}

@(private)
file_replace :: proc(from,to:string) -> bool {
    FILE_RENAME_INFO_EX :: win32.FILE_INFO_BY_HANDLE_CLASS(22)
    FILE_RENAME_FLAG_REPLACE_IF_EXISTS :: 0x1
    FILE_RENAME_FLAG_POSIX_SEMANTICS :: 0x2
    absolute,absolute_error:=os.get_absolute_path(to,context.temp_allocator)
    wide_from:=file_wide(from)
    if absolute_error!=nil || wide_from==nil {return false}
    target:=win32.utf8_to_utf16(file_verbatim(absolute),context.temp_allocator)
    info_bytes,alloc_error:=mem.alloc_bytes(int(offset_of(Rename_Info,name))+size_of(u16)*(len(target)+1),align_of(Rename_Info),context.temp_allocator)
    if target==nil || alloc_error!=nil {return false}
    info:=(^Rename_Info)(raw_data(info_bytes))
    info^={flags=FILE_RENAME_FLAG_REPLACE_IF_EXISTS|FILE_RENAME_FLAG_POSIX_SEMANTICS,name_bytes=u32(size_of(u16)*len(target))}
    copy(info_bytes[offset_of(Rename_Info,name):],slice.to_bytes(target))
    staging:=win32.CreateFileW(wide_from,win32.DELETE|win32.SYNCHRONIZE,win32.FILE_SHARE_READ|win32.FILE_SHARE_WRITE|win32.FILE_SHARE_DELETE,nil,win32.OPEN_EXISTING,win32.FILE_ATTRIBUTE_NORMAL,nil)
    if staging==win32.INVALID_HANDLE {return false}
    defer win32.CloseHandle(staging)
    class:=FILE_RENAME_INFO_EX
    start:=time.tick_now()
    for !win32.SetFileInformationByHandle(staging,class,info,win32.DWORD(len(info_bytes))) {
        switch error:=win32.GetLastError();error {
        case win32.ERROR_INVALID_PARAMETER,win32.ERROR_NOT_SUPPORTED,win32.ERROR_INVALID_FUNCTION:
            if class==.FileRenameInfo {return false}
            class,info.flags=.FileRenameInfo,1
        case win32.ERROR_SHARING_VIOLATION,win32.ERROR_ACCESS_DENIED:
            if time.tick_since(start)>RENAME_PATIENCE {return false}
            win32.Sleep(1)
        case:
            return false
        }
    }
    return true
}

// Past MAX_PATH Windows takes only an absolute path with the \\?\ prefix and backslashes.
@(private="file")
file_wide :: proc(path:string) -> win32.wstring {
    if len(path)<248 {return win32.utf8_to_wstring(path,context.temp_allocator)}
    absolute,error:=os.get_absolute_path(path,context.temp_allocator)
    return error==nil?win32.utf8_to_wstring(file_verbatim(absolute),context.temp_allocator):nil
}

@(private="file")
file_verbatim :: proc(absolute:string) -> string {
    long,_:=strings.replace_all(strings.concatenate({`\\?\`,absolute},context.temp_allocator),"/",`\`,context.temp_allocator)
    return long
}
