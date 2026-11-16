#+build linux
package base

import si "core:sys/info"

// MemTotal and MemAvailable of /proc/meminfo: what is free and what the page
// cache gives back.
@(private)
_memory_stats :: proc "contextless" () -> (total,available:i64,ok:bool) {
    total,available,_,_,ok=si.ram_stats()
    return
}
