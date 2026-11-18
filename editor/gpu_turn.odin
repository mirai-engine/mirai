package editor

import "core:fmt"
import "core:time"
import "mirai:cook/workspace"
import "mirai:rhi"
import "mirai:std/subprocess"

// The turn of the GPU the tool gave this editor (--gpu-turn: the handle that
// holds its lock, workspace.gpu_try) and what the turns of the tool learn
// from its device: the memory of the card and the peak the session of its
// project held, looked at once each GPU_WATCH_INTERVAL.
Gpu_Turn :: struct {
    handle:uintptr,     // 0: it holds none
    checked:time.Tick,  // when the memory of the device was looked at last
    peak:i64,           // the most memory of the device this editor held
    kept:i64,           // the peak in the cache, which only grows while it runs
}

GPU_WATCH_INTERVAL :: time.Second

// Takes the turn this editor was started with, which goes to no process it
// starts but the editor it starts again as (gpu_turn_pass).
@(private)
gpu_turn_take :: proc(s:^Session,handle:uintptr) {
    if handle!=0 && subprocess.handle_keep(handle) {s.gpu.handle=handle}
}

// What the editor that starts in place of this one needs to hold its turn:
// its arguments and the handle it inherits.
@(private)
gpu_turn_pass :: proc(s:^Session,command:^[dynamic]string) -> []uintptr {
    if s.gpu.handle==0 {return nil}
    append(command,"--gpu-turn",fmt.tprintf("%d",s.gpu.handle))
    handles:=make([]uintptr,1,context.temp_allocator)
    handles[0]=s.gpu.handle
    return handles
}

// Keeps the memory of the card and a peak of the session above the one kept
// at once, so that one that ends badly still leaves it.
@(private)
gpu_watch :: proc(s:^Session) {
    device:=s.app.device
    if device==nil || !s.has_project {return}
    if s.gpu.checked!={} && time.tick_since(s.gpu.checked)<GPU_WATCH_INTERVAL {return}
    if s.gpu.checked=={} {
        workspace.gpu_memory_write(s.engine_root,i64(rhi.device_info(device).memory))
        s.gpu.kept,_=workspace.gpu_peak(s.engine_root,s.project_root)
    }
    s.gpu.checked=time.tick_now()
    used,_:=rhi.device_memory(device)
    s.gpu.peak=max(s.gpu.peak,i64(used))
    if s.gpu.peak>s.gpu.kept {
        workspace.gpu_peak_write(s.engine_root,s.project_root,s.gpu.peak)
        s.gpu.kept=s.gpu.peak
    }
}

// The peak of the session that ends is the one the next is charged, also
// when lower than the one kept.
@(private)
gpu_watch_end :: proc(s:^Session) {
    if s.has_project && s.gpu.peak>0 {workspace.gpu_peak_write(s.engine_root,s.project_root,s.gpu.peak)}
}
