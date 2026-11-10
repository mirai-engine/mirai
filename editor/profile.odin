package editor

import "core:fmt"
import "core:math"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:platform"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:std/jobs"

// Captures of frames that the profile.* methods record and answer about. A
// capture keeps, in its own arena, every frame with its zones and the times of
// the renderer and the GPU, and the conditions it was measured in: two
// captures only compare when those are the same.

PROFILE_CAPTURES :: 8
PROFILE_DEPTH_MAX :: 64
// The zones of the frame itself, children of "frame" on the main thread.
PROFILE_PARTS :: [?]string{"platform","watch","game","editor","audio","render","pacing"}

// A GPU that idled runs its first frames at a lower clock, in steps of a few
// hundred ms, and lowers it again after a second or two without frames: a
// capture that advances records once the frames that ran back to back up to
// it stopped getting faster.
PROFILE_RECENT :: 1024                      // frames the API ran last that are kept to tell
PROFILE_SETTLE_SPAN :: time.Second          // of those frames, longer than a step of the clock
PROFILE_SETTLE_FRAMES :: 8                  // at least, when they take longer
PROFILE_SETTLE_GAP :: 500*time.Millisecond  // between two frames, past which the earlier do not count
PROFILE_SETTLE_TOLERANCE :: 0.03            // the later half of the span may be faster than the earlier by this fraction
PROFILE_SETTLE_MAX :: 5*time.Second         // of frames run to settle before recording anyway

Profile_State :: enum u8 {Recording,Done,Stopped}

Profile_Conditions :: struct {
    optimization:string, // of the engine: None, Minimal, Size, Speed, Aggressive
    debug:bool,
    write_checks:bool,   // MIRAI_CHECK_WRITES: every function of the loops checks what it writes
    validation:bool,     // of the graphics API
    backend,device,device_type:string,
    mode:string,
    headless,manual:bool,
    window:[2]int,       // pixels of the drawable
    render:[2]int,       // pixels the scene is rendered at
    preset:string,
    render_scale:f32,
    preset_height:u32,
    vsync:bool,
    frame_limit:u32,
    refresh_hz:f32,      // of the display the window is on; 0 when unknown
    document:string,
    entities:int,
    workers:int,         // threads of the job system besides the main one
}

Profile_Frame_Record :: struct {
    start_ns,ns:i64,    // the frame zone, since the first frame began
    between_ns:i64,     // from its end to the start of the next one: what runs between frames
    pacing_ns:i64,
    wait_ms,gpu_ms:f32, // the wait for a frame slot, and the last frame the GPU finished
    render_prepare_ms,render_record_ms,render_end_ms:f32,
    drawn:bool,
    generated:bool,     // it drew an image shown before its own
    presented,intervals:int, // images given to the display since the frame before, and the intervals between them
    interval_total_ms,interval_square:f64, // their sum and the sum of their squares
    latency_ms:f32,
    zone_first,zone_count:int, // its zones of the main thread, by start
    pass_first,pass_count:int,
    worker_ns:i64,      // time of the other threads in jobs
    jobs:int,
}

Profile_Zone_Record :: struct {
    name,frame,thread,depth:int,
    start_ns,ns,self_ns:i64,
}

Profile_Pass_Record :: struct {name:int,ms:f32}

Profile_Capture :: struct {
    arena:vmem.Arena,
    id:int, // 0: the slot is free
    label:string,
    state:Profile_State,
    requested:int,
    conditions:Profile_Conditions,
    frames:[]Profile_Frame_Record,
    zones:[]Profile_Zone_Record, // the main thread frame by frame, then the other threads
    names:[]string,
    passes:[]Profile_Pass_Record,
    pass_names:[]string,
    threads:int,
    lost:u64,
    warmup:int,      // frames run before recording until they stopped getting faster
    unsettled:bool,  // they were still getting faster after PROFILE_SETTLE_MAX
}

Profile_Sample :: struct {end:time.Tick,ms,gpu_ms:f32} // a frame the API ran

Profiles :: struct {
    captures:[PROFILE_CAPTURES]Profile_Capture,
    next_id:int,
    recording:int, // id of the capture being recorded; 0: none
    recent:[PROFILE_RECENT]Profile_Sample, // a ring, the newest at (recent_count-1)%PROFILE_RECENT
    recent_count:int,
}

profiles_destroy :: proc(s:^Session) {
    for &c in s.profiles.captures {profile_capture_free(&c)}
    s.profiles={}
}

@(private)
profile_capture_free :: proc(c:^Profile_Capture) {
    if c.id!=0 {vmem.arena_destroy(&c.arena)}
    c^={}
}

profile_find :: proc(s:^Session,id:int) -> ^Profile_Capture {
    ps:=&s.profiles
    best:^Profile_Capture
    for &c in ps.captures {
        if c.id==0 {continue}
        if id>0 && c.id==id {return &c}
        if id<=0 && c.state!=.Recording && (best==nil || c.id>best.id) {best=&c}
    }
    return id<=0?best:nil
}

// Starts recording frames into a new capture, which replaces the oldest when
// all are taken. Fails while another records.
profile_begin :: proc(s:^Session,frames:int,label:string) -> (c:^Profile_Capture,error:string) {
    profile_collect(s)
    ps:=&s.profiles
    if ps.recording!=0 {return nil,fmt.tprintf("Capture %d is still recording; profile.stop ends it",ps.recording)}
    for &slot in ps.captures {
        if slot.id==0 {c=&slot;break}
        if c==nil || slot.id<c.id {c=&slot}
    }
    profile_capture_free(c)
    if vmem.arena_init_growing(&c.arena)!=nil {return nil,"No memory for a capture"}
    ps.next_id+=1
    c.id=ps.next_id
    c.requested=frames
    context.allocator=vmem.arena_allocator(&c.arena)
    c.label=strings.clone(label)
    c.conditions=profile_conditions(s)
    if !host.profile_start(s.app,frames) {
        profile_capture_free(c)
        return nil,"The recorder could not reserve its memory"
    }
    ps.recording=c.id
    return c,""
}

// Turns a recording that ended into its capture.
profile_collect :: proc(s:^Session) {
    ps:=&s.profiles
    if ps.recording==0 || s.app.profiler.recording {return}
    c:=profile_find(s,ps.recording)
    ps.recording=0
    if c==nil {return}
    recording:=host.profile_recording(s.app)
    c.state=recording.complete?.Done:.Stopped
    context.allocator=vmem.arena_allocator(&c.arena)
    profile_build(c,recording,s.app)
}

@(private)
profile_conditions :: proc(s:^Session) -> (c:Profile_Conditions) {
    app:=s.app
    c.optimization=fmt.aprint(ODIN_OPTIMIZATION_MODE)
    c.debug=ODIN_DEBUG
    c.write_checks=core.CHECK_WRITES
    c.mode=fmt.aprint(s.mode)
    c.headless=s.headless
    if st:=api_state(s);st!=nil {c.manual=st.manual}
    c.window={int(app.drawable.x),int(app.drawable.y)}
    if app.platform!=nil {c.refresh_hz=platform.window_refresh_rate(app.platform)}
    if app.device!=nil {
        info:=rhi.device_info(app.device)
        c.backend,c.device,c.device_type=fmt.aprint(info.backend),strings.clone(info.name),fmt.aprint(info.type)
        c.validation=info.features.validation
    }
    if app.renderer!=nil {
        stats:=gpu.renderer_stats(app.renderer)
        c.render={int(stats.render_width),int(stats.render_height)}
    }
    if g:=graphics_settings(s);g!=nil {
        c.preset=strings.clone(graphics_quality_label(erender.graphics_quality_of(g^)))
        c.render_scale,c.preset_height,c.vsync,c.frame_limit=g.render_scale,g.preset_height,g.vsync,g.frame_limit
    }
    current:=status(s)
    c.document,c.entities=strings.clone(current.document),current.entities
    c.workers=max(jobs.worker_count(&app.jobs)-1,0)
    return
}

// What a recording left, ordered and with the time of every zone without its children.
@(private)
profile_build :: proc(c:^Profile_Capture,recording:host.Profile_Recording,app:^host.App) {
    c.threads,c.lost=recording.threads,recording.lost
    numbers:=make(map[u32]int,len(recording.frames),context.temp_allocator)
    for frame,i in recording.frames {numbers[frame.number]=i}
    c.frames=make([]Profile_Frame_Record,len(recording.frames))
    epoch:=i64(max(i64))
    for zone in recording.zones {
        if zone.thread==0 && zone.depth==0 && zone.name=="frame" {epoch=min(epoch,zone.start)}
    }
    if epoch==max(i64) {
        for zone in recording.zones {epoch=min(epoch,zone.start)}
    }

    // Zones end inner first, so what the children of a zone took is known when it ends.
    selfs:=make([]i64,len(recording.zones),context.temp_allocator)
    children:=make([][PROFILE_DEPTH_MAX]i64,max(c.threads,1),context.temp_allocator)
    for zone,i in recording.zones {
        if int(zone.thread)>=len(children) {continue}
        depth:=min(int(zone.depth),PROFILE_DEPTH_MAX-2)
        sums:=&children[zone.thread]
        selfs[i]=max(zone.duration-sums[depth+1],0)
        sums[depth+1]=0
        sums[depth]+=zone.duration
    }

    ids:=make(map[string]int,64,context.temp_allocator)
    names:=make([dynamic]string)
    name_of :: proc(ids:^map[string]int,names:^[dynamic]string,name:string) -> int {
        if index,found:=ids[name];found {return index}
        index:=len(names)
        copied:=strings.clone(name)
        append(names,copied)
        ids[copied]=index
        return index
    }
    main:=make([dynamic]Profile_Zone_Record,0,len(recording.zones),context.temp_allocator)
    workers:=make([dynamic]Profile_Zone_Record,0,len(recording.zones),context.temp_allocator)
    for zone,i in recording.zones {
        frame,found:=numbers[zone.frame]
        if !found || zone.duration<0 {continue}
        if zone.thread==0 && zone.depth==0 && zone.name=="frame" {
            c.frames[frame].start_ns,c.frames[frame].ns=zone.start-epoch,zone.duration
            continue
        }
        record:=Profile_Zone_Record{name_of(&ids,&names,zone.name),frame,int(zone.thread),int(zone.depth),zone.start-epoch,zone.duration,selfs[i]}
        if zone.thread==0 {
            append(&main,record)
            if zone.depth==1 && zone.name=="pacing" {c.frames[frame].pacing_ns+=zone.duration}
        } else {
            append(&workers,record)
            if zone.depth==0 {c.frames[frame].worker_ns+=zone.duration;c.frames[frame].jobs+=1}
        }
    }
    slice.sort_by(main[:],proc(a,b:Profile_Zone_Record) -> bool {
        if a.frame!=b.frame {return a.frame<b.frame}
        if a.start_ns!=b.start_ns {return a.start_ns<b.start_ns}
        return a.depth<b.depth
    })
    c.zones=make([]Profile_Zone_Record,len(main)+len(workers))
    copy(c.zones,main[:])
    copy(c.zones[len(main):],workers[:])
    c.names=names[:]
    for zone,i in main {
        frame:=&c.frames[zone.frame]
        if frame.zone_count==0 {frame.zone_first=i}
        frame.zone_count+=1
    }

    pass_ids:=make(map[int]int,64,context.temp_allocator)
    pass_names:=make([dynamic]string)
    c.passes=make([]Profile_Pass_Record,len(recording.passes))
    for pass,i in recording.passes {
        index,found:=pass_ids[pass.name]
        if !found {
            index=len(pass_names)
            append(&pass_names,strings.clone(host.profile_pass_name(app,pass.name)))
            pass_ids[pass.name]=index
        }
        c.passes[i]={index,pass.ms}
    }
    c.pass_names=pass_names[:]
    for frame,i in recording.frames {
        // The size the scene was drawn at is known once a frame drew.
        if c.conditions.render=={} && frame.render_width>0 {c.conditions.render={int(frame.render_width),int(frame.render_height)}}
        record:=&c.frames[i]
        record.wait_ms,record.gpu_ms=frame.render_wait_ms,frame.gpu_ms
        record.render_prepare_ms,record.render_record_ms,record.render_end_ms=frame.render_prepare_ms,frame.render_record_ms,frame.render_end_ms
        record.drawn=frame.drawn
        record.generated,record.presented,record.intervals=frame.generated,int(frame.presented),int(frame.intervals)
        record.interval_total_ms,record.interval_square,record.latency_ms=frame.interval_total_ms,frame.interval_square,frame.latency_ms
        record.pass_first,record.pass_count=frame.pass_first,frame.pass_count
    }
    // A manual editor waits for the next request between frames: that is not part of a frame.
    if !c.conditions.manual {
        for i in 0..<len(c.frames)-1 {
            record:=&c.frames[i]
            record.between_ns=max(c.frames[i+1].start_ns-(record.start_ns+record.ns),0)
        }
    }
}

// ---------------------------------------------------------------- settling

// Keeps a frame the API ran, which began at start.
profile_sample :: proc(s:^Session,start:time.Tick) {
    ps:=&s.profiles
    end:=time.tick_now()
    sample:=Profile_Sample{end=end,ms=f32(time.duration_milliseconds(time.tick_diff(start,end)))}
    if s.app.renderer!=nil {sample.gpu_ms=gpu.renderer_stats(s.app.renderer).gpu_ms}
    ps.recent[ps.recent_count%PROFILE_RECENT]=sample
    ps.recent_count+=1
}

// Runs frames until those that ran back to back up to now stopped getting
// faster, for up to PROFILE_SETTLE_MAX: how many it ran and whether they did.
@(private)
profile_settle :: proc(s:^Session,dt:f32) -> (frames:int,settled:bool) {
    start:=time.tick_now()
    for {
        ps:=&s.profiles
        kept:=min(ps.recent_count,PROFILE_RECENT)
        recent:=make([]Profile_Sample,kept,context.temp_allocator)
        for &sample,i in recent {sample=ps.recent[(ps.recent_count-kept+i)%PROFILE_RECENT]}
        if profile_settled(recent,time.tick_now()) {return frames,true}
        // The frames free the temporary memory: nothing above outlives them.
        if time.tick_since(start)>=PROFILE_SETTLE_MAX || api_frames(s,1,dt)==0 || s.quit {return frames,false}
        frames+=1
    }
}

// Whether the frames that ran back to back up to now, oldest first, stopped
// getting faster: over the last PROFILE_SETTLE_SPAN of them, or all of them
// when PROFILE_RECENT fill less, the medians of the frame and GPU times of the
// later half are not below those of the earlier by more than PROFILE_SETTLE_TOLERANCE.
profile_settled :: proc(samples:[]Profile_Sample,now:time.Tick) -> bool {
    n:=len(samples)
    if n<PROFILE_SETTLE_FRAMES || time.tick_diff(samples[n-1].end,now)>PROFILE_SETTLE_GAP {return false}
    duration :: proc(ms:f32) -> time.Duration {return time.Duration(f64(ms)*f64(time.Millisecond))}
    first:=n-1
    for {
        span:=time.tick_diff(samples[first].end,samples[n-1].end)+duration(samples[first].ms)
        if span>=PROFILE_SETTLE_SPAN && n-first>=PROFILE_SETTLE_FRAMES {break}
        if first==0 {
            if n<PROFILE_RECENT {return false}
            break
        }
        if time.tick_diff(samples[first-1].end,samples[first].end)-duration(samples[first].ms)>PROFILE_SETTLE_GAP {return false}
        first-=1
    }
    medians :: proc(samples:[]Profile_Sample) -> (ms,gpu_ms:f64) {
        frame,gpu:=make([]f64,len(samples),context.temp_allocator),make([]f64,len(samples),context.temp_allocator)
        for sample,i in samples {frame[i],gpu[i]=f64(sample.ms),f64(sample.gpu_ms)}
        return profile_spread(frame).p50,profile_spread(gpu).p50
    }
    middle:=(first+n)/2
    earlier_ms,earlier_gpu:=medians(samples[first:middle])
    later_ms,later_gpu:=medians(samples[middle:])
    keep:=1-PROFILE_SETTLE_TOLERANCE
    return later_ms>=earlier_ms*keep && later_gpu>=earlier_gpu*keep
}

// ---------------------------------------------------------------- analysis

Profile_Bound :: enum u8 {Cpu,Gpu,Paced}

// The milliseconds of a frame as the one who plays sees it: the frame and what ran until the next.
profile_frame_ms :: proc(f:Profile_Frame_Record) -> f64 {return f64(f.ns+f.between_ns)/1e6}

// What a frame waited for: the pacing of the window (frame limit, vsync) or a
// frame slot of the GPU, when either took at least a quarter of it.
profile_frame_bound :: proc(f:Profile_Frame_Record) -> Profile_Bound {
    total:=profile_frame_ms(f)
    if total<=0 {return .Cpu}
    if f64(f.pacing_ns)/1e6>=total/4 {return .Paced}
    if f64(f.wait_ms)>=total/4 {return .Gpu}
    return .Cpu
}

// The time of the main thread that was not waiting.
profile_frame_cpu_ms :: proc(f:Profile_Frame_Record) -> f64 {
    return max(profile_frame_ms(f)-f64(f.pacing_ns)/1e6-f64(f.wait_ms),0)
}

Profile_Spread :: struct {mean,p50,p95,p99,max,min:f64}

profile_spread :: proc(values:[]f64) -> (s:Profile_Spread) {
    if len(values)==0 {return}
    sorted:=slice.clone(values,context.temp_allocator)
    slice.sort(sorted)
    total:f64
    for v in sorted {total+=v}
    at :: proc(sorted:[]f64,q:f64) -> f64 {return sorted[clamp(int(math.ceil(q*f64(len(sorted))))-1,0,len(sorted)-1)]}
    s.mean=total/f64(len(sorted))
    s.p50,s.p95,s.p99=at(sorted,0.5),at(sorted,0.95),at(sorted,0.99)
    s.max,s.min=sorted[len(sorted)-1],sorted[0]
    return
}

// Rounded to the microsecond, which is what a time in milliseconds needs and keeps the answer short.
profile_ms :: proc(ms:f64) -> f32 {return f32(math.round(ms*1000)/1000)}

// The zones of one name and thread kind, frame by frame.
Profile_Aggregate :: struct {
    name:int,
    worker:bool,      // on the threads of the job system besides the main one
    calls:int,
    frames_present:int,
    total,self:[]f64, // ms per frame
}

profile_aggregate :: proc(c:^Profile_Capture,allocator:=context.temp_allocator) -> []Profile_Aggregate {
    context.allocator=allocator
    index:=make(map[int]int,len(c.names)*2)
    list:=make([dynamic]Profile_Aggregate)
    for zone in c.zones {
        key:=zone.name*2+(zone.thread!=0?1:0)
        at,found:=index[key]
        if !found {
            at=len(list)
            append(&list,Profile_Aggregate{name=zone.name,worker=zone.thread!=0,total=make([]f64,len(c.frames)),self=make([]f64,len(c.frames))})
            index[key]=at
        }
        a:=&list[at]
        a.calls+=1
        if a.total[zone.frame]==0 && zone.ns>0 {a.frames_present+=1}
        a.total[zone.frame]+=f64(zone.ns)/1e6
        a.self[zone.frame]+=f64(zone.self_ns)/1e6
    }
    return list[:]
}

profile_is_part :: proc(name:string) -> bool {
    parts:=PROFILE_PARTS
    for part in parts {if part==name {return true}}
    return false
}

// The per frame time of each pass of the GPU.
profile_passes_by_name :: proc(c:^Profile_Capture,allocator:=context.temp_allocator) -> [][]f64 {
    context.allocator=allocator
    values:=make([][]f64,len(c.pass_names))
    for &v in values {v=make([]f64,len(c.frames))}
    for frame,i in c.frames {
        for pass in c.passes[frame.pass_first:][:frame.pass_count] {values[pass.name][i]+=f64(pass.ms)}
    }
    return values
}
