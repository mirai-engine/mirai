#+build linux, darwin
package rhi

import "core:sys/posix"

// Ends the process now: exit would first run the handlers and destructors of
// the libraries, the GPU driver's among them, which may wait for the GPU that is stuck.
@(private)
watchdog_exit :: proc "contextless" (code: int) -> ! {
	posix._exit(i32(code))
}
