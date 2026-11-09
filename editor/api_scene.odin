package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// The scene through the agent API. Entities are named by their Id, as
// hexadecimal strings; transforms are local to the parent, with the rotation
// in degrees; the value of a component is the JSON of its schema, so the
// components of a game or a plugin need no code here. Every method that
// edits is one transaction of the history: an undo step, or nothing at all
// when any part of it fails.

API_BATCH_LIMIT :: 64
API_INSPECT_DEFAULT :: 256

Api_Inspect_Params :: struct {
    root:[API_ENTITY_TEXT]u8 `mirai:"optional,text,label=By its name or a path Parent/Child or its id: this entity and what hangs from it nested by children; the document scene.write takes"`,
    entity:[API_ENTITY_TEXT]u8 `mirai:"optional,text,label=By its name or a path Parent/Child or its id or handle: only this entity"`,
    name:[128]u8 `mirai:"optional,text,label=Only the entities with this name; * stands for any run of characters"`,
    component:[64]u8 `mirai:"optional,text,label=Only the entities that have this component"`,
    components:u8 `mirai:"any,optional,label=true: the values of every component; a list of names: only those; omitted: id, name, parent, position and the names of the components"`,
    include_runtime:bool `mirai:"optional,label=Include hidden fields and transient component state for inspection"`,
    offset:int `mirai:"optional,min=0"`,
    limit:int `mirai:"optional,min=1,max=4096,clamp"`,
    player:int `mirai:"optional,min=0,max=3,label=play.inspect: the run of that player of a game a turn plays on the network"`,
    storages:bool `mirai:"optional,label=Include the storages of the world by name with their values: in play.inspect the score or the state of a match"`,
    storage:[64]u8 `mirai:"optional,text,label=Only the storages with this name (* stands for any run of characters); implies storages"`,
}

Api_Entity_Params :: struct {
    entity:[API_ENTITY_TEXT]u8 `mirai:"text,label=The entity by its name or a path Parent/Child or its id"`,
}

Api_Edit_Result :: struct {
    id:base.Entity_Id `mirai:"label=The entity; the new one when the method makes one"`,
}

Api_Path_Params :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text,optional,label=A file or a path inside the asset folder; the file of the document when empty"`,
}

Api_File_Result :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text,label=The file of the document"`,
    entities:int `mirai:"label=Entities alive in the scene"`,
    dirty:bool `mirai:"label=Whether the document has unsaved changes"`,
}

Api_Inspect_Result :: struct {
    path:[DOCUMENT_PATH_BYTES]u8 `mirai:"text,label=The file of the document; empty before it has one"`,
    dirty:bool `mirai:"label=Whether the document has unsaved changes"`,
    playing:bool `mirai:"label=scene.inspect: whether the editor is out of Edit mode; play.inspect: true"`,
    total:int `mirai:"label=Entities alive in the world"`,
    offset:int,
    entities:[1]Api_Inspect_Entity `mirai:"list,label=Parents before their children and siblings in their order"`,
    shown:int,
    matched:int `mirai:"label=Entities the filters take"`,
    omitted:int `mirai:"label=Entities matched past the limit"`,
    storages:u8 `mirai:"any,optional,label=With storages: by name the value of each storage of the world that is plain data with Entity fields as the entities are named"`,
}
Api_Inspect_Entity :: struct {
    id:u8 `mirai:"any,label=The id in hexadecimal; null for an entity of a game that has none"`,
    entity:core.Entity `mirai:"optional,label=play.inspect: the handle of the entity in the game"`,
    name:[64]u8 `mirai:"text"`,
    parent:u8 `mirai:"any,optional,label=The id of the parent (in play.inspect its handle); null for a root; with root the nesting gives it"`,
    position:[3]f32 `mirai:"optional,label=Local to the parent"`,
    rotation_deg:[3]f32 `mirai:"optional,label=Local to the parent in degrees"`,
    scale:[3]f32 `mirai:"optional"`,
    world_position:[3]f32 `mirai:"optional"`,
    visible:bool `mirai:"optional"`,
    enabled:bool `mirai:"optional"`,
    active:bool `mirai:"optional,label=Whether it runs: false when it or a parent is disabled"`,
    off:[1][64]u8 `mirai:"text,list,optional,label=The components turned off by themselves"`,
    prefab:Api_Inspect_Prefab `mirai:"optional,label=scene.inspect: the link of a member of an instance of a prefab"`,
    components:u8 `mirai:"any,optional,label=By name the value of each component as component.list describes it with Entity fields holding ids (in play.inspect handles); with summary the list of their names; with root only the fields that differ from the value it starts with"`,
    children:u8 `mirai:"any,optional,label=With root: the entities that hang from it in their order nested the same way"`,
}
Api_Inspect_Prefab :: struct {
    instance:u32 `mirai:"optional,label=The instance placed in the document as prefab.list lists it; not with root"`,
    asset:base.Asset_Id `mirai:"label=The prefab"`,
    source:base.Entity_Id `mirai:"optional,label=The entity of the prefab it stands for; not with root"`,
    root:bool `mirai:"label=Whether it is the root of the instance"`,
}

// What api_play_player writes: Play_Player_Snapshot as JSON.
Api_Play_Player_Result :: struct {
    available:bool `mirai:"label=Whether a local seat has focus; without one the rest is empty"`,
    tick:u64,
    seconds:f32 `mirai:"label=The time of the game"`,
    seat:Api_Play_Player_Entity `mirai:"label=The focused local seat"`,
    body:Api_Play_Player_Entity `mirai:"label=The body the seat drives"`,
    camera:Api_Play_Player_Entity `mirai:"label=The camera the view shows; that of the body when the view names none"`,
}
Api_Play_Player_Entity :: struct {
    entity:[16]u8 `mirai:"text,label=The handle in hexadecimal; empty when there is no entity"`,
    id:[16]u8 `mirai:"text,label=The id in hexadecimal; empty for an entity without one"`,
    name:[64]u8 `mirai:"text"`,
    position:[3]f32 `mirai:"label=Local to the parent"`,
    rotation_deg:[3]f32 `mirai:"label=Local to the parent in degrees"`,
    scale:[3]f32,
    world_position:[3]f32,
}

Api_Batch_Result :: struct {
    results:[1]Api_Batch_Entry `mirai:"list,label=One per operation in their order"`,
}
Api_Batch_Entry :: struct {
    id:base.Entity_Id `mirai:"label=The entity of the operation; the new one of scene.add and scene.duplicate"`,
}

@(private)
api_scene_register :: proc(s:^Session,st:^Api_State) {
    inspect:=Api_Inspect_Params{limit=API_INSPECT_DEFAULT}
    api_register(s,st,{name="scene.inspect",summary="The entities of the document in save order with their place and the names of their components; with components, their transforms, prefab links and values; with root, that entity and what hangs from it as the nested document scene.write takes.",params=Api_Inspect_Params,result=Api_Inspect_Result,writes_result=true,defaults=&inspect,flags={.Core,.Read_Only},run=api_scene_inspect})
    api_register(s,st,{name="play.inspect",summary="As scene.inspect, on the world of the game that plays, whose entities are named by their handle; with storages, also its storages: the score or the state of a match.",params=Api_Inspect_Params,result=Api_Inspect_Result,writes_result=true,defaults=&inspect,flags={.Core,.Read_Only},run=api_play_inspect})
    api_register(s,st,{name="play.player",summary="The focused local seat of the game that plays, the body it drives and the camera that shows it. play.inspect with include_runtime reads the rest.",params=Api_Play_Player_Params,result=Api_Play_Player_Result,writes_result=true,flags={.Read_Only},run=api_play_player})
    api_register(s,st,{name="scene.add",flags={.Core},params_schema=API_ADD_SCHEMA,summary="Creates an entity from a preset or the card of a plugin.",result=Api_Edit_Result,run=api_scene_add})
    api_register(s,st,{name="scene.set",flags={.Core},params_schema=API_SET_SCHEMA,summary="Changes an entity; what the params leave out stays as it is.",result=Api_Edit_Result,run=api_scene_set})
    api_register(s,st,{name="scene.delete",summary="Destroys an entity with what hangs from it.",params=Api_Entity_Params,result=Api_Edit_Result,flags={.Core,.Destructive},run=api_scene_delete})
    api_register(s,st,{name="scene.duplicate",summary="Copies an entity and what hangs from it with new ids.",params=Api_Entity_Params,result=Api_Edit_Result,run=api_scene_duplicate})
    api_scene_write_register(s,st)
    api_register(s,st,{name="scene.batch",flags={.Core},params_schema=API_BATCH_SCHEMA,summary="Runs scene.add, scene.set, scene.delete and scene.duplicate operations as one transaction: one step of undo, undone whole when one fails.",result=Api_Batch_Result,writes_result=true,run=api_scene_batch})
    api_register(s,st,{name="scene.save",flags={.Core},summary="Writes the document to its file or to another, which becomes its file.",params=Api_Path_Params,result=Api_File_Result,run=api_scene_save})
    api_register(s,st,{name="scene.open",summary="Opens a scene or a prefab file as the document, with an empty history.",params=Api_Path_Params,result=Api_File_Result,flags={.Destructive},run=api_scene_open})
}

// ---------------------------------------------------------------- scene.inspect

// The component values the API names: what a scene saves, besides the identity and the place of an entity.
@(private)
api_component_listed :: proc(s:^Session,t:^core.Table_Info,include_runtime:=false) -> bool {
    if t.place!=.World || (!inspector_listed(s,t) && !(include_runtime && !type_saved(t.info))) {return false}
    st:=api_state(s)
    return st.types[api_table_index(s,t)]!=serial.TYPE_NONE
}

// The bytes of a component value as the API shows them: Entity fields hold
// Ids, or with handles the live entities, as a play world names them.
@(private)
api_value_out :: proc(w:core.World_Ref,type:^runtime.Type_Info,value:rawptr,bytes:[]u8,handles:=false) {
    size:=type.size
    if size>0 {runtime.mem_copy(raw_data(bytes),value,size)}
    if handles {return}
    for offset in entity_offsets(type) {
        field:=cast(^u64)&bytes[offset]
        field^=u64(api_entity_id(w,core.Entity(field^)))
    }
}

// Which components of an entity an inspect gives the values of.
@(private)
Api_Inspect_Values :: struct {
    every,listed:bool, // listed: the param gave a list of names, perhaps empty
    only:[]^core.Table_Info,
}

// What the param components of an inspect asks: true, every component; a
// list of names or one name, those; left out, none. false after failing the
// call.
@(private)
api_inspect_values :: proc(s:^Session,call:^api.Call,w:core.World_Ref,include_runtime:bool) -> (values:Api_Inspect_Values,ok:bool) {
    given:[1]string
    if !api.object_values(call.allocator,call.raw,{"components"},given[:]) || given[0]=="" {return {},true}
    if given[0]=="true" {return {every=true},true}
    names,is_list:=api.json_elements(given[0],call.allocator)
    if !is_list {
        names=make([dynamic]string,call.allocator)
        append(&names,given[0])
    }
    only:=make([dynamic]^core.Table_Info,call.allocator)
    for each in names {
        name,is_text:=api.json_string(each)
        if !is_text {api.call_fail(call,api.INVALID_PARAMS,"components must be true or a list of names of components");return}
        t,problem:=api_component_named(w,name)
        if t==nil {api.call_failf(call,api.INVALID_PARAMS,"components: %s; component.list lists them",problem);return}
        if !api_component_listed(s,t,include_runtime) {api.call_failf(call,api.INVALID_PARAMS,"components: %s has no values an inspect gives: Transform, Name, Parent, Hidden and Disabled have their own fields, and include_runtime gives the state of a game",name);return}
        append(&only,t)
    }
    return {listed=true,only=only[:]},true
}

@(private)
api_inspect_wants :: proc(values:Api_Inspect_Values,t:^core.Table_Info) -> bool {
    return values.every || slice.contains(values.only,t)
}

// components false writes only the id, the name, the parent, the local
// position and the names of its components. only: with components, those of
// these tables and no others.
@(private)
api_entity_write :: proc(s:^Session,w:core.World_Ref,out:^serial.Writer,e:core.Entity,components:bool,scratch:[]u8,play:bool,include_runtime:=false,only:[]^core.Table_Info=nil) {
    st:=api_state(s)
    id:=api_entity_id(w,e)
    serial.text_write_raw(out,`{"id":`)
    if id!=0 {api_write_id(out,id)} else {serial.text_write_raw(out,"null")}
    if play {
        api.write_key(out,"entity")
        serial.write_u8(out,'"');serial.text_write_hex(out,u64(e));serial.write_u8(out,'"')
    }
    api.write_key(out,"name");serial.text_write_string(out,entity_name(w,e))
    api.write_key(out,"parent")
    parent:=entity_parent(w,e)
    if play && parent!=core.NONE {serial.write_u8(out,'"');serial.text_write_hex(out,u64(parent));serial.write_u8(out,'"')}
    else if parent!=core.NONE && api_entity_id(w,parent)!=0 {api_write_id(out,api_entity_id(w,parent))}
    else {serial.text_write_raw(out,"null")}
    local:=entity_local(w,e)
    if !components {
        api.write_key(out,"position");api.write_list(out,local.position[:])
        api.write_key(out,"components");serial.write_u8(out,'[')
        first:=true
        for &t in s.info.tables {
            if !api_component_listed(s,&t,include_runtime) || core.raw_find(core.world_table_at(w,&t),t.info,e)==nil {continue}
            if !first {serial.write_u8(out,',')}
            first=false
            serial.text_write_string(out,t.name)
        }
        serial.text_write_raw(out,"]}")
        return
    }
    angles:=mm.quat_to_euler(local.rotation)*mm.DEG_PER_RAD
    api.write_key(out,"position");api.write_list(out,local.position[:])
    api.write_key(out,"rotation_deg");api.write_list(out,angles[:])
    api.write_key(out,"scale");api.write_list(out,local.scale[:])
    placed:=entity_world(w,e)
    api.write_key(out,"world_position");api.write_list(out,placed.position[:])
    api.write_key(out,"visible");api.write_flag(out,!entity_has(w,e,erender.Hidden))
    api.write_key(out,"enabled");api.write_flag(out,!entity_has(w,e,core.Disabled))
    api.write_key(out,"active");api.write_flag(out,!core.entity_off(core.world_entities(w),e))
    off_first:=true
    for &t in s.info.tables {
        if !api_component_listed(s,&t,include_runtime) {continue}
        if _,turned_off,_:=core.raw_state(core.world_table_at(w,&t),e);!turned_off {continue}
        if off_first {api.write_key(out,"off");serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        off_first=false
        serial.text_write_string(out,t.name)
    }
    if !off_first {serial.write_u8(out,']')}
    if !play {
        if link,linked:=prefab_link_of(s,id);linked {
            api.write_key(out,"prefab");serial.text_write_raw(out,`{"instance":`);serial.text_write_uint(out,u64(link.instance))
            api.write_key(out,"asset");api_asset_write(out,link.asset)
            api.write_key(out,"source");api_write_id(out,link.source)
            api.write_key(out,"root");api.write_flag(out,link.root)
            serial.write_u8(out,'}')
        }
    }
    api.write_key(out,"components");serial.write_u8(out,'{')
    first:=true
    for &t,i in s.info.tables {
        if !api_component_listed(s,&t,include_runtime) || only!=nil && !slice.contains(only,&t) {continue}
        table:=core.world_table_at(w,&t)
        value:=core.raw_find(table,t.info,e)
        if value==nil {continue}
        api_value_out(w,t.info,value,scratch,play)
        api.write_key(out,t.name,first)
        first=false
        size:=t.info.size
        omitted:=serial.Field_Flags{.Transient,.Hidden} if !include_runtime else serial.Field_Flags{}
        serial.text_write(out,&st.schema,st.types[i],scratch[:size],.Line,omit_fields=omitted)
    }
    serial.write_u8(out,'}')
    serial.write_u8(out,'}')
}

// The entities of a world depth first, parents before children, siblings in their order.
api_entities_ordered :: proc(w:core.World_Ref,allocator:=context.temp_allocator) -> []core.Entity {
    transforms:=core.world_table_of(w,core.Transform)
    parents:=core.world_table_of(w,core.Parent)
    h:=entity_hierarchy(w)
    out:=make([dynamic]core.Entity,allocator)
    if transforms==nil {return out[:]}
    for e in transforms.entities {
        if parents!=nil && core.has(parents,e) {continue}
        for at:=e;at!=core.NONE;at=core.subtree_next(h,e,at) {append(&out,at)}
    }
    return out[:]
}

@(private)
api_inspect_run :: proc(s:^Session,call:^api.Call,w:core.World_Ref,play:bool) {
    params:=api.call_params(call,Api_Inspect_Params)
    if base.text_get(params.root[:])!="" {
        if play {api.call_fail(call,api.INVALID_PARAMS,"root is of scene.inspect: the document scene.write takes");return}
        api_inspect_tree(s,call,w,params)
        return
    }
    out:=call.out
    st:=api_state(s)
    scratch,memory:=make([]u8,max(st.largest,1),call.allocator)
    if memory!=nil {
        api.call_fail(call,api.INTERNAL_ERROR,"the request needs more scratch memory than the server has")
        return
    }
    only:core.Entity
    if base.text_get(params.entity[:])!="" {
        known:bool
        if only,known=api_call_entity(call,w,params.entity[:],game=play);!known {return}
    }
    pattern:=base.text_get(params.name[:])
    component:^core.Table_Info
    if name:=base.text_get(params.component[:]);name!="" {
        problem:string
        if component,problem=api_component_named(w,name);component==nil {
            api.call_failf(call,api.INVALID_PARAMS,"component: %s; component.list lists them",problem)
            return
        }
    }
    values,read:=api_inspect_values(s,call,w,params.include_runtime)
    if !read {return}
    storages:=base.text_get(params.storage[:])
    if storages!="" && !api_storage_named(s,storages) {
        api.call_failf(call,api.INVALID_PARAMS,"storage %q names no storage of the world the API shows; leave it out with storages true to list them all",storages)
        return
    }
    entities:=core.world_entities(w)
    offset:=only!=core.NONE?0:params.offset
    serial.text_write_raw(out,`{"path":`);serial.text_write_string(out,document_path(s.document))
    api.write_key(out,"dirty");api.write_flag(out,document_dirty(s))
    api.write_key(out,"playing");api.write_flag(out,play || s.mode!=.Edit)
    api.write_key(out,"total");serial.text_write_int(out,i64(entities.alive))
    api.write_key(out,"offset");serial.text_write_int(out,i64(offset))
    api.write_key(out,"entities");serial.write_u8(out,'[')
    candidates:=[]core.Entity{only} if only!=core.NONE else api_entities_ordered(w)
    matched,shown:=0,0
    for e in candidates {
        if pattern!="" && !api_name_match(pattern,entity_name(w,e)) {continue}
        if component!=nil && core.raw_find(core.world_table_at(w,component),component.info,e)==nil {continue}
        matched+=1
        if matched<=offset || shown>=params.limit {continue}
        if shown>0 {serial.write_u8(out,',')}
        api_entity_write(s,w,out,e,values.every || len(values.only)>0,scratch,play,params.include_runtime,values.only)
        shown+=1
    }
    serial.write_u8(out,']')
    api.write_key(out,"shown");serial.text_write_int(out,i64(shown))
    api.write_key(out,"matched");serial.text_write_int(out,i64(matched))
    api.write_key(out,"omitted");serial.text_write_int(out,i64(max(matched-offset-shown,0)))
    if params.storages || storages!="" {
        api.write_key(out,"storages")
        api_storages_write(s,w,out,storages,scratch,play,params.include_runtime)
    }
    serial.write_u8(out,'}')
}

// The storages of a world the API shows whose name is the pattern ("": all),
// as an object by name.
@(private)
api_storages_write :: proc(s:^Session,w:core.World_Ref,out:^serial.Writer,pattern:string,scratch:[]u8,handles,include_runtime:bool) {
    st:=api_state(s)
    serial.write_u8(out,'{')
    first:=true
    for &info,i in s.info.storages {
        if st.storage_types[i]==serial.TYPE_NONE || pattern!="" && !api_name_match(pattern,info.name) {continue}
        value:=rawptr(uintptr(w.data)+info.offset)
        api_value_out(w,info.info,value,scratch,handles)
        api.write_key(out,info.name,first)
        first=false
        omitted:=serial.Field_Flags{.Transient,.Hidden} if !include_runtime else serial.Field_Flags{}
        serial.text_write(out,&st.schema,st.storage_types[i],scratch[:info.info.size],.Line,omit_fields=omitted)
    }
    serial.write_u8(out,'}')
}

// Whether a storage the API shows has a name the pattern takes.
@(private)
api_storage_named :: proc(s:^Session,pattern:string) -> bool {
    st:=api_state(s)
    for &info,i in s.info.storages {
        if st.storage_types[i]!=serial.TYPE_NONE && api_name_match(pattern,info.name) {return true}
    }
    return false
}

// Whether a name is the pattern, where * stands for any run of characters.
api_name_match :: proc "contextless" (pattern,name:string) -> bool {
    p,n:=0,0
    star,resume:=-1,0
    for n<len(name) {
        switch {
        case p<len(pattern) && pattern[p]=='*':
            star,resume=p,n
            p+=1
        case p<len(pattern) && pattern[p]==name[n]:
            p+=1;n+=1
        case star>=0:
            resume+=1
            p,n=star+1,resume
        case:
            return false
        }
    }
    for p<len(pattern) && pattern[p]=='*' {p+=1}
    return p==len(pattern)
}

@(private)
api_scene_inspect :: proc(s:^Session,call:^api.Call) {api_inspect_run(s,call,edited_world(s),false)}

@(private)
api_play_inspect :: proc(s:^Session,call:^api.Call) {
    r,_:=api_play_run(s,call,api.call_params(call,Api_Inspect_Params).player)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,API_NO_GAME);return}
    api_inspect_run(s,call,core.world_ref(r.world,s.info),true)
}

// ---------------------------------------------------------------- edits

// Sets, adds or removes one component from the value at the reader: an
// object with the fields to change, or null to remove it.
@(private)
api_component_apply :: proc(s:^Session,a:^Rpc_Args,w:core.World_Ref,e:core.Entity,name:string) -> bool {
    st:=api_state(s)
    t,problem:=api_component_named(shown_world(s),name)
    if t==nil || t.place!=.World {return rpc_fail(a,"components: %s; component.list lists them",problem)}
    if !api_component_listed(s,t) {return rpc_fail(a,"components: %s is not edited as a component: Transform, Name, Parent, Hidden and Disabled have their own fields (position, name, parent, visible, enabled)",name)}
    at:=api_table_index(s,t)
    type:=st.types[at]
    table:=core.world_table_at(w,t)
    current:=core.raw_find(table,t.info,e)
    if serial.text_keyword(&a.r,"null") {
        if current!=nil {component_remove(s,e,t)}
        core.world_settle(w)
        return true
    }
    size:=t.info.size
    bytes,memory:=make([]u8,max(size,1),a.call.allocator)
    if memory!=nil {
        api.call_fail(a.call,api.INTERNAL_ERROR,"the request needs more scratch memory than the server has")
        a.failed=true
        return false
    }
    if message,ok:=component_value_read(w,t,current,&st.schema,type,&a.r,bytes[:size],strings.concatenate({"components.",name},a.call.allocator),a.call.allocator,read_only_kept=true);!ok {
        return rpc_fail(a,"%s",message)
    }
    component_add(s,e,t,raw_data(bytes))
    core.world_settle(w)
    return true
}

// The path of the first read-only field whose bytes the reader changed; "" when none did.
@(private)
read_only_written :: proc(schema:^serial.Schema,type:serial.Type_Index,before,after:[]u8,prefix:string) -> string {
    for field in serial.schema_fields(schema,type) {
        inner:=serial.schema_type(schema,field.type)
        if inner==nil || int(field.offset+inner.size)>len(after) {continue}
        path:=prefix==""?field.name:strings.concatenate({prefix,".",field.name},context.temp_allocator)
        at:=before[field.offset:][:inner.size]
        now:=after[field.offset:][:inner.size]
        if .Read_Only in field.flags && !slice.equal(at,now) {return path}
        if inner.kind==.Struct {
            if found:=read_only_written(schema,field.type,at,now,path);found!="" {return found}
        }
    }
    return ""
}

// The value a component starts with, as the API shows it: Entity fields hold no id.
@(private)
component_start :: proc(t:^core.Table_Info,bytes:[]u8) {
    mem.zero_slice(bytes)
    if t.default!=nil {t.default(raw_data(bytes))} else {component_default(t.type,bytes)}
    for offset in entity_offsets(t.info) {(cast(^u64)&bytes[offset])^=0}
}

// Copies from kept the fields the API neither shows nor changes: hidden, transient and read-only ones.
@(private)
fields_kept :: proc(schema:^serial.Schema,type:serial.Type_Index,bytes,kept:[]u8) {
    for field in serial.schema_fields(schema,type) {
        inner:=serial.schema_type(schema,field.type)
        if inner==nil || int(field.offset+inner.size)>len(bytes) {continue}
        part:=bytes[field.offset:][:inner.size]
        if field.flags&{.Hidden,.Transient,.Read_Only}!={} {
            copy(part,kept[field.offset:][:inner.size])
        } else if inner.kind==.Struct {
            fields_kept(schema,field.type,part,kept[field.offset:][:inner.size])
        }
    }
}

// The value of a component with the JSON object at r applied over it: the
// current value, or the default without one, with the fields the object
// names. from, a value as the API shows it, is where it starts instead,
// keeping of the current value only what the API neither shows nor changes:
// hidden, transient and read-only fields. An Entity field holds the id it
// names, which must be an entity of the scene of w. path names the value in
// the messages.
component_value_read :: proc(w:core.World_Ref,t:^core.Table_Info,current:rawptr,schema:^serial.Schema,type:serial.Type_Index,r:^serial.Text_Reader,bytes:[]u8,path:string,allocator:runtime.Allocator,read_only_kept:=false,from:[]u8=nil) -> (message:string,ok:bool) {
    if from!=nil {
        copy(bytes,from)
        if current!=nil {
            kept:=make([]u8,len(bytes),allocator)
            api_value_out(w,t.info,current,kept)
            fields_kept(schema,type,bytes,kept)
        }
    } else if current!=nil {
        api_value_out(w,t.info,current,bytes)
    } else {
        component_start(t,bytes)
    }
    before:=read_only_kept?slice.clone(bytes,allocator):nil
    if !serial.text_read(r,schema,type,bytes) {
        line,column:=serial.text_position(r.text,r.error.offset)
        return fmt.aprintf("%s at line %d column %d",serial.text_error_message(r,path,allocator),line,column,allocator=allocator),false
    }
    if field:=read_only_kept?read_only_written(schema,type,before,bytes,""):"";field!="" {
        return fmt.aprintf("%s.%s is read only: leave it out of the value",path,field,allocator=allocator),false
    }
    if message,valid:=api.value_check(schema,type,bytes,path,allocator);!valid {return message,false}
    for offset in entity_offsets(t.info) {
        field:=cast(^u64)&bytes[offset]
        named:=field^
        if named==0 {continue}
        target:=api_entity(w,base.Entity_Id(named))
        if target==core.NONE {return fmt.aprintf("%s names 0x%016x, which is not an entity of the scene",path,named,allocator=allocator),false}
        field^=u64(target)
    }
    return "",true
}

@(private)
api_components_apply :: proc(s:^Session,a:^Rpc_Args,w:core.World_Ref,e:core.Entity) -> bool {
    object:Rpc_Object
    rpc_object_begin(a,"components") or_return
    name:[64]u8
    for key in rpc_next(a,&object) {
        count:=copy(name[:],key)
        api_component_apply(s,a,w,e,string(name[:count])) or_return
    }
    return !a.failed
}

// Turns components of the entity off by themselves, or on, from the object at
// the reader: by component name, true for off.
@(private)
api_off_apply :: proc(s:^Session,a:^Rpc_Args,w:core.World_Ref,e:core.Entity) -> bool {
    object:Rpc_Object
    rpc_object_begin(a,"off") or_return
    name:[64]u8
    for key in rpc_next(a,&object) {
        count:=copy(name[:],key)
        given:=string(name[:count])
        off:=rpc_bool(a,"off") or_return
        t,problem:=api_component_named(shown_world(s),given)
        if t==nil || t.place!=.World {return rpc_fail(a,"off: %s; component.list lists them",problem)}
        table:=core.world_table_at(w,t)
        if table.base {return rpc_fail(a,"off: %s is the base of every entity and does not turn off; enabled:false turns the whole entity off",given)}
        if core.raw_row(table,e)<0 {return rpc_fail(a,"off: the entity has no %s; add it with components first",given)}
        component_turn(s,e,t,off)
    }
    core.world_settle(w)
    return !a.failed
}

// What an add and a set share besides the transform and the name: raw objects
// at the reader for components and off.
@(private)
Api_Flags :: struct {
    visible,enabled:Maybe(bool),
    components,off:string,
}

@(private)
Api_Transform_Edit :: struct {
    position,rotation_deg,scale:[3]f32,
    has_position,has_rotation,has_scale:bool,
}

@(private)
api_transform_apply :: proc(s:^Session,a:^Rpc_Args,e:core.Entity,edit:Api_Transform_Edit) -> bool {
    if !edit.has_position && !edit.has_rotation && !edit.has_scale {return true}
    w:=edited_world(s)
    local:=entity_local(w,e)
    if edit.has_position {local.position=edit.position}
    if edit.has_rotation {local.rotation=mm.quat_from_euler(edit.rotation_deg*mm.RAD_PER_DEG)}
    if edit.has_scale {local.scale=edit.scale}
    if !transform_set(s,e,local) {return rpc_fail(a,"transform: the entity has no Transform")}
    return true
}

// The keys an add and a set share. handled is false for a key that is not one of them.
@(private)
api_common_key :: proc(a:^Rpc_Args,key:string,edit:^Api_Transform_Edit,name:^[64]u8,name_text:^string,flags:^Api_Flags) -> (handled,ok:bool) {
    switch key {
    case "name":
        name_text^,ok=rpc_text(a,key,name[:63])
    case "position":
        ok=rpc_vector(a,key,edit.position[:])
        edit.has_position=ok
    case "rotation_deg":
        ok=rpc_vector(a,key,edit.rotation_deg[:])
        edit.has_rotation=ok
    case "scale":
        ok=rpc_vector(a,key,edit.scale[:])
        edit.has_scale=ok
    case "visible":
        value:bool
        value,ok=rpc_bool(a,key)
        flags.visible=value
    case "enabled":
        value:bool
        value,ok=rpc_bool(a,key)
        flags.enabled=value
    case "components":
        flags.components,ok=rpc_raw(a)
    case "off":
        flags.off,ok=rpc_raw(a)
    case:
        return false,true
    }
    return true,ok
}

// Applies what an add and a set share once the entity exists.
@(private)
api_common_apply :: proc(s:^Session,a:^Rpc_Args,w:core.World_Ref,e:core.Entity,edit:Api_Transform_Edit,name:string,has_name:bool,flags:Api_Flags) -> bool {
    if has_name {
        if !entity_rename(s,e,name) {return rpc_fail(a,"name: the name is empty")}
    }
    api_transform_apply(s,a,e,edit) or_return
    if shown,given:=flags.visible.?;given {entity_hidden_set(s,e,!shown)}
    if on,given:=flags.enabled.?;given {entity_enabled_set(s,e,on)}
    core.world_settle(w)
    if flags.components!="" {
        inner:Rpc_Args
        rpc_init(&inner,a.call,flags.components)
        if !api_components_apply(s,&inner,w,e) {
            a.failed=true
            return false
        }
    }
    if flags.off!="" {
        inner:Rpc_Args
        rpc_init(&inner,a.call,flags.off)
        if !api_off_apply(s,&inner,w,e) {
            a.failed=true
            return false
        }
    }
    return true
}

// One scene.add inside the open transaction, from the params at the reader.
@(private)
api_add_apply :: proc(s:^Session,a:^Rpc_Args,w:core.World_Ref) -> (id:base.Entity_Id,ok:bool) {
    card:=int(Preset.Empty)
    parent:core.Entity
    edit:Api_Transform_Edit
    name:[64]u8
    name_text:string
    has_name:=false
    flags:Api_Flags
    object:Rpc_Object
    rpc_object_begin(a,"params") or_return
    for key in rpc_next(a,&object) {
        handled:=api_common_key(a,key,&edit,&name,&name_text,&flags) or_return
        if handled {
            has_name||=key=="name"
            continue
        }
        switch key {
        case "preset":
            text:[32]u8
            given:=rpc_text(a,key,text[:]) or_return
            found:bool
            card,found=card_named(s,given)
            if !found {return 0,rpc_fail(a,"preset: %s",cards_problem(s,given))}
        case "parent":
            parent=rpc_entity(a,w,key) or_return
        case:
            return 0,rpc_fail_unknown(a,key,"name","position","rotation_deg","scale","visible","enabled","components","off","preset","parent")
        }
    }
    if a.failed {return 0,false}
    transform:=core.TRANSFORM_IDENTITY
    if edit.has_position {transform.position=edit.position}
    if edit.has_rotation {transform.rotation=mm.quat_from_euler(edit.rotation_deg*mm.RAD_PER_DEG)}
    if edit.has_scale {transform.scale=edit.scale}
    named:=has_name && strings.trim_space(name_text)!=""
    if _,reason:=section_target_texts(s,w,parent!=core.NONE?parent:section_editing(s));reason!="" {return 0,rpc_fail(a,"%s",reason)}
    e:=entity_create(s,{card=card,parent=parent,transform=transform,name=strings.trim_space(name_text),named=named})
    if e==core.NONE {return 0,rpc_fail(a,"The prefab root has no size in some axis; a child cannot be placed")}
    core.world_settle(w)
    id=api_entity_id(w,e)
    edit.has_position,edit.has_rotation,edit.has_scale=false,false,false
    api_common_apply(s,a,w,e,edit,name_text,has_name && !named,flags) or_return
    return id,true
}

@(private)
api_set_apply :: proc(s:^Session,a:^Rpc_Args,w:core.World_Ref) -> (id:base.Entity_Id,ok:bool) {
    parent:core.Entity
    has_parent,has_name:=false,false
    e:core.Entity
    edit:Api_Transform_Edit
    name:[64]u8
    name_text:string
    flags:Api_Flags
    object:Rpc_Object
    rpc_object_begin(a,"params") or_return
    for key in rpc_next(a,&object) {
        handled:=api_common_key(a,key,&edit,&name,&name_text,&flags) or_return
        if handled {
            has_name||=key=="name"
            continue
        }
        switch key {
        case "entity":
            e=rpc_entity(a,w,key) or_return
        case "parent":
            parent=rpc_entity(a,w,key) or_return
            has_parent=true
        case:
            return 0,rpc_fail_unknown(a,key,"entity","name","position","rotation_deg","scale","visible","enabled","components","off","parent")
        }
    }
    if a.failed {return 0,false}
    if e==core.NONE {return 0,rpc_fail(a,"entity is required: its name, a path Parent/Child or its id")}
    id=api_entity_id(w,e)
    if text:=section_lock_text(s,w,e,true);text!="" {return 0,rpc_fail(a,"entity: %s",text)}
    if has_parent && entity_parent(w,e)!=parent {
        if _,reason:=section_target_texts(s,w,parent);reason!="" {return 0,rpc_fail(a,"%s",reason)}
        if prefab_member_locked(s,w,e) {
            return 0,rpc_fail(a,"parent: the entity is a member of an instance of a prefab and keeps the place its prefab gives it; edit the prefab or unlink the instance")
        }
        if !entity_reparent(s,e,parent) {return 0,rpc_fail(a,"parent: the parent is the entity or hangs from it, or has no size in some axis")}
        core.world_settle(w)
    }
    api_common_apply(s,a,w,e,edit,name_text,has_name,flags) or_return
    return id,true
}

@(private)
api_delete_apply :: proc(s:^Session,call:^api.Call,w:core.World_Ref,e:core.Entity) -> bool {
    if e==document_root(s,w) {api.call_fail(call,api.SERVER_ERROR,"The root of the prefab document cannot be deleted");return false}
    if text:=section_lock_text(s,w,e,true);text!="" {
        api.call_failf(call,api.SERVER_ERROR,"scene.delete: %s",text)
        return false
    }
    if prefab_member_locked(s,w,e) {
        api.call_fail(call,api.SERVER_ERROR,"scene.delete: the entity is a member of an instance of a prefab; turn it off with scene.set enabled false to leave it out of this instance, delete the instance, or unlink it")
        return false
    }
    entities_delete(s,{e})
    core.world_settle(w)
    return true
}

@(private)
api_duplicate_apply :: proc(s:^Session,call:^api.Call,w:core.World_Ref,e:core.Entity) -> (copy:base.Entity_Id,ok:bool) {
    if text:=section_lock_text(s,w,e,true);text!="" {
        api.call_failf(call,api.SERVER_ERROR,"scene.duplicate: %s",text)
        return 0,false
    }
    copies:=entities_duplicate(s,{e})
    core.world_settle(w)
    if len(copies)==0 {
        api.call_fail(call,api.SERVER_ERROR,"scene.duplicate: nothing was copied")
        return 0,false
    }
    return api_entity_id(w,copies[0]),true
}

@(private)
api_scene_add :: proc(s:^Session,call:^api.Call) {
    if !api_edit_begin(s,call,"Add entity") {return}
    w:=edited_world(s)
    a:Rpc_Args
    rpc_init(&a,call,call.raw)
    id,applied:=api_add_apply(s,&a,w)
    if api_edit_end(s,call,applied) {api.call_result(call,Api_Edit_Result).id=id}
}

@(private)
api_scene_set :: proc(s:^Session,call:^api.Call) {
    if !api_edit_begin(s,call,"Edit entity") {return}
    w:=edited_world(s)
    a:Rpc_Args
    rpc_init(&a,call,call.raw)
    id,applied:=api_set_apply(s,&a,w)
    if api_edit_end(s,call,applied) {api.call_result(call,Api_Edit_Result).id=id}
}

@(private)
api_scene_delete :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Entity_Params)
    if !api_edit_begin(s,call,"Delete entity") {return}
    w:=edited_world(s)
    e,known:=api_call_entity(call,w,params.entity[:])
    id:=api_entity_id(w,e)
    if api_edit_end(s,call,known && api_delete_apply(s,call,w,e)) {api.call_result(call,Api_Edit_Result).id=id}
}

@(private)
api_scene_duplicate :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Entity_Params)
    if !api_edit_begin(s,call,"Duplicate entity") {return}
    w:=edited_world(s)
    e,known:=api_call_entity(call,w,params.entity[:])
    copied:base.Entity_Id
    applied:=false
    if known {copied,applied=api_duplicate_apply(s,call,w,e)}
    if api_edit_end(s,call,applied) {api.call_result(call,Api_Edit_Result).id=copied}
}

@(private)
Api_Operation :: struct {method,params:string}

@(private)
api_scene_batch :: proc(s:^Session,call:^api.Call) {
    operations,memory:=make([]Api_Operation,API_BATCH_LIMIT,call.allocator)
    if memory!=nil {
        api.call_fail(call,api.INTERNAL_ERROR,"the request needs more scratch memory than the server has")
        return
    }
    count:=0
    a:Rpc_Args
    rpc_init(&a,call,call.raw)
    object:Rpc_Object
    if !rpc_object_begin(&a,"params") {return}
    for key in rpc_next(&a,&object) {
        switch key {
        case "operations":
            if !serial.text_accept(&a.r,'[') {rpc_fail(&a,"operations must be an array");break}
            if serial.text_accept(&a.r,']') {break}
            for !a.failed {
                if count>=API_BATCH_LIMIT {rpc_fail(&a,"operations has more than %d entries",API_BATCH_LIMIT);break}
                operation:=&operations[count]
                operation.params="{}"
                inner:Rpc_Object
                if !rpc_object_begin(&a,"an operation") {break}
                for field in rpc_next(&a,&inner) {
                    switch field {
                    case "method":
                        // The name is kept in the scratch of the call: the reader reuses its buffer.
                        text:[32]u8
                        if name,ok:=rpc_text(&a,field,text[:]);ok {operation.method=strings.clone(name,call.allocator)}
                    case "params": operation.params,_=rpc_raw(&a)
                    case:          rpc_fail_unknown(&a,field,"method","params")
                    }
                }
                count+=1
                if serial.text_accept(&a.r,',') {continue}
                if !serial.text_accept(&a.r,']') {rpc_fail(&a,"operations must be an array")}
                break
            }
        case:
            rpc_fail_unknown(&a,key,"operations")
        }
    }
    if a.failed {return}
    for &operation,i in operations[:count] {
        if call.server==nil {break}
        method:=api.method_find(call.server,operation.method)
        if method==nil {continue}
        shaped,problem:=api.params_shape(call.server,api.params_schema_text(call.server,method),operation.params)
        if problem!="" {api.call_failf(call,api.INVALID_PARAMS,"operations[%d].params: %s",i,problem);return}
        operation.params=shaped
    }
    if count==0 {
        api.call_failf(call,api.INVALID_PARAMS,"operations must have 1 to %d entries",API_BATCH_LIMIT)
        return
    }
    for operation,index in operations[:count] {
        switch operation.method {
        case "scene.add","scene.set","scene.delete","scene.duplicate":
        case:
            api.call_failf(call,api.INVALID_PARAMS,"operations[%d]: %q is not an operation of a batch",index,operation.method)
            return
        }
    }
    if !api_edit_begin(s,call,"Batch") {return}
    world:=edited_world(s)
    ids,_:=make([]base.Entity_Id,count,call.allocator)
    applied:=true
    failed_at:=-1
    for operation,at in operations[:count] {
        inner:Rpc_Args
        rpc_init(&inner,call,operation.params)
        switch operation.method {
        case "scene.add": ids[at],applied=api_add_apply(s,&inner,world)
        case "scene.set": ids[at],applied=api_set_apply(s,&inner,world)
        case "scene.delete","scene.duplicate":
            target:core.Entity
            fields:Rpc_Object
            applied=rpc_object_begin(&inner,"params")
            for field in rpc_next(&inner,&fields) {
                switch field {
                case "entity": target,_=rpc_entity(&inner,world,field)
                case:          rpc_fail_unknown(&inner,field,"entity")
                }
            }
            applied=applied && !inner.failed
            if applied && target==core.NONE {applied=rpc_fail(&inner,"entity is required")}
            if applied {
                if operation.method=="scene.delete" {
                    ids[at]=api_entity_id(world,target)
                    applied=api_delete_apply(s,call,world,target)
                } else {
                    ids[at],applied=api_duplicate_apply(s,call,world,target)
                }
            }
        }
        if !applied || call.failed {
            failed_at=at
            break
        }
    }
    if failed_at>=0 && call.failed {
        call.error.message=api.format_text(call.allocator,"operations[%d]: %s",failed_at,call.error.message)
    }
    if !api_edit_end(s,call,failed_at<0) {return}
    w:=call.out
    serial.text_write_raw(w,`{"results":[`)
    for id,at in ids {
        if at>0 {serial.write_u8(w,',')}
        serial.text_write_raw(w,`{"id":`);api_write_id(w,id);serial.write_u8(w,'}')
    }
    serial.text_write_raw(w,"]}")
}

// ---------------------------------------------------------------- files

@(private)
api_file_result :: proc(s:^Session,call:^api.Call) {
    result:=api.call_result(call,Api_File_Result)
    result.entities,result.dirty=core.world_entities(edited_world(s)).alive,document_dirty(s)
    api_text_put(result.path[:],document_path(s.document))
}

@(private)
api_document_fail :: proc(call:^api.Call,error:Document_Error,path:string) {
    api.call_failf(call,api.SERVER_ERROR,"%s: %s",path,document_error_text(error))
}

@(private)
api_scene_save :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Path_Params)
    if !api_guard(s,call) {return}
    if !collab_can_save(s) {
        api.call_fail(call,api.SERVER_ERROR,"The host of the session saves the shared scene")
        return
    }
    path:=base.text_get(params.path[:])
    if path=="" {path=document_path(s.document)}
    if path=="" {
        api.call_fail(call,api.SERVER_ERROR,"The scene has no file yet; pass a path")
        return
    }
    if error:=scene_save(s,strings.clone(path,call.allocator));error!=.None {
        api_document_fail(call,error,path)
        return
    }
    api_file_result(s,call)
}

@(private)
api_scene_open :: proc(s:^Session,call:^api.Call) {
    if api_turn_refused(s,call,"replace the document and its history") {return}
    params:=api.call_params(call,Api_Path_Params)
    if !collab_can_open(s) {
        api.call_fail(call,api.SERVER_ERROR,"Leave the session before opening another scene (collab.leave)")
        return
    }
    path:=base.text_get(params.path[:])
    if path=="" {path=document_path(s.document)}
    if path=="" {
        api.call_fail(call,api.SERVER_ERROR,"The scene has no file yet; pass a path")
        return
    }
    target:=strings.clone(path,call.allocator)
    tools_release(s)
    if error:=scene_open(s,target);error!=.None {
        api_document_fail(call,error,target)
        return
    }
    following:=host.load_phase_begin(s.app,.Editor)
    prefabs_follow(s,prefabs_of(s))
    host.load_phase_end(s.app,following)
    host.load_ready(s.app,.Scene,core.world_entities(edited_world(s)).alive)
    api_file_result(s,call)
}

// The shapes of the params of the methods that read them by hand.
@(private) API_ADD_SCHEMA :: `{"type":"object","additionalProperties":false,"properties":{"preset":{"type":"string","description":"empty, cube, sphere, cylinder, cone, capsule, plane, prism, pyramid, point_light, spot_light, rect_light, sun, camera, spawn, particles, or the card of a plugin by its label"},"name":{"type":"string"},"parent":{"type":["string","null"],"description":"the parent by its name, a path Parent/Child or its id; null: a root"},"position":{"type":"array","items":{"type":"number"},"minItems":3,"maxItems":3},"rotation_deg":{"type":"array","items":{"type":"number"},"minItems":3,"maxItems":3},"scale":{"type":"array","items":{"type":"number"},"minItems":3,"maxItems":3},"visible":{"type":"boolean"},"enabled":{"type":"boolean","description":"false turns the entity and everything under it off: their components keep their values and no system sees them"},"components":{"type":"object","additionalProperties":{"type":"object"},"description":"by component name, the fields to set"},"off":{"type":"object","additionalProperties":{"type":"boolean"},"description":"by component name, true turns the component off by itself and false on; it keeps its values"}}}`
@(private) API_SET_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["entity"],"properties":{"entity":{"type":"string","description":"the entity by its name, a path Parent/Child or its id; a name several entities have is an error listing them"},"name":{"type":"string","description":"its new name"},"parent":{"type":["string","null"],"description":"the parent by its name, a path Parent/Child or its id; null: a root"},"position":{"type":"array","items":{"type":"number"},"minItems":3,"maxItems":3},"rotation_deg":{"type":"array","items":{"type":"number"},"minItems":3,"maxItems":3},"scale":{"type":"array","items":{"type":"number"},"minItems":3,"maxItems":3},"visible":{"type":"boolean"},"enabled":{"type":"boolean","description":"false turns the entity and everything under it off: their components keep their values and no system sees them"},"components":{"type":"object","additionalProperties":{"type":["object","null"]},"description":"by component name, the fields to change, or null to remove it"},"off":{"type":"object","additionalProperties":{"type":"boolean"},"description":"by component name, true turns the component off by itself and false on; it keeps its values"}}}`
@(private) API_BATCH_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["operations"],"properties":{"operations":{"type":"array","minItems":1,"maxItems":64,"items":{"type":"object","required":["method"],"additionalProperties":false,"properties":{"method":{"type":"string","enum":["scene.add","scene.set","scene.delete","scene.duplicate"]},"params":{"type":"object","description":"the params of that method"}}}}}}`
