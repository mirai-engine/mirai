package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"

@(private="file")
CAMERAS :: `{"size":[1440,900],"frames":600,"views":[
    {"name":"wide","scene":"raft/raft.scene","position":[9,5,14],"target":[0,0,0],"fov":60,"threshold":0.99},
    {"name":"under","scene":"raft/raft.scene","position":[3,-2.5,9],"target":[0,-0.5,0],"threshold":0.99},
    {"name":"opening","scene":"raft/raft.scene","threshold":0.99},
    {"name":"night","scene":"lights/night.scene","position":[0,1,2],"target":[0,0,0],"threshold":0.99}]}`

@(private="file")
cameras_of :: proc(t:^testing.T) -> (cameras:Capture_Views) {
    folder:=base.test_folder(t,"flight-cameras")
    if folder=="" {return}
    testing.expect(t,os.write_entire_file(strings.concatenate({folder,"/",CAPTURE_PLAN_FILE}),transmute([]u8)string(CAMERAS))==nil)
    problem:string
    cameras,problem=capture_views_load(folder)
    testing.expect_value(t,problem,"")
    return
}

// The named cameras: a name picks one view, and one missing names those there are.
@(test)
named_cameras_are_views_of_the_capture_plan :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    cameras:=cameras_of(t)
    view,problem:=capture_view_find(cameras,"under")
    testing.expect_value(t,problem,"")
    testing.expect_value(t,view.position[1],-2.5)
    _,problem=capture_view_find(cameras,"over")
    testing.expect(t,strings.contains(problem,"no view 'over'") && strings.contains(problem,"wide, under, opening, night"),problem)
    twice:Capture_Views
    problem=capture_views_parse(`{"views":[{"name":"a","scene":"s.scene","threshold":0.9},{"name":"a","scene":"t.scene","threshold":0.9}]}`,&twice)
    testing.expect(t,strings.contains(problem,"two views are named 'a'"),problem)
}

// What a flight file says, and each mistake with what to fix.
@(test)
a_flight_file_is_checked_with_what_to_fix :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    cameras:=cameras_of(t)
    Case :: struct {text,problem:string}
    cases:=[]Case{
        {`{"scene":"raft/raft.scene","segments":[{"camera":"wide","settle":600},{"frames":120},{"keys":["w","Left_Shift"],"turn":[0.5,0],"frames":300},{"position":[1,2,3],"target":[0,2,0],"fov":70,"frames":10}]}`,""},
        {`{"scene":"raft/raft.scene","segments":[{"camera":"wide","settle":10}],"speed":2}`,"speed"},
        {`{"segments":[{"camera":"wide","settle":10}]}`,"has no scene"},
        {`{"scene":"raft/raft.scene","segments":[]}`,"has no segments"},
        {`{"scene":"raft/raft.scene","segments":[{"camera":"wide"}]}`,"segment 1: give it frames"},
        {`{"scene":"raft/raft.scene","segments":[{"camera":"wide","frames":10,"settle":10}]}`,"segment 1: give it frames"},
        {`{"scene":"raft/raft.scene","segments":[{"camera":"wide","frames":-1}]}`,"above 0"},
        {`{"scene":"raft/raft.scene","segments":[{"camera":"wide","frames":40000}]}`,"36000 frames at most"},
        {`{"scene":"raft/raft.scene","segments":[{"camera":"wide","settle":10,"keys":["W"]}]}`,"settle waits with the camera still"},
        {`{"scene":"raft/raft.scene","segments":[{"camera":"wide","position":[1,2,3],"target":[0,0,0],"frames":1}]}`,"camera or position and target, not both"},
        {`{"scene":"raft/raft.scene","segments":[{"position":[1,2,3],"frames":1}]}`,"go together"},
        {`{"scene":"raft/raft.scene","segments":[{"camera":"wide","frames":1},{"fov":50,"frames":1}]}`,"segment 2: fov goes with position and target"},
        {`{"scene":"raft/raft.scene","segments":[{"position":[1,2,3],"target":[0,0,0],"fov":200,"frames":1}]}`,"above 0 up to 170"},
        {`{"scene":"raft/raft.scene","segments":[{"frames":1}]}`,"segment 1 places the camera"},
        {`{"scene":"raft/raft.scene","segments":[{"position":[1,2,3],"target":[1,2,3],"frames":1}]}`,"the same point"},
        {`{"scene":"raft/raft.scene","segments":[{"camera":"wide","keys":["Shift"],"frames":1}]}`,"'Shift' is not a key"},
        {`{"scene":"raft/raft.scene","segments":[{"camera":"far","frames":1}]}`,"no view 'far'"},
        {`{"scene":"raft/raft.scene","segments":[{"camera":"night","frames":1}]}`,"is a view of lights/night.scene, and the flight flies raft/raft.scene"},
        {`{"scene":"raft/raft.scene","segments":[{"camera":"opening","frames":1}]}`,"has no position"},
    }
    for c in cases {
        _,problem:=flight_parse(c.text,"f.mirai",cameras,"")
        if c.problem=="" {testing.expectf(t,problem=="","%s: %s",c.text,problem)}
        else {testing.expectf(t,strings.contains(problem,c.problem),"%s: %q is not in %q",c.text,c.problem,problem)}
    }
    flight,_:=flight_parse(cases[0].text,"f.mirai",cameras,"")
    testing.expect_value(t,flight.segments[0].fov,60)
    testing.expect_value(t,flight.segments[2].keys[0],"W")
    testing.expect_value(t,flight_label(flight.segments[2]),"fly W+Left_Shift, turn 0.5,0")
    _,problem:=flight_parse(`{"scene":"raft/raft.scene","segments":[{"camera":"wide","frames":1}]}`,"f.mirai",{},"demo/captures.mirai is missing")
    testing.expect(t,strings.contains(problem,"camera 'wide': demo/captures.mirai is missing"),problem)
}

@(test)
flight_options_name_the_flight_and_the_limit :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    o,problem:=flight_options({"demo","raft","--limit","50","--out","bin/x"})
    testing.expect_value(t,problem,"")
    testing.expect(t,o.folder=="demo" && o.flight=="raft" && o.limit==50 && o.out=="bin/x" && !o.release,fmt.tprint(o))
    o,problem=flight_options({"raft","--release"})
    testing.expect(t,problem=="" && o.folder=="." && o.release,problem)
    Case :: struct {args:[]string,problem:string}
    for c in ([]Case{{{},"name the flight"},{{"a","b","c"},"one too many"},{{"a","--limit","0"},"above 0"},{{"a","--limit"},"needs a value"},{{"a","--fast"},"no option --fast"}}) {
        _,problem=flight_options(c.args)
        testing.expectf(t,strings.contains(problem,c.problem),"%v: %q",c.args,problem)
    }
}

// A frame with its time, its GPU and its costliest pass and part.
@(private="file")
frame_of :: proc(ms:f64,gpu:=0.0,bound:="Gpu",pass:="resolve",part:="render") -> Flight_Frame {
    gpu:=gpu if gpu>0 else ms*0.8
    passes:=make([]Flight_Pass,2,context.temp_allocator)
    passes[0],passes[1]={"tonemap",0.1},{pass,gpu*0.5}
    zones:=make([]Flight_Zone,2,context.temp_allocator)
    zones[0],zones[1]={"editor",1,0.2},{part,1,ms*0.6}
    return {ms=ms,cpu_ms=ms*0.7,wait_ms=ms*0.1,gpu_ms=gpu,gpu_measured=true,bound=bound,zones=zones,gpu=passes}
}

// The figures of the report on recorded frames: means, the nearest-rank p95,
// the counts over each threshold, where they fall after the jumps, the
// slowest, the means of the passes over the captures and the first over a limit.
@(test)
the_report_counts_hitches_by_frames_after_a_jump :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    run:Flight_Run
    // Segment 1 jumps and settles in 4 frames; segment 2 flies on; segment 3 jumps again.
    times:=[]f64{120,40,20,10, 10,10,10,10,10,10,10,10,10,10,60, 10,55,10}
    for ms in times {append(&run.frames,frame_of(ms))}
    run.frames[1].gpu_measured=false
    append(&run.segments,Flight_Done{first=0,count=4,jumped=true,settle=100,settled=2},Flight_Done{first=4,count=11},Flight_Done{first=15,count=3,jumped=true})

    s:=flight_stat(run.frames[:4])
    testing.expect_value(t,s.frames,4)
    testing.expect_value(t,s.mean,47.5)
    testing.expect_value(t,s.worst,120)
    testing.expect_value(t,s.p95,120)
    testing.expectf(t,abs(s.gpu-40)<1e-9,"gpu %f",s.gpu)
    testing.expect_value(t,s.over,[4]int{3,2,1,1})
    ten:=make([]Flight_Frame,20,context.temp_allocator)
    for &f,i in ten {f=frame_of(f64(i+1))}
    testing.expect_value(t,flight_stat(ten).p95,19)

    testing.expect_value(t,flight_since(run.segments[:],3),3)
    testing.expect_value(t,flight_since(run.segments[:],14),14)
    testing.expect_value(t,flight_since(run.segments[:],16),1)
    testing.expect_value(t,flight_segment_of(run.segments[:],14),1)
    testing.expect_value(t,flight_bucket(9),0)
    testing.expect_value(t,flight_bucket(10),1)
    testing.expect_value(t,flight_bucket(100),2)
    counts:=flight_buckets(run)
    testing.expect_value(t,counts[0],[4]int{4,3,2,1}) // 120 and 40 and 20 after the first jump, 55 after the second
    testing.expect_value(t,counts[1],[4]int{1,1,1,0}) // 60, 14 frames after the first jump
    testing.expect_value(t,counts[2],[4]int{})

    worst:=flight_worst(run.frames[:],3)
    testing.expect(t,len(worst)==3 && worst[0]==0 && worst[1]==14 && worst[2]==16,fmt.tprint(worst))
    testing.expect_value(t,flight_over(run.frames[:],4,50),14)
    testing.expect_value(t,flight_over(run.frames[:],4,0),-1)
    testing.expect_value(t,flight_over(run.frames[:],15,60),-1)

    chunks:=[]Flight_Chunk{{frames=10,gpu={{"resolve",2},{"shadows",1}}},{frames=30,gpu={{"resolve",4}}}}
    means:=flight_passes(chunks)
    testing.expect(t,len(means)==2 && means[0].name=="resolve" && means[0].mean_ms==3.5 && means[1].mean_ms==0.25,fmt.tprint(means))

    cause:=flight_cause(frame_of(100,40,"Cpu","glass reflect","render"))
    testing.expect(t,strings.contains(cause,"bound by the cpu") && strings.contains(cause,"glass reflect (20.0 ms of 40.0") && strings.contains(cause,"render (60.0 ms"),cause)

    run.project,run.flight,run.scene,run.commit="demo","demo/tests/flights/raft.mirai","raft/raft.scene","abc"
    run.segments[0].label="settle"
    table:=flight_markdown(run)
    for text in ([]string{"flight `raft`","| 1 settle | 4 | 47.5 | 120.0 | 120.0 |","| 0-9 | 4 | 3 | 2 | 1 |","| 10-99 | 1 | 1 | 1 | 0 |","| 100 or more |"}) {
        testing.expectf(t,strings.contains(table,text),"%q is not in:\n%s",text,table)
    }
}

// The log of an editor the watchdog ended names the pass the GPU stopped in,
// or the last its frame recorded; any other end, the last line.
@(test)
an_editor_that_ended_says_why_from_its_log :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"flight-ended")
    if folder=="" {return}
    log:=strings.concatenate({folder,"/session.log"})
    Case :: struct {text,said:string,watchdog:bool}
    cases:=[]Case{
        {"loading\nrhi: GPU watchdog: frame 812 has not finished on the GPU 1520 ms after it was submitted (MIRAI_GPU_WATCHDOG_MS=1500); it stopped in glass reflect; the frame recorded the passes visibility, glass reflect; the process ends\n","stopped in glass reflect",true},
        {"rhi: GPU watchdog: frame 9 has not finished on the GPU 40 ms after it was submitted (MIRAI_GPU_WATCHDOG_MS=30); where it stopped is not known: the device marks no progress; the frame recorded the passes visibility, resolve; the process ends\n","stopped after resolve, the last pass",true},
        {"loading\nout of memory\n","ends with: out of memory",false},
        {"","is empty",false},
    }
    for c in cases {
        testing.expect(t,os.write_entire_file(log,transmute([]u8)c.text)==nil)
        said,watchdog:=flight_ended(log)
        testing.expectf(t,watchdog==c.watchdog && strings.contains(said,c.said),"%q is not in %q",c.said,said)
    }
}
