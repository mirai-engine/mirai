#+build windows
package platform

import win "core:sys/windows"

process_memory :: proc() -> (m:Process_Memory) {
    counters:win.PROCESS_MEMORY_COUNTERS
    counters.cb=size_of(counters)
    if !win.GetProcessMemoryInfo(win.GetCurrentProcess(),&counters,size_of(counters)) {return}
    return {u64(counters.WorkingSetSize),u64(counters.PagefileUsage)}
}
