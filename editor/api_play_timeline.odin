package editor

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
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
API_PRESS_HELD :: 2 // ticks a press holds its button

Api_Play_Segment :: struct {
    duration:[api.DURATION_TEXT]u8 `mirai:"optional,text,name=for,label=How long it runs with this input: a number is ticks and a text ending in s is seconds as 120 or 1.5s; 1 tick when a step gives none"`,
    keys:core.Keys `mirai:"optional,label=Keys held in every tick; they go to the local seat with the focus; a key named by consecutive calls or segments stays held with no release between them and one left out is released"`,
    mouse_buttons:core.Mouse_Buttons `mirai:"optional,label=Buttons held in every tick; held across calls and segments as keys are"`,
    tap_keys:core.Keys `mirai:"optional,label=Keys pressed and released inside the first tick: a press shorter than a tick that is never down"`,
    tap_buttons:core.Mouse_Buttons `mirai:"optional,label=Buttons pressed and released inside the first tick"`,
    mouse_position:[2]f32 `mirai:"optional,label=Where the pointer is from the first tick on in points of the window from its top left (the image of capture over the density): the UI of the game takes it and its clicks; it stays there after it"`,
    mouse_delta:[2]f32 `mirai:"optional,label=Relative motion of the mouse in points spread evenly over the ticks: a look that turns along them"`,
    wheel:[2]f32 `mirai:"optional,label=Added to the first tick"`,
    text:[ui.INPUT_TEXT_CAPACITY]u8 `mirai:"optional,text,label=Printable ASCII typed in the first tick: the field of the UI of the game with the focus takes it"`,
    press:[ui.TREE_NAME_CAPACITY]u8 `mirai:"optional,text,label=The button of the screen on top to press by its name: the pointer goes over it and Left is held as a click takes; ticks or seconds run after the click; no other input with it"`,
    gamepads:[core.GAMEPAD_CAPACITY]Api_Play_Gamepad `mirai:"optional,label=The gamepads connected in every tick; gamepad i is that of the local seat of slot i when the game has several"`,
}

Api_Play_Trace :: struct {
    entity:[API_ENTITY_TEXT]u8 `mirai:"optional,text,entity,label=The entity by its name or a path Parent/Child or its id or its handle; a name with * stands for any run of characters and takes every entity it fits"`,
    component:[64]u8 `mirai:"optional,text,label=Only the entities that have this component"`,
    storage:[64]u8 `mirai:"optional,text,label=A storage of the world in place of entities"`,
    view:bool `mirai:"optional,label=What the player sees as play.view writes it in place of entities or a storage: the entities named are its points"`,
    fields:[API_TRACE_FIELDS][128]u8 `mirai:"text,label=Values as play.get names them for an entity (Motion.linear.1 or world_position) or names of fields and indices joined by dots inside the storage or the view (points.0.normalized); a[0].b is a.0.b"`,
    every:int `mirai:"optional,min=1,max=3600,label=Ticks between two rows"`,
    include_runtime:bool `mirai:"optional,label=Hidden fields and transient component state as play.inspect with include_runtime reads them"`,
}

// What play.step writes: Api_Play_Result, the ticks it ran and its trace.
Api_Play_Step_Result :: struct {
    using play:Api_Play_Result `mirai:"inline"`,
    ran:int `mirai:"label=The ticks it ran"`,
    met:bool `mirai:"label=With until: whether they held when it stopped"`,
    drive:Api_Play_Drive_Result `mirai:"optional,label=With drive: where the player ended and why it stopped; ran says its ticks"`,
    trace:Api_Play_Trace_Table `mirai:"optional,label=With trace: the values it read"`,
}
Api_Play_Trace_Table :: struct {
    columns:[]Api_Play_Trace_Column `mirai:"label=What each value of a row is: every field of the first entity and then of the next"`,
    rows:[]Api_Play_Trace_Row `mirai:"label=One before the first tick and one every every ticks and one after the last"`,
}
Api_Play_Trace_Column :: struct {
    entity:core.Entity `mirai:"optional,label=The handle of the entity"`,
    name:string `mirai:"optional,label=The name of the entity"`,
    storage:string `mirai:"optional,label=The storage in place of an entity"`,
    view:bool `mirai:"optional,label=The view in place of an entity"`,
    field:string,
}
Api_Play_Trace_Row :: struct {
    tick:u64 `mirai:"label=The tick of the game it was read at"`,
    values:serial.Json `mirai:"label=One per column as play.inspect writes it; null where the entity or its component is gone"`,
}

// One segment of input of a step, checked.
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
    press:string, // the button whose middle the pointer goes to, found when its first tick comes
}

// A segment of the params; raw is its JSON object, at names it in errors and
// tick_dt is the seconds of a tick.
@(private)
api_segment_read :: proc(call:^api.Call,segment:^Api_Play_Segment,raw:string,at:string,tick_dt:f32,fallback:=0) -> (step:Api_Step_Input,ok:bool) {
    values:[3]string
    api.object_values(call.allocator,raw,{"mouse_position","gamepads","for"},values[:])
    step={ticks=fallback,keys=segment.keys,buttons=segment.mouse_buttons,tap_keys=segment.tap_keys,tap_buttons=segment.tap_buttons,mouse_position=segment.mouse_position,placed=values[0]!="",mouse_delta=segment.mouse_delta,wheel=segment.wheel}
    step.press=base.text_get(segment.press[:])
    if values[2]!="" {
        step.ticks=api_call_duration(call,segment.duration[:],fmt.tprintf("%sfor",at),tick_dt,step.press!=""?0:1,API_STEP_LIMIT) or_return
    }
    if step.press!="" {
        if step.keys!={} || step.buttons!={} || step.tap_keys!={} || step.tap_buttons!={} || step.placed || step.mouse_delta!={} || step.wheel!={} || segment.text[0]!=0 || values[1]!="" {
            api.call_failf(call,api.INVALID_PARAMS,"%spress is a whole click: give other input in another segment or step",at)
            return
        }
        if values[2]=="" {step.ticks=0}
        return step,true
    }
    if step.ticks<1 {api.call_failf(call,api.INVALID_PARAMS,"%sfor: give how long it holds its input, %s",at,api.DURATION_FORM);return}
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
    for pad in segment.gamepads[:api.json_count(values[1])] {
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
    if count==0 {api.call_fail(call,api.INVALID_PARAMS,`segments is empty: give them as [{"for": 2, "keys": ["Space"]}, {"for": "0.5s"}] or leave it out`);return}
    timeline=make([]Api_Step_Input,count,call.allocator)
    for &step,i in timeline {
        step=api_segment_read(call,&segments[i],items[i],fmt.tprintf("segments[%d].",i),tick_dt) or_return
    }
    timeline=api_timeline_presses(timeline,call.allocator)
    if total:=api_timeline_ticks(timeline);total>API_STEP_LIMIT {
        api.call_failf(call,api.INVALID_PARAMS,"segments run %d ticks and a step runs at most %d: split them into several calls",total,API_STEP_LIMIT)
        return
    }
    return timeline,true
}

// The whole ticks of a duration of the params, from least to limit: of seconds
// the nearest and at least 1. problem names the param by what.
api_duration_ticks :: proc(text,what:string,tick_dt:f32,least,limit:int) -> (ticks:int,problem:string) {
    d,valid:=api.duration_parse(text)
    if !valid {return 0,fmt.tprintf("%s takes %s, not %q",what,api.DURATION_FORM,text)}
    count:=d.in_seconds?d.seconds/f64(max(tick_dt,1e-6)):f64(d.ticks)
    if count>f64(limit) || count<f64(least) && !d.in_seconds || d.in_seconds && d.seconds==0 && least>0 {
        return 0,fmt.tprintf("%s: %s is outside %d to %d ticks of %g s",what,text,least,limit,tick_dt)
    }
    if !d.in_seconds {return int(d.ticks),""}
    return d.seconds>0?max(int(math.round(count)),1):0,""
}

// api_duration_ticks of a text of the params; false after failing the call.
api_call_duration :: proc(call:^api.Call,field:[]u8,what:string,tick_dt:f32,least,limit:int) -> (ticks:int,ok:bool) {
    problem:string
    if ticks,problem=api_duration_ticks(base.text_get(field),what,tick_dt,least,limit);problem!="" {
        api.call_fail(call,api.INVALID_PARAMS,problem)
        return
    }
    return ticks,true
}

// The input of play.step along its ticks: its segments, or the input fields as one segment of ticks.
@(private)
api_step_timeline :: proc(call:^api.Call,params:^Api_Play_Step_Params,tick_dt:f32) -> (timeline:[]Api_Step_Input,ok:bool) {
    keys:=[?]string{"segments","for","keys","mouse_buttons","tap_keys","tap_buttons","mouse_position","mouse_delta","wheel","text","gamepads","press"}
    values:[len(keys)]string
    api.object_values(call.allocator,call.raw,keys[:],values[:])
    if values[0]!="" {
        for value,i in values[1:] {
            if value!="" {api.call_failf(call,api.INVALID_PARAMS,"%s goes inside each of segments, which carry their own ticks and input: move it there or leave segments out",keys[i+1]);return}
        }
        return api_segments_read(call,params.segments[:],values[0],tick_dt)
    }
    timeline=make([]Api_Step_Input,1,call.allocator)
    timeline[0]=api_segment_read(call,&params.input,call.raw,"",tick_dt,1) or_return
    timeline=api_timeline_presses(timeline,call.allocator)
    if total:=api_timeline_ticks(timeline);total>API_STEP_LIMIT {
        api.call_failf(call,api.INVALID_PARAMS,"it runs %d ticks and a step runs at most %d: split it into several calls",total,API_STEP_LIMIT)
        return
    }
    return timeline,true
}

// A press as the ticks of a person, so that hover and taps see it: the pointer
// over the button, the button held, let go, and the ticks asked for after it.
@(private)
api_timeline_presses :: proc(timeline:[]Api_Step_Input,allocator:=context.allocator) -> []Api_Step_Input {
    count:=len(timeline)
    for step in timeline {if step.press!="" {count+=2}}
    if count==len(timeline) {return timeline}
    expanded:=make([]Api_Step_Input,count,allocator)
    at:=0
    for step in timeline {
        if step.press=="" {
            expanded[at]=step
            at+=1
            continue
        }
        expanded[at].ticks=1
        expanded[at].press=step.press
        expanded[at+1].ticks=API_PRESS_HELD
        expanded[at+1].buttons={.Left}
        expanded[at+2].ticks=1+step.ticks
        at+=3
    }
    return expanded
}

// The middle of the button of a screen by its name; problem names the ones it shows.
@(private)
api_press_center :: proc(top:^Play_Ui_Top,name:string) -> (center:[2]f32,problem:string) {
    names:=make([]string,len(top.buttons),context.temp_allocator)
    for &b,i in top.buttons {names[i]=b.name}
    index,_:=base.name_find(name,names)
    if index<0 {return {},fmt.tprintf("press: %q does not name one button of the screen on top: %s",name,strings.join(names,", ",context.temp_allocator))}
    b:=&top.buttons[index]
    if b.disabled {return {},fmt.tprintf("press: %q is disabled",b.name)}
    if !b.laid {return {},fmt.tprintf("press: %q has no place in the window: the last frame did not lay it out",b.name)}
    return {b.rect[0]+b.rect[2]*0.5,b.rect[1]+b.rect[3]*0.5},""
}

// Puts the pointer of the first tick of a press over its button; "" or why not.
@(private)
api_press_aim :: proc(s:^Session,r:^Run,step:^Api_Step_Input) -> string {
    arena:virtual.Arena
    if virtual.arena_init_growing(&arena)!=nil {return "press: no memory to read the screen"}
    defer virtual.arena_destroy(&arena)
    top,found:=play_ui_screen(s,r,false,virtual.arena_allocator(&arena))
    if !found {return "press: the game shows no screen with buttons now: play.ui says what it shows"}
    center,problem:=api_press_center(&top,step.press)
    if problem!="" {return problem}
    step.mouse_position,step.placed=center,true
    return ""
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
        if step.keys!={} || step.buttons!={} || step.tap_keys!={} || step.tap_buttons!={} || step.mouse_delta!={} || step.wheel!={} || step.placed || step.text!="" || step.gamepads!={} || step.press!="" {return true}
    }
    return false
}

// What a step samples along its ticks: a trace, or a filmstrip.
@(private)
Api_Step_Sampler :: union {^Api_Trace,^Api_Filmstrip}

// Takes a sample of the game w after ran ticks of the step; "" or why the step fails.
@(private)
api_step_sample :: proc(s:^Session,sampler:Api_Step_Sampler,w:core.World_Ref,ran:int) -> string {
    switch taken in sampler {
    case ^Api_Trace:     return api_trace_take(s,taken,w,ran)
    case ^Api_Filmstrip: return api_filmstrip_take(s,taken,ran)
    }
    return ""
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
    every:int,                  // ticks between two samples
    drive:^Api_Drive,           // nil: none; it steers before each tick
    look:^Api_Look,             // nil: none; it turns the view before each tick
}

// Runs the ticks of a timeline, its segments one after the other, until its
// conditions hold, sampling every some ticks and after the last one. The
// user's Play pauses first. problem: why it stopped failing.
@(private)
api_step_run :: proc(s:^Session,run:^Api_Step_Run,frame:Api_Step_Frame) -> (ran:int,met:bool,problem:string) {
    target:=run_player(s,run.owner,run.player)
    if target==nil {return 0,false,"That player has no run: play.start with online opens them"}
    if len(run.until)>0 {
        if met,problem=api_conditions_read(s,run_ref(s,target),run.until,nil,"until");problem!="" {return}
    }
    if run.owner==0 && !play_paused(s) {play_pause(s,true,stepped=true)}
    every:=max(run.every,1)
    total:=api_timeline_ticks(run.timeline)
    sampled:=0
    segment,at:=0,0
    for ran<total {
        if len(run.until)>0 && met {break}
        if api_stop_asked(s) {return}
        if st:=api_state(s);st!=nil && api.server_progress_due(&st.server) {api.server_progress(&st.server,fmt.tprintf("ran %d of %d ticks",ran,total),ran,total)}
        if run.look!=nil {
            if problem=api_look_steer(s,target,run.look);problem!="" {return}
        }
        if run.drive!=nil && !play_drive_steer(s,target,run.drive) {break}
        for at>=run.timeline[segment].ticks {segment+=1;at=0}
        if at==0 && run.timeline[segment].press!="" {
            if problem=api_press_aim(s,target,&run.timeline[segment]);problem!="" {return}
        }
        api_step_tick(s,run.owner,run.player,&run.timeline[segment],at)
        if !frame(s) {return}
        ran+=1;at+=1
        // The run ends with its turn or with the document.
        if run_find(s,run.owner)==nil {return}
        if target=run_player(s,run.owner,run.player);target==nil {return}
        run_tell_ticked(s,target)
        if len(run.until)>0 {
            if met,problem=api_conditions_read(s,run_ref(s,target),run.until,nil,"until");problem!="" {
                problem=fmt.tprintf("%s, after %d ticks",problem,ran)
                return
            }
        }
        if run.sampler!=nil && ran%every==0 {
            if problem=api_step_sample(s,run.sampler,run_ref(s,target),ran);problem!="" {return}
            sampled=ran
        }
    }
    if run.sampler!=nil && sampled!=ran {problem=api_step_sample(s,run.sampler,run_ref(s,target),ran)}
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
    rows:[dynamic]Api_Play_Trace_Row, // in the memory of the call
}

// Reads the trace of params (raw: its JSON) for a step of ticks at most and
// takes its first row from w; "" or what is wrong with it.
@(private)
api_trace_read :: proc(s:^Session,call:^api.Call,w:core.World_Ref,p:^Api_Play_Trace,raw:string,ticks:int,trace:^Api_Trace) -> (problem:string) {
    st:=api_state(s)
    trace^={storage=-1,view=p.view,include_runtime=p.include_runtime}
    values:[1]string
    api.object_values(call.allocator,raw,{"fields"},values[:])
    trace.field_count=api.json_count(values[0])
    if trace.field_count==0 {return `trace.fields is empty: give the paths to read, as ["world_position", "Motion.linear"]`}
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
    trace.rows=make([dynamic]Api_Play_Trace_Row,call.allocator)
    return api_trace_take(s,trace,w,0)
}

// A row of a trace: the tick and the value of each field of each document.
// In the first row a path that is not there fails, unless it names a
// component the entity does not have yet; later it is null.
@(private)
api_trace_take :: proc(s:^Session,trace:^Api_Trace,w:core.World_Ref,ran:int) -> string {
    st:=api_state(s)
    row:Api_Play_Trace_Row
    if t:=core.world_storage_of(w,core.Time);t!=nil {row.tick=t.tick}
    // The values are what the world names: one per column, as play.inspect writes it.
    values:serial.Writer
    serial.writer_init(&values,0,trace.rows.allocator)
    out:=&values
    serial.write_u8(out,'[')
    doc:serial.Writer
    serial.writer_init(&doc,0,context.temp_allocator)
    omitted:=serial.Field_Flags{.Transient,.Hidden} if !trace.include_runtime else serial.Field_Flags{}
    for d in 0..<(trace.storage>=0 || trace.view?1:trace.count) {
        serial.writer_reset(&doc)
        there:=true
        is_entity:=!trace.view && trace.storage<0
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
        } else {there=core.alive(core.world_entities(w),trace.entities[d])}
        whole:json.Value
        if there && !is_entity {
            parse_error:json.Error
            if whole,parse_error=json.parse(serial.writer_bytes(&doc),allocator=context.temp_allocator);parse_error!=nil {return "trace: a value could not be read back as JSON"}
        }
        for field,i in trace.fields[:trace.field_count] {
            if d>0 || i>0 {serial.write_u8(out,',')}
            if !there {serial.text_write_raw(out,"null");continue}
            leaf:json.Value
            there_value:=true
            missing:string
            if is_entity {leaf,there_value,missing=api_entity_value(s,w,trace.entities[d],field,trace.include_runtime,context.temp_allocator,trace.scratch)}
            else {leaf,missing=api_json_select(whole,field)}
            switch {
            case missing=="" && there_value:
                serial.text_write_raw(out,api_json_text(leaf))
            case missing!="" && len(trace.rows)==0:
                return fmt.tprintf("trace.fields[%d] %q: %s",i,field,missing)
            case:
                serial.text_write_raw(out,"null")
            }
        }
    }
    serial.write_u8(out,']')
    row.values=serial.Json(string(serial.writer_bytes(&values)))
    append(&trace.rows,row)
    return ""
}

// The result of play.step: that of the other play methods, and its trace.
@(private)
api_play_step_write :: proc(s:^Session,call:^api.Call,r:^Run,ran:int,met:bool,trace:^Api_Trace,drive:^Api_Drive=nil) {
    result:=api.call_result(call,Api_Play_Step_Result)
    api_play_result_fill(s,&result.play,r)
    result.ran,result.met=ran,met
    if drive!=nil {result.drive=api_drive_result(drive)}
    if trace!=nil {result.trace=api_trace_table(s,trace,call.allocator)}
}

// The columns and the rows of a trace.
@(private)
api_trace_table :: proc(s:^Session,trace:^Api_Trace,allocator:=context.temp_allocator) -> Api_Play_Trace_Table {
    columns:=make([dynamic]Api_Play_Trace_Column,allocator)
    for d in 0..<(trace.storage>=0 || trace.view?1:trace.count) {
        for field in trace.fields[:trace.field_count] {
            column:=Api_Play_Trace_Column{view=trace.view,field=field}
            switch {
            case trace.view:
            case trace.storage>=0: column.storage=s.info.storages[trace.storage].name
            case: column.entity,column.name=trace.entities[d],trace.names[d]
            }
            append(&columns,column)
        }
    }
    return {columns[:],trace.rows[:]}
}


