package host

import "base:runtime"
import "core:time"
import render "mirai:render"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:std/jobs"

// A recording of frames for whoever measures the application (the profile.*
// methods of the editor): on the main thread a zone for the frame and one for
// each of its parts; one for each function of the loops, which the world
// opens with profile_step_begin on the ring of the worker that runs it; on
// the ring of each worker of the job system its jobs; and per frame what the
// zones do not carry, the times of the
// renderer and of the GPU. Rings are drained at the end of every frame, so a
// ring only has to hold one frame. The GPU times of a frame come back
// rhi.MAX_FRAMES_IN_FLIGHT frames later, tagged with the rhi frame they
// measured: they go to the frame that submitted it, and a recording runs up
// to PROFILE_GPU_LATE frames past its last one to receive them. While nothing
// records a zone costs a branch and the GPU reports only its whole frame. The first profile_start
// reserves the memory; a recording allocates nothing. Whoever reads the zones
// as they happen (a profiler plugin) asks for them every frame with
// profile_request and reads the rings with profile_read.

PROFILE_RING :: 1<<13          // zones one thread can finish within a frame
PROFILE_ZONES :: 1<<18         // zones of a whole recording
PROFILE_FRAMES_MAX :: 3600
PROFILE_PASSES :: 1<<17        // GPU pass times of a whole recording
PROFILE_PASS_NAMES :: 128      // the last one names every pass that did not fit
PROFILE_PASS_NAME_BYTES :: 32
PROFILE_MAIN :: jobs.OWNER     // the ring of the main thread, worker 0 of the job system
PROFILE_GPU_LATE :: rhi.MAX_FRAMES_IN_FLIGHT+1 // frames a recording runs past its last one for the GPU times of its frames

Profile_Frame :: struct {
    number:u32,       // the frame of base.Profile that the zones of this frame carry
    drawn:bool,
    render_prepare_ms:f32, // of the renderer, when it drew
    render_wait_ms:f32,    // the wait for a frame slot of the GPU (and for the display with vsync)
    render_record_ms:f32,
    render_end_ms:f32,
    gpu:bool,              // the GPU times of what it submitted came back: gpu_ms and its passes are its own
    gpu_ms:f32,            // of what it submitted, the sum of its passes
    device_first,device_end:u64, // the rhi.frame_number of the frames it submitted: [first, end)
    render_width,render_height:u32,
    generated:bool,        // it drew an image shown before its own (frame generation)
    presented:u32,         // images given to the display since the frame before
    intervals:u32,         // between them, with their sum and the sum of their squares, in ms
    interval_total_ms,interval_square:f64,
    latency_ms:f32,        // from the start of the last frame shown to its image going to the display
    pass_first,pass_count:int,
}

Profile_Pass :: struct {
    name:int,           // into the names of the pass of the Profiler
    start_ns,end_ns:i64, // on the clock of the zones: nanoseconds since the Profile was made
}

Profiler :: struct {
    profile:base.Profile,
    rings_ready:bool, // the base.Profile rings, which profile_request needs without the recording buffers
    reserved:bool,    // the recording buffers below
    recording:bool,
    requested:u8,     // frames profile_request keeps the zones and the GPU passes on
    wanted:int,                // frames the recording ends after
    frames:[]Profile_Frame,
    frame_count:int,
    zones:[]base.Profile_Zone, // in nanoseconds since the Profile was made
    zone_count:int,
    lost:u64,                  // zones overwritten in a ring or that did not fit in zones
    cursors:[]u64,             // per ring: the next zone to drain
    passes:[]Profile_Pass,
    pass_count:int,
    pass_names:[][PROFILE_PASS_NAME_BYTES]u8, // the GPU reuses the memory of its names every frame
    pass_name_lengths:[]u8,
    pass_name_count:int,
    frame_zone:base.Profile_Scope,
    presented:rhi.Present_Stats, // as the frame before left them
    device_open:u64,   // rhi.frame_number when the frame opened
    timings_taken:u64, // 1 + the rhi frame whose GPU times were taken last; 0: none
    late:int,          // frames run past the last one recorded, waiting for its GPU times
}

// What a recording left, until the next profile_start. Zones of the main
// thread end in the order of the frame, inner zones before the one around them.
Profile_Recording :: struct {
    frames:[]Profile_Frame,
    zones:[]base.Profile_Zone,
    passes:[]Profile_Pass,
    threads:int,
    lost:u64,
    complete:bool, // it reached the frames asked for
}

// Starts recording the next frames, at most PROFILE_FRAMES_MAX. False while
// another recording runs, or when the memory cannot be reserved.
profile_start :: proc(app:^App,frames:int) -> bool {
    p:=&app.profiler
    if p.recording || frames<=0 {return false}
    if !p.reserved && !profile_reserve(app) {return false}
    p.wanted=min(frames,PROFILE_FRAMES_MAX)
    p.frame_count,p.zone_count,p.pass_count,p.lost=0,0,0,0
    p.frame_zone={}
    p.timings_taken,p.late=0,0
    if app.device!=nil {p.presented=rhi.present_stats(app.device);p.device_open=rhi.frame_number(app.device)}
    out:[0]base.Profile_Zone
    for &cursor,thread in p.cursors {_,cursor,_=base.profile_read_since(&p.profile,thread,0,out[:])}
    p.recording=true
    base.profile_set_enabled(&p.profile,true)
    return true
}

// Ends a recording before its last frame, or before the GPU times of its
// last frames came back: those keep gpu false. Between frames.
profile_stop :: proc(app:^App) {
    p:=&app.profiler
    if !p.recording {return}
    base.profile_set_enabled(&p.profile,false)
    p.recording=false
}

profile_recording :: proc(app:^App) -> Profile_Recording {
    p:=&app.profiler
    return {
        frames=p.frames[:p.frame_count],zones=p.zones[:p.zone_count],passes=p.passes[:p.pass_count],
        threads=len(p.cursors),lost=p.lost,complete=!p.recording && p.wanted>0 && p.frame_count>=p.wanted,
    }
}

// Keeps the zones of the threads and the GPU timings of the passes recorded
// through the next frame: call it every frame while reading them. The first
// call reserves the rings; false without memory.
profile_request :: proc(app:^App) -> bool {
    p:=&app.profiler
    if !profile_reserve_rings(app) {return false}
    p.requested=2
    return true
}

// Whether the zones and the GPU passes are being recorded.
profile_active :: proc "contextless" (app:^App) -> bool {
    p:=&app.profiler
    return p.rings_ready && (p.recording || p.requested>0)
}

// The rings: one per thread, the main one first.
profile_threads :: proc(app:^App) -> int {return len(app.profiler.profile.threads)}

// The zones a thread finished since the cursor since, oldest first, with
// their times in nanoseconds since profile_epoch_ns; as base.profile_read_since.
// The editor recording reads the same rings with cursors of its own.
profile_read :: proc(app:^App,thread:int,since:u64,out:[]base.Profile_Zone) -> (count:int,next:u64,lost:u64) {
    p:=&app.profiler
    if !p.rings_ready {return 0,since,0}
    return base.profile_read_since(&p.profile,thread,since,out)
}

// The time of time.tick_now, in nanoseconds, the times of the zones count from.
profile_epoch_ns :: proc(app:^App) -> i64 {
    return time.duration_nanoseconds(time.tick_diff({},app.profiler.profile.epoch_tick))
}

profile_pass_name :: proc(app:^App,index:int) -> string {
    p:=&app.profiler
    if index<0 || index>=p.pass_name_count {return ""}
    return string(p.pass_names[index][:p.pass_name_lengths[index]])
}

// The zone of a function of the loops, by its index in info.steps, on the
// ring of the worker that runs it: the world opens one around each call.
profile_step_begin :: #force_inline proc "contextless" (app:^App,index,worker:int) -> base.Profile_Scope {
    if !profile_active(app) {return {}}
    return profile_step_open(app,index,worker)
}
profile_step_end :: #force_inline proc "contextless" (zone:base.Profile_Scope) {
    base.profile_end(zone)
}
profile_step_open :: proc "contextless" (app:^App,index,worker:int) -> base.Profile_Scope {
    if app.info==nil || index<0 || index>=len(app.info.steps) {return {}}
    return base.profile_begin(&app.profiler.profile,worker,app.info.steps[index].name)
}

// A zone of the main thread named by a literal, for a part of the frame.
@(private)
profile_part :: #force_inline proc "contextless" (app:^App,name:string) -> base.Profile_Scope {
    if !profile_active(app) {return {}}
    return base.profile_begin(&app.profiler.profile,PROFILE_MAIN,name)
}

@(private)
profile_frame_open :: proc(app:^App) {
    p:=&app.profiler
    active:=profile_active(app)
    if p.rings_ready {base.profile_set_enabled(&p.profile,active)}
    if !active {return}
    base.profile_frame(&p.profile)
    if app.device!=nil {p.device_open=rhi.frame_number(app.device)}
    p.frame_zone=base.profile_begin(&p.profile,PROFILE_MAIN,"frame")
}

@(private)
profile_frame_close :: proc(app:^App) {
    p:=&app.profiler
    base.profile_end(p.frame_zone)
    p.frame_zone={}
}

// Whether the frame about to be drawn records the GPU time of each pass.
@(private)
profile_gpu_want :: proc(app:^App) {
    if app.device!=nil {rhi.timestamps_want(app.device,profile_active(app))}
}

// Closes the frame, keeps what the renderer measured, takes the GPU times that
// came back and drains the rings.
@(private)
profile_frame_end :: proc(app:^App,drawn:bool) {
    load_profile_frame(app,drawn)
    p:=&app.profiler
    opened:=p.frame_zone.profile!=nil
    if opened {profile_frame_close(app)}
    if p.requested>0 {p.requested-=1}
    if !p.recording {return}
    recorded:=false
    if opened && p.frame_count<p.wanted && p.frame_count<len(p.frames) {
        frame:=&p.frames[p.frame_count]
        frame^={number=p.profile.frame,drawn=drawn,pass_first=p.pass_count,device_first=p.device_open,device_end=p.device_open}
        if app.device!=nil {
            frame.device_end=rhi.frame_number(app.device)
            shown:=rhi.present_stats(app.device)
            frame.presented,frame.intervals=u32(shown.presented-p.presented.presented),u32(shown.intervals-p.presented.intervals)
            frame.interval_total_ms=shown.interval_total_ms-p.presented.interval_total_ms
            frame.interval_square=shown.interval_square-p.presented.interval_square
            frame.latency_ms=shown.latency_ms
            p.presented=shown
        }
        if r:=app.renderer;r!=nil {
            stats:=render.renderer_stats(r)
            frame.generated=stats.generated
            frame.render_width,frame.render_height=stats.render_width,stats.render_height
            if drawn {
                frame.render_prepare_ms,frame.render_wait_ms=stats.cpu_prepare_ms,stats.cpu_begin_ms
                frame.render_record_ms,frame.render_end_ms=stats.cpu_record_ms,stats.cpu_end_ms
            }
        }
        p.frame_count+=1
        recorded=true
    } else if p.frame_count>=p.wanted {
        p.late+=1
    }
    profile_gpu_take(app)
    for &cursor,thread in p.cursors {
        if !recorded {
            // A frame run for the GPU times of the last ones keeps none of its zones.
            out:[0]base.Profile_Zone
            _,cursor,_=base.profile_read_since(&p.profile,thread,cursor,out[:])
            continue
        }
        count,next,lost:=base.profile_read_since(&p.profile,thread,cursor,p.zones[p.zone_count:])
        p.zone_count+=count
        p.lost+=lost
        cursor=next
    }
    if p.frame_count>=p.wanted && (profile_gpu_done(p) || p.late>=PROFILE_GPU_LATE) {profile_stop(app)}
}

// The GPU times the renderer collected last.
@(private)
profile_gpu_take :: proc(app:^App) {
    if r:=app.renderer;r!=nil {
        stats:=render.renderer_stats(r)
        profile_gpu_add(&app.profiler,stats.timings,stats.timings_frame,profile_epoch_ns(app))
    }
}

// Gives the GPU times of the rhi frame measured, once, to the recorded frame
// that submitted it; those of a frame not recorded go. epoch: the time of
// time.tick_now in nanoseconds the zones count from.
@(private)
profile_gpu_add :: proc(p:^Profiler,timings:[]rhi.Gpu_Timing,measured:u64,epoch:i64) {
    if len(timings)==0 || measured+1<=p.timings_taken {return}
    p.timings_taken=measured+1
    for i:=p.frame_count-1;i>=0;i-=1 {
        frame:=&p.frames[i]
        if measured>=frame.device_end {break}
        if measured<frame.device_first {continue}
        // Times come back in order: the passes of the frame stay together after those of the frames before.
        if !frame.gpu {frame.gpu,frame.pass_first,frame.pass_count=true,p.pass_count,0}
        for timing in timings {
            frame.gpu_ms+=timing.ms
            if p.pass_count>=len(p.passes) {continue}
            p.passes[p.pass_count]={profile_pass_intern(p,timing.name),timing.start_ns-epoch,timing.end_ns-epoch}
            p.pass_count+=1
            frame.pass_count+=1
        }
        break
    }
}

// Whether the GPU times of the last recorded frame came back.
@(private)
profile_gpu_done :: proc(p:^Profiler) -> bool {
    if p.frame_count==0 {return true}
    last:=p.frames[p.frame_count-1]
    return last.device_end==last.device_first || p.timings_taken>=last.device_end
}

@(private)
profile_pass_intern :: proc(p:^Profiler,name:string) -> int {
    for i in 0..<p.pass_name_count {
        if string(p.pass_names[i][:p.pass_name_lengths[i]])==name {return i}
    }
    if len(p.pass_names)<PROFILE_PASS_NAMES {return 0}
    if p.pass_name_count==PROFILE_PASS_NAMES-1 {
        other:=PROFILE_PASS_NAMES-1
        p.pass_name_lengths[other]=u8(copy(p.pass_names[other][:],"other"))
        return other
    }
    if p.pass_name_count>=PROFILE_PASS_NAMES {return PROFILE_PASS_NAMES-1}
    index:=p.pass_name_count
    p.pass_name_lengths[index]=u8(copy(p.pass_names[index][:],name))
    p.pass_name_count+=1
    return index
}

// The rings are all profile_request needs: the recording buffers below
// (about 13 MB) are only for an editor recording. Idempotent.
@(private)
profile_reserve_rings :: proc(app:^App) -> bool {
    p:=&app.profiler
    if p.rings_ready {return true}
    threads:=max(jobs.worker_count(&app.jobs),1)
    if !base.profile_init(&p.profile,{threads=threads,zones_per_thread=PROFILE_RING,allocator=app.allocator}) {return false}
    base.profile_set_enabled(&p.profile,false)
    p.rings_ready=true
    if jobs.worker_count(&app.jobs)>0 {jobs.system_profile_set(&app.jobs,&p.profile)}
    return true
}

@(private)
profile_reserve :: proc(app:^App) -> bool {
    p:=&app.profiler
    if !profile_reserve_rings(app) {return false}
    threads:=max(jobs.worker_count(&app.jobs),1)
    error:runtime.Allocator_Error
    p.frames,error=make([]Profile_Frame,PROFILE_FRAMES_MAX,app.allocator)
    if error==nil {p.zones,error=make([]base.Profile_Zone,PROFILE_ZONES,app.allocator)}
    if error==nil {p.cursors,error=make([]u64,threads,app.allocator)}
    if error==nil {p.passes,error=make([]Profile_Pass,PROFILE_PASSES,app.allocator)}
    if error==nil {p.pass_names,error=make([][PROFILE_PASS_NAME_BYTES]u8,PROFILE_PASS_NAMES,app.allocator)}
    if error==nil {p.pass_name_lengths,error=make([]u8,PROFILE_PASS_NAMES,app.allocator)}
    if error!=nil {
        profile_release(app)
        return false
    }
    p.reserved=true
    return true
}

// After the job system stopped: no worker records any more.
@(private)
profile_release :: proc(app:^App) {
    p:=&app.profiler
    delete(p.frames,app.allocator)
    delete(p.zones,app.allocator)
    delete(p.cursors,app.allocator)
    delete(p.passes,app.allocator)
    delete(p.pass_names,app.allocator)
    delete(p.pass_name_lengths,app.allocator)
    if p.rings_ready {base.profile_destroy(&p.profile)}
    p^={}
}
