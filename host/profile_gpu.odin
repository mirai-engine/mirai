package host

import "base:runtime"
import render "mirai:render"
import "mirai:rhi"

// The Gpu track of a recording: the passes of what each frame submitted, each
// with its interval on the clock of the zones. The GPU times of a frame come
// back rhi.MAX_FRAMES_IN_FLIGHT frames later, tagged with the rhi frame they
// measured: they go to the recorded frame that submitted it, and a recording
// runs up to PROFILE_GPU_LATE frames past its last one to receive them.

PROFILE_PASSES :: 1<<17        // GPU pass times of a whole recording
PROFILE_PASS_NAMES :: 128      // the last one names every pass that did not fit
PROFILE_PASS_NAME_BYTES :: 32
PROFILE_GPU_LATE :: rhi.MAX_FRAMES_IN_FLIGHT+1 // frames a recording runs past its last one for the GPU times of its frames

Profile_Gpu_Frame :: struct {
    measured:bool,  // the GPU times of what it submitted came back: ms and its passes are its own
    ms:f32,         // of what it submitted, the sum of its passes
    device_first,device_end:u64, // the rhi.frame_number of the frames it submitted: [first, end)
    pass_first,pass_count:int,
}

Profile_Pass :: struct {
    name:int,           // into the names of the pass of the Profiler
    start_ns,end_ns:i64, // on the clock of the zones: nanoseconds since the Profile was made
}

Profile_Gpu :: struct {
    frames:[]Profile_Gpu_Frame, // with the frames of the Profiler, index by index
    passes:[]Profile_Pass,
    pass_count:int,
    pass_names:[][PROFILE_PASS_NAME_BYTES]u8, // the GPU reuses the memory of its names every frame
    pass_name_lengths:[]u8,
    pass_name_count:int,
    device_open:u64,   // rhi.frame_number when the frame opened
    timings_taken:u64, // 1 + the rhi frame whose GPU times were taken last; 0: none
}

Profile_Gpu_Recording :: struct {
    frames:[]Profile_Gpu_Frame,
    passes:[]Profile_Pass,
}

profile_pass_name :: proc(app:^App,index:int) -> string {
    g:=&app.profiler.gpu
    if index<0 || index>=g.pass_name_count {return ""}
    return string(g.pass_names[index][:g.pass_name_lengths[index]])
}

// Whether the frame about to be drawn records the GPU time of each pass.
@(private)
profile_gpu_want :: proc(app:^App) {
    if app.device==nil {return}
    p:=&app.profiler
    rhi.timestamps_want(app.device,p.rings_ready && (p.requested>0 || p.recording && .Gpu in p.tracks))
}

@(private)
profile_gpu_start :: proc(app:^App) {
    g:=&app.profiler.gpu
    g.pass_count,g.timings_taken=0,0
    if app.device!=nil {g.device_open=rhi.frame_number(app.device)}
}

@(private)
profile_gpu_frame_open :: proc(app:^App) {
    if app.device!=nil {app.profiler.gpu.device_open=rhi.frame_number(app.device)}
}

@(private)
profile_gpu_frame_end :: proc(app:^App,index:int) {
    g:=&app.profiler.gpu
    frame:=&g.frames[index]
    frame^={pass_first=g.pass_count,device_first=g.device_open,device_end=g.device_open}
    if app.device!=nil {frame.device_end=rhi.frame_number(app.device)}
}

// The GPU times the renderer collected last.
@(private)
profile_gpu_take :: proc(app:^App) {
    if r:=app.renderer;r!=nil {
        stats:=render.renderer_stats(r)
        profile_gpu_add(&app.profiler.gpu,app.profiler.frame_count,stats.timings,stats.timings_frame,profile_epoch_ns(app))
    }
}

// Gives the GPU times of the rhi frame measured, once, to the one of the
// first count frames that submitted it; those of a frame not recorded go.
// epoch: the time of time.tick_now in nanoseconds the zones count from.
@(private)
profile_gpu_add :: proc(g:^Profile_Gpu,count:int,timings:[]rhi.Gpu_Timing,measured:u64,epoch:i64) {
    if len(timings)==0 || measured+1<=g.timings_taken {return}
    g.timings_taken=measured+1
    for i:=count-1;i>=0;i-=1 {
        frame:=&g.frames[i]
        if measured>=frame.device_end {break}
        if measured<frame.device_first {continue}
        // Times come back in order: the passes of the frame stay together after those of the frames before.
        if !frame.measured {frame.measured,frame.pass_first,frame.pass_count=true,g.pass_count,0}
        for timing in timings {
            frame.ms+=timing.ms
            if g.pass_count>=len(g.passes) {continue}
            g.passes[g.pass_count]={profile_pass_intern(g,timing.name),timing.start_ns-epoch,timing.end_ns-epoch}
            g.pass_count+=1
            frame.pass_count+=1
        }
        break
    }
}

// Whether the GPU times of the last recorded frame came back.
@(private)
profile_gpu_done :: proc(p:^Profiler) -> bool {
    if p.frame_count==0 {return true}
    last:=p.gpu.frames[p.frame_count-1]
    return last.device_end==last.device_first || p.gpu.timings_taken>=last.device_end
}

@(private)
profile_pass_intern :: proc(g:^Profile_Gpu,name:string) -> int {
    for i in 0..<g.pass_name_count {
        if string(g.pass_names[i][:g.pass_name_lengths[i]])==name {return i}
    }
    if len(g.pass_names)<PROFILE_PASS_NAMES {return 0}
    if g.pass_name_count==PROFILE_PASS_NAMES-1 {
        other:=PROFILE_PASS_NAMES-1
        g.pass_name_lengths[other]=u8(copy(g.pass_names[other][:],"other"))
        return other
    }
    if g.pass_name_count>=PROFILE_PASS_NAMES {return PROFILE_PASS_NAMES-1}
    index:=g.pass_name_count
    g.pass_name_lengths[index]=u8(copy(g.pass_names[index][:],name))
    g.pass_name_count+=1
    return index
}

@(private)
profile_gpu_reserve :: proc(g:^Profile_Gpu,allocator:runtime.Allocator) -> (error:runtime.Allocator_Error) {
    g.frames,error=make([]Profile_Gpu_Frame,PROFILE_FRAMES_MAX,allocator)
    if error==nil {g.passes,error=make([]Profile_Pass,PROFILE_PASSES,allocator)}
    if error==nil {g.pass_names,error=make([][PROFILE_PASS_NAME_BYTES]u8,PROFILE_PASS_NAMES,allocator)}
    if error==nil {g.pass_name_lengths,error=make([]u8,PROFILE_PASS_NAMES,allocator)}
    return
}

@(private)
profile_gpu_release :: proc(g:^Profile_Gpu,allocator:runtime.Allocator) {
    delete(g.frames,allocator)
    delete(g.passes,allocator)
    delete(g.pass_names,allocator)
    delete(g.pass_name_lengths,allocator)
}
