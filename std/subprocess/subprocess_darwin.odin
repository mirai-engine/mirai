#+build darwin
#+private
package subprocess

import "core:os"

// macOS enforces no limit on the memory of another process.
memory_limit :: proc(pid:int,memory:u64) {}

// The process of core:os holds no handle on macOS.
process_close :: proc(process:os.Process) {}
