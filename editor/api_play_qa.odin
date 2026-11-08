package editor

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import img "mirai:cook/image"
import "mirai:core"
import "mirai:editor/api"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"

// Monitors of the game a run plays, armed by play.qa.start and read by
// play.qa.report, for the ticks the API runs (play.step, a scenario,
// play.explore, a filmstrip, play.walk). The first thing the API does to a run
// reserves its log of what the run received, from which a repro plays the same
// ticks again whenever the monitors started; a tick writes into that, and a
// run the API never touched only tests a pointer.

QA_VIOLATIONS :: 64
QA_LOG_ENTRIES :: 8192
QA_LOG_TEXT :: 256*1024
@(private) QA_MOVE_HELD :: f32(0.05)      // length of a Move_Input that asks for movement
@(private) QA_STUCK_DISTANCE :: f32(0.1)  // meters that count as having moved
@(private) QA_MEMORY_EVERY :: 30          // ticks between two readings of the memory
@(private) QA_FILMSTRIP_AROUND :: u64(60) // ticks a filmstrip shows on each side of a violation
@(private) QA_FILMSTRIP_CELLS :: 9
@(private) QA_FILMSTRIP_FRAMES :: 2       // frames drawn per cell of the past

Api_Qa_Kind :: enum u8 {Frame_Time,Memory,Stuck,Fell,Non_Finite,Problem}
Api_Qa_Severity :: enum u8 {Warning,Error}

Api_Play_Qa_Start_Params :: struct {
    frame_ms:f32 `mirai:"optional,min=0,unit=ms,label=Longest whole frame of the application; 0: off"`,
    memory_mb:f32 `mirai:"optional,min=0,label=Megabytes the process may grow since this call; 0: off"`,
    stuck_seconds:f32 `mirai:"optional,min=0,unit=s,label=Game time the body may ask to move without moving; 0: off"`,
    fall_below:f32 `mirai:"optional,unit=m,label=World height the body must stay above; absent: off"`,
    non_finite:bool `mirai:"optional,label=A NaN or infinite Transform is a violation"`,
    problems:bool `mirai:"optional,label=A core.report problem is a violation"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Qa_Start_Result :: struct {
    tick:u64 `mirai:"label=The tick the monitors start at"`,
    repro:bool `mirai:"label=Its violations can write a repro: the log of the inputs starts at tick 0"`,
}

Api_Play_Qa_Report_Params :: struct {
    violation:int `mirai:"optional,min=-1,max=63,label=The index of the violation repro and filmstrip are of; -1: none"`,
    repro:bool `mirai:"optional,label=Writes tests/scenarios/bug_<tick>.mirai under the project: the inputs from tick 0 to that violation ending in a play.check"`,
    filmstrip:[API_PATH_BYTES]u8 `mirai:"optional,text,label=PNG of the ticks around that violation from the past of the run; the run stays where it is"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Qa_Report :: struct {
    passed:bool `mirai:"label=No violation"`,
    tick:u64 `mirai:"label=The tick of the game now"`,
    violations:[1]Api_Play_Qa_Violation `mirai:"list"`,
    dropped:int `mirai:"optional,label=Violations that did not fit"`,
    repro:[API_PATH_BYTES]u8 `mirai:"optional,text,label=The scenario written"`,
    filmstrip:Api_Capture_Result `mirai:"optional,label=The filmstrip written"`,
}
Api_Play_Qa_Violation :: struct {
    index:int,
    kind:Api_Qa_Kind,
    severity:Api_Qa_Severity,
    tick:u64 `mirai:"label=Of its first time"`,
    position:[3]f32 `mirai:"label=Of the body of the focused player at that tick"`,
    value:f32 `mirai:"label=What was measured: ms or megabytes or seconds or a height"`,
    limit:f32 `mirai:"label=What it passed"`,
    count:int `mirai:"optional,label=Times it repeated"`,
    last_tick:u64 `mirai:"optional,label=Of its last time when it repeated"`,
    entity:[16]u8 `mirai:"optional,text,label=The entity it is about"`,
    code:[core.PROBLEM_CODE]u8 `mirai:"optional,text,label=Of a problem"`,
    text:[core.PROBLEM_TEXT]u8 `mirai:"optional,text,label=What the problem says"`,
}

// What play.qa.start asked.
Qa_Limits :: struct {
    frame_ms,memory_mb,stuck_seconds,fall_below:f32,
    falls,non_finite,problems:bool,
}

@(private)
Qa_Violation :: struct {
    kind:Api_Qa_Kind,
    severity:Api_Qa_Severity,
    tick,last_tick:u64,
    position:[3]f32,
    value,limit:f32,
    count:int,
    entity:core.Entity,
    ran:int, // ticks of the log up to it
    problem:core.Problem,
    has_problem:bool,
}

// An entry of the log, in the order the run received them.
@(private)
Qa_Entry_Kind :: enum u8 {Input,Hold,Call,Focus,Monitors}
@(private)
Qa_Entry :: struct {
    kind:Qa_Entry_Kind,
    given:Api_Step_Input, // Input: its text is in the text of the log
    total:int,            // Input: ticks of the segment it came from
    at:int,               // Input: of the last tick it took in that segment
    hold:input.Hold_Request,
    slot:int,             // Hold: of the seat; Focus: the seat it goes to
    method:string,        // Call: a constant
    text_at,text_len:int, // Input: text; Call: params
}

Run_Qa :: struct {
    allocator:runtime.Allocator,
    limits:Qa_Limits,
    started:u64,   // the tick the API first touched the run at
    tick:u64,      // of the last tick it saw
    from_zero:bool,
    armed:bool,    // play.qa.start was called: the monitors run
    armed_at:int,  // the entry of the log where they started last
    ran:int,       // ticks logged
    broken:string, // why the log cannot replay; a constant
    log:[]Qa_Entry,
    log_count:int,
    text:[]u8,
    text_used:int,
    violations:[]Qa_Violation,
    violation_count,dropped:int,
    counts:[Api_Qa_Kind]int,
    serial:u64,       // the Problems.serial it has seen
    memory_base:u64,
    memory_next:int,  // ran of the next reading
    anchor:[3]f32,    // where the body was when it last asked to move and moved
    anchor_seconds:f64,
    stuck,fell:bool,  // the episode that is going on
}

@(private)
qa_api_register :: proc(s:^Session,st:^Api_State) {
    defaults:=Api_Play_Qa_Start_Params{stuck_seconds=3,non_finite=true,problems=true}
    report:=Api_Play_Qa_Report_Params{violation=-1}
    api_register(s,st,{name="play.qa.start",flags={.Core},summary="Starts monitors on the game of the caller, for the ticks the API runs: frame time, memory, stuck, falling, non-finite transforms and core.report problems. A violation can write a repro whenever they start, as long as the API drove the game from its first tick.",params=Api_Play_Qa_Start_Params,result=Api_Play_Qa_Start_Result,defaults=&defaults,run=api_play_qa_start})
    api_register(s,st,{name="play.qa.report",flags={.Core},summary="The violations the monitors of play.qa.start saw, with tick, place and severity; for one of them writes a repro scenario or a filmstrip around its tick.",params=Api_Play_Qa_Report_Params,result=Api_Play_Qa_Report,writes_result=true,defaults=&report,run=api_play_qa_report})
}

// The seat with the focus and the body it drives; NONE where there is none.
@(private)
play_focused :: proc(w:core.World_Ref) -> (seat,body:core.Entity) {
    state,seats:=core.world_storage_of(w,input.Seats),core.world_table_of(w,input.Seat)
    if state==nil || seats==nil {return}
    seat=input.focused(state,core.read(seats))
    if drivables:=core.world_table_of(w,input.Drivable);drivables!=nil {body=input.body_of(core.read(drivables),seat)}
    return
}

// Whether a body is asked to move this tick, by a seat or by whatever drives it.
@(private)
play_moving :: proc(w:core.World_Ref,body:core.Entity) -> bool {
    moves:=core.world_table_of(w,input.Move_Input)
    if moves==nil {return false}
    move,found:=core.get(core.read(moves),body)
    return found && linalg.length(move.move)>=QA_MOVE_HELD
}

// What the first call of the API on a run reserves: the log of its inputs.
// Nil without memory, and the run then plays without one.
@(private)
qa_reserve :: proc(s:^Session,r:^Run) -> ^Run_Qa {
    if r.qa!=nil {return r.qa}
    allocator:=s.app.allocator
    q:=new(Run_Qa,allocator)
    if q==nil {return nil}
    q.allocator=allocator
    q.log=make([]Qa_Entry,QA_LOG_ENTRIES,allocator)
    q.text=make([]u8,QA_LOG_TEXT,allocator)
    q.violations=make([]Qa_Violation,QA_VIOLATIONS,allocator)
    if q.log==nil || q.text==nil || q.violations==nil {
        qa_free(q)
        return nil
    }
    tick:u64
    if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {tick=t.tick}
    q.started,q.tick,q.from_zero=tick,tick,tick==0
    r.qa=q
    return q
}

// Starts the monitors of a run, or takes new limits and starts counting again,
// keeping its log. The log says where, so that a repro starts them there.
@(private)
qa_arm :: proc(s:^Session,r:^Run,limits:Qa_Limits) -> ^Run_Qa {
    q:=qa_reserve(s,r)
    if q==nil {return nil}
    w:=run_ref(s,r)
    seconds:f64
    if t:=core.world_storage_of(w,core.Time);t!=nil {seconds=t.seconds}
    q.armed=true
    q.limits=limits
    q.violation_count,q.dropped=0,0
    q.counts={}
    q.stuck,q.fell=false,false
    q.anchor_seconds=seconds
    _,body:=play_focused(w)
    if body!=core.NONE {q.anchor=entity_world(w,body).position}
    if problems:=host.app_world_storage(s.app,w.data,core.Problems);problems!=nil {q.serial=problems.serial}
    q.memory_base=platform.process_memory_bytes()
    q.memory_next=q.ran+QA_MEMORY_EVERY
    if q.broken=="" {
        if e:=qa_entry_next(q);e!=nil {e.kind,q.armed_at=.Monitors,q.log_count-1}
    }
    return q
}

@(private)
qa_free :: proc(q:^Run_Qa) {
    if q==nil {return}
    context.allocator=q.allocator
    delete(q.log);delete(q.text);delete(q.violations)
    free(q)
}

@(private)
qa_text_put :: proc(q:^Run_Qa,text:string) -> (at,count:int,ok:bool) {
    if q.text_used+len(text)>len(q.text) {return}
    at=q.text_used
    copy(q.text[at:],text)
    q.text_used+=len(text)
    return at,len(text),true
}

@(private)
qa_text :: proc(q:^Run_Qa,at,count:int) -> string {return string(q.text[at:][:count])}

@(private)
qa_entry_next :: proc(q:^Run_Qa) -> ^Qa_Entry {
    if q.log_count==len(q.log) {
        q.broken="the log of the inputs of the run filled up"
        return nil
    }
    e:=&q.log[q.log_count]
    e^={}
    q.log_count+=1
    return e
}

// Whether a tick of a segment gives input only by what it holds.
@(private)
qa_input_held_only :: proc(step:^Api_Step_Input) -> bool {
    return step.tap_keys=={} && step.tap_buttons=={} && !step.placed && step.wheel=={} && step.mouse_delta=={} && step.text=="" && step.pad_taps=={}
}

// The input one tick receives, before it runs: at is that tick of its
// segment. The holds waiting for it come first, as play.input asks them.
@(private)
qa_log_tick :: proc(s:^Session,r:^Run,step:^Api_Step_Input,at:int) {
    q:=qa_reserve(s,r)
    if q==nil {return}
    w:=run_ref(s,r)
    tick:u64
    if t:=core.world_storage_of(w,core.Time);t!=nil {tick=t.tick}
    if q.broken=="" && tick!=q.tick {q.broken="the game ran ticks no step gave it, or went back with play.seek"}
    q.ran+=1
    if q.broken!="" {return}
    if requests:=core.world_storage_of(w,input.Hold_Requests);requests!=nil {
        seats:=core.world_table_of(w,input.Seat)
        for i in 0..<len(requests.queue.items) {
            e:=qa_entry_next(q)
            if e==nil {return}
            e.kind,e.hold=.Hold,requests.queue.items[i]
            if seats!=nil {
                if seat,found:=core.get(core.read(seats),e.hold.seat);found {e.slot=int(seat.slot)}
            }
        }
    }
    if q.log_count>0 && q.log[q.log_count-1].kind==.Input {
        last:=&q.log[q.log_count-1]
        if at>0 && at==last.at+1 && last.total==step.ticks {
            last.given.ticks+=1
            last.at=at
            return
        }
        same:=at==0 && qa_input_held_only(step) && last.given.mouse_delta=={} && last.given.keys==step.keys && last.given.buttons==step.buttons && last.given.gamepads==step.gamepads
        if same {
            last.given.ticks+=1
            last.at,last.total=0,step.ticks
            return
        }
    }
    e:=qa_entry_next(q)
    if e==nil {return}
    e^={kind=.Input,given=step^,total=step.ticks,at=at}
    e.given.ticks=1
    e.given.text=""
    if at>0 {
        // What only the first tick of a segment gives was given then.
        e.given.placed,e.given.wheel,e.given.tap_keys,e.given.tap_buttons,e.given.pad_taps=false,{},{},{},{}
    } else if step.text!="" {
        stored:bool
        if e.text_at,e.text_len,stored=qa_text_put(q,step.text);!stored {q.broken="the log of the inputs of the run filled up"}
    }
}

// A call that changed the run between two ticks, as a scenario makes it again.
@(private)
qa_log_call :: proc(s:^Session,r:^Run,method,params:string) {
    q:=qa_reserve(s,r)
    if q==nil || q.broken!="" {return}
    e:=qa_entry_next(q)
    if e==nil {return}
    stored:bool
    if e.text_at,e.text_len,stored=qa_text_put(q,params);!stored {
        q.broken="the log of the inputs of the run filled up"
        return
    }
    e.kind,e.method=.Call,method
}

@(private)
qa_log_focus :: proc(s:^Session,r:^Run,slot:int) {
    q:=qa_reserve(s,r)
    if q==nil || q.broken!="" {return}
    if e:=qa_entry_next(q);e!=nil {e.kind,e.slot=.Focus,slot}
}

@(private)
qa_violation_add :: proc(q:^Run_Qa,v:Qa_Violation,repeats:bool) {
    q.counts[v.kind]+=1
    if repeats {
        for &known in q.violations[:q.violation_count] {
            if known.kind!=v.kind || known.entity!=v.entity || known.problem.code!=v.problem.code {continue}
            known.count+=1
            known.last_tick=v.tick
            known.value=max(known.value,v.value)
            return
        }
    }
    if q.violation_count==len(q.violations) {q.dropped+=1;return}
    new_one:=v
    new_one.count=1
    new_one.last_tick=v.tick
    new_one.ran=q.ran
    q.violations[q.violation_count]=new_one
    q.violation_count+=1
}

@(private)
qa_finite :: proc "contextless" (values:[]f32) -> bool {
    for v in values {if !rpc_finite(v) {return false}}
    return true
}

// The monitors after one tick the API ran.
@(private)
qa_tick :: proc(s:^Session,r:^Run) {
    q:=r.qa
    if q==nil {return}
    w:=run_ref(s,r)
    tick,seconds:=u64(0),f64(0)
    if t:=core.world_storage_of(w,core.Time);t!=nil {tick,seconds=t.tick,t.seconds}
    q.tick=tick
    if !q.armed {return}
    limits:=&q.limits
    _,body:=play_focused(w)
    at:[3]f32
    if body!=core.NONE {at=entity_world(w,body).position}
    if limits.problems {
        if problems:=host.app_world_storage(s.app,w.data,core.Problems);problems!=nil && problems.serial!=q.serial {
            for &p in core.problems_list(problems) {
                if p.last<=q.serial {continue}
                qa_violation_add(q,{kind=.Problem,severity=.Error,tick=tick,position=at,entity=p.entity,problem=p,has_problem=true,value=f32(p.count)},true)
            }
            q.serial=problems.serial
        }
    }
    if limits.non_finite {
        if transforms:=core.world_table_of(w,core.Transform);transforms!=nil {
            for &t,row in transforms.values[:core.count(transforms)] {
                p,o,e:=t.position,transmute([4]f32)t.rotation,t.scale
                if qa_finite(p[:]) && qa_finite(o[:]) && qa_finite(e[:]) {continue}
                qa_violation_add(q,{kind=.Non_Finite,severity=.Error,tick=tick,position=at,entity=transforms.entities[row]},true)
            }
        }
    }
    if limits.frame_ms>0 && s.app.stats.frame_ms>limits.frame_ms {
        qa_violation_add(q,{kind=.Frame_Time,severity=.Warning,tick=tick,position=at,value=s.app.stats.frame_ms,limit=limits.frame_ms},true)
    }
    if limits.memory_mb>0 && q.ran>=q.memory_next {
        q.memory_next=q.ran+QA_MEMORY_EVERY
        now:=platform.process_memory_bytes()
        grown:=now>q.memory_base?f32(now-q.memory_base)/(1024*1024):0
        if grown>limits.memory_mb {qa_violation_add(q,{kind=.Memory,severity=.Warning,tick=tick,position=at,value=grown,limit=limits.memory_mb},true)}
    }
    if body==core.NONE {return}
    if limits.falls {
        below:=at.y<limits.fall_below
        if below && !q.fell {qa_violation_add(q,{kind=.Fell,severity=.Error,tick=tick,position=at,value=at.y,limit=limits.fall_below,entity=body},false)}
        q.fell=below
    }
    if limits.stuck_seconds>0 {
        if !play_moving(w,body) || linalg.length(at-q.anchor)>=QA_STUCK_DISTANCE {
            q.anchor,q.anchor_seconds,q.stuck=at,seconds,false
        } else if seconds-q.anchor_seconds>=f64(limits.stuck_seconds) && !q.stuck {
            q.stuck=true
            qa_violation_add(q,{kind=.Stuck,severity=.Warning,tick=tick,position=at,value=f32(seconds-q.anchor_seconds),limit=limits.stuck_seconds,entity=body},false)
        }
    }
}

@(private)
qa_limits_read :: proc(call:^api.Call,p:^Api_Play_Qa_Start_Params) -> Qa_Limits {
    values:[1]string
    api.object_values(call.allocator,call.raw,{"fall_below"},values[:])
    return {frame_ms=p.frame_ms,memory_mb=p.memory_mb,stuck_seconds=p.stuck_seconds,fall_below=p.fall_below,falls=values[0]!="",non_finite=p.non_finite,problems=p.problems}
}

@(private)
api_play_qa_start :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Qa_Start_Params)
    r,own:=api_play_own_run(s,call,p.player)
    if !own {return}
    q:=qa_arm(s,r,qa_limits_read(call,p))
    if q==nil {api.call_fail(call,api.SERVER_ERROR,"No memory for the monitors");return}
    result:=api.call_result(call,Api_Play_Qa_Start_Result)
    result.tick,result.repro=q.tick,q.from_zero && q.broken==""
}

// The violations, with the index of each.
@(private)
qa_violations_write :: proc(s:^Session,out:^serial.Writer,q:^Run_Qa) {
    w:=q.violations[:q.violation_count]
    api.write_key(out,"violations");serial.write_u8(out,'[')
    for &v,i in w {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_int(out,"index",i64(i),true)
        api.write_text(out,"kind",fmt.tprint(v.kind))
        api.write_text(out,"severity",fmt.tprint(v.severity))
        api.write_uint(out,"tick",v.tick)
        observe_vector_write(out,"position",v.position[:])
        api.write_key(out,"value");api.write_number(out,observe_round(v.value))
        api.write_key(out,"limit");api.write_number(out,observe_round(v.limit))
        if v.count>1 {
            api.write_int(out,"count",i64(v.count))
            api.write_uint(out,"last_tick",v.last_tick)
        }
        if v.entity!=core.NONE {
            api.write_key(out,"entity")
            serial.write_u8(out,'"');serial.text_write_hex(out,u64(v.entity),16,false);serial.write_u8(out,'"')
        }
        if v.has_problem {
            api.write_text(out,"code",core.problem_code(&v.problem))
            api.write_text(out,"text",core.problem_text(&v.problem))
        }
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
}

@(private)
api_play_qa_report :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Qa_Report_Params)
    r,_:=api_play_run(s,call,p.player)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,"No game is playing; play.start first");return}
    q:=r.qa
    if q==nil || !q.armed {api.call_fail(call,api.INVALID_PARAMS,"No monitors on this game: play.qa.start first");return}
    strip_path:=base.text_get(p.filmstrip[:])
    if (p.repro || strip_path!="") && (p.violation<0 || p.violation>=q.violation_count) {
        api.call_failf(call,api.INVALID_PARAMS,"violation %d: repro and filmstrip are of one violation; give its index, 0 to %d",p.violation,q.violation_count-1)
        return
    }
    repro,strip:string
    if p.repro {
        file,problem:=qa_repro_write(s,call,r,&q.violations[p.violation],call.allocator)
        if problem!="" {api.call_fail(call,api.SERVER_ERROR,problem);return}
        repro=file
    }
    if strip_path!="" {
        strip=qa_filmstrip(s,call,r,&q.violations[p.violation],strip_path)
        if strip=="" {return}
    }
    out:=call.out
    serial.write_u8(out,'{')
    api.write_bool(out,"passed",q.violation_count==0 && q.dropped==0,true)
    api.write_uint(out,"tick",q.tick)
    qa_violations_write(s,out,q)
    if q.dropped>0 {api.write_int(out,"dropped",i64(q.dropped))}
    if repro!="" {api.write_text(out,"repro",repro)}
    if strip!="" {api.write_key(out,"filmstrip");serial.text_write_raw(out,strip)}
    serial.write_u8(out,'}')
}

// How many violations of each kind, as the conditions with qa read them.
@(private)
qa_counts_write :: proc(out:^serial.Writer,q:^Run_Qa) {
    serial.write_u8(out,'{')
    for count,kind in q.counts {
        api.write_int(out,fmt.tprint(kind),i64(count),kind==Api_Qa_Kind(0))
    }
    serial.write_u8(out,'}')
}

// ---------------------------------------------------------------- repro

@(private)
Repro_Writer :: struct {
    s:^Session,
    q:^Run_Qa,
    out:serial.Writer,
    steps:int,
    segments:[API_STEP_SEGMENTS]^Qa_Entry,
    segment_ticks:[API_STEP_SEGMENTS]int,
    segment_count,tick_sum:int,
    focus:int, // of the next play.step; -1: none
}

@(private)
repro_step_begin :: proc(w:^Repro_Writer,method:string) {
    if w.steps>0 {serial.write_u8(&w.out,',')}
    w.steps+=1
    serial.text_write_raw(&w.out,`{"method":`);serial.text_write_string(&w.out,method)
    serial.text_write_raw(&w.out,`,"params":`)
}

@(private)
repro_names :: proc(out:^serial.Writer,key:string,names:[]string) {
    if len(names)==0 {return}
    api.write_key(out,key);serial.write_u8(out,'[')
    for name,i in names {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_string(out,name)
    }
    serial.write_u8(out,']')
}

@(private)
repro_keys :: proc(out:^serial.Writer,key:string,keys:core.Keys) {
    names:=make([dynamic]string,context.temp_allocator)
    for k in keys {append(&names,fmt.tprint(k))}
    repro_names(out,key,names[:])
}

@(private)
repro_buttons :: proc(out:^serial.Writer,key:string,buttons:core.Mouse_Buttons) {
    names:=make([dynamic]string,context.temp_allocator)
    for b in buttons {append(&names,fmt.tprint(b))}
    repro_names(out,key,names[:])
}

@(private)
repro_pads :: proc(out:^serial.Writer,key:string,buttons:platform.Gamepad_Buttons) {
    names:=make([dynamic]string,context.temp_allocator)
    for b in buttons {append(&names,fmt.tprint(b))}
    repro_names(out,key,names[:])
}

@(private)
repro_pair :: proc(out:^serial.Writer,key:string,value:[2]f32) {
    value:=value
    api.write_key(out,key)
    api.write_list(out,value[:])
}

// A segment as play.step takes it.
@(private)
repro_segment :: proc(w:^Repro_Writer,e:^Qa_Entry,ticks:int) {
    out:=&w.out
    i:=&e.given
    serial.write_u8(out,'{')
    api.write_int(out,"ticks",i64(ticks),true)
    repro_keys(out,"keys",i.keys)
    repro_buttons(out,"mouse_buttons",i.buttons)
    repro_keys(out,"tap_keys",i.tap_keys)
    repro_buttons(out,"tap_buttons",i.tap_buttons)
    if i.placed {repro_pair(out,"mouse_position",i.mouse_position)}
    if i.mouse_delta!={} {repro_pair(out,"mouse_delta",i.mouse_delta*f32(ticks)/f32(max(e.total,1)))}
    if i.wheel!={} {repro_pair(out,"wheel",i.wheel)}
    if e.text_len>0 {api.write_text(out,"text",qa_text(w.q,e.text_at,e.text_len))}
    connected:=false
    for &pad,slot in i.gamepads {
        if !pad.connected {continue}
        if !connected {api.write_key(out,"gamepads");serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        connected=true
        serial.write_u8(out,'{')
        api.write_int(out,"slot",i64(slot),true)
        repro_pads(out,"buttons",pad.down)
        repro_pads(out,"tapped",i.pad_taps[slot])
        repro_pair(out,"left_stick",{pad.axes[.Left_X],pad.axes[.Left_Y]})
        repro_pair(out,"right_stick",{pad.axes[.Right_X],pad.axes[.Right_Y]})
        api.write_key(out,"left_trigger");api.write_number(out,pad.axes[.Left_Trigger])
        api.write_key(out,"right_trigger");api.write_number(out,pad.axes[.Right_Trigger])
        serial.write_u8(out,'}')
    }
    if connected {serial.write_u8(out,']')}
    serial.write_u8(out,'}')
}

// The play.step of the segments gathered so far.
@(private)
repro_flush :: proc(w:^Repro_Writer) {
    if w.segment_count==0 {return}
    repro_step_begin(w,"play.step")
    out:=&w.out
    serial.text_write_raw(out,`{"segments":[`)
    for e,i in w.segments[:w.segment_count] {
        if i>0 {serial.write_u8(out,',')}
        repro_segment(w,e,w.segment_ticks[i])
    }
    serial.write_u8(out,']')
    if w.focus>=0 {api.write_int(out,"focus",i64(w.focus))}
    serial.text_write_raw(out,"}}")
    w.focus=-1
    w.segment_count,w.tick_sum=0,0
}

@(private)
repro_input :: proc(w:^Repro_Writer,e:^Qa_Entry,ticks:int) {
    ticks:=ticks
    for ticks>0 {
        if w.segment_count==API_STEP_SEGMENTS || w.tick_sum==API_STEP_LIMIT {repro_flush(w)}
        take:=min(ticks,API_STEP_LIMIT-w.tick_sum)
        w.segments[w.segment_count],w.segment_ticks[w.segment_count]=e,take
        w.segment_count+=1
        w.tick_sum+=take
        ticks-=take
    }
}

// Holds that came together, as one play.input per seat.
@(private)
repro_holds :: proc(w:^Repro_Writer,entries:[]Qa_Entry) {
    m:=core.world_storage_of(run_ref(w.s,run_of_qa(w.s,w.q)),input.Input_Map)
    out:=&w.out
    start:=0
    for start<len(entries) {
        end:=start+1
        for end<len(entries) && entries[end].kind==.Hold && entries[end].slot==entries[start].slot && end-start<input.HOLD_CAPACITY {end+=1}
        repro_step_begin(w,"play.input")
        serial.text_write_raw(out,`{"actions":[`)
        for &e,i in entries[start:end] {
            if i>0 {serial.write_u8(out,',')}
            name,_:=core.name_of(w.s.info,input.Action,i64(e.hold.action))
            serial.text_write_raw(out,`{"name":`);serial.text_write_string(out,name)
            if e.hold.value=={} {
                api.write_bool(out,"release",true)
            } else {
                #partial switch m!=nil?m.kinds[e.hold.action]:input.Action_Kind.Button {
                case .Axis:  api.write_key(out,"value");api.write_number(out,e.hold.value.x)
                case .Axis2: repro_pair(out,"vector",e.hold.value)
                }
                if e.hold.ticks>0 {api.write_int(out,"ticks",i64(e.hold.ticks))}
            }
            serial.write_u8(out,'}')
        }
        serial.write_u8(out,']')
        api.write_int(out,"slot",i64(entries[start].slot))
        serial.text_write_raw(out,"}}")
        start=end
    }
}

@(private)
run_of_qa :: proc(s:^Session,q:^Run_Qa) -> ^Run {
    for &r in s.runs {if r.qa==q {return &r}}
    return nil
}

// What must hold for the violation not to happen: a violation fails the
// scenario, so the file reports the bug while it exists and passes once
// it is fixed.
@(private)
repro_monitor :: proc(out:^serial.Writer,q:^Run_Qa,v:^Qa_Violation) {
    l:=&q.limits
    serial.write_u8(out,'{')
    api.write_bool(out,"non_finite",v.kind==.Non_Finite,true)
    api.write_bool(out,"problems",v.kind==.Problem)
    api.write_key(out,"stuck_seconds");api.write_number(out,v.kind==.Stuck?l.stuck_seconds:0)
    if v.kind==.Frame_Time {api.write_key(out,"frame_ms");api.write_number(out,l.frame_ms)}
    if v.kind==.Memory {api.write_key(out,"memory_mb");api.write_number(out,l.memory_mb)}
    if v.kind==.Fell {api.write_key(out,"fall_below");api.write_number(out,l.fall_below)}
    serial.write_u8(out,'}')
}

// The text of the scenario that plays a run from tick 0 to a violation.
@(private)
qa_repro_text :: proc(s:^Session,r:^Run,q:^Run_Qa,v:^Qa_Violation,allocator:=context.allocator) -> (text,problem:string) {
    if !q.from_zero {return "",fmt.tprintf("No repro: a repro plays from tick 0 and the game ran %d ticks by itself before the API drove it; give the game its ticks with play.step from the first one",q.started)}
    if q.broken!="" {return "",fmt.tprintf("No repro: %s",q.broken)}
    w:core.World_Ref=run_ref(s,r)
    if network:=core.world_storage_of(w,core.Network);network!=nil && network.role!=.Standalone {return "","No repro: a game on the network does not play the same ticks again"}
    repro:Repro_Writer
    repro.s,repro.q,repro.focus=s,q,-1
    serial.writer_init(&repro.out,8192,allocator)
    out:=&repro.out
    serial.write_u8(out,'{')
    path:=document_path(s.document)
    if path!="" {api.write_text(out,"scene",path,true)}
    api.write_key(out,"start",path=="");serial.write_u8(out,'{')
    if seats:=core.world_storage_of(w,input.Seats);seats!=nil && seats.local_count>0 {api.write_int(out,"players",i64(seats.local_count),true)}
    serial.write_u8(out,'}')
    api.write_key(out,"steps");serial.write_u8(out,'[')
    left:=v.ran
    entries:
    for i:=0;i<q.log_count && left>0;i+=1 {
        e:=&q.log[i]
        switch e.kind {
        case .Input:
            ticks:=min(e.given.ticks,left)
            repro_input(&repro,e,ticks)
            left-=ticks
        case .Hold:
            end:=i
            for end<q.log_count && q.log[end].kind==.Hold {end+=1}
            repro_flush(&repro)
            repro_holds(&repro,q.log[i:end])
            i=end-1
        case .Focus:
            repro_flush(&repro)
            repro.focus=e.slot
        case .Monitors:
            if i!=q.armed_at {continue}
            repro_flush(&repro)
            repro_step_begin(&repro,"play.qa.start")
            repro_monitor(out,q,v)
            serial.write_u8(out,'}')
        case .Call:
            repro_flush(&repro)
            repro_step_begin(&repro,e.method)
            serial.text_write_raw(out,qa_text(q,e.text_at,e.text_len))
            serial.write_u8(out,'}')
        }
        if left==0 {break entries}
    }
    repro_flush(&repro)
    repro_step_begin(&repro,"play.check")
    serial.text_write_raw(out,`{"conditions":[{"qa":true,"field":`)
    serial.text_write_string(out,fmt.tprint(v.kind))
    serial.text_write_raw(out,`,"compare":"Equal","number":0}]}}`)
    serial.text_write_raw(out,"]}")
    bytes:=serial.writer_bytes(out)
    if len(bytes)>API_SCENARIO_FILE_BYTES {return "",fmt.tprintf("No repro: its scenario takes %d bytes and a scenario file %d",len(bytes),API_SCENARIO_FILE_BYTES)}
    if repro.steps>API_SCENARIO_STEPS {return "",fmt.tprintf("No repro: its scenario takes %d steps and a scenario file %d",repro.steps,API_SCENARIO_STEPS)}
    return string(bytes),""
}

// Writes tests/scenarios/bug_<tick>.mirai of a violation; its file, or why not.
@(private)
qa_repro_write :: proc(s:^Session,call:^api.Call,r:^Run,v:^Qa_Violation,allocator:=context.allocator) -> (file,problem:string) {
    text,wrong:=qa_repro_text(s,r,r.qa,v,allocator)
    if wrong!="" {return "",wrong}
    path:=fmt.tprintf("%s/bug_%d%s",SCENARIO_FOLDER,v.tick,SCENARIO_EXTENSION)
    target,bad:=api_output_path(s.project_root,path,context.temp_allocator)
    if bad!="" {return "",bad}
    if why,_:=api_output_prepare(target);why!="" {return "",why}
    if error:=os.write_entire_file(target,transmute([]u8)text);error!=nil {return "",fmt.tprintf("%s could not be written: %s",target,os.error_string(error))}
    return path,""
}

// ---------------------------------------------------------------- filmstrip

// A filmstrip of the ticks the run keeps around a violation, played again on
// the World of the run, which is put back after; what it answers, or "" after failing the call.
@(private)
qa_filmstrip :: proc(s:^Session,call:^api.Call,r:^Run,v:^Qa_Violation,path:string) -> string {
    if s.app==nil || s.app.renderer==nil {api.call_fail(call,api.SERVER_ERROR,"A filmstrip needs a GPU");return ""}
    if reason:=history_reason(s,r);reason!="" {api.call_fail(call,api.SERVER_ERROR,reason);return ""}
    h:=r.history
    oldest,newest,_,_,_:=history_span(h)
    from:=v.tick>oldest+QA_FILMSTRIP_AROUND?v.tick-QA_FILMSTRIP_AROUND:oldest
    to:=min(v.tick+QA_FILMSTRIP_AROUND,newest)
    first:=history_frame_for(h,from)
    if first==0 {api_history_older(call,h,from);return ""}
    file,writable:=api_output_file(s,call,path,call.allocator)
    if !writable {return ""}
    span:=to>from?to-from:0
    every:=max(span/(QA_FILMSTRIP_CELLS-1),1)
    strip:=new(Api_Filmstrip,call.allocator)
    strip^={frames=QA_FILMSTRIP_FRAMES,count=int(span/every)+1}
    strip.run={owner=r.owner,player=r.player}
    strip.cells=make([]Api_Filmstrip_Cell,strip.count,call.allocator)
    defer img.sheet_destroy(&strip.sheet)
    saved,copied:=history_save(s,r)
    if !copied {api.call_fail(call,api.SERVER_ERROR,"No memory for a copy of the World to play its past on; the game stays as it is");return ""}
    problem:string
    {
        kept:=extras_mark(s.app)
        defer extras_drop(s.app,kept)
        problem=qa_filmstrip_cells(s,r,strip,first,to,every)
    }
    history_restore(s,r,&saved)
    if problem!="" {api.call_fail(call,api.SERVER_ERROR,problem);return ""}
    sheet:=strip.sheet
    strip.sheet={}
    if !api_png_write(s,file,sheet.image.pixels,sheet.image.width,sheet.image.height) {api.call_fail(call,api.SERVER_ERROR,"The filmstrip could not be written");return ""}
    return api_filmstrip_result(file,sheet,strip.cells[:strip.taken],false,call.allocator)
}

@(private)
qa_filmstrip_cells :: proc(s:^Session,r:^Run,strip:^Api_Filmstrip,first,to,every:u64) -> string {
    h:=r.history
    if !history_seek(s,r,first).ok {return "No memory to go back to the tick of the violation"}
    if problem:=api_filmstrip_take(s,strip,run_ref(s,r),0);problem!="" {return problem}
    last:=history_frame_of(h,first).tick
    for serial:=first+1;serial<=h.serial;serial+=1 {
        f:=history_frame_of(h,serial)
        if f==nil || f.tick>to {break}
        if !history_seek(s,r,serial).ok {return "No memory to play the past again"}
        if f.tick<last+every {continue}
        if problem:=api_filmstrip_take(s,strip,run_ref(s,r),0);problem!="" {return problem}
        last=f.tick
    }
    return ""
}
