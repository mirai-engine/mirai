#+build windows
package base

import win32 "core:sys/windows"

@(private)
_memory_stats :: proc "contextless" () -> (total,available:i64,ok:bool) {
    state:win32.MEMORYSTATUSEX
    state.dwLength=size_of(state)
    if !win32.GlobalMemoryStatusEx(&state) {return}
    return i64(state.ullTotalPhys),i64(state.ullAvailPhys),true
}
