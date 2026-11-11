#+build linux, darwin
package platform

import "core:c"

@(private="file")
Rusage :: struct {
    user_time,system_time:[2]i64,
    max_rss:c.long, // kilobytes on Linux and bytes on macOS
    rest:[13]c.long,
}

foreign import libc "system:c"
@(default_calling_convention="c",private="file")
foreign libc {
    getrusage :: proc(who:c.int,usage:^Rusage) -> c.int ---
}

// The bytes of memory the process holds: the most it has held; 0 when the system does not say.
process_memory_bytes :: proc "contextless" () -> u64 {
    usage:Rusage
    if getrusage(0,&usage)!=0 {return 0}
    when ODIN_OS==.Linux {return u64(usage.max_rss)*1024} else {return u64(usage.max_rss)}
}
