package editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:cook/workspace"
import "mirai:editor/api"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The profile.* methods: record frames and answer about them with what an
// agent needs to decide, not with the events themselves. Every time is in ms.

PROFILE_TREE_ZONES :: 256 // zones of one frame in profile.frames
PROFILE_WAIT :: 900       // seconds profile.capture queues by default for a compilation or another measurement: the maximum of its wait
PROFILE_NAME_BYTES :: 128 // of a zone or a GPU pass in an answer
PROFILE_NOTE_BYTES :: 256
PROFILE_LOAD_TOP :: 8     // slowest assets and loop functions of each load in profile.load

Api_Profile_Capture_Params :: struct {
    frames:int `mirai:"optional,min=1,max=3600,label=Frames to record"`,
    advance:bool `mirai:"optional,label=Run the frames inside the call and answer with the summary; first it runs frames until they stop getting faster, unless those that ran just before already did, since a GPU that idled starts at a lower clock. false records the frames the loop runs next (of a window or engine.step or editor.input or play.step) and answers at once: profile.summary answers once they ran"`,
    dt:f32 `mirai:"optional,min=0.0001,max=0.25,unit=s,label=Of each frame a manual editor runs"`,
    label:[32]u8 `mirai:"optional,text,label=Name to tell the capture by"`,
    top:int `mirai:"optional,min=1,max=64,clamp,label=Zones and GPU passes in the summary"`,
    wait:int `mirai:"optional,min=0,max=900,unit=s,label=With advance: how long to queue for a compilation or another measurement that runs; past it the call fails"`,
    allow_limited:bool `mirai:"optional,label=Measure with VSync or a frame limit or graphics validation on; the call refuses otherwise and says how to turn them off. The summary says comparable:false"`,
}
Api_Profile_Id_Params :: struct {
    id:int `mirai:"optional,min=0,label=Capture; 0 is the last one"`,
    top:int `mirai:"optional,min=1,max=64,clamp,label=Zones and GPU passes in the summary"`,
}
Api_Profile_Frames_Params :: struct {
    id:int `mirai:"optional,min=0,label=Capture; 0 is the last one"`,
    worst:int `mirai:"optional,min=1,max=16,clamp,label=The slowest frames when first is not given"`,
    first:int `mirai:"optional,min=-1,max=3599,label=First frame of a range by index in the capture; -1 takes the worst"`,
    count:int `mirai:"optional,min=1,max=16,clamp,label=Frames of the range"`,
    depth:int `mirai:"optional,min=1,max=16,label=Deepest zone: 1 the parts of the frame; 2 the functions of the loops; 3 what runs inside them"`,
    min_ms:f32 `mirai:"optional,min=0,max=1000,label=Zones shorter than this are left out"`,
}
Api_Profile_Zone_Params :: struct {
    id:int `mirai:"optional,min=0,label=Capture; 0 is the last one"`,
    name:[64]u8 `mirai:"text,label=A zone: a part of the frame or a function of the loops or a job or range"`,
    thread:[16]u8 `mirai:"optional,text,label=main or workers; empty: main or else workers when only they have it"`,
}
Api_Profile_Compare_Params :: struct {
    base:int `mirai:"optional,min=0,label=Capture to compare against; 0 is the one before id"`,
    id:int `mirai:"optional,min=0,label=Capture compared; 0 is the last one"`,
    top:int `mirai:"optional,min=1,max=64,clamp,label=Zones and GPU passes that changed the most"`,
}
Api_Profile_Export_Params :: struct {
    id:int `mirai:"optional,min=0,label=Capture; 0 is the last one"`,
    path:[API_PATH_BYTES]u8 `mirai:"optional,text,label=JSON file to write; empty: .mirai/profiles/profile-<id>.json of the project"`,
}

Api_Profile_Stat :: struct {
    name:string,
    mean_ms,p95_ms,max_ms:f32,
}
Api_Profile_Bounds :: struct {cpu,gpu,paced:int}
Api_Profile_Frame_Stats :: struct {
    count:int,
    mean_ms:f32 `mirai:"label=Of the time of a frame: from its start to the start of the next"`,
    p50_ms,p95_ms,p99_ms,max_ms,min_ms:f32,
    fps:f32,
    cpu_ms:f32 `mirai:"label=Mean of the main thread when it was not waiting"`,
    wait_ms:f32 `mirai:"label=Mean wait for a frame slot of the GPU"`,
    pacing_ms:f32 `mirai:"label=Mean wait for the frame limit or VSync"`,
    between_ms:f32 `mirai:"label=Mean from the end of a frame to the start of the next"`,
    gpu_ms:f32 `mirai:"label=Mean of the GPU"`,
    bound:Api_Profile_Bounds `mirai:"label=Frames by what they waited for"`,
    spikes:int `mirai:"label=Frames over twice the median"`,
    worst:[]int `mirai:"label=The slowest frames by index; the slowest first"`,
}
Api_Profile_Zone :: struct {
    name:string,
    thread:string `mirai:"label=main or workers"`,
    calls_per_frame:f32,
    self_ms:f32 `mirai:"label=Mean per frame without the zones inside"`,
    total_ms:f32 `mirai:"label=Mean per frame"`,
    p95_ms:f32 `mirai:"label=Of the total per frame"`,
    max_ms:f32 `mirai:"label=Of the total per frame"`,
    share:f32 `mirai:"label=self_ms over the mean frame"`,
}
Api_Profile_Workers :: struct {
    threads:int `mirai:"label=Of the job system besides the main one"`,
    busy_ms:f32 `mirai:"label=Per frame: all of them together"`,
    jobs_per_frame:f32,
    utilization:f32 `mirai:"label=busy_ms over threads times the mean frame"`,
}
Api_Profile_Presentation :: struct {
    generated_frames:int `mirai:"label=Frames that drew an image shown before their own (frame generation)"`,
    images:int `mirai:"label=Given to the display"`,
    images_per_second:f32 `mirai:"label=Images given to the display over the time of the frames"`,
    interval_mean_ms:f32 `mirai:"label=Between two images given to the display"`,
    interval_deviation_ms:f32 `mirai:"label=Standard deviation of those intervals: the evenness of the pacing"`,
    latency_mean_ms:f32 `mirai:"label=From the start of a frame to its own image going to the display with its GPU work done; without frame generation the GPU is taken to start each frame once it is submitted and the one before is done"`,
    latency_p95_ms:f32,
}
Api_Profile_Summary :: struct {
    id:int `mirai:"label=What the id of the other profile methods takes"`,
    label:string,
    state:Profile_State `mirai:"label=Stopped: ended by profile.stop. While Recording (profile.capture without advance) only id and label and state and frames_requested are given"`,
    frames_recorded:int `mirai:"optional"`,
    frames_requested:int,
    conditions:Profile_Conditions `mirai:"optional,label=How it was measured"`,
    comparable:bool `mirai:"optional,label=Measured without VSync or a frame limit or graphics validation: its frame time is the cost"`,
    frame:Api_Profile_Frame_Stats `mirai:"optional"`,
    presentation:Api_Profile_Presentation `mirai:"optional,label=The images given to the display, the generated ones included"`,
    parts:[]Api_Profile_Stat `mirai:"optional,label=The parts of the frame by their mean time; other: what the frame took besides them; between: what ran between frames"`,
    zones:[]Api_Profile_Zone `mirai:"optional,label=The other zones that cost the most by their own time"`,
    gpu:[]Api_Profile_Stat `mirai:"optional,label=The GPU passes that cost the most"`,
    workers:Api_Profile_Workers `mirai:"optional"`,
    lost_zones:u64 `mirai:"optional,label=Zones the recorder had no room for"`,
    notes:[]string `mirai:"optional,label=What to know before reading the numbers"`,
}

Api_Profile_Tree :: struct {
    name:string,
    depth:int `mirai:"label=1 for a part of the frame"`,
    start_ms:f32 `mirai:"label=Since the frame began"`,
    ms:f32,
    self_ms:f32 `mirai:"label=Without the zones inside"`,
}
Api_Profile_Pass :: struct {
    name:string,
    ms:f32,
}
Api_Profile_Frame :: struct {
    index:int `mirai:"label=In the capture"`,
    ms:f32 `mirai:"label=From its start to the start of the next"`,
    cpu_ms:f32 `mirai:"label=Of the main thread when it was not waiting"`,
    wait_ms:f32 `mirai:"label=For a frame slot of the GPU"`,
    pacing_ms:f32 `mirai:"label=For the frame limit or VSync"`,
    between_ms:f32 `mirai:"label=From its end to the start of the next"`,
    gpu_ms:f32 `mirai:"label=Of the last frame the GPU finished"`,
    bound:Profile_Bound `mirai:"label=What it waited for"`,
    workers_busy_ms:f32,
    jobs:int,
    zones:[]Api_Profile_Tree `mirai:"label=Of the main thread by start"`,
    hidden_zones:int `mirai:"label=Deeper or shorter than asked or past the most listed"`,
    gpu:[]Api_Profile_Pass `mirai:"label=The passes that took the longest"`,
}
Api_Profile_Frames :: struct {
    id:int,
    frames:[]Api_Profile_Frame,
}

Api_Profile_Spread :: struct {mean_ms,p50_ms,p95_ms,max_ms:f32}
Api_Profile_Parent :: struct {
    name:string,
    calls_per_frame:f32,
}
Api_Profile_Related :: struct {
    name:string,
    calls_per_frame,total_ms:f32,
}
Api_Profile_Worst :: struct {
    index:int `mirai:"label=Of the frame in the capture"`,
    ms:f32 `mirai:"label=Of the zone in that frame"`,
    frame_ms:f32,
}
Api_Profile_Zone_Detail :: struct {
    id:int,
    name:string,
    thread:string `mirai:"label=main or workers"`,
    frames_present:int `mirai:"label=Frames it ran in"`,
    calls:int,
    calls_per_frame:f32,
    total:Api_Profile_Spread `mirai:"label=Of its time per frame"`,
    self:Api_Profile_Spread `mirai:"label=Of its time per frame without the zones inside"`,
    share:f32 `mirai:"label=The mean of self over the mean frame"`,
    parents:[]Api_Profile_Parent `mirai:"label=The zones around it; empty on the workers"`,
    children:[]Api_Profile_Related `mirai:"label=The zones inside it per frame by their time; empty on the workers"`,
    worst_frames:[]Api_Profile_Worst `mirai:"label=Where it took the longest"`,
}

Api_Profile_Delta :: struct {
    base,id:f32,
    delta:f32 `mirai:"label=id minus base"`,
    delta_pct:f32 `mirai:"label=Of base; 0 when base is 0"`,
}
Api_Profile_Change :: struct {
    name:string,
    thread:string `mirai:"label=main or workers; gpu for a pass"`,
    base_ms,id_ms,delta_ms:f32,
    delta_pct:f32 `mirai:"label=Of base_ms; 0 when it is 0"`,
}
Api_Profile_Difference :: struct {
    field:string `mirai:"label=A key of conditions"`,
    base:string `mirai:"label=Its value in base as text"`,
    id:string `mirai:"label=Its value in id as text"`,
    blocking:bool `mirai:"label=It changes the times by itself"`,
}
Api_Profile_Compare :: struct {
    base,id:int,
    comparable:bool `mirai:"label=No blocking difference and neither measured with VSync or a frame limit or graphics validation"`,
    differences:[]Api_Profile_Difference `mirai:"label=How their conditions differ"`,
    mean_ms:Api_Profile_Delta `mirai:"label=Of the time of a frame"`,
    p95_ms:Api_Profile_Delta,
    cpu_ms:Api_Profile_Delta `mirai:"label=Mean of the main thread when it was not waiting"`,
    gpu_ms:Api_Profile_Delta `mirai:"label=Mean of the GPU"`,
    zones:[]Api_Profile_Change `mirai:"label=Own time per frame of the zones both have; the largest change first"`,
    gpu:[]Api_Profile_Change `mirai:"label=The GPU passes both have; the largest change first"`,
    only_in_base:[]string `mirai:"label=Zones only base has"`,
    only_in_id:[]string `mirai:"label=Zones only id has"`,
    notes:[]string `mirai:"label=What to know before reading the changes"`,
}

Api_Profile_Export :: struct {
    id:int,
    path:[API_PATH_BYTES]u8 `mirai:"text"`,
    events:int `mirai:"label=Trace events written"`,
    bytes:int,
}

Api_Profile_List_Item :: struct {
    id:int,
    label:string,
    state:Profile_State,
    frames:int,
    mean_ms,p95_ms:f32,
    mode,optimization,preset,document:string,
}
Api_Profile_List :: struct {
    recording:int `mirai:"label=The capture that records; 0: none"`,
    recorded:int `mirai:"label=Frames the capture that records recorded so far"`,
    requested:int `mirai:"label=Frames the capture that records asked for"`,
    captures:[]Api_Profile_List_Item `mirai:"label=Those that ended; the newest last"`,
}

@(private)
profile_api_register :: proc(s:^Session,st:^Api_State) {
    capture_default:=Api_Profile_Capture_Params{frames=120,advance=true,dt=HEADLESS_DT,top=12,wait=PROFILE_WAIT}
    id_default:=Api_Profile_Id_Params{top=12}
    frames_default:=Api_Profile_Frames_Params{worst=5,first=-1,count=1,depth=3,min_ms=0.02}
    compare_default:=Api_Profile_Compare_Params{top=12}
    api_register(s,st,{name="profile.capture",summary="Records frames to see where their time goes: a zone per part of the frame, per function of the loops and per job, the waits of the renderer and the GPU passes.",params=type_info_of(Api_Profile_Capture_Params),result=type_info_of(Api_Profile_Summary),defaults=&capture_default,run=api_profile_capture})
    api_register(s,st,{name="profile.stop",summary="Ends the capture that is recording before its frames are done; it keeps those it recorded.",params=type_info_of(Api_Profile_Id_Params),result=type_info_of(Api_Profile_Summary),defaults=&id_default,run=api_profile_stop})
    api_register(s,st,{name="profile.list",summary="The captures kept in memory and the one that is recording.",result=type_info_of(Api_Profile_List),flags={.Read_Only},run=api_profile_list})
    api_register(s,st,{name="profile.summary",summary="What a capture says: where the time of its frames went and what bounds them, with notes on how to read it.",params=type_info_of(Api_Profile_Id_Params),result=type_info_of(Api_Profile_Summary),defaults=&id_default,flags={.Read_Only},run=api_profile_summary})
    api_register(s,st,{name="profile.frames",summary="The slowest frames of a capture, or a range of them, zone by zone with their GPU passes: where a spike went.",params=type_info_of(Api_Profile_Frames_Params),result=type_info_of(Api_Profile_Frames),defaults=&frames_default,flags={.Read_Only},run=api_profile_frames})
    api_register(s,st,{name="profile.zone",summary="One zone across a capture: how its time spreads with and without what runs inside it, the zones around and inside it and the frames where it took the longest.",params=type_info_of(Api_Profile_Zone_Params),result=type_info_of(Api_Profile_Zone_Detail),flags={.Read_Only},run=api_profile_zone})
    api_register(s,st,{name="profile.compare",summary="Two captures: whether they were measured alike and, zone by zone and pass by pass, what changed the most.",params=type_info_of(Api_Profile_Compare_Params),result=type_info_of(Api_Profile_Compare),defaults=&compare_default,flags={.Read_Only},run=api_profile_compare})
    load_default:=Api_Profile_Load_Params{top=PROFILE_LOAD_TOP}
    api_register(s,st,{name="profile.load",summary="Where the seconds of the last load of the document, of Play and of a section went: phase by phase, by kind of asset with the slowest, the loop functions meanwhile and what it waited for until a frame drew with all of it resident; Loading until then.",params=type_info_of(Api_Profile_Load_Params),result=type_info_of(Api_Profile_Loads),defaults=&load_default,flags={.Read_Only},run=api_profile_load})
    api_register(s,st,{name="profile.export",summary="Writes a capture as a Chrome trace (JSON) for Perfetto, chrome://tracing or Spall.",params=type_info_of(Api_Profile_Export_Params),result=type_info_of(Api_Profile_Export),run=api_profile_export})
}

@(private)
api_profile_get :: proc(s:^Session,call:^api.Call,id:int) -> ^Profile_Capture {
    profile_collect(s)
    c:=profile_find(s,id)
    if c!=nil && c.state==.Recording {
        api.call_failf(call,api.SERVER_ERROR,"Capture %d is still recording; wait for profile.list to say Done, or end it with profile.stop",c.id)
        return nil
    }
    if c==nil {
        if s.profiles.recording!=0 && (id==0 || id==s.profiles.recording) {api.call_failf(call,api.SERVER_ERROR,"Capture %d is still recording; profile.stop ends it",s.profiles.recording)}
        else if id==0 {api.call_fail(call,api.SERVER_ERROR,"No capture yet: profile.capture records one")}
        else {api.call_failf(call,api.INVALID_PARAMS,"No capture %d: profile.list lists them",id)}
    }
    return c
}

@(private)
api_profile_capture :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Profile_Capture_Params)
    if !p.allow_limited {
        conditions:Profile_Conditions
        {
            context.allocator=context.temp_allocator
            conditions=profile_conditions(s)
        }
        if refusal:=profile_refusal(profile_limits(conditions));refusal!="" {api.call_fail(call,api.SERVER_ERROR,refusal);return}
    }
    // Frames that run here run alone among the checkouts, or not at all: in
    // the turn this takes, or in that of the measurement the caller is part of.
    measure:workspace.Lock
    defer workspace.lock_release(&measure)
    if p.advance && s.engine_root!="" {
        ok,compiling:bool
        holder:string
        measure,ok,holder,compiling=workspace.measure_try(s.engine_root,workspace.measure_holder(fmt.tprintf("profile.capture in %s",s.project_root)),time.Duration(p.wait)*time.Second,call.measure)
        if holder=="" {holder="another process"}
        what:=compiling?"A compilation":"Another measurement"
        if !ok {api.call_failf(call,api.SERVER_ERROR,"%s runs (%s) and did not end within wait (%d s); mirai locks says who holds its turn, and the call can be made again when it ends",what,holder,p.wait);return}
    }
    // While another capture records, profile_begin refuses: no frames run into it.
    profile_collect(s)
    warmup,settled:=0,true
    if p.advance && s.profiles.recording==0 {warmup,settled=profile_settle(s,p.dt)}
    c,error:=profile_begin(s,p.frames,base.text_get(p.label[:]))
    if c==nil {api.call_fail(call,api.SERVER_ERROR,error);return}
    c.warmup,c.unsettled=warmup,!settled
    if !p.advance {
        api.call_result(call,Api_Profile_Summary)^={id=c.id,label=c.label,state=.Recording,frames_requested=p.frames}
        return
    }
    api_frames(s,p.frames,p.dt)
    host.profile_stop(s.app)
    profile_collect(s)
    api.call_result(call,Api_Profile_Summary)^=profile_summary(c,p.top)
}

@(private)
api_profile_stop :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Profile_Id_Params)
    id:=s.profiles.recording
    if id==0 {api.call_fail(call,api.SERVER_ERROR,"Nothing is recording");return}
    host.profile_stop(s.app)
    if c:=api_profile_get(s,call,id);c!=nil {api.call_result(call,Api_Profile_Summary)^=profile_summary(c,p.top)}
}

@(private)
api_profile_list :: proc(s:^Session,call:^api.Call) {
    profile_collect(s)
    out:Api_Profile_List
    out.recording=s.profiles.recording
    if out.recording!=0 {
        out.recorded,out.requested=s.app.profiler.frame_count,s.app.profiler.wanted
    }
    list:=make([dynamic]Api_Profile_List_Item,call.allocator)
    for &c in s.profiles.captures {
        if c.id==0 || c.state==.Recording {continue}
        totals:=make([]f64,len(c.frames),context.temp_allocator)
        for f,i in c.frames {totals[i]=profile_frame_ms(f)}
        spread:=profile_spread(totals)
        append(&list,Api_Profile_List_Item{c.id,c.label,c.state,len(c.frames),profile_ms(spread.mean),profile_ms(spread.p95),c.conditions.mode,c.conditions.optimization,c.conditions.preset,c.conditions.document})
    }
    slice.sort_by(list[:],proc(a,b:Api_Profile_List_Item) -> bool {return a.id<b.id})
    out.captures=list[:]
    api.call_result(call,Api_Profile_List)^=out
}

@(private)
api_profile_summary :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Profile_Id_Params)
    if c:=api_profile_get(s,call,p.id);c!=nil {api.call_result(call,Api_Profile_Summary)^=profile_summary(c,p.top)}
}

// ---------------------------------------------------------------- summary

profile_summary :: proc(c:^Profile_Capture,top:int) -> (out:Api_Profile_Summary) {
    context.allocator=context.temp_allocator
    out.id,out.label,out.state=c.id,c.label,c.state
    out.frames_recorded,out.frames_requested=len(c.frames),c.requested
    out.conditions=c.conditions
    out.comparable=profile_limits(c.conditions)=={}
    out.lost_zones=c.lost
    n:=len(c.frames)
    if n==0 {
        notes:=make([]string,1)
        notes[0]="No frame was recorded: in a manual editor frames only run when asked to (advance, engine.step, editor.input)"
        out.notes=notes
        return
    }
    totals,cpu,wait,pacing,between,gpu:=make([]f64,n),make([]f64,n),make([]f64,n),make([]f64,n),make([]f64,n),make([]f64,n)
    for f,i in c.frames {
        totals[i],cpu[i],wait[i]=profile_frame_ms(f),profile_frame_cpu_ms(f),f64(f.wait_ms)
        pacing[i],between[i],gpu[i]=f64(f.pacing_ns)/1e6,f64(f.between_ns)/1e6,f64(f.gpu_ms)
        switch profile_frame_bound(f) {
        case .Cpu: out.frame.bound.cpu+=1
        case .Gpu: out.frame.bound.gpu+=1
        case .Paced: out.frame.bound.paced+=1
        }
    }
    spread:=profile_spread(totals)
    out.frame.count=n
    out.frame.mean_ms,out.frame.p50_ms,out.frame.p95_ms=profile_ms(spread.mean),profile_ms(spread.p50),profile_ms(spread.p95)
    out.frame.p99_ms,out.frame.max_ms,out.frame.min_ms=profile_ms(spread.p99),profile_ms(spread.max),profile_ms(spread.min)
    if spread.mean>0 {out.frame.fps=profile_ms(1000/spread.mean)}
    out.frame.cpu_ms,out.frame.wait_ms=profile_ms(profile_spread(cpu).mean),profile_ms(profile_spread(wait).mean)
    out.frame.pacing_ms,out.frame.between_ms=profile_ms(profile_spread(pacing).mean),profile_ms(profile_spread(between).mean)
    out.frame.gpu_ms=profile_ms(profile_spread(gpu).mean)
    for t in totals {if t>2*spread.p50 {out.frame.spikes+=1}}
    out.frame.worst=profile_worst(c,min(3,n))
    out.presentation=profile_presentation(c,spread.mean*f64(n))

    aggregates:=profile_aggregate(c)
    parts:=make([dynamic]Api_Profile_Stat)
    zones:=make([dynamic]Api_Profile_Zone)
    covered:=make([]f64,n)
    for a in aggregates {
        name:=c.names[a.name]
        if !a.worker && profile_is_part(name) {
            for v,i in a.total {covered[i]+=v}
            total:=profile_spread(a.total)
            append(&parts,Api_Profile_Stat{name,profile_ms(total.mean),profile_ms(total.p95),profile_ms(total.max)})
            continue
        }
        total,own:=profile_spread(a.total),profile_spread(a.self)
        append(&zones,Api_Profile_Zone{
            name=name,thread=a.worker?"workers":"main",calls_per_frame=profile_ms(f64(a.calls)/f64(n)),
            self_ms=profile_ms(own.mean),total_ms=profile_ms(total.mean),p95_ms=profile_ms(total.p95),max_ms=profile_ms(total.max),
            share=spread.mean>0?profile_ms(own.mean/spread.mean):0,
        })
    }
    // What the frame zone took besides its parts: the editor between its loops, input, Play.
    other:=make([]f64,n)
    for f,i in c.frames {other[i]=max(f64(f.ns)/1e6-covered[i],0)}
    other_spread:=profile_spread(other)
    append(&parts,Api_Profile_Stat{"other",profile_ms(other_spread.mean),profile_ms(other_spread.p95),profile_ms(other_spread.max)})
    between_spread:=profile_spread(between)
    append(&parts,Api_Profile_Stat{"between",profile_ms(between_spread.mean),profile_ms(between_spread.p95),profile_ms(between_spread.max)})
    slice.sort_by(parts[:],proc(a,b:Api_Profile_Stat) -> bool {return a.mean_ms>b.mean_ms})
    slice.sort_by(zones[:],proc(a,b:Api_Profile_Zone) -> bool {return a.self_ms>b.self_ms})
    out.parts=parts[:]
    out.zones=zones[:min(len(zones),top)]

    passes:=profile_passes_by_name(c)
    gpu_list:=make([dynamic]Api_Profile_Stat)
    for values,i in passes {
        pass:=profile_spread(values)
        append(&gpu_list,Api_Profile_Stat{c.pass_names[i],profile_ms(pass.mean),profile_ms(pass.p95),profile_ms(pass.max)})
    }
    slice.sort_by(gpu_list[:],proc(a,b:Api_Profile_Stat) -> bool {return a.mean_ms>b.mean_ms})
    out.gpu=gpu_list[:min(len(gpu_list),top)]

    out.workers.threads=c.conditions.workers
    busy,jobs:f64
    for f in c.frames {busy+=f64(f.worker_ns)/1e6;jobs+=f64(f.jobs)}
    out.workers.busy_ms,out.workers.jobs_per_frame=profile_ms(busy/f64(n)),profile_ms(jobs/f64(n))
    if out.workers.threads>0 && spread.mean>0 {out.workers.utilization=profile_ms(busy/f64(n)/(f64(out.workers.threads)*spread.mean))}
    out.notes=profile_notes(c,out)
    return
}

@(private="file")
Ranked :: struct {index:int,value:f64}

// The indices of the largest values, largest first.
@(private="file")
profile_largest :: proc(values:[]f64,count:int) -> []int {
    ranked:=make([]Ranked,len(values),context.temp_allocator)
    for v,i in values {ranked[i]={i,v}}
    slice.sort_by(ranked,proc(a,b:Ranked) -> bool {return a.value>b.value || (a.value==b.value && a.index<b.index)})
    out:=make([]int,min(count,len(ranked)),context.temp_allocator)
    for &v,i in out {v=ranked[i].index}
    return out
}

// The slowest frames, slowest first.
@(private)
profile_worst :: proc(c:^Profile_Capture,count:int) -> []int {
    totals:=make([]f64,len(c.frames),context.temp_allocator)
    for f,i in c.frames {totals[i]=profile_frame_ms(f)}
    return profile_largest(totals,count)
}

Profile_Limit :: enum u8 {Vsync,Frame_Limit,Validation}
Profile_Limits :: bit_set[Profile_Limit;u8]

// What keeps the frame time of a capture from being the cost of its frames:
// waiting for the display or for a limit, or a graphics API that checks every
// call. A window paces its frames as the graphics settings say; a headless
// editor does not pace them.
profile_presentation :: proc(c:^Profile_Capture,total_ms:f64) -> (out:Api_Profile_Presentation) {
    intervals:=0
    sum,square:f64
    latencies:=make([dynamic]f64,context.temp_allocator)
    for f in c.frames {
        if f.generated {out.generated_frames+=1}
        out.images+=f.presented
        intervals+=f.intervals
        sum+=f.interval_total_ms
        square+=f.interval_square
        if f.drawn && f.latency_ms>0 {append(&latencies,f64(f.latency_ms))}
    }
    if total_ms>0 {out.images_per_second=profile_ms(f64(out.images)*1000/total_ms)}
    if intervals>0 {
        mean:=sum/f64(intervals)
        out.interval_mean_ms=profile_ms(mean)
        out.interval_deviation_ms=profile_ms(math.sqrt(max(square/f64(intervals)-mean*mean,0)))
    }
    if len(latencies)>0 {
        latency:=profile_spread(latencies[:])
        out.latency_mean_ms,out.latency_p95_ms=profile_ms(latency.mean),profile_ms(latency.p95)
    }
    return
}

profile_limits :: proc(k:Profile_Conditions) -> (limits:Profile_Limits) {
    if !k.headless && k.vsync {limits+={.Vsync}}
    if !k.headless && k.frame_limit>0 {limits+={.Frame_Limit}}
    if k.validation {limits+={.Validation}}
    return
}

// Why profile.capture does not measure with limits, and how to lift each; "" without them.
profile_refusal :: proc(limits:Profile_Limits) -> string {
    if limits=={} {return ""}
    lifts:=make([dynamic]string,context.temp_allocator)
    if .Vsync in limits {append(&lifts,`VSync is on: settings.set {"settings":{"Graphics_Settings":{"vsync":false}}} turns it off`)}
    if .Frame_Limit in limits {append(&lifts,`frames are limited: settings.set {"settings":{"Graphics_Settings":{"frame_limit":0}}} lifts the limit`)}
    if .Validation in limits {append(&lifts,"graphics API validation is on: open the editor without --validation")}
    return fmt.tprintf("The frame time would not be the cost of the frame: %s. A headless editor (mirai session start) paces nothing; allow_limited:true measures anyway, with comparable:false",strings.join(lifts[:],"; ",context.temp_allocator))
}

// What an agent should know before it reads the numbers.
@(private)
profile_notes :: proc(c:^Profile_Capture,out:Api_Profile_Summary) -> []string {
    notes:=make([dynamic]string)
    k:=c.conditions
    n:=f64(out.frame.count)
    if k.optimization!="Speed" && k.optimization!="Aggressive" {
        append(&notes,fmt.tprintf("The engine is built with -o:%s: times are not those of a release; mirai build engine --release builds it at Speed before measuring",strings.to_lower(k.optimization)))
    }
    if k.write_checks {append(&notes,"MIRAI_CHECK_WRITES is on: every function of the loops checks what it writes")}
    if k.validation {append(&notes,"Graphics API validation is on: CPU and GPU times are inflated; measure without it")}
    if k.headless && !k.manual {append(&notes,"Headless: no display, so pacing and vsync do not apply")}
    if k.manual {append(&notes,"Manual editor: frames run on request, so the wait between them is left out and a frame time is the work of that frame")}
    if k.backend=="" {append(&notes,"No GPU: render and gpu are empty")}
    if c.unsettled {
        append(&notes,fmt.tprintf("The frames were still getting faster after %d frames (%v) run to let the GPU reach its clock: another program loads it or the scene gets cheaper as it runs; a second capture says whether the time holds",c.warmup,PROFILE_SETTLE_MAX))
    } else if c.warmup>0 {
        append(&notes,fmt.tprintf("%d frames ran before recording, until they stopped getting faster: a GPU that idled starts at a lower clock",c.warmup))
    }
    if f64(out.frame.bound.paced)>=n/2 {
        append(&notes,fmt.tprintf("%d of %d frames wait for pacing (frame_limit %d, vsync %v): the frame time is the limit, not the cost; read cpu_ms, or lift the limit with settings.set",out.frame.bound.paced,out.frame.count,k.frame_limit,k.vsync))
    } else if f64(out.frame.bound.gpu)>=n/2 {
        append(&notes,fmt.tprintf("%d of %d frames wait for the GPU (wait_ms): CPU savings will not shorten them; the gpu passes say where the GPU goes",out.frame.bound.gpu,out.frame.count))
        if k.vsync {append(&notes,"vsync is on: the wait for a frame slot includes the display; with VSync off (settings.set) it is only the GPU")}
    }
    if len(c.pass_names)==1 && c.pass_names[0]=="frame" {append(&notes,"The GPU of this backend is measured per frame, not per pass: gpu has the whole frame only")}
    if out.frame.spikes>0 {append(&notes,fmt.tprintf("%d frames took more than twice the median: profile.frames shows the worst with their zones",out.frame.spikes))}
    if c.lost>0 {append(&notes,fmt.tprintf("%d zones were lost: record fewer frames for an exact count",c.lost))}
    if c.state==.Stopped {append(&notes,fmt.tprintf("Stopped after %d of %d frames",len(c.frames),c.requested))}
    if len(c.frames)<30 {append(&notes,"Fewer than 30 frames: percentiles are rough")}
    return notes[:]
}

// ---------------------------------------------------------------- frames

@(private)
api_profile_frames :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Profile_Frames_Params)
    c:=api_profile_get(s,call,p.id)
    if c==nil {return}
    context.allocator=context.temp_allocator
    indices:[]int
    if p.first>=0 {
        if p.first>=len(c.frames) {api.call_failf(call,api.INVALID_PARAMS,"Capture %d has %d frames (0 to %d)",c.id,len(c.frames),len(c.frames)-1);return}
        list:=make([dynamic]int)
        for i in p.first..<min(p.first+p.count,len(c.frames)) {append(&list,i)}
        indices=list[:]
    } else {
        indices=profile_worst(c,p.worst)
    }
    out:=Api_Profile_Frames{id=c.id,frames=make([]Api_Profile_Frame,len(indices))}
    for index,k in indices {out.frames[k]=profile_frame_out(c,index,p.depth,f64(p.min_ms))}
    api.call_result(call,Api_Profile_Frames)^=out
}

profile_frame_out :: proc(c:^Profile_Capture,index,depth:int,min_ms:f64) -> (out:Api_Profile_Frame) {
    f:=c.frames[index]
    out.index=index
    out.ms,out.cpu_ms,out.wait_ms=profile_ms(profile_frame_ms(f)),profile_ms(profile_frame_cpu_ms(f)),profile_ms(f64(f.wait_ms))
    out.pacing_ms,out.between_ms,out.gpu_ms=profile_ms(f64(f.pacing_ns)/1e6),profile_ms(f64(f.between_ns)/1e6),profile_ms(f64(f.gpu_ms))
    out.bound=profile_frame_bound(f)
    out.workers_busy_ms,out.jobs=profile_ms(f64(f.worker_ns)/1e6),f.jobs
    zones:=make([dynamic]Api_Profile_Tree)
    for zone in c.zones[f.zone_first:][:f.zone_count] {
        ms:=f64(zone.ns)/1e6
        if zone.depth>depth || ms<min_ms || len(zones)>=PROFILE_TREE_ZONES {out.hidden_zones+=1;continue}
        append(&zones,Api_Profile_Tree{c.names[zone.name],zone.depth,profile_ms(f64(zone.start_ns-f.start_ns)/1e6),profile_ms(ms),profile_ms(f64(zone.self_ns)/1e6)})
    }
    out.zones=zones[:]
    passes:=make([dynamic]Api_Profile_Pass)
    for pass in c.passes[f.pass_first:][:f.pass_count] {append(&passes,Api_Profile_Pass{c.pass_names[pass.name],profile_ms(f64(pass.ms))})}
    slice.sort_by(passes[:],proc(a,b:Api_Profile_Pass) -> bool {return a.ms>b.ms})
    out.gpu=passes[:min(len(passes),8)]
    return
}

// ---------------------------------------------------------------- zone

@(private)
api_profile_zone :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Profile_Zone_Params)
    c:=api_profile_get(s,call,p.id)
    if c==nil {return}
    out,error:=profile_zone_detail(c,base.text_get(p.name[:]),base.text_get(p.thread[:]))
    if error!="" {api.call_fail(call,api.INVALID_PARAMS,error);return}
    api.call_result(call,Api_Profile_Zone_Detail)^=out
}

profile_zone_detail :: proc(c:^Profile_Capture,name,thread:string) -> (out:Api_Profile_Zone_Detail,error:string) {
    context.allocator=context.temp_allocator
    if thread!="" && thread!="main" && thread!="workers" {return {},"thread is main or workers"}
    aggregates:=profile_aggregate(c)
    found:^Profile_Aggregate
    for &a in aggregates {
        if c.names[a.name]!=name {continue}
        if thread=="workers" && !a.worker {continue}
        if thread=="main" && a.worker {continue}
        if found==nil || (thread=="" && !a.worker) {found=&a}
    }
    if found==nil {
        known:=make([dynamic]string)
        for a in aggregates {if len(known)<8 && strings.contains(c.names[a.name],name) {append(&known,c.names[a.name])}}
        if len(known)>0 {return {},fmt.tprintf("No zone %q in capture %d; close names: %s",name,c.id,strings.join(known[:],", "))}
        return {},fmt.tprintf("No zone %q in capture %d: profile.summary lists the costliest",name,c.id)
    }
    n:=f64(len(c.frames))
    out.id,out.name,out.thread=c.id,name,found.worker?"workers":"main"
    out.frames_present,out.calls=found.frames_present,found.calls
    out.calls_per_frame=profile_ms(f64(found.calls)/n)
    total,own:=profile_spread(found.total),profile_spread(found.self)
    out.total={profile_ms(total.mean),profile_ms(total.p50),profile_ms(total.p95),profile_ms(total.max)}
    out.self={profile_ms(own.mean),profile_ms(own.p50),profile_ms(own.p95),profile_ms(own.max)}
    frames:=make([]f64,len(c.frames))
    for f,i in c.frames {frames[i]=profile_frame_ms(f)}
    if mean:=profile_spread(frames).mean;mean>0 {out.share=profile_ms(own.mean/mean)}

    // Parents and children: on the main thread, where zones nest.
    if !found.worker {
        parents:=make(map[int]int)
        children:=make(map[int][2]f64) // calls, ms
        for f in c.frames {
            zones:=c.zones[f.zone_first:][:f.zone_count]
            for zone,i in zones {
                if zone.name!=found.name {continue}
                for j:=i-1;j>=0;j-=1 {
                    if zones[j].depth<zone.depth {parents[zones[j].name]+=1;break}
                }
                for j in i+1..<len(zones) {
                    if zones[j].depth<=zone.depth {break}
                    if zones[j].depth==zone.depth+1 {
                        v:=children[zones[j].name]
                        children[zones[j].name]={v[0]+1,v[1]+f64(zones[j].ns)/1e6}
                    }
                }
            }
        }
        around:=make([dynamic]Api_Profile_Parent)
        for key,calls in parents {append(&around,Api_Profile_Parent{c.names[key],profile_ms(f64(calls)/n)})}
        out.parents=around[:]
        list:=make([dynamic]Api_Profile_Related)
        for key,v in children {append(&list,Api_Profile_Related{c.names[key],profile_ms(v[0]/n),profile_ms(v[1]/n)})}
        slice.sort_by(list[:],proc(a,b:Api_Profile_Related) -> bool {return a.total_ms>b.total_ms})
        out.children=list[:min(len(list),16)]
    }
    values:=found.total
    worst:=make([dynamic]Api_Profile_Worst)
    for index in profile_largest(values,5) {
        if values[index]<=0 {break}
        append(&worst,Api_Profile_Worst{index,profile_ms(values[index]),profile_ms(profile_frame_ms(c.frames[index]))})
    }
    out.worst_frames=worst[:]
    return
}

// ---------------------------------------------------------------- compare

@(private)
api_profile_compare :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Profile_Compare_Params)
    b:=api_profile_get(s,call,p.id)
    if b==nil {return}
    base_id:=p.base
    if base_id==0 {
        for &c in s.profiles.captures {
            if c.id!=0 && c.id<b.id && c.state!=.Recording && c.id>base_id {base_id=c.id}
        }
        if base_id==0 {api.call_failf(call,api.SERVER_ERROR,"Capture %d has none before it: record another, or pass base",b.id);return}
    }
    a:=api_profile_get(s,call,base_id)
    if a==nil {return}
    if a==b {api.call_fail(call,api.INVALID_PARAMS,"base and id are the same capture");return}
    api.call_result(call,Api_Profile_Compare)^=profile_compare(a,b,p.top)
}

profile_compare :: proc(a,b:^Profile_Capture,top:int) -> (out:Api_Profile_Compare) {
    context.allocator=context.temp_allocator
    out.base,out.id=a.id,b.id
    out.differences=profile_differences(a.conditions,b.conditions)
    apart:=false
    for d in out.differences {if d.blocking {apart=true}}
    limited:=profile_limits(a.conditions)!={} || profile_limits(b.conditions)!={}
    out.comparable=!apart && !limited

    fa,fb:=profile_spread(frame_values(a,0)),profile_spread(frame_values(b,0))
    out.mean_ms,out.p95_ms=delta(fa.mean,fb.mean),delta(fa.p95,fb.p95)
    out.cpu_ms=delta(profile_spread(frame_values(a,1)).mean,profile_spread(frame_values(b,1)).mean)
    out.gpu_ms=delta(profile_spread(frame_values(a,2)).mean,profile_spread(frame_values(b,2)).mean)

    ma,mb:=means(a),means(b)
    changes:=make([dynamic]Api_Profile_Change)
    only_a,only_b:=make([dynamic]string),make([dynamic]string)
    for key,x in ma {
        y,found:=mb[key]
        if !found {append(&only_a,key.name);continue}
        d:=delta(x,y)
        append(&changes,Api_Profile_Change{key.name,key.worker?"workers":"main",d.base,d.id,d.delta,d.delta_pct})
    }
    for key,_ in mb {if key not_in ma {append(&only_b,key.name)}}
    slice.sort_by(changes[:],proc(x,y:Api_Profile_Change) -> bool {return abs(x.delta_ms)>abs(y.delta_ms)})
    out.zones=changes[:min(len(changes),top)]
    out.only_in_base,out.only_in_id=only_a[:min(len(only_a),top)],only_b[:min(len(only_b),top)]

    pa,pb:=pass_means(a),pass_means(b)
    gpu_changes:=make([dynamic]Api_Profile_Change)
    for name,x in pa {
        y,found:=pb[name]
        if !found {continue}
        d:=delta(x,y)
        append(&gpu_changes,Api_Profile_Change{name,"gpu",d.base,d.id,d.delta,d.delta_pct})
    }
    slice.sort_by(gpu_changes[:],proc(x,y:Api_Profile_Change) -> bool {return abs(x.delta_ms)>abs(y.delta_ms)})
    out.gpu=gpu_changes[:min(len(gpu_changes),top)]

    notes:=make([dynamic]string)
    if apart {append(&notes,"Measured in different conditions: a change in time can be the conditions and not the code. Record both alike")}
    if limited {append(&notes,"A capture was measured with VSync, a frame limit or graphics validation (allow_limited): its frame time is not the cost; cpu_ms and the zones still compare")}
    if len(a.frames)<30 || len(b.frames)<30 {append(&notes,"Fewer than 30 frames in a capture: differences of a few percent are noise")}
    out.notes=notes[:]
    return
}

@(private="file")
delta :: proc(x,y:f64) -> Api_Profile_Delta {
    return {profile_ms(x),profile_ms(y),profile_ms(y-x),f32(x>0?math.round((y-x)/x*1000)/10:0)}
}

@(private="file")
frame_values :: proc(c:^Profile_Capture,which:int) -> []f64 {
    values:=make([]f64,len(c.frames))
    for f,i in c.frames {
        switch which {
        case 0: values[i]=profile_frame_ms(f)
        case 1: values[i]=profile_frame_cpu_ms(f)
        case 2: values[i]=f64(f.gpu_ms)
        }
    }
    return values
}

@(private="file")
Key :: struct {name:string,worker:bool}

@(private="file")
means :: proc(c:^Profile_Capture) -> map[Key]f64 {
    result:=make(map[Key]f64)
    for agg in profile_aggregate(c) {result[{c.names[agg.name],agg.worker}]=profile_spread(agg.self).mean}
    return result
}

@(private="file")
pass_means :: proc(c:^Profile_Capture) -> map[string]f64 {
    result:=make(map[string]f64)
    for values,i in profile_passes_by_name(c) {result[c.pass_names[i]]=profile_spread(values).mean}
    return result
}

@(private="file")
difference_check :: proc(list:^[dynamic]Api_Profile_Difference,field:string,x,y:$T,blocking:bool) {
    if x!=y {append(list,Api_Profile_Difference{field,fmt.tprint(x),fmt.tprint(y),blocking})}
}

// How two captures were measured differently. A blocking difference changes
// the times by itself: the build, the device, the graphics, the scene.
profile_differences :: proc(a,b:Profile_Conditions) -> []Api_Profile_Difference {
    list:=make([dynamic]Api_Profile_Difference)
    difference_check(&list,"optimization",a.optimization,b.optimization,true)
    difference_check(&list,"debug",a.debug,b.debug,true)
    difference_check(&list,"write_checks",a.write_checks,b.write_checks,true)
    difference_check(&list,"validation",a.validation,b.validation,true)
    difference_check(&list,"backend",a.backend,b.backend,true)
    difference_check(&list,"device",a.device,b.device,true)
    difference_check(&list,"mode",a.mode,b.mode,true)
    difference_check(&list,"headless",a.headless,b.headless,true)
    difference_check(&list,"manual",a.manual,b.manual,true)
    difference_check(&list,"window",a.window,b.window,true)
    difference_check(&list,"render",a.render,b.render,true)
    difference_check(&list,"preset",a.preset,b.preset,true)
    difference_check(&list,"resolution",a.resolution,b.resolution,true)
    difference_check(&list,"vsync",a.vsync,b.vsync,true)
    difference_check(&list,"frame_limit",a.frame_limit,b.frame_limit,true)
    difference_check(&list,"document",a.document,b.document,true)
    difference_check(&list,"entities",a.entities,b.entities,false)
    difference_check(&list,"workers",a.workers,b.workers,false)
    return list[:]
}

// ---------------------------------------------------------------- export

@(private)
api_profile_export :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Profile_Export_Params)
    c:=api_profile_get(s,call,p.id)
    if c==nil {return}
    path,native:=project.path_native(base.text_get(p.path[:]))
    if !native {api.call_failf(call,api.INVALID_PARAMS,"%s: %s",path,document_error_text(.Bad_Path));return}
    if path=="" {
        if !s.has_project {api.call_fail(call,api.INVALID_PARAMS,"Without a project there is no .mirai folder: pass path");return}
        folder:=project.path(project.folder_path(s.project_root,.Generated,context.temp_allocator),"profiles",allocator=context.temp_allocator)
        if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {api.call_failf(call,api.SERVER_ERROR,"%s could not be made",folder);return}
        path=project.path(folder,fmt.tprintf("profile-%d.json",c.id),allocator=context.temp_allocator)
    }
    text,events:=profile_trace(c)
    if os.write_entire_file(path,transmute([]u8)text)!=nil {api.call_failf(call,api.SERVER_ERROR,"%s could not be written",path);return}
    r:=api.call_result(call,Api_Profile_Export)
    r.id,r.events,r.bytes=c.id,events,len(text)
    base.text_set(r.path[:],path)
}

// The capture in the Trace Event Format: a complete event per zone, a thread
// per ring, and counters with the time of each frame and of the GPU.
profile_trace :: proc(c:^Profile_Capture) -> (text:string,events:int) {
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,`{"displayTimeUnit":"ms","traceEvents":[`)
    first:=true
    event :: proc(b:^strings.Builder,first:^bool) {
        if !first^ {strings.write_byte(b,',')}
        first^=false
        strings.write_byte(b,'\n')
    }
    for thread in 0..<max(c.threads,1) {
        event(&b,&first)
        fmt.sbprintf(&b,`{{"name":"thread_name","ph":"M","pid":1,"tid":%d,"args":{{"name":"%s"}}}}`,thread,thread==0?"main":fmt.tprintf("worker %d",thread))
        events+=1
    }
    for f,i in c.frames {
        event(&b,&first)
        fmt.sbprintf(&b,`{{"name":"frame %d","ph":"X","pid":1,"tid":0,"ts":%.3f,"dur":%.3f}}`,i,f64(f.start_ns)/1e3,f64(f.ns)/1e3)
        event(&b,&first)
        fmt.sbprintf(&b,`{{"name":"ms","ph":"C","pid":1,"ts":%.3f,"args":{{"frame":%.3f,"gpu":%.3f,"wait":%.3f}}}}`,f64(f.start_ns)/1e3,profile_frame_ms(f),f64(f.gpu_ms),f64(f.wait_ms))
        events+=2
    }
    for zone in c.zones {
        event(&b,&first)
        strings.write_string(&b,`{"name":`)
        strings.write_string(&b,serial.text_quote(c.names[zone.name]))
        fmt.sbprintf(&b,`,"ph":"X","pid":1,"tid":%d,"ts":%.3f,"dur":%.3f}}`,zone.thread,f64(zone.start_ns)/1e3,f64(zone.ns)/1e3)
        events+=1
    }
    strings.write_string(&b,"\n]}\n")
    return strings.to_string(b),events
}
