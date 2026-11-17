#+build windows
package rhi

import "base:intrinsics"
import win "core:sys/windows"

// Ends the process now: ExitProcess would first run the detach of every DLL,
// the GPU driver's among them, which may wait for the GPU that is stuck.
@(private)
watchdog_exit :: proc "contextless" (code: int) -> ! {
	win.TerminateProcess(win.GetCurrentProcess(), win.UINT(code))
	intrinsics.trap()
}
