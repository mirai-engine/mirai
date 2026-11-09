package playtest_editor

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"

// Monitors of the game a run plays, armed by play.qa.start and read by
// play.qa.report, for the ticks the API runs (play.step, a scenario,
// play.explore, a filmstrip). The first thing the API does to a run
// reserves its log of what the run received, from which a repro plays the same
// ticks again whenever the monitors started; a tick writes into that.

QA_VIOLATIONS :: 64
QA_LOG_ENTRIES :: 8192
QA_LOG_TEXT :: 256*1024
@(private) QA_MOVE_HELD :: f32(0.05)      // length of a Move_Input that asks for movement
@(private) QA_STUCK_DISTANCE :: f32(0.1)  // meters that count as having moved
@(private) QA_MEMORY_EVERY :: 30          // ticks between two readings of the memory
@(private) QA_FALL_MARGIN :: f32(5)       // meters under the lowest of the scene where falling starts

Api_Qa_Kind :: enum u8 {Frame_Time,Memory,Stuck,Fell,Non_Finite,Problem}
Api_Qa_Severity :: enum u8 {Warning,Error}

Api_Play_Qa_Start_Params :: struct {
    frame_ms:f32 `mirai:"optional,min=0,unit=ms,label=Longest whole frame of the application; 0: off"`,
    memory_mb:f32 `mirai:"optional,min=0,label=Megabytes the process may grow since this call; 0: off"`,
    stuck_seconds:f32 `mirai:"optional,min=0,unit=s,label=Game time the body may ask to move without moving; 0: off"`,
    fall_below:f32 `mirai:"optional,unit=m,label=World height the body must stay above; absent: a little under the lowest of the scene"`,
    falls:bool `mirai:"optional,label=Falling below fall_below is a violation"`,
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
    filmstrip:[editor.API_PATH_BYTES]u8 `mirai:"optional,text,label=PNG of the ticks around that violation from the past of the run; the run stays where it is"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Qa_Report :: struct {
    passed:bool `mirai:"label=No violation"`,
    tick:u64 `mirai:"label=The tick of the game now"`,
    violations:[1]Api_Play_Qa_Violation `mirai:"list"`,
    dropped:int `mirai:"optional,label=Violations that did not fit"`,
    repro:[editor.API_PATH_BYTES]u8 `mirai:"optional,text,label=The scenario written"`,
    filmstrip:editor.Api_Capture_Result `mirai:"optional,label=The filmstrip written"`,
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
    entity:[editor.API_HANDLE_TEXT]u8 `mirai:"optional,text,label=The entity it is about"`,
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
    given:editor.Api_Step_Input, // Input: its text is in the text of the log
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
    stuck,fell:bool,  // the episode that is going on
}

@(private)
qa_api_register :: proc(s:^editor.Session) {
    defaults:=Api_Play_Qa_Start_Params{stuck_seconds=3,falls=true,non_finite=true,problems=true}
    report:=Api_Play_Qa_Report_Params{violation=-1}
    editor.api_method_register(s,{name="play.qa.start",summary="Starts monitors on the game of the caller, for the ticks the API runs: frame time, memory, stuck, falling, non-finite transforms and core.report problems. A violation can write a repro whenever they start, as long as the API drove the game from its first tick.",params=Api_Play_Qa_Start_Params,params_info=type_info_of(Api_Play_Qa_Start_Params),result=Api_Play_Qa_Start_Result,result_info=type_info_of(Api_Play_Qa_Start_Result),defaults=&defaults,run=api_play_qa_start})
    editor.api_method_register(s,{name="play.qa.report",summary="The violations the monitors of play.qa.start saw, with tick, place and severity; for one of them writes a repro scenario or a filmstrip around its tick.",params=Api_Play_Qa_Report_Params,params_info=type_info_of(Api_Play_Qa_Report_Params),result=Api_Play_Qa_Report,result_info=type_info_of(Api_Play_Qa_Report),writes_result=true,defaults=&report,run=api_play_qa_report})
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
qa_reserve :: proc(s:^editor.Session,r:^editor.Run) -> ^Run_Qa {
    slot:=playtest_run(s,r)
    if slot==nil {return nil}
    if slot.qa!=nil {return slot.qa}
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
    if t:=core.world_storage_of(editor.run_ref(s,r),core.Time);t!=nil {tick=t.tick}
    q.started,q.tick,q.from_zero=tick,tick,tick==0
    slot.qa=q
    return q
}

// Starts the monitors of a run, or takes new limits and starts counting again,
// keeping its log. The log says where, so that a repro starts them there.
@(private)
qa_arm :: proc(s:^editor.Session,r:^editor.Run,limits:Qa_Limits) -> ^Run_Qa {
    q:=qa_reserve(s,r)
    if q==nil {return nil}
    w:=editor.run_ref(s,r)
    seconds:f64
    if t:=core.world_storage_of(w,core.Time);t!=nil {seconds=t.seconds}
    q.armed=true
    q.limits=limits
    q.violation_count,q.dropped=0,0
    q.counts={}
    q.stuck,q.fell=false,false
    _,body:=editor.play_focused(w)
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
qa_input_held_only :: proc(step:^editor.Api_Step_Input) -> bool {
    return step.tap_keys=={} && step.tap_buttons=={} && !step.placed && step.wheel=={} && step.mouse_delta=={} && step.text=="" && step.pad_taps=={}
}

// The input one tick receives, before it runs: at is that tick of its
// segment. The holds waiting for it come first, as play.input asks them.
@(private)
qa_log_tick :: proc(s:^editor.Session,r:^editor.Run,step:^editor.Api_Step_Input,at:int) {
    q:=qa_reserve(s,r)
    if q==nil {return}
    w:=editor.run_ref(s,r)
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
qa_log_call :: proc(s:^editor.Session,r:^editor.Run,method,params:string) {
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
qa_log_focus :: proc(s:^editor.Session,r:^editor.Run,slot:int) {
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

// How long the body has asked to move and stayed where it was, in seconds of
// the game; 0 when it moved or does not ask to. The one measure of stuck of a run.
@(private)
stuck_watch :: proc(watch:^Stuck_Watch,w:core.World_Ref,body:core.Entity,at:[3]f32,seconds:f64) -> f64 {
    if body==core.NONE || !play_moving(w,body) || !watch.anchored || linalg.length(at-watch.anchor)>=QA_STUCK_DISTANCE {
        watch^={at,seconds,true}
    }
    return seconds-watch.since
}

@(private)
qa_finite :: proc "contextless" (values:[]f32) -> bool {
    for v in values {if v-v!=0 {return false}}
    return true
}

// The monitors after one tick the API ran.
@(private)
qa_tick :: proc(s:^editor.Session,r:^editor.Run) {
    q:=qa_of(s,r)
    if q==nil {return}
    w:=editor.run_ref(s,r)
    tick,seconds:=u64(0),f64(0)
    if t:=core.world_storage_of(w,core.Time);t!=nil {tick,seconds=t.tick,t.seconds}
    q.tick=tick
    if !q.armed {return}
    limits:=&q.limits
    _,body:=editor.play_focused(w)
    at:[3]f32
    if body!=core.NONE {at=editor.entity_world(w,body).position}
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
        still:=stuck_watch(&playtest_run(s,r).stuck,w,body,at,seconds)
        if still==0 {
            q.stuck=false
        } else if still>=f64(limits.stuck_seconds) && !q.stuck {
            q.stuck=true
            qa_violation_add(q,{kind=.Stuck,severity=.Warning,tick=tick,position=at,value=f32(still),limit=limits.stuck_seconds,entity=body},false)
        }
    }
}

@(private)
qa_limits_read :: proc(s:^editor.Session,call:^api.Call,p:^Api_Play_Qa_Start_Params) -> Qa_Limits {
    values:[1]string
    api.object_values(call.allocator,call.raw,{"fall_below"},values[:])
    limits:=Qa_Limits{frame_ms=p.frame_ms,memory_mb=p.memory_mb,stuck_seconds=p.stuck_seconds,fall_below=p.fall_below,falls=p.falls,non_finite=p.non_finite,problems=p.problems}
    if values[0]=="" && p.falls {limits.fall_below,limits.falls=qa_fall_default(s)}
    return limits
}

// A little under the lowest of the document: what no body stands on. No height
// when the scene is empty.
@(private)
qa_fall_default :: proc(s:^editor.Session) -> (height:f32,known:bool) {
    w:=editor.edited_world(s)
    entities:=editor.api_entities_ordered(w)
    if len(entities)==0 {return}
    return editor.api_entities_box(s,w,entities).min.y-QA_FALL_MARGIN,true
}

@(private)
api_play_qa_start :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Qa_Start_Params)
    r,own:=editor.api_play_own_run(s,call,p.player)
    if !own {return}
    q:=qa_arm(s,r,qa_limits_read(s,call,p))
    if q==nil {api.call_fail(call,api.SERVER_ERROR,"No memory for the monitors");return}
    result:=api.call_result(call,Api_Play_Qa_Start_Result)
    result.tick,result.repro=q.tick,q.from_zero && q.broken==""
}

// The violations, with the index of each.
@(private)
qa_violations_write :: proc(s:^editor.Session,out:^serial.Writer,q:^Run_Qa) {
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
            serial.write_u8(out,'"');serial.text_write_hex(out,u64(v.entity));serial.write_u8(out,'"')
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
api_play_qa_report :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Qa_Report_Params)
    r,_:=editor.api_play_run(s,call,p.player)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,editor.API_NO_GAME);return}
    q:=qa_of(s,r)
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
        strip=editor.api_filmstrip_around(s,call,r,q.violations[p.violation].tick,strip_path)
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

// ---------------------------------------------------------------- repro

@(private)
Repro_Writer :: struct {
    s:^editor.Session,
    r:^editor.Run,
    q:^Run_Qa,
    out:serial.Writer,
    steps:int,
    segments:[editor.API_STEP_SEGMENTS]^Qa_Entry,
    segment_ticks:[editor.API_STEP_SEGMENTS]int,
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
        if w.segment_count==editor.API_STEP_SEGMENTS || w.tick_sum==editor.API_STEP_LIMIT {repro_flush(w)}
        take:=min(ticks,editor.API_STEP_LIMIT-w.tick_sum)
        w.segments[w.segment_count],w.segment_ticks[w.segment_count]=e,take
        w.segment_count+=1
        w.tick_sum+=take
        ticks-=take
    }
}

// Holds that came together, as one play.input per seat.
@(private)
repro_holds :: proc(w:^Repro_Writer,entries:[]Qa_Entry) {
    m:=core.world_storage_of(editor.run_ref(w.s,w.r),input.Input_Map)
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

// What must hold for the violation not to happen: a violation fails the
// scenario, so the file reports the bug while it exists and passes once
// it is fixed.
@(private)
repro_monitor :: proc(out:^serial.Writer,q:^Run_Qa,v:^Qa_Violation) {
    l:=&q.limits
    serial.write_u8(out,'{')
    api.write_bool(out,"non_finite",v.kind==.Non_Finite,true)
    api.write_bool(out,"problems",v.kind==.Problem)
    api.write_bool(out,"falls",v.kind==.Fell)
    api.write_key(out,"stuck_seconds");api.write_number(out,v.kind==.Stuck?l.stuck_seconds:0)
    if v.kind==.Frame_Time {api.write_key(out,"frame_ms");api.write_number(out,l.frame_ms)}
    if v.kind==.Memory {api.write_key(out,"memory_mb");api.write_number(out,l.memory_mb)}
    if v.kind==.Fell {api.write_key(out,"fall_below");api.write_number(out,l.fall_below)}
    serial.write_u8(out,'}')
}

// The text of the scenario that plays a run from tick 0 to a violation.
@(private)
qa_repro_text :: proc(s:^editor.Session,r:^editor.Run,q:^Run_Qa,v:^Qa_Violation,allocator:=context.allocator) -> (text,problem:string) {
    if !q.from_zero {return "",fmt.tprintf("No repro: a repro plays from tick 0 and the game ran %d ticks by itself before the API drove it; give the game its ticks with play.step from the first one",q.started)}
    if q.broken!="" {return "",fmt.tprintf("No repro: %s",q.broken)}
    w:core.World_Ref=editor.run_ref(s,r)
    if network:=core.world_storage_of(w,core.Network);network!=nil && network.role!=.Standalone {return "","No repro: a game on the network does not play the same ticks again"}
    repro:Repro_Writer
    repro.s,repro.r,repro.q,repro.focus=s,r,q,-1
    serial.writer_init(&repro.out,8192,allocator)
    out:=&repro.out
    serial.write_u8(out,'{')
    path:=editor.document_path(s.document)
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
    repro_step_begin(&repro,"play.qa.report")
    serial.text_write_raw(out,"{}}]}")
    bytes:=serial.writer_bytes(out)
    if len(bytes)>editor.API_SCENARIO_FILE_BYTES {return "",fmt.tprintf("No repro: its scenario takes %d bytes and a scenario file %d",len(bytes),editor.API_SCENARIO_FILE_BYTES)}
    if repro.steps>editor.API_SCENARIO_STEPS {return "",fmt.tprintf("No repro: its scenario takes %d steps and a scenario file %d",repro.steps,editor.API_SCENARIO_STEPS)}
    return string(bytes),""
}

// Writes tests/scenarios/bug_<tick>.mirai of a violation; its file, or why not.
@(private)
qa_repro_write :: proc(s:^editor.Session,call:^api.Call,r:^editor.Run,v:^Qa_Violation,allocator:=context.allocator) -> (file,problem:string) {
    text,wrong:=qa_repro_text(s,r,qa_of(s,r),v,allocator)
    if wrong!="" {return "",wrong}
    path:=fmt.tprintf("%s/bug_%d%s",editor.SCENARIO_FOLDER,v.tick,editor.SCENARIO_EXTENSION)
    target,bad:=editor.api_file_path(s.project_root,path,context.temp_allocator)
    if bad!="" {return "",bad}
    if why,_:=editor.api_output_prepare(target);why!="" {return "",why}
    if error:=os.write_entire_file(target,transmute([]u8)text);error!=nil {return "",fmt.tprintf("%s could not be written: %s",target,os.error_string(error))}
    return path,""
}
