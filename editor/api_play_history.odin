package editor

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import "mirai:std/serial"

// The past a run keeps (play_history.odin), to the API: going back to a tick
// with play.seek, and with play.history reading values at the ticks it played
// or checking that playing its frames again leaves what they left. Reading
// and checking play the frames again on the World of the run and put it back
// after, as it was: the game does not change. The last Play of the user
// stays after Stop (Session.replay): both read it, and play.seek opens it
// again, paused.

Api_Play_Seek_Params :: struct {
    tick:u64 `mirai:"optional,label=The tick to go to; when no frame ended on it the newest before it"`,
    seconds:f64 `mirai:"optional,min=0,unit=s,label=In place of tick: the game time to go to; the newest tick at or before it"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Seek_Result :: struct {
    tick:u64 `mirai:"label=The tick reached"`,
    seconds:f64,
    paused:bool,
    replayed:int `mirai:"label=Frames played again to get there from a keyframe or from where the game was"`,
    matches:bool `mirai:"label=The frames played again left the World as when they played; false: the game does not repeat itself or something outside its frames changed it (an edit or a move of the simulation)"`,
}

Api_Play_History_Params :: struct {
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
    from:u64 `mirai:"optional,label=The first tick read or checked; the oldest kept when 0"`,
    to:u64 `mirai:"optional,label=The last tick read or checked; the newest kept when 0 or past it"`,
    from_seconds:f64 `mirai:"optional,min=0,unit=s,label=In place of from: the game time of the first tick read or checked"`,
    to_seconds:f64 `mirai:"optional,min=0,unit=s,label=In place of to: the game time of the last tick read or checked"`,
    trace:Api_Play_Trace `mirai:"optional,label=Values of a few entities or of a storage as play.step traces them, at the ticks the run played from from to to every every ticks: the trace of the result"`,
    verify:bool `mirai:"optional,label=Plays the kept frames from from to to again and compares what they leave with what they left when they played: verify says where they first differ"`,
}

// Where playing the past again first differs from what played.
Api_Play_Verify :: struct {
    frames:int `mirai:"label=Frames played again and compared; 0 without verify"`,
    diverged:bool `mirai:"label=A frame played again left the World otherwise than when it played: the game does not repeat itself (it reads something outside its World, the clock, an order of a map) or something outside its frames changed it (an edit while it played)"`,
    tick:u64 `mirai:"label=The first tick whose transforms differ, or else the tick of the copy of the World that differs"`,
    since:u64 `mirai:"label=The tick of the copy of the World the frames were played from: the cause is in the ticks after it"`,
    compared:u64 `mirai:"label=The tick of the copy of the World the field was compared at; 0 when only the transforms of a tick say it"`,
    entity:core.Entity `mirai:"optional,label=The entity whose field differs"`,
    name:[64]u8 `mirai:"text,label=Its name"`,
    storage:[64]u8 `mirai:"text,label=The storage whose field differs, in place of an entity"`,
    field:[128]u8 `mirai:"text,label=The first path that differs, as trace.fields takes it; empty for an entity alive in one and not in the other"`,
    recorded:[256]u8 `mirai:"text,label=Its value when it played, as JSON"`,
    replayed:[256]u8 `mirai:"text,label=Its value played again, as JSON"`,
}

// What play.history writes: Api_Play_History_Info and its trace.
Api_Play_History_Result :: struct {
    playing:bool `mirai:"label=A game of the caller plays; false with stopped its last Play, and without both the rest is empty"`,
    on:bool `mirai:"label=The run keeps its past"`,
    stopped:bool `mirai:"label=It is the last Play of the user, kept after it stopped until the next Play: play.seek opens it again, paused"`,
    tick:u64 `mirai:"label=Where the run is"`,
    oldest,newest:u64 `mirai:"label=The ticks play.seek goes to"`,
    oldest_seconds,newest_seconds:f64,
    frames:int `mirai:"label=Frames kept with what they gave the World"`,
    keyframes:int `mirai:"label=Copies of the World kept"`,
    capacity:int `mirai:"label=The copies that fit in the time and the memory of the history"`,
    interval:u64 `mirai:"label=Ticks between two copies: going to a tick plays again at most these"`,
    megabytes:f32 `mirai:"label=What the copies and the frames take"`,
    reason:[160]u8 `mirai:"text,label=Why it keeps none, when it does not"`,
    next:u64 `mirai:"label=With a trace that filled its rows before to: the from that goes on; 0 when it reached to"`,
    verify:Api_Play_Verify `mirai:"label=With verify: where playing the past again first differs"`,
    trace:Api_Play_Trace_Table `mirai:"optional,label=With trace: the values it read"`,
}
@(private)
Api_Play_History_Info :: struct {
    playing:bool,
    on:bool,
    stopped:bool,
    tick:u64,
    oldest,newest:u64,
    oldest_seconds,newest_seconds:f64,
    frames,keyframes,capacity:int,
    interval:u64,
    megabytes:f32,
    reason:[160]u8 `mirai:"text"`,
    next:u64,
    verify:Api_Play_Verify,
}

@(private)
api_play_history_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="play.seek",summary="Takes the game of the caller, or the last Play of the user after it stopped, to a tick it played, paused, to look at it and play on from there: the copy of the World before it and the frames between played again.",params=Api_Play_Seek_Params,result=Api_Play_Seek_Result,run=api_play_seek})
    history_default:=Api_Play_History_Params{trace={every=1}}
    api_register(s,st,{name="play.history",summary="The ticks the game of the caller, or the last Play of the user after it stopped, keeps to go back to and what they take; with trace, values of entities at those ticks, and with verify, whether playing them again repeats them: the game stays as it is.",params=Api_Play_History_Params,result=Api_Play_History_Result,writes_result=true,defaults=&history_default,flags={.Read_Only},run=api_play_history})
    if _,ok:=api.schema_register(&st.server,Api_Play_History_Info);!ok {
        st.refused+=1
        if st.refused==1 {st.refusal=fmt.bprintf(st.refusal_buffer[:],"play.history: its result has no schema: %s",st.server.schema.error)}
    }
}

@(private)
api_play_seek :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Seek_Params)
    r,own,stopped:=api_history_run(s,call,p.player)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,API_NO_GAME);return}
    if !own && stopped {api.call_fail(call,api.SERVER_ERROR,"A turn reads the last Play of the user with play.history; it opens again only from outside a turn");return}
    if !own {api_play_refused(call);return}
    if reason:=history_reason(s,r);reason!="" {api.call_fail(call,api.SERVER_ERROR,reason);return}
    tick,given:=api_history_tick(call,r.history,p.tick,p.seconds,"tick","seconds")
    if !given {
        if !call.failed {api.call_fail(call,api.INVALID_PARAMS,"give tick, or seconds (a game time the history keeps): play.history says which")}
        return
    }
    serial:=history_frame_for(r.history,tick)
    if serial==0 {api_history_older(call,r.history,tick);return}
    if stopped {
        if !play_review(s) {api.call_fail(call,api.SERVER_ERROR,"The editor shows another game: stop it to open the last Play again");return}
        r=run_find(s,0)
    }
    if r.owner==0 && !play_paused(s) {play_pause(s,true)}
    seek:=history_seek(s,r,serial)
    if !seek.ok {api.call_fail(call,api.SERVER_ERROR,"No memory to go back: the game stays where it was");return}
    result:=api.call_result(call,Api_Play_Seek_Result)
    if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {result.tick,result.seconds=t.tick,t.seconds}
    result.paused=r.owner!=0 || play_paused(s)
    result.replayed,result.matches=seek.replayed,seek.matches
}

// The run a call on the past acts on: that of the caller, or else the last
// Play of the user after it stopped. own: the call may move it; stopped: it is
// that last Play.
@(private)
api_history_run :: proc(s:^Session,call:^api.Call,player:int) -> (r:^Run,own,stopped:bool) {
    owner:=ai_task_of_call(s,call)
    r,own=api_play_run(s,call,player)
    if r==nil && player==0 && s.replay.world!=nil {return &s.replay,owner==0,true}
    return
}

// The tick a call on the past names, by its tick or by a game time: the
// newest tick the history keeps at or before it. given is false when it named
// neither, and after failing the call when it gave both.
@(private)
api_history_tick :: proc(call:^api.Call,h:^Run_History,tick:u64,seconds:f64,tick_name,seconds_name:string) -> (found:u64,given:bool) {
    if !tool_call_given(call,seconds_name) {return tick,tool_call_given(call,tick_name)}
    if tool_call_given(call,tick_name) {
        api.call_failf(call,api.INVALID_PARAMS,"%s and %s name the same tick: give one",tick_name,seconds_name)
        return
    }
    if h!=nil {
        for at in 0..<h.frame_count {
            f:=history_frame_at(h,at)
            if f==nil || f.seconds>seconds {break}
            found=f.tick
        }
    }
    return found,true
}

@(private)
api_history_older :: proc(call:^api.Call,h:^Run_History,tick:u64) {
    oldest,newest,_,_,_:=history_span(h)
    api.call_failf(call,api.INVALID_PARAMS,"tick %d is older than the history keeps: it goes to ticks %d to %d (play.history); Play_History.seconds and megabytes of the preferences keep more",tick,oldest,newest)
}

@(private)
api_play_history :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_History_Params)
    r,_,stopped:=api_history_run(s,call,p.player)
    raw:[1]string
    api.object_values(call.allocator,call.raw,{"trace"},raw[:])
    traced:=raw[0]!=""
    looks:=traced || p.verify
    info:Api_Play_History_Info
    if r==nil {
        api_text_put(info.reason[:],"No game is playing")
        api_play_history_write(s,call,&info,nil)
        return
    }
    info.playing,info.stopped=!stopped,stopped
    if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {info.tick=t.tick}
    if reason:=history_reason(s,r);reason!="" {
        if looks {api.call_fail(call,api.SERVER_ERROR,reason);return}
        api_text_put(info.reason[:],reason)
        api_play_history_write(s,call,&info,nil)
        return
    }
    h:=r.history
    info.on=true
    info.oldest,info.newest,info.oldest_seconds,info.newest_seconds,_=history_span(h)
    info.frames,info.keyframes,info.capacity,info.interval=h.frame_count,h.count,h.limit,h.interval
    info.megabytes=f32(f64(history_bytes(h)+i64(len(h.frames)*size_of(History_Frame)))/(1024*1024))
    if !looks {api_play_history_write(s,call,&info,nil);return}
    from_tick,_:=api_history_tick(call,h,p.from,p.from_seconds,"from","from_seconds")
    to_tick,_:=api_history_tick(call,h,p.to,p.to_seconds,"to","to_seconds")
    if call.failed {return}
    from:=from_tick!=0?from_tick:info.oldest
    to:=to_tick!=0?min(to_tick,info.newest):info.newest
    if from>to {api.call_failf(call,api.INVALID_PARAMS,"from %d is after to %d: give from at or before to; the history keeps ticks %d to %d",from,to,info.oldest,info.newest);return}
    if history_frame_for(h,from)==0 {api_history_older(call,h,from);return}
    saved,copied:=history_save(s,r)
    if !copied {api.call_fail(call,api.SERVER_ERROR,"No memory for a copy of the World to play its past on; the game stays as it is");return}
    problem:string
    trace:Api_Trace
    {
        kept:=extras_mark(s.app)
        defer extras_drop(s.app,kept)
        if traced {problem=api_history_trace(s,call,r,&p.trace,raw[0],from,to,&trace,&info.next)}
        if problem=="" && p.verify {problem=api_history_verify(s,r,from,to,&info.verify)}
    }
    history_restore(s,r,&saved)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    api_play_history_write(s,call,&info,traced?&trace:nil)
}

@(private)
api_play_history_write :: proc(s:^Session,call:^api.Call,info:^Api_Play_History_Info,trace:^Api_Trace) {
    sc:=&api_state(s).server.schema
    index,found:=sc.lookup[Api_Play_History_Info]
    if !found {api.call_fail(call,api.INTERNAL_ERROR,"the result of play.history has no schema");return}
    out:=call.out
    serial.text_write(out,sc,index,mem.ptr_to_bytes(info),.Line)
    if trace==nil {return}
    out.count-=1 // the brace that closes it
    api_trace_write(s,out,trace)
    serial.write_u8(out,'}')
}

// The rows of a trace at the frames kept from the one at or before from to
// the last at or before to: the first, then one a frame that reached every
// ticks past the row before, and the last. A frame that ran several ticks
// shows the last. Rows beyond API_TRACE_ROWS are left for next.
@(private)
api_history_trace :: proc(s:^Session,call:^api.Call,r:^Run,p:^Api_Play_Trace,raw:string,from,to:u64,trace:^Api_Trace,next:^u64) -> string {
    h:=r.history
    first:=history_frame_for(h,from)
    if !history_seek(s,r,first).ok {return "No memory to go back to the first tick of the trace"}
    every:=u64(max(p.every,1))
    span:=int(min(to-from,u64(API_TRACE_ROWS-1)*every))
    if problem:=api_trace_read(s,call,run_ref(s,r),p,raw,span,trace);problem!="" {return problem}
    last:=history_frame_of(h,first).tick
    pending:=u64(0) // a frame played after the last row, whose tick is the last of the trace
    for serial:=first+1;serial<=h.serial;serial+=1 {
        f:=history_frame_of(h,serial)
        if f==nil || f.tick>to {break}
        due:=f.tick>=last+every
        if due && trace.row_count==API_TRACE_ROWS {next^,pending=f.tick,0;break}
        if !history_seek(s,r,serial).ok {return "No memory to play the past again"}
        if !due {pending=serial;continue}
        if problem:=api_trace_take(s,trace,run_ref(s,r),0);problem!="" {return problem}
        last,pending=f.tick,0
    }
    if pending==0 {return ""}
    if trace.row_count==API_TRACE_ROWS {
        next^=history_frame_of(h,pending).tick
        return ""
    }
    return api_trace_take(s,trace,run_ref(s,r),0)
}

// Plays again the frames from each keyframe to the next that reach from to
// to, as Jolt's state recorder validates a replay: after each frame the hash
// of the transforms against the one it kept, and at the next keyframe every
// entity and storage, as play.inspect writes them, against that copy. The
// copy of the World the frames leave is made as keyframes are, so that what
// a copy leaves out does not differ. Stops at the first span that differs.
@(private)
api_history_verify :: proc(s:^Session,r:^Run,from,to:u64,out:^Api_Play_Verify) -> string {
    h:=r.history
    allocator:=s.app.allocator
    context.allocator=allocator
    copied,error:=mem.alloc(max(s.info.sizes[.World],1),max(s.info.aligns[.World],1),allocator)
    if error!=nil || copied==nil {return "No memory for a copy of the World to compare"}
    defer mem.free(copied,allocator)
    if !s.info.init[.World](copied,allocator) {s.info.destroy[.World](copied);return "No memory for a copy of the World to compare"}
    defer s.info.destroy[.World](copied)
    marks,marks_error:=make([]core.Copy_Mark,len(s.info.tables),context.temp_allocator)
    if marks_error!=nil {return "No memory for a copy of the World to compare"}
    w:=run_ref(s,r)
    for n in 0..<h.count {
        key:=history_at(h,n)
        if key.tick>to {break}
        next:^History_Slot
        end:=h.serial
        if n+1<h.count {next=history_at(h,n+1);end=next.frame}
        if f:=history_frame_of(h,end);f==nil || f.tick<from {continue}
        if !history_load(s,r,key) {return "No memory to go back to a copy of the World"}
        for h.at<end {
            f:=history_frame_of(h,h.at+1)
            if f==nil || f.tick>to || !history_replay(s,r,f) {break}
            out.frames+=1
            // A keyframe of an edit is not where the frames before it lead.
            if next!=nil && next.edited && h.at==end {break}
            if !out.diverged && f.hash!=history_hash(w) {out.diverged,out.tick,out.since=true,f.tick,key.tick}
        }
        if next!=nil && !next.edited && h.at==end {
            for &mark in marks {mark={}}
            same:=s.info.copy_changed!=nil?s.info.copy_changed(copied,r.world,marks):s.info.copy(copied,r.world)
            if !same {return "No memory for a copy of the World to compare"}
            if api_history_differs(s,core.world_ref(next.world,s.info),core.world_ref(copied,s.info),out) {
                if !out.diverged {out.diverged,out.tick,out.since=true,next.tick,key.tick}
                out.compared=next.tick
                return ""
            }
        }
        if out.diverged {return ""}
    }
    return ""
}

// The first entity or storage whose document differs between what played
// and what played again, into out; false when none does.
@(private)
api_history_differs :: proc(s:^Session,recorded,replayed:core.World_Ref,out:^Api_Play_Verify) -> bool {
    st:=api_state(s)
    scratch:=make([]u8,max(st.largest,1),context.temp_allocator)
    a,b:serial.Writer
    serial.writer_init(&a,0,context.temp_allocator)
    serial.writer_init(&b,0,context.temp_allocator)
    for &info in s.info.tables {
        if info.place!=.World {continue}
        x,y:=core.world_table_at(recorded,&info),core.world_table_at(replayed,&info)
        if api_history_table_same(x,y,&info) {continue}
        for side in ([2]^core.Raw_Table{x,y}) {
            for e in side.entities[:core.raw_count(side)] {
                serial.writer_reset(&a);serial.writer_reset(&b)
                there_a:=core.alive(core.world_entities(recorded),e)
                there_b:=core.alive(core.world_entities(replayed),e)
                if there_a {api_entity_write(s,recorded,&a,e,true,scratch,true)}
                if there_b {api_entity_write(s,replayed,&b,e,true,scratch,true)}
                if slice.equal(serial.writer_bytes(&a),serial.writer_bytes(&b)) {continue}
                if !api_history_documents_differ(&a,&b,there_a,there_b,out) {continue}
                out.entity=e
                api_text_put(out.name[:],entity_name(there_a?recorded:replayed,e))
                return true
            }
        }
    }
    omitted:=serial.Field_Flags{.Transient,.Hidden}
    value:=make([]u8,max(st.largest,1),context.temp_allocator)
    for &info,i in s.info.storages {
        if info.place!=.World || st.storage_types[i]==serial.TYPE_NONE {continue}
        serial.writer_reset(&a);serial.writer_reset(&b)
        for side in ([2]struct{w:core.World_Ref,doc:^serial.Writer}{{recorded,&a},{replayed,&b}}) {
            at:=rawptr(uintptr(side.w.data)+info.offset)
            if info.info.size<=len(value) {mem.copy(raw_data(value),at,info.info.size);api_history_cursors_clear(info.info,raw_data(value));at=raw_data(value)}
            api_value_out(side.w,info.info,at,scratch,handles=true)
            serial.text_write(side.doc,&st.schema,st.storage_types[i],scratch[:info.info.size],.Line,omit_fields=omitted)
        }
        if slice.equal(serial.writer_bytes(&a),serial.writer_bytes(&b)) {continue}
        if !api_history_documents_differ(&a,&b,true,true,out) {continue}
        api_text_put(out.storage[:],info.name)
        return true
    }
    return false
}

// Zeroes the change cursors (core.Seen) inside a value: where a reader was in a table depends on
// the versions of the copy of the World it was restored from, not on what the game did.
@(private)
api_history_cursors_clear :: proc(info:^runtime.Type_Info,data:rawptr) {
    if info==nil {return}
    if info.id==core.Seen {mem.zero(data,size_of(core.Seen));return}
    #partial switch v in runtime.type_info_base(info).variant {
    case runtime.Type_Info_Struct:
        for k in 0..<int(v.field_count) {api_history_cursors_clear(v.types[k],rawptr(uintptr(data)+v.offsets[k]))}
    case runtime.Type_Info_Array:
        for k in 0..<v.count {api_history_cursors_clear(v.elem,rawptr(uintptr(data)+uintptr(k*v.elem_size)))}
    }
}

// Whether two tables hold the same rows with the same bytes, for a type
// without references: then none of their entities differs in it.
@(private)
api_history_table_same :: proc(x,y:^core.Raw_Table,info:^core.Table_Info) -> bool {
    count:=core.raw_count(x)
    if count!=core.raw_count(y) || !slice.equal(x.entities[:count],y.entities[:count]) || !slice.equal(x.off[:],y.off[:]) {return false}
    if !core.value_flat(info.info) {return false}
    size:=count*info.info.size
    return size==0 || mem.compare_byte_ptrs((^u8)(x.values.data),(^u8)(y.values.data),size)==0
}

// The first path where two JSON documents differ, and its two values, into
// out; false when they read the same. One that is not there is null.
@(private)
api_history_documents_differ :: proc(a,b:^serial.Writer,there_a,there_b:bool,out:^Api_Play_Verify) -> bool {
    if there_a!=there_b {
        api_text_put(out.recorded[:],there_a?"\"alive\"":"null")
        api_text_put(out.replayed[:],there_b?"\"alive\"":"null")
        return true
    }
    x,x_error:=json.parse(serial.writer_bytes(a),allocator=context.temp_allocator)
    y,y_error:=json.parse(serial.writer_bytes(b),allocator=context.temp_allocator)
    if x_error!=nil || y_error!=nil {return false}
    path:=strings.builder_make(context.temp_allocator)
    if !api_json_differs(x,y,&path) {return false}
    at:=strings.to_string(path)
    api_text_put(out.field[:],at)
    for side in ([2]struct{value:json.Value,text:[]u8}{{x,out.recorded[:]},{y,out.replayed[:]}}) {
        leaf,missing:=api_json_select(side.value,at)
        api_text_put(side.text,missing==""?api_json_text(leaf):"null")
    }
    return true
}

// Whether two JSON values differ, with the path to the first place they do:
// names joined by dots and [i] for element i, keys in alphabetical order.
@(private)
api_json_differs :: proc(a,b:json.Value,path:^strings.Builder) -> bool {
    mark:=len(path.buf)
    #partial switch x in a {
    case json.Object:
        y,same:=b.(json.Object)
        if !same {return true}
        keys:=make([dynamic]string,context.temp_allocator)
        for key in x {append(&keys,key)}
        for key in y {if key not_in x {append(&keys,key)}}
        slice.sort(keys[:])
        for key in keys {
            u,has_u:=x[key]
            v,has_v:=y[key]
            if mark>0 {strings.write_byte(path,'.')}
            strings.write_string(path,key)
            if has_u!=has_v || api_json_differs(u,v,path) {return true}
            resize(&path.buf,mark)
        }
        return false
    case json.Array:
        y,same:=b.(json.Array)
        if !same || len(x)!=len(y) {return true}
        for i in 0..<len(x) {
            fmt.sbprintf(path,"[%d]",i)
            if api_json_differs(x[i],y[i],path) {return true}
            resize(&path.buf,mark)
        }
        return false
    }
    return api_json_text(a)!=api_json_text(b)
}

// Why a run has no past to go back to; empty when it has one.
@(private)
history_reason :: proc(s:^Session,r:^Run) -> string {
    if r.history!=nil && r.history.count>0 {return ""}
    if s.play_history==nil || !s.play_history.on {return "The history of Play is off: Play_History.on in the preferences of the editor turns it on"}
    if network:=core.world_storage_of(run_ref(s,r),core.Network);network!=nil && network.role!=.Standalone {return "A game on the network keeps no history: its past belongs to its server"}
    if r.history_off {return "This run keeps no history: there was no memory for it"}
    return "The game has not run a tick yet: play.step first"
}
