package main

import win "core:sys/windows"

// The manifests of the implicit Vulkan layers the loader would load, from the
// registry of the machine and of the user.
implicit_layers :: proc(allocator:=context.allocator) -> []string {
    list:=make([dynamic]string,allocator)
    key:=win.utf8_to_wstring(`SOFTWARE\Khronos\Vulkan\ImplicitLayers`,context.temp_allocator)
    for hive in ([2]win.HKEY{win.HKEY_LOCAL_MACHINE,win.HKEY_CURRENT_USER}) {
        opened:win.HKEY
        if win.RegOpenKeyExW(hive,key,0,win.KEY_READ,&opened)!=win.LSTATUS(win.ERROR_SUCCESS) {continue}
        defer win.RegCloseKey(opened)
        for index:win.DWORD=0;;index+=1 {
            name:[1024]u16
            length:=win.DWORD(len(name))
            if win.RegEnumValueW(opened,index,&name[0],&length,nil,nil,nil,nil)!=win.LSTATUS(win.ERROR_SUCCESS) {break}
            text,error:=win.utf16_to_utf8(name[:length],allocator)
            if error==nil {append(&list,text)}
        }
    }
    return list[:]
}
