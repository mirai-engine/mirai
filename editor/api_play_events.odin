package editor

import "base:runtime"
import "core:slice"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"

// What a library reported in the game of the caller: the items of the core.Events fields of one
// storage (Physics_Events, Ability_Events, Nav_Events, Perception_Events, Animation_Events, or
// one of the game), read by reflection as any storage is. Without from and to, those of the last
// frame; with them, those each frame the history keeps reported, read by playing it again.

Api_Play_Events_Params :: struct {
    storage:[64]u8 `mirai:"text,label=A storage of the game with core.Events fields, as Physics_Events or Ability_Events"`,
    entity:Api_Entity_Text `mirai:"optional,text,entity,label=Only the events with a field that holds this entity, by its name, a path Parent/Child, its id or its handle"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
    from:[api.DURATION_TEXT]u8 `mirai:"optional,text,label=The first tick of the history to read: a number is a tick and a text ending in s a game time as 240 or 3.2s; without from and to the last frame"`,
    to:[api.DURATION_TEXT]u8 `mirai:"optional,text,label=The last tick of the history to read in the form of from; the newest kept when omitted or past it"`,
    limit:int `mirai:"optional,min=1,max=1024,clamp,label=Events to give at most; those past it are counted in dropped"`,
}

Api_Play_Events :: struct {
    storage:string,
    logs:[]string `mirai:"label=Its fields that are core.Events, in their order"`,
    events:[]Api_Play_Event `mirai:"label=By frame, then by log in the order of logs, then in the order they were pushed"`,
    dropped:int `mirai:"optional,label=Events past limit that were not given"`,
    next:u64 `mirai:"optional,label=With from or to: the from that goes on when the frames read stopped before to"`,
}
Api_Play_Event :: struct {
    tick:u64 `mirai:"label=Of the game after the frame that reported it"`,
    log:string `mirai:"label=The field of the storage it was pushed to"`,
    event:serial.Json `mirai:"label=The item as the schema of its type, with Entity fields holding handles"`,
}

// A core.Events field of a storage, found by reflection.
@(private)
Play_Events_Log :: struct {
    name:string,
    items:uintptr, // offset of its [dynamic]T in the storage
    first:uintptr, // offset of how many came before items[0]
    item:^runtime.Type_Info,
    type:serial.Type_Index,
}

// What reading the events of a storage keeps from one frame to the next.
@(private)
Play_Events_Read :: struct {
    call:^api.Call,
    storage:^core.Storage_Info,
    logs:[]Play_Events_Log,
    schema:serial.Schema,
    entity:string,    // the text that names the entity of the filter; "" for none
    filter:core.Entity, // the entity last found by entity
    found:bool,       // entity named one at some frame
    cursors:[]u64,    // of each log: the end of what was read
    looked:bool,
    limit:int,
    events:[dynamic]Api_Play_Event,
    dropped:int,
}

@(private)
play_events_api_register :: proc(s:^Session,st:^Api_State) {
    defaults:=Api_Play_Events_Params{limit=256}
    api_register(s,st,{name="play.events",summary="What a library reported in the game of the caller: the items of the core.Events fields of one storage (Physics_Events, Ability_Events, Nav_Events, Perception_Events, Animation_Events or one of the game), those that hold an entity when one is given. Without from and to those of the last frame; with them those of each frame the history keeps, read by playing it again; the game stays as it is.",params=type_info_of(Api_Play_Events_Params),result=type_info_of(Api_Play_Events),defaults=&defaults,flags={.Read_Only},run=api_play_events})
}

// The core.Events fields of a storage; none for a storage that reports nothing.
@(private)
play_events_logs :: proc(info:^runtime.Type_Info,allocator:=context.temp_allocator) -> []Play_Events_Log {
    logs:=make([dynamic]Play_Events_Log,allocator)
    s,is_struct:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
    if !is_struct {return nil}
    for i in 0..<int(s.field_count) {
        named,is_named:=s.types[i].variant.(runtime.Type_Info_Named)
        if !is_named || !strings.has_prefix(named.name,"Events(") {continue}
        // Events(T) holds a Log(T) of items and first.
        events,_:=runtime.type_info_base(s.types[i]).variant.(runtime.Type_Info_Struct)
        if events.field_count==0 || events.names[0]!="log" {continue}
        log,_:=runtime.type_info_base(events.types[0]).variant.(runtime.Type_Info_Struct)
        if log.field_count<2 || log.names[0]!="items" || log.names[1]!="first" || log.types[1].id!=u64 {continue}
        items,dynamic_array:=runtime.type_info_base(log.types[0]).variant.(runtime.Type_Info_Dynamic_Array)
        if !dynamic_array {continue}
        at:=s.offsets[i]+events.offsets[0]
        append(&logs,Play_Events_Log{name=s.names[i],items=at+log.offsets[0],first=at+log.offsets[1],item=items.elem})
    }
    return logs[:]
}

// The storages of the game that report events, by name.
@(private)
play_events_storages :: proc(w:core.World_Ref,allocator:=context.temp_allocator) -> []string {
    names:=make([dynamic]string,allocator)
    for &info in w.info.storages {
        if info.place==.World && !info.by_world && info.info!=nil && len(play_events_logs(info.info))>0 {append(&names,info.name)}
    }
    slice.sort(names[:])
    return names[:]
}

@(private)
api_play_events :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Events_Params)
    r,_:=api_play_run(s,call,p.player)
    if r==nil {api_no_game(call);return}
    w:=run_ref(s,r)
    name:=base.text_get(p.storage[:])
    read:=Play_Events_Read{call=call,entity=base.text_get(p.entity[:]),limit=p.limit,events=make([dynamic]Api_Play_Event,call.allocator)}
    for &info in w.info.storages {
        if info.name==name && info.place==.World && !info.by_world {read.storage=&info;break}
    }
    if read.storage!=nil {read.logs=play_events_logs(read.storage.info,call.allocator)}
    if len(read.logs)==0 {
        what:="is not a storage of the game" if read.storage==nil else "reports no events: it has no core.Events field"
        api.call_failf(call,api.INVALID_PARAMS,"storage %q %s; the storages that report events are %s",name,what,strings.join(play_events_storages(w),", ",call.allocator))
        return
    }
    serial.schema_init(&read.schema,call.allocator)
    read.schema.unsized,read.schema.named=true,api_state(s).schema.named
    for &log in read.logs {
        ok:bool
        if log.type,ok=serial.schema_add_type_info(&read.schema,log.item);!ok {
            api.call_failf(call,api.SERVER_ERROR,"the events of %s.%s could not be reflected: %s",name,log.name,read.schema.error)
            return
        }
    }
    read.cursors=make([]u64,len(read.logs),call.allocator)
    result:=api.call_result(call,Api_Play_Events)
    if base.text_get(p.from[:])=="" && base.text_get(p.to[:])=="" {
        if read.entity!="" {
            e,named:=api_call_entity(call,w,p.entity[:],game=true)
            if !named {return}
            read.filter,read.found=e,true
        }
        play_events_take(&read,w,true)
    } else {
        next,ok:=history_look(s,call,p.player,p.from[:],p.to[:],1,API_TRACE_ROWS,play_events_look,&read)
        if !ok {return}
        if read.entity!="" && !read.found {
            api.call_failf(call,api.INVALID_PARAMS,"entity %q names no entity of the game at those ticks; scene.inspect with world Game lists them and play.history the ticks it keeps",read.entity)
            return
        }
        result.next=next
    }
    result.storage,result.events,result.dropped=read.storage.name,read.events[:],read.dropped
    result.logs=make([]string,len(read.logs),call.allocator)
    for log,i in read.logs {result.logs[i]=log.name}
}

@(private)
play_events_look :: proc(s:^Session,w:core.World_Ref,row:bool,data:rawptr) -> string {
    read:=(^Play_Events_Read)(data)
    if read.entity!="" {
        // An entity found again at each frame; one gone keeps the handle it had.
        if e,problem:=api_entity_select(w,read.entity,"entity",true,read.call.allocator);problem=="" {read.filter,read.found=e,true}
    }
    play_events_take(read,w,row)
    return ""
}

// The events of the storage since the cursors, which move to their ends: kept when take.
@(private)
play_events_take :: proc(read:^Play_Events_Read,w:core.World_Ref,take:bool) {
    storage:=uintptr(w.data)+read.storage.offset
    tick:u64
    if t:=core.world_storage_of(w,core.Time);t!=nil {tick=t.tick}
    looked:=read.looked
    read.looked=true
    for &log,i in read.logs {
        items:=(^runtime.Raw_Dynamic_Array)(storage+log.items)
        first:=(^u64)(storage+log.first)^
        end:=first+u64(items.len)
        // What came before the cursor was read; what the log dropped before it was read was not.
        from:=0
        if looked && read.cursors[i]>first {from=int(min(read.cursors[i]-first,u64(items.len)))}
        read.cursors[i]=end
        if !take {continue}
        size:=log.item.size
        offsets:=entity_offsets(log.item) if read.entity!="" else nil
        for at in from..<items.len {
            item:=([^]u8)(items.data)[at*size:][:size]
            if read.entity!="" && (!read.found || !play_events_holds(item,offsets,read.filter)) {continue}
            if len(read.events)>=read.limit {read.dropped+=1;continue}
            out:serial.Writer
            serial.writer_init(&out,0,read.call.allocator)
            serial.text_write(&out,&read.schema,log.type,item,.Line,omit_fields={})
            append(&read.events,Api_Play_Event{tick=tick,log=log.name,event=serial.Json(string(serial.writer_bytes(&out)))})
        }
    }
}

// Whether an item holds e in one of its Entity fields.
@(private)
play_events_holds :: proc(item:[]u8,offsets:[]uintptr,e:core.Entity) -> bool {
    for offset in offsets {
        if (^core.Entity)(&item[offset])^==e {return true}
    }
    return false
}
