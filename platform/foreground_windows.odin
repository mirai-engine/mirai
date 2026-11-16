#+build windows
package platform

import win32 "core:sys/windows"

foreign import user32 "system:User32.lib"

@(private="file",default_calling_convention="system")
foreign user32 {
    AllowSetForegroundWindow :: proc(process:win32.DWORD) -> win32.BOOL ---
}

// Lets the process pid bring its window to the front, which Windows allows
// only to the process the user last gave input to: this one, when the user
// opened it.
window_foreground_allow :: proc(pid:int) {
    if pid>0 {_=AllowSetForegroundWindow(win32.DWORD(pid))}
}
