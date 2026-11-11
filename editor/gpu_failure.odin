package editor

import "core:fmt"
import "core:log"
import "mirai:host"
import "mirai:platform"

// What the editor does once its GPU stopped working (host.app_gpu_failure):
// it starts again with its documents as they are (restart), so a reset of
// the GPU costs a moment and none of the work. An editor that a failure
// started (--gpu-lost) and whose GPU fails again within GPU_FAILURE_AGAIN_NS
// of being ready would loop on the same work: it keeps every tab and the
// unsaved assets for the recovery of the next start and ends with
// EDITOR_GPU_LOST, naming where the GPU stopped.

GPU_FAILURE_AGAIN_NS :: u64(60_000_000_000)

Gpu_Failure_Reaction :: enum u8 {None, Restarted, Ended}

@(private)
gpu_failure_react :: proc(s:^Session) {
    if s.gpu_failure!=.None || s.quit {return}
    failure,text:=host.app_gpu_failure(s.app)
    if failure==.None {return}
    again:=s.gpu_lost_before!="" && platform.clock_ns()-s.ready_ns<GPU_FAILURE_AGAIN_NS
    if !again {
        notify(s,"The GPU stopped working: the editor starts again with the documents as they are")
        if restart(s,{"--gpu-lost",text}) {s.gpu_failure=.Restarted;return}
    }
    s.gpu_failure=.Ended
    // The next start offers the recovery of every tab and of the unsaved assets.
    recovery_tabs_keep(s)
    ended:=fmt.tprintf("the editor ends: %s",text)
    if again {ended=fmt.tprintf("the editor ends: the GPU stopped working again %d s after the editor started again for it, so the same work stops it: %s",(platform.clock_ns()-s.ready_ns)/1_000_000_000,text)}
    log.error(ended)
    fmt.eprintfln("mirai: %s. The next start offers to recover the tabs and the unsaved assets",ended)
    s.quit=true
}

// What a failure of the GPU left of the editor before this one, which it started.
@(private)
gpu_failure_notify :: proc(s:^Session) {
    if s.gpu_lost_before=="" {return}
    log.warnf("the editor started again because the GPU of the one before stopped working: %s",s.gpu_lost_before)
    notify(s,"The editor started again because the GPU stopped working")
}
