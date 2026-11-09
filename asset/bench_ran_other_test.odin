#+build !windows
package asset

import "core:sys/posix"

@(private)
bench_thread_ran :: proc() -> (thread,all:u64) {
    ran,passed:posix.timespec
    posix.clock_gettime(.THREAD_CPUTIME_ID,&ran)
    posix.clock_gettime(.MONOTONIC,&passed)
    return u64(ran.tv_sec)*1e9+u64(ran.tv_nsec),u64(passed.tv_sec)*1e9+u64(passed.tv_nsec)
}
