#+build windows
package asset

import "base:intrinsics"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign kernel32 {
    QueryThreadCycleTime :: proc(thread:win.HANDLE,cycles:^u64) -> win.BOOL ---
}

// What the calling thread has run and what has passed, in one unit: how much they grow between
// two readings says how much of that time the thread had a processor.
@(private)
bench_thread_ran :: proc() -> (thread,all:u64) {
    QueryThreadCycleTime(win.GetCurrentThread(),&thread)
    return thread,u64(intrinsics.read_cycle_counter())
}
