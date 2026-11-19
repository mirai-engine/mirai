package editor

import "core:fmt"
import "core:os"
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
    pressed:bool,       // the device held close to what the driver let it (workspace.gpu_pressed)
    turn:int,           // the number of the turn that names this editor its holder; -1 before it is found
    said:Gpu_Said,      // what the turn says of this editor, as it last wrote it
}

// Whether the turn says this editor puts work on the GPU or stays open and
// idle (workspace.gpu_turn_mark); Unsaid before it writes either.
Gpu_Said :: enum u8 {Unsaid,Work,Open}

GPU_WATCH_INTERVAL :: time.Second

// Takes the turn this editor was started with, which goes to no process it
// starts but the editor it starts again as (gpu_turn_pass).
@(private)
gpu_turn_take :: proc(s:^Session,handle:uintptr) {
    s.gpu.turn,s.gpu.said=-1,.Unsaid
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

// The editor that started in place of this one with its turn (gpu_turn_pass)
// is named its holder, which mirai locks shows.
@(private)
gpu_turn_handed :: proc(s:^Session,pid:int) {
    if s.gpu.handle!=0 {workspace.gpu_turn_follow(s.engine_root,os.get_pid(),pid)}
}

// Says on the turn whether this editor puts work on the GPU now, which a
// measurement waits for before it times, or stays open and idle, which it
// does not (workspace.gpu_work). A window draws by itself, but a person or
// an agent keeps it open for long: it is open. A manual editor is open while
// it waits for calls and works while a call draws (api_measured_wait).
@(private)
gpu_turn_use :: proc(s:^Session,open:bool) {
    said:=Gpu_Said.Open if open else .Work
    if s.gpu.handle==0 || s.gpu.said==said || s.engine_root=="" {return}
    s.gpu.turn=workspace.gpu_turn_mark(s.engine_root,os.get_pid(),open,s.gpu.turn)
    if s.gpu.turn>=0 {s.gpu.said=said}
}

// Before a call that draws in a manual editor: waits while a measurement that
// neither this editor nor its caller (part_of, its MEASURE_ENV) is part of
// runs, at most limit (zero: no limit), with the turn open meanwhile, and
// then says it works. ok is false, with who measures, when the limit passed
// or the caller cancelled the call first.
@(private)
gpu_work_begin :: proc(s:^Session,part_of:string,limit:time.Duration) -> (ok:bool,holder:string) {
    if s.engine_root=="" {return true,""}
    start:=time.tick_now()
    for {
        gpu_turn_use(s,false)
        what:workspace.Measured
        what,holder=workspace.measured(s.engine_root,true,part_of,context.temp_allocator)
        if what!=.Wait {return true,""}
        gpu_turn_use(s,true)
        fmt.eprintfln("mirai: a call that draws waits for a measurement to finish (%s)",holder)
        left:=time.Duration(0)
        if limit>0 {
            left=limit-time.tick_since(start)
            if left<=0 {return false,holder}
        }
        if !workspace.measurement_wait(s.engine_root,part_of,limit=left,stop=proc(user:rawptr) -> bool {return api_stop_asked((^Session)(user))},user=s) {return false,holder}
    }
}

// Keeps the memory of the card and a peak of the session above the one kept
// at once, so that one that ends badly still leaves it, and raises the charge
// of its turn to what it held.
@(private)
gpu_watch :: proc(s:^Session) {
    if st:=api_state(s);st==nil || !st.manual {gpu_turn_use(s,true)}
    device:=s.app.device
    if device==nil || !s.has_project {return}
    if s.gpu.checked!={} && time.tick_since(s.gpu.checked)<GPU_WATCH_INTERVAL {return}
    if s.gpu.checked=={} {
        info:=rhi.device_info(device)
        if refused:=workspace.gpu_card_write(s.engine_root,{i64(info.memory),info.type==.Discrete,info.name});refused!="" {fmt.eprintfln("mirai: %s",refused)}
        s.gpu.kept,_=workspace.gpu_peak(s.engine_root,s.project_root)
    }
    s.gpu.checked=time.tick_now()
    used,budget:=rhi.device_memory(device)
    s.gpu.peak=max(s.gpu.peak,i64(used))
    s.gpu.pressed||=workspace.gpu_pressed(i64(used),i64(budget))
    if s.gpu.handle!=0 {s.gpu.turn=workspace.gpu_turn_raise(s.engine_root,os.get_pid(),s.gpu.peak,s.gpu.turn)}
    if s.gpu.peak>s.gpu.kept {
        workspace.gpu_peak_write(s.engine_root,s.project_root,s.gpu.peak)
        s.gpu.kept=s.gpu.peak
    }
}

// The peak of the session that ends is the one the next is charged, also
// when lower than the one kept unless the card pressed it (gpu_peak_end).
@(private)
gpu_watch_end :: proc(s:^Session) {
    if s.has_project {workspace.gpu_peak_end(s.engine_root,s.project_root,s.gpu.peak,s.gpu.pressed)}
}
