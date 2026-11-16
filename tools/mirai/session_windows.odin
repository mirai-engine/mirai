#+build windows
package main

import win "core:sys/windows"

// Ends a process and waits for it to be gone. os.process_kill cannot with a
// handle of os.process_open, which lacks PROCESS_TERMINATE (see ODIN_WORKAROUNDS).
process_kill_pid :: proc(pid:int) -> bool {
    handle:=win.OpenProcess(win.PROCESS_TERMINATE|win.SYNCHRONIZE,false,win.DWORD(pid))
    if handle==nil {return false}
    defer win.CloseHandle(handle)
    return bool(win.TerminateProcess(handle,1)) && win.WaitForSingleObject(handle,5000)==win.WAIT_OBJECT_0
}
