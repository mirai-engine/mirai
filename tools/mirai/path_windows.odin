package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

@(private="file") SMTO_ABORTIFHUNG :: 0x0002

// Puts folder first in the Path of the user, without the entries of its kind
// of other copies of the engine, and tells the open programs.
path_add :: proc(folder:string,kind:Path_Entry) -> (message:string,ok:bool) {
    key:=win.utf8_to_wstring("Environment")
    name:=win.utf8_to_wstring("Path")
    flags:win.DWORD=win.RRF_RT_REG_SZ|win.RRF_RT_REG_EXPAND_SZ|win.RRF_NOEXPAND
    size:win.DWORD
    current:string
    status:=win.RegGetValueW(win.HKEY_CURRENT_USER,key,name,flags,nil,nil,&size)
    if status==win.LSTATUS(win.ERROR_SUCCESS) {
        buffer:=make([]u16,size/2+1,context.temp_allocator)
        size=win.DWORD(len(buffer)*2)
        status=win.RegGetValueW(win.HKEY_CURRENT_USER,key,name,flags,nil,&buffer[0],&size)
        if status!=win.LSTATUS(win.ERROR_SUCCESS) {return "mirai setup path: could not read the user Path",false}
        current,_=win.wstring_to_utf8(win.wstring(raw_data(buffer)),-1,context.temp_allocator)
    } else if status!=win.LSTATUS(win.ERROR_FILE_NOT_FOUND) {
        return "mirai setup path: could not read the user Path",false
    }
    entries:[dynamic]string
    entries.allocator=context.temp_allocator
    append(&entries,folder)
    for entry in strings.split(current,";",context.temp_allocator) {
        if entry=="" || strings.equal_fold(entry,folder) {continue}
        if path_entry_is(entry,kind) {continue}
        append(&entries,entry)
    }
    updated:=strings.join(entries[:],";",context.temp_allocator)
    if updated==current {return fmt.tprintf("%s is already in the user Path.",folder),true}
    value:=win.utf8_to_wstring(updated)
    bytes:=win.DWORD((len(win.utf8_to_utf16(updated,context.temp_allocator))+1)*2)
    if win.RegSetKeyValueW(win.HKEY_CURRENT_USER,key,name,win.REG_EXPAND_SZ,rawptr(value),bytes)!=win.LSTATUS(win.ERROR_SUCCESS) {
        return "mirai setup path: could not write the user Path",false
    }
    _=win.SendMessageTimeoutW(win.HWND_BROADCAST,win.WM_SETTINGCHANGE,0,win.LPARAM(uintptr(rawptr(key))),SMTO_ABORTIFHUNG,5000,nil)
    return fmt.tprintf("%s is now in the user Path. Open a new terminal; open applications pick it up when they restart.",folder),true
}

// Whether path is a symbolic link that leads to a folder. A link git made
// before its target existed is a link to a file, which Windows does not
// open as a folder. core:os reports what a link leads to, not the link.
link_to_folder :: proc(path:string) -> bool {
    attributes:=win.GetFileAttributesW(win.utf8_to_wstring(path,context.temp_allocator))
    return attributes!=win.INVALID_FILE_ATTRIBUTES && attributes&win.FILE_ATTRIBUTE_REPARSE_POINT!=0 && attributes&win.FILE_ATTRIBUTE_DIRECTORY!=0
}
