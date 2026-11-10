#+build !windows
package main

import "core:os"
import "core:time"
import "mirai:std/subprocess"

// Ends a process and waits for it to be gone.
process_kill_pid :: proc(pid:int) -> bool {
    process,error:=os.process_open(pid)
    if error!=nil || os.process_kill(process)!=nil {return false}
    for _ in 0..<20 {
        if !subprocess.process_alive(pid) {return true}
        time.sleep(250*time.Millisecond)
    }
    return false
}
