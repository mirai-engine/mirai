package editor

import "core:encoding/json"
import vmem "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
MS :: i64(1_000_000)

@(private="file")
zone_at :: proc(name:string,frame:u32,thread,depth:int,start,ns:i64) -> base.Profile_Zone {
    return {name=name,start=start,duration=ns,frame=frame,depth=u16(depth),thread=u16(thread)}
}

// Two frames as the recorder drains them: the main thread in the order its
// zones end, then the worker. The first frame takes 9 ms and 2 ms pass
// until the next; in the second the function a takes a_ms instead of 4.
@(private="file")
recording_fixture :: proc(a_ms:i64) -> host.Profile_Recording {
    zones:=make([dynamic]base.Profile_Zone,context.temp_allocator)
    frame_start:=[2]i64{1*MS,12*MS}
    a:=[2]i64{4*MS,a_ms*MS}
    for f in 0..<2 {
        t:=frame_start[f]
        number:=u32(5+f)
        editor:=a[f]+2*MS
        append(&zones,
            zone_at("job",number,0,3,t+2*MS,1*MS),
            zone_at("a",number,0,2,t+1*MS,a[f]),
            zone_at("b",number,0,2,t+1*MS+a[f]+MS/2,1*MS),
            zone_at("editor",number,0,1,t+MS/2,editor),
            zone_at("pacing",number,0,1,t+MS/2+editor,2*MS),
            zone_at("frame",number,0,0,t,editor+3*MS),
            zone_at("job",number,1,0,t+2*MS,2*MS),
        )
    }
    frames:=make([]host.Profile_Frame,2,context.temp_allocator)
    frames[0]={number=5,drawn=true,render_wait_ms=0.5,gpu_ms=3}
    frames[1]={number=6,drawn=true,render_wait_ms=0.5,gpu_ms=3}
    return {frames=frames,zones=zones[:],threads=2,complete=true}
}

@(private="file")
capture_fixture :: proc(c:^Profile_Capture,id:int,a_ms:i64,preset:="Ultra",manual:=false) -> bool {
    if vmem.arena_init_growing(&c.arena)!=nil {return false}
    c.id,c.requested,c.state=id,2,.Done
    context.allocator=vmem.arena_allocator(&c.arena)
    c.conditions={optimization="Speed",mode="Edit",preset=preset,window={800,600},render={800,600},workers=1,manual=manual}
    profile_build(c,recording_fixture(a_ms),nil)
    return true
}

@(test)
a_capture_keeps_each_zone_with_its_own_time_and_each_frame_with_its_waits :: proc(t:^testing.T) {
    c:Profile_Capture
    if !testing.expect(t,capture_fixture(&c,1,4)) {return}
    defer profile_capture_free(&c)

    testing.expect_value(t,len(c.frames),2)
    testing.expect_value(t,c.frames[0].ns,9*MS)
    testing.expect_value(t,c.frames[0].between_ns,2*MS)
    testing.expect_value(t,c.frames[0].pacing_ns,2*MS)
    testing.expect_value(t,c.frames[0].worker_ns,2*MS)
    testing.expect_value(t,c.frames[0].jobs,1)
    testing.expect_value(t,profile_frame_ms(c.frames[0]),11.0)
    testing.expect_value(t,profile_frame_bound(c.frames[0]),Profile_Bound.Cpu)
    testing.expect_value(t,profile_frame_cpu_ms(c.frames[0]),8.5)

    // The main zones of a frame come by start, the zone around before the ones inside.
    zones:=c.zones[c.frames[0].zone_first:][:c.frames[0].zone_count]
    testing.expect_value(t,len(zones),5)
    order:=[?]string{"editor","a","job","b","pacing"}
    for name,i in order {testing.expect_value(t,c.names[zones[i].name],name)}
    testing.expect_value(t,zones[1].self_ns,3*MS) // a without the job it ran
    testing.expect_value(t,zones[0].self_ns,1*MS) // editor without a and b
}

@(test)
the_summary_ranks_zones_by_their_own_time_and_reads_what_bounds_the_frames :: proc(t:^testing.T) {
    c:Profile_Capture
    if !testing.expect(t,capture_fixture(&c,1,12)) {return}
    defer profile_capture_free(&c)
    summary:=profile_summary(&c,4)

    testing.expect_value(t,summary.frame.count,2)
    testing.expect_value(t,summary.frame.max_ms,17.0)
    testing.expect_value(t,summary.frame.worst[0],1)
    testing.expect_value(t,summary.zones[0].name,"a")
    testing.expect_value(t,summary.zones[0].thread,"main")
    testing.expect_value(t,summary.zones[0].self_ms,7.0)   // (3+11)/2
    testing.expect_value(t,summary.zones[0].total_ms,8.0)  // (4+12)/2
    testing.expect_value(t,summary.zones[0].calls_per_frame,1.0)
    workers:=false
    for z in summary.zones {if z.name=="job" && z.thread=="workers" {workers=true}}
    testing.expect(t,workers,"the jobs of the workers are a zone of their own")
    parts:=map[string]bool{}
    defer delete(parts)
    for part in summary.parts {parts[part.name]=true}
    testing.expect(t,parts["editor"] && parts["pacing"] && parts["other"] && parts["between"],"the parts of the frame, what they leave and what runs between frames")
    testing.expect_value(t,summary.frame.bound.cpu,2)
    testing.expect_value(t,summary.workers.threads,1)
    testing.expect_value(t,summary.workers.busy_ms,2.0)
    testing.expect(t,len(summary.notes)>0,"two frames are too few for percentiles")
}

@(test)
frames_and_zones_answer_where_a_slow_frame_went :: proc(t:^testing.T) {
    c:Profile_Capture
    if !testing.expect(t,capture_fixture(&c,1,12)) {return}
    defer profile_capture_free(&c)
    // As the API calls them: what they answer lives until the end of the call.
    context.allocator=context.temp_allocator

    frame:=profile_frame_out(&c,1,2,0)
    testing.expect_value(t,frame.index,1)
    testing.expect_value(t,frame.ms,17.0)
    testing.expect_value(t,len(frame.zones),4)
    testing.expect_value(t,frame.hidden_zones,1) // the job, one level deeper than asked
    testing.expect_value(t,frame.zones[1].name,"a")
    testing.expect_value(t,frame.zones[1].start_ms,1.0)
    testing.expect_value(t,frame.zones[1].self_ms,11.0)

    detail,error:=profile_zone_detail(&c,"a","")
    testing.expect_value(t,error,"")
    testing.expect_value(t,detail.thread,"main")
    testing.expect_value(t,detail.calls,2)
    testing.expect_value(t,detail.total.max_ms,12.0)
    testing.expect_value(t,detail.parents[0].name,"editor")
    testing.expect_value(t,detail.children[0].name,"job")
    testing.expect_value(t,detail.worst_frames[0].index,1)

    detail,error=profile_zone_detail(&c,"job","workers")
    testing.expect_value(t,error,"")
    testing.expect_value(t,detail.thread,"workers")
    _,error=profile_zone_detail(&c,"jo","")
    testing.expect(t,strings.contains(error,"job"),"an unknown zone suggests the close names")
    _,error=profile_zone_detail(&c,"a","gpu")
    testing.expect(t,error!="")
}

@(test)
two_captures_compare_zone_by_zone_and_say_when_they_were_measured_apart :: proc(t:^testing.T) {
    before,after,other:Profile_Capture
    if !testing.expect(t,capture_fixture(&before,1,12)) {return}
    defer profile_capture_free(&before)
    if !testing.expect(t,capture_fixture(&after,2,4)) {return}
    defer profile_capture_free(&after)
    if !testing.expect(t,capture_fixture(&other,3,4,"Low")) {return}
    defer profile_capture_free(&other)

    result:=profile_compare(&before,&after,8)
    testing.expect(t,result.comparable,"same conditions")
    testing.expect_value(t,len(result.differences),0)
    testing.expect_value(t,result.zones[0].name,"a")
    testing.expect_value(t,result.zones[0].delta_ms,-4.0) // own time 7 -> 3
    testing.expect_value(t,result.mean_ms.delta,-4.0)
    testing.expect(t,result.mean_ms.delta_pct<0)

    result=profile_compare(&after,&other,8)
    testing.expect(t,!result.comparable,"another preset changes the times by itself")
    testing.expect_value(t,result.differences[0].field,"preset")
    testing.expect(t,len(result.notes)>0)
}

// A window paces its frames as the graphics settings say and a headless
// editor paces none; validation inflates both. The refusal says how to lift each.
@(test)
a_capture_refuses_what_keeps_the_frame_time_from_being_the_cost :: proc(t:^testing.T) {
    testing.expect_value(t,profile_limits({vsync=true,frame_limit=60}),Profile_Limits{.Vsync,.Frame_Limit})
    testing.expect_value(t,profile_limits({headless=true,vsync=true,frame_limit=60}),Profile_Limits{})
    testing.expect_value(t,profile_limits({headless=true,validation=true}),Profile_Limits{.Validation})
    refusal:=profile_refusal({.Vsync,.Frame_Limit,.Validation})
    testing.expect(t,strings.contains(refusal,`{"option":"VSync","choice":0}`),refusal)
    testing.expect(t,strings.contains(refusal,`{"option":"Frame limit","choice":5}`),refusal) // Off
    testing.expect(t,strings.contains(refusal,"--validation"),refusal)
    testing.expect(t,strings.contains(refusal,"allow_limited"),refusal)
    testing.expect_value(t,profile_refusal({}),"")
}

// What was measured with limits anyway says so, and so does a comparison with it.
@(test)
a_capture_measured_with_limits_is_not_comparable :: proc(t:^testing.T) {
    free,limited,other:Profile_Capture
    if !testing.expect(t,capture_fixture(&free,1,4)) {return}
    defer profile_capture_free(&free)
    if !testing.expect(t,capture_fixture(&limited,2,4)) {return}
    defer profile_capture_free(&limited)
    if !testing.expect(t,capture_fixture(&other,3,4)) {return}
    defer profile_capture_free(&other)
    limited.conditions.vsync,other.conditions.vsync=true,true

    testing.expect(t,profile_summary(&free,4).comparable)
    testing.expect(t,!profile_summary(&limited,4).comparable)
    result:=profile_compare(&limited,&other,8)
    testing.expect_value(t,len(result.differences),0)
    testing.expect(t,!result.comparable,"both waited for the display")
    testing.expect(t,strings.contains(strings.join(result.notes,"\n",context.temp_allocator),"allow_limited"))
    testing.expect(t,profile_compare(&free,&free,8).comparable)
}

@(test)
a_capture_exports_as_a_trace_event_file :: proc(t:^testing.T) {
    c:Profile_Capture
    if !testing.expect(t,capture_fixture(&c,1,4)) {return}
    defer profile_capture_free(&c)
    text,events:=profile_trace(&c)
    // Two thread names, two events per frame and every zone that is not a frame.
    testing.expect_value(t,events,2+2*2+len(c.zones))
    testing.expect(t,strings.contains(text,`"name":"a","ph":"X","pid":1,"tid":0`))
    testing.expect(t,strings.contains(text,`"args":{"name":"worker 1"}`))
    testing.expect(t,strings.has_suffix(text,"]}\n"))
}

@(test)
a_manual_editor_leaves_the_wait_between_frames_out :: proc(t:^testing.T) {
    c:Profile_Capture
    if !testing.expect(t,capture_fixture(&c,1,4,manual=true)) {return}
    defer profile_capture_free(&c)
    testing.expect_value(t,c.frames[0].between_ns,i64(0))
    testing.expect_value(t,profile_frame_ms(c.frames[0]),9.0)
}

// Frames back to back after the last, or after a pause of after_ms, of ms
// each, the GPU taking gpu_ms (ms when negative).
@(private="file")
frames_add :: proc(samples:^[dynamic]Profile_Sample,count:int,ms:f32,gpu_ms:=f32(-1),after_ms:=f32(0)) {
    end:=len(samples)>0?samples[len(samples)-1].end._nsec:0
    end+=i64(after_ms*f32(MS))
    for _ in 0..<count {
        end+=i64(ms*f32(MS))
        append(samples,Profile_Sample{end={end},ms=ms,gpu_ms=gpu_ms<0?ms:gpu_ms})
    }
}

@(private="file")
tick_after :: proc(samples:[]Profile_Sample,ms:i64) -> time.Tick {return {samples[len(samples)-1].end._nsec+ms*MS}}

@(test)
a_capture_records_once_the_frames_that_ran_back_to_back_stop_getting_faster :: proc(t:^testing.T) {
    samples:=make([dynamic]Profile_Sample,context.temp_allocator)
    frames_add(&samples,100,4.5)
    testing.expect(t,!profile_settled(samples[:],tick_after(samples[:],1)),"less than a span ran")

    // A GPU that idled: its clock rises in the middle of the span.
    clear(&samples)
    frames_add(&samples,100,6)
    frames_add(&samples,90,4.5)
    testing.expect(t,!profile_settled(samples[:],tick_after(samples[:],1)),"the later half is faster")
    frames_add(&samples,200,4.5)
    testing.expect(t,profile_settled(samples[:],tick_after(samples[:],1)))
    testing.expect(t,!profile_settled(samples[:],tick_after(samples[:],600)),"no frame ran for longer than the gap")

    // Frames paced to the display that the GPU draws faster as its clock rises.
    clear(&samples)
    frames_add(&samples,30,16.7,9)
    frames_add(&samples,31,16.7,4.5)
    testing.expect(t,!profile_settled(samples[:],tick_after(samples[:],1)),"the GPU got faster")

    // Frames that get slower are measured as they are.
    clear(&samples)
    frames_add(&samples,120,4.5)
    frames_add(&samples,120,6)
    testing.expect(t,profile_settled(samples[:],tick_after(samples[:],1)))

    // Those before a pause do not count.
    clear(&samples)
    frames_add(&samples,300,4.5)
    frames_add(&samples,50,4.5,after_ms=600)
    testing.expect(t,!profile_settled(samples[:],tick_after(samples[:],1)),"a pause cut the frames")

    // Frames faster than PROFILE_RECENT fill the span settle on all of them.
    clear(&samples)
    frames_add(&samples,PROFILE_RECENT,0.5)
    testing.expect(t,profile_settled(samples[:],tick_after(samples[:],1)))
}

@(test)
answers_cut_their_fractions_to_the_microsecond_outside_strings :: proc(t:^testing.T) {
    text:=json_numbers_short(`{"a":40.4990000000000023,"b":"x 1.5555","c":1.00000000,"d":-0.0001,"e":3,"f":[0.1250000000000001,-2]}`,context.temp_allocator)
    testing.expect_value(t,text,`{"a":40.499,"b":"x 1.5555","c":1,"d":0,"e":3,"f":[0.125,-2]}`)
}

@(private="file")
profile_answer_expect :: proc(t:^testing.T,s:^Session,run:Api_Handler,params:rawptr,params_id,shape:typeid,loc:=#caller_location) {
    method:=api.Method{params_id=params_id}
    w:serial.Writer
    serial.writer_init(&w,0,context.temp_allocator)
    call:=api.Call{method=&method,params=params,out=&w,allocator=context.temp_allocator}
    run(s,&call)
    if !testing.expectf(t,!call.failed,"%s",call.error.message,loc=loc) {return}
    api_result_shape_expect(t,string(serial.writer_bytes(&w)),shape,loc)
}

// What the profile methods write has the keys and the values their results
// declare, of a capture without frames too.
@(test)
the_answers_of_the_profile_methods_have_the_shape_they_declare :: proc(t:^testing.T) {
    s:Session
    defer for &c in s.profiles.captures {profile_capture_free(&c)}
    if !testing.expect(t,capture_fixture(&s.profiles.captures[0],1,4)) {return}
    if !testing.expect(t,capture_fixture(&s.profiles.captures[1],2,12,"Low")) {return}
    empty:=&s.profiles.captures[2]
    if !testing.expect(t,vmem.arena_init_growing(&empty.arena)==nil) {return}
    empty.id,empty.requested,empty.state,empty.conditions=3,5,.Stopped,{optimization="Speed",mode="Edit"}

    for id in 1..=3 {
        summary:=Api_Profile_Id_Params{id=id,top=12}
        profile_answer_expect(t,&s,api_profile_summary,&summary,Api_Profile_Id_Params,Api_Profile_Summary)
    }
    recording,_:=json.marshal(Profile_Recording_Out{4,"lab","Recording",120},allocator=context.temp_allocator)
    api_result_shape_expect(t,string(recording),Api_Profile_Summary)
    profile_answer_expect(t,&s,api_profile_list,nil,nil,Api_Profile_List)
    worst:=Api_Profile_Frames_Params{id=2,worst=5,first=-1,count=1,depth=3,min_ms=0.02}
    profile_answer_expect(t,&s,api_profile_frames,&worst,Api_Profile_Frames_Params,Api_Profile_Frames)
    span:=Api_Profile_Frames_Params{id=1,first=0,count=2,depth=1}
    profile_answer_expect(t,&s,api_profile_frames,&span,Api_Profile_Frames_Params,Api_Profile_Frames)
    for thread in ([]string{"main","workers"}) {
        zone:=Api_Profile_Zone_Params{id=2}
        base.text_set(zone.name[:],"job")
        base.text_set(zone.thread[:],thread)
        profile_answer_expect(t,&s,api_profile_zone,&zone,Api_Profile_Zone_Params,Api_Profile_Zone_Detail)
    }
    compare:=Api_Profile_Compare_Params{base=1,id=2,top=12}
    profile_answer_expect(t,&s,api_profile_compare,&compare,Api_Profile_Compare_Params,Api_Profile_Compare)

    // A load still waiting, and one that ended, with what it counted.
    app:host.App
    s.app=&app
    defer host.load_profile_destroy(&app)
    host.load_open(&app,.Play,"scenes/lab.scene")
    host.load_phase_add(&app,.World_Copy,4e6,12)
    host.load_phase_add(&app,.Nav_Tiles,9e6,3)
    host.load_asset_done(&app.load_profile,{1,2},.Mesh,1<<20,2e6,5e6,false)
    host.load_ready(&app,.Play,12)
    host.load_profile_frame(&app,true)
    load:=Api_Profile_Load_Params{top=8}
    profile_answer_expect(t,&s,api_profile_load,&load,Api_Profile_Load_Params,Api_Profile_Loads)
    host.load_profile_frame(&app,true)
    load.kind=.Play
    profile_answer_expect(t,&s,api_profile_load,&load,Api_Profile_Load_Params,Api_Profile_Loads)
}
