package editor

import "base:runtime"
import "core:fmt"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import "mirai:std/serial"

// Requests pushed to the queues of the game that plays, as its functions
// push them: they go to the run of the caller (that of its turn, or the Play
// of the user outside a turn). Its entities are written by scene.write with
// world Game (api_scene_write.odin).

API_PLAY_PUSH_LIMIT :: 64

Api_Play_Push_Result :: struct {
    pushed:int `mirai:"label=Items pushed; the functions that take the queue read them in the next tick"`,
}

Api_Play_Push_Params :: struct {
    storage:string `mirai:"label=the name of a queue storage of the game: Seat_Requests, Spawns or one of the project"`,
    items:[]serial.Json `mirai:"label=At most 64. its requests as the schema of the type of its items, with Entity fields holding handles; scene.inspect with world Game and storages names them"`,
    player:int `mirai:"optional,min=0,max=3,label=the run of that player of a game a turn plays on the network"`,
}

@(private)
api_play_edit_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="play.push",params=type_info_of(Api_Play_Push_Params),summary="Pushes requests to a queue storage of the game of the caller, as its functions push them (Seat_Requests, Spawns or one of the game); the functions that take it read them in the next tick.",result=type_info_of(Api_Play_Push_Result),run=api_play_push})
    api_play_input_register(s,st)
}

// The run of the caller that a method of the game changes; false after
// failing the call.
api_play_own_run :: proc(s:^Session,call:^api.Call,player:int) -> (r:^Run,ok:bool) {
    own:bool
    r,own=api_play_run(s,call,player)
    switch {
    case r==nil: api_no_game(call)
    case !own:   api_play_refused(call)
    case:        return r,true
    }
    return nil,false
}

// The queue of a storage: its field that is a core.Queue, and the type of its items.
@(private)
api_queue_of :: proc(info:^runtime.Type_Info) -> (offset:uintptr,item:^runtime.Type_Info,ok:bool) {
    s:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct) or_return
    for i in 0..<int(s.field_count) {
        named,is_named:=s.types[i].variant.(runtime.Type_Info_Named)
        if !is_named || !strings.has_prefix(named.name,"Queue") {continue}
        q,is_struct:=runtime.type_info_base(s.types[i]).variant.(runtime.Type_Info_Struct)
        if !is_struct || q.field_count==0 || q.names[0]!="items" {continue}
        items,dynamic_array:=runtime.type_info_base(q.types[0]).variant.(runtime.Type_Info_Dynamic_Array)
        if !dynamic_array {continue}
        return s.offsets[i],items.elem,true
    }
    return
}

@(private)
api_play_push :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Push_Params)
    storage:=p.storage
    r,ok:=api_play_own_run(s,call,p.player)
    if !ok {return}
    w:=run_ref(s,r)
    st:=api_state(s)
    info:^core.Storage_Info
    at:int
    for &candidate,i in s.info.storages {
        if candidate.place==.World && !candidate.by_world && candidate.name==storage {info,at=&candidate,i;break}
    }
    if info==nil {api.call_failf(call,api.INVALID_PARAMS,"storage %q is not a storage of the game; scene.inspect with world Game and storages lists them",storage);return}
    offset,item,queued:=api_queue_of(info.info)
    if !queued {api.call_failf(call,api.INVALID_PARAMS,"%s is not a queue: play.push takes a storage with a core.Queue, as @(storage,queue) declares one",storage);return}
    type:=st.queue_types[at]
    if type==serial.TYPE_NONE {api.call_failf(call,api.INVALID_PARAMS,"the requests of %s are not plain data the API can write",storage);return}
    // Every item is read before any is pushed: a failure pushes nothing.
    size:=item.size
    values:=make([dynamic]u8,call.allocator)
    count:=len(p.items)
    if count>API_PLAY_PUSH_LIMIT {api.call_failf(call,api.INVALID_PARAMS,"items holds %d requests at most: push the rest in another call",API_PLAY_PUSH_LIMIT);return}
    resize(&values,count*size)
    for text,i in p.items {
        bytes:=values[i*size:][:size]
        path:=fmt.aprintf("items[%d]",i,allocator=call.allocator)
        reader:serial.Text_Reader
        api.call_reader_init(call,&reader,string(text))
        if !serial.text_read(&reader,&st.schema,type,bytes) {
            line,column:=serial.text_position(reader.text,reader.error.offset)
            api.call_failf(call,api.INVALID_PARAMS,"%s at line %d column %d",serial.text_error_message(&reader,path,call.allocator),line,column)
            return
        }
        if message,valid:=api.value_check(&st.schema,type,bytes,path,call.allocator);!valid {api.call_fail(call,api.INVALID_PARAMS,message);return}
        for at in entity_offsets(item) {
            named:=core.Entity((cast(^u64)&bytes[at])^)
            if named!=core.NONE && !core.alive(core.world_entities(w),named) {
                api.call_failf(call,api.INVALID_PARAMS,"%s names 0x%016x, which is not alive in the game: Entity fields hold handles as scene.inspect with world Game gives them",path,u64(named))
                return
            }
        }
    }
    queue:=cast(^runtime.Raw_Dynamic_Array)(uintptr(core.world_storage_at(w,at))+offset)
    if queue.allocator.procedure==nil {queue.allocator=s.app.allocator}
    for i in 0..<count {
        runtime.__dynamic_array_append(queue,size,item.align,&values[i*size],1)
    }
    run_tell_call(s,r,"play.push",call.raw)
    api.call_result(call,Api_Play_Push_Result).pushed=count
}

