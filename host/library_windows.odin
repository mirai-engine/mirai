package host

import win "core:sys/windows"

// Windows looks for the libraries a library links in the folder of the
// program and in PATH, not in the folder of the library: it is told the folder.
library_dependencies_where :: proc(folder:string) {
    _=win.SetDllDirectoryW(win.utf8_to_wstring(folder,context.temp_allocator))
}
