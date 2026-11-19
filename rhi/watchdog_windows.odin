#+build windows
package rhi

import "base:intrinsics"
import win "core:sys/windows"

// The path of the record, wide and ended by a zero, made when the device is:
// writing it allocates nothing.
@(private)
Watchdog_Path :: struct {
	units: [WATCHDOG_RECORD_PATH]u16,
	set:   bool,
}

@(private)
watchdog_path_set :: proc(path: ^Watchdog_Path, text: string) -> bool {
	count := win.MultiByteToWideChar(win.CP_UTF8, 0, raw_data(text), i32(len(text)), nil, 0)
	if count <= 0 || int(count) >= len(path.units) {return false}
	win.MultiByteToWideChar(win.CP_UTF8, 0, raw_data(text), i32(len(text)), raw_data(path.units[:]), count)
	path.units[count] = 0
	path.set = true
	return true
}

// Replaces the record with data, written through to the disk.
@(private)
watchdog_record_write :: proc "contextless" (path: ^Watchdog_Path, data: []u8) {
	if !path.set {return}
	file := win.CreateFileW(cstring16(raw_data(path.units[:])), win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL | win.FILE_FLAG_WRITE_THROUGH, nil)
	if file == win.INVALID_HANDLE_VALUE {return}
	written: win.DWORD
	win.WriteFile(file, raw_data(data), win.DWORD(len(data)), &written, nil)
	win.FlushFileBuffers(file)
	win.CloseHandle(file)
}

@(private)
watchdog_record_remove :: proc "contextless" (path: ^Watchdog_Path) {
	if path.set {win.DeleteFileW(cstring16(raw_data(path.units[:])))}
}

// Ends the process now: ExitProcess would first run the detach of every DLL,
// the GPU driver's among them, which may wait for the GPU that is stuck.
@(private)
watchdog_exit :: proc "contextless" (code: int) -> ! {
	win.TerminateProcess(win.GetCurrentProcess(), win.UINT(code))
	intrinsics.trap()
}
