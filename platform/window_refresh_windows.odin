#+build windows
package platform

import win32 "core:sys/windows"
import sdl "vendor:sdl3"

// When the GPU scales the desktop to another signal, SDL can report a rate
// the display does not run at (100 Hz for a 1440p desktop on a 4K 60 Hz
// signal); Windows says the rate of the mode the desktop runs at.
@(private)
window_native_refresh_hz :: proc(p:^Platform,sdl_hz:f32) -> f32 {
    hwnd:=win32.HWND(sdl.GetPointerProperty(sdl.GetWindowProperties(p.window.handle),sdl.PROP_WINDOW_WIN32_HWND_POINTER,nil))
    if hwnd==nil {return sdl_hz}
    monitor:=win32.MonitorFromWindow(hwnd,.MONITOR_DEFAULTTONEAREST)
    info:=win32.MONITORINFOEXW{}
    info.cbSize=size_of(info)
    if monitor==nil || !win32.GetMonitorInfoW(monitor,cast(win32.LPMONITORINFO)&info) {return sdl_hz}
    mode:=win32.DEVMODEW{dmSize=size_of(win32.DEVMODEW)}
    if !win32.EnumDisplaySettingsW(cstring16(&info.szDevice[0]),win32.ENUM_CURRENT_SETTINGS,&mode) {return sdl_hz}
    // 0 and 1 stand for the default rate of the hardware. The rate is whole
    // (59 for 59.94 Hz): SDL's keeps the fraction when it is the same mode.
    hz:=f32(mode.dmDisplayFrequency)
    if mode.dmDisplayFrequency<=1 || abs(hz-sdl_hz)<1 {return sdl_hz}
    return hz
}
