package editor

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import scene "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// Changes to the game that plays, as the game would make them between two
// ticks: values of components, teleports, prefabs spawned, entities
// destroyed and requests pushed to its queues. They go to the run of the
// caller (that of its turn, or the Play of the user outside a turn), never
// to the document, and take no step of the history.

API_PLAY_PUSH_LIMIT :: 64

Api_Play_Entity_Params :: struct {
    entity:[API_ENTITY_TEXT]u8 `mirai:"text,entity,label=The entity by its name or a path Parent/Child or its id or its handle"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Destroy_Result :: struct {
    destroyed:int `mirai:"label=Entities destroyed: it and what hangs from it"`,
}

Api_Play_Spawn_Params :: struct {
    asset:[API_PATH_BYTES]u8 `mirai:"text,label=The prefab: its file, a path inside the assets folder or its asset id"`,
    parent:[API_ENTITY_TEXT]u8 `mirai:"optional,text,entity,label=The entity it hangs from by its name or a path Parent/Child or its id or its handle; none: a root"`,
    position:[3]f32 `mirai:"optional,label=Of its root: in the world or local to parent"`,
    rotation_deg:[3]f32 `mirai:"optional,label=Of its root: in the world or local to parent"`,
    scale:[3]f32 `mirai:"optional,min=0,label=Of its root"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Spawn_Result :: struct {
    entity:[API_HANDLE_TEXT]u8 `mirai:"text,label=The handle of the root of what it placed"`,
    entities:int `mirai:"label=Entities it placed"`,
}

Api_Play_Set_Result :: struct {
    entity:[API_HANDLE_TEXT]u8 `mirai:"text,label=The handle of the entity"`,
    teleported:bool `mirai:"label=A teleport was asked: a free Transform holds it now; one a library owns (a body of physics) jumps there in the next tick"`,
}

Api_Play_Push_Result :: struct {
    pushed:int `mirai:"label=Items pushed; the functions that take the queue read them in the next tick"`,
}

@(private)
api_play_edit_register :: proc(s:^Session,st:^Api_State) {
    spawn_default:=Api_Play_Spawn_Params{scale={1,1,1}}
    api_register(s,st,{name="play.set",params_schema=API_PLAY_SET_SCHEMA,summary="Changes an entity of the game of the caller between two ticks: values of its components, and a teleport to a place of the world. Not the document, and not in the history.",result=Api_Play_Set_Result,run=api_play_set})
    api_register(s,st,{name="play.spawn",summary="Places a prefab in the game of the caller now, as the game spawns one; returns its root.",params=Api_Play_Spawn_Params,result=Api_Play_Spawn_Result,defaults=&spawn_default,run=api_play_spawn})
    api_register(s,st,{name="play.destroy",summary="Destroys an entity of the game of the caller with what hangs from it.",params=Api_Play_Entity_Params,result=Api_Play_Destroy_Result,flags={.Destructive},run=api_play_destroy})
    api_register(s,st,{name="play.push",params_schema=API_PLAY_PUSH_SCHEMA,summary="Pushes requests to a queue storage of the game of the caller, as its functions push them (Seat_Requests, Spawns or one of the game); the functions that take it read them in the next tick.",result=Api_Play_Push_Result,run=api_play_push})
    api_play_input_register(s,st)
}

// The run of the caller that a method of the game changes; false after
// failing the call.
api_play_own_run :: proc(s:^Session,call:^api.Call,player:int) -> (r:^Run,ok:bool) {
    own:bool
    r,own=api_play_run(s,call,player)
    switch {
    case r==nil: api.call_fail(call,api.SERVER_ERROR,API_NO_GAME)
    case !own:   api_play_refused(call)
    case:        return r,true
    }
    return nil,false
}

// The value of a component of a running world with the JSON object at r
// over it: Entity fields hold handles of live entities.
@(private)
api_play_component_read :: proc(s:^Session,w:core.World_Ref,t:^core.Table_Info,e:core.Entity,r:^serial.Text_Reader,bytes:[]u8,path:string,allocator:runtime.Allocator) -> (message:string,ok:bool) {
    st:=api_state(s)
    type:=st.types[api_table_index(s,t)]
    if current:=core.raw_find(core.world_table_at(w,t),t.info,e);current!=nil {
        api_value_out(w,t.info,current,bytes,handles=true)
    } else if t.default!=nil {
        t.default(raw_data(bytes))
    } else {
        component_default(t.type,bytes)
    }
    before:=slice.clone(bytes,allocator)
    if !serial.text_read(r,&st.schema,type,bytes) {
        line,column:=serial.text_position(r.text,r.error.offset)
        return fmt.aprintf("%s at line %d column %d",serial.text_error_message(r,path,allocator),line,column,allocator=allocator),false
    }
    if field:=read_only_written(&st.schema,type,before,bytes,"");field!="" {
        return fmt.aprintf("%s.%s is read only: leave it out of the value",path,field,allocator=allocator),false
    }
    if message,valid:=api.value_check(&st.schema,type,bytes,path,allocator);!valid {return message,false}
    for offset in entity_offsets(t.info) {
        named:=core.Entity((cast(^u64)&bytes[offset])^)
        if named!=core.NONE && !core.alive(core.world_entities(w),named) {
            return fmt.aprintf("%s names 0x%016x, which is not alive in the game: Entity fields of play.set hold handles as play.inspect gives them",path,u64(named),allocator=allocator),false
        }
    }
    return "",true
}

@(private)
Api_Play_Change :: struct {
    table:^core.Table_Info,
    bytes:[]u8, // nil: the component goes
}

@(private)
api_play_set :: proc(s:^Session,call:^api.Call) {
    a:Rpc_Args
    rpc_init(&a,call,call.raw)
    selector:[API_ENTITY_TEXT]u8
    selected,components:string
    player:int
    position,rotation_deg:[3]f32
    has_position,has_rotation:bool
    object:Rpc_Object
    if !rpc_object_begin(&a,"params") {return}
    for key in rpc_next(&a,&object) {
        switch key {
        case "entity":       selected,_=rpc_text(&a,key,selector[:])
        case "player":
            value,_:=rpc_unsigned(&a,key)
            if value>3 {rpc_fail(&a,"player is 0 to 3")}
            player=int(value)
        case "position":     has_position=rpc_vector(&a,key,position[:])
        case "rotation_deg": has_rotation=rpc_vector(&a,key,rotation_deg[:])
        case "components":   components,_=rpc_raw(&a)
        case:                rpc_fail_type(&a,"unknown field %q: play.set takes entity, position, rotation_deg, components and player",key)
        }
    }
    if a.failed {return}
    r,ok:=api_play_own_run(s,call,player)
    if !ok {return}
    w:=run_ref(s,r)
    e,problem:=api_entity_select(w,selected,game=true,allocator=call.allocator)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    if !has_position && !has_rotation && components=="" {
        api.call_fail(call,api.INVALID_PARAMS,"nothing to change: give position, rotation_deg or components")
        return
    }
    // Every value is read before anything changes: a failure changes nothing.
    changes:=make([dynamic]Api_Play_Change,call.allocator)
    if components!="" {
        c:Rpc_Args
        rpc_init(&c,call,components)
        values:Rpc_Object
        if !rpc_object_begin(&c,"components") {return}
        for key in rpc_next(&c,&values) {
            name:=strings.clone(key,call.allocator)
            t,_:=api_component_named(shown_world(s),name)
            if t==nil || t.place!=.World || api_state(s).types[api_table_index(s,t)]==serial.TYPE_NONE {rpc_fail(&c,"components: %q is not a component of the game; play.inspect names those of an entity",name);break}
            if !api_component_listed(s,t,true) {rpc_fail(&c,"components: %s is not changed as a component: position and rotation_deg teleport the entity",name);break}
            if serial.text_keyword(&c.r,"null") {append(&changes,Api_Play_Change{t,nil});continue}
            bytes:=make([]u8,max(t.info.size,1),call.allocator)
            if message,read:=api_play_component_read(s,w,t,e,&c.r,bytes[:t.info.size],strings.concatenate({"components.",name},call.allocator),call.allocator);!read {rpc_fail(&c,"%s",message);break}
            append(&changes,Api_Play_Change{t,bytes[:t.info.size]})
        }
        if c.failed {return}
    }
    placed:=entity_world(w,e)
    target,turn:=placed.position,placed.rotation
    if has_position {target=position}
    if has_rotation {turn=mm.quat_from_euler(rotation_deg*mm.RAD_PER_DEG)}
    placer:core.Placer
    if has_position || has_rotation {
        placer={core.world_table_of(w,core.Transform),core.read(core.world_table_of(w,core.Parent)),core.world_storage_of(w,core.Places),core.world_storage_of(w,core.Jumps)}
        if placer.transforms==nil || placer.places==nil || placer.jumps==nil || !core.has(placer.transforms,e) {
            api.call_fail(call,api.INVALID_PARAMS,"position and rotation_deg teleport an entity with a Transform, and this one has none")
            return
        }
    }
    for change in changes {
        table:=core.world_table_at(w,change.table)
        if change.bytes==nil {core.raw_remove(table,e)} else {core.raw_add(table,change.table.info,e,raw_data(change.bytes))}
    }
    core.world_settle(w)
    run_tell_call(s,r,"play.set",call.raw)
    result:=api.call_result(call,Api_Play_Set_Result)
    if has_position || has_rotation {
        if !core.place(placer,e,target,turn) {
            api.call_fail(call,api.SERVER_ERROR,"The teleport could not be asked: a parent of the entity cannot hold that place")
            return
        }
        core.world_settle(w)
        result.teleported=true
    }
    api_handle_put(result.entity[:],e)
}

@(private)
api_play_spawn :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Play_Spawn_Params)
    r,ok:=api_play_own_run(s,call,params.player)
    if !ok {return}
    w:=run_ref(s,r)
    id,located:=prefab_named(s,call,base.text_get(params.asset[:]))
    if !located {return}
    spawned:=scene.Spawn{prefab=id}
    if base.text_get(params.parent[:])!="" {
        known:bool
        if spawned.parent,known=api_call_entity(call,w,params.parent[:],"parent",game=true);!known {return}
    }
    spawned.transform={position=params.position,rotation=mm.quat_from_euler(params.rotation_deg*mm.RAD_PER_DEG),scale=params.scale}
    report,error:=scene.spawn_prefab(core.commands_of(w),s.app.assets,spawned)
    core.world_settle(w)
    if error!=.None {
        api.call_failf(call,api.SERVER_ERROR,"The prefab could not be spawned: %s",scene.error_text(error))
        return
    }
    run_tell_call(s,r,"play.spawn",call.raw)
    result:=api.call_result(call,Api_Play_Spawn_Result)
    api_handle_put(result.entity[:],report.root)
    result.entities=report.entities
}

@(private)
api_play_destroy :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Play_Entity_Params)
    r,ok:=api_play_own_run(s,call,params.player)
    if !ok {return}
    w:=run_ref(s,r)
    e,known:=api_call_entity(call,w,params.entity[:],game=true)
    if !known {return}
    run_tell_call(s,r,"play.destroy",call.raw)
    before:=core.world_entities(w).alive
    core.world_destroy_tree(w,e)
    core.world_settle(w)
    api.call_result(call,Api_Play_Destroy_Result).destroyed=before-core.world_entities(w).alive
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
    a:Rpc_Args
    rpc_init(&a,call,call.raw)
    name:[64]u8
    storage,items:string
    player:int
    object:Rpc_Object
    if !rpc_object_begin(&a,"params") {return}
    for key in rpc_next(&a,&object) {
        switch key {
        case "storage": storage,_=rpc_text(&a,key,name[:])
        case "items":   items,_=rpc_raw(&a)
        case "player":
            value,_:=rpc_unsigned(&a,key)
            if value>3 {rpc_fail(&a,"player is 0 to 3")}
            player=int(value)
        case: rpc_fail_type(&a,"unknown field %q: play.push takes storage, items and player",key)
        }
    }
    if a.failed {return}
    if storage=="" || items=="" {api.call_fail(call,api.INVALID_PARAMS,"give storage, the name of a queue storage, and items, an array of its requests");return}
    r,ok:=api_play_own_run(s,call,player)
    if !ok {return}
    w:=run_ref(s,r)
    st:=api_state(s)
    info:^core.Storage_Info
    at:int
    for &candidate,i in s.info.storages {
        if candidate.place==.World && !candidate.by_world && candidate.name==storage {info,at=&candidate,i;break}
    }
    if info==nil {api.call_failf(call,api.INVALID_PARAMS,"storage %q is not a storage of the game; play.inspect with storages lists them",storage);return}
    offset,item,queued:=api_queue_of(info.info)
    if !queued {api.call_failf(call,api.INVALID_PARAMS,"%s is not a queue: play.push takes a storage with a core.Queue, as @(storage,queue) declares one",storage);return}
    type:=st.queue_types[at]
    if type==serial.TYPE_NONE {api.call_failf(call,api.INVALID_PARAMS,"the requests of %s are not plain data the API can write",storage);return}
    // Every item is read before any is pushed: a failure pushes nothing.
    size:=item.size
    values:=make([dynamic]u8,call.allocator)
    count:=0
    c:Rpc_Args
    rpc_init(&c,call,items)
    if !serial.text_accept(&c.r,'[') {api.call_fail(call,api.INVALID_PARAMS,"items must be an array of requests");return}
    if !serial.text_accept(&c.r,']') {
        for {
            if count==API_PLAY_PUSH_LIMIT {api.call_failf(call,api.INVALID_PARAMS,"items holds %d requests at most: push the rest in another call",API_PLAY_PUSH_LIMIT);return}
            resize(&values,(count+1)*size)
            bytes:=values[count*size:][:size]
            path:=fmt.aprintf("items[%d]",count,allocator=call.allocator)
            if !serial.text_read(&c.r,&st.schema,type,bytes) {
                line,column:=serial.text_position(c.r.text,c.r.error.offset)
                api.call_failf(call,api.INVALID_PARAMS,"%s at line %d column %d",serial.text_error_message(&c.r,path,call.allocator),line,column)
                return
            }
            if message,valid:=api.value_check(&st.schema,type,bytes,path,call.allocator);!valid {api.call_fail(call,api.INVALID_PARAMS,message);return}
            for at in entity_offsets(item) {
                named:=core.Entity((cast(^u64)&bytes[at])^)
                if named!=core.NONE && !core.alive(core.world_entities(w),named) {
                    api.call_failf(call,api.INVALID_PARAMS,"%s names 0x%016x, which is not alive in the game: Entity fields hold handles as play.inspect gives them",path,u64(named))
                    return
                }
            }
            count+=1
            if serial.text_accept(&c.r,',') {continue}
            if !serial.text_accept(&c.r,']') {api.call_fail(call,api.INVALID_PARAMS,"items must be an array of requests");return}
            break
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

@(private) API_PLAY_SET_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["entity"],"properties":{"entity":{"type":"string","description":"the entity by its name, a path Parent/Child, its id or its handle; a name several entities have is an error listing them"},"position":{"type":"array","items":{"type":"number"},"minItems":3,"maxItems":3,"description":"where in the world it goes, as a teleport: a body of physics jumps there in the next tick"},"rotation_deg":{"type":"array","items":{"type":"number"},"minItems":3,"maxItems":3,"description":"its rotation in the world in degrees, with the teleport"},"components":{"type":"object","description":"by name the fields of each component to change as component.list describes them, with Entity fields holding handles; null removes it","additionalProperties":{"type":["object","null"]}},"player":{"type":"integer","minimum":0,"maximum":3,"description":"the run of that player of a game a turn plays on the network"}}}`
@(private) API_PLAY_PUSH_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["storage","items"],"properties":{"storage":{"type":"string","description":"the name of a queue storage of the game: Seat_Requests, Spawns or one of the project"},"items":{"type":"array","maxItems":64,"items":{"type":"object"},"description":"its requests as the schema of the type of its items, with Entity fields holding handles; play.inspect with storages names them"},"player":{"type":"integer","minimum":0,"maximum":3,"description":"the run of that player of a game a turn plays on the network"}}}`
