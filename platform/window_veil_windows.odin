#+build windows
#+private
package platform

import win32 "core:sys/windows"
import sdl "vendor:sdl3"

// Cloaked, a window is shown, sized and composed by the window manager, and
// the screen does not show it.
window_veil :: proc(w:^Window,veiled:bool) {
    hwnd:=win32.HWND(sdl.GetPointerProperty(sdl.GetWindowProperties(w.handle),sdl.PROP_WINDOW_WIN32_HWND_POINTER,nil))
    if hwnd==nil {return}
    cloak:=win32.BOOL(veiled)
    _=win32.DwmSetWindowAttribute(hwnd,u32(win32.DWMWINDOWATTRIBUTE.DWMWA_CLOAK),&cloak,size_of(cloak))
}
