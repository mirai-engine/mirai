#+build linux, darwin
package rhi

import "core:sys/posix"

// The path of the record, ended by a zero, made when the device is: writing
// it allocates nothing.
@(private)
Watchdog_Path :: struct {
	bytes: [WATCHDOG_RECORD_PATH]u8,
	set:   bool,
}

@(private)
watchdog_path_set :: proc(path: ^Watchdog_Path, text: string) -> bool {
	if len(text) == 0 || len(text) >= len(path.bytes) {return false}
	copy(path.bytes[:], text)
	path.bytes[len(text)] = 0
	path.set = true
	return true
}

// Replaces the record with data, flushed to the disk.
@(private)
watchdog_record_write :: proc "contextless" (path: ^Watchdog_Path, data: []u8) {
	if !path.set {return}
	file := posix.open(cstring(raw_data(path.bytes[:])), {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if file < 0 {return}
	posix.write(file, raw_data(data), uint(len(data)))
	posix.fsync(file)
	posix.close(file)
}

@(private)
watchdog_record_remove :: proc "contextless" (path: ^Watchdog_Path) {
	if path.set {posix.unlink(cstring(raw_data(path.bytes[:])))}
}

// Ends the process now: exit would first run the handlers and destructors of
// the libraries, the GPU driver's among them, which may wait for the GPU that is stuck.
@(private)
watchdog_exit :: proc "contextless" (code: int) -> ! {
	posix._exit(i32(code))
}
