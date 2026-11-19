#+build windows
package shaders

import win "core:sys/windows"

// The library next to slangc. The libraries it loads later (the SPIR-V tools
// of Slang) are looked for in its folder, as they are for slangc.
@(private)
compiler_library :: proc(slangc:string,allocator:=context.allocator) -> string {
    folder:=path_parent(slangc)
    win.SetDllDirectoryW(win.utf8_to_wstring(folder,context.temp_allocator))
    return path_join(folder,"slang.dll",allocator=allocator)
}
