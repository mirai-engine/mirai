package host

import "base:runtime"
import "core:time"
import render "mirai:render"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:std/jobs"

// A recording of frames for whoever measures the application (the profile.*
// methods of the editor), in three tracks that share the frames:
//
// - Cpu: on the main thread a zone for the frame and one for each of its
//   parts; one for each function of the loops, which the world opens with
//   profile_step_begin on the ring of the worker that runs it; on the ring of
//   each worker of the job system its jobs; per frame the waits and the parts
//   of the renderer and what the display was given. The frames are delimited
//   by its zones, so it always records.
// - Gpu: the GPU passes of what each frame submitted (profile_gpu.odin).
// - Memory: what the process, the GPU and the pools of the renderer hold at
//   the end of each frame (profile_memory.odin).
//
// Rings are drained at the end of every frame, so a ring only has to hold one
// frame. While nothing records a zone costs a branch and the GPU reports only
// its whole frame. The first profile_start reserves the memory; a recording
// allocates nothing. Whoever reads the zones as they happen (a profiler
// plugin) asks for them and the GPU passes every frame with profile_request
// and reads the rings with profile_read.

PROFILE_RING :: 1<<13          // zones one thread can finish within a frame
PROFILE_ZONES :: 1<<18         // zones of a whole recording
PROFILE_FRAMES_MAX :: 3600
PROFILE_MAIN :: jobs.OWNER     // the ring of the main thread, worker 0 of the job system

Profile_Track :: enum u8 {Cpu,Gpu,Memory}
Profile_Tracks :: bit_set[Profile_Track;u8]
PROFILE_TRACKS_ALL :: Profile_Tracks{.Cpu,.Gpu,.Memory}

// A frame of the Cpu track, and what every track shares of it.
Profile_Frame :: struct {
    number:u32,       // the frame of base.Profile that the zones of this frame carry
    drawn:bool,
    render_prepare_ms:f32, // of the renderer, when it drew
    render_wait_ms:f32,    // the wait for a frame slot of the GPU (and for the display with vsync)
    render_record_ms:f32,
    render_end_ms:f32,
    render_width,render_height:u32,
    generated:bool,        // it drew an image shown before its own (frame generation)
    presented:u32,         // images given to the display since the frame before
    intervals:u32,         // between them, with their sum and the sum of their squares, in ms
    interval_total_ms,interval_square:f64,
    latency_ms:f32,        // from the start of the last frame shown to its image going to the display
}

Profiler :: struct {
    profile:base.Profile,
    rings_ready:bool, // the base.Profile rings, which profile_request needs without the recording buffers
    reserved:bool,    // the recording buffers below
    recording:bool,
    tracks:Profile_Tracks, // of the recording
    requested:u8,     // frames profile_request keeps the zones and the GPU passes on
    wanted:int,                // frames the recording ends after
    frames:[]Profile_Frame,
    frame_count:int,
    zones:[]base.Profile_Zone, // in nanoseconds since the Profile was made
    zone_count:int,
    lost:u64,                  // zones overwritten in a ring or that did not fit in zones
    cursors:[]u64,             // per ring: the next zone to drain
    frame_zone:base.Profile_Scope,
    presented:rhi.Present_Stats, // as the frame before left them
    late:int,          // frames run past the last one recorded, waiting for its GPU times
    gpu:Profile_Gpu,
    memory:[]Profile_Memory_Frame, // with the frames, index by index
}

Profile_Cpu_Recording :: struct {
    zones:[]base.Profile_Zone,
    threads:int,
    lost:u64,
}

// What a recording left, until the next profile_start. The frames of a track
// it did not record are empty; those of the others go with frames, index by
// index. Zones of the main thread end in the order of the frame, inner zones
// before the one around them.
Profile_Recording :: struct {
    tracks:Profile_Tracks,
    frames:[]Profile_Frame,
    cpu:Profile_Cpu_Recording,
    gpu:Profile_Gpu_Recording,
    memory:[]Profile_Memory_Frame,
    complete:bool, // it reached the frames asked for
}

// Starts recording the next frames, at most PROFILE_FRAMES_MAX, in tracks and
// the Cpu one. False while another recording runs, or when the memory cannot
// be reserved.
profile_start :: proc(app:^App,frames:int,tracks:=PROFILE_TRACKS_ALL) -> bool {
    p:=&app.profiler
    if p.recording || frames<=0 {return false}
    if !p.reserved && !profile_reserve(app) {return false}
    p.wanted=min(frames,PROFILE_FRAMES_MAX)
    p.tracks=tracks+{.Cpu}
    p.frame_count,p.zone_count,p.lost,p.late=0,0,0,0
    p.frame_zone={}
    if app.device!=nil {p.presented=rhi.present_stats(app.device)}
    profile_gpu_start(app)
    out:[0]base.Profile_Zone
    for &cursor,thread in p.cursors {_,cursor,_=base.profile_read_since(&p.profile,thread,0,out[:])}
    p.recording=true
    base.profile_set_enabled(&p.profile,true)
    return true
}

// Ends a recording before its last frame, or before the GPU times of its
// last frames came back: those keep measured false. Between frames.
profile_stop :: proc(app:^App) {
    p:=&app.profiler
    if !p.recording {return}
    base.profile_set_enabled(&p.profile,false)
    p.recording=false
}

profile_recording :: proc(app:^App) -> Profile_Recording {
    p:=&app.profiler
    r:=Profile_Recording{
        tracks=p.tracks,frames=p.frames[:p.frame_count],
        cpu={zones=p.zones[:p.zone_count],threads=len(p.cursors),lost=p.lost},
        complete=!p.recording && p.wanted>0 && p.frame_count>=p.wanted,
    }
    if .Gpu in p.tracks {r.gpu={frames=p.gpu.frames[:p.frame_count],passes=p.gpu.passes[:p.gpu.pass_count]}}
    if .Memory in p.tracks {r.memory=p.memory[:p.frame_count]}
    return r
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

// Whether the zones are being recorded.
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
    profile_gpu_frame_open(app)
    p.frame_zone=base.profile_begin(&p.profile,PROFILE_MAIN,"frame")
}

@(private)
profile_frame_close :: proc(app:^App) {
    p:=&app.profiler
    base.profile_end(p.frame_zone)
    p.frame_zone={}
}

// Closes the frame, keeps what each track measured of it, takes the GPU
// times that came back and drains the rings.
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
        frame^={number=p.profile.frame,drawn=drawn}
        if app.device!=nil {
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
        if .Gpu in p.tracks {profile_gpu_frame_end(app,p.frame_count)}
        if .Memory in p.tracks {profile_memory_sample(app,&p.memory[p.frame_count])}
        p.frame_count+=1
        recorded=true
    } else if p.frame_count>=p.wanted {
        p.late+=1
    }
    if .Gpu in p.tracks {profile_gpu_take(app)}
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
    if p.frame_count>=p.wanted && (.Gpu not_in p.tracks || profile_gpu_done(p) || p.late>=PROFILE_GPU_LATE) {profile_stop(app)}
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
    if error==nil {p.memory,error=make([]Profile_Memory_Frame,PROFILE_FRAMES_MAX,app.allocator)}
    if error==nil {error=profile_gpu_reserve(&p.gpu,app.allocator)}
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
    delete(p.memory,app.allocator)
    profile_gpu_release(&p.gpu,app.allocator)
    if p.rings_ready {base.profile_destroy(&p.profile)}
    p^={}
}
