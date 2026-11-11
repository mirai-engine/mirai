#+build windows
package platform

import win32 "core:sys/windows"

@(private="file")
Process_Memory_Counters :: struct {
    cb,page_fault_count:u32,
    peak_working_set,working_set,quota_peak_paged,quota_paged,quota_peak_non_paged,quota_non_paged,pagefile,peak_pagefile:uint,
}

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention="system",private="file")
foreign kernel32 {
    K32GetProcessMemoryInfo :: proc(process:win32.HANDLE,counters:^Process_Memory_Counters,size:u32) -> win32.BOOL ---
}

// The bytes of memory the process holds: its working set; 0 when the system does not say.
process_memory_bytes :: proc "contextless" () -> u64 {
    counters:=Process_Memory_Counters{cb=size_of(Process_Memory_Counters)}
    if !K32GetProcessMemoryInfo(win32.GetCurrentProcess(),&counters,counters.cb) {return 0}
    return u64(counters.working_set)
}
