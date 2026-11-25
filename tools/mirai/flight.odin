package main

import "core:fmt"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:cook/workspace"
import "mirai:editor/api"
import "mirai:project"
import "mirai:rhi"
import "mirai:std/input"
import "mirai:std/serial"
import "mirai:std/subprocess"

BENCH_FLIGHT_USAGE :: "bench flight [project] <flight> [--limit MS] [--out folder] [--release]"

// mirai bench flight: flies the camera of the editor through a scene of a
// copy of the project as a flight file says, in a headless editor of its own
// with its GPU turn and under the GPU watchdog, alone among the checkouts, and
// says whether and where its frames hitch: the frame, the GPU and the CPU of
// each segment, the frames over each of FLIGHT_THRESHOLDS and how many frames
// after a jump they fall, the slowest frames with their passes, the frames a
// view takes to settle and the shadows and what is pending at the end of each
// segment. A flight is named by its name in FLIGHT_FOLDER or by its path; its
// cameras are views of CAPTURE_PLAN_FILE, at whose size it flies. Every frame
// is recorded, in captures of FLIGHT_CHUNK frames read back after each.
// Exit 1 when a frame of a segment that does not settle takes longer than
// --limit, which stops the flight there, and rhi.WATCHDOG_EXIT_CODE when the
// watchdog ended the editor, with the pass it stopped in. The table goes to
// stdout and, with the frames, to --out.

FLIGHT_FOLDER :: "tests/flights"
FLIGHT_EXTENSION :: ".mirai"
FLIGHT_FRAMES_MAX :: 36000 // of a segment
FLIGHT_CHUNK :: 100        // frames of a capture while flying or still; editor.input takes them in one call
FLIGHT_SETTLE_CHUNK :: 10  // frames between two looks at what is pending while a view settles
FLIGHT_PAGE :: 16          // frames profile.frames gives at once
FLIGHT_TOP :: 64           // passes of a summary
FLIGHT_THRESHOLDS :: [?]f64{16.7,33.3,50,100} // ms: 60 fps, 30 fps and two sizes of hitch
FLIGHT_SINCE :: [?]int{10,100} // frames since a jump where the counts split: 0-9, 10-99 and 100 or more
FLIGHT_WORST :: 10
FLIGHT_PASSES :: 12        // in the table of the passes
FLIGHT_FRAME_PASSES :: 3   // of a slowest frame
FLIGHT_TIMEOUT_MS :: 600000
FLIGHT_WATCHDOG :: "rhi: GPU watchdog:"

// A flight as its file holds it; the first segment places the camera.
Flight :: struct {
    scene:string, // relative to the assets folder of the project
    segments:[]Flight_Segment,
}

// A jump, or none, then frames: still, flying with the right button held, or
// still until the view settles.
Flight_Segment :: struct {
    camera:string,         // a view of CAPTURE_PLAN_FILE the camera jumps to
    position,target:[]f64, // or the pose it jumps to
    fov:f64,               // degrees, vertical, with the pose; 0 keeps that of the editor
    frames:int,            // the frames it runs
    settle:int,            // or the most it runs still until nothing is pending and no shadow page waits
    keys:[]string,         // held all along, with the right button: W A S D Q E, Left_Shift...
    turn:[2]f64,           // mouse_delta of each frame, points
}

Flight_Zone :: struct {name:string,depth:int,ms:f64}
Flight_Pass :: struct {name:string,ms:f64}
Flight_Mean :: struct {name:string,mean_ms:f64}

// A frame as profile.frames gives it, with the parts of the frame.
Flight_Frame :: struct {
    ms,cpu_ms,wait_ms,gpu_ms:f64,
    gpu_measured:bool,
    bound:string,
    zones:[]Flight_Zone,
    gpu:[]Flight_Pass, // its costliest passes
}

// What engine.status says at the end of a segment.
Flight_Status :: struct {
    pending:struct {programs,pipelines,assets:int},
    shadow_maps:struct {pages_drawn,pages_asked,pages_waiting:int},
    validation_errors:int,
    renderer_problem:string,
}

// A segment as it flew.
Flight_Done :: struct {
    label:string,
    first,count:int, // its frames in the flight
    jumped:bool,
    settle:int,      // the most frames it waited to settle; 0: it did not settle
    settled:int,     // frames until nothing was pending, at two looks in a row; -1: not within settle
    status:Flight_Status,
}

// A capture: its frames and the mean of its passes.
Flight_Chunk :: struct {
    frames:int,
    gpu:[]Flight_Mean,
}

Flight_Run :: struct {
    project,flight,scene,commit,device,date:string,
    size:[2]int,
    release:bool,
    limit:f64, // ms; 0: none
    segments:[dynamic]Flight_Done,
    frames:[dynamic]Flight_Frame,
    chunks:[dynamic]Flight_Chunk,
    stopped:string, // why it ended before its last frame
    warnings:[dynamic]string,
}

Flight_Options :: struct {
    folder,flight,out:string,
    limit:f64,
    release:bool,
}

// The options of mirai bench flight; problem says what is wrong with them.
flight_options :: proc(args:[]string) -> (o:Flight_Options,problem:string) {
    o.folder="."
    named:=make([dynamic]string,context.temp_allocator)
    for i:=0;i<len(args);i+=1 {
        option:=args[i]
        if positional(option) {append(&named,option);continue}
        switch option {
        case "--release": o.release=true;continue
        case "--limit","--out":
        case: return o,fmt.tprintf("there is no option %s",option)
        }
        if i+1>=len(args) || args[i+1]=="" {return o,fmt.tprintf("%s needs a value",option)}
        i+=1
        if option=="--out" {o.out=args[i];continue}
        limit,ok:=strconv.parse_f64(args[i])
        if !ok || !(limit>0) {return o,fmt.tprintf("--limit is the milliseconds a frame may take, above 0, not '%s'",args[i])}
        o.limit=limit
    }
    switch len(named) {
    case 0: return o,"name the flight: a name of tests/flights of the project or the path of its file"
    case 1: o.flight=named[0]
    case 2: o.folder,o.flight=named[0],named[1]
    case: return o,fmt.tprintf("'%s' is one too many: a project and a flight",named[2])
    }
    return o,""
}

// The file of a flight: a name of FLIGHT_FOLDER, with or without its extension, or a path.
flight_file :: proc(folder,name:string) -> (path,problem:string) {
    path=name
    if !strings.contains_any(name,"/\\") {
        file:=strings.has_suffix(name,FLIGHT_EXTENSION)?name:strings.concatenate({name,FLIGHT_EXTENSION},context.temp_allocator)
        path=project.path(folder,FLIGHT_FOLDER,file,allocator=context.temp_allocator)
    }
    path=project.path_absolute(path,context.temp_allocator)
    path,_=strings.replace_all(path,"\\","/",context.temp_allocator)
    if !os.is_file(path) {return "",fmt.tprintf("%s: %s is not there; a flight is a name of %s of the project or the path of its file",name,path,FLIGHT_FOLDER)}
    return path,""
}

// The flight in text with its cameras resolved: those of cameras, or
// cameras_problem when the project has none to read. problem says what is
// wrong and how to fix it.
flight_parse :: proc(text,path:string,cameras:Capture_Views,cameras_problem:string) -> (flight:Flight,problem:string) {
    if decoded:=serial.text_decode(text,&flight);decoded!="" {return flight,fmt.tprintf(`%s: %s: a flight is {"scene": "<scene>", "segments": [...]}`,path,decoded)}
    if flight.scene=="" {return flight,fmt.tprintf("%s has no scene: name the .scene it flies, relative to the assets folder",path)}
    if len(flight.segments)==0 {return flight,fmt.tprintf("%s has no segments: each one jumps the camera or not, then runs frames or settles",path)}
    keys:=reflect.enum_field_names(input.Key)
    for &s,i in flight.segments {
        at:=fmt.tprintf("%s: segment %d",path,i+1)
        posed:=len(s.position)>0 || len(s.target)>0
        switch {
        case s.frames<0 || s.settle<0:
            return flight,fmt.tprintf("%s: frames and settle count frames: above 0",at)
        case (s.frames>0)==(s.settle>0):
            return flight,fmt.tprintf("%s: give it frames, the frames it runs, or settle, the most frames it waits still for nothing to be pending; one of the two",at)
        case max(s.frames,s.settle)>FLIGHT_FRAMES_MAX:
            return flight,fmt.tprintf("%s: %d frames at most; split a longer one in segments",at,FLIGHT_FRAMES_MAX)
        case s.settle>0 && (len(s.keys)>0 || s.turn!={}):
            return flight,fmt.tprintf("%s: settle waits with the camera still: fly in a segment of its own, with frames",at)
        case s.camera!="" && (posed || s.fov!=0):
            return flight,fmt.tprintf("%s: camera or position and target, not both: camera takes the pose and the fov of its view",at)
        case posed && (len(s.position)!=3 || len(s.target)!=3):
            return flight,fmt.tprintf("%s: position and target go together, three numbers each",at)
        case !posed && s.fov!=0:
            return flight,fmt.tprintf("%s: fov goes with position and target",at)
        case s.fov<0 || s.fov>170:
            return flight,fmt.tprintf("%s: fov is the vertical field of view in degrees, above 0 up to 170",at)
        case i==0 && s.camera=="" && !posed:
            return flight,fmt.tprintf("%s places the camera: give it camera, a view of %s, or position and target, so that every run starts from the same view",at,CAPTURE_PLAN_FILE)
        case posed && s.position[0]==s.target[0] && s.position[1]==s.target[1] && s.position[2]==s.target[2]:
            return flight,fmt.tprintf("%s: position and target are the same point: target is where the camera looks",at)
        }
        for &key in s.keys {
            found:=false
            for name in keys {
                if strings.equal_fold(name,key) {key,found=name,true;break}
            }
            if !found {return flight,fmt.tprintf("%s: '%s' is not a key; keys are named as std/input names them: W, A, S, D, Q, E, Left_Shift, Space...",at,key)}
        }
        if s.camera=="" {continue}
        if cameras_problem!="" {return flight,fmt.tprintf("%s: camera '%s': %s",at,s.camera,cameras_problem)}
        view,missing:=capture_view_find(cameras,s.camera)
        switch {
        case missing!="":
            return flight,fmt.tprintf("%s: %s",at,missing)
        case view.scene!=flight.scene:
            return flight,fmt.tprintf("%s: camera '%s' is a view of %s, and the flight flies %s: a flight stays in its scene",at,s.camera,view.scene,flight.scene)
        case len(view.position)!=3:
            return flight,fmt.tprintf("%s: camera '%s' has no position in %s: a flight jumps only to views with a position and a target",at,s.camera,cameras.path)
        }
        s.position,s.target,s.fov=view.position,view.target,view.fov
    }
    return flight,""
}

// What a segment does, for the table.
flight_label :: proc(s:Flight_Segment) -> string {
    b:=strings.builder_make(context.temp_allocator)
    switch {
    case s.camera!="":        fmt.sbprintf(&b,"at `%s`: ",s.camera)
    case len(s.position)==3:  fmt.sbprintf(&b,"at %g,%g,%g: ",s.position[0],s.position[1],s.position[2])
    }
    switch {
    case s.settle>0: strings.write_string(&b,"settle")
    case len(s.keys)>0 || s.turn!={}:
        strings.write_string(&b,"fly")
        if len(s.keys)>0 {fmt.sbprintf(&b," %s",strings.join(s.keys,"+",context.temp_allocator))}
        if s.turn!={} {fmt.sbprintf(&b,", turn %g,%g",s.turn.x,s.turn.y)}
    case: strings.write_string(&b,"still")
    }
    return strings.to_string(b)
}

// The figures of some frames: means over them, the GPU over those it measured.
Flight_Stat :: struct {
    frames:int,
    mean,p95,worst,gpu,cpu:f64,
    over:[len(FLIGHT_THRESHOLDS)]int,
}

flight_stat :: proc(frames:[]Flight_Frame) -> (s:Flight_Stat) {
    s.frames=len(frames)
    if s.frames==0 {return}
    times:=make([]f64,len(frames),context.temp_allocator)
    measured:=0
    thresholds:=FLIGHT_THRESHOLDS
    for f,i in frames {
        times[i]=f.ms
        s.mean+=f.ms
        s.cpu+=f.cpu_ms
        if f.gpu_measured {s.gpu+=f.gpu_ms;measured+=1}
        for limit,k in thresholds {if f.ms>limit {s.over[k]+=1}}
    }
    s.mean/=f64(s.frames)
    s.cpu/=f64(s.frames)
    if measured>0 {s.gpu/=f64(measured)}
    slice.sort(times)
    s.worst=times[len(times)-1]
    // The nearest rank: the time 95 % of the frames do not pass.
    rank:=(95*len(times)+99)/100
    s.p95=times[max(rank,1)-1]
    return
}

// The segment a frame of the flight belongs to; -1 outside them.
flight_segment_of :: proc(segments:[]Flight_Done,index:int) -> int {
    for s,i in segments {
        if index>=s.first && index<s.first+s.count {return i}
    }
    return -1
}

// Frames from the last jump at or before a frame to it; -1 with no jump before.
flight_since :: proc(segments:[]Flight_Done,index:int) -> int {
    since:=-1
    for s in segments {
        if s.first>index {break}
        if s.jumped {since=index-s.first}
    }
    return since
}

// Which part of FLIGHT_SINCE frames since a jump fall in.
flight_bucket :: proc(since:int) -> int {
    bounds:=FLIGHT_SINCE
    for bound,i in bounds {
        if since<bound {return i}
    }
    return len(bounds)
}

// The frames over each threshold, by how many frames after a jump they fall.
flight_buckets :: proc(run:Flight_Run) -> (counts:[len(FLIGHT_SINCE)+1][len(FLIGHT_THRESHOLDS)]int) {
    thresholds:=FLIGHT_THRESHOLDS
    for f,i in run.frames {
        since:=flight_since(run.segments[:],i)
        if since<0 {continue}
        for limit,k in thresholds {if f.ms>limit {counts[flight_bucket(since)][k]+=1}}
    }
    return
}

// The slowest frames, the slowest first.
flight_worst :: proc(frames:[]Flight_Frame,count:int) -> []int {
    Timed :: struct {index:int,ms:f64}
    timed:=make([]Timed,len(frames),context.temp_allocator)
    for f,i in frames {timed[i]={i,f.ms}}
    slice.sort_by(timed,proc(a,b:Timed) -> bool {return a.ms>b.ms || a.ms==b.ms && a.index<b.index})
    order:=make([]int,min(count,len(timed)),context.temp_allocator)
    for &index,i in order {index=timed[i].index}
    return order
}

// The mean of each pass over every frame of the captures, the costliest first.
flight_passes :: proc(chunks:[]Flight_Chunk) -> []Flight_Mean {
    total:=0
    sums:=make(map[string]f64,context.temp_allocator)
    for c in chunks {
        total+=c.frames
        for pass in c.gpu {sums[pass.name]+=pass.mean_ms*f64(c.frames)}
    }
    means:=make([dynamic]Flight_Mean,0,len(sums),context.temp_allocator)
    if total==0 {return means[:]}
    for name,sum in sums {append(&means,Flight_Mean{name,sum/f64(total)})}
    slice.sort_by(means[:],proc(a,b:Flight_Mean) -> bool {return a.mean_ms>b.mean_ms || a.mean_ms==b.mean_ms && a.name<b.name})
    return means[:]
}

// The first frame from first on that takes longer than limit; -1 when none does.
flight_over :: proc(frames:[]Flight_Frame,first:int,limit:f64) -> int {
    if limit<=0 {return -1}
    for f,i in frames[first:] {
        if f.ms>limit {return first+i}
    }
    return -1
}

// Where the time of a frame went: what it waited for, its costliest GPU pass
// and its costliest part of the CPU.
flight_cause :: proc(f:Flight_Frame) -> string {
    pass:Flight_Pass
    for p in f.gpu {if p.ms>pass.ms {pass=p}}
    part:Flight_Zone
    for z in f.zones {if z.depth==1 && z.ms>part.ms {part=z}}
    bound:=strings.to_lower(f.bound,context.temp_allocator)
    if bound=="" {bound="unknown"}
    return fmt.tprintf("bound by the %s; its costliest GPU pass is %s (%.1f ms of %.1f on the GPU) and its costliest part of the CPU %s (%.1f ms of %.1f)",
        bound,pass.name!=""?pass.name:"none",pass.ms,f.gpu_ms,part.name!=""?part.name:"none",part.ms,f.cpu_ms)
}

// What the log of an editor that ended says of why; watchdog: the GPU
// watchdog ended it, and said names the pass where the GPU stopped, or the
// last its frame recorded when the device does not mark where.
flight_ended :: proc(log:string) -> (said:string,watchdog:bool) {
    data,_:=os.read_entire_file(log,context.temp_allocator)
    last:=""
    for line in strings.split_lines(string(data),context.temp_allocator) {
        line:=strings.trim_space(line)
        if line=="" {continue}
        last=line
        if !strings.has_prefix(line,FLIGHT_WATCHDOG) {continue}
        place:="where is not known"
        if at:=strings.index(line,"; it stopped in ");at>=0 {
            rest:=line[at+len("; it stopped in "):]
            if end:=strings.index_byte(rest,';');end>=0 {rest=rest[:end]}
            place=fmt.tprintf("in %s",rest)
        } else if at:=strings.index(line,"; the frame recorded the passes ");at>=0 {
            rest:=line[at+len("; the frame recorded the passes "):]
            if end:=strings.index_byte(rest,';');end>=0 {rest=rest[:end]}
            if comma:=strings.last_index(rest,", ");comma>=0 {rest=rest[comma+2:]}
            place=fmt.tprintf("after %s, the last pass its frame recorded",rest)
        }
        return fmt.tprintf("the GPU watchdog ended the editor, the GPU stopped %s: %s",place,line),true
    }
    if last=="" {return fmt.tprintf("the editor ended and its log %s is empty",log),false}
    return fmt.tprintf("the editor ended; its log %s ends with: %s",log,last),false
}

// The headless editor that flies: its API, its process and its log.
@(private="file")
Flight_Editor :: struct {
    port,pid:int,
    log:string,
    center:[2]f64, // of the viewport, in points: where the pointer flies from
    flying:bool,   // the right button was held in the last frame
    code:int,      // exit code of what stopped the flight
}

// A frame of synthetic input; a mouse_position or a mouse_delta left out keeps
// the pointer, and the keys and buttons listed are those held.
@(private="file")
Flight_Event :: struct {
    mouse_position:[]f64 `mirai:"optional"`,
    mouse_buttons,keys:[]string,
    mouse_delta:[]f64 `mirai:"optional"`,
}

// One call; a failure stops the flight, saying why, and when the editor is
// gone, what its log said.
@(private="file")
flight_call :: proc(e:^Flight_Editor,run:^Flight_Run,method:string,params:any) -> (result:string,ok:bool) {
    text,_:=serial.text_encode(params,.Line,context.temp_allocator,sparse=true)
    response,err,called:=api.rpc_call(e.port,method,string(text),1,FLIGHT_TIMEOUT_MS,context.allocator)
    if called {return response,true}
    for at:=time.tick_now();subprocess.process_alive(e.pid) && time.tick_since(at)<3*time.Second; {time.sleep(100*time.Millisecond)}
    if subprocess.process_alive(e.pid) {
        run.stopped=fmt.aprintf("%s: %s",method,api.error_text(err,context.temp_allocator))
        e.code=1
        return "",false
    }
    said,watchdog:=flight_ended(e.log)
    run.stopped=fmt.aprintf("frame %d of the flight%s: %s",len(run.frames),flight_where(run^,len(run.frames)),said)
    e.code=watchdog?rhi.WATCHDOG_EXIT_CODE:1
    return "",false
}

// Of a frame, its segment and how far after the jump, for a message.
@(private="file")
flight_where :: proc(run:Flight_Run,index:int) -> string {
    segment:=len(run.segments)-1
    if found:=flight_segment_of(run.segments[:],index);found>=0 {segment=found}
    since:=flight_since(run.segments[:],index)
    if segment<0 {return ""}
    if since<0 {return fmt.tprintf(" (segment %d)",segment+1)}
    return fmt.tprintf(" (segment %d, %d frames after the jump)",segment+1,since)
}

// Records the frames of events, one each, and reads them back.
@(private="file")
flight_chunk :: proc(e:^Flight_Editor,run:^Flight_Run,events:[]Flight_Event) -> bool {
    Capture :: struct {frames:int,advance,allow_limited:bool,label:string,top:int}
    if _,ok:=flight_call(e,run,"profile.capture",Capture{len(events),false,true,"flight",FLIGHT_TOP});!ok {return false}
    if _,ok:=flight_call(e,run,"editor.input",struct {events:[]Flight_Event}{events});!ok {return false}
    Summary :: struct {
        frames_recorded:int,
        conditions:struct {device:string,validation:bool},
        gpu:[]Flight_Mean,
    }
    // A capture past its frames still waits for the GPU times of the last ones,
    // and the next cannot begin meanwhile: it ends here, so that every frame of
    // the flight is recorded, and those frames go without GPU times.
    list_text,listed:=flight_call(e,run,"profile.list",struct {}{})
    if !listed {return false}
    list:struct {recording:int}
    _=serial.text_decode(list_text,&list,skip_unknown=true)
    text,ok:=flight_call(e,run,list.recording!=0?"profile.stop":"profile.summary",struct {top:int}{FLIGHT_TOP})
    if !ok {return false}
    summary:Summary
    _=serial.text_decode(text,&summary,skip_unknown=true)
    if run.device=="" {run.device=summary.conditions.device}
    if summary.conditions.validation && len(run.chunks)==0 {append(&run.warnings,"the editor validated the graphics API: the times are inflated")}
    append(&run.chunks,Flight_Chunk{summary.frames_recorded,summary.gpu})
    Frames :: struct {first,count,depth:int}
    Page :: struct {frames:[]Flight_Frame}
    for first:=0;first<summary.frames_recorded;first+=FLIGHT_PAGE {
        page_text,page_ok:=flight_call(e,run,"profile.frames",Frames{first,min(FLIGHT_PAGE,summary.frames_recorded-first),1})
        if !page_ok {return false}
        page:Page
        if problem:=serial.text_decode(page_text,&page,skip_unknown=true);problem!="" {
            run.stopped=fmt.aprintf("profile.frames gave what this tool does not read: %s",problem)
            e.code=1
            return false
        }
        append(&run.frames,..page.frames)
    }
    return true
}

@(private="file")
flight_status :: proc(e:^Flight_Editor,run:^Flight_Run) -> (status:Flight_Status,ok:bool) {
    text:string
    text,ok=flight_call(e,run,"engine.status",struct {}{})
    if ok {_=serial.text_decode(text,&status,skip_unknown=true)}
    return
}

// What the frames still wait for: what is being made and the shadow pages not drawn whole.
flight_busy :: proc(s:Flight_Status) -> int {
    return s.pending.programs+s.pending.pipelines+s.pending.assets+s.shadow_maps.pages_waiting
}

@(private="file")
flight_segment :: proc(e:^Flight_Editor,run:^Flight_Run,s:Flight_Segment) -> bool {
    append(&run.segments,Flight_Done{label=strings.clone(flight_label(s)),first=len(run.frames),settle=s.settle,settled=-1})
    at:=len(run.segments)-1
    if len(s.position)==3 {
        if _,ok:=flight_call(e,run,"camera.set",Camera_Set{position=s.position,target=s.target,fov=s.fov,exposure="scene"});!ok {return false}
        run.segments[at].jumped=true
    }
    flying:=len(s.keys)>0 || s.turn!={}
    right:=[]string{"right"}
    turn:=s.turn
    total:=s.settle>0?s.settle:s.frames
    calm:=-1 // frames when nothing was pending at the last look
    for done:=0;done<total; {
        n:=min(s.settle>0?FLIGHT_SETTLE_CHUNK:FLIGHT_CHUNK,total-done)
        events:=make([]Flight_Event,n,context.temp_allocator)
        for &event in events {
            switch {
            case !flying:  e.flying=false // nothing held: the right button and the keys are let go
            case !e.flying:
                event={mouse_position=e.center[:],mouse_buttons=right}
                e.flying=true
            case: event={mouse_buttons=right,keys=s.keys,mouse_delta=turn[:]}
            }
        }
        first:=len(run.frames)
        if !flight_chunk(e,run,events) {
            run.segments[at].count=len(run.frames)-run.segments[at].first
            return false
        }
        done+=n
        run.segments[at].count=len(run.frames)-run.segments[at].first
        if s.settle==0 {
            if over:=flight_over(run.frames[:],first,run.limit);over>=0 {
                run.stopped=fmt.aprintf("frame %d of the flight%s took %.1f ms, over --limit %g: %s",over,flight_where(run^,over),run.frames[over].ms,run.limit,flight_cause(run.frames[over]))
                e.code=1
                return false
            }
            continue
        }
        status,ok:=flight_status(e,run)
        if !ok {return false}
        switch {
        case flight_busy(status)>0: calm=-1
        case calm<0:                calm=done
        case:
            run.segments[at].settled=calm
            done=total
        }
    }
    status,ok:=flight_status(e,run)
    run.segments[at].status=status
    return ok
}

@(private="file")
flight_fly :: proc(e:^Flight_Editor,run:^Flight_Run,flight:Flight) -> bool {
    if _,ok:=flight_call(e,run,"scene.open",struct {path:string}{flight.scene});!ok {return false}
    Rects :: struct {window:struct {size:[2]f64},layout:struct {bar,left,right,bottom:[4]f64}}
    rects:Rects
    text,ok:=flight_call(e,run,"editor.inspect",struct {}{})
    if !ok {return false}
    _=serial.text_decode(text,&rects,skip_unknown=true)
    free:=render_free_region(rects.window.size,int(rects.window.size.x),int(rects.window.size.y),rects.layout.bar,rects.layout.left,rects.layout.right,rects.layout.bottom)
    e.center={f64(free.x)+0.5*f64(free.w),f64(free.y)+0.5*f64(free.h)}
    for s in flight.segments {
        if !flight_segment(e,run,s) {return false}
    }
    return true
}

bench_flight :: proc(root:string,args:[]string) -> int {
    o,problem:=flight_options(args)
    if problem!="" {fmt.eprintfln("mirai bench: %s\nUsage: mirai %s",problem,BENCH_FLIGHT_USAGE);return 2}
    if !os.is_file(project.path(o.folder,project.PROJECT_FILE,allocator=context.temp_allocator)) {
        fmt.eprintfln("mirai bench: %s is not a project (%s is missing); pass the folder of the project before the flight",o.folder,project.PROJECT_FILE)
        return 2
    }
    folder:=project.path_absolute(o.folder)
    path,missing:=flight_file(folder,o.flight)
    if missing!="" {fmt.eprintfln("mirai bench: %s",missing);return 2}
    data,read_error:=os.read_entire_file(path,context.allocator)
    if read_error!=nil {fmt.eprintfln("mirai bench: could not read %s: %v",path,read_error);return 2}
    cameras,cameras_problem:=capture_views_load(folder)
    flight,flight_problem:=flight_parse(string(data),path,cameras,cameras_problem)
    if flight_problem!="" {fmt.eprintfln("mirai bench: %s",flight_problem);return 2}
    size:=BENCH_SIZE
    if cameras_problem=="" && cameras.plan.size.x>0 && cameras.plan.size.y>0 {size=cameras.plan.size}
    out:=o.out
    if out=="" {out=join(root,"bin","flight",render_stamp(true))}
    out=project.path_absolute(out)
    if os.make_directory_all(out)!=nil && !os.is_dir(out) {fmt.eprintfln("mirai bench: could not create %s",out);return 1}
    relative,_:=os.get_relative_path(root,folder,context.temp_allocator)
    relative,_=strings.replace_all(relative,"\\","/",context.temp_allocator)
    run:=Flight_Run{project=relative,flight=path,scene=flight.scene,commit=render_commit(root),date=render_stamp(false),size=size,release=o.release,limit=o.limit}
    mode:=Build_Mode.Release if o.release else Build_Mode.Dev

    load:Render_Report
    scratch_sweep_say(folder,"bench")
    copy,copy_lock,copy_problem:=session_copy(folder)
    if copy_problem!="" {fmt.eprintfln("mirai bench: %s",copy_problem);return 1}
    if code,_,_:=build_project(root,.Editor,{copy},mode);code!=0 {
        workspace.lock_release(&copy_lock)
        session_copy_remove(copy,"bench flight")
        return code
    }
    // The editor opened is part of this measurement (MEASURE_ENV); it opens
    // before the measurement takes its turn, which other measurements,
    // compilations and the GPU work of others wait for, and which it holds
    // from the scene the flight opens to the end of the flight.
    measure_env_set()
    file,code:=session_open(root,copy,mode,true,180,{"--width",fmt.tprintf("%d",size.x),"--height",fmt.tprintf("%d",size.y)})
    workspace.lock_release(&copy_lock)
    if code!=0 {
        session_copy_remove(copy,"bench flight")
        return code
    }
    measure:=measure_lock(root,"bench flight")
    workspace.gpu_load(&load.warnings,{file.pid},"at the start",true)
    fmt.eprintfln("mirai bench: flying %s in a copy of %s at %dx%d (pid %d)",path,relative,size.x,size.y,file.pid)
    e:=Flight_Editor{port=file.port,pid=file.pid,log=session_log_path(copy)}
    _=flight_fly(&e,&run,flight)
    workspace.gpu_load(&load.warnings,{file.pid},"at the end",true)
    workspace.lock_release(&measure)
    session_close(copy,file,true,"bench flight")
    log:=join(out,"editor.log")
    if bytes,error:=os.read_entire_file(e.log,context.temp_allocator);error==nil {_=os.write_entire_file(log,bytes)}
    session_copy_remove(copy,"bench flight")
    append(&run.warnings,..load.warnings[:])

    markdown:=flight_markdown(run)
    json_path,markdown_path:=join(out,"flight.json"),join(out,"flight.md")
    text,_:=serial.text_encode(run,.Pretty,context.temp_allocator)
    if os.write_entire_file(json_path,text)!=nil {fmt.eprintfln("mirai bench: could not write %s",json_path)}
    if os.write_entire_file(markdown_path,transmute([]u8)markdown)!=nil {fmt.eprintfln("mirai bench: could not write %s",markdown_path)}
    fmt.print(markdown)
    fmt.println()
    fmt.printfln("Table: %s",markdown_path)
    fmt.printfln("Frames: %s",json_path)
    fmt.printfln("Log of the editor: %s",log)
    if run.stopped!="" {
        fmt.eprintfln("mirai bench: the flight stopped at %s",run.stopped)
        return e.code
    }
    return 0
}

// A number of milliseconds with one decimal; a dash for none.
@(private="file")
flight_ms :: proc(value:f64,has:bool) -> string {return has?fmt.tprintf("%.1f",value):"—"}

// The table of a flight, ready for a report.
flight_markdown :: proc(run:Flight_Run) -> string {
    b:=strings.builder_make()
    thresholds:=FLIGHT_THRESHOLDS
    name:=strings.trim_suffix(run.flight[strings.last_index_byte(run.flight,'/')+1:],FLIGHT_EXTENSION)
    fmt.sbprintfln(&b,"## %s: flight `%s` at `%s`",run.project,name,run.commit)
    strings.write_byte(&b,'\n')
    device:=run.device!=""?run.device:"an unnamed GPU"
    bench_wrap(&b,fmt.tprintf("`mirai bench flight` of %s on %s: scene `%s` at %dx%d, %d frames in %d segments, in a headless editor built `%s` that draws every frame with the same dt, without VSync or frame limit. Times in ms: the frame from its start to the start of the next, the CPU of the main thread while it did not wait, the GPU of its own submissions. A segment that names a place jumps the camera there first; one that settles stays still until nothing is pending and no shadow page waits, at two looks %d frames apart.",run.date,device,run.scene,run.size.x,run.size.y,len(run.frames),len(run.segments),render_mode_name(run.release),FLIGHT_SETTLE_CHUNK),BENCH_LINE)

    strings.write_string(&b,"\n| Segment | Frames | Mean | p95 | Worst | GPU | CPU |")
    for limit in thresholds {fmt.sbprintf(&b," > %g |",limit)}
    strings.write_string(&b," Settled in | At its end |\n| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for _ in thresholds {strings.write_string(&b," ---: |")}
    strings.write_string(&b," ---: | --- |\n")
    row :: proc(b:^strings.Builder,label:string,s:Flight_Stat,settled,end:string) {
        has:=s.frames>0
        fmt.sbprintf(b,"| %s | %d | %s | %s | %s | %s | %s |",label,s.frames,flight_ms(s.mean,has),flight_ms(s.p95,has),flight_ms(s.worst,has),flight_ms(s.gpu,has),flight_ms(s.cpu,has))
        for count in s.over {fmt.sbprintf(b," %d |",count)}
        fmt.sbprintfln(b," %s | %s |",settled,end)
    }
    for s,i in run.segments {
        settled:="—"
        switch {
        case s.settle>0 && s.settled>=0: settled=fmt.tprintf("%d",s.settled)
        case s.settle>0:                 settled=fmt.tprintf("not in %d",s.count)
        }
        st:=s.status
        end:=fmt.tprintf("pending %d, shadow pages waiting %d, asked %d, drawn %d",st.pending.programs+st.pending.pipelines+st.pending.assets,st.shadow_maps.pages_waiting,st.shadow_maps.pages_asked,st.shadow_maps.pages_drawn)
        if st.validation_errors>0 {end=fmt.tprintf("%s, %d validation errors",end,st.validation_errors)}
        if st.renderer_problem!="" {end=fmt.tprintf("%s, the renderer: %s",end,st.renderer_problem)}
        row(&b,fmt.tprintf("%d %s",i+1,s.label),flight_stat(run.frames[s.first:][:s.count]),settled,end)
    }
    row(&b,"Flight",flight_stat(run.frames[:]),"—","—")

    strings.write_string(&b,"\n| Frames after a jump |")
    for limit in thresholds {fmt.sbprintf(&b," > %g |",limit)}
    strings.write_string(&b,"\n| --- |")
    for _ in thresholds {strings.write_string(&b," ---: |")}
    strings.write_byte(&b,'\n')
    bounds:=FLIGHT_SINCE
    for counts,k in flight_buckets(run) {
        from:=k==0?0:bounds[k-1]
        label:=k<len(bounds)?fmt.tprintf("%d-%d",from,bounds[k]-1):fmt.tprintf("%d or more",from)
        fmt.sbprintf(&b,"| %s |",label)
        for count in counts {fmt.sbprintf(&b," %d |",count)}
        strings.write_byte(&b,'\n')
    }

    worst:=flight_worst(run.frames[:],FLIGHT_WORST)
    if len(worst)>0 {
        strings.write_string(&b,"\n| Slowest frames | Segment | After the jump | Frame | CPU | Wait | GPU | Bound | Costliest GPU passes | Costliest parts of the CPU |\n")
        strings.write_string(&b,"| ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |\n")
        for index in worst {
            f:=run.frames[index]
            passes:=slice.clone(f.gpu,context.temp_allocator)
            slice.sort_by(passes,proc(a,b:Flight_Pass) -> bool {return a.ms>b.ms})
            pass_text:=make([dynamic]string,context.temp_allocator)
            for p in passes[:min(len(passes),FLIGHT_FRAME_PASSES)] {append(&pass_text,fmt.tprintf("%s %.1f",p.name,p.ms))}
            parts:=make([dynamic]Flight_Zone,context.temp_allocator)
            for z in f.zones {if z.depth==1 {append(&parts,z)}}
            slice.sort_by(parts[:],proc(a,b:Flight_Zone) -> bool {return a.ms>b.ms})
            part_text:=make([dynamic]string,context.temp_allocator)
            for z in parts[:min(len(parts),FLIGHT_FRAME_PASSES)] {append(&part_text,fmt.tprintf("%s %.1f",z.name,z.ms))}
            segment,since:=flight_segment_of(run.segments[:],index),flight_since(run.segments[:],index)
            fmt.sbprintfln(&b,"| %d | %d | %d | %.1f | %.1f | %.1f | %s | %s | %s | %s |",index,segment+1,since,f.ms,f.cpu_ms,f.wait_ms,flight_ms(f.gpu_ms,f.gpu_measured),strings.to_lower(f.bound,context.temp_allocator),strings.join(pass_text[:],", ",context.temp_allocator),strings.join(part_text[:],", ",context.temp_allocator))
        }
    }

    passes:=flight_passes(run.chunks[:])
    if len(passes)>0 {
        strings.write_string(&b,"\n| GPU by pass, ms | Mean |\n| --- | ---: |\n")
        for p in passes[:min(len(passes),FLIGHT_PASSES)] {fmt.sbprintfln(&b,"| `%s` | %.3f |",p.name,p.mean_ms)}
    }
    if run.stopped!="" {
        strings.write_byte(&b,'\n')
        bench_wrap(&b,fmt.tprintf("Stopped at %s",run.stopped),BENCH_LINE)
    }
    if len(run.warnings)>0 {
        strings.write_string(&b,"\nWarnings:\n\n")
        for warning in run.warnings {bench_wrap(&b,fmt.tprintf("- %s",warning),BENCH_LINE,"  ")}
    }
    return strings.to_string(b)
}
