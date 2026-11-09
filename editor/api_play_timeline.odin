package editor

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The ticks a step runs as a timeline of segments, each holding its input for
// its ticks, and the samples it takes of the game along them: before the
// first tick, every some ticks and after the last. A sample (a row of a
// trace, a cell of a filmstrip) is kept in the memory of the call, between
// ticks: the tick of the game allocates nothing for it.

API_STEP_SEGMENTS :: 32
API_TRACE_ENTITIES :: 4
API_TRACE_FIELDS :: 8
API_TRACE_ROWS :: 256

Api_Play_Segment :: struct {
    ticks:int `mirai:"optional,max=3600,label=Fixed ticks it holds this input; 1 or more; in place of seconds"`,
    seconds:f32 `mirai:"optional,label=Game time it holds this input in place of ticks: the nearest whole ticks and at least 1"`,
    keys:core.Keys `mirai:"optional,label=Keys held in every tick of the segment; they go to the local seat with the focus"`,
    mouse_buttons:core.Mouse_Buttons `mirai:"optional,label=Buttons held in every tick of the segment"`,
    tap_keys:core.Keys `mirai:"optional,label=Keys pressed and released inside its first tick: a press shorter than a tick that is never down"`,
    tap_buttons:core.Mouse_Buttons `mirai:"optional,label=Buttons pressed and released inside its first tick"`,
    mouse_position:[2]f32 `mirai:"optional,label=Where the pointer goes at its first tick in points of the window from its top left; it stays there after it"`,
    mouse_delta:[2]f32 `mirai:"optional,label=Relative motion of the mouse in points spread evenly over its ticks: a look that turns along the segment"`,
    wheel:[2]f32 `mirai:"optional,label=Added to its first tick"`,
    text:[ui.INPUT_TEXT_CAPACITY]u8 `mirai:"optional,text,label=Printable ASCII typed in its first tick"`,
    gamepads:[core.GAMEPAD_CAPACITY]Api_Play_Gamepad `mirai:"optional,label=The gamepads connected in every tick of the segment"`,
}

Api_Play_Trace :: struct {
    entity:[API_ENTITY_TEXT]u8 `mirai:"optional,text,label=The entity by its name or a path Parent/Child or its id or its handle; a name with * stands for any run of characters and takes every entity it fits"`,
    component:[64]u8 `mirai:"optional,text,label=Only the entities that have this component"`,
    storage:[64]u8 `mirai:"optional,text,label=A storage of the world in place of entities"`,
    view:bool `mirai:"optional,label=What the player sees as play.view writes it in place of entities or a storage: the entities named are its points"`,
    fields:[API_TRACE_FIELDS][128]u8 `mirai:"text,label=Paths inside the document of an entity as play.inspect writes it (or inside the storage or the view): names joined by dots and [i] for element i as world_position or components.Motion.linear[1] or points[0].normalized"`,
    every:int `mirai:"optional,min=1,max=3600,label=Ticks between two rows"`,
    include_runtime:bool `mirai:"optional,label=Hidden fields and transient component state as play.inspect with include_runtime reads them"`,
}

// What play.step writes: Api_Play_Result and its trace.
Api_Play_Step_Result :: struct {
    playing,paused:bool `mirai:"optional"`,
    detached:bool `mirai:"optional,label=The run is of a turn: the editor does not show it"`,
    simulating:bool `mirai:"optional"`,
    tick:u64 `mirai:"optional"`,
    seconds:f64 `mirai:"optional"`,
    entities:int `mirai:"optional"`,
    ticks_dropped:u64 `mirai:"optional"`,
    game_camera:bool `mirai:"optional"`,
    input_released:bool `mirai:"optional"`,
    building:bool `mirai:"optional,label=An Odin source changed since the last build: the build runs and the game starts once it stands"`,
    ran:int `mirai:"label=The ticks it ran"`,
    met:bool `mirai:"label=With until: whether they held when it stopped"`,
    scripted:int `mirai:"optional,label=Ticks left of the input play.input scheduled: the next steps without input play them"`,
    trace:Api_Play_Trace_Table `mirai:"optional,label=With trace: the values it read"`,
    observe:Api_Play_Observe `mirai:"optional,label=With observe: what play.observe says after the ticks in place of the rest but ran and met; null when the game ended"`,
}
Api_Play_Trace_Table :: struct {
    columns:[1]Api_Play_Trace_Column `mirai:"list,label=What each value of a row is: every field of the first entity and then of the next"`,
    rows:[1]Api_Play_Trace_Row `mirai:"list,label=One before the first tick and one every every ticks and one after the last"`,
}
Api_Play_Trace_Column :: struct {
    entity:core.Entity `mirai:"optional,label=The handle of the entity"`,
    name:[64]u8 `mirai:"optional,text,label=The name of the entity"`,
    storage:[64]u8 `mirai:"optional,text,label=The storage in place of an entity"`,
    view:bool `mirai:"optional,label=The view in place of an entity"`,
    field:[128]u8 `mirai:"text"`,
}
Api_Play_Trace_Row :: struct {
    tick:u64 `mirai:"label=The tick of the game it was read at"`,
    values:u8 `mirai:"any,label=One per column as play.inspect writes it; null where the entity or its component is gone"`,
}

// One segment of input of a step, checked.
@(private)
Api_Step_Input :: struct {
    ticks:int,
    keys:core.Keys,
    buttons:core.Mouse_Buttons,
    tap_keys:core.Keys, // pressed and released inside the first tick
    tap_buttons:core.Mouse_Buttons,
    mouse_position:[2]f32,
    placed:bool, // mouse_position was given
    mouse_delta:[2]f32, // along all its ticks
    wheel:[2]f32,
    text:string,
    gamepads:[core.GAMEPAD_CAPACITY]core.Gamepad,
    pad_taps:[core.GAMEPAD_CAPACITY]platform.Gamepad_Buttons, // pressed and released inside the first tick
}

// A segment of the params; raw is its JSON object, at names it in errors and
// tick_dt is the seconds of a tick.
@(private)
api_segment_read :: proc(call:^api.Call,segment:^Api_Play_Segment,raw:string,at:string,tick_dt:f32) -> (step:Api_Step_Input,ok:bool) {
    values:[4]string
    api.object_values(call.allocator,raw,{"mouse_position","gamepads","ticks","seconds"},values[:])
    step={ticks=segment.ticks,keys=segment.keys,buttons=segment.mouse_buttons,tap_keys=segment.tap_keys,tap_buttons=segment.tap_buttons,mouse_position=segment.mouse_position,placed=values[0]!="",mouse_delta=segment.mouse_delta,wheel=segment.wheel}
    if values[3]!="" {
        if values[2]!="" {api.call_failf(call,api.INVALID_PARAMS,"%sticks and %sseconds both say how long it holds: give one",at,at);return}
        span,timed:=api_seconds_ticks(call,at,f64(segment.seconds),tick_dt,API_STEP_LIMIT)
        if !timed {return}
        step.ticks=span
    }
    if step.ticks<1 {api.call_failf(call,api.INVALID_PARAMS,"%sticks: give the ticks it holds its input (1 or more) or seconds",at);return}
    if both:=step.keys&step.tap_keys;both!={} {api.call_failf(call,api.INVALID_PARAMS,"%stap_keys: %v are in keys too; a key is held or tapped",at,both);return}
    if both:=step.buttons&step.tap_buttons;both!={} {api.call_failf(call,api.INVALID_PARAMS,"%stap_buttons: %v are in mouse_buttons too; a button is held or tapped",at,both);return}
    if step.placed && (!rpc_finite(step.mouse_position.x) || !rpc_finite(step.mouse_position.y)) {
        api.call_failf(call,api.INVALID_PARAMS,"%smouse_position takes two finite numbers: points of the window from its top left",at)
        return
    }
    if !rpc_finite(step.mouse_delta.x) || !rpc_finite(step.mouse_delta.y) || !rpc_finite(step.wheel.x) || !rpc_finite(step.wheel.y) {
        api.call_failf(call,api.INVALID_PARAMS,"%smouse_delta and wheel take finite numbers",at)
        return
    }
    step.text=base.text_get(segment.text[:])
    for c in step.text {
        if c<' ' || c>'~' {api.call_failf(call,api.INVALID_PARAMS,"%stext takes printable ASCII from space to ~; %q has a character outside it",at,step.text);return}
    }
    for pad in segment.gamepads[:api_list_count(values[1])] {
        g:=&step.gamepads[pad.slot]
        if g.connected {api.call_failf(call,api.INVALID_PARAMS,"%sgamepads: slot %d is given twice; give each gamepad once",at,pad.slot);return}
        if both:=pad.buttons&pad.tapped;both!={} {api.call_failf(call,api.INVALID_PARAMS,"%sgamepads: slot %d holds and taps %v; a button is held or tapped",at,pad.slot,both);return}
        g.connected,g.down=true,pad.buttons
        g.axes={.Left_X=pad.left_stick.x,.Left_Y=pad.left_stick.y,.Right_X=pad.right_stick.x,.Right_Y=pad.right_stick.y,.Left_Trigger=pad.left_trigger,.Right_Trigger=pad.right_trigger}
        step.pad_taps[pad.slot]=pad.tapped
    }
    return step,true
}

// The JSON text of each element of an array, up to len(items); how many there are.
@(private)
api_list_items :: proc(text:string,items:[]string) -> int {
    if text=="" {return 0}
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    if !serial.text_accept(&r,'[') || serial.text_accept(&r,']') {return 0}
    count:=0
    for {
        serial.text_peek(&r)
        start:=r.offset
        if !serial.text_skip(&r) {break}
        if count<len(items) {items[count]=r.text[start:r.offset]}
        count+=1
        if !serial.text_accept(&r,',') {break}
    }
    return min(count,len(items))
}

// The segments given as JSON in raw, checked; their ticks are at most a step.
@(private)
api_segments_read :: proc(call:^api.Call,segments:[]Api_Play_Segment,raw:string,tick_dt:f32) -> (timeline:[]Api_Step_Input,ok:bool) {
    items:=make([]string,len(segments),call.allocator)
    count:=api_list_items(raw,items)
    if count==0 {api.call_fail(call,api.INVALID_PARAMS,`segments is empty: give them as [{"ticks": 2, "keys": ["Space"]}, {"seconds": 0.5}] or leave it out`);return}
    timeline=make([]Api_Step_Input,count,call.allocator)
    for &step,i in timeline {
        step=api_segment_read(call,&segments[i],items[i],fmt.tprintf("segments[%d].",i),tick_dt) or_return
    }
    if total:=api_timeline_ticks(timeline);total>API_STEP_LIMIT {
        api.call_failf(call,api.INVALID_PARAMS,"segments run %d ticks and a step runs at most %d: split them into several calls",total,API_STEP_LIMIT)
        return
    }
    return timeline,true
}

// The whole ticks of a game time, the nearest and at least 1; ok is false
// after failing the call. at names the entry in the error (with its separator)
// and limit is the most ticks it may be.
api_seconds_ticks :: proc(call:^api.Call,at:string,seconds:f64,tick_dt:f32,limit:int) -> (span:int,ok:bool) {
    count:=seconds/f64(max(tick_dt,1e-6))
    if !rpc_finite(f32(seconds)) || !(seconds>0) || count>f64(limit) {
        api.call_failf(call,api.INVALID_PARAMS,"%sseconds takes a time above 0 and up to %d ticks of %g s",at,limit,tick_dt)
        return
    }
    return max(int(math.round(count)),1),true
}

// The input of play.step along its ticks: its segments, or the input fields as one segment of ticks.
@(private)
api_step_timeline :: proc(call:^api.Call,params:^Api_Play_Step_Params,tick_dt:f32) -> (timeline:[]Api_Step_Input,ok:bool) {
    keys:=[?]string{"segments","ticks","seconds","keys","mouse_buttons","tap_keys","tap_buttons","mouse_position","mouse_delta","wheel","text","gamepads"}
    values:[len(keys)]string
    api.object_values(call.allocator,call.raw,keys[:],values[:])
    if values[0]!="" {
        for value,i in values[1:] {
            if value!="" {api.call_failf(call,api.INVALID_PARAMS,"%s goes inside each of segments, which carry their own ticks and input: move it there or leave segments out",keys[i+1]);return}
        }
        return api_segments_read(call,params.segments[:],values[0],tick_dt)
    }
    flat:=new(Api_Play_Segment,call.allocator)
    flat^={ticks=params.ticks,seconds=params.seconds,keys=params.keys,mouse_buttons=params.mouse_buttons,tap_keys=params.tap_keys,tap_buttons=params.tap_buttons,mouse_position=params.mouse_position,mouse_delta=params.mouse_delta,wheel=params.wheel,text=params.text,gamepads=params.gamepads}
    timeline=make([]Api_Step_Input,1,call.allocator)
    timeline[0]=api_segment_read(call,flat,call.raw,"",tick_dt) or_return
    return timeline,true
}

@(private)
api_timeline_ticks :: proc(timeline:[]Api_Step_Input) -> (ticks:int) {
    for step in timeline {ticks+=step.ticks}
    return
}

// Whether a timeline gives the player any input.
@(private)
api_timeline_input :: proc(timeline:[]Api_Step_Input) -> bool {
    for step in timeline {
        if step.keys!={} || step.buttons!={} || step.tap_keys!={} || step.tap_buttons!={} || step.mouse_delta!={} || step.wheel!={} || step.placed || step.text!="" || step.gamepads!={} {return true}
    }
    return false
}

// The input of devices play.input schedules for the next ticks of a run: each
// tick the API runs without input of its own plays the next one, and nothing
// is held once it ends. Its texts live here, not in the memory of a call.
Run_Script :: struct {
    run:u64, // Run.id of the run it is for; another run in the same place has none
    steps:[API_STEP_SEGMENTS]Api_Step_Input, // their text is in texts
    texts:[API_STEP_SEGMENTS][ui.INPUT_TEXT_CAPACITY]u8,
    count,segment,at:int, // at: the ticks of segment already played
}

// The script of a run of s.runs; nil without the API, which keeps them.
@(private)
run_script :: proc(s:^Session,r:^Run) -> ^Run_Script {
    st:=api_state(s)
    if st==nil || r==nil {return nil}
    if uintptr(r)<uintptr(&s.runs[0]) {return nil}
    place:=int(uintptr(r)-uintptr(&s.runs[0]))/size_of(Run)
    if place>=len(s.runs) {return nil}
    script:=&st.scripts[place]
    if script.run!=r.id {script^={run=r.id}}
    return script
}

@(private)
run_script_set :: proc(script:^Run_Script,timeline:[]Api_Step_Input) {
    script^={run=script.run,count=len(timeline)}
    for step,i in timeline {
        script.steps[i]=step
        script.steps[i].text=""
        copy(script.texts[i][:],step.text)
    }
}

// The ticks of a script still to play.
@(private)
run_script_ticks :: proc "contextless" (script:^Run_Script) -> (ticks:int) {
    if script==nil || script.segment>=script.count {return 0}
    for step in script.steps[script.segment:script.count] {ticks+=step.ticks}
    return ticks-script.at
}

// The input of the next tick of a script and which tick of its segment it is;
// nothing held once it ended.
@(private)
run_script_take :: proc(script:^Run_Script) -> (step:Api_Step_Input,at:int) {
    if script==nil {return {ticks=1},0}
    for script.segment<script.count && script.at>=script.steps[script.segment].ticks {script.segment+=1;script.at=0}
    if script.segment>=script.count {
        script^={run=script.run}
        return {ticks=1},0
    }
    step,at=script.steps[script.segment],script.at
    step.text=base.text_get(script.texts[script.segment][:])
    script.at+=1
    return
}

// Why a call that gives input of its own cannot run while r has a script; "" when it can.
@(private)
run_script_blocks :: proc(s:^Session,r:^Run) -> string {
    if ticks:=run_script_ticks(run_script(s,r));ticks>0 {
        return fmt.tprintf("play.input scheduled %d more ticks of input, which the next steps play: step without input to play them, or play.input with release_all to drop them",ticks)
    }
    return ""
}

// Takes a sample of the game w after ran ticks of the step; "" or why the step fails.
@(private)
Api_Step_Sample :: #type proc(s:^Session,data:rawptr,w:core.World_Ref,ran:int) -> string

@(private)
Api_Step_Sampler :: struct {
    every:int, // ticks between two samples
    take:Api_Step_Sample, // nil: none
    data:rawptr,
}

// One frame of the editor, in which the runs asked for a tick take it; false when it ends.
@(private)
Api_Step_Frame :: #type proc(s:^Session) -> bool

@(private)
api_step_frame :: proc(s:^Session) -> bool {
    if st:=api_state(s);st!=nil && st.step_frame!=nil {return st.step_frame(s)}
    return api_frames(s,1,0)>0
}

@(private)
Api_Step_Run :: struct {
    owner,player:int,
    timeline:[]Api_Step_Input,
    until:[]Api_Play_Condition, // checked by the caller
    sampler:Api_Step_Sampler,   // the sample before the first tick is the caller's
}

// Runs the ticks of a timeline, its segments one after the other, until its
// conditions hold, sampling every some ticks and after the last one. A
// timeline without input plays the script of the run instead. The user's Play
// pauses first. problem: why it stopped failing.
@(private)
api_step_run :: proc(s:^Session,run:^Api_Step_Run,frame:Api_Step_Frame) -> (ran:int,met:bool,problem:string) {
    target:=run_player(s,run.owner,run.player)
    if target==nil {return 0,false,"That player has no run: play.start with online opens them"}
    if len(run.until)>0 {
        if met,problem=api_conditions_read(s,run_ref(s,target),run.until,nil,"until");problem!="" {return}
    }
    if run.owner==0 && !play_paused(s) {play_pause(s,true,stepped=true)}
    every:=max(run.sampler.every,1)
    total:=api_timeline_ticks(run.timeline)
    sampled:=0
    segment,at:=0,0
    scripted:=!api_timeline_input(run.timeline)
    for ran<total {
        if len(run.until)>0 && met {break}
        for at>=run.timeline[segment].ticks {segment+=1;at=0}
        api_step_tick(s,run.owner,run.player,scripted?nil:&run.timeline[segment],at)
        if !frame(s) {return}
        ran+=1;at+=1
        // The run ends with its turn or with the document.
        if run_find(s,run.owner)==nil {return}
        if target=run_player(s,run.owner,run.player);target==nil {return}
        qa_tick(s,target)
        if len(run.until)>0 {
            if met,problem=api_conditions_read(s,run_ref(s,target),run.until,nil,"until");problem!="" {
                problem=fmt.tprintf("%s, after %d ticks",problem,ran)
                return
            }
        }
        if run.sampler.take!=nil && ran%every==0 {
            if problem=run.sampler.take(s,run.sampler.data,run_ref(s,target),ran);problem!="" {return}
            sampled=ran
        }
    }
    if run.sampler.take!=nil && sampled!=ran {problem=run.sampler.take(s,run.sampler.data,run_ref(s,target),ran)}
    return
}

// The entities or the storage a trace reads, its fields and the rows it keeps.
@(private)
Api_Trace :: struct {
    entities:[API_TRACE_ENTITIES]core.Entity,
    names:[API_TRACE_ENTITIES]string, // when the step began, for the columns
    count:int,
    storage:int, // in the storages of the world; -1: entities
    view:bool,   // the view, whose points are the entities
    fields:[API_TRACE_FIELDS]string,
    field_count:int,
    include_runtime:bool,
    scratch:[]u8,
    rows:serial.Writer, // their JSON, in the memory of the call
    row_count:int,
}

// Reads the trace of params (raw: its JSON) for a step of ticks at most and
// takes its first row from w; "" or what is wrong with it.
@(private)
api_trace_read :: proc(s:^Session,call:^api.Call,w:core.World_Ref,p:^Api_Play_Trace,raw:string,ticks:int,trace:^Api_Trace) -> (problem:string) {
    st:=api_state(s)
    trace^={storage=-1,view=p.view,include_runtime=p.include_runtime}
    values:[1]string
    api.object_values(call.allocator,raw,{"fields"},values[:])
    trace.field_count=api_list_count(values[0])
    if trace.field_count==0 {return `trace.fields is empty: give the paths to read, as ["world_position", "components.Motion.linear"]`}
    for &field,i in trace.fields[:trace.field_count] {
        field=base.text_get(p.fields[i][:])
        if field=="" {return fmt.tprintf("trace.fields[%d] is empty: give a path as world_position",i)}
    }
    every:=max(p.every,1)
    if rows:=1+(ticks+every-1)/every;rows>API_TRACE_ROWS {
        return fmt.tprintf("trace would keep %d rows and keeps at most %d: give every %d or more",rows,API_TRACE_ROWS,(ticks+API_TRACE_ROWS-2)/(API_TRACE_ROWS-1))
    }
    entity,component,storage:=base.text_get(p.entity[:]),base.text_get(p.component[:]),base.text_get(p.storage[:])
    pattern:=strings.contains_rune(entity,'*')
    named:=entity!="" || component!=""
    switch {
    case p.view && storage!="": return "trace: view reads what the player sees in place of a storage: leave storage out"
    case !p.view && named==(storage!=""): return "trace: name what it reads: entities by entity or component (they narrow each other), a storage or the view"
    }
    if storage!="" {
        for &info,i in s.info.storages {if st.storage_types[i]!=serial.TYPE_NONE && info.name==storage {trace.storage=i;break}}
        if trace.storage<0 {return fmt.tprintf("trace.storage %q is not a storage of the game; play.inspect with storages lists them",storage)}
    } else if named {
        table:^core.Table_Info
        if component!="" {
            problem:string
            if table,problem=api_component_named(w,component);table==nil {return fmt.tprintf("trace.component: %s; component.list lists them",problem)}
        }
        candidates:[]core.Entity
        one:[1]core.Entity
        if entity!="" && !pattern {
            e,wrong:=api_entity_select(w,entity,"trace.entity",true,call.allocator)
            if wrong!="" {return wrong}
            one[0]=e
            candidates=one[:]
        } else {candidates=api_entities_ordered(w)}
        matched:=0
        for e in candidates {
            if pattern && !api_name_match(entity,entity_name(w,e)) {continue}
            if table!=nil && core.raw_find(core.world_table_at(w,table),table.info,e)==nil {continue}
            if matched<API_TRACE_ENTITIES {trace.entities[matched],trace.names[matched]=e,strings.clone(entity_name(w,e),call.allocator)}
            matched+=1
        }
        if matched==0 {return "trace matches no entity of the game: play.inspect lists them"}
        if matched>API_TRACE_ENTITIES {return fmt.tprintf("trace matches %d entities and reads at most %d: narrow it with entity or component",matched,API_TRACE_ENTITIES)}
        trace.count=matched
    }
    if !trace.view {
        scratch,memory:=make([]u8,max(st.largest,1),call.allocator)
        if memory!=nil {return "the request needs more scratch memory than the server has"}
        trace.scratch=scratch
    }
    serial.writer_init(&trace.rows,4096,call.allocator)
    return api_trace_take(s,trace,w,0)
}

// A row of a trace: the tick and the value of each field of each document.
// In the first row a path that is not there fails, unless it names a
// component the entity does not have yet; later it is null.
@(private)
api_trace_take :: proc(s:^Session,data:rawptr,w:core.World_Ref,ran:int) -> string {
    trace:=cast(^Api_Trace)data
    st:=api_state(s)
    out:=&trace.rows
    tick:u64
    if t:=core.world_storage_of(w,core.Time);t!=nil {tick=t.tick}
    if trace.row_count>0 {serial.write_u8(out,',')}
    serial.text_write_raw(out,`{"tick":`);serial.text_write_uint(out,tick)
    api.write_key(out,"values");serial.write_u8(out,'[')
    doc:serial.Writer
    serial.writer_init(&doc,0,context.temp_allocator)
    omitted:=serial.Field_Flags{.Transient,.Hidden} if !trace.include_runtime else serial.Field_Flags{}
    for d in 0..<(trace.storage>=0 || trace.view?1:trace.count) {
        serial.writer_reset(&doc)
        there:=true
        if trace.view {
            targets:[API_TRACE_ENTITIES]Play_View_Target
            for e,i in trace.entities[:trace.count] {targets[i]={entity=e,named=true}}
            text,problem:=play_view_json(w,targets[:trace.count])
            if problem!="" {return problem}
            serial.text_write_raw(&doc,text)
        } else if trace.storage>=0 {
            info:=&s.info.storages[trace.storage]
            api_value_out(w,info.info,rawptr(uintptr(w.data)+info.offset),trace.scratch,handles=true)
            serial.text_write(&doc,&st.schema,st.storage_types[trace.storage],trace.scratch[:info.info.size],.Line,omit_fields=omitted)
        } else if e:=trace.entities[d];core.alive(core.world_entities(w),e) {
            api_entity_write(s,w,&doc,e,true,trace.scratch,true,trace.include_runtime)
        } else {there=false}
        whole:json.Value
        if there {
            parse_error:json.Error
            if whole,parse_error=json.parse(serial.writer_bytes(&doc),allocator=context.temp_allocator);parse_error!=nil {return "trace: a value could not be read back as JSON"}
        }
        for field,i in trace.fields[:trace.field_count] {
            if d>0 || i>0 {serial.write_u8(out,',')}
            if !there {serial.text_write_raw(out,"null");continue}
            leaf,missing:=api_json_select(whole,field)
            switch {
            case missing=="":
                serial.text_write_raw(out,api_json_text(leaf))
            case trace.row_count==0 && !api_trace_component_absent(s,whole,field):
                return fmt.tprintf("trace.fields[%d] %q: %s",i,field,missing)
            case:
                serial.text_write_raw(out,"null")
            }
        }
    }
    serial.text_write_raw(out,"]}")
    trace.row_count+=1
    return ""
}

// Whether a path names a component of the game that the document of an entity lacks.
@(private)
api_trace_component_absent :: proc(s:^Session,whole:json.Value,path:string) -> bool {
    if !strings.has_prefix(path,"components.") {return false}
    rest:=path[len("components."):]
    name:=rest
    if end:=strings.index_any(rest,".[");end>=0 {name=rest[:end]}
    if component_table(s,name)==nil {return false}
    doc,_:=whole.(json.Object)
    components,_:=doc["components"].(json.Object)
    _,has:=components[name]
    return !has
}

// The result of play.step: that of the other play methods, and its trace.
@(private)
api_play_step_write :: proc(s:^Session,call:^api.Call,r:^Run,ran:int,met:bool,trace:^Api_Trace) {
    result:Api_Play_Result
    api_play_result_fill(s,&result,r)
    result.ran,result.met=ran,met
    sc:=&api_state(s).server.schema
    index,found:=sc.lookup[Api_Play_Result]
    if !found {api.call_fail(call,api.INTERNAL_ERROR,"the result of the play methods has no schema");return}
    out:=call.out
    serial.text_write(out,sc,index,mem.ptr_to_bytes(&result),.Line)
    if trace==nil {return}
    out.count-=1 // the brace that closes it
    api_trace_write(s,out,trace)
    serial.write_u8(out,'}')
}

// The small answer of play.step with observe: its ticks and what play.observe
// says after them, and its trace when it read one.
@(private)
api_play_step_observe_write :: proc(s:^Session,call:^api.Call,r:^Run,ran:int,met:bool,targets:[]string,trace:^Api_Trace) {
    out:=call.out
    serial.write_u8(out,'{')
    api.write_int(out,"ran",i64(ran),true)
    api.write_bool(out,"met",met)
    api.write_key(out,"observe")
    if r!=nil {play_observe_write(s,out,r,targets,API_OBSERVE_NEAREST,call.allocator)} else {serial.text_write_raw(out,"null")}
    if trace!=nil {api_trace_write(s,out,trace)}
    serial.write_u8(out,'}')
}

// The trace of a result, as its last key: its columns and its rows.
@(private)
api_trace_write :: proc(s:^Session,out:^serial.Writer,trace:^Api_Trace) {
    api.write_key(out,"trace");serial.text_write_raw(out,`{"columns":[`)
    first:=true
    for d in 0..<(trace.storage>=0 || trace.view?1:trace.count) {
        for field in trace.fields[:trace.field_count] {
            if !first {serial.write_u8(out,',')}
            first=false
            if trace.view {
                serial.text_write_raw(out,`{"view":true`)
            } else if trace.storage>=0 {
                serial.text_write_raw(out,`{"storage":`);serial.text_write_string(out,s.info.storages[trace.storage].name)
            } else {
                serial.text_write_raw(out,`{"entity":"`);serial.text_write_hex(out,u64(trace.entities[d]))
                serial.text_write_raw(out,`","name":`);serial.text_write_string(out,trace.names[d])
            }
            api.write_key(out,"field");serial.text_write_string(out,field)
            serial.write_u8(out,'}')
        }
    }
    serial.text_write_raw(out,`],"rows":[`)
    serial.text_write_raw(out,string(serial.writer_bytes(&trace.rows)))
    serial.text_write_raw(out,"]}")
}
